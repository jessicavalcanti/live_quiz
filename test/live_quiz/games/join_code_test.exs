defmodule LiveQuiz.Games.JoinCodeTest do
  use ExUnit.Case, async: true

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode

  doctest LiveQuiz.Games.JoinCode

  @alphabet MapSet.new(String.graphemes(GameSession.join_code_alphabet()))

  describe "generate/0" do
    test "produz seis caracteres do alfabeto permitido em mil execuções" do
      for _attempt <- 1..1_000 do
        code = JoinCode.generate()

        assert String.length(code) == GameSession.join_code_length()
        assert MapSet.subset?(MapSet.new(String.graphemes(code)), @alphabet)
      end
    end

    test "nunca produz os caracteres confundíveis O, 0, I e 1" do
      codes = Enum.map_join(1..1_000, fn _attempt -> JoinCode.generate() end)

      refute String.contains?(codes, ["O", "0", "I", "1"])
    end

    test "não repete códigos em dez mil execuções" do
      codes = Enum.map(1..10_000, fn _attempt -> JoinCode.generate() end)

      # Sanity check of the generator, not a statistical guarantee: in a space of
      # 32⁶ codes the birthday bound puts one repeat in 10.000 draws at roughly
      # 4,6%, so a single collision is expected noise and two is a red flag.
      assert codes |> MapSet.new() |> MapSet.size() >= 9_999
    end
  end

  describe "normalize/1" do
    test "remove espaços das pontas e aplica upcase" do
      assert JoinCode.normalize(" k7p4q2 ") == "K7P4Q2"
    end

    test "devolve um código já normalizado inalterado" do
      assert JoinCode.normalize("K7P4Q2") == "K7P4Q2"
    end

    test "devolve string vazia para uma entrada vazia" do
      assert JoinCode.normalize("") == ""
      assert JoinCode.normalize("   ") == ""
    end
  end

  describe "valid_format?/1" do
    test "aceita um código de seis caracteres do alfabeto" do
      assert JoinCode.valid_format?("K7P4Q2")
      assert JoinCode.valid_format?("23456789ABCDEFGHJKLMNPQRSTUVWXYZ" |> String.slice(0, 6))
    end

    test "rejeita tamanho diferente de seis" do
      refute JoinCode.valid_format?("")
      refute JoinCode.valid_format?("K7P4Q")
      refute JoinCode.valid_format?("K7P4Q22")
    end

    test "rejeita caracteres fora do alfabeto" do
      refute JoinCode.valid_format?("K7P4Q0")
      refute JoinCode.valid_format?("K7P4QO")
      refute JoinCode.valid_format?("K7P4QI")
      refute JoinCode.valid_format?("K7P4Q1")
      refute JoinCode.valid_format?("K7P4Q-")
    end

    test "rejeita um código em minúsculas, que precisa ser normalizado antes" do
      refute JoinCode.valid_format?("k7p4q2")
    end

    test "rejeita valores que não são texto" do
      refute JoinCode.valid_format?(nil)
      refute JoinCode.valid_format?(123_456)
    end
  end

  describe "max_attempts/0" do
    test "expõe o limite de tentativas do retry de colisão" do
      assert JoinCode.max_attempts() == 5
    end
  end
end
