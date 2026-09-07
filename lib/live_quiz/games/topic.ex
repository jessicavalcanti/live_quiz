defmodule LiveQuiz.Games.Topic do
  @moduledoc """
  The single topic every event of a room travels on, and the two ways in.

  A room has one topic and not one per concern (AD-45): the lobby, the match and
  the ranking all publish on it, because the screens that care about one of them
  care about the others in the same breath, and a second topic would only be a
  second thing to subscribe to.

  It is a module of its own because publishing is the one thing every part of
  `LiveQuiz.Games` does — entering a room, advancing a question, scoring one,
  ending the match — and each of them would otherwise have to reach back into
  the context it was split out of.

  Everything is announced **after** the transaction that caused it has committed
  (AD-31): a subscriber woken by an event that goes on to read the database has
  to find what the event is about already there.
  """

  @topic_prefix "game_session:"

  @doc "The PubSub topic every event of a room is published on."
  @spec topic(integer()) :: String.t()
  def topic(session_id), do: "#{@topic_prefix}#{session_id}"

  @doc """
  Reads the room back out of a topic built by `topic/1`.

  Answers `:error` for anything else, so a presence diff on a topic this
  context did not build is ignored instead of crashing the tracker.
  """
  @spec session_id_from_topic(String.t()) :: {:ok, integer()} | :error
  def session_id_from_topic(@topic_prefix <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _not_an_id -> :error
    end
  end

  def session_id_from_topic(_topic), do: :error

  @doc """
  Subscribes the calling process to the events of a room.

  A LiveView calls it in the connected mount and nowhere else: subscribing in
  the disconnected mount would leave the static render holding a subscription
  no process is going to consume.
  """
  @spec subscribe(integer()) :: :ok | {:error, term()}
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(LiveQuiz.PubSub, topic(session_id))

  @doc """
  Publishes an event to everybody watching the room.

  Called only from inside `LiveQuiz.Games` and its submodules — nothing outside
  announces what a room did.
  """
  @spec broadcast(integer(), tuple()) :: :ok
  def broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(LiveQuiz.PubSub, topic(session_id), event)
  end
end
