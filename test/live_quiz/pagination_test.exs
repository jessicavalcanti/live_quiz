defmodule LiveQuiz.PaginationTest do
  use ExUnit.Case, async: true

  alias LiveQuiz.Pagination

  describe "parse/2" do
    test "an absent or blank value is the default, not a refusal" do
      assert Pagination.parse(%{}) == {:ok, %{page: 1, per_page: 20}}

      assert Pagination.parse(%{"page" => "", "per_page" => ""}) ==
               {:ok, %{page: 1, per_page: 20}}

      assert Pagination.parse(page: nil, per_page: nil) == {:ok, %{page: 1, per_page: 20}}
    end

    test "reads string and atom keys, and integers and numeric strings alike" do
      assert Pagination.parse(%{"page" => "3", "per_page" => "50"}) ==
               {:ok, %{page: 3, per_page: 50}}

      assert Pagination.parse(%{page: 3, per_page: 50}) == {:ok, %{page: 3, per_page: 50}}
      assert Pagination.parse(page: "3", per_page: 50) == {:ok, %{page: 3, per_page: 50}}
    end

    test "refuses anything that is not a page somebody could have" do
      for params <- [
            %{"page" => "abc"},
            %{"page" => "0"},
            %{"page" => "-1"},
            %{"page" => "1.5"},
            %{"per_page" => "abc"},
            %{"per_page" => "0"},
            %{"per_page" => "-3"}
          ] do
        assert Pagination.parse(params) == {:error, :invalid_filter}, inspect(params)
      end
    end

    test "refuses a page larger than the ceiling" do
      assert Pagination.parse(%{"per_page" => "100"}) == {:ok, %{page: 1, per_page: 100}}
      assert Pagination.parse(%{"per_page" => "101"}) == {:error, :invalid_filter}
    end

    test "a listing may name its own default size" do
      assert Pagination.parse(%{}, per_page: 10) == {:ok, %{page: 1, per_page: 10}}

      assert Pagination.parse(%{"per_page" => "5"}, per_page: 10) ==
               {:ok, %{page: 1, per_page: 5}}
    end
  end

  describe "normalize/2" do
    test "agrees with parse/2 on everything it accepts" do
      for params <- [%{}, %{"page" => "3"}, %{"per_page" => "50"}, %{page: 2, per_page: 100}] do
        assert {:ok, parsed} = Pagination.parse(params)
        assert Pagination.normalize(params) == parsed
      end
    end

    test "falls back per value instead of refusing" do
      assert Pagination.normalize(%{"page" => "abc", "per_page" => "50"}) ==
               %{page: 1, per_page: 50}

      assert Pagination.normalize(%{"page" => "3", "per_page" => "101"}) ==
               %{page: 3, per_page: 20}

      assert Pagination.normalize(%{"page" => "abc", "per_page" => "abc"}) ==
               %{page: 1, per_page: 20}
    end

    test "keeps the listing's own default when the value is unusable" do
      assert Pagination.normalize(%{"per_page" => "abc"}, per_page: 10) ==
               %{page: 1, per_page: 10}
    end
  end
end
