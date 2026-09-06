defmodule LiveQuizWeb.Api.ErrorJSON do
  @moduledoc """
  Renders the error envelope shared by every endpoint of the JSON API.

  Every error answers with `%{errors: ...}`: a `detail` string for the errors
  that do not belong to a field, and a map of `field => messages` for changeset
  errors.
  """

  @unauthorized "Não autenticado"
  @not_found "Não encontrado"

  @doc """
  Renders an error of the API.

    * `"error.json"` — a single human readable message, given in `:detail`;
    * `"changeset.json"` — the field errors of an invalid changeset, already
      translated to pt-BR;
    * `"<status>.json"` — the standard message of that status.

  """
  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  def render("changeset.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  def render("401.json", _assigns), do: %{errors: %{detail: @unauthorized}}
  def render("404.json", _assigns), do: %{errors: %{detail: @not_found}}

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end

  defdelegate translate_error(error), to: LiveQuizWeb.CoreComponents
end
