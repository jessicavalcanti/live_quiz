defmodule LiveQuizWeb.ErrorHTMLTest do
  use LiveQuizWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a friendly 404.html in pt-BR" do
    html = render_to_string(LiveQuizWeb.ErrorHTML, "404", "html", [])

    assert html =~ ~s(lang="pt-BR")
    assert html =~ "Página não encontrada"
    assert html =~ "O endereço que você acessou não existe ou foi movido."
    assert html =~ "Voltar para a página inicial"
  end

  test "renders 500.html" do
    assert render_to_string(LiveQuizWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end

  test "answers unknown routes with the 404 page", %{conn: conn} do
    conn = get(conn, "/pagina-que-nao-existe")

    assert html_response(conn, 404) =~ "Página não encontrada"
  end
end
