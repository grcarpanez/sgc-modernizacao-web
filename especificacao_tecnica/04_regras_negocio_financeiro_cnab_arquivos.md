# 04 — Regras de Negócio Financeiras, Fórmulas, CNAB 240 e Layouts Posicionais de Arquivos

> **Origem da Engenharia Reversa:** Análise instrução a instrução (x86/x87 FPU) das units `02_ULib.c`, `16_UAdesao.c`, `17_UCarne.c`, `21_URecuperaArquivo.c`, `24_UBoletoBancario.c`, `26_UBaixaManual.c`, `27_UBaixaAutomatica.c`, `28_UCancelamento.c`, `29_UsegundaVia.c`, `30_Udiagnostico.c` e `34_UArquivoRemessa.c`. Todas as larguras posicionais abaixo foram conferidas contra os buffers reais `PadLeftZero`, `PadRightSpace`, `LStrCatN` e `WriteLn` do binário.

---

## 1. Algoritmos Utilitários Centrais e Criptografia Legada

### 1.1 Ofuscação Legada de Senhas e Caminho do Banco (`ULib__fn_57f498`)
- **Onde é usada no legado:** Coluna `USUARIOS.SENHA` e chave de registro `HKCU\Software\FG\SGC\Caminho`.
- **Algoritmo Exato:** Toma a constante string `"Acadêmico"` em `Windows-1252`, soma os bytes de seus caracteres módulo 256 (`0x41+0x63+0x61+0x64+0xEA+0x6D+0x69+0x63+0x6F = 0x3C5 -> 0xC5 = 197`) e aplica **`byte XOR 0xC5`** caractere a caractere (operação simétrica/involutiva: cifrar = decifrar).
- **Instrução para o Novo Sistema Web:**
  - **JAMAIS** utilizar `XOR 0xC5` em produção.
  - Utilizar exclusivamente a função de decifragem durante o **ETL de migração inicial** (` Firebird -> PostgreSQL`) caso se deseje converter as senhas atuais diretamente para **Argon2id** (`memory=64MB, iterations=3, parallelism=4`) ou **BCrypt (`cost=12`)**, marcando `trocar_senha_proximo_login = TRUE` para todos os usuários migrados.

### 1.2 Agendador Quinzenal de Geração de Carnês (`ULib__fn_57eb08` — `EMPRESAS.DATA_ARQ`)
O sistema opera em janelas quinzenais ancoradas nos dias **`10`** e **`25`** de cada mês:
- Se `Dia(Hoje) < 10`: próxima `DATA_ARQ = 10/MM/AAAA` do mês corrente.
- Se `10 <= Dia(Hoje) <= 24`: avalia `25/MM/AAAA` (garantindo intervalo mínimo de 15 dias em relação à geração atual; caso contrário, avança para `10` do mês subsequente).
- Se `Dia(Hoje) >= 25`: próxima `DATA_ARQ = 10` do mês subsequente (`10/(MM+1)/AAAA`).

### 1.3 Validação de CPF e CNPJ (`ValidarCpfCnpj` — Módulo 11)
- Remove pontuação (`SomenteNumeros`).
- **CPF (11 dígitos):** Calcula $DV_1$ com pesos `10..2` sobre os 9 primeiros dígitos ($r = (\sum d_i \cdot p_i) \bmod 11$; se $r < 2 \Rightarrow 0$, senão $11 - r$) e $DV_2$ com pesos `11..2` sobre os 10 primeiros dígitos.
- **CNPJ (14 dígitos):** Calcula $DV_1$ com pesos `[5,4,3,2,9,8,7,6,5,4,3,2]` e $DV_2$ com pesos `[6,5,4,3,2,9,8,7,6,5,4,3,2]`.
- **Correção Obrigatória de Bug Legado:** O código legado não rejeitava sequências repetidas (`000.000.000-00`, `111.111.111-11`, ..., `999.999.999-99` e equivalentes de 14 dígitos), que passam matematicamente no Módulo 11.No sistema web:
  - **Em novos cadastros/edições e seleção CNAB 240:** rejeitar CPFs/CNPJs com todos os dígitos iguais (`/^(\d)\1+$/`).
  - **Na migração de dados legados:** importar todos os clientes históricos preservando o documento original e sinalizando `cpf_valido = false` para saneamento cadastral sem perda de histórico financeiro.

### 1.4 Cálculo do Dígito Verificador do Nosso Número Sicoob (`SicoobNossoNumeroDV` @ `0x5ae7f0`)
Para boletos registrados no **Banco Cooperativo do Brasil — Sicoob (`756`)**, o DV do Nosso Número utiliza **Módulo 11 com constante cíclica `3197`** sobre uma cadeia exata de **21 dígitos**:

$$\text{Base}_{21} = \underbrace{\text{PadLeftZero}(\text{AG\_BANCOB}, 4)}_{4\text{ dígitos}} \;\Vert\; \underbrace{\text{PadLeftZero}(\text{CODCED\_BANCOB}, 10)}_{10\text{ dígitos}} \;\Vert\; \underbrace{\text{PadLeftZero}(\text{NOSSONUMERO}, 7)}_{7\text{ dígitos}}$$

1. Multiplica-se cada dígito $b_k$ ($k = 1 \dots 21$, da esquerda para a direita) pelo peso correspondente da sequência repetida `[3, 1, 9, 7, 3, 1, 9, 7, 3, 1, 9, 7, 3, 1, 9, 7, 3, 1, 9, 7, 3]`:
   $$S = \sum_{k=1}^{21} b_k \cdot w_k, \quad R = S \bmod 11$$
2. Se $R = 0$ ou $R = 1$, então $\text{DV} = 0$; caso contrário, $\text{DV} = 11 - R$.
3. No Segmento `P` do CNAB 240 (posições `38..47`, 10 bytes), grava-se `PadLeftZero(NOSSONUMERO_7_digitos + DV_1_digito, 10)` (ex.: Nosso Número `185432` -> `7` dígitos `0185432` + DV `4` -> campo de 10 posições `"0001854324"`).
   > **Atenção:** Se `GEN_NOSSONUMERO_ID` ultrapassar `9.999.999` (7 dígitos), alertar ou ciclar faixa conforme manual Sicoob (no banco atual o contador está na casa de centenas de milhares, bem abaixo de `9.999.999`).

---

## 2. Regras Completas do Ciclo de Vida Financeiro

### 2.1 Emissão de Fichas de Adesão em Estoque (`TFrmAdesao` — `0x5937b0`)
1. Numeração de remessa própria das fichas de adesão:
   ```sql
   SELECT COALESCE(MAX(REMESSA), 0) + 1 FROM CARNE WHERE NUM_PARC = 1
   ```
2. Para cada uma das $Q$ fichas solicitadas:
   - Gera `ADESAO.NUMERO` via sequence `GEN_NUMERO_ID`.
   - Cria um registro em `CARNE` (`NUM_ADESAO = NUMERO`, `DATA = CURRENT_DATE`, `NUM_PARC = 1`, `REMESSA = rem`).
   - Cria a parcela de taxa de adesão em `PARCELAS`:
     - `NUM_CARNE = CARNE.NUMERO`
     - `NUM_ADESAO = ADESAO.NUMERO`
     - `ANOMES = '0000'` (identificador universal de **Taxa de Adesão**)
     - `ID_PARC = 'ADESÃO'`
     - `DTEM = CURRENT_DATE`
     - `DTVENC = NULL`, `VALOR = NULL`, `DTPAG = NULL`, `VALOR_PAGO = NULL`
     - `NOSSONUMERO = NEXTVAL(GEN_NOSSONUMERO_ID)`
