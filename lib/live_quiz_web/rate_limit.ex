defmodule LiveQuizWeb.RateLimit do
  @moduledoc """
  Where the budgets of `LiveQuiz.RateLimit` meet a request.

  A plug for the endpoints whose budget is per origin, and the origin itself
  for the callers that key on something else too — a login also counts against
  the account it names, and a LiveView has no plug pipeline to hang this on.

  ## What "origin" means here

  `conn.remote_ip`, and nothing else. The `X-Forwarded-For` header is *not*
  read: it is written by whoever sends the request, so trusting it would let
  anybody spend somebody else's budget and none of their own — a limiter keyed
  on a value the attacker chooses is not a limiter. A deployment behind a proxy
  has to make the proxy set the peer address (or add a plug that trusts one
  named hop), which is a deployment decision and not a default.

  ## Why the address is truncated

  Counting a full IPv6 address counts nothing: a single subscriber is routinely
  handed a /64, which is more addresses than the table could ever hold. IPv6 is
  therefore counted per /64 and IPv4 per address, so the unit of the budget is
  roughly "one connection" in both.
  """

  import Plug.Conn

  alias LiveQuiz.RateLimit
  alias LiveQuizWeb.Api.ErrorJSON

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
  def origin(%Plug.Conn{remote_ip: remote_ip}), do: origin(remote_ip)
  def origin({_a, _b, _c, _d} = ipv4), do: ipv4
  def origin({a, b, c, d, _e, _f, _g, _h}), do: {a, b, c, d}
  # A LiveView reached over a socket whose peer data was not asked for. One
  # bucket for all of them is a worse budget than one per address and a better
  # one than none.
  def origin(_unknown), do: :unknown

  @doc """
  Remembers the origin of a LiveView, so its events can be budgeted.

  `get_connect_info/2` only answers during `mount/3` and only on the connected
  mount, so the address is read once and kept in the socket. A disconnected
  mount renders and spends nothing, which is right: it is a page, not an
  attempt.
  """
  @spec assign_origin(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_origin(socket) do
    origin =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> origin(address)
        _disconnected_or_absent -> :unknown
      end

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
