defmodule LiveQuiz.Games.ParticipantTokenTest do
  use ExUnit.Case, async: true

  doctest LiveQuiz.Games.ParticipantToken

  alias LiveQuiz.Games.ParticipantToken

  describe "build/0" do
    test "devolve o token em claro e o resumo que vai para o banco" do
      {token, hash} = ParticipantToken.build()

      assert is_binary(token)
      assert byte_size(hash) == 32
      assert ParticipantToken.hash(token) == {:ok, hash}
    end

    test "o token em claro é Base64 URL-safe sem preenchimento" do
      {token, _hash} = ParticipantToken.build()

      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, token)
      refute String.contains?(token, "=")
      assert {:ok, bytes} = Base.url_decode64(token, padding: false)
      assert byte_size(bytes) == ParticipantToken.rand_size()
    end

    test "duas gerações seguidas não colidem" do
      {first_token, first_hash} = ParticipantToken.build()
      {second_token, second_hash} = ParticipantToken.build()

      assert first_token != second_token
      assert first_hash != second_hash
    end

    test "cem gerações produzem cem tokens distintos" do
      tokens = for _index <- 1..100, do: elem(ParticipantToken.build(), 0)

      assert tokens |> MapSet.new() |> MapSet.size() == 100
    end
  end

  describe "hash/1" do
    test "é determinístico para o mesmo token" do
      {token, _hash} = ParticipantToken.build()

      assert ParticipantToken.hash(token) == ParticipantToken.hash(token)
    end

    test "devolve :error para texto que não é Base64 válido" do
      assert ParticipantToken.hash("não é base64!") == :error
      assert ParticipantToken.hash("****") == :error
    end

    test "devolve :error para Base64 válido com o número errado de bytes" do
      assert ParticipantToken.hash(Base.url_encode64("curto", padding: false)) == :error

      assert ParticipantToken.hash(
               Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)
             ) == :error
    end

    test "devolve :error para uma string vazia" do
      assert ParticipantToken.hash("") == :error
    end

    test "devolve :error para valores que não são texto" do
      assert ParticipantToken.hash(nil) == :error
      assert ParticipantToken.hash(123) == :error
    end
  end
end