3. Exporta `REMADESAO{rem:05d}.TXT` (250 bytes/linha) para impressão das fichas pré-numeradas.
4. **Regra de Liberação do 1º Carnê:** Um cliente PF recém-cadastrado **só entra na geração de carnês após a quitação da parcela `ANOMES = '0000'`** (`DTPAG IS NOT NULL`).

### 2.2 Elegibilidade e Cálculo de Carnês PF (`TFrmCarne` — `0x594698`)

#### A. Critérios Exatos de Elegibilidade de um Cliente PF (`CLIENTES`)
Um cliente PF recebe um novo carnê de 12 meses no lote se, e somente se, cumprir **todas** as condições abaixo:
1. `CLIENTES.SITUACAO = 'A'` (Ativo) e `CLIENTES.BANCO` corresponde ao banco selecionado (ou carteira Sicoob padrão `'2'`).
2. **Adesão Paga:** Existe registro em `PARCELAS` com `NUM_ADESAO = C.NUMERO AND ANOMES = '0000' AND DTPAG IS NOT NULL`.
3. **Sem Carnê Vigente a Vencer Longe / Pronto para Renovação:**
   - **Caso 1º Carnê:** O cliente ainda **não possui** nenhum registro em `CARNE` com `NUM_PARC = 12`.
   - **Caso Renovação:** O cliente já possui carnê anterior (`NUM_PARC = 12`), sua última parcela (`12/12`) vence dentro da janela de renovação (ou já venceu/quitou) e a quantidade de parcelas vencidas e não pagas (`DTPAG IS NULL AND DTVENC < CURRENT_DATE AND ID_PARC NOT IN ('ÚNICA')`) é **menor ou igual** ao parâmetro `edtParcelasEmAberto` (default `0`).

#### B. Reconciliação de `VALOR_PLANO` vs. Tabela de Preços Vigente (`0x594758..0x594a20`)
Seja:
- $V_{\text{tit}}$ = `Valor por titular (R$)` informado na tela (default `12,00`).
- $V_{\text{dep}}$ = `Valor por dependente (R$)` informado na tela (default `2,00`).
- $N_{\text{dep}}$ = quantidade de dependentes do cliente em `DEPENDENTES` (`COUNT(*) WHERE COD_CLIENTE = C.NUMERO`).
- $V_{\text{calc}} = V_{\text{tit}} + (N_{\text{dep}} \times V_{\text{dep}})$.

Se $V_{\text{calc}} \neq \text{CLIENTES.VALOR\_PLANO}$:
- No desktop legado, o sistema exibia caixa de diálogo (`Sim`, `Não`, `Sim para Todos`, `Não para Todos`, `Cancelar`) perguntando se desejava atualizar `CLIENTES.VALOR_PLANO` para $V_{\text{calc}}$.
- **Na aplicação Web Moderna:** Exibir na tela de **Simulação do Lote** uma opção de política para divergências:
  1. `Atualizar todos para a tabela vigente (V_calc)` *(padrão recomendado)*;
  2. `Manter valor individual negociado no cadastro do cliente (VALOR_PLANO)`;
  3. `Selecionar caso a caso na prévia`.

#### C. Fórmula Exata das 13 Parcelas do Carnê (`12` Mensais + `1` `ÚNICA` — `0x594a60..0x594f50`)
Para cada cliente elegível com mensalidade base $M$ e dia de vencimento $D = \text{CLIENTES.DIAVENC} \in [1..28]$:
1. Define-se a **Taxa de Manutenção Anual** $A$ *(chamada no legado de "Acréscimo de Renovação" / `ValorAcrescimo`, distinta da **Taxa de Adesão** na matrícula e da **Taxa de Reativação** no retorno de ex-cliente)*:
   - Se for o **1º carnê** do cliente (após Taxa de Adesão) ou **1º carnê pós-reativação** (após Taxa de Reativação): $A = 0,00$.
   - Se for **renovação** (a partir do 2º carnê PF): $A = \text{valor\_taxa\_manutencao\_anual}$ do plano (default `12,00` no legado), registrado na coluna `valor_taxa_manutencao_embutida` nas parcelas `'01/12'` e `'UNICA'` (**sem desconto** na cota única: $\text{UNICA} = (\text{mensalidade} \times 12 \times 0,80) + A$).
2. Determina-se o **1º vencimento ($V_1$)**:
   - Se for 1º carnê: menor data $D/\text{MM}/\text{AAAA} \ge \text{Data de Emissão}$ (se $D/\text{mês atual} < \text{Hoje}$, avança para o mês seguinte).
   - Se for renovação: mês imediatamente subsequente ao vencimento da parcela `12/12` do último carnê (ou mês corrente/seguinte se o carnê anterior já expirou no passado), sempre no dia $D$.
3. Cria-se `CARNE` com `NUM_ADESAO = C.NUMERO`, `DATA = Hoje`, `NUM_PARC = 12`, `REMESSA = novo_remessa_carne` (`COALESCE(MAX(REMESSA) WHERE NUM_PARC=12, 0) + 1`).
4. Geram-se **13 registros em `PARCELAS`** (todos com `NOSSONUMERO` individual via `GEN_NOSSONUMERO_ID`):

| Ordem | `ID_PARC` | `ANOMES` | `DTVENC` | Fórmula Exata de `VALOR` (confirmada em `0x594b00` e `0x594d48`) |
|---|---|---|---|---|
| Cota Anual | `'ÚNICA'` | `AA + '99'` (ano de $V_1$, ex.: `'2699'`) | $V_1$ (mesmo vencimento da `01/12`!) | $\text{VALOR}_{\text{ÚNICA}} = \text{ROUND}\!\left(\frac{12 \times M \times 8}{10} + A,\; 2\right) = (12 \times M \times 0,80) + A$ |
| 1ª Mensal | `'01/12'` | `AAMM` de $V_1$ (ex.: `'2605'`) | $V_1$ | $\text{VALOR}_{1} = M + A$ |
| 2ª..12ª Mensais | `'02/12'` .. `'12/12'` | `AAMM` de $V_k$ ($k=2\dots 12$) | $V_k = \text{AddMonths}(V_1, k-1)$ | $\text{VALOR}_{k} = M$ |

> **Exemplo Numérico Verificado:**
> - Titular com `2` dependentes ($V_{\text{tit}} = 12,00$, $V_{\text{dep}} = 2,00 \Rightarrow M = 16,00$), **Renovação** ($A = 12,00$), 1º vencimento em `10/05/2026`:
>   - `01/12` (`ANOMES = '2605'`, venc. `10/05/2026`): $16,00 + 12,00 =$ **R\$ 28,00**.
>   - `02/12` a `12/12` (`ANOMES = '2606'` a `'2704'`): **R\$ 16,00** cada.
>   - `ÚNICA` (`ANOMES = '2699'`, venc. `10/05/2026`): $(12 \times 16,00 \times 0,80) + 12,00 = 153,60 + 12,00 =$ **R\$ 165,60**.
> - No arquivo gráfico `REMESSA`, as parcelas são ordenadas por `ORDER BY DTVENC, VALOR DESC`, o que posiciona automaticamente a **`ÚNICA` (R\$ 165,60) na primeira lâmina do carnê**, seguida de `01/12` (R\$ 28,00) e `02/12..12/12` (R\$ 16,00)!

