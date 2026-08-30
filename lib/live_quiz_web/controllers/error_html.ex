defmodule LiveQuizWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use LiveQuizWeb, :html

  # Pages living in the error_html directory take over the default rendering.
  # Everything else falls back to a plain text status message.
  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "500.html" becomes
  # "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
