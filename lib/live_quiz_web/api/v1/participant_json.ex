defmodule LiveQuizWeb.Api.V1.ParticipantJSON do
  @moduledoc """
  Renders participations inside the `data` envelope of the API.

  Two shapes, and the difference between them is privacy. `data/1` is what a
  room says about somebody to everybody else in it — the nickname, whether they
  are connected and when they arrived — and it deliberately leaves the account
  out: taking part with an account is not a thing the other people in the lobby
  get to learn. `detail/1` adds `user_id` and is only ever used to answer
  somebody about their own participation.

  Neither shape carries the credential. It exists in clear exactly once, in the
  answer of the join endpoint, and this module has no way of putting it anywhere
  else.

  `connected` comes ready from whoever built the list: this module reads the
  virtual field and asks the presence for nothing.
  """

  alias LiveQuiz.Games.Participant

  @doc "Renders the lobby list of a room."
  def index(%{participants: participants}), do: %{data: Enum.map(participants, &data/1)}

  @doc "Renders one participation to the person it belongs to."
  def show(%{participant: %Participant{} = participant}), do: %{data: detail(participant)}

  @doc "What a participation shows to the other people in the room."
  @spec data(Participant.t()) :: map()
  def data(%Participant{} = participant) do
    %{
      id: participant.id,
      nickname: participant.nickname,
      connected: participant.connected,
      joined_at: participant.joined_at
    }
  end

  @doc "What a participation shows to the person who holds it."
  @spec detail(Participant.t()) :: map()
  def detail(%Participant{} = participant) do
    Map.put(data(participant), :user_id, participant.user_id)
  end
end