---

### 2.3 Faturamento Mensal Pessoa Jurídica (`TFrmBoletoBancario` — `0x5a2f34`)
1. Recebe competência `MM/AA` (`EMesAno`).
2. Percorre todas as empresas em `PESSOAJURIDICA` com `SITUACAO = 'A'`.
3. Verifica se já existe parcela para `NUM_ADESAO = PJ.NUMERO AND ANOMES = AAMM` (evita faturamento duplicado na mesma competência).
4. Calcula valor total da fatura mensal somando os planos dos funcionários vinculados:
   - **Query Legada (COM BUG):** `SELECT * FROM FUNCIONARIOSPESSOAJURIDICA WHERE CODIGOPESSOAJURIDICA = :pj_num` (somava todos, inclusive inativos!).
   - **Regra Corrigida no Novo Sistema Web:** Filtrar obrigatoriamente **`AND SITUACAO = 'A'`** (`SUM(VALOR_PLANO) WHERE CODIGOPESSOAJURIDICA = :pj_num AND SITUACAO = 'A'`). Se a soma for `0`, pular a empresa PJ.
5. Cria `CARNE` (`NUM_PARC = 1`, `DATA = Hoje`, `REMESSA = rem`) e `PARCELAS` (`ANOMES = AAMM`, `ID_PARC = '01/01'`, `DTEM = Hoje`, `DTVENC = PJ.DIAVENC/MM/20AA`, `VALOR = SomaAtivos`, `NOSSONUMERO = NEXTVAL`).
6. Emite `REMESSA{rem:07d}.TXT` (350 bytes/linha).

---

### 2.4 Consolidação de Inadimplência — Parcela `'DEBIT'` (`TfrmGerarRemessa.btnCalcularDebitosAgoraClick` — `0x5ac300`)
Quando o operador filtra inadimplentes com até $K$ parcelas vencidas em aberto (`DTPAG IS NULL AND DTVENC < CURRENT_DATE AND ID_PARC <> 'ÚNICA'`) e aciona a consolidação para um novo vencimento $V_{\text{novo}}$:
1. Soma o saldo em aberto das parcelas vencidas do cliente: $S_{\text{deb}} = \sum \text{VALOR}$.
2. **Baixa técnica por substituição** das parcelas originais atrasadas:
   - `DTPAG = CURRENT_DATE`
   - `VALOR_PAGO = 0,00`
   - `VALOR_COMP = 0,00`
   *(No PostgreSQL moderno, gravar também `situacao_parcela = 'CONSOLIDADA'` e vínculo à parcela destino para rastreabilidade contábil perfeita, preservando `VALOR_PAGO = 0` para não alterar a soma de caixa recebido).*
3. Cria um novo registro em `CARNE` (`NUM_PARC = 1`, `DATA = CURRENT_DATE`) e uma única parcela em `PARCELAS`:
   - `ANOMES = AA + '00'` (ex.: `'2600'`; se já existir `'2600'` no mesmo carnê, usa o novo `NUM_CARNE` da PK composta `(NUM_CARNE, NUM_ADESAO, ANOMES)`!)
   - `ID_PARC = 'DEBIT'`
   - `DTEM = CURRENT_DATE`
   - `DTVENC = V_novo`
   - `VALOR = S_deb`
   - `REGISTRADO = 'N'`
   - `NOSSONUMERO = NEXTVAL(GEN_NOSSONUMERO_ID)`

---

### 2.5 Regras de Baixa (Liquidação) e Cascata da Parcela `'ÚNICA'`

#### A. Regra Universal da Parcela `'ÚNICA'` (Manual, CNAB e Excel)
- **Ao liquidar uma parcela onde `ID_PARC = 'ÚNICA'` (ou `ANOMES LIKE '%99'`):**
  1. A parcela `'ÚNICA'` recebe `DTPAG = data_pagamento`, `VALOR_PAGO = valor_recebido`, `VALOR_COMP = tarifa_compensacao`.
  2. **Cascata Automática:** Todas as 12 parcelas mensais irmãs do **mesmo carnê** (`WHERE NUM_CARNE = :num_carne AND ID_PARC <> 'ÚNICA' AND DTPAG IS NULL`) são imediatamente atualizadas com:
     - `DTPAG = data_pagamento`
     - `VALOR_PAGO = 0.00`
     - `VALOR_COMP = 0.00`
     *(No PostgreSQL moderno: `situacao_parcela = 'QUITADA_POR_UNICA'`).*
- **Regra Inversa (Inadimplência e Contas a Receber):**
  - Parcelas com `ID_PARC = 'ÚNICA'` **NUNCA** entram no cálculo de inadimplência nem na soma de **Contas a Receber** (`WHERE ID_PARC <> 'ÚNICA'`), pois são uma opção facultativa de pagamento anual antecipado!

#### B. Baixa Manual e Estorno (`TFrmBaixaManual`)
- **Chave de Busca (`ENossoNum`):** Embora o rótulo diga `"Nosso Número"`, o código em `UBaixaManual` decompõe a string digitada $S$ (com tamanho $\ge 5$) em:
  - `ANOMES = Right(S, 4)` (últimos 4 caracteres)
  - `NUM_ADESAO = StrToInt(Left(S, Length(S) - 4))` (prefixo numérico)
  - Na versão web, suportar **ambos**: busca por `NUM_ADESAO + ANOMES` **e** busca direta por `PARCELAS.NOSSONUMERO`!
- **Liquidação Manual:** `VALOR_COMP = 0,00`, `VALOR LIQUIDO = VALOR_PAGO`. Se o título tinha `REGISTRADO = 'S'` no Sicoob, ele passa automaticamente a aparecer na aba **`Gerar Remessa Baixa`** (`chkPagos = true`: `VALOR_COMP = 0 AND DTPAG IS NOT NULL AND REGISTRADO = 'S'`) para envio do comando `'02'` (Pedido de Baixa) ao banco!

---

## 3. Especificação Byte a Byte dos Layouts de Arquivos (Base 1)

> **Convenções de Formatação:**
> - **Codificação nos arquivos legados de gráfica e CNAB:** `Windows-1252` (`ANSI` / `ISO-8859-1` sem BOM), terminador de linha **`CRLF` (`\r\n`)**.
> - `9(N)` / `PadLeftZero(N)`: Numérico alinhado à direita, preenchido com zeros `'0'` à esquerda; se o valor exceder `N`, trunca mantendo `N` caracteres. Valores monetários em centavos sem separador decimal (ex.: `R\$ 16,00` em `9(10)` -> `"0000001600"`).
> - `X(N)` / `PadRightSpace(N)`: Alfanumérico alinhado à esquerda, preenchido com espaços `' '` à direita; se exceder `N`, trunca nos primeiros `N` caracteres (`Copy(S, 1, N)`).

