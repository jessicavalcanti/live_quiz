defmodule LiveQuizWeb.VisualPolicyTest do
  @moduledoc """
  A regra de scripts inline, verificada em vez de só escrita (R42).

  O AGENTS.md dizia uma coisa e o repositório fazia outra, o que deixa o
  próximo agente sem regra que possa seguir estendendo o que já existe. A regra
  agora é: um bundle, hooks colocados, e **uma** exceção nomeada — o bootstrap
  de tema, que precisa rodar antes da primeira pintura. Este teste é o que
  impede uma segunda exceção de aparecer sem que ninguém decida.
  """

  use ExUnit.Case, async: true

  @root "lib/live_quiz_web/components/layouts/root.html.heex"

  # Um `<script>` com `src` é o bundle; um com `:type={Phoenix.LiveView.ColocatedHook}`
  # é um hook, que o mecanismo compila para dentro do bundle e que o próprio
  # review distingue de script inline de runtime.
  @inline_script ~r/<script(?![^>]*(?:src=|:type=))[^>]*>/

  test "o bootstrap de tema é o único script inline do projeto" do
    offenders =
      for template <- Path.wildcard("lib/**/*.heex"),
          template != @root,
          Regex.match?(@inline_script, File.read!(template)),
          do: template

    assert offenders == [],
           """
           Estes templates têm <script> inline, que a seção 8 do AGENTS.md proíbe:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Use um hook colocado (`:type={Phoenix.LiveView.ColocatedHook}`) ou o
           bundle. Se o script precisa mesmo rodar antes da primeira pintura,
           isso é uma decisão a tomar e a escrever no AGENTS.md — não uma
           exceção a criar em silêncio.
           """
  end

  test "o bootstrap de tema não toca em localStorage sem proteção" do
    body = theme_script()

    assert body =~ "localStorage", "o bootstrap de tema deixou de usar localStorage?"

    # Em janela privada, ou com dados de site bloqueados, o acesso *lança*. Sem
    # o `try`, a exceção derrubava a IIFE inteira: nenhum tema aplicado e nenhum
    # ouvinte registrado, então o botão de tema parava de funcionar em silêncio.
    refute unguarded(body) =~ "localStorage",
           "há um acesso a localStorage fora de um bloco try no bootstrap de tema"
  end

  # Só o corpo do script: o comentário acima dele fala sobre localStorage, e um
  # teste que lesse a prosa junto estaria medindo a explicação em vez do código.
  defp theme_script do
    [[_match, body]] = Regex.scan(~r/<script>(.*?)<\/script>/s, File.read!(@root))

    body
  end

  # O corpo sem os blocos `try`, que é onde os acessos têm de morar.
  defp unguarded(body) do
    String.replace(body, ~r/try \{.*?\} catch \(\w+\) \{[^}]*\}/s, "")
  end
end
