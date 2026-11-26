# 05 — Especificação Técnica Completa dos Relatórios (`Relatorios.rav`)

> **O que é o arquivo `Relatorios.rav`?**
> O arquivo `Relatorios.rav` (`17.074` bytes comprimidos em disco -> **`68.968` bytes descomprimidos**) é um projeto compilado do gerador de relatórios **Nevrona Rave Reports 5.0** (nativo do Borland Delphi 7).
> Internamente, possui cabeçalho mágico `"RAV\x1a"` versão `156` (`0x009C`) e armazena a árvore de objetos `RvProjRelatorios` em **duas camadas aninhadas de compressão LZW de 8 a 13 bits MSB-first** (marcador `0x0002` + `uint32_le tamanho` + `0x80`, código `256` de limpeza de dicionário):
> - **Camada Externa:** Metadados do projeto (`Param.DATAINI`, `Param.DATAFIM`, `Param.TITULO`), **6 `TRaveDataView`** e os cabeçalhos dos **6 `TRaveReport`**.
> - **Camada Interna (`Page1`):** Layout milimétrico de cada página A4 (`TRavePage`), bandas (`TRaveBand` / `TRaveDataBand`), agrupamentos, campos calculados (`TRaveCalcText` — `Sum` e `Count`), fontes e bordas.

---

## 1. Arquitetura de Dados dos Relatórios (`TDM` <-> `Relatorios.rav`)

No `TDM.dfm`, existem **9 componentes `TRvDataSetConnection`**, dos quais **6 alimentam diretamente os `TRaveDataView` ativos** dentro de `Relatorios.rav`:

| `TRvDataSetConnection` (`TDM`) | Dataset Delphi (`TDM`) | `TRaveDataView` (`Relatorios.rav`) | Relatório(s) Consumidor(es) | Observações Técnicas |
|---|---|---|---|---|
| `RvDSConEmpresa` | `IBDEmpresaAtiva` | `DVEmpresa` | **Todos os 6 relatórios** | Cabeçalho institucional com `LOGOMARCA` (BLOB), CNPJ, endereço e telefones |
| `RvDSConContasRecebidas` | `IBDContasRecebidas` | `DVContasRecebidas` | `RelContasRecebidas` | Agregação diária de recebimentos (`VALOR PAGO`, `VL COMPENSAÇÃO`, `VALOR LIQUIDO`) |
| `RvDSConContasReceber` | `IBDContasReceber` | `DVContasReceber` | `RelContasAReceber` | Agregação diária de previsões em aberto (`DTVENC`, `SUM`) |
| `RvDSetConQryRelClientes` | `IBQryRelClientes` | `DVClientes` | `RelClientesInadimplentes`, `RelClientesAdimplentes` | Join `CLIENTES` x `PARCELAS` (e opcionalmente `CONVENIOS`) ordenado por `NUM_ADESAO, DTVENC` |
| `RvDSConIBDClientes` | `IBDClientes` | `DVClienteGeral` | `RelClientesGeral` | Cadastro de `CLIENTES` filtrado por situação, mês de aniversário ou adesão `0000` em aberto |
| `RvDSConQryRelConvenio` | `IBQryRelConvenio` | `DVConvenio` | `RelConvenios` | Join `CLIENTES` x `PARCELAS` x `CONVENIOS` calculando `<COMISSÃO>` por parcela paga |
| `RvDSConDependentes` | `IBDDependentes` | *(não instanciado no `.rav`)* | — | Declarado no `TDM`, mas sem relatório Rave vinculado |
| `RvDataSetConConevenios` *(sic)* | `IBDConvenios` | *(não instanciado no `.rav`)* | — | Substituído por `RvDSConQryRelConvenio` |
| `RvDSConParcelas` | `IBDParcelas` | *(não instanciado no `.rav`)* | — | Substituído por `RvDSetConQryRelClientes` |

---

## 2. Cabeçalho Institucional Padrão (Banda `Cabecalho` — Comum aos 6 Relatórios)

