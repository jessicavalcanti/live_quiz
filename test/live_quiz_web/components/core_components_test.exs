defmodule LiveQuizWeb.CoreComponentsTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LiveQuizWeb.CoreComponents

  test "back button renders its destination, label, and accessible icon" do
    html =
      render_component(&CoreComponents.back_button/1,
        id: "back-to-quizzes",
        navigate: "/quizzes",
        label: "Voltar para Meus quizzes"
      )

    assert html =~ ~s(id="back-to-quizzes")
    assert html =~ ~s(href="/quizzes")
    assert html =~ "Voltar para Meus quizzes"
    assert html =~ "hero-arrow-left"
  end

  test "flash renders an auto-hide duration and progress bar" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :info,
        flash: %{"info" => "Alterações salvas"}
      )

    assert html =~ ~s(data-auto-hide-ms="7000")
    assert html =~ "data-flash-progress"
    assert html =~ ~s(phx-hook="LiveQuizWeb.CoreComponents.FlashTimer")
    refute html =~ ~s(phx-hook=".FlashTimer")
  end

  test "flash can remain visible without a timer" do
    html =
      render_component(&CoreComponents.flash/1,
        id: "connection-error",
        kind: :error,
        flash: %{"error" => "Reconectando"},
        auto_hide: false
      )

    refute html =~ "data-auto-hide-ms"
    refute html =~ "data-flash-progress"
  end
end
