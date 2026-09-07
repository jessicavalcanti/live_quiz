defmodule LiveQuizWeb.Api.ErrorJSON do
  @moduledoc """
  Renders the error envelope shared by every endpoint of the JSON API.

  Every error answers with `%{errors: ...}`: a `detail` string for the errors
  that do not belong to a field, and a map of `field => messages` for changeset
  errors.
  """

  @unauthorized "Não autenticado"
  @not_found "Não encontrado"
  @too_many_requests "Muitas tentativas. Tente novamente em instantes."

  @doc """
  Renders an error of the API.

    * `"error.json"` — a single human readable message, given in `:detail`, and
      the stable `:code` of the refusal when it has one;
    * `"changeset.json"` — the field errors of an invalid changeset, already
      translated to pt-BR;
    * `"429.json"` — a budget spent, carrying the `rate_limited` code because a
      client is expected to act on it: wait out the `Retry-After` and retry;
    * `"<status>.json"` — the standard message of that status.

  The message is written for a person and is free to change; the code is written
  for a client and is not. Renaming one would break whoever branches on it, so
  the refusals that carry a code are the ones a client is expected to act on —
  reconsult the state, correct the payload — and never a decoration on every
  error the API can produce.
  """
  def render("error.json", %{detail: detail, code: code}) do
    %{errors: %{detail: detail, code: code}}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  def render("changeset.json", %{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  def render("401.json", _assigns), do: %{errors: %{detail: @unauthorized}}
  def render("404.json", _assigns), do: %{errors: %{detail: @not_found}}

  def render("429.json", _assigns),
    do: %{errors: %{detail: @too_many_requests, code: "rate_limited"}}

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end

  defdelegate translate_error(error), to: LiveQuizWeb.CoreComponents
end
