defmodule Isox.Xmldsig.SignatureRoundTripTest do
  use ExUnit.Case, async: true

  require Record

  alias Isox.Xmldsig.{Signer, Verifier}
  alias Isox.Xmldsig.TestCA

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @country {2, 5, 4, 6}
  @organization {2, 5, 4, 10}
  @common_name {2, 5, 4, 3}

  setup do
    {:ok, TestCA.generate()}
  end

  defp app_hdr_xml do
    ~s(<AppHdr xmlns="urn:pix"><Fr>11111111</Fr><To>22222222</To>) <>
      ~s(<BizMsgIdr>M12345678901234567890123456789</BizMsgIdr>) <>
      ~s(<MsgDefIdr>pacs.008.spi.1.16</MsgDefIdr><CreDt>2026-09-12T10:00:00.000Z</CreDt>) <>
      ~s(<Sgntr></Sgntr></AppHdr>)
  end

  defp document_xml do
    ~s(<Document xmlns="urn:pix:pacs.008"><FIToFICstmrCdtTrf><GrpHdr><MsgId>x</MsgId></GrpHdr></FIToFICstmrCdtTrf></Document>)
  end

  # A pacs.008/AppHdr real tem <Sgntr> como filho do AppHdr; aqui o corpo
  # do teste simula isso: assina, encaixa o <Signature> dentro do <Sgntr>
  # e monta o envelope completo, do jeito que o Engine faria de verdade.
  defp assemble_envelope(app_hdr_without_sgntr, document, signature_xml) do
    app_hdr_with_signature =
      String.replace(app_hdr_without_sgntr, "<Sgntr></Sgntr>", "<Sgntr>#{signature_xml}</Sgntr>")

    ~s(<Envelope xmlns="urn:envelope">#{app_hdr_with_signature}#{document}</Envelope>)
  end

  test "verificar contra mensagem sem assinatura nenhuma erra, não crasha", %{
    certificate_der: certificate_der
  } do
    # Regressão: usar `valor || :atomo_de_erro` como fallback de "nil" num
    # guard `not is_nil/1` não funciona, porque o próprio átomo de erro também
    # não é nil, então o guard passava e o código seguia tratando o átomo
    # como se fosse o elemento encontrado, e explodia mais adiante.
    envelope = assemble_envelope(app_hdr_xml(), document_xml(), "")

    assert {:error, :missing_signature} = Verifier.verify(envelope, certificate_der)
  end

  test "assina e verifica com sucesso", %{
    private_key_der: private_key_der,
    certificate_der: certificate_der
  } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)
    envelope = assemble_envelope(app_hdr_xml(), document_xml(), signature_xml)

    assert Verifier.verify(envelope, certificate_der) == :ok
  end

  test "o KeyInfo usa X509IssuerSerial (emissor + número de série), não o certificado inteiro",
       %{
         private_key_der: private_key_der,
         certificate_der: certificate_der
       } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)

    assert signature_xml =~ "<ds:X509IssuerSerial>"
    assert signature_xml =~ "<ds:X509IssuerName>"
    assert signature_xml =~ "<ds:X509SerialNumber>"
    refute signature_xml =~ "<ds:X509Certificate>"
  end

  test "rejeita quando o Document foi alterado depois de assinado", %{
    private_key_der: private_key_der,
    certificate_der: certificate_der
  } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)

    tampered_document = String.replace(document_xml(), "<MsgId>x</MsgId>", "<MsgId>y</MsgId>")
    envelope = assemble_envelope(app_hdr_xml(), tampered_document, signature_xml)

    assert {:error, {:digest_mismatch, 2}} = Verifier.verify(envelope, certificate_der)
  end

  test "rejeita quando o AppHdr foi alterado depois de assinado", %{
    private_key_der: private_key_der,
    certificate_der: certificate_der
  } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)

    tampered_app_hdr = String.replace(app_hdr_xml(), "<Fr>11111111</Fr>", "<Fr>99999999</Fr>")
    envelope = assemble_envelope(tampered_app_hdr, document_xml(), signature_xml)

    assert {:error, {:digest_mismatch, 1}} = Verifier.verify(envelope, certificate_der)
  end

  test "rejeita certificado diferente do que assinou (emissor+série não batem)", %{
    private_key_der: private_key_der,
    certificate_der: certificate_der
  } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)
    envelope = assemble_envelope(app_hdr_xml(), document_xml(), signature_xml)

    other = TestCA.generate()
    assert {:error, :certificate_mismatch} = Verifier.verify(envelope, other.certificate_der)
  end

  test "rejeita SignedInfo cuja assinatura foi trocada por outra válida (mixagem)", %{
    private_key_der: private_key_der,
    certificate_der: certificate_der
  } do
    signature_xml = Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)

    other_signature_xml =
      Signer.sign(app_hdr_xml(), document_xml(), private_key_der, certificate_der)

    [_, other_value] =
      Regex.run(~r{<ds:SignatureValue>(.*?)</ds:SignatureValue>}, other_signature_xml)

    [_, own_value] = Regex.run(~r{<ds:SignatureValue>(.*?)</ds:SignatureValue>}, signature_xml)

    mixed_signature_xml = String.replace(signature_xml, own_value, other_value)
    envelope = assemble_envelope(app_hdr_xml(), document_xml(), mixed_signature_xml)

    assert {:error, :invalid_signature} = Verifier.verify(envelope, certificate_der)
  end

  test "AppHdr com atributos fora de ordem canônica ao assinar quebra a verificação (contrato de sign/4)",
       %{
         private_key_der: private_key_der,
         certificate_der: certificate_der
       } do
    # Ordem canônica de atributo é alfabética por nome local: "Zebra"
    # antes de "Apple" é válido como XML, mas não-canônico. sign/4 não
    # canonicaliza (é o contrato: quem chama garante isso, ADR 0006), então
    # assina os bytes como vieram; verify/2 sempre recanonicaliza de
    # verdade (não pode confiar no que chegou de terceiro) e reordenaria
    # pra "Apple" antes de "Zebra", e os dois digests do AppHdr divergem.
    non_canonical_app_hdr =
      ~s(<AppHdr xmlns="urn:pix" Zebra="2" Apple="1"><Fr>11111111</Fr><To>22222222</To>) <>
        ~s(<BizMsgIdr>M12345678901234567890123456789</BizMsgIdr>) <>
        ~s(<MsgDefIdr>pacs.008.spi.1.16</MsgDefIdr><CreDt>2026-09-12T10:00:00.000Z</CreDt>) <>
        ~s(<Sgntr></Sgntr></AppHdr>)

    signature_xml =
      Signer.sign(non_canonical_app_hdr, document_xml(), private_key_der, certificate_der)

    envelope = assemble_envelope(non_canonical_app_hdr, document_xml(), signature_xml)

    assert {:error, {:digest_mismatch, 1}} = Verifier.verify(envelope, certificate_der)
  end

  describe "formato da chave privada" do
    test "PKCS#1 assina exatamente como antes de PKCS#8 ser aceito", %{
      private_key_der: private_key_der
    } do
      signed_info =
        ~s(<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"></ds:SignedInfo>)

      before =
        signed_info
        |> :public_key.sign(:sha256, :public_key.der_decode(:RSAPrivateKey, private_key_der))
        |> Base.encode64()

      assert Signer.rsa_sign(signed_info, private_key_der) == before
      assert Signer.rsa_sign(signed_info, pkcs8(private_key_der)) == before
    end

    test "PKCS#8 assina e verifica", %{
      private_key_der: private_key_der,
      certificate_der: certificate_der
    } do
      signature_xml =
        Signer.sign(app_hdr_xml(), document_xml(), pkcs8(private_key_der), certificate_der)

      envelope = assemble_envelope(app_hdr_xml(), document_xml(), signature_xml)

      assert Verifier.verify(envelope, certificate_der) == :ok
    end

    test "chave EC levanta ArgumentError, em SEC1 ou em PKCS#8", %{
      certificate_der: certificate_der
    } do
      ec_key = :public_key.generate_key({:namedCurve, :secp256r1})

      for ec_der <- [
            :public_key.der_encode(:ECPrivateKey, ec_key),
            :public_key.der_encode(:PrivateKeyInfo, ec_key)
          ] do
        assert_raise ArgumentError, ~r/chave privada é EC.*RSA-SHA256/, fn ->
          Signer.sign(app_hdr_xml(), document_xml(), ec_der, certificate_der)
        end
      end
    end

    test "bytes que não são chave levantam ArgumentError", %{certificate_der: certificate_der} do
      assert_raise ArgumentError, ~r/não reconhecida.*PKCS#1.*PKCS#8/, fn ->
        Signer.sign(app_hdr_xml(), document_xml(), "não é DER", certificate_der)
      end
    end
  end

  describe "emissor do certificado" do
    test "UTF8String com acento assina e verifica", ca do
      certificate_der =
        certificate_with_issuer(ca, [
          {@country, ~c"BR"},
          {@organization, {:utf8String, "AC Teste São Paulo"}},
          {@common_name, {:utf8String, "PSP Teste"}}
        ])

      assert {"C=BR, O=AC Teste São Paulo, CN=PSP Teste", _serial} =
               Signer.issuer_and_serial(certificate_der)

      signature_xml =
        Signer.sign(app_hdr_xml(), document_xml(), ca.private_key_der, certificate_der)

      assert signature_xml =~
               "<ds:X509IssuerName>C=BR, O=AC Teste São Paulo, CN=PSP Teste</ds:X509IssuerName>"

      envelope = assemble_envelope(app_hdr_xml(), document_xml(), signature_xml)

      assert Verifier.verify(envelope, certificate_der) == :ok
    end

    # Em BMPString e UniversalString, `:public_key` entrega caractere acima
    # de 255 como quádrupla {grupo, plano, linha, célula}.
    for {type, value, rendered} <- [
          {:printableString, ~c"AC Teste", "AC Teste"},
          {:teletexString, [?S, 0xE3, ?o], "São"},
          {:bmpString, [?S, 0xE3, ?o, ?\s, {0, 0, 0x4E, 0x2D}], "São 中"},
          {:universalString, [?S, 0xE3, ?o, ?\s, {0, 0, 0x4E, 0x2D}, {0, 1, 0xD1, 0x1E}],
           "São 中𝄞"}
        ] do
      test "#{type} assina e verifica", ca do
        certificate_der =
          certificate_with_issuer(ca, [
            {@organization, {unquote(type), unquote(Macro.escape(value))}}
          ])

        assert {"O=" <> unquote(rendered), _serial} = Signer.issuer_and_serial(certificate_der)

        signature_xml =
          Signer.sign(app_hdr_xml(), document_xml(), ca.private_key_der, certificate_der)

        envelope = assemble_envelope(app_hdr_xml(), document_xml(), signature_xml)

        assert Verifier.verify(envelope, certificate_der) == :ok
      end
    end
  end

  defp pkcs8(rsa_private_key_der) do
    :public_key.der_encode(
      :PrivateKeyInfo,
      :public_key.der_decode(:RSAPrivateKey, rsa_private_key_der)
    )
  end

  # O certificado do TestCA com emissor e titular trocados, assinado de
  # novo pela mesma chave: o jeito mais curto de ter na mão um certificado
  # com o tipo de DirectoryString que se quer testar.
  defp certificate_with_issuer(ca, attributes) do
    name =
      {:rdnSequence,
       Enum.map(attributes, fn {oid, value} -> [{:AttributeTypeAndValue, oid, value}] end)}

    ca.certificate_der
    |> :public_key.pkix_decode_cert(:otp)
    |> otp_certificate(:tbsCertificate)
    |> otp_tbs_certificate(issuer: name, subject: name)
    |> :public_key.pkix_sign(:public_key.der_decode(:RSAPrivateKey, ca.private_key_der))
  end
end
