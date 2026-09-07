defmodule LiveQuizWeb.RequestLogging do
  @moduledoc """
  Which requests are logged with their address, and which are not logged at all.

  Filtering parameters keeps a password out of the log. It does nothing for a
  secret that travels in the **path**, and three of this application's do: the
  reset link, the confirmation link and the e-mail change link all carry their
  token as a path segment, and the request line is logged with the path in it
  (R04).

  Redacting the segment would be the nicer answer and is not available: Phoenix
  logs the line from the connection, and by the time this could rewrite it the
  routing has already happened. What *is* available is not logging those lines,
  which is what this does — the level for a request carrying a token in its path
  is `false`.

  It costs the access log entry for four routes. What it buys is that a token
  good enough to take over an account does not sit in a log file, a log
  aggregator, or whatever ships them onward.

  Everything else keeps the level it always had.
  """

  # Only the prefixes whose *next* segment is a token. `/users/settings` is not
  # one of them; `/users/settings/confirm-email/<token>` is.
  @secret_in_path [
    ~w(users reset-password),
    ~w(users confirm),
    ~w(users settings confirm-email)
  ]

  @doc """
  The level `Plug.Telemetry` should log this request at, or `false` for silence.

  Wired in the endpoint as `plug Plug.Telemetry, log: {__MODULE__, :level, []}`.
  """
  @spec level(Plug.Conn.t()) :: Logger.level() | false
  def level(%Plug.Conn{path_info: path_info}) do
    if secret_in_path?(path_info), do: false, else: :info
  end

  @doc "Whether this path carries a credential in one of its segments."
  @spec secret_in_path?([String.t()]) :: boolean()
  def secret_in_path?(path_info) when is_list(path_info) do
    Enum.any?(@secret_in_path, fn prefix ->
      # A token has to actually be there: the prefix alone is a listing page.
      List.starts_with?(path_info, prefix) and length(path_info) > length(prefix)
    end)
  end

  @doc "The path prefixes whose next segment is a credential."
  @spec secret_prefixes() :: [[String.t()]]
  def secret_prefixes, do: @secret_in_path
end