Todos os 6 relatórios renderizam no topo da primeira página (ou topo de cada página) a banda institucional alimentada por `DVEmpresa` (`EMPRESAS`):
- **À esquerda (`Bitmap1`):** Logomarca da empresa ativa (`DVEmpresa.LOGOMARCA`, redimensionada proporcionalmente).
- **Ao centro/direita (4 linhas de texto — Arial 9pt/11pt Negrito):**
  1. `DVEmpresa.NOME_EMPRESA` (Razão Social em destaque)
  2. `DVEmpresa.ENDERECO + '  ' + DVEmpresa.END_NUMERO + '  ' + DVEmpresa.COMPLEMENTO`
  3. `DVEmpresa.CEP + ' ' + DVEmpresa.BAIRRO + ' ' + DVEmpresa.CIDADE + ' - ' + DVEmpresa.ESTADO`
  4. `'Tel. ' + DVEmpresa.TELEFONE_COMERCIAL + '  Fax. ' + DVEmpresa.TELEFONE_FAX`
- **Rodapé de Página Padrão:** Data/hora de emissão à esquerda (`Report.Date` / `dd/mm/yyyy HH:mm`) e numeração `'Página X de Y'` à direita.

---

## 3. Especificação Individual dos 6 Relatórios Extraídos + 7º Relatório PJ

---

### REL-01: Relatório de Contas Recebidas (`RelContasRecebidas`)
- **Acionamento no Legado:** Menu `Relatórios -> Contas Recebidas` (`Ctrl+B`) -> `TFrmRelatoriosContas` (`Tipo = 'RECEBIDO'`).
- **Orientação:** Retrato (`poPortrait`, A4). *(Curiosidade interna do `.rav`: a propriedade `FullName` foi salva como `"Contas a Receber"` por cópia de template, mas o título impresso na página `Text1` é `"Relatório de Contas Recebidas"`).*
- **Parâmetros:** `DATAINI` (`dd/mm/yyyy`) e `DATAFIM` (`dd/mm/yyyy`).
- **Subtítulo Impresso:** `"Período de Consulta: de " + Param.DATAINI + " até " + Param.DATAFIM`.
- **Query SQL Exata (Equivalente PostgreSQL Parametrizada):**
  ```sql
  SELECT
      p.dt_pagamento AS dtpag,
      SUM(COALESCE(p.valor_pago, 0)) AS valor_pago,
      SUM(COALESCE(p.valor_compensacao, 0)) AS vl_compensacao,
      SUM(COALESCE(p.valor_pago, 0) - COALESCE(p.valor_compensacao, 0)) AS valor_liquido
  FROM parcelas p
  WHERE p.empresa_id = :empresa_id
    AND p.dt_pagamento BETWEEN :data_ini AND :data_fim
    AND COALESCE(p.valor_pago, 0) > 0
  GROUP BY p.dt_pagamento
  ORDER BY p.dt_pagamento ASC;
  ```
  *(Nota: parcelas baixadas em cascata por `ÚNICA` ou consolidadas por `DEBIT` têm `VALOR_PAGO = 0`, portanto não distorcem a soma; filtrar `valor_pago > 0` evita listar dias com soma R\$ 0,00).*
- **Colunas da Banda de Detalhe (`DVContasRecebidas`):**
  1. **Data** (`DTPAG` — formato `dd/mm/yyyy`)
  2. **Valor Recebido** (`<VALOR PAGO>` — formato `R\$ #,##0.00`, alinhado à direita)
  3. **Vl. Compensação** (`<VL COMPENSAÇÃO>` — tarifas bancárias retidas no CNAB, `R\$ #,##0.00`)
  4. **Valor Líquido** (`<VALOR LIQUIDO>` — `Valor Recebido - Vl. Compensação`, `R\$ #,##0.00`)
- **Banda de Rodapé Geral (`Totais`):**
  - `Total Bruto:` `SUM(<VALOR PAGO>)` (`R\$ #,##0.00`)
  - `Total Compens.:` `SUM(<VL COMPENSAÇÃO>)` (`R\$ #,##0.00`)
  - `Total Liquido:` `SUM(<VALOR LIQUIDO>)` (`R\$ #,##0.00`)