---

### 3.1 Arquivo de Fichas de Adesão — `REMADESAO{rem:05d}.TXT` (250 bytes/linha)

#### Registro `00` — Header (250 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"00"` |
| 3 | 20 | 18 | `X(18)` | `"REMADESAO" + PadLeftZero(rem, 5) + ".TXT"` (compõe `1..20` com `"00"`) |
| 21 | 28 | 8 | `9(8)` | Data de geração (`ddmmyyyy`) |
| 29 | 42 | 14 | `9(14)` | `SomenteNumeros(EMPRESAS.CNPJ_EMPRESA)` |
| 43 | 92 | 50 | `X(50)` | `EMPRESAS.NOME_EMPRESA` |
| 93 | 142 | 50 | `X(50)` | `EMPRESAS.ENDERECO` |
| 143 | 148 | 6 | `X(6)` | `EMPRESAS.END_NUMERO` |
| 149 | 168 | 20 | `X(20)` | `EMPRESAS.COMPLEMENTO` |
| 169 | 174 | 6 | `X(6)` | `EMPRESAS.BAIRRO` *(truncado em 6 posições)* |
| 175 | 183 | 9 | `X(9)` | `EMPRESAS.CEP` |
| 184 | 213 | 30 | `X(30)` | `EMPRESAS.CIDADE` |
| 214 | 215 | 2 | `X(2)` | `EMPRESAS.ESTADO` |
| 216 | 228 | 13 | `X(13)` | `EMPRESAS.TELEFONE_COMERCIAL` |
| 229 | 241 | 13 | `X(13)` | `EMPRESAS.TELEFONE_FAX` |
| 242 | 244 | 3 | `X(3)` | Filler espaços (`"   "`) |
| 245 | 250 | 6 | `9(6)` | Sequencial do registro = `"000001"` |

#### Registro `01` — Detalhe de Ficha de Adesão (250 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"01"` |
| 3 | 12 | 10 | `9(10)` | `PadLeftZero(ADESAO.NUMERO, 10)` |
| 13 | 16 | 4 | `9(4)` | Literal `"0000"` (`ANOMES` da taxa de adesão) |
| 17 | 244 | 228 | `X(228)` | Espaços em branco (ou metadados Sicoob na variante bancária + espaços totalizando 228) |
| 245 | 250 | 6 | `9(6)` | `PadLeftZero(sequencial_linha, 6)` (`000002` .. `N+1`) |

#### Registro `99` — Trailer (250 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"99"` |
| 3 | 8 | 6 | `9(6)` | `PadLeftZero(total_fichas_01, 6)` |
| 9 | 244 | 236 | `X(236)` | Espaços em branco |
| 245 | 250 | 6 | `9(6)` | `PadLeftZero(sequencial_final, 6)` (`total_fichas + 2`) |

---

### 3.2 Arquivo Gráfico de Carnês PF, Faturas PJ e 2ª Via — `REMESSA{rem:07d}_{banco}.TXT`, `SEG_VIA_CARNE.TXT`, `SEG_VIA_CARTÃO.TXT` (350 bytes/linha)

#### Registro `00` — Header (350 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 20 | 20 | `X(20)` | Carnê/PJ: `"00REMESSA" + PadLeftZero(rem, 7) + ".TXT"`<br>2ª Via Carnê: `"00SEG_VIA_CARNE .TXT"`<br>2ª Via Cartão: `"00SEG_VIA_CARTÃO.TXT"` |
| 21 | 28 | 8 | `9(8)` | Data de geração (`ddmmyyyy`) |
| 29 | 42 | 14 | `9(14)` | `PadLeftZero(SomenteNumeros(EMPRESAS.CNPJ_EMPRESA), 14)` |
| 43 | 92 | 50 | `X(50)` | `EMPRESAS.NOME_EMPRESA` |
| 93 | 142 | 50 | `X(50)` | `EMPRESAS.ENDERECO` |
| 143 | 148 | 6 | `X(6)` | `EMPRESAS.END_NUMERO` |
| 149 | 168 | 20 | `X(20)` | `EMPRESAS.COMPLEMENTO` |
| 169 | 174 | 6 | `X(6)` | `EMPRESAS.BAIRRO` *(peculiaridade legada: 6 chars)* |
| 175 | 183 | 9 | `X(9)` | `EMPRESAS.CEP` |
| 184 | 213 | 30 | `X(30)` | `EMPRESAS.CEP` *(bug legado confirmado em `0x595f3c` e `0x5a7e1d`: repete `CEP` em 30 colunas em vez de `BAIRRO` — **manter compatibilidade posicional para a gráfica**!)* |
| 214 | 243 | 30 | `X(30)` | `EMPRESAS.CIDADE` |
| 244 | 245 | 2 | `X(2)` | `EMPRESAS.ESTADO` |
| 246 | 258 | 13 | `X(13)` | `EMPRESAS.TELEFONE_COMERCIAL` |
| 259 | 271 | 13 | `X(13)` | `EMPRESAS.TELEFONE_FAX` |
| 272 | 344 | 73 | `X(73)` | **Modo Sicoob (`REMESSA` PF):** `"2"` (`272`) + `PadLeftZero(AG_BANCOB,4)` (`273..276`) + `PadLeftZero(CONTA_BANCOB,8)` (`277..284`) + `PadLeftZero(DVCONTA_BANCOB,1)` (`285`) + `PadLeftZero(CODCED_BANCOB,7)` (`286..292`) + `PadLeftZero(CARTEIRA_BANCOB,1)` (`293`) + `PadLeftZero(MODALIDADE_BANCOB,2)` (`294..295`) + `49 espaços` (`296..344`).<br>**Modo 2ª Via / Caixa:** `73 espaços`. |
| 345 | 350 | 6 | `9(6)` | `"000001"` |

#### Registro `01` — Titular PF / Empresa PJ (350 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"01"` |
| 3 | 12 | 10 | `9(10)` | `PadLeftZero(CLIENTES.NUMERO, 10)` |
| 13 | 22 | 10 | `9(10)` | `PadLeftZero(CARNE.NUMERO, 10)` *(em `SEG_VIA_CARTÃO`: `"0000000000"`)* |
| 23 | 24 | 2 | `9(2)` | `PadLeftZero(CARNE.NUM_PARC, 2)` *(em `SEG_VIA_CARTÃO`: `"00"`)* |
| 25 | 74 | 50 | `X(50)` | `NOME` (Titular PF ou Razão Social PJ) |
| 75 | 85 | 11 | `9(11)` | `PadLeftZero(SomenteNumeros(CPF), 11)` *(em PJ, `75..88` = CNPJ `9(14)` e `89..107` ajusta IE/espaços)* |
| 86 | 99 | 14 | `X(14)` | `RG` |
| 100 | 107 | 8 | `X(8)` | `FormatDateTime("ddmmyyyy", DATA_NASC)` |
| 108 | 157 | 50 | `X(50)` | `NOME_MAE` |
| 158 | 207 | 50 | `X(50)` | `ENDERECO` |
| 208 | 213 | 6 | `X(6)` | `END_NUMERO` |
| 214 | 233 | 20 | `X(20)` | `COMPLEMENTO` |
| 234 | 263 | 30 | `X(30)` | `BAIRRO` |
| 264 | 272 | 9 | `X(9)` | `PadRightSpace(SomenteNumeros(CEP), 9)` |
| 273 | 302 | 30 | `X(30)` | `CIDADE` |
| 303 | 304 | 2 | `X(2)` | `ESTADO` |
| 305 | 344 | 40 | `X(40)` | Em `REMESSA` / `SEG_VIA_CARNE`: `40 espaços`.<br>Em `SEG_VIA_CARTÃO` (`0x5a8278`): `PadLeftZero(CLIENTES.NUMERO, 10)` (`305..314`) + `30 espaços` (`315..344`). |
| 345 | 350 | 6 | `9(6)` | `PadLeftZero(sequencial_linha, 6)` |

