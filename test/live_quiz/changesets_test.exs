defmodule LiveQuiz.ChangesetsTest do
  use ExUnit.Case, async: true

  alias LiveQuiz.Changesets

  describe "trim/1" do
    test "removes the whitespace around a string" do
      assert Changesets.trim("  Capitais  ") == "Capitais"
      assert Changesets.trim("\n\tCapitais\n") == "Capitais"
    end

    test "leaves anything that is not a string alone" do
      assert Changesets.trim(nil) == nil
      assert Changesets.trim(42) == 42
    end
  end

  describe "upcase/1" do
    test "trims and upcases, which is how a join code is stored" do
      assert Changesets.upcase(" 4n8322 ") == "4N8322"
    end

    test "leaves anything that is not a string alone" do
      assert Changesets.upcase(nil) == nil
    end
  end
end