- **Melhoria Recomendada na Web:** Permitir alternar entre visão **Sintética Diária** (idêntica ao legado) e visão **Analítica por Parcela/Cliente/Banco**, além de filtro por canal de baixa (`Manual`, `CNAB Sicoob`, `CNAB Caixa`, `Planilha`).

---

### REL-02: Relatório de Contas a Receber (`RelContasAReceber`)
- **Acionamento no Legado:** Menu `Relatórios -> Contas a Receber` (`Ctrl+R`) -> `TFrmRelatoriosContas` (`Tipo = 'RECEBER'`).
- **Orientação:** Retrato (`poDefault` / A4).
- **Parâmetros:** `DATAINI` e `DATAFIM` (intervalo de **vencimento** `DTVENC`).
- **Subtítulo Impresso:** `"Período de Consulta: de " + Param.DATAINI + " até " + Param.DATAFIM`.
- **Query SQL Exata:**
  ```sql
  SELECT
      p.dt_vencimento AS dtvenc,
      SUM(p.valor_nominal) AS valor_a_receber,
      COUNT(*) AS qtd_parcelas
  FROM parcelas p
  LEFT JOIN clientes_pf cpf ON cpf.numero_adesao = p.numero_adesao
  LEFT JOIN clientes_pj cpj ON cpj.numero_adesao = p.numero_adesao
  WHERE p.empresa_id = :empresa_id
    AND p.dt_vencimento BETWEEN :data_ini AND :data_fim
    AND p.dt_pagamento IS NULL
    AND p.id_parcela <> 'ÚNICA'
    AND COALESCE(cpf.situacao, cpj.situacao, 'A') = 'A'
  GROUP BY p.dt_vencimento
  ORDER BY p.dt_vencimento ASC;
  ```
  > **Regra Crítica:** Excluir obrigatoriamente `ID_PARC = 'ÚNICA'` (pois do contrário duplicaria em 180% a previsão de recebíveis do mês do 1º vencimento!) e clientes cancelados (`SITUACAO = 'C'`).
- **Colunas da Banda de Detalhe (`DVContasReceber`):**
  1. **Data** (`DTVENC` — `dd/mm/yyyy`)
  2. **Valor a receber** (`SUM` — `R\$ #,##0.00`)
- **Banda de Rodapé Geral:**
  - `Valor Total:` `SUM(SUM)` (`R\$ #,##0.00`).

---

### REL-03: Relatório de Clientes Inadimplentes (`RelClientesInadimplentes`)
- **Acionamento no Legado:** Menu `Relatórios -> Clientes Inadimplentes` (`Ctrl+I`) -> `TFrmRelatoriosClientes` (`Tipo = 'INADIMPLENTES'`).
- **Parâmetros de Filtro:**
  - `AteData` (`DData`): Data de corte de vencimento (`DTVENC <= :ate_data`, default `CURRENT_DATE`).
  - **Filtro de Modalidade de Inadimplência (Novo Sistema Web — baseado em `tipo_parcela` e `situacao_parcela = 'ABERTA'`):**
    1. **`GERAL` (Padrão):** Exibe todos os clientes inadimplentes, somando tanto **Mensalidades Regulares vencidas** (`tipo_parcela = 'MENSALIDADE_PF'`) quanto **Parcelas de Renegociação/Acordo vencidas** (`tipo_parcela = 'ACORDO_RENEGOCIACAO'`);
    2. **`APENAS_RENEGOCIACOES`:** Exibe exclusivamente clientes com inadimplência em parcelas de **Acordo / Renegociação** (`tipo_parcela = 'ACORDO_RENEGOCIACAO'` vencidas e em aberto);
    3. **`APENAS_MENSALIDADES`:** Exibe apenas clientes com mensalidades regulares de carnê vencidas (`tipo_parcela = 'MENSALIDADE_PF'`).
  - Filtro opcional dinâmico: campo cadastral de `CLIENTES` ou Unidade (`unidades.nome ILIKE :texto`).
