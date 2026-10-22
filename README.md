# Isox

[![CI](https://github.com/openspb/isox/actions/workflows/ci.yml/badge.svg)](https://github.com/openspb/isox/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/isox.svg)](https://hex.pm/packages/isox)
[![Documentation](https://img.shields.io/badge/hexdocs-online-purple.svg)](https://hexdocs.pm/isox)
[![License](https://img.shields.io/hexpm/l/isox.svg)](LICENSE)

Codec ISO 20022 para o catálogo de mensagens do SPI (Pix, Banco Central do
Brasil), com `encode/2` e `decode/1` genéricos por envelope (cabeçalho mais
mensagem), um dicionário que diz o que cada campo de cada mensagem quer
dizer, e um módulo separado de assinatura XMLDSig no perfil do Manual de
Segurança do SFN.

A lib cuida só do formato das mensagens. Ela não conhece transporte nem
regra de negócio de quem a usa.

## Instalação

```elixir
def deps do
  [
    {:isox, "~> 0.1.0"}
  ]
end
```

## Uso

Toda mensagem do catálogo viaja com um cabeçalho comum (`Isox.AppHdr`). Os
dois juntos formam um `Isox.Envelope`, que é a entrada de `Isox.encode/2` e
a saída de `Isox.decode/1`.

```elixir
# Truncar pra milissegundo importa: é a precisão que o XML carrega de volta.
# Sem truncar, o valor devolvido por decode/1 não é `==` ao original.
header = %Isox.AppHdr{
  from_ispb: "11111111",
  to_ispb: "22222222",
  biz_msg_idr: "M123456780123456789abcdefghijklm",
  created_at: DateTime.utc_now() |> DateTime.truncate(:millisecond)
}

mensagem = %Isox.Pacs008{
  msg_id: "M123456780123456789abcdefghijklm",
  created_at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
  svc_lvl_prtry: "PAGPRI",
  end_to_end_id: "E11111111202609121030abcdefghijk",
  value: "150.00",
  accptnc_dt_tm: DateTime.utc_now() |> DateTime.truncate(:millisecond),
  lcl_instrm: "MANU",
  dbtr_name: "Fulano de Tal",
  dbtr_cpf_cnpj: "12345678901",
  dbtr_acct_id: "00012345",
  dbtr_agt_ispb: "11111111",
  cdtr_cpf_cnpj: "12345678000199",
  cdtr_acct_id: "00098765",
  cdtr_agt_ispb: "22222222",
  purp_cd: "IPAY"
}

envelope = %Isox.Envelope{header: header, message: mensagem}

{:ok, xml} = Isox.encode(envelope, :v1_16)
{:ok, %Isox.Envelope{message: ^mensagem}, :v1_16} = Isox.decode(xml)
```

`Isox.decode/1` descobre o tipo da mensagem e a versão do schema pelo
namespace do XML, então você não precisa saber de antemão o que está
chegando.

Quando o tipo já é conhecido, cada mensagem tem seu módulo de baixo nível,
com a mesma forma de API e sem o despacho automático:

```elixir
{:ok, xml} = Isox.Pacs008.encode(mensagem, header, :v1_16)
{:ok, ^mensagem, :v1_16} = Isox.Pacs008.decode(xml)
```

Mensagens cobertas: `Admi002`, `Admi004`, `Camt014`, `Camt025`, `Camt029`,
`Camt052`, `Camt053`, `Camt054`, `Camt055`, `Camt060`, `Pacs002`,
`Pacs004`, `Pacs008`, `Pain009`, `Pain011`, `Pain012`, `Pain013`,
`Pain014`, `Pibr001`, `Pibr002`, `Reda014`, `Reda016`, `Reda017`,
`Reda022`, `Reda031`, `Reda041`, `Trck002`.

### Lote

Onze mensagens aceitam várias transações num XML só, porque o elemento de
transação é `max: ilimitado` no XSD: `Pacs002`, `Pacs004`, `Pacs008`,
`Camt052`, `Camt053`, `Camt054`, `Pain009`, `Pain012`, `Pain013`,
`Pain014` e `Trck002`.

`encode/3` aceita uma mensagem ou uma lista. `decode/1` devolve uma struct
ou uma lista, conforme o que o XML trouxer. É a mesma função nos dois
casos, sem API paralela:

```elixir
# enviando um lote de 2 devoluções (pacs.004)
{:ok, xml} = Isox.Pacs004.encode([devolucao1, devolucao2], header, :v1_5)

# recebendo: decode devolve lista quando o XML trouxer mais de 1 item
{:ok, [d1, d2], :v1_5} = Isox.Pacs004.decode(xml)

# 1 mensagem continua funcionando igual, sem lista
{:ok, xml} = Isox.Pacs004.encode(devolucao1, header, :v1_5)
{:ok, ^devolucao1, :v1_5} = Isox.Pacs004.decode(xml)
```

Campos de `GrpHdr` como `msg_id` e `created_at` são únicos por XML, não por
transação. Em lote, `encode/3` confere que todos os itens da lista
concordam nesses campos e devolve erro se divergirem, em vez de usar o
primeiro e ignorar o resto em silêncio.

## O que cada campo quer dizer

Integrar com o SPI é passar o dia com a planilha do catálogo aberta do lado
do editor para descobrir que `dbtr_acct_id` é a conta do pagador. O
`Isox.Dictionary` traz essa informação para dentro do código.

```elixir
iex> Isox.Pacs008 |> Isox.explain(:dbtr_acct_id) |> IO.puts()
Campo            Isox.Pacs008.dbtr_acct_id
Nome no catálogo contaUsuarioPagador
Caminho XML      FIToFICstmrCdtTrf/CdtTrfTxInf/DbtrAcct/Id/Othr/Id
Tipo             texto, até 20 caracteres
Obrigatório      sim
O que é          Número da conta de onde o dinheiro sai, como o PSP do pagador a identifica.
```

`Nome no catálogo` é a chave de busca: é por ele que se acha o campo em
qualquer documento oficial do Pix.

Campo de domínio traz os valores aceitos, com o significado de cada um:

```elixir
{:ok, codigos} = Isox.Dictionary.codes(Isox.Pacs008, :purp_cd)
codigos["GSCB"]
#=> "Pix Troco: compra com saque de dinheiro em espécie no mesmo pagamento."
```

Quando você não sabe em que mensagem o campo está, procure por qualquer
termo. A busca ignora acento e caixa:

```elixir
Isox.search("chave pix") |> Enum.map(fn {mensagem, campo} -> {mensagem, campo.field} end)
#=> [
#=>   {Isox.Camt054, :cdtr_acct_proxy},
#=>   {Isox.Pacs008, :cdtr_acct_proxy},
#=>   {Isox.Trck002, :lcl_instrm},
#=>   {Isox.Trck002, :cdtr_acct_proxy}
#=> ]
```

`Isox.fields/1` devolve a mensagem inteira como dado, útil para montar
formulário ou validação do seu lado. A documentação de cada mensagem traz a
mesma informação em tabela, gerada a partir do mesmo dicionário.

As descrições saem dos documentos que o Banco Central publica (XSD, planilha
do catálogo e manuais do Pix), reescritas aqui. O catálogo continua sendo a
fonte normativa: em caso de divergência, quem manda é o documento oficial.

## Assinatura digital

Implementa o perfil do Manual de Segurança do SFN Vol. II §3:
canonicalização XML exclusiva, RSA-SHA256 e as três `<ds:Reference>`
(`KeyInfo`, `AppHdr` com transformação enveloped-signature e `Document` sem
atributo `URI`).

```elixir
# app_hdr_xml e document_xml precisam vir já em forma canônica exclusiva.
# sign/4 não canonicaliza: isso é responsabilidade de quem chama.
signature_xml = Isox.sign(app_hdr_xml, document_xml, minha_chave_privada_der, meu_certificado_der)

:ok = Isox.verify(envelope_recebido_xml, certificado_de_quem_assinou_der)
```

Para controle mais fino, como montar um perfil com outro número de
`<ds:Reference>`, use `Isox.Xmldsig.Signer` e `Isox.Xmldsig.Verifier`
direto.

### Certificados

Assinar e verificar usam chaves de lados opostos da conversa. Você assina
com a sua chave privada e o seu certificado. Você verifica com o
certificado público de quem assinou, nunca com o seu.

Na prática, um PSP guarda a própria chave privada para assinar e o
certificado público do Bacen para verificar as respostas dele. Quem simula
o Bacen faz o espelho disso.

Para testar localmente, gere um par para cada lado:

```elixir
psp = Isox.generate_test_certificate()

signature_xml = Isox.sign(app_hdr_xml, document_xml, psp.private_key_der, psp.certificate_der)

# quem recebe verifica com o certificado do PSP, não com o próprio
:ok = Isox.verify(envelope_xml, psp.certificate_der)
```

`Isox.generate_test_certificate/0` gera tudo em memória e serve só para
teste.

Em produção, chave privada não entra em código nem em variável de ambiente
em texto puro. O padrão comum é guardar caminhos de arquivo `.pem` em
config e decodificar para DER na sua aplicação. Esta lib de propósito não
lê arquivo, env nem config: ela só recebe bytes.

Para medir o throughput local de assinatura e verificação:

```bash
MIX_ENV=test mix xmldsig.spike
```

## Gerando o codec a partir dos XSDs

Os XSDs publicados pelo Banco Central não são redistribuídos aqui. Para
gerar ou regenerar o codec a partir deles:

```bash
mix catalog.gen --xsd-dir /caminho/para/xsd --out lib/isox/generated
```

## Desenvolvimento

```bash
mix deps.get
mix precommit   # compila com warning como erro, formata, credo --strict, testes
mix dialyzer    # análise estática, mais lenta, fora do precommit
mix docs        # gera a documentação em doc/
```

Os testes de round-trip contra os exemplos oficiais do catálogo precisam da
variável `CATALOGO_SPI_DIR` apontando para um diretório local com os XSDs e
exemplos. Sem ela, essa suíte é pulada.

## Licença

[MIT](LICENSE).
