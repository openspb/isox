defmodule Isox.Xml.CharsetTest do
  use ExUnit.Case, async: true

  alias Isox.Xml.Charset

  describe "check/1" do
    test "aceita a faixa do catálogo inteira" do
      allowed =
        [0x09, 0x0A, 0x0D, 0x85] ++ Enum.to_list(0x20..0x7E) ++ Enum.to_list(0xA0..0xFF)

      assert Charset.check(List.to_string(allowed)) == :ok
      assert Charset.check("Pagamento de São João, R$ 10,00 ©") == :ok
    end

    test "recusa controles C0 que não sejam tab, LF e CR" do
      for c <- Enum.to_list(0x00..0x08) ++ [0x0B, 0x0C] ++ Enum.to_list(0x0E..0x1F) ++ [0x7F] do
        assert {:error, 1, ^c} = Charset.check("a" <> <<c::utf8>>)
      end
    end

    test "recusa controles C1, exceto #x85" do
      for c <- Enum.to_list(0x80..0x84) ++ Enum.to_list(0x86..0x9F) do
        assert {:error, 0, ^c} = Charset.check(<<c::utf8>>)
      end
    end

    test "recusa o que está acima de Latin-1, com a posição em bytes" do
      assert {:error, 6, 0x20AC} = Charset.check("ação€")
      assert {:error, 0, 0x1F600} = Charset.check("😀")
    end

    test "recusa UTF-8 malformado" do
      assert {:error, 2, :invalid_utf8} = Charset.check("ab" <> <<0xC3>>)
      assert {:error, 0, :invalid_utf8} = Charset.check(<<0xE9>>)
    end
  end

  describe "strip_framing/1" do
    test "tira o BOM UTF-8 do início e o padding de #x0000 do fim" do
      assert Charset.strip_framing(<<0xEF, 0xBB, 0xBF>> <> "<a/>" <> <<0, 0, 0>>) == "<a/>"
      assert Charset.strip_framing("<a/>") == "<a/>"
    end

    test "não tira zero que não esteja no fim" do
      assert Charset.strip_framing("<a>" <> <<0>> <> "</a>") == "<a>" <> <<0>> <> "</a>"
    end
  end

  describe "locate/2" do
    test "devolve o caminho dos elementos abertos até a posição" do
      xml = ~s(<?xml version="1.0"?><A><B>ok</B><C/><D><E>x€</E></D></A>)
      {:error, offset, _} = Charset.check(xml)
      assert Charset.locate(xml, offset) == "A/D/E"
    end

    test "marca quando a posição cai dentro de um atributo" do
      xml = ~s(<A><Amt Ccy="B€L">1</Amt></A>)
      {:error, offset, _} = Charset.check(xml)
      assert Charset.locate(xml, offset) == "A/Amt (atributo)"
    end
  end

  describe "find_in_term/2" do
    test "acha o primeiro valor inválido, com índice de lista e atributo" do
      term = %{"A" => %{"B" => ["ok", "x€"]}}
      assert Charset.find_in_term(term) == {"A/B[1]", 0x20AC}

      term = %{"Amt" => %{value: "1", attributes: %{"Ccy" => "B€L"}}}
      assert Charset.find_in_term(term) == {"Amt/@Ccy", 0x20AC}
    end

    test "nil quando está tudo certo, e respeita o skip?" do
      assert Charset.find_in_term(%{"A" => "ok", "N" => 10}) == nil
      assert Charset.find_in_term(%{"A" => "€"}, &(&1 == "€")) == nil
    end
  end
end
