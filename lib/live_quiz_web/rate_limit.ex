defmodule LiveQuizWeb.RateLimit do
  @moduledoc """
  Where the budgets of `LiveQuiz.RateLimit` meet a request.

  A plug for the endpoints whose budget is per origin, and the origin itself
  for the callers that key on something else too — a login also counts against
  the account it names, and a LiveView has no plug pipeline to hang this on.

  ## What "origin" means here

  The address of whoever made the request, which depends on what is in front of
  the application — and that is **declared**, never guessed.

  `TRUSTED_PROXY_HOPS=0` means nothing is in front: the origin is
  `conn.remote_ip`, the peer of the socket, which no client can forge.

  `TRUSTED_PROXY_HOPS=N` means N proxies are, and the origin is the entry *N
  from the end* of `X-Forwarded-For` — the one the nearest trusted proxy
  observed and appended. The front of that list is written by the client and is
  worth nothing: a limiter keyed on a value the caller picks is not a limiter,
  which is why the count from the end is the whole point.

  Guessing wrong in either direction is bad, and one direction is worse. Read
  the header when nothing sets it and anybody spends anybody's budget. Read the
  peer when a balancer is in front and *every request in the world* lands on
  one key — which is not a weak limiter but an outage, since a room of thirty
  people entering at once locks itself out of a budget of twenty. That is why
  production refuses to start without the variable rather than picking a side.

  When the header carries fewer hops than were declared, the topology is not
  what it was said to be. The origin falls back to the peer and the fact is
  logged and emitted, instead of being quietly guessed.

  ## Why the address is truncated

  Counting a full IPv6 address counts nothing: a single subscriber is routinely
  handed a /64, which is more addresses than the table could ever hold. IPv6 is
  therefore counted per /64 and IPv4 per address, so the unit of the budget is
  roughly "one connection" in both.
  """

  import Plug.Conn

  alias LiveQuiz.RateLimit
  alias LiveQuizWeb.Api.ErrorJSON

  require Logger

  @doc """
  Plug that spends one attempt of `:bucket`, keyed by the origin of the request.

  Refuses with `429` and a `Retry-After` in whole seconds, in the same error
  envelope as every other refusal of the API, and halts — the point of a budget
  is that the expensive work never starts.
  """
  @spec init(keyword()) :: keyword()
  def init(opts), do: Keyword.validate!(opts, [:bucket])

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    case RateLimit.hit(Keyword.fetch!(opts, :bucket), origin(conn)) do
      :ok -> conn
      {:error, retry_after} -> refuse(conn, retry_after)
    end
  end

  @doc """
  The key an origin is counted by: a v4 address, or the /64 of a v6 one.
  """
  @spec origin(Plug.Conn.t() | :inet.ip_address() | nil) :: term()
  def origin(%Plug.Conn{} = conn) do
    resolve(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))
  end

  def origin({_a, _b, _c, _d} = ipv4), do: ipv4
  def origin({a, b, c, d, _e, _f, _g, _h}), do: {a, b, c, d}
  # A LiveView reached over a socket whose peer data was not asked for. One
  # bucket for all of them is a worse budget than one per address and a better
  # one than none.
  def origin(_unknown), do: :unknown

  @doc """
  How many trusted proxies stand in front of the application.

  Zero — a direct connection — is the default everywhere but production, which
  requires the variable to be set because a silent default is the defect.
  """
  @spec trusted_proxy_hops() :: non_neg_integer()
  def trusted_proxy_hops do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:trusted_proxy_hops, 0)
  end

  @doc """
  The origin of a request, from its peer and its forwarded headers.

  Both a connection and a socket end up here, because both arrive through
  whatever is in front of the application and both have to be counted the same
  way.
  """
  @spec resolve(:inet.ip_address() | nil, [String.t()]) :: term()
  def resolve(peer, forwarded) do
    case trusted_proxy_hops() do
      0 -> origin(peer)
      hops -> origin(forwarded_address(forwarded, hops) || peer)
    end
  end

  # The nearest trusted proxy appended what it saw to the end of the list, so
  # the address to count is `hops` from the end. Everything before it is the
  # client's to write, and is worth exactly nothing.
  defp forwarded_address(forwarded, hops) do
    addresses =
      forwarded
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.at(addresses, -hops) do
      nil -> untrusted(:too_few_hops)
      address -> parse(address) || untrusted(:unparsable)
    end
  end

  defp parse(address) do
    case address |> String.to_charlist() |> :inet.parse_address() do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end

  # The header is not the shape the deployment said it would be. Falling back to
  # the peer is the safe answer — at worst one bucket, never somebody else's —
  # and saying so out loud is what turns a misconfiguration into something
  # findable instead of a room that mysteriously locks itself out.
  defp untrusted(reason) do
    :telemetry.execute([:live_quiz, :rate_limit, :untrusted_origin], %{count: 1}, %{
      reason: reason
    })

    Logger.warning(
      "X-Forwarded-For does not carry #{trusted_proxy_hops()} trusted hop(s) (#{reason}); " <>
        "counting the socket peer instead. Check TRUSTED_PROXY_HOPS against the deployment."
    )

    nil
  end

  @doc """
  Remembers the origin of a LiveView, so its events can be budgeted.

  `get_connect_info/2` only answers during `mount/3` and only on the connected
  mount, so the address is read once and kept in the socket. A disconnected
  mount renders and spends nothing, which is right: it is a page, not an
  attempt.
  """
  @spec assign_origin(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_origin(socket) do
    peer =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _disconnected_or_absent -> nil
      end

    # A socket arrives through the same proxies a request does, so it is counted
    # the same way — otherwise the two budgets a LiveView spends, entering a room
    # and asking for a reset link, would be the ones that collapse.
    forwarded =
      socket
      |> Phoenix.LiveView.get_connect_info(:x_headers)
      |> List.wrap()
      |> Enum.filter(fn {name, _value} -> name == "x-forwarded-for" end)
      |> Enum.map(fn {_name, value} -> value end)

    origin = resolve(peer, forwarded)

    Phoenix.Component.assign(socket, :rate_limit_origin, origin)
  end

  @doc """
  Spends one attempt of `bucket` for the origin remembered in the socket.
  """
  @spec hit(Phoenix.LiveView.Socket.t(), RateLimit.bucket()) :: :ok | {:error, pos_integer()}
  def hit(%Phoenix.LiveView.Socket{} = socket, bucket) do
    RateLimit.hit(bucket, socket.assigns[:rate_limit_origin] || :unknown)
  end

  @doc """
  Writes the `429` an API caller gets, and halts the pipeline.
  """
  @spec refuse(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def refuse(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode_to_iodata!(ErrorJSON.render("429.json", %{})))
    |> halt()
  end
end