- **Query SQL Exata:**
  ```sql
  SELECT
      c.numero_adesao AS numero,
      c.nome,
      c.cpf,
      c.endereco,
      c.end_numero,
      c.complemento,
      c.bairro,
      c.cidade,
      c.estado,
      c.cep,
      c.telefone_cel,
      c.telefone_fax,
      c.telefone_comercial,
      p.id_parcela AS id_parc,
      p.anomes,
      p.dt_emissao AS dtem,
      p.dt_vencimento AS dtvenc,
      p.valor_nominal AS valor
  FROM clientes_pf c
  INNER JOIN parcelas p ON p.numero_adesao = c.numero_adesao
  LEFT JOIN convenios conv ON conv.id = c.convenio_id
  WHERE c.empresa_id = :empresa_id
    AND c.situacao = 'A'
    AND p.dt_pagamento IS NULL
    AND p.dt_vencimento <= :ate_data
    AND p.id_parcela <> 'ÚNICA'
    AND p.anomes <> '0000'
  ORDER BY c.numero_adesao ASC, p.dt_vencimento ASC;
  ```
- **Estrutura de Agrupamento (`GroupKey = NUM_ADESAO`):**
  - **Cabeçalho de Grupo (`Band1` — Dados do Cliente para Cobrança):**
    - Linha 1: `'Cliente: ' + NUMERO + '  ' + NOME + '   CPF: ' + CPF`
    - Linha 2: Endereço completo (`ENDERECO, END_NUMERO, COMPLEMENTO - BAIRRO - CEP - CIDADE/ESTADO`)
    - Linha 3: `'Fones: ' + TELEFONE_CEL + '  ' + TELEFONE_FAX + '  ' + TELEFONE_COMERCIAL`
  - **Banda de Detalhe (Parcelas Vencidas do Cliente):**
    1. `Identificação da Parcela`: `ID_PARC + '  -  ' + ANOMES`
    2. `Data de Emissão`: `DTEM` (`dd/mm/yyyy`)
    3. `Data de Vencimento`: `DTVENC` (`dd/mm/yyyy`)
    4. `Valor`: `VALOR` (`R\$ #,##0.00`)
  - **Rodapé de Grupo (`Band2`):** `"Total devido pelo cliente:"` -> `SUM(VALOR)` por `NUM_ADESAO`.
  - **Rodapé Geral do Relatório (`Band3`):** `"Total Geral Devido"` -> `SUM(VALOR)` de todos os inadimplentes listados.

---

### REL-04: Relatório de Clientes Adimplentes (`RelClientesAdimplentes`)
- **Acionamento no Legado:** Menu `Relatórios -> Clientes Adimplentes` (`Ctrl+A`) -> `TFrmRelatoriosClientes` (`Tipo = 'ADIMPLENTES'`).
- **Parâmetros de Filtro:**
  - `AteData` (`DData`): Cliente **não pode possuir nenhuma parcela comum vencida e não paga até `:ate_data`** (`NOT EXISTS (SELECT 1 FROM parcelas p2 WHERE p2.numero_adesao = c.numero_adesao AND p2.dt_pagamento IS NULL AND p2.dt_vencimento <= :ate_data AND p2.id_parcela <> 'ÚNICA')`) **e** lista as parcelas efetivamente pagas (`p.dt_pagamento IS NOT NULL AND p.valor_pago > 0`).
  - `ChkCarneCompleto ("Apenas Clientes Com Carnê Quitado")`: Quando marcado, exige adicionalmente que o cliente tenha quitado a 12ª parcela (`ANOMES LIKE '%12' AND DTPAG IS NOT NULL`, ou parcela `'ÚNICA'` paga) e não tenha nenhuma outra parcela `%12` em aberto!
  - Filtro opcional por campo cadastral / `NOME DO CADASTRANTE`.