#### Registro `02` — Dependente PF / Funcionário PJ / Dependente PJ (350 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"02"` |
| 3 | 12 | 10 | `9(10)` | `PadLeftZero(COD_CLIENTE, 10)` (PF: `NUMERO` do titular; PJ Funcionário: `PJ.NUMERO`; PJ Dependente: `CODIGOFUNC`) |
| 13 | 62 | 50 | `X(50)` | `NOME` do dependente (ou funcionário PJ) |
| 63 | 73 | 11 | `X(11)` | `PARENTESCO` *(para Funcionário PJ titular: literal `"TITULAR    "`)* |
| 74 | 81 | 8 | `X(8)` | `FormatDateTime("ddmmyyyy", DATA_NASC)` |
| 82 | 344 | 263 | `X(263)` | **Em `REMESSA` / `SEG_VIA_CARNE`:** `263 espaços`.<br>**Em `SEG_VIA_CARTÃO` (`0x5a84e1..0x5a865a`):** Dados do Titular para impressão no verso do cartão do dependente: `NOME_TITULAR` (`82..131`, 50) + `ENDERECO` (`132..181`, 50) + `END_NUMERO` (`182..187`, 6) + `COMPLEMENTO` (`188..207`, 20) + `BAIRRO` (`208..237`, 30) + `SomenteNumeros(CEP)` (`238..246`, 9) + `CIDADE` (`247..276`, 30) + `ESTADO` (`277..278`, 2) + `PadLeftZero(DEPENDENTES.CODIGO, 10)` (`279..288`, 10) + `56 espaços` (`289..344`, 56). |
| 345 | 350 | 6 | `9(6)` | `PadLeftZero(sequencial_linha, 6)` |

#### Registro `03` — Parcela / Lâmina de Pagamento (350 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"03"` |
| 3 | 12 | 10 | `9(10)` | `PadLeftZero(PARCELAS.NUM_ADESAO, 10)` |
| 13 | 16 | 4 | `9(4)` | `PadLeftZero(PARCELAS.ANOMES, 4)` |
| 17 | 26 | 10 | `9(10)` | `PadLeftZero(PARCELAS.NUM_CARNE, 10)` |
| 27 | 34 | 8 | `X(8)` | `FormatDateTime("ddmmyyyy", PARCELAS.DTEM)` |
| 35 | 42 | 8 | `X(8)` | `FormatDateTime("ddmmyyyy", PARCELAS.DTVENC)` |
| 43 | 52 | 10 | `9(8)V99` | `PadLeftZero(Round(PARCELAS.VALOR * 100), 10)` |
| 53 | 57 | 5 | `X(5)` | `PadLeftZero(PARCELAS.ID_PARC, 5)` (`"ÚNICA"`, `"01/12"`, `"DEBIT"`, `"01/01"`) |
| 58 | 67 | 10 | `9(10)` | `PadLeftZero(PARCELAS.NOSSONUMERO, 10)` |
| 68 | 344 | 277 | `X(277)` | Espaços em branco |
| 345 | 350 | 6 | `9(6)` | `PadLeftZero(sequencial_linha, 6)` |

#### Registro `99` — Trailer (350 bytes)
| Pos. Inicial | Pos. Final | Tam. | Formato | Conteúdo / Campo de Origem |
|---:|---:|---:|---|---|
| 1 | 2 | 2 | `X(2)` | Literal `"99"` |
| 3 | 8 | 6 | `9(6)` | `PadLeftZero(total_carnes_ou_cartoes, 6)` |
| 9 | 344 | 336 | `X(336)` | Espaços em branco |
| 345 | 350 | 6 | `9(6)` | `PadLeftZero(sequencial_final, 6)` |

---

### 3.3 CNAB 240 Sicoob (`756`) — Arquivo de Remessa Bancária (`UArquivoRemessa__fn_5aec24`, 240 bytes/linha)

Gerado em `TfrmGerarRemessa` tanto para **Entrada de Títulos (`Mov = '01'`)** quanto para **Pedido de Baixa (`Mov = '02'`)**:

#### Header de Arquivo (Tipo `0` — 240 bytes)
| Pos. | Tam. | Formato | Valor / Regra Exata |
|---|---:|---|---|
| `1..3` | 3 | `9(3)` | `"756"` (Banco Sicoob) |
| `4..7` | 4 | `9(4)` | `"0000"` |
| `8..8` | 1 | `9(1)` | `"0"` (Header de Arquivo) |
| `9..17` | 9 | `X(9)` | 9 espaços |
| `18..18` | 1 | `9(1)` | `"1"` se CPF (11 dígitos), `"2"` se CNPJ (14 dígitos) |
| `19..32` | 14 | `9(14)` | `PadLeftZero(SomenteNumeros(EMPRESAS.CNPJ_EMPRESA), 14)` |
| `33..52` | 20 | `X(20)` | 20 espaços (Convênio em branco no padrão Sicoob) |
| `53..57` | 5 | `9(5)` | `PadLeftZero(EMPRESAS.AG_BANCOB, 5)` |
| `58..58` | 1 | `X(1)` | `PadLeftZero(EMPRESAS.DVAG, 1)` |
| `59..70` | 12 | `9(12)` | `PadLeftZero(EMPRESAS.CONTA_BANCOB, 12)` |
| `71..71` | 1 | `X(1)` | `PadLeftZero(EMPRESAS.DVCONTA_BANCOB, 1)` |
| `72..72` | 1 | `X(1)` | `"0"` |
| `73..102` | 30 | `X(30)` | `PadRightSpace(EMPRESAS.NOME_EMPRESA, 30)` |
| `103..132` | 30 | `X(30)` | `PadRightSpace("SICOOB", 30)` |
| `133..142` | 10 | `X(10)` | 10 espaços |
| `143..143` | 1 | `9(1)` | `"1"` (Remessa Cliente -> Banco) |
| `144..151` | 8 | `9(8)` | Data de geração (`ddmmyyyy`) |
| `152..157` | 6 | `9(6)` | Hora de geração (`hhmmss`) |
| `158..163` | 6 | `9(6)` | `PadLeftZero(sequencial_remessa, 6)` |
| `164..166` | 3 | `9(3)` | `"081"` (Versão Layout Arquivo Sicoob) |
| `167..171` | 5 | `9(5)` | `"00000"` |
| `172..240` | 69 | `X(69)` | 69 espaços |

