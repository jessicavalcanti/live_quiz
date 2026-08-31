defmodule LiveQuizWeb.ShareSessionTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LiveQuizWeb.ShareSession

  defp render_block(code) do
    render_component(&ShareSession.share_session/1,
      code: code,
      url: ShareSession.join_url(code)
    )
  end

  describe "join_url/1" do
    test "aponta para a tela pública de entrada, com o código" do
      assert ShareSession.join_url("K7P4Q2") ==
               "#{LiveQuizWeb.Endpoint.url()}/join?code=K7P4Q2"
    end

    test "normaliza o código" do
      assert ShareSession.join_url(" k7p4q2 ") =~ "code=K7P4Q2"
    end
  end

  describe "qr_code_svg/1" do
    test "gera SVG inline, sem prólogo XML e sem chamada externa" do
      svg =
        "https://exemplo.test/join?code=K7P4Q2" |> ShareSession.qr_code_svg() |> safe_to_string()

      assert String.starts_with?(svg, "<svg")
      refute svg =~ "<?xml"
      refute svg =~ "http://api."
      assert svg =~ "<rect"
    end

    test "reserva a quiet zone de 4 módulos ao redor do símbolo" do
      svg =
        "https://exemplo.test/join?code=K7P4Q2" |> ShareSession.qr_code_svg() |> safe_to_string()

      assert [_match, min_x, min_y, width, height] =
               Regex.run(~r/viewBox="(-?\d+) (-?\d+) (\d+) (\d+)"/, svg)

      assert min_x == "-4"
      assert min_y == "-4"
      assert String.to_integer(width) == String.to_integer(height)
      # O símbolo é o viewBox menos as duas margens de 4 módulos.
      assert String.to_integer(width) > 8
    end

    test "conteúdos diferentes geram símbolos diferentes" do
      one =
        "https://exemplo.test/join?code=K7P4Q2" |> ShareSession.qr_code_svg() |> safe_to_string()

      other =
        "https://exemplo.test/join?code=J9M3T5" |> ShareSession.qr_code_svg() |> safe_to_string()

      refute one == other
    end
  end

  describe "share_session/1" do
    test "mostra o código em destaque" do
      html = render_block("K7P4Q2")

      assert html =~ ~s(id="join-code")
      assert html =~ "K7P4Q2"
    end

    test "mostra o link de convite e o botão de copiar" do
      html = render_block("K7P4Q2")

      assert html =~ ShareSession.join_url("K7P4Q2")
      assert html =~ ~s(id="copy-link")
      assert html =~ ~s(id="copy-code")
      assert html =~ ~s(phx-click="copy_link")
      assert html =~ ~s(phx-click="copy_code")
    end

    test "o QR code é inline e aponta para a entrada da sala" do
      html = render_block("K7P4Q2")
      expected = "K7P4Q2" |> ShareSession.join_url() |> ShareSession.qr_code_svg()

      assert html =~ ~s(id="join-qr-code")
      assert html =~ safe_to_string(expected)
    end

    test "o QR code tem texto alternativo dizendo o que ele é" do
      html = render_block("K7P4Q2")

      assert html =~ ~s(role="img")
      assert html =~ "QR code com o link de entrada da sala K7P4Q2"
    end

    test "o quadro branco em volta do QR code sobrevive ao tema escuro" do
      html = render_block("K7P4Q2")

      assert html =~ "bg-white"
    end
  end

  defp safe_to_string(safe), do: Phoenix.HTML.safe_to_string(safe)
end
