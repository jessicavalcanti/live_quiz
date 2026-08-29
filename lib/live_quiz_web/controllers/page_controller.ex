defmodule LiveQuizWeb.PageController do
  use LiveQuizWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
