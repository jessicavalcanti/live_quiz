defmodule LiveQuizWeb.Api.V1.SessionJSON do
  @moduledoc """
  Renders the session payloads inside the `data` envelope of the API.
  """

  alias LiveQuiz.Accounts.User

  @doc """
  Renders the pair of tokens issued at login, alongside the basic user data.
  """
  def create(%{tokens: tokens, user: %User{} = user}) do
    %{data: Map.put(tokens, :user, basic_user(user))}
  end

  @doc """
  Renders the access token issued by a refresh.
  """
  def refresh(%{tokens: tokens}), do: %{data: tokens}

  @doc """
  Renders the authenticated user.
  """
  def me(%{user: %User{} = user}) do
    %{data: Map.put(basic_user(user), :confirmed, not is_nil(user.confirmed_at))}
  end

  defp basic_user(%User{} = user) do
    %{id: user.id, name: user.name, email: user.email}
  end
end
