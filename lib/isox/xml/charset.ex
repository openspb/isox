defmodule Isox.Xml.Charset do
  # Conjunto de caracteres aceito pelo catálogo do BCB (seção "Codificação
  # das Mensagens"): UTF-8, restrito a Basic Latin e Latin-1 Supplement
  # sem os controles C0 e C1, exceto tab, LF, CR e NEL (#x85):
  #
  #   #x09 | #x0A | #x0D | [#x20-#x7E] | #x85 | [#xA0-#xFF]
  #
  # O xmerl só aplica a regra do XML 1.0, que aceita bem mais que isso
  # (C1, U+20AC, emoji), então a restrição do catálogo precisa morar aqui.
  #
  # A checagem roda uma vez sobre o documento inteiro, no caminho feliz.
  # Achar o campo culpado é mais caro e só acontece quando ela falha.
  @moduledoc false

  @bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Prepara o XML recebido para o parser: tira o BOM UTF-8 do início, se
  houver, e o padding de `#x0000` do fim.
  """
  @spec strip_framing(binary()) :: binary()
  def strip_framing(@bom <> rest), do: strip_padding(rest)
  def strip_framing(xml), do: strip_padding(xml)

  defp strip_padding(xml), do: String.trim_trailing(xml, <<0>>)

  @doc """
  Confere se todo o binário é UTF-8 válido e só tem caracteres do catálogo.
  No erro, devolve a posição em bytes e o caractere (ou `:invalid_utf8`).
  """
  @spec check(binary()) :: :ok | {:error, non_neg_integer(), char() | :invalid_utf8}
  def check(binary) when is_binary(binary), do: check(binary, 0)

  defp check(<<>>, _offset), do: :ok

  defp check(<<c, rest::binary>>, offset) when c in 0x20..0x7E or c in [0x09, 0x0A, 0x0D],
    do: check(rest, offset + 1)

  defp check(<<c::utf8, rest::binary>>, offset) when c == 0x85 or c in 0xA0..0xFF,
    do: check(rest, offset + 2)

  defp check(<<c::utf8, _rest::binary>>, offset), do: {:error, offset, c}
  defp check(_invalid, offset), do: {:error, offset, :invalid_utf8}

  @doc "Atalho booleano de `check/1`, para a busca do campo culpado."
  @spec valid?(binary()) :: boolean()
  def valid?(binary), do: check(binary) == :ok

  @doc "Descreve o caractere inválido para a mensagem de erro."
  @spec describe(char() | :invalid_utf8) :: String.t()
  def describe(:invalid_utf8), do: "sequência UTF-8 inválida"

  def describe(c) do
    code = c |> Integer.to_string(16) |> String.pad_leading(4, "0")
    "caractere U+#{code} fora do conjunto aceito pelo catálogo"
  end

  @doc """
  Caminho do elemento (ex. `Envelope/Document/RmtInf/Ustrd`) que contém a
  posição `offset` do XML, a partir das tags abertas antes dela. Quando a
  posição cai dentro de uma tag de abertura, o caminho termina nessa tag e
  ganha o sufixo `(atributo)`.
  """
  @spec locate(binary(), non_neg_integer()) :: String.t()
  def locate(xml, offset) do
    prefix = binary_part(xml, 0, offset)

    {stack, inside_tag} =
      ~r/<(\/?)([A-Za-z_][\w.:-]*)([^<>]*)(>?)/
      |> Regex.scan(prefix, capture: :all_but_first)
      |> Enum.reduce({[], nil}, &track_tag/2)

    path = stack |> Enum.reverse() |> Enum.join("/")

    case inside_tag do
      nil -> path
      tag -> Enum.join(Enum.reject([path, tag], &(&1 == "")), "/") <> " (atributo)"
    end
  end

  @doc """
  Primeiro valor inválido de um termo genérico do codec (mapas, listas e
  valores simples), como `{caminho, caractere}`, ou `nil` se não houver.
  O caminho usa as chaves do termo, `[i]` para posição em lista e `@` para
  atributo. `skip?`
  diz quais valores ignorar (os marcadores de lacuna do template).
  """
  @spec find_in_term(term(), (binary() -> boolean())) ::
          {String.t(), char() | :invalid_utf8} | nil
  def find_in_term(term, skip? \\ fn _ -> false end), do: find(term, [], skip?)

  defp find(map, path, skip?) when is_map(map) do
    Enum.find_value(map, fn
      {:value, value} ->
        find(value, path, skip?)

      {:attributes, attributes} when is_map(attributes) ->
        Enum.find_value(attributes, fn {key, value} -> find(value, ["@#{key}" | path], skip?) end)

      {key, value} ->
        find(value, [to_string(key) | path], skip?)
    end)
  end

  defp find(list, path, skip?) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, i} -> find(value, ["[#{i}]" | path], skip?) end)
  end

  defp find(nil, _path, _skip?), do: nil

  defp find(value, path, skip?) do
    string = to_string(value)

    with false <- skip?.(string),
         {:error, _offset, c} <- check(string) do
      {path |> Enum.reverse() |> join_path(), c}
    else
      _ -> nil
    end
  end

  defp join_path(segments) do
    Enum.reduce(segments, "", fn
      "[" <> _ = index, acc -> acc <> index
      segment, "" -> segment
      segment, acc -> acc <> "/" <> segment
    end)
  end

  defp track_tag([_close, tag, _attrs, ""], {stack, _inside}), do: {stack, tag}
  defp track_tag(["/", _tag, _attrs, ">"], {[_ | stack], _inside}), do: {stack, nil}
  defp track_tag(["/", _tag, _attrs, ">"], {[], _inside}), do: {[], nil}

  defp track_tag(["", tag, attrs, ">"], {stack, _inside}) do
    if String.ends_with?(attrs, "/"), do: {stack, nil}, else: {[tag | stack], nil}
  end
end