- **Estrutura de Agrupamento (`GroupKey = NUM_ADESAO`):**
  - **Cabeçalho de Grupo (`Band1`):** `'Cliente: ' + NUMERO + '  ' + NOME + '   CPF: ' + CPF`.
  - **Banda de Detalhe (6 colunas):**
    1. `Ident. da Parcela`: `ID_PARC + ' - ' + ANOMES`
    2. `Dt. Vencimento`: `DTVENC` (`dd/mm/yyyy`)
    3. `Valor Pago`: `VALOR_PAGO` (`R\$ #,##0.00`)
    4. `Dt. Pagamento`: `DTPAG` (`dd/mm/yyyy`)
    5. `Vl. Compens.`: `VALOR_COMP` (`R\$ #,##0.00`)
    6. `Vl. Liquido`: `<VL LIQUIDO>` (`VALOR_PAGO - VALOR_COMP`, `R\$ #,##0.00`)
  - **Rodapé de Grupo (`Band2` — `"Total do Cliente"`):**
    - `Total Bruto = SUM(VALOR_PAGO)` | `Total Compens. = SUM(VALOR_COMP)` | `Total Liquido = SUM(<VL LIQUIDO>)`.
  - **Rodapé Geral (`Band3` — `"Total Geral "`):**
    - Soma global de `Total Bruto`, `Total Compens.` e `Total Liquido`.

---

### REL-05: Relatório Geral de Clientes (`RelClientesGeral`)
- **Acionamento no Legado:** Menu `Relatórios -> Geral de Clientes` (`Ctrl+Shift+C`) -> `TFrmRelGeralClientes`.
- **Orientação:** Retrato (`poPortrait`, A4).
- **Título Dinâmico (`Param.TITULO`):**
  - Modo `0` (`Geral de clientes`): `"Relatório Geral de Clientes"` — todos os clientes com `SITUACAO = 'A'` (ou `'I'` se `chkInativos` estiver marcado).
  - Modo `1` (`De aniversariantes do mês`): `"Relatório de Clientes Aniversariantes do mês MM"` — filtra `EXTRACT(MONTH FROM DATA_NASC) = :mes` (na web, permitir escolher qualquer mês `1..12`, com default no mês atual!) ordenado por `EXTRACT(DAY FROM DATA_NASC), NOME`.
  - Modo `2` (`De clientes que não pagaram a adesão`): `"Relatório de Clientes que não pagaram a adesão"` — filtra clientes cuja parcela `ANOMES = '0000'` continua com `VALOR_PAGO IS NULL / DTPAG IS NULL`.
- **Layout da Banda de Detalhe (Formato Ficha Compacta por Cliente):**
  - `Número`: `NUMERO` | `Nome`: `NOME`
  - `Data de Nascimento`: `DATA_NASC` | `Data de Inscrição`: `INSCRICAO` | `Valor do Plano`: `VALOR_PLANO` (`R\$ #,##0.00`)
  - `Fones de Contato`: `TELEFONE_COMERCIAL + '  ' + TELEFONE_FAX + '  ' + TELEFONE_CEL`
- **Banda de Rodapé Geral (`Band2`):**
  - `"Total de Clientes Listados:"` `COUNT(NUMERO)` + `"Fim do relatório"`.

---

### REL-06: Relatório de Comissões de Cadastrantes (`RelConvenios`)
- **Acionamento no Legado:** Menu `Relatórios -> Comissões` -> `TFrmRelConvenios`.
- **Orientação:** Retrato (`poPortrait`, A4).
- **Parâmetros:** `CodCadastrante` (opcional; se omitido, traz todos), `DATAINI` e `DATAFIM` (intervalo de `PARCELAS.DTPAG`).
- **Query SQL Exata:**
  ```sql
  SELECT
      conv.id AS cod_convenio,
      conv.nome AS cadastrante,
      conv.perc_comissao AS perc_com,
      c.numero_adesao AS numero,
      c.nome,
      p.id_parcela,
      p.anomes,
      p.dt_pagamento,
      p.valor_pago,
      ROUND((p.valor_pago * conv.perc_comissao / 100.0), 2) AS comissao
  FROM parcelas p
  INNER JOIN clientes_pf c ON c.numero_adesao = p.numero_adesao
  INNER JOIN convenios conv ON conv.id = c.convenio_id
  WHERE p.empresa_id = :empresa_id
    AND p.dt_pagamento BETWEEN :data_ini AND :data_fim
    AND COALESCE(p.valor_pago, 0) > 0
    AND (:convenio_id IS NULL OR conv.id = :convenio_id)
  ORDER BY conv.id ASC, c.numero_adesao ASC, p.dt_pagamento ASC;
  ```