#### Header de Lote (Tipo `1` — 240 bytes)
| Pos. | Tam. | Formato | Valor / Regra Exata |
|---|---:|---|---|
| `1..17` | 17 | `X(17)` | `"75600011R01  040 "` (`Lote=0001`, `Tipo=1`, `Oper=R`, `Serv=01`, `LayoutLote=040`) |
| `18..18` | 1 | `9(1)` | `"1"` (CPF) ou `"2"` (CNPJ) |
| `19..33` | 15 | `9(15)` | `PadLeftZero(SomenteNumeros(EMPRESAS.CNPJ_EMPRESA), 15)` |
| `34..53` | 20 | `X(20)` | 20 espaços |
| `54..58` | 5 | `9(5)` | `PadLeftZero(EMPRESAS.AG_BANCOB, 5)` |
| `59..59` | 1 | `X(1)` | `PadLeftZero(EMPRESAS.DVAG, 1)` |
| `60..71` | 12 | `9(12)` | `PadLeftZero(EMPRESAS.CONTA_BANCOB, 12)` |
| `72..72` | 1 | `X(1)` | `PadLeftZero(EMPRESAS.DVCONTA_BANCOB, 1)` |
| `73..73` | 1 | `X(1)` | `" "` |
| `74..103` | 30 | `X(30)` | `PadRightSpace(EMPRESAS.NOME_EMPRESA, 30)` |
| `104..183` | 80 | `X(80)` | 80 espaços (Mensagens 1 e 2) |
| `184..191` | 8 | `9(8)` | `PadLeftZero(sequencial_remessa, 8)` |
| `192..199` | 8 | `9(8)` | Data de gravação (`ddmmyyyy`) |
| `200..207` | 8 | `9(8)` | `"00000000"` |
| `208..240` | 33 | `X(33)` | 33 espaços |

#### Detalhe — Segmento `P` (Tipo `3` — Obrigatório em `Mov = '01'` e `Mov = '02'`, 240 bytes)
| Pos. | Tam. | Formato | Valor / Regra Exata |
|---|---:|---|---|
| `1..8` | 8 | `X(8)` | `"75600013"` |
| `9..13` | 5 | `9(5)` | `PadLeftZero(seq_registro_no_lote, 5)` (inicia em `00001`, incrementa a cada segmento `P`, `Q`, `R`) |
| `14..15` | 2 | `X(2)` | `"P "` |
| `16..17` | 2 | `9(2)` | `"01"` (Entrada de Títulos) ou `"02"` (Pedido de Baixa) |
| `18..22` | 5 | `9(5)` | `PadLeftZero(AG_BANCOB, 5)` |
| `23..23` | 1 | `X(1)` | `PadLeftZero(DVAG, 1)` |
| `24..35` | 12 | `9(12)` | `PadLeftZero(CONTA_BANCOB, 12)` |
| `36..36` | 1 | `X(1)` | `PadLeftZero(DVCONTA_BANCOB, 1)` |
| `37..37` | 1 | `X(1)` | `" "` |
| `38..47` | 10 | `9(10)` | `PadLeftZero(NOSSONUMERO_7dig + SicoobNossoNumeroDV, 10)` |
| `48..49` | 2 | `9(2)` | Número da Parcela (`01`..`12`; se `ÚNICA`/`DEBIT`/`ADESÃO`, `"01"`) |
| `50..51` | 2 | `9(2)` | `PadLeftZero(MODALIDADE_BANCOB, 2)` |
| `52..52` | 1 | `9(1)` | `"3"` (Tipo Formulário Sicoob: Carnê/A4 sem envelopamento) |
| `53..57` | 5 | `X(5)` | 5 espaços |
| `58..58` | 1 | `9(1)` | `PadLeftZero(CARTEIRA_BANCOB, 1)` (`"1"`) |
| `59..62` | 4 | `X(4)` | `"0 22"` (Cadastramento=`0`, Doc=` `, Emissão=`2` Beneficiário, Distribuição=`2` Beneficiário) |
| `63..77` | 15 | `X(15)` | `PadLeftZero(NUM_ADESAO + ANOMES, 10) + "     "` (Número do Documento) |
| `78..85` | 8 | `9(8)` | `FormatDateTime("ddmmyyyy", PARCELAS.DTVENC)` |
| `86..100` | 15 | `9(13)V99` | `PadLeftZero(Round(PARCELAS.VALOR * 100), 15)` |
| `101..109` | 9 | `X(9)` | `"00000 04N"` (Ag. Cobradora `00000 `, Espécie `04` Duplicata de Serviço/Carnê, Aceite `N`) |
| `110..117` | 8 | `9(8)` | `FormatDateTime("ddmmyyyy", PARCELAS.DTEM)` |
| `118..141` | 24 | `9(24)` | **Juros de Mora:** Se `EMPRESAS.JUROSDIA > 0`: `"1"` (`118`, Valor por Dia) + `FormatDateTime("ddmmyyyy", DTVENC)` (`119..126`) + `PadLeftZero(Round(JUROSDIA * 100), 15)` (`127..141`). Se `0`: `24 zeros`. |
| `142..165` | 24 | `9(24)` | Desconto 1 = `24 zeros` |
| `166..195` | 30 | `9(30)` | Valor IOF (`15 zeros`) + Valor Abatimento (`15 zeros`) |
| `196..220` | 25 | `9(25)` | `PadLeftZero(NUM_ADESAO + ANOMES, 25)` (Uso da Empresa — chave de retorno!) |
| `221..221` | 1 | `9(1)` | `"3"` (Não Protestar) ou `"1"` conforme configuração |
| `222..223` | 2 | `9(2)` | `"00"` (Prazo Protesto) |
| `224..227` | 4 | `X(4)` | `"0   "` (Código Baixa/Devolução = `0`, Prazo = `   `) |
| `228..229` | 2 | `9(2)` | `"09"` (Código da Moeda = Real) |
| `230..239` | 10 | `9(10)` | `"0000000000"` (Número do Contrato) |
| `240..240` | 1 | `X(1)` | `" "` |

#### Detalhe — Segmento `Q` (Tipo `3` — Emitido somente quando `Mov = '01'`, 240 bytes)
| Pos. | Tam. | Formato | Valor / Regra Exata |
|---|---:|---|---|
| `1..8` | 8 | `X(8)` | `"75600013"` |
| `9..13` | 5 | `9(5)` | `PadLeftZero(seq_registro_no_lote, 5)` |
| `14..17` | 4 | `X(4)` | `"Q 01"` |
| `18..18` | 1 | `9(1)` | `"1"` (CPF) ou `"2"` (CNPJ) |
| `19..33` | 15 | `9(15)` | `PadLeftZero(SomenteNumeros(CLIENTES.CPF), 15)` |
| `34..73` | 40 | `X(40)` | `PadRightSpace(CLIENTES.NOME, 40)` |
| `74..113` | 40 | `X(40)` | `PadRightSpace(ENDERECO + " " + END_NUMERO + " " + COMPLEMENTO, 40)` |
| `114..128` | 15 | `X(15)` | `PadRightSpace(CLIENTES.BAIRRO, 15)` |
| `129..136` | 8 | `9(8)` | `PadLeftZero(SomenteNumeros(CLIENTES.CEP), 8)` |
| `137..151` | 15 | `X(15)` | `PadRightSpace(CLIENTES.CIDADE, 15)` |
| `152..153` | 2 | `X(2)` | `PadRightSpace(CLIENTES.ESTADO, 2)` |
| `154..169` | 16 | `9(16)` | `16 zeros` (Sacador/Avalista) |
| `170..209` | 40 | `X(40)` | `40 espaços` |
| `210..212` | 3 | `9(3)` | `"000"` |
| `213..240` | 28 | `X(28)` | `28 espaços` |

