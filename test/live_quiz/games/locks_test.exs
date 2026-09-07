defmodule LiveQuiz.Games.LocksTest do
  @moduledoc """
  The key an advisory lock is taken on.

  Regression for R45 of the review. The two-argument form of
  `pg_advisory_xact_lock` takes two `int4`, and the ids of this application are
  `bigint`. Past `2_147_483_647` the id is simply not representable there — the
  call would fail, on the busiest table, long after anybody was still thinking
  about advisory locks.
  """

  use LiveQuiz.DataCase, async: true

  alias LiveQuiz.Games.Locks

  describe "a chave" do
    test "distingue as classes para o mesmo id" do
      keys = Enum.map(1..3, &Locks.key(&1, 42))

      assert length(Enum.uniq(keys)) == 3
    end

    test "distingue os ids dentro de uma classe" do
      assert Locks.key(1, 1) != Locks.key(1, 2)
    end

    test "é exata, não um hash: dois assuntos nunca colidem" do
      # A classe ocupa os bits altos e o id os baixos, então a chave é a
      # concatenação dos dois — não há função de dispersão para colidir.
      assert Locks.key(2, 7) - Locks.key(1, 7) == Locks.key(1, 0) - Locks.key(0, 0)
    end

    test "cabe num bigint com folga no maior id aceito" do
      assert Locks.key(3, Locks.max_id()) < 9_223_372_036_854_775_807
    end
  end

  describe "o intervalo de ids" do
    test "vai muito além do que um bigserial alcança" do
      # 2^56. Um `bigserial` precisaria de uma linha por microssegundo durante
      # dois mil anos para chegar aqui.
      assert Locks.max_id() == 72_057_594_037_927_935
      assert Locks.max_id() > 2_147_483_647
    end
  end

  describe "tomar o lock" do
    test "funciona com um id maior que um int4, que era o defeito" do
      big = 2_147_483_648

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 assert Locks.identity(big) == :ok
                 assert Locks.seats(big) == :ok

                 Locks.match(big)
               end)
    end

    test "funciona no maior id aceito" do
      assert Repo.transaction(fn -> Locks.match(Locks.max_id()) end) == {:ok, :ok}
    end

    test "recusa um id fora do intervalo dizendo o que houve" do
      for id <- [0, -1, Locks.max_id() + 1] do
        assert_raise ArgumentError, ~r/cannot be locked/, fn ->
          Repo.transaction(fn -> Locks.match(id) end)
        end
      end
    end

    test "room/1 toma os dois locks da sala" do
      assert Repo.transaction(fn -> Locks.room(2_147_483_649) end) == {:ok, :ok}
    end
  end
end
