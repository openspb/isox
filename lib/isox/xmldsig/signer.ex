defmodule Isox.Xmldsig.Signer do
  @moduledoc """
  Núcleo do XMLDSig do Pix (Manual de Segurança do SFN Vol. II §3), comum
  aos dois perfis que o manual define: SPI, com três `<ds:Reference>`
  (tabela 3), e DICT, com duas (tabela 4). Hoje só o perfil SPI está
  implementado, em `sign/4`. `sign_references/3` e `key_info_xml/2` já
  bastam para montar o do DICT quando existir um simulador para ele, já
  que a diferença entre os dois é só a lista de referências, não o resto
  do mecanismo (§3.2 do manual: os passos são os mesmos).

  RSA-SHA256, digest SHA-256, canonicalização exclusiva.
  """

  require Record

  Record.defrecord(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @c14n_algorithm "http://www.w3.org/2001/10/xml-exc-c14n#"
  @signature_algorithm "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
  @digest_algorithm "http://www.w3.org/2001/04/xmlenc#sha256"
  @enveloped_algorithm "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
  @ds_ns "http://www.w3.org/2000/09/xmldsig#"

  @type reference_spec :: {uri :: String.t() | nil, transforms :: [String.t()], binary()}

  @doc """
  Perfil SPI (tabela 3): três `<ds:Reference>`, sendo `KeyInfo` por Id,
  `AppHdr` sem `<Sgntr>` preenchido e com transformação
  enveloped-signature, e `Document` sem atributo `URI`. A última fica fora
  do processamento padrão de XMLDSig: "deve ser interpretada pela
  aplicação de forma a referenciar a mensagem ISO 20.022 propriamente
  dita", manual §3.1.

  **`app_hdr_xml` e `document_xml` precisam já vir em forma canônica
  exclusiva.** Quem chama é o caminho de template da lib de codec (ADR
  0006), e essa é a razão de ele existir: sem isso, assinar pagaria
  canonicalização no caminho quente.

  Passar XML não canônico aqui produz uma assinatura que não bate na
  verificação, porque a verificação sempre canonicaliza de verdade (não
  pode confiar no que chegou de terceiro). Isto não é checado aqui de
  propósito: checar seria fazer a mesma canonicalização que o caminho de
  template existe para evitar.

  `private_key_der` é a chave privada RSA em DER, em um de dois formatos:
  PKCS#1 (`RSAPrivateKey`, o PEM `BEGIN RSA PRIVATE KEY`) ou PKCS#8 sem
  cifra (`PrivateKeyInfo`, o PEM `BEGIN PRIVATE KEY`, que é o que o
  OpenSSL 3 grava por padrão e o que vem dentro de um `.pfx`/`.p12`).
  Chave de outro algoritmo, como EC, levanta `ArgumentError`, porque o
  perfil é RSA-SHA256. `certificate_der` é o certificado X.509 dessa
  chave, também em DER.
  """
  @spec sign(binary(), binary(), binary(), binary()) :: binary()
  def sign(app_hdr_xml, document_xml, private_key_der, certificate_der) do
    key_info_id = "ki-" <> random_id()
    key_info_xml = key_info_xml(key_info_id, certificate_der)

    sign_references(
      [
        {"##{key_info_id}", [@c14n_algorithm], key_info_xml},
        {"", [@enveloped_algorithm, @c14n_algorithm], app_hdr_xml},
        {nil, [@c14n_algorithm], document_xml}
      ],
      private_key_der,
      key_info_xml
    )
  end

  @doc """
  Monta `<ds:Signature>` a partir de uma lista arbitrária de referências
  já canônicas, o núcleo comum aos dois perfis do manual. `key_info_xml`
  entra pronto (já contém o `Id` que a referência correspondente usa em
  `URI="#..."`) porque quem monta a lista de referências é quem sabe qual
  delas aponta pro `KeyInfo`.

  `private_key_der` aceita os mesmos formatos de `sign/4`: RSA em DER,
  PKCS#1 ou PKCS#8 sem cifra.
  """
  @spec sign_references([reference_spec()], binary(), binary()) :: binary()
  def sign_references(references, private_key_der, key_info_xml) do
    signed_info = signed_info_xml(references)
    signature_value = rsa_sign(signed_info, private_key_der)

    ~s(<ds:Signature xmlns:ds="#{@ds_ns}">) <>
      signed_info <>
      ~s(<ds:SignatureValue>#{signature_value}</ds:SignatureValue>) <>
      key_info_xml <>
      ~s(</ds:Signature>)
  end

  @doc """
  Monta `<ds:KeyInfo>` com `<ds:X509IssuerSerial>` (tabela 2, item 1.2.3.1
  do manual): nome do emissor (DN) e número de série do certificado, não
  o certificado inteiro embutido. É assim que o manual descreve: quem
  verifica é responsável por manter sua própria base de números de série
  e chaves públicas dos certificados (§3.3, nota de rodapé), não por
  confiar num certificado que veio dentro da própria mensagem.
  """
  @spec key_info_xml(String.t(), binary()) :: binary()
  def key_info_xml(id, certificate_der) do
    {issuer_name, serial_number} = issuer_and_serial(certificate_der)

    ~s(<ds:KeyInfo xmlns:ds="#{@ds_ns}" Id="#{id}"><ds:X509Data><ds:X509IssuerSerial>) <>
      ~s(<ds:X509IssuerName>#{escape_text(issuer_name)}</ds:X509IssuerName>) <>
      ~s(<ds:X509SerialNumber>#{serial_number}</ds:X509SerialNumber>) <>
      ~s(</ds:X509IssuerSerial></ds:X509Data></ds:KeyInfo>)
  end

  @doc "Nome do emissor (DN, renderizado) e número de série do certificado DER dado."
  @spec issuer_and_serial(binary()) :: {String.t(), integer()}
  def issuer_and_serial(certificate_der) do
    tbs =
      certificate_der
      |> :public_key.pkix_decode_cert(:otp)
      |> otp_certificate(:tbsCertificate)

    {render_name(otp_tbs_certificate(tbs, :issuer)), otp_tbs_certificate(tbs, :serialNumber)}
  end

  @spec digest(binary()) :: binary()
  def digest(canonical_xml), do: :sha256 |> :crypto.hash(canonical_xml) |> Base.encode64()

  @doc """
  Assina `canonical_signed_info` em RSA-SHA256 (PKCS#1 v1.5) e devolve o
  valor em Base64, como vai em `<ds:SignatureValue>`. `private_key_der`
  aceita os mesmos formatos de `sign/4`.
  """
  @spec rsa_sign(binary(), binary()) :: binary()
  def rsa_sign(canonical_signed_info, private_key_der) do
    private_key = rsa_private_key(private_key_der)
    canonical_signed_info |> :public_key.sign(:sha256, private_key) |> Base.encode64()
  end

  # PKCS#1 é tentado primeiro por ser o formato que sempre foi aceito: quem
  # já passa PKCS#1 segue pelo mesmo caminho de antes. ECPrivateKey (SEC1)
  # entra na lista só para a mensagem de erro dizer que a chave é EC, em
  # vez de dizer que não foi reconhecida.
  @private_key_formats [:RSAPrivateKey, :PrivateKeyInfo, :ECPrivateKey]

  defp rsa_private_key(der) do
    case decode_private_key(der) do
      {:ok, key} when Record.is_record(key, :RSAPrivateKey) ->
        key

      {:ok, key} ->
        raise ArgumentError,
              "a chave privada é #{key_type(key)}, mas o perfil de assinatura do " <>
                "Manual de Segurança do SFN é RSA-SHA256 e precisa de chave RSA"

      :error ->
        raise ArgumentError,
              "chave privada não reconhecida: esperado o DER de uma chave RSA em " <>
                "PKCS#1 (RSAPrivateKey) ou PKCS#8 sem cifra (PrivateKeyInfo)"
    end
  end

  defp decode_private_key(der) do
    Enum.find_value(@private_key_formats, :error, &decode_private_key(&1, der))
  end

  defp decode_private_key(format, der) do
    {:ok, :public_key.der_decode(format, der)}
  rescue
    _ -> nil
  end

  defp key_type(key) when Record.is_record(key, :ECPrivateKey), do: "EC"
  defp key_type(key) when Record.is_record(key, :DSAPrivateKey), do: "DSA"
  defp key_type({rsa, _pss_params}) when Record.is_record(rsa, :RSAPrivateKey), do: "RSASSA-PSS"
  defp key_type(_key), do: "de um algoritmo que não é RSA"

  defp signed_info_xml(references) do
    refs = Enum.map_join(references, "", &reference_xml/1)

    ~s(<ds:SignedInfo xmlns:ds="#{@ds_ns}">) <>
      ~s(<ds:CanonicalizationMethod Algorithm="#{@c14n_algorithm}"></ds:CanonicalizationMethod>) <>
      ~s(<ds:SignatureMethod Algorithm="#{@signature_algorithm}"></ds:SignatureMethod>) <>
      refs <>
      ~s(</ds:SignedInfo>)
  end

  defp reference_xml({uri, transforms, canonical_content}) do
    digest = digest(canonical_content)

    transforms_xml =
      Enum.map_join(transforms, "", fn algorithm ->
        ~s(<ds:Transform Algorithm="#{algorithm}"></ds:Transform>)
      end)

    uri_attr = if uri, do: ~s( URI="#{uri}"), else: ""

    ~s(<ds:Reference#{uri_attr}>) <>
      ~s(<ds:Transforms>#{transforms_xml}</ds:Transforms>) <>
      ~s(<ds:DigestMethod Algorithm="#{@digest_algorithm}"></ds:DigestMethod>) <>
      ~s(<ds:DigestValue>#{digest}</ds:DigestValue>) <>
      ~s(</ds:Reference>)
  end

  # Renderização "best-effort" do Distinguished Name (não há função pronta
  # pra isso em :public_key). Cobre os atributos comuns em certificados
  # ICP-Brasil (CN, OU, O, L, ST, C), com fallback pelo OID pra qualquer
  # outro. A ordem é a da própria codificação do certificado, não
  # necessariamente "CN primeiro" como no exemplo do manual. Validar
  # contra certificado real de CERTPIA/CERTPIC quando existir (issue #34).
  @oid_short_names %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU"
  }

  defp render_name({:rdnSequence, rdns}), do: Enum.map_join(rdns, ", ", &render_rdn/1)

  defp render_rdn(attributes) do
    Enum.map_join(attributes, "+", fn {:AttributeTypeAndValue, oid, value} ->
      "#{oid_short_name(oid)}=#{attribute_value(value)}"
    end)
  end

  defp oid_short_name(oid),
    do: Map.get(@oid_short_names, oid, oid |> Tuple.to_list() |> Enum.join("."))

  # DirectoryString (RFC 5280 §4.1.2.4) na forma em que `:public_key` o
  # devolve: UTF8String como binário, já em UTF-8; PrintableString,
  # TeletexString, BMPString e UniversalString como lista de caracteres.
  # Nas duas últimas, caractere acima de 255 vem como a quádrupla
  # {grupo, plano, linha, célula} do ASN.1, não como inteiro. TeletexString
  # é lido como Latin-1, que é o uso dele na prática.
  defp attribute_value({:utf8String, utf8}) when is_binary(utf8), do: utf8

  defp attribute_value({_tag, chars}) when is_list(chars),
    do: chars |> Enum.map(&codepoint/1) |> List.to_string()

  defp attribute_value(chars) when is_list(chars), do: to_string(chars)
  defp attribute_value(other), do: to_string(other)

  defp codepoint({group, plane, row, cell}),
    do: group * 0x1000000 + plane * 0x10000 + row * 0x100 + cell

  defp codepoint(char), do: char

  defp escape_text(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp random_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