#### Detalhe — Segmento `R` (Tipo `3` — Emitido somente quando `Mov = '01'`, 240 bytes)
| Pos. | Tam. | Formato | Valor / Regra Exata |
|---|---:|---|---|
| `1..8` | 8 | `X(8)` | `"75600013"` |
| `9..13` | 5 | `9(5)` | `PadLeftZero(seq_registro_no_lote, 5)` |
| `14..17` | 4 | `X(4)` | `"R 01"` |
| `18..65` | 48 | `9(48)` | `48 zeros` (Descontos 2 e 3) |
| `66..89` | 24 | `9(24)` | **Multa:** Se `EMPRESAS.PERCENTMULTA > 0`: `"2"` (`66`, Percentual) + `FormatDateTime("ddmmyyyy", DTVENC)` (`67..74`) + `PadLeftZero(Round(PERCENTMULTA * 100), 15)` (`75..89`). Se `0`: `24 zeros`. |
| `90..199` | 110 | `X(110)` | `110 espaços` |
| `200..231` | 32 | `X(32)` | `16 zeros` + `" "` + `12 zeros` + `"  0"` |
| `232..240` | 9 | `X(9)` | `9 espaços` |

#### Trailer de Lote (`5`) e Trailer de Arquivo (`9`) — 240 bytes cada
- **Trailer de Lote (`5`):** `1..8 = "75600015"`, `9..17 = 9 espaços`, `18..23 = PadLeftZero(qtd_reg_lote, 6)` (Header Lote + todos `P/Q/R` + Trailer Lote), `24..29 = PadLeftZero(qtd_titulos, 6)`, `30..46 = PadLeftZero(soma_valores_centavos, 17)`, `47..115 = 69 zeros`, `116..240 = 125 espaços`.
- **Trailer de Arquivo (`9`):** `1..8 = "75699999"`, `9..17 = 9 espaços`, `18..23 = "000001"`, `24..29 = PadLeftZero(qtd_total_linhas_arquivo, 6)`, `30..35 = "000000"`, `36..240 = 205 espaços`.

---

### 3.3.1 Composição Oficial do Código de Barras (`44` dígitos) e Linha Digitável (`47` dígitos) — Sicoob (`756`)

> **Fonte Oficial Verificada:** Planilha `documentos_auxiliares/Layouts_para_troca_de_informações - cooperativas.xls` (aba `02.Especificações do Boleto`). Esses campos devem ser calculados pelo sistema na geração direta dos carnês/boletos em PDF e persistidos em `parcelas.codigo_barras` (`VARCHAR(44)`) e `parcelas.linha_digitavel` (`VARCHAR(47)`).

#### A. Código de Barras (`44` posições numéricas)
| Posição | Tam. | Campo | Regra Exata |
|---|---:|---|---|
| `1..3` | 3 | Banco | `"756"` (Código do Sicoob na câmara de compensação) |
| `4..4` | 1 | Moeda | `"9"` (Real) |
| `5..5` | 1 | DV Geral (`L`) | **Módulo 11** (pesos `2..9` da direita para a esquerda sobre os 43 dígitos restantes; se `11 - resto` for `0`, `1` ou `> 9`, assume **`"1"`**) |
| `6..9` | 4 | Fator de Vencimento (`MMMM`) | Para vencimentos $\ge$ **`22/02/2025`**: `(data_vencimento - 22/02/2025) + 1000` *(para datas anteriores: `(data_vencimento - 03/07/2000) + 1000`; sem vencimento: `"0000"`)* |
| `10..19` | 10 | Valor (`NNNNNNNNNN`) | `PadLeftZero(Round(valor_boleto * 100), 10)` *(zeros se valor em aberto)* |
| `20..20` | 1 | Carteira (`C`) | Código da carteira Sicoob (1 dígito, ex.: `"1"`) |
| `21..24` | 4 | Agência / Cooperativa (`DDDD`) | `PadLeftZero(agencia, 4)` |
| `25..26` | 2 | Modalidade (`FF`) | `PadLeftZero(modalidade, 2)` |
| `27..33` | 7 | Código do Beneficiário (`GGGGGGG`) | `PadLeftZero(codigo_cedente, 7)` |
| `34..41` | 8 | Nosso Número (`HHHHHHHH`) | `PadLeftZero(nosso_numero_7dig + dv_nosso_numero, 8)` *(DV calculado por Módulo 11 peso cíclico `3197` sobre os 21 dígitos)* |
| `42..44` | 3 | Número da Parcela (`JJJ`) | `PadLeftZero(num_parcela, 3)` (ex.: `"001"`..`"012"`; `"001"` se parcela única / boleto avulso) |

#### B. Linha Digitável (`47` dígitos em 5 Campos: `AAABC.DDDDE  FFGGG.GGGGHI  HHHHH.HHJJJK  L  MMMMNNNNNNNNNN`)
1. **Campo 1 (`AAABC.DDDDE` — 10 dígitos + 1 DV):** `Banco(3)` + `Moeda(1)` + `Carteira(1)` + `Agência(4)` + **`E` (DV Módulo 10)**;
2. **Campo 2 (`FFGGG.GGGGHI` — 10 dígitos + 1 DV):** `Modalidade(2)` + `Código Beneficiário(7)` + `1º dígito do Nosso Número(1)` + **`I` (DV Módulo 10)**;
3. **Campo 3 (`HHHHH.HHJJJK` — 10 dígitos + 1 DV):** `7 dígitos restantes do Nosso Número(7)` + `Parcela(3)` + **`K` (DV Módulo 10)**;
4. **Campo 4 (`L` — 1 dígito):** DV Geral do Código de Barras (posição `5` do código de barras, **Módulo 11**);
5. **Campo 5 (`MMMMNNNNNNNNNN` — 14 dígitos):** `Fator de Vencimento(4)` + `Valor em centavos(10)`.

#### C. Regra do Módulo 10 (para os DVs `E`, `I` e `K` dos Campos 1, 2 e 3)
* Multiplicar cada dígito do campo da **direita para a esquerda** alternando os pesos **`2, 1, 2, 1...`**;
* Se qualquer produto for `> 9`, somar os algarismos do produto até reduzir a 1 dígito (ex.: `18` $\to$ `1 + 8 = 9`);
* Somar todos os resultados, encontrar a dezena imediatamente superior (ou igual) à soma e subtrair a soma (ex.: soma `25` $\to$ `30 - 25 = 5`; se a soma for múltipla de 10, DV = `0`).

---

### 3.4 Processamento de Retorno CNAB 240 (`TFrmBaixaAutomatica` — `27_UBaixaAutomatica.c`)

O parser inspeciona `Copy(linha, 1, 3)` (código do banco) e `linha[8]` (tipo de registro = `'3'` Detalhe) + `linha[14]` (código de segmento):

