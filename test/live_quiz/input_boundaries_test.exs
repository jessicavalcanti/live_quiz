defmodule LiveQuiz.InputBoundariesTest do
  @moduledoc """
  What the edge accepts, and what it refuses without reaching the database.

  Regressions for R30 of the review. Ids and pagination arrive from paths and
  query strings, where everything is a string and anything can be typed. The
  question each of these answers is which of "that is not a resource" and "that
  is not a filter" the value deserves — and neither answer is a crash.
  """

  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.ResultFilters
  alias LiveQuiz.Pagination
  alias LiveQuiz.Quizzes
  alias LiveQuiz.ResourceId

  describe "ResourceId.cast/1" do
    test "accepts an integer and its string form" do
      assert ResourceId.cast(7) == {:ok, 7}
      assert ResourceId.cast("7") == {:ok, 7}
    end

    test "accepts the widest id a bigserial can hold" do
      assert ResourceId.cast(ResourceId.max()) == {:ok, ResourceId.max()}
      assert ResourceId.cast(to_string(ResourceId.max())) == {:ok, ResourceId.max()}
    end

    test "refuses anything no row could ever be" do
      for value <- [0, -1, "0", "-1", "1.5", "1abc", "abc", "", nil, ["1"], %{"a" => 1}] do
        assert ResourceId.cast(value) == :error, "#{inspect(value)} was accepted as an id"
      end
    end

    test "refuses a number wider than a bigint" do
      assert ResourceId.cast(ResourceId.max() + 1) == :error
      assert ResourceId.cast(to_string(ResourceId.max() + 1)) == :error
      assert ResourceId.cast(String.duplicate("9", 40)) == :error
    end
  end

  describe "reading a quiz by an impossible id" do
    setup :owner

    test "answers the same missing resource a stranger's quiz answers", %{scope: scope} do
      for id <- ["abc", "1.5", "-3", "0", String.duplicate("9", 40)] do
        assert_raise Ecto.NoResultsError, fn -> Quizzes.get_quiz!(scope, id) end
      end
    end

    test "still reads a quiz named by the string form of its id", %{scope: scope} do
      quiz = quiz_fixture(scope)

      assert Quizzes.get_quiz!(scope, to_string(quiz.id)).id == quiz.id
    end
  end

  describe "pagination" do
    test "refuses a page nobody could ever reach" do
      assert Pagination.parse(%{"page" => to_string(Pagination.max_page() + 1)}) ==
               {:error, :invalid_filter}

      assert Pagination.parse(%{"page" => String.duplicate("9", 40)}) ==
               {:error, :invalid_filter}
    end

    test "accepts the last page it offers" do
      assert {:ok, %{page: page}} = Pagination.parse(%{"page" => Pagination.max_page()})
      assert page == Pagination.max_page()
    end

    test "the multiplication that becomes an OFFSET stays inside a bigint" do
      assert {:ok, %{page: page, per_page: per_page}} =
               Pagination.parse(%{
                 "page" => Pagination.max_page(),
                 "per_page" => Pagination.max_per_page()
               })

      assert page * per_page < ResourceId.max()
    end

    test "a screen falls back instead of failing on the same value" do
      assert Pagination.normalize(%{"page" => String.duplicate("9", 40)}) == %{
               page: Pagination.default_page(),
               per_page: Pagination.default_per_page()
             }
    end

    test "a list or a map where a number belongs is refused, not crashed" do
      for value <- [["1"], %{"a" => "1"}, true] do
        assert Pagination.parse(%{"page" => value}) == {:error, :invalid_filter}
        assert Pagination.parse(%{"per_page" => value}) == {:error, :invalid_filter}
      end
    end
  end

  describe "result filters" do
    test "an identifier wider than a bigint is an invalid filter, not a lookup" do
      assert ResultFilters.parse(%{"quiz_id" => String.duplicate("9", 40)}) ==
               {:error, :invalid_filter}

      assert ResultFilters.required_quiz_id(String.duplicate("9", 40)) ==
               {:error, :invalid_filter}
    end

    test "a list or a map where an identifier belongs is refused" do
      for value <- [["1"], %{"a" => "1"}] do
        assert ResultFilters.parse(%{"quiz_id" => value}) == {:error, :invalid_filter}
        assert ResultFilters.parse(%{"from" => value}) == {:error, :invalid_filter}
        assert ResultFilters.parse(%{"to" => value}) == {:error, :invalid_filter}
      end
    end

    test "a screen drops the unusable filter instead of failing" do
      assert ResultFilters.normalize(%{"quiz_id" => String.duplicate("9", 40)}).quiz_id == nil
    end

    test "still reads an identifier that is one" do
      assert ResultFilters.parse(%{"quiz_id" => "7"}) == {:ok, %{quiz_id: 7, from: nil, to: nil}}
    end
  end

  defp owner(_context), do: %{scope: user_scope_fixture()}
end
