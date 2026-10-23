defmodule Isox do
  @moduledoc """
  Codec das mensagens ISO 20022 do catálogo do SPI (Pix).

  `encode/2` e `decode/1` são genéricos: despacham pelo tipo do modelo na
  ida e pelo namespace do XML na volta, então você não precisa saber de
  antemão qual mensagem está em jogo. O schema vem dos XSDs publicados
  pelo Banco Central, que não são redistribuídos aqui (ver
  `mix catalog.gen`).

      envelope = %Isox.Envelope{
        header: %Isox.AppHdr{...},
        message: %Isox.Pacs008{...}
      }

      {:ok, xml} = Isox.encode(envelope, :v1_16)
      {:ok, %Isox.Envelope{message: %Isox.Pacs008{}}, :v1_16} = Isox.decode(xml)

  `encode/2` recebe um `Isox.Envelope`, que é o par cabeçalho e mensagem,
  mais a versão do schema, e devolve o XML pronto e já validado.
  `decode/1` faz o caminho inverso e devolve os dois de volta dentro de um
  envelope.

  Cada mensagem também tem seu módulo de baixo nível, com a mesma forma de
  API mas sem o despacho automático. Serve para quando você já sabe o que
  está manipulando:

      {:ok, xml} = Isox.Pacs008.encode(mensagem, cabecalho, :v1_16)
      {:ok, mensagem, :v1_16} = Isox.Pacs008.decode(xml)

  ## O que cada campo quer dizer

  A pergunta que mais aparece integrando com o SPI é o que é um campo. O
  `Isox.Dictionary` responde, sem sair do editor:

      iex> {:ok, entrada} = Isox.Dictionary.field(Isox.Pacs008, :dbtr_acct_id)
      iex> entrada.name_br
      "contaUsuarioPagador"

  `explain/2` mostra o campo inteiro, com caminho no XML, regra de
  preenchimento e valores aceitos. `search/1` procura por qualquer termo
  em todas as mensagens. A documentação de cada mensagem traz a mesma
  informação em tabela.

  ## Assinatura digital

  `sign/4`, `verify/2` e `generate_test_certificate/0` cobrem o dia a dia:
  assinar o que sua aplicação envia, verificar o que ela recebe e gerar
  certificado descartável para testar.

  Por baixo, quem faz isso é `Isox.Xmldsig`, um módulo à parte que não
  conhece estrutura de mensagem nenhuma. Para esta camada de codec,
  `<Sgntr>` é sempre opaco. Vá direto lá só se precisar de controle mais
  fino, como um perfil com outro número de referências.

      # Os dois lados usam chaves opostas. Para assinar o que você manda,
      # é a sua chave privada com o seu certificado. Para verificar o que
      # você recebe, é o certificado público de quem assinou. Nenhum dos
      # lados precisa da chave privada do outro. Ver a seção de
      # certificados no README.
      signature_xml = Isox.sign(app_hdr_xml, document_xml, minha_chave_privada_der, meu_certificado_der)
      :ok = Isox.verify(envelope_recebido_xml, certificado_de_quem_enviou_der)
  """

  alias Isox.{AppHdr, Dictionary, Envelope, Registry}
  alias Isox.Xmldsig.{Signer, TestCA, Verifier}

  @doc """
  Codifica um envelope (cabeçalho + modelo da mensagem) para XML, na
  versão de schema dada. Despacha pelo tipo do modelo em
  `envelope.message` para o módulo de baixo nível certo: se for um
  `Isox.Pacs008`, chama `Isox.Pacs008.encode/3`.
  """
  @spec encode(Envelope.t(), atom()) :: {:ok, binary()} | {:error, term()}
  def encode(%Envelope{header: %AppHdr{} = header, message: %module{} = message}, version) do
    module.encode(message, header, version)
  end

  @doc """
  Decodifica um XML de qualquer mensagem do catálogo, identificando
  sozinho o tipo e a versão a partir do namespace. É o ponto de entrada
  para quem recebe XML sem saber de antemão que mensagem é, no lugar de
  `Isox.Registry.decode/1`.
  """
  @spec decode(binary()) :: {:ok, Envelope.t(), atom()} | {:error, term()}
  def decode(xml) when is_binary(xml) do
    with {:ok, generated_module, term} <- Registry.decode(xml),
         {:ok, wrapper} <- wrapper_module(generated_module),
         {:ok, message, version} <- wrapper.decode(xml) do
      {:ok, %Envelope{header: AppHdr.from_term(term["AppHdr"]), message: message}, version}
    end
  end

  # Isox.Generated.<Mensagem>.<Versao> -> Isox.<Mensagem> (ADR 0004): o
  # módulo de baixo nível achado pelo namespace e o módulo de mensagem que
  # sabe montar o modelo a partir dele têm sempre esses dois nomes, então
  # não precisa de mais uma tabela de despacho pra manter em dia.
  defp wrapper_module(generated_module) do
    case Module.split(generated_module) do
      ["Isox", "Generated", message_module, _version_module] ->
        {:ok, Module.concat(Isox, message_module)}

      _ ->
        {:error, {:unsupported_message, generated_module}}
    end
  end

  @doc """
  O campo explicado em texto corrido, para ler no IEx.

      Isox.Pacs008 |> Isox.explain(:purp_cd) |> IO.puts()

  Encaminha para `Isox.Dictionary.explain/2`.
  """
  @spec explain(module(), atom()) :: String.t()
  defdelegate explain(message, field), to: Dictionary

  @doc """
  Todos os campos de uma mensagem, com nome no catálogo, caminho no XML,
  obrigatoriedade e descrição. Encaminha para `Isox.Dictionary.fields/1`.
  """
  @spec fields(module()) :: [Isox.Dictionary.Entry.t()]
  defdelegate fields(message), to: Dictionary

  @doc """
  Procura um termo nos campos de todas as mensagens, ignorando acento e
  caixa. Encaminha para `Isox.Dictionary.search/1`.
  """
  @spec search(String.t()) :: [{module(), Isox.Dictionary.Entry.t()}]
  defdelegate search(term), to: Dictionary

  @doc """
  Assina `app_hdr_xml` + `document_xml` no perfil de três `<ds:Reference>`
  do Manual de Segurança do SFN. Ambos precisam já vir em forma canônica
  exclusiva. Esta função só encaminha para `Isox.Xmldsig.Signer.sign/4`.

  A chave privada é RSA em DER, em PKCS#1 (`BEGIN RSA PRIVATE KEY`) ou
  PKCS#8 sem cifra (`BEGIN PRIVATE KEY`, o padrão do OpenSSL 3 e o formato
  de dentro de um `.pfx`/`.p12`). O certificado também vai em DER. Chave
  de outro algoritmo levanta `ArgumentError`.
  """
  @spec sign(binary(), binary(), binary(), binary()) :: binary()
  defdelegate sign(app_hdr_xml, document_xml, private_key_der, certificate_der), to: Signer

  @doc """
  Verifica a assinatura de `envelope_xml` contra `certificate_der`, o
  certificado que você confia para quem assinou. Encaminha para
  `Isox.Xmldsig.Verifier.verify/2`.
  """
  @spec verify(binary(), binary()) :: :ok | {:error, Verifier.error()}
  defdelegate verify(envelope_xml, certificate_der), to: Verifier

  @doc """
  Gera, em memória, um par de chave privada + certificado autoassinado
  para testes. **Nunca em produção**. Ver `Isox.Xmldsig.TestCA`.
  """
  @spec generate_test_certificate() :: TestCA.ca()
  defdelegate generate_test_certificate, to: TestCA, as: :generate
end
