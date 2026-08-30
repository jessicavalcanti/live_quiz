defmodule LiveQuizWeb.FormattersTest do
  use ExUnit.Case, async: true

  doctest LiveQuizWeb.Formatters

  alias LiveQuizWeb.Formatters

  describe "format_date/1" do
    test "converts a UTC timestamp to the São Paulo date" do
      assert Formatters.format_date(~U[2026-08-30 14:00:00Z]) == "30/08/2026"
    end

    test "rolls back to the previous day when 23h UTC is still yesterday in São Paulo" do
      assert Formatters.format_date(~U[2026-08-30 02:30:00Z]) == "29/08/2026"
    end

    test "pads day and month with a leading zero" do
      assert Formatters.format_date(~U[2026-01-05 12:00:00Z]) == "05/01/2026"
    end
  end

  describe "format_datetime/1" do
    test "converts date and time to São Paulo" do
      assert Formatters.format_datetime(~U[2026-08-29 22:32:00Z]) == "29/08/2026 19:32"
    end

    test "pads hour and minute with a leading zero" do
      assert Formatters.format_datetime(~U[2026-08-30 12:05:00Z]) == "30/08/2026 09:05"
    end
  end
end
