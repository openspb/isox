# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
este projeto segue [versionamento semântico](https://semver.org/lang/pt-BR/).

## [0.2.0] - 2026-09-14

### Adicionado

- `Isox.Dictionary`: o que cada campo de cada mensagem quer dizer, para as
  28 structs da lib (308 campos). Cada entrada amarra o nome do campo aqui,
  o nome que o Banco Central dá a ele na planilha do catálogo (`name_br`),
  o caminho dentro do XML, tipo, tamanho, obrigatoriedade, descrição,
  regra de preenchimento e, quando é campo de domínio, os valores aceitos
  com o significado de cada um.

  A informação sai de três formas, todas da mesma fonte: como dado, em
  `fields/1` e `field/2`; como texto para o IEx, em `explain/2`; e como
  tabela na documentação de cada mensagem, montada em tempo de compilação
  por `doc/1`. Descrição que mora em dois lugares diverge, e a que diverge
  é sempre a que alguém vai ler.

  `search/1` procura um termo em todas as mensagens, ignorando acento e
  caixa. `codes/2` devolve o domínio de um campo, incluindo as tabelas de
  rejeição mais consultadas: os 45 códigos do `pacs.002`, os 23 da
  `pain.012`, os 20 da `pain.014`, os 15 da `reda.016`.

  As descrições são escritas aqui, a partir dos documentos que o BCB
  publica (XSD, planilha do catálogo e manuais), não copiadas deles. O
  catálogo continua sendo a fonte normativa.

- `Isox.explain/2`, `Isox.fields/1` e `Isox.search/1` como atalho para o
  dicionário, no módulo principal.

### Modificado

- Documentação revisada de ponta a ponta. As moduledocs das 28 mensagens
  foram reescritas: começam dizendo o que a mensagem é e onde ela entra no
  fluxo, antes das particularidades de schema, e cada uma agora termina com
  a tabela de campos e a lista de domínios.

- Nenhum travessão em texto nenhum do projeto, com teste que falha se um
  voltar (`Isox.EstiloTest`).

### Corrigido

- `Isox.AppHdr`: a moduledoc dizia que a assinatura estava "ainda não
  implementada". Está, desde a 0.1.0, em `Isox.Xmldsig`.

- Documentado que a planilha HEAD001 do catálogo troca os nomes de
  `BizMsgIdr` e `MsgDefIdr` entre si (chama o primeiro de `tipoMensagem` e
  o segundo de `idMensagem`). O XSD e os exemplos oficiais deixam claro que
  é o contrário. O dicionário registra o que acontece de verdade.

## [0.1.0] - 2026-09-13

Primeira versão pública.

### Adicionado

- Suporte real a lote (`encode/3` aceita 1 mensagem ou uma lista;
  `decode/1` devolve 1 struct ou uma lista, dependendo de quantos itens
  o XML traz) nas 11 mensagens cujo elemento de transação é
  `max: ilimitado` no XSD: `Pacs002`, `Pacs004`, `Pacs008`, `Camt052`,
  `Camt053`, `Camt054`, `Pain009`, `Pain012`, `Pain013`, `Pain014`,
  `Trck002`. Antes, mais de 1 transação virava
  `{:error, {:unsupported_batch, n}}` (issue #47). Agora é suportado de
  verdade, dos dois lados (enviar e receber), sem API paralela: a mesma
  `encode/3`/`decode/1`, só que polimórfica.
- `Isox.encode/2` e `Isox.decode/1`: API genérica por `Isox.Envelope`
  (cabeçalho + modelo da mensagem), que despacha pelo tipo do modelo
  (`encode/2`) ou pelo namespace do XML (`decode/1`). Não precisa mais
  saber de antemão qual mensagem está sendo codificada ou decodificada.
- Codec `encode/3`/`decode/1` tipado por mensagem, de baixo nível, para
  as mensagens do catálogo do SPI: `Admi002`, `Admi004`, `Camt014`,
  `Camt025`, `Camt029`, `Camt052`, `Camt053`, `Camt054`, `Camt055`,
  `Camt060`, `Pacs002`, `Pacs004`, `Pacs008`, `Pain009`, `Pain011`,
  `Pain012`, `Pain013`, `Pain014`, `Pibr001`, `Pibr002`, `Reda014`,
  `Reda016`, `Reda017`, `Reda022`, `Reda031`, `Reda041`, `Trck002`.
- `Isox.Registry` para descobrir o módulo certo a partir do
  namespace de um XML de entrada, quando o tipo da mensagem não é
  conhecido de antemão (usado por `Isox.decode/1` por baixo).
- `mix catalog.gen`: gera o codec de cada mensagem a partir dos XSDs
  publicados pelo Banco Central (não redistribuídos neste pacote).
- `Isox.Xmldsig`: canonicalização XML exclusiva
  (`xml-exc-c14n#`), assinatura e verificação RSA-SHA256 no perfil do
  Manual de Segurança do SFN Vol. II (três `<ds:Reference>`: `KeyInfo`,
  `AppHdr`, `Document`), com `KeyInfo` por `X509IssuerSerial`.
  `Isox.Xmldsig.TestCA` para gerar certificados de teste em
  memória.
- `mix xmldsig.spike`: mede o throughput local de assinar/verificar.

### Corrigido

- `Trck002`: nada validava 3 regras da planilha do catálogo (BCB) que o
  XSD sozinho não expressa (o mesmo enum de 5 opções é reusado pra
  conta devedora e credora, e `Prxy`/`InstrId` são apenas opcionais na
  estrutura, sem condição nenhuma):
  - `cdtr_acct_proxy` (chave Pix): obrigatório quando `lcl_instrm` é
    `"DICT"`/`"QRDN"`/`"QRES"`/`"APDN"`/`"APES"`/`"INIC"`, proibido
    quando é `"MANU"`/`"AUTO"`. Dava pra montar uma transação `QRDN`
    sem chave nenhuma, ou uma `MANU` carregando uma chave Pix que não
    devia existir, sem erro algum. O próprio teste do módulo tinha essa
    segunda combinação inconsistente (`InstrId` + `cdtr_acct_proxy`
    junto com `lcl_instrm = "MANU"`) sem ninguém notar, impossível na
    prática, já que devolução (que exige `MANU`) e chave Pix
    (proibida em `MANU`) se excluem mutuamente.
  - `cdtr_acct_type` nunca pode ser `"SLRY"` (Conta-Salário não recebe
    pagamentos). O XSD permite porque reusa o mesmo enum de tipo de
    conta pros dois lados.
  - `instr_id` presente (transação de devolução, análoga a uma
    `Pacs004`) exige `lcl_instrm == "MANU"`.

  `encode/3` agora valida as 3, confirmado pelo único exemplo oficial
  do BCB (idêntico em ambas as versões do catálogo). Achado no deep
  dive de validação do catálogo (issue #63, trck.002), última das 27
  mensagens do catálogo revisadas.


- `Reda041`: a moduledoc dizia que `Rcrd.Othr` era `max: ilimitado`,
  mas o schema real da BCB limita a `[1..3]` (`maxOccurs="3"`, sem
  `minOccurs` declarado, logo `1` implícito), consistente com só existirem
  3 códigos possíveis de campo alterado (`FldNm`: `MODP`/`NOME`/`NOMR`)
  na tabela de domínios. O comportamento em si já estava certo, porque o
  motor (fix da issue #50) já rejeita 0 ou mais de 3 alterações via
  `confirm/2`. Só a documentação estava errada. Reforçada cobertura de
  teste pros dois limites. Achado no deep dive de validação do catálogo
  (issue #62, reda.041).


- `Reda022`: a moduledoc dizia que `Mod` era `max: ilimitado`, mas o
  schema real da BCB exige exatamente 4 (`minOccurs="4"
  maxOccurs="4"`): sempre as 4 modificações juntas (contato, diretor,
  endereço técnico, CPF do diretor), nunca um subconjunto, confirmado
  pelo único exemplo oficial do catálogo. `encode/3` agora valida essa
  composição exata (4 itens, um de cada tipo) com mensagem clara, em
  vez de deixar o `confirm/2` (round-trip) rejeitar com um erro de XML
  de baixo nível. Também corrigido: `Rspnsblty` é fixo por tipo
  (`"CONTATOPSP"` em `:contact`, `"DIRETORPSP"` em `:director`,
  conforme a planilha do catálogo), mas nada garantia que o valor
  certo fosse usado no ramo certo, porque o schema só valida que é um dos 2
  valores do enum, não a correspondência com o tipo; dava pra montar,
  por exemplo, um `:contact` com `"DIRETORPSP"` sem erro nenhum. Agora
  `encode/3` valida essa correspondência também. Achado no deep dive de
  validação do catálogo (issue #60, reda.022).


- `Reda016`: nada validava a regra cruzada entre `sts`, `rsn_prtry` e
  `sys_pty_ispb`. Dava pra montar um `"COMP"` (sucesso) sem
  `SysPtyId` (mesmo a planilha do catálogo exigindo explicitamente:
  "devem ser preenchidos caso Status seja 'COMP'") ou carregando um
  motivo de erro sobrando, ou um `"QUED"`/`"REJT"` sem motivo, sem erro
  nenhum. O próprio teste do módulo tinha essa combinação inconsistente
  (`"COMP"` sem `SysPtyId`) sem ninguém notar. A moduledoc também só
  mencionava 2 dos 3 status reais (`Status6Code` tem `COMP`/`QUED`/
  `REJT`. `QUED`, fila e pendência, usa motivo igual `REJT`, confirmado
  pelo exemplo oficial). `encode/3` agora valida tudo isso, confirmado
  pelos 3 exemplos oficiais do BCB (2 por versão do catálogo, XSD
  idêntico). Também corrigido: `rspnsbl_pty_ispb` preenchido sem
  `sys_pty_ispb` era descartado silenciosamente no encode (o elemento
  contêiner `SysPtyId` só é emitido quando `sys_pty_ispb` existe), e
  agora é rejeitado explicitamente em vez de perder o dado calado.
  Achado no deep dive de validação do catálogo (issue #58, reda.016).


- `Pain014`: nada validava a regra cruzada da planilha do catálogo
  entre `tx_sts` e `rsn_prtry`. Dava pra montar um `ACSP` (aceite) com
  motivo sobrando, ou um `RJCT` (rejeição) sem motivo nenhum, sem erro
  algum. `encode/3` agora valida: `ACSP` exige `rsn_prtry` ausente,
  `RJCT` exige `rsn_prtry` presente, confirmado pelos 4 exemplos
  oficiais do BCB (2 por versão do catálogo). Achado no deep dive de
  validação do catálogo (issue #54, pain.014).


- `Pain013`: o bloco `Tax` (divisão de tributos IBS e CBS, o Split
  Payment da reforma tributária) era completamente ignorado. `decode/1`
  descartava silenciosamente os dados de tributo de qualquer XML real
  que os trouxesse (sem erro nenhum), e `encode/3` não tinha como
  montá-los. Confirmado com o exemplo oficial novo do BCB introduzido
  no catálogo v5.13.1 (`pain.013_SplitPayment.xml`), que só decodificava
  com perda de dado. Agora `tax_ref_nb`/`tax_records` fazem parte da
  struct, com as regras da planilha do catálogo validadas em
  `encode/3`: o bloco só é permitido quando `dbtr_cpf_cnpj` é CNPJ (14
  caracteres); cada tipo de tributo presente precisa de um `Record`
  `ctgy: "INF"`; e a soma dos valores efetivos (`COR` tem prioridade
  sobre `INF` quando ambos existem) não pode exceder `value`. Também
  nada validava a regra cruzada entre `ReqdExctnDt` e `Purp/Prtry`:
  obrigatório quando `"AGND"`, proibido quando `"NTAG"`/`"RIFL"`,
  confirmada nos 4 exemplos oficiais do BCB para esta mensagem, sem
  exceção (o próprio teste do módulo tinha essa combinação
  inconsistente sem ninguém notar). Achado no deep dive de validação do
  catálogo (issue #53, pain.013).


- `Pain012`: nada validava a regra cruzada da planilha do catálogo
  entre `accptd`, `rjct_rsn_prtry`, `mndt_sts` e `mndt_prcg_dtls`.
  dava pra montar uma resposta de aceite sem `mndt_sts` (obrigatório
  pela planilha quando `accptd = "true"`), ou uma rejeição carregando
  `mndt_sts`/`mndt_prcg_dtls` (que a planilha diz que não devem ser
  preenchidos quando `accptd = "false"`), sem erro nenhum. O próprio
  teste do módulo tinha essa combinação inconsistente (aceite sem
  nenhum dado de `SplmtryData`) sem ninguém notar. `encode/3` agora
  valida isso explicitamente, confirmado pelos 12 exemplos oficiais do
  BCB pra esta mensagem, sem exceção. Achado no deep dive de validação
  do catálogo (issue #52, pain.012).

- `xs:boolean` (`TrckgInd`/`DtAdjstmntRuleInd`, usados em `Pain009`,
  `Pain011`, `Pain012`) não tinha validação nenhuma, mesma causa raiz
  do `xs:date` (issue #47): o XSD desses campos não declara `pattern`
  nenhum, confiando na validação léxica embutida do tipo, que o motor
  não implementava. Qualquer string passava como boolean válido, tanto
  no parse quanto no build (XML inválido saía sem erro nenhum).
  O motor (Isox.Xml.Codec, módulo interno) agora valida contra as 4
  representações léxicas válidas de `xs:boolean`
  (`true`/`false`/`1`/`0`). Achado no deep dive de validação do
  catálogo (issue #50, pain.009).
- Elemento repetido com `maxOccurs` numérico maior que 1 (ex.:
  `MndtPrcgDtls` do `Pain009`, `minOccurs="3" maxOccurs="3"`) só tinha o
  mínimo validado. O máximo nunca era checado, então mais itens do que
  o schema permite passava reto pelo parse (e pelo round-trip de
  `confirm/2`, que usa o mesmo parse). O motor (Isox.Xml.Codec) agora
  rejeita contagem acima do máximo declarado. Achado no mesmo deep dive
  (issue #50, pain.009). Também afeta `Pain011` (`MndtPrcgDtls`,
  `maxOccurs="2"`).

- `Camt060`: `RptgPrd` (período do relatório) sempre incluía `FrToTm`
  (horário) mesmo sem `rptg_prd_fr_tm`/`rptg_prd_to_tm` informados,
  produzindo um `<FrToTm></FrToTm>` vazio que violava o schema. Mas
  `FrToTm` é independentemente opcional (`minOccurs="0"`, separado de
  `FrToDt`), usado só em consulta de relação de lançamentos.
  Consultas de saldo de dia anterior, de remuneração da Conta PI, ou de
  arquivo `TRD`/`TRT` usam só data, sem horário, e 3 dos 7 exemplos
  oficiais do BCB para esta mensagem são exatamente esse caso, e
  ficavam impossíveis de montar (`encode/3` errava com "elemento
  obrigatório ausente: FrTm"). `FrToTm` agora só entra quando os campos
  de horário são realmente informados (e os dois precisam vir juntos).
  Achado no deep dive de validação do catálogo (issue #46, camt.060).

- `Camt029`: nada validava a regra cruzada da planilha do catálogo
  entre `pmt_inf_cxl_sts`, `rsn_prtry` e `cxl_prcg_tp`. Dava pra montar
  um `RJCR` (rejeição) sem motivo nenhum, ou uma combinação `ACCR`
  (aceite) com motivo sobrando, ou `cxl_prcg_tp` inconsistente com o
  status, tudo sem nenhum erro (o próprio teste do módulo tinha essa
  combinação inconsistente sem ninguém notar). `encode/3` agora valida
  explicitamente: `ACCR` exige `rsn_prtry` ausente e `cxl_prcg_tp ==
  "DHAC"`; `RJCR` exige `rsn_prtry` presente e `cxl_prcg_tp == "DHRC"`,
  confirmado pelos 4 exemplos oficiais do BCB (2 por versão do
  catálogo). Achado no deep dive de validação do catálogo (issue #41,
  camt.029).

- `Camt025`: `StsRsn.AddtlInf` (opcional) estava sendo tratado como
  incondicional e `StsRsn.Rsn` (obrigatório no schema sempre que
  `StsRsn` aparece) como condicional, o inverso do XSD real. Na prática
  só se manifestava com `addtl_inf` presente e `rsn_prtry` ausente:
  virava um erro confuso de round-trip (`"elemento obrigatório ausente:
  Rsn"`) em vez de uma mensagem clara. `encode/3` agora valida isso
  explicitamente antes de montar o XML. Achado no deep dive de validação
  do catálogo (issue #40, camt.025).

- Validação de valor decimal (`fractionDigits`/`totalDigits`/`minInclusive`/
  `maxInclusive` do XSD, ex.: `ActiveCurrencyAndAmount_SimpleType`): não
  existia. Um valor monetário negativo, com casas decimais a mais, com
  mais dígitos que o permitido, ou nem sequer numérico (`"abc"`) passava
  reto pelo `encode/3` de qualquer mensagem com campo de valor (`Pacs008`,
  `Pacs004`, `Camt053`, `Camt054`, `Pain009/011/012/013`, `Trck002`, entre
  outras). Achado no deep dive de validação do catálogo (issue #49).
- `xs:date` sem `pattern` no XSD (ex.: `OrgnlTxRef/IntrBkSttlmDt` do
  `Pacs002`): um valor não-data crashava (`ArgumentError`) em vez de
  devolver erro. O motor não validava `xs:date` de jeito nenhum quando
  o XSD não declarava pattern, e o crash acontecia fora da zona
  protegida do `parse/2`, direto em quem chama `decode/1`.
- Elemento repetido (`max: ilimitado`) que o modelo assume como exatamente
  1 (`TxInfAndSts` do `Pacs002`, `TxInf` do `Pacs004`, `CdtTrfTxInf` do
  `Pacs008`, e outros 8: `Camt052/053/054`, `Pain009/012/013/014`,
  `Trck002`): uma mensagem com mais de um item crashava (`MatchError`) em
  vez de devolver erro, confirmado com exemplos oficiais do BCB que vêm
  em lote (`pacs.002_SPI_10_msg.xml`, `pacs.004_SPI_10_msg.xml`,
  `pacs.008_CONTA_10_msg.xml`, entre outros). `decode/1` agora devolve
  `{:error, {:unsupported_batch, contagem}}` nesses 11 módulos. Não
  passou a suportar lote, só parou de crashar por causa dele. Achado no
  deep dive de validação do catálogo (issue #47, pacs.002).

[0.2.0]: https://github.com/openspb/isox/releases/tag/v0.2.0
[0.1.0]: https://github.com/openspb/isox/releases/tag/v0.1.0
