defmodule LiveQuiz.Games.ResultFiltersZoneTest do
  @moduledoc """
  Whose day a date filter means.

  Regression for R39 of the review. A day only means something in a time zone,
  and the two callers do not share one: the API documents UTC, the screens show
  São Paulo. A match played at `01:00Z` on the 7th appears under the 6th on
  screen, and asking for the 6th used to leave it out — the filter closed the
  6th at `23:59:59Z`, an hour before that match happened.
  """

  use ExUnit.Case, async: true

  alias LiveQuiz.Games.ResultFilters

  @screen "America/Sao_Paulo"
  # 07/09 às 01:00 UTC é 06/09 às 22:00 em São Paulo: a partida que a tela
  # mostra no dia 6 e o filtro do dia 6 precisa encontrar.
  @late_night ~U[2026-09-07 01:00:00Z]

  describe "um dia lido no fuso da tela" do
    test "inclui a partida que a tela mostra naquele dia" do
      {:ok, %{from: from, to: to}} =
        ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"},
          time_zone: @screen
        )

      assert DateTime.compare(@late_night, from) in [:gt, :eq]
      assert DateTime.compare(@late_night, to) in [:lt, :eq]
    end

    test "abre e fecha nos instantes UTC que correspondem ao dia local" do
      {:ok, %{from: from, to: to}} =
        ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"},
          time_zone: @screen
        )

      # São Paulo é UTC-3: o dia 6 local vai das 03:00Z do dia 6 às 02:59:59Z
      # do dia 7.
      assert from == ~U[2026-09-06 03:00:00.000000Z]
      assert to == ~U[2026-09-07 02:59:59.999999Z]
    end

    test "o que chega à consulta continua sendo UTC" do
      {:ok, %{from: from, to: to}} =
        ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"},
          time_zone: @screen
        )

      assert from.time_zone == "Etc/UTC"
      assert to.time_zone == "Etc/UTC"
    end
  end

  describe "o mesmo dia lido em UTC" do
    test "deixa de fora a partida que a tela mostra naquele dia" do
      {:ok, %{to: to}} = ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"})

      # É o contrato documentado da API, e é por isso que ele não muda: quem
      # pede UTC recebe UTC.
      assert to == ~U[2026-09-06 23:59:59.999999Z]
      assert DateTime.compare(@late_night, to) == :gt
    end

    test "é o padrão quando ninguém diz o fuso" do
      assert ResultFilters.parse(%{"from" => "2026-09-06"}) ==
               ResultFilters.parse(%{"from" => "2026-09-06"}, time_zone: "Etc/UTC")
    end
  end

  describe "um instante completo" do
    test "é tomado como está, em qualquer dos dois fusos" do
      params = %{"from" => "2026-09-06T12:00:00Z"}

      assert ResultFilters.parse(params) ==
               ResultFilters.parse(params, time_zone: @screen)
    end
  end

  describe "normalize/2" do
    test "aceita o fuso e continua descartando o que não dá para ler" do
      filters =
        ResultFilters.normalize(%{"from" => "2026-09-06", "to" => "nao-e-data"},
          time_zone: @screen
        )

      assert filters.from == ~U[2026-09-06 03:00:00.000000Z]
      assert filters.to == nil
    end
  end

  describe "o fuso da tela" do
    test "é declarado uma vez, e é o que os formatadores usam" do
      assert ResultFilters.screen_time_zone() == @screen

      # A mesma conversão que a tela faz ao exibir a data.
      assert LiveQuizWeb.Formatters.format_date(@late_night) == "06/09/2026"
    end
  end
end
