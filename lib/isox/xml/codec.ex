defmodule Isox.Xml.Codec do
  # Motor genérico de parse/build orientado a Isox.Schema. Não
  # conhece nenhuma mensagem específica, só percorre a árvore do schema
  # contra o XML (na entrada) ou contra o termo genérico (na saída).
  #
  # O termo genérico é: valor simples vira string; elemento complexo normal
  # vira mapa %{tag => valor} (lista quando max permite repetição);
  # simpleContent (valor + atributo, ex. IntrBkSttlmAmt) vira
  # %{value: ..., attributes: %{tag => valor}}; :opaque (<Sgntr>) vira a
  # string do XML interno, sem interpretar.
  #
  # Validação (pattern/enum/tamanho) acontece no parse; o build confia no
  # termo que recebe. A exceção é o conjunto de caracteres do catálogo
  # (Isox.Xml.Charset), conferido nos dois sentidos sobre o documento todo.
  #
  # compile_template/3 + render/2 são a terceira API do ADR 0003: compila
  # um termo com lacunas (gap/1) uma vez, e cada renderização só preenche
  # as lacunas, sem percorrer o schema de novo.
  #
  # Motor interno. Não faz parte da API pública da lib (quem consome usa
  # os módulos de mensagem, ex. Isox.Pacs008).
  @moduledoc false

  import Isox.Xml.Records

  alias Isox.Schema.{Attribute, Choice, ComplexType, Element, SimpleType}
  alias Isox.Xml.Charset

  @doc """
  Decodifica um XML contra o schema (a raiz, um `Schema.Element`).

  Antes do parser: tira o BOM UTF-8 e o padding de `#x0000` do fim, e
  confere o conjunto de caracteres do catálogo (`Isox.Xml.Charset`).
  Conteúdo que não seja espaço depois do elemento raiz é erro.
  """
  @spec parse(Element.t(), binary()) :: {:ok, term()} | {:error, String.t()}
  def parse(%Element{} = schema, xml) when is_binary(xml) do
    xml = Charset.strip_framing(xml)

    with :ok <- check_received(xml) do
      # bytes crus, não codepoints já decodificados: o prólogo declara
      # encoding="UTF-8" e é o próprio xmerl quem decodifica a partir disso.
      {node, rest} = :xmerl_scan.string(:binary.bin_to_list(xml))
      ensure_nothing_after_root!(rest)
      {:ok, extract_type(node, schema.type)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    # XML malformado faz o xmerl sair com exit, não raise, e isso não pode
    # derrubar o processo chamador; é entrada não confiável (PSP), não bug.
    :exit, reason -> {:error, inspect(reason)}
  end

  defp check_received(xml) do
    case Charset.check(xml) do
      :ok ->
        :ok

      {:error, offset, c} ->
        {:error, "#{Charset.locate(xml, offset)}: #{Charset.describe(c)} (byte #{offset})"}
    end
  end

  defp ensure_nothing_after_root!(rest) do
    unless rest |> List.to_string() |> String.trim() == "" do
      raise "conteúdo inesperado depois do elemento raiz"
    end
  end

  @doc """
  Monta o XML (com prólogo) a partir do termo genérico, contra o schema.

  `namespace`, quando dado, vira o `xmlns` da tag raiz. Namespace é
  declaração XML, não um `xs:attribute` do schema, então não é modelado
  como atributo comum; sem ele, o XML montado não teria como ser
  redespachado por `Isox.Registry.decode/1`.
  """
  @spec build(Element.t(), term(), String.t() | nil) :: {:ok, binary()} | {:error, String.t()}
  def build(%Element{} = schema, term, namespace \\ nil) do
    with {:ok, xml} <- build_unchecked(schema, term, namespace) do
      case Charset.check(xml) do
        :ok -> {:ok, xml}
        {:error, offset, c} -> {:error, charset_error(schema, term, xml, offset, c)}
      end
    end
  end

  defp build_unchecked(schema, term, namespace) do
    body =
      schema
      |> build_element(term)
      |> inject_xmlns(schema.tag, namespace)

    {:ok, ~s(<?xml version="1.0" encoding="UTF-8"?>) <> body}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Caminho de erro só: a checagem do documento inteiro já falhou, e agora
  # vale a pena percorrer o termo para dizer qual campo tem o caractere.
  # Sem achar no termo (o namespace, por exemplo), cai na posição do XML.
  defp charset_error(schema, term, xml, offset, c, skip? \\ fn _ -> false end) do
    case Charset.find_in_term(term, skip?) do
      {path, c} -> "#{schema.tag}/#{path}: #{Charset.describe(c)}"
      nil -> "#{Charset.locate(xml, offset)}: #{Charset.describe(c)} (byte #{offset})"
    end
  end

  defp inject_xmlns(body, _tag, nil), do: body

  defp inject_xmlns(body, tag, namespace) do
    String.replace(body, "<#{tag}>", ~s(<#{tag} xmlns="#{escape_attribute(namespace)}">),
      global: false
    )
  end

  # --- template canônico (ADR 0003) ---

  @gap_regex ~r/\x00([a-zA-Z_][a-zA-Z0-9_]*)\x00/
  @gap_marker ~r/^\x00[a-zA-Z_][a-zA-Z0-9_]*\x00$/

  @typedoc "Template compilado: trechos fixos intercalados com lacunas a preencher depois."
  @type template :: [binary() | {:gap, atom()}]

  @doc """
  Marcador de lacuna: usa no lugar de um valor real, num termo passado para
  `compile_template/3`, pra dizer "isso varia, preenche depois".
  """
  @spec gap(atom()) :: binary()
  def gap(key) when is_atom(key), do: <<0>> <> Atom.to_string(key) <> <<0>>

  @doc """
  Compila `{schema, termo com lacunas}` num template canônico: monta o XML
  normalmente (reaproveita `encode/3`, mesma árvore, mesma validação de
  atributo obrigatório) e depois separa os trechos fixos das lacunas, sem
  percorrer o schema de novo. Pensado pro caminho quente do simulador: o
  custo de percorrer a árvore é pago uma vez aqui, não a cada mensagem.
  """
  @spec compile_template(Element.t(), term(), String.t() | nil) ::
          {:ok, template()} | {:error, String.t()}
  def compile_template(%Element{} = schema, term_with_gaps, namespace \\ nil) do
    with {:ok, xml} <- build_unchecked(schema, term_with_gaps, namespace) do
      fixed = Regex.replace(@gap_regex, xml, "")

      case Charset.check(fixed) do
        :ok ->
          {:ok, split_gaps(xml)}

        {:error, offset, c} ->
          skip? = &Regex.match?(@gap_marker, &1)
          {:error, charset_error(schema, term_with_gaps, fixed, offset, c, skip?)}
      end
    end
  end

  @doc """
  Preenche as lacunas de um template já compilado, produzindo o XML final.
  Só os valores das lacunas passam pela checagem de caracteres: os trechos
  fixos já passaram em `compile_template/3`. Valor fora do conjunto do
  catálogo levanta `ArgumentError`, como lacuna sem valor levanta
  `KeyError`.
  """
  @spec render(template(), %{atom() => term()}) :: binary()
  def render(template, variable_fields) do
    Enum.map_join(template, "", fn
      {:gap, key} ->
        variable_fields |> Map.fetch!(key) |> to_string() |> checked_gap(key) |> escape_text()

      fixed ->
        fixed
    end)
  end

  defp checked_gap(value, key) do
    case Charset.check(value) do
      :ok -> value
      {:error, _offset, c} -> raise ArgumentError, "lacuna #{key}: #{Charset.describe(c)}"
    end
  end

  defp split_gaps(xml) do
    @gap_regex
    |> Regex.split(xml, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&segment/1)
  end

  defp segment(<<0, rest::binary>>),
    do: {:gap, rest |> String.trim_trailing(<<0>>) |> String.to_existing_atom()}

  defp segment(fixed), do: fixed

  # --- extração (parse) ---

  defp extract_type(_node, :opaque), do: nil
  defp extract_type(node, %SimpleType{} = type), do: node |> direct_text() |> validate!(type)

  defp extract_type(node, %ComplexType{text: %SimpleType{} = text_type} = type) do
    %{
      value: node |> direct_text() |> validate!(text_type),
      attributes: extract_attributes(node, type.attributes)
    }
  end

  defp extract_type(node, %ComplexType{content: items}) do
    grouped = group_by_tag(node)
    Enum.reduce(items, %{}, fn item, acc -> Map.merge(acc, extract_item(item, grouped)) end)
  end

  defp extract_opaque_content(node),
    do: node |> xmlElement(:content) |> Enum.map_join("", &serialize_node/1)

  defp extract_item(%Element{type: :opaque, tag: tag, min: min}, grouped) do
    case Map.get(grouped, tag, []) do
      [single] -> %{tag => extract_opaque_content(single)}
      [] when min == 0 -> %{}
      [] -> raise "elemento obrigatório ausente: #{tag}"
    end
  end

  defp extract_item(%Element{tag: tag, type: type, min: min, max: 1}, grouped) do
    case Map.get(grouped, tag, []) do
      [single] -> %{tag => extract_type(single, type)}
      [] when min == 0 -> %{}
      [] -> raise "elemento obrigatório ausente: #{tag}"
      _ -> raise "elemento #{tag} apareceu mais de uma vez, mas a cardinalidade máxima é 1"
    end
  end

  defp extract_item(%Element{tag: tag, type: type, min: min, max: max}, grouped) do
    children = Map.get(grouped, tag, [])
    count = length(children)

    cond do
      count < min ->
        raise "elemento #{tag}: esperado ao menos #{min}, vieram #{count}"

      max != :unbounded and count > max ->
        raise "elemento #{tag}: esperado no máximo #{max}, vieram #{count}"

      true ->
        %{tag => Enum.map(children, &extract_type(&1, type))}
    end
  end

  defp extract_item(%Choice{options: options, min: min}, grouped) do
    case best_option(options, &Map.has_key?(grouped, &1)) do
      nil when min == 0 ->
        %{}

      nil ->
        raise "nenhuma opção da escolha está presente: #{inspect(Enum.map(options, &option_tags/1))}"

      option ->
        extract_option(option, grouped)
    end
  end

  # Uma opção de `Choice` é ou 1 elemento, ou (quando vem de `xs:group ref=`
  # dentro de um `xs:choice` com mais de 1 elemento no grupo) a lista de
  # elementos do grupo inteiro. Duas opções de grupo podem compartilhar tag
  # (ex. reda.022: `ReqdModContato` e `ReqdModDiretor` têm PhneNb/EmailAdr/
  # Rspnsblty em comum, só `Nm` distingue): "presente" não basta, escolhe a
  # opção com MAIS tags batendo, não a primeira com alguma batendo, senão um
  # exemplar do ramo com o campo distintivo ausente escolhe o ramo errado e
  # perde esse campo.
  defp best_option(options, key_present?) do
    options
    |> Enum.map(&{&1, present_count(&1, key_present?)})
    |> Enum.filter(fn {_option, count} -> count > 0 end)
    |> Enum.max_by(fn {_option, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp present_count(%Element{tag: tag}, key_present?),
    do: if(key_present?.(tag), do: 1, else: 0)

  defp present_count(members, key_present?) when is_list(members),
    do: Enum.count(members, &key_present?.(&1.tag))

  defp option_tags(%Element{tag: tag}), do: tag
  defp option_tags(members) when is_list(members), do: Enum.map(members, & &1.tag)

  defp extract_option(%Element{} = element, grouped), do: extract_item(element, grouped)

  defp extract_option(members, grouped) when is_list(members) do
    Enum.reduce(members, %{}, fn item, acc -> Map.merge(acc, extract_item(item, grouped)) end)
  end

  defp group_by_tag(node) do
    node
    |> xmlElement(:content)
    |> Enum.filter(&(is_tuple(&1) and elem(&1, 0) == :xmlElement))
    |> Enum.group_by(&(&1 |> xmlElement(:name) |> Atom.to_string()))
  end

  defp extract_attributes(node, schema_attributes) do
    raw = xmlElement(node, :attributes)

    Enum.reduce(schema_attributes, %{}, fn %Attribute{tag: tag, type: type}, acc ->
      case attribute_value(raw, tag) do
        nil -> acc
        value -> Map.put(acc, tag, validate!(value, type))
      end
    end)
  end

  defp attribute_value(raw, tag) do
    Enum.find_value(raw, fn a ->
      if Atom.to_string(xmlAttribute(a, :name)) == tag,
        do: a |> xmlAttribute(:value) |> List.to_string()
    end)
  end

  defp direct_text(node) do
    node
    |> xmlElement(:content)
    |> Enum.filter(&(is_tuple(&1) and elem(&1, 0) == :xmlText))
    |> Enum.map_join("", fn t -> t |> xmlText(:value) |> List.to_string() end)
    |> String.trim()
  end

  defp validate!(value, %SimpleType{} = type) do
    if type.pattern && not Regex.match?(anchored_regex(type.pattern), value) do
      raise "valor #{inspect(value)} não bate com o padrão #{type.pattern}"
    end

    if type.enum && value not in type.enum do
      raise "valor #{inspect(value)} não está entre #{inspect(type.enum)}"
    end

    if type.max_length && String.length(value) > type.max_length do
      raise "valor #{inspect(value)} excede o tamanho máximo #{type.max_length}"
    end

    if type.min_length && String.length(value) < type.min_length do
      raise "valor #{inspect(value)} é menor que o tamanho mínimo #{type.min_length}"
    end

    validate_decimal!(value, type)
    validate_date!(value, type)
    validate_boolean!(value, type)

    value
  end

  # xs:pattern casa contra o valor inteiro, não uma substring, então Regex.match?
  # do Elixir não ancora sozinho.
  defp anchored_regex(pattern), do: Regex.compile!("^(?:" <> pattern <> ")$")

  # fractionDigits/totalDigits/minInclusive/maxInclusive (ex.:
  # ActiveCurrencyAndAmount_SimpleType: fractionDigits 2, totalDigits 18,
  # minInclusive 0) não tinham validação nenhuma antes: pattern/enum/
  # tamanho não cobrem faixa numérica nem casas decimais, então um valor
  # monetário negativo, com casas decimais demais, ou nem sequer numérico
  # ("abc") passava reto pelo parse. Sem lib de decimal: os valores desse
  # catálogo cabem em inteiro nativo (≤18 dígitos), então compara como
  # inteiro escalado (parte inteira + fracionária concatenadas, fração
  # completada com zero à direita até o mesmo tamanho dos dois lados) em vez
  # de converter pra float, que perderia precisão exata em valor monetário.
  defp validate_decimal!(value, %SimpleType{
         fraction_digits: fraction_digits,
         total_digits: total_digits,
         min_inclusive: min_inclusive,
         max_inclusive: max_inclusive
       })
       when not is_nil(fraction_digits) or not is_nil(total_digits) or
              not is_nil(min_inclusive) or not is_nil(max_inclusive) do
    case parse_decimal(value) do
      :error ->
        raise "valor #{inspect(value)} não é um decimal válido"

      decimal ->
        check_fraction_digits!(value, decimal, fraction_digits)
        check_total_digits!(value, decimal, total_digits)
        check_min_inclusive!(value, decimal, min_inclusive)
        check_max_inclusive!(value, decimal, max_inclusive)
    end
  end

  defp validate_decimal!(_value, _type), do: :ok

  defp check_fraction_digits!(_value, _decimal, nil), do: :ok

  defp check_fraction_digits!(value, {_sign, _int_digits, frac_digits}, fraction_digits) do
    if String.length(frac_digits) > fraction_digits do
      raise "valor #{inspect(value)} tem mais casas decimais que o permitido (#{fraction_digits})"
    end
  end

  defp check_total_digits!(_value, _decimal, nil), do: :ok

  defp check_total_digits!(value, {_sign, int_digits, frac_digits}, total_digits) do
    if significant_digits(int_digits, frac_digits) > total_digits do
      raise "valor #{inspect(value)} excede o total de dígitos permitido (#{total_digits})"
    end
  end

  defp check_min_inclusive!(_value, _decimal, nil), do: :ok

  defp check_min_inclusive!(value, decimal, min_inclusive) do
    if compare_decimal(decimal, min_inclusive) == :lt do
      raise "valor #{inspect(value)} é menor que o mínimo permitido (#{min_inclusive})"
    end
  end

  defp check_max_inclusive!(_value, _decimal, nil), do: :ok

  defp check_max_inclusive!(value, decimal, max_inclusive) do
    if compare_decimal(decimal, max_inclusive) == :gt do
      raise "valor #{inspect(value)} excede o máximo permitido (#{max_inclusive})"
    end
  end

  # xs:date (ex.: OrgnlTxRef/IntrBkSttlmDt do pacs.002) nunca vem com
  # pattern no XSD do catálogo: <xs:restriction base="xs:date"/> vazio,
  # confiando na validação léxica embutida do xs:date. Este motor não
  # implementa isso, então sem este check um valor não-data passava reto
  # pelo parse e só quebrava (raise não capturado) mais tarde, dentro do
  # parse_date! de quem lê o termo, depois da zona protegida pelo rescue
  # de Codec.parse/2. Usa o mesmo Date.from_iso8601/1 que esse parse final
  # já usa, pra não ter padrão duplo entre o que valida aqui e o que quem
  # chama espera conseguir parsear depois.
  defp validate_date!(value, %SimpleType{base: "date"}) do
    if match?({:error, _}, Date.from_iso8601(value)) do
      raise "valor #{inspect(value)} não é uma data válida (YYYY-MM-DD)"
    end
  end

  defp validate_date!(_value, _type), do: :ok

  # xs:boolean (ex.: TrckgInd/DtAdjstmntRuleInd do pacs.009/011/012)
  # também nunca vem com pattern no XSD do catálogo,
  # <xs:restriction base="xs:boolean"/> vazio, mesma situação do
  # xs:date acima: confia na validação léxica embutida do tipo, que
  # este motor não implementa de nenhum outro jeito. Sem este check,
  # qualquer string passava reto pelo parse/build como se fosse um
  # boolean válido. "true"/"false"/"1"/"0" são as 4 representações
  # léxicas válidas de xs:boolean pela especificação XML Schema.
  defp validate_boolean!(value, %SimpleType{base: "boolean"}) do
    if value not in ["true", "false", "1", "0"] do
      raise "valor #{inspect(value)} não é um boolean válido (true/false/1/0)"
    end
  end

  defp validate_boolean!(_value, _type), do: :ok

  # named_captures, não Regex.run posicional: quando o grupo fracionário
  # opcional não participa do match (valor sem ponto decimal, ex. "0"), o
  # :re do Erlang derruba esse grupo à direita da lista em vez de devolver
  # "": Regex.run vem com aridade variável nesse caso, e um case por
  # posição quebra. named_captures sempre devolve as 3 chaves.
  @decimal_pattern ~r/^(?<sign>-?)(?<int>\d+)(?:\.(?<frac>\d+))?$/

  defp parse_decimal(value) do
    case Regex.named_captures(@decimal_pattern, value) do
      %{"sign" => sign, "int" => int_digits, "frac" => frac_digits} ->
        {if(sign == "-", do: -1, else: 1), int_digits, frac_digits}

      nil ->
        :error
    end
  end

  defp significant_digits(int_digits, frac_digits) do
    trimmed = String.trim_leading(int_digits, "0")
    int_count = if trimmed == "", do: 1, else: String.length(trimmed)
    int_count + String.length(frac_digits)
  end

  defp compare_decimal({sign, int_digits, frac_digits}, bound) do
    {bound_sign, bound_int, bound_frac} = parse_decimal(bound)
    scale = max(String.length(frac_digits), String.length(bound_frac))

    magnitude = String.to_integer(int_digits <> String.pad_trailing(frac_digits, scale, "0"))
    bound_magnitude = String.to_integer(bound_int <> String.pad_trailing(bound_frac, scale, "0"))

    ordering(sign * magnitude, bound_sign * bound_magnitude)
  end

  defp ordering(a, b) when a < b, do: :lt
  defp ordering(a, b) when a > b, do: :gt
  defp ordering(_a, _b), do: :eq

  defp serialize_node(node) do
    case elem(node, 0) do
      :xmlText ->
        node |> xmlText(:value) |> List.to_string()

      :xmlElement ->
        tag = node |> xmlElement(:name) |> Atom.to_string()
        attributes = node |> xmlElement(:attributes) |> Enum.map_join("", &serialize_attribute/1)
        children = node |> xmlElement(:content) |> Enum.map_join("", &serialize_node/1)
        "<#{tag}#{attributes}>#{children}</#{tag}>"
    end
  end

  defp serialize_attribute(a) do
    name = xmlAttribute(a, :name)
    value = a |> xmlAttribute(:value) |> List.to_string() |> escape_attribute()
    ~s( #{name}="#{value}")
  end

  # --- construção (build) ---

  defp build_element(%Element{tag: tag, type: type}, term) do
    "<#{tag}#{build_attributes(type, term)}>#{build_content(type, term)}</#{tag}>"
  end

  defp build_attributes(%ComplexType{attributes: attributes}, term) when attributes != [] do
    map = Map.get(term, :attributes, %{})

    Enum.map_join(attributes, "", fn %Attribute{tag: tag} ->
      ~s( #{tag}="#{map |> Map.fetch!(tag) |> to_string() |> escape_attribute()}")
    end)
  end

  defp build_attributes(_type, _term), do: ""

  defp build_content(:opaque, term), do: term || ""
  defp build_content(%SimpleType{}, term), do: escape_text(to_string(term))

  defp build_content(%ComplexType{text: %SimpleType{}}, term) do
    escape_text(to_string(Map.fetch!(term, :value)))
  end

  defp build_content(%ComplexType{content: items}, term) do
    Enum.map_join(items, "", &build_item(&1, term))
  end

  defp build_item(%Element{tag: tag, max: 1} = element, term) do
    case Map.get(term, tag) do
      nil -> ""
      value -> build_element(element, value)
    end
  end

  defp build_item(%Element{tag: tag} = element, term) do
    term |> Map.get(tag, []) |> Enum.map_join("", &build_element(element, &1))
  end

  defp build_item(%Choice{options: options}, term) do
    case best_option(options, &Map.has_key?(term, &1)) do
      nil -> ""
      option -> build_option(option, term)
    end
  end

  defp build_option(%Element{} = element, term), do: build_item(element, term)

  defp build_option(members, term) when is_list(members),
    do: Enum.map_join(members, "", &build_item(&1, term))

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attribute(text), do: text |> escape_text() |> String.replace(~s("), "&quot;")
end