- **Estrutura de Agrupamento (`GroupKey = COD_CONVENIO`):**
  - **Cabeçalho de Grupo (`Band1`):** `'Cadastrante: ' + COD_CONVENIO + ' - ' + CADASTRANTE + ' (' + PERC_COM + '%)'`.
  - **Banda de Detalhe (3 colunas no legado; expandir com parcela/data na web):**
    1. `Cliente`: `NUMERO + '  ' + NOME`
    2. `Vl. Pago`: `VALOR_PAGO` (`R\$ #,##0.00`)
    3. `Vl. Comissão`: `<COMISSÃO>` (`R\$ #,##0.00`)
  - **Rodapé de Grupo (`Band2` — `"Total do Cadastrante"`):**
    - `Total Pago = SUM(VALOR_PAGO)` | `Total Comissão = SUM(<COMISSÃO>)`.
  - **Rodapé Geral (`Band3` — `"Total Geral"`):**
    - `Total Pago = SUM(VALOR_PAGO)` | `Total Geral Comissões = SUM(<COMISSÃO>)`.

---

### REL-07: Relatório Financeiro de Clientes Pessoa Jurídica *(Inacabado no Legado — Concluir na Web)*
- **Evidência no Legado:** Item de menu oculto `Relatorio1` (`Caption = "Pessoa Juridica"`, `ShortCut = Ctrl+Shift+J`, `Visible = False`) em `TFrmPrincipal.dfm` + query `IBQryRelPessoaJuridica` em `TDMPessoaJuridica.dfm`:
  ```sql
  SELECT PJ.NUMERO, PJ.NOME, PJ.CNPJ,
         P.ANOMES, P.ID_PARC, P.DTEM, P.DTVENC, P.VALOR,
         P.DTPAG, P.VALOR_PAGO, P.VALOR_COMP,
         (COALESCE(P.VALOR_PAGO, 0) - COALESCE(P.VALOR_COMP, 0)) AS VL_LIQUIDO
  FROM clientes_pj PJ
  INNER JOIN parcelas P ON P.numero_adesao = PJ.numero_adesao
  WHERE PJ.empresa_id = :empresa_id
  ORDER BY P.numero_adesao, P.anomes;
  ```
- **Especificação para o Novo Sistema Web (`/relatorios/faturamento-pj`):**
  - Filtros: Empresa PJ (opcional), Situação da Fatura (`Todas`, `Abertas/A Vencer`, `Vencidas/Inadimplentes`, `Pagas`), Competência/Período (`Data Inicial`..`Data Final`), Situação da Empresa PJ (`Ativa`/`Inativa`/`Cancelada`).
  - Agrupamento por `PJ.NUMERO - PJ.NOME (CNPJ)` exibindo quantidade atual de funcionários ativos, faturas emitidas, valores nominais, valores pagos, tarifas de compensação, valor líquido recebido e saldo em aberto, com subtotais por empresa e total geral.

---

## 4. Requisitos de Exportação e Impressão na Nova Plataforma Web

1. **Visualização Interativa em Tela:** Todos os 7 relatórios devem primeiro renderizar os resultados na própria tela em tabelas ricas (com paginação, ordenação, totalizadores fixos no topo/rodapé e drill-down para a ficha do cliente), preservando e ampliando a experiência de `TFrmRelatoriosClientes`.
2. **Geração de PDF Oficial (Substituto do `RvRenderPDF`):** Gerar PDF A4 com cabeçalho institucional idêntico ao padrão `DVEmpresa` (logomarca da empresa ativa, CNPJ, endereço, telefones, título, parâmetros utilizados, usuário emissor, timestamp e numeração `Página X de Y`).
3. **Exportação Tabular (`XLSX` e `CSV` UTF-8 com BOM):** Disponibilizar exportação direta dos dados desnormalizados de qualquer relatório para análise em Excel/BI.
