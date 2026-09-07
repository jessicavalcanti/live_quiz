defmodule LiveQuiz.Games.ResultFiltersTest do
  use ExUnit.Case, async: true

  alias LiveQuiz.Games.ResultFilters

  describe "parse/1 dates" do
    test "a bare date is the whole day, opened by from and closed by to" do
      assert {:ok, filters} = ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"})

      assert filters.from == ~U[2026-09-06 00:00:00.000000Z]
      assert filters.to == ~U[2026-09-06 23:59:59.999999Z]
    end

    test "from=X&to=X contains every instant of X" do
      assert {:ok, %{from: from, to: to}} =
               ResultFilters.parse(%{"from" => "2026-09-06", "to" => "2026-09-06"})

      for instant <- [
            ~U[2026-09-06 00:00:00Z],
            ~U[2026-09-06 12:30:00Z],
            ~U[2026-09-06 23:59:59Z]
          ] do
        assert DateTime.compare(instant, from) != :lt
        assert DateTime.compare(instant, to) != :gt
      end
    end

    test "a full instant is taken as given" do
      assert {:ok, %{to: ~U[2026-09-06 10:00:00Z]}} =
               ResultFilters.parse(%{"to" => "2026-09-06T10:00:00Z"})
    end

    test "a DateTime passes through untouched" do
      assert {:ok, %{from: ~U[2026-09-06 10:00:00Z]}} =
               ResultFilters.parse(%{from: ~U[2026-09-06 10:00:00Z]})
    end

    test "refuses what is not a date" do
      assert ResultFilters.parse(%{"from" => "ontem"}) == {:error, :invalid_filter}
      assert ResultFilters.parse(%{"to" => "2026-13-45"}) == {:error, :invalid_filter}
    end
  end

  describe "parse/1 quiz_id" do
    test "reads an identifier from an integer or a numeric string" do
      assert {:ok, %{quiz_id: 7}} = ResultFilters.parse(%{"quiz_id" => "7"})
      assert {:ok, %{quiz_id: 7}} = ResultFilters.parse(%{quiz_id: 7})
    end

    test "a blank is no filter at all, never an empty string reaching the database" do
      assert {:ok, %{quiz_id: nil}} = ResultFilters.parse(%{"quiz_id" => ""})
      assert {:ok, %{quiz_id: nil}} = ResultFilters.parse(%{})
    end

    test "refuses what is not an identifier" do
      for value <- ["abc", "0", "-1", "1.5"] do
        assert ResultFilters.parse(%{"quiz_id" => value}) == {:error, :invalid_filter}, value
      end
    end
  end

  describe "required_quiz_id/1" do
    test "reads an identifier the same way the filter does" do
      assert ResultFilters.required_quiz_id("7") == {:ok, 7}
      assert ResultFilters.required_quiz_id(7) == {:ok, 7}
    end

    test "refuses a blank, which the filter would have accepted" do
      assert {:ok, %{quiz_id: nil}} = ResultFilters.parse(%{"quiz_id" => ""})
      assert ResultFilters.required_quiz_id("") == {:error, :invalid_filter}
      assert ResultFilters.required_quiz_id(nil) == {:error, :invalid_filter}
    end
  end

  describe "normalize/1" do
    test "agrees with parse/1 on everything it accepts" do
      params = %{"quiz_id" => "7", "from" => "2026-09-01", "to" => "2026-09-30"}
      assert {:ok, parsed} = ResultFilters.parse(params)
      assert ResultFilters.normalize(params) == parsed
    end

    test "drops only the value it cannot read, keeping the others" do
      assert ResultFilters.normalize(%{"quiz_id" => "abc", "from" => "2026-09-01"}) ==
               %{quiz_id: nil, from: ~U[2026-09-01 00:00:00.000000Z], to: nil}
    end

    test "an empty filter selects everything" do
      assert ResultFilters.normalize(%{}) == ResultFilters.empty()
    end
  end
end