#### A. Retorno Sicoob (`756`) — Par de Segmentos `T` + `U`
1. **No Segmento `T` (`linha[14] = 'T'`):**
   - `CodMovimento = Copy(linha, 16, 2)` (posições `16..17`).
   - `NossoNumeroSemDV = StrToInt(Copy(linha, 38, 9))` (posições `38..46` — 9 dígitos sem o 10º dígito verificador!).
   - `SeuNumero / UsoEmpresa` = fallback `NUM_ADESAO + ANOMES` em `Copy(linha, 59, 15)` / `Copy(linha, 106, 25)`.
   - `ValorTarifa = StrToCurr(Copy(linha, 199, 15)) / 100` (posições `199..213` -> alimenta `PARCELAS.VALOR_COMP`!).
2. **No Segmento `U` subsequente (`linha[14] = 'U'`):**
   - `ValorPago = StrToCurr(Copy(linha, 78, 15)) / 100` (posições `78..92`).
   - `ValorLiquidoCreditado = StrToCurr(Copy(linha, 93, 15)) / 100` (posições `93..107`).
   - `DataOcorrencia = ParseDDMMYYYY(Copy(linha, 138, 8))` (posições `138..145` -> alimenta `PARCELAS.DTPAG`).
3. **Ação por Código de Movimento (`CodMovimento`):**
   - `'02'` (**Entrada Confirmada**): Atualiza `PARCELAS.REGISTRADO = 'S'` onde `NOSSONUMERO = NossoNumeroSemDV`.
   - `'03'` (**Entrada Rejeitada**) ou `'09'` (**Baixa Comandada/Simples**): Atualiza `PARCELAS.REGISTRADO = 'N'`.
   - `'06'` (**Liquidação**): Atualiza `DTPAG = DataOcorrencia`, `VALOR_PAGO = ValorPago`, `VALOR_COMP = ValorTarifa` (ou `ValorPago - ValorLiquidoCreditado` quando tarifa vier embutida) **e executa a cascata automática caso `ID_PARC = 'ÚNICA'`!**

#### B. Retorno Caixa Econômica Federal (`104`) — Cobrança (`T`/`U`) e Arrecadação (`G`)
1. **Variante Cobrança (`Segmentos T + U`):**
   - **BUG CRÍTICO NO LEGADO (`0x5a5010`):** O binário extraía apenas `Copy(linha, 49, 4)` para `NUM_ADESAO` e `Copy(linha, 53, 4)` para `ANOMES`, truncando adesões com 5+ dígitos (`>= 10.000`, sendo que o banco atual já possui mais de `19.000` adesões!).
   - **Correção no Novo Sistema Web:** Localizar prioritariamente pelo `NOSSONUMERO` completo e, no fallback por `Seu Número` (`pos 59..73` ou `106..130`), ler todos os dígitos significativos antes dos 4 dígitos finais de `ANOMES`!
   - `ValorTarifa` em `T[199..213]`, `ValorPago` em `U[78..92]`, `DataPag` em `U[138..145]`.
2. **Variante Convênio Arrecadação / Lotérico (`Segmento G`, `linha[14] = 'G'`):**
   - Código de barras nas posições `18..61` (44 posições): extrai `NUM_ADESAO` e `ANOMES` do campo livre do código de barras Febraban, `DataPagamento` (`pos 22..29` ou campo data crédito) e `ValorRecebido` (`pos 74..85`, 12 dígitos em centavos) + tarifa de arrecadação (`VALOR_COMP`).

#### C. Importação de Baixas via Planilha Excel (`.xls` / `.xlsx` / `.csv`)
Cada linha de dados da planilha selecionada contém **3 colunas**:
- **Coluna A (`Fields[0]`):** Data de pagamento (`DD/MM/AAAA` ou tipo Date do Excel).
- **Coluna B (`Fields[1]`):** Identificador composto de **13 dígitos** = `PadLeftZero(NUM_ADESAO, 9) + ANOMES(4)` (ou string variável onde os últimos 4 dígitos são `ANOMES` e os anteriores são `NUM_ADESAO`).
- **Coluna C (`Fields[2]`):** Valor pago (`NUMERIC(12,2)`). `VALOR_COMP` assume `0,00` (salvo se houver 4ª coluna opcional na versão web). Aplica igualmente a cascata da parcela `'ÚNICA'`.

---

## 4. Resumo Consolidado de Bugs Legados e Decisões de Modernização

| # | Bug Identificado na Engenharia Reversa | Local no Binário | Comportamento Recomendado no Novo Sistema Web |
|---:|---|---|---|
| 1 | Senhas e caminho do banco com `XOR 0xC5` e limite de 10 chars | `ULib__fn_57f498` / `TFrmLogin` | Substituir por **Argon2id/BCrypt**, JWT HttpOnly e senhas de 8 a 128 chars |
| 2 | Credenciais `SYSDBA` / `masterkey` fixas no executável | `TDM.dfm` / `TFrmConectar` | Eliminar acesso direto do cliente ao SGBD; conexão somente no backend via `DATABASE_URL` |
| 3 | 7 itens de menu sem checagem RBAC + `ComboBox1` desconectado | `Uprincipal__fn_5b11d8` / `TFrmUsuarios` | Proteger **100% dos endpoints da API** e rotas de UI com as 18 flags RBAC granulares |
| 4 | 3 colisões de atalhos (`Ctrl+R`, `Ctrl+A`, `Ctrl+Shift+C`) + `Ctrl+C` | `TFrmPrincipal.dfm` | Usar Command Palette (`Ctrl+K`) e atalhos web sem conflito com atalhos nativos do navegador |
| 5 | Truncamento de `NUM_ADESAO` em 4 dígitos no Retorno Caixa `104` | `UBaixaAutomatica` (`0x5a5010`) | Conciliar por `NOSSONUMERO` exato e extrair `NUM_ADESAO` completo sem limite de 4 dígitos |
| 6 | Faturamento PJ somando funcionários inativos (`SITUACAO = 'I'`) | `UBoletoBancario` (`0x5a3a47`) | Filtrar `WHERE CODIGOPESSOAJURIDICA = :id AND SITUACAO = 'A'` (exibindo inativos separados na memória de cálculo) |
| 7 | `ValidarCpfCnpj` aceita dígitos repetidos (`111.111.111-11`) | `ULib` | Bloquear dígitos repetidos em novos cadastros/edições e auditar base legada na migração |
| 8 | Repetição de `EMPRESA.CEP` nas colunas `184..213` do Header `REMESSA` | `UCarne` (`0x595f3c`), `UsegundaVia` | **Manter por padrão no exportador legado de 350 colunas** (para não quebrar máscara da gráfica!), com flag opcional `corrigir_bairro_header_grafica` |
| 9 | Rótulos invertidos/antigos `&SICAP` / `&SIGCB` em `TFrmClientes.Rbanco` | `TFrmClientes.dfm` | Exibir nomes claros: `1 - Caixa Econômica Federal` e `2 - Sicoob (756)` |
| 10 | Concatenação direta de SQL com datas `mm/dd/yyyy` (SQL Injection) | Todas as units de consulta/relatório | `100%` Prepared Statements / ORM parametrizado com tipos `DATE` nativos |
