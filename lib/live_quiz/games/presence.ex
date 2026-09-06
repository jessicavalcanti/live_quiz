defmodule LiveQuiz.Games.Presence do
  @moduledoc """
  Who is connected to a room **right now**.

  Presence is the only ephemeral state of the domain (AD-23) and it is the
  source of truth for nothing else: the database still answers who signed up,
  who left and whether the room is live. A restart wipes it clean, which is the
  correct state — nobody is connected to an application that just booted — and
  it fills up again as browsers reconnect.

  Presences are keyed by what they represent, never by the process holding
  them: `participant:<id>` for a participation and `host:<user_id>` for the
  host. That is what makes two tabs of the same person one connected person,
  and it is why `connected_count/1` counts keys instead of metas.

  Every change on a room topic is announced to the subscribers as
  `{:presence_changed, session_id}` — a nudge to re-read, not a payload — and
  the host coming and going is forwarded to `LiveQuiz.Games.HostMonitor`, which
  owns the grace period. No rule is decided here: this module counts, and
  `LiveQuiz.Games` decides.

  The diff announcement is a `local_broadcast`: every node runs its own tracker
  and receives the same diff, so a cluster-wide broadcast would deliver one
  message per node.
  """

  use Phoenix.Presence,
    otp_app: :live_quiz,
    pubsub_server: LiveQuiz.PubSub

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.HostMonitor
  alias LiveQuiz.Games.Participant

  @participant_prefix "participant:"
  @host_prefix "host:"

  @doc """
  Registers the presence of a participation on the topic of its room.

  `pid` is the process whose life the presence follows — the LiveView — so the
  presence disappears on its own when the browser goes away. Tracking the same
  participation from another tab adds a meta to the same key and still counts
  as one connected person.
  """
  @spec track_participant(pid(), Participant.t(), Ecto.UUID.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def track_participant(pid, %Participant{} = participant, connection_id) when is_pid(pid) do
    track(
      pid,
      Games.topic(participant.game_session_id),
      participant_key(participant),
      meta(connection_id)
    )
  end

  @doc """
  Registers the presence of the host on the topic of the room.

  The key is the account, not the room, so the host reloading the page or
  opening a second tab never looks like two different people to
  `host_connected?/1`.
  """
  @spec track_host(pid(), GameSession.t(), Ecto.UUID.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def track_host(pid, %GameSession{} = session, connection_id) when is_pid(pid) do
    track(pid, Games.topic(session.id), host_key(session), meta(connection_id))
  end

  @doc """
  Ids of the participations connected to the room.

  Whoever signed up and is not connected right now is simply absent from the
  set: the lobby still lists them, marked as disconnected, because the seat is
  still theirs (AD-27).
  """
  @spec connected_participant_ids(integer()) :: MapSet.t(integer())
  def connected_participant_ids(session_id) do
    session_id
    |> presences()
    |> Enum.flat_map(fn {key, _presence} -> participant_id(key) end)
    |> MapSet.new()
  end

  @doc """
  How many participations are connected — the argument `start_game_session/3`
  takes.

  Counts people, not connections: two tabs of the same participation are one.
  The host is not a participant and is never counted here.
  """
  @spec connected_count(integer()) :: non_neg_integer()
  def connected_count(session_id) do
    session_id |> connected_participant_ids() |> MapSet.size()
  end

  @doc "Tells whether the host of the room is connected from anywhere."
  @spec host_connected?(integer()) :: boolean()
  def host_connected?(session_id) do
    session_id |> presences() |> Enum.any?(fn {key, _presence} -> host_key?(key) end)
  end

  @impl Phoenix.Presence
  def init(_opts), do: {:ok, %{}}

  @impl Phoenix.Presence
  def handle_metas(topic, diff, presences, state) do
    case Games.session_id_from_topic(topic) do
      {:ok, session_id} -> announce(session_id, topic, diff, presences)
      :error -> :ok
    end

    {:ok, state}
  end

  # The monitor is told before the subscribers are: a screen woken by the diff
  # that goes on to read the room has to find the absence already recorded, not
  # a message still on its way.
  defp announce(session_id, topic, %{joins: joins, leaves: leaves}, presences) do
    if host_arrived?(joins), do: HostMonitor.host_connected(session_id)
    if host_gone?(leaves, presences), do: HostMonitor.host_disconnected(session_id)

    Phoenix.PubSub.local_broadcast(LiveQuiz.PubSub, topic, {:presence_changed, session_id})
  end

  defp host_arrived?(joins), do: Enum.any?(joins, fn {key, _presence} -> host_key?(key) end)

  # A single tab closing is not the host leaving: the key stays in `presences`
  # while any other connection still holds it.
  defp host_gone?(leaves, presences) do
    Enum.any?(leaves, fn {key, _presence} ->
      host_key?(key) and not Map.has_key?(presences, key)
    end)
  end

  defp presences(session_id), do: session_id |> Games.topic() |> list()

  defp meta(connection_id) do
    %{connection_id: connection_id, online_at: DateTime.utc_now()}
  end

  defp participant_key(%Participant{id: id}), do: "#{@participant_prefix}#{id}"

  defp host_key(%GameSession{host_id: host_id}), do: "#{@host_prefix}#{host_id}"

  defp host_key?(key), do: String.starts_with?(key, @host_prefix)

  defp participant_id(@participant_prefix <> id) do
    case Integer.parse(id) do
      {id, ""} -> [id]
      _not_an_id -> []
    end
  end

  defp participant_id(_key), do: []
end
