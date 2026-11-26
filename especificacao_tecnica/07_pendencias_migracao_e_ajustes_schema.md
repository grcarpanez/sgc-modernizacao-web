# 07 — Pendências de Migração (ETL) e Ajustes no Schema Moderno

> **Propósito deste Documento:** Registrar problemas, lacunas de modelagem e decisões técnicas descobertas durante a revisão conjunta dos schemas (`01_schema_firebird_legado.sql` e `02_schema_postgresql_moderno.sql`). Este arquivo serve como **memória oficial para a IA Agêntica** revisar o `02_schema_postgresql_moderno.sql` antes do congelamento do banco e implementar corretamente o script de migração (`Firebird -> PostgreSQL`).
>
> **Status:** Em construção (atualizado conforme o avanço da leitura dos arquivos `.sql`).

---

## 1. Ajustes Pendentes no Schema (`02_schema_postgresql_moderno.sql`)

### 1.1 Unicidade de CPF em `clientes_pf` e Bloqueio Cruzado no PF
* **Estado Atual no SQL Moderno:** `clientes_pf.cpf` possui apenas um índice simples (`idx_clientes_pf_cpf`), sem constraint `UNIQUE`.
* **Decisão de Negócio:**
  * O sistema **deve impedir** a criação de dois cadastros de Titular PF para o mesmo CPF (ex-clientes que retornam devem passar pelo fluxo de **Reativação** — ver `08_rotinas_operacionais_nao_documentadas.md`).
  * Para **novos cadastros e inclusões no sistema novo**, o **backend** deve bloquear também que um mesmo CPF fique **Ativo (`situacao = 'A'`)** em mais de um vínculo PF ao mesmo tempo (Titular PF Ativo $\times$ Dependente PF Ativo). Se o vínculo anterior estiver Cancelado (`'C'`) ou Inativo (`'I'`), o CPF fica livre (e no cruzamento PF $\times$ PJ exibe apenas **alerta forte com confirmação**, sem bloqueio).
* **Ação no Schema:**
  * Adicionar `CONSTRAINT uq_clientes_pf_cpf UNIQUE (cpf)` em `clientes_pf`.
  * *Nota técnica PostgreSQL:* `UNIQUE (cpf)` permite múltiplos `NULL` (usado para CPFs inválidos/ausentes do legado preservados em `cpf_legado_bruto`), mas bloqueia estritamente qualquer CPF válido duplicado dentro de `clientes_pf`.
  * *Compatibilidade na Migração:* Como o bloqueio cruzado (Titular PF $\times$ Dependente PF) fica no **backend**, a carga inicial do `ABAC.FDB` não quebra caso haja registros históricos cruzados assinados no legado.

---

### 1.2 Colisão na Constraint `uq_parcelas_adesao_anomes` (`(num_adesao, anomes)`)
* **Estado Atual no SQL Moderno:**
  ```sql
  CONSTRAINT uq_parcelas_adesao_anomes UNIQUE (num_adesao, anomes)
  ```
* **Por que isso é um problema herdado do Firebird:**
  No legado, a PK era `(NUM_ADESAO, ANOMES)`. Como `ANOMES` tem apenas 4 caracteres, ocorrem **3 colisões reais** na operação:
  1. **Taxa de Adesão / Reativação (`'0000'`):** Um cliente pode passar por **"infinitas" reativações** ao longo da vida. Ele já possui `'0000'` da adesão original, então não é possível gerar outro `'0000'` se a unicidade for `(num_adesao, anomes)`.
  2. **Parcela `'ÚNICA'` (`AA + '99'` / `AA + '98'`):**
     * *Caso histórico (2018):* Na troca de banco por exigência da FEBRABAN (cobrança registrada), carnês já emitidos no ano precisaram ser cortados e reemitidos no mesmo ano — como `'1899'` já estava ocupado, foi necessário criar um código emergencial `'1898'`.
     * *Caso recorrente (Reativação no mesmo ano):* Cliente cancelou em fevereiro (carnê tinha `'2699'` e parcelas até novembro) e reativa em julho para gerar novo carnê a partir de agosto. O novo carnê também exigiria `'2699'`, colidindo com o carnê cancelado!
  3. **Meses sobrepostos (`YYMM`):** Parcelas futuras em aberto do carnê cancelado/substituído colidem com os meses do novo carnê caso não sejam deletadas (perdendo histórico no legado).

* **Diretriz de Solução para o Schema Moderno (a revisar na versão final do SQL):**
  * **Regra Universal de Carnê (1 Parcela = 1 Carnê):** Toda e qualquer parcela/boleto do sistema pertence obrigatoriamente a **1 e somente 1 carnê** (`carnes`, via `num_carne NOT NULL`): carnê anual PF (`CARNE_PF`), fatura mensal PJ (`BOLETO_PJ`), taxa de adesão (`ADESAO`), taxa de reativação (`REATIVACAO`), acordo/renegociação (`RENEGOCIACAO`) ou cobrança de 2ª via (`SEGUNDA_VIA`).
  * **Regra interna do banco de dados:** Alterar a unicidade estrutural da lâmina para **`(num_carne, anomes)`** (garantindo que não haja repetição dentro do mesmo carnê, mas permitindo novos carnês em reativações, reemissões no mesmo ano e acordos sem precisar da gambiarra `'YY98'`).
  * **Preservação visual no Boleto e Carnê:** Essa alteração é **estritamente interna no banco de dados** — as colunas `num_adesao` e `anomes` permanecem intactas na tabela `parcelas` e continuam sendo exibidas normalmente no campo **`Nº do Documento`** do boleto/carnê (conforme padrão do item **1.5**), garantindo que colaboradoras e associados identifiquem facilmente a competência (`anomes`) mesmo quando várias parcelas atrasadas caírem no mesmo vencimento.
  * **Classificação de Origem (`tipo_parcela`) e Status Financeiro (`situacao_parcela`):**
    * **`tipo_parcela_enum` (`tipo_parcela`):** Define a natureza/origem exata de cada parcela:
      1. `MENSALIDADE_PF` (parcelas mensais comuns `01/12`..`12/12` do carnê PF);
      2. `COTA_UNICA_ANUAL` (lâmina opcional `'ÚNICA'` com desconto anual — nunca gera inadimplência);
      3. `FATURA_MENSAL_PJ` (boleto mensal corporativo de empresa PJ);
      4. `TAXA_ADESAO` (taxa inicial `'0000'` de entrada PF ou PJ — traz por padrão o valor definido na configuração/plano, com opção na tela de cadastro para isentar ou definir valor negociado no contrato);
      5. `TAXA_REATIVACAO` (taxa de retorno/reativação de ex-cliente PF ou PJ — traz por padrão o valor da configuração/plano, também com opção de isentar ou negociar o valor);
      6. `TAXA_MANUTENCAO` (taxa de manutenção anual do contrato PF ou PJ — traz por padrão o valor definido na configuração/plano, permitindo isentar ou negociar o valor no cadastro do contrato como margem comercial; nos carnês PF a partir do 2º ano vai somada/embutida na parcela `'01/12'` e na `'ÚNICA'`, registrada também na coluna `valor_taxa_manutencao_embutida NUMERIC(12,2) NOT NULL DEFAULT 0.00`, ou faturada no aniversário anual PJ quando não isenta);
      7. `ACORDO_RENEGOCIACAO` (parcelas `REN 01/M`..`REN M/M` de acordo parcelado ou consolidação `'DEBIT'`);
      8. `TAXA_SEGUNDA_VIA` (cobrança futura de emissão de 2ª via de cartão/carnê).
    * **`situacao_parcela_enum` (`situacao_parcela`):** Define o estado financeiro no ciclo de vida da parcela:
      1. `ABERTA` (não paga: *A Vencer* se `data_vencimento >= CURRENT_DATE`, ou *Vencida/Inadimplente* se `data_vencimento < CURRENT_DATE`);
      2. `PAGA` (liquidada com entrada financeira real no caixa/banco: `valor_pago > 0`);
      3. `QUITADA_POR_UNICA` (mensalidade `01/12`..`12/12` baixada em cascata com `valor_pago = 0.00` pelo pagamento da `COTA_UNICA_ANUAL`);
      4. `RENEGOCIADA` (parcela original atrasada encerrada com `valor_pago = 0.00` e transferida para um acordo `ACORDO_RENEGOCIACAO` ainda em andamento);
      5. `QUITADA_POR_ACORDO` (status assumido automaticamente pelas parcelas originais `RENEGOCIADA`, mantendo `valor_pago = 0.00` para não duplicar o caixa, no exato momento em que o cliente termina de pagar todas as $M$ parcelas do acordo vinculado);
      6. `PERDOADA` (parcela antiga dispensada com `valor_pago = 0.00` mediante autorização de alçada de Gerente/Administrador na reativação);
      7. `CANCELADA` (parcela futura de carnê interrompido/cancelado, preservando 100% da auditoria sem `DELETE` físico).
  * **Trava contra mensalidade duplicada:** Para evitar cobrança mensal duplicada sem bloquear acordos parcelados no mesmo mês (ex.: mensalidade `2610` em um carnê `CARNE_PF` + parcela `02/04` do acordo também em `2610` em um carnê `RENEGOCIACAO` distinto), a restrição de "apenas 1 parcela ativa por mês" aplica-se no backend apenas a **carnês mensais regulares (`CARNE_PF` / `BOLETO_PJ`)**, permitindo a convivência com carnês de `RENEGOCIACAO` (e como estarão em `num_carne` diferentes, `(num_carne, anomes)` nunca colide).
  * Taxas de adesão (`'0000'`) e reativações (`'REATIVACAO'`) nascem **`ABERTA`** dentro de seu próprio `num_carne` (`ADESAO` / `REATIVACAO`) e exigem liquidação (manual ou automática) como gatilho para efetivar o cliente e liberar a geração do carnê.

---

### 1.3 Fila de Geração de Carnês (`fila_geracao_carnes`) e Isenção da Taxa de Manutenção Anual Pós-Reativação
* **Conceito de Negócio (Taxa de Adesão vs. Taxa de Manutenção Anual):**
  * No 1º ano (entrada do associado), cobra-se a **Taxa de Adesão** (`TAXA_ADESAO`, ou `TAXA_REATIVACAO` no retorno de ex-cliente). Por isso, o 1º carnê `CARNE_PF` (`12+1`) nunca possui acréscimo na `01/12` nem na `ÚNICA`.
  * A partir do 2º ano (renovações anuais subsequentes de PF), aquele valor adicional somado à parcela `'01/12'` ($M + A$) e à `'ÚNICA'` ($(12 \times M \times 0,80) + A$) é oficialmente a **Taxa de Manutenção Anual** (que tem a mesma natureza da taxa de adesão, porém cobrada anualmente na renovação do carnê PF).
  * **Regra Comercial para PF e PJ (Valor Padrão na Configuração + Opção de Isentar ou Negociar no Contrato):** Tanto para **PF** quanto para **PJ**, as duas taxas (**Taxa de Adesão/Reativação** e **Taxa de Manutenção Anual**) possuem **valor padrão oficial definido na configuração/plano** (criando margem/"gordura" comercial de negociação). Na tela de cadastro/contrato (e na reativação), o sistema exibe o valor padrão configurado e oferece a opção de **isentar** ou **informar um valor negociado** para aquele contrato (registrando em `clientes_pj` / `clientes_pf` se a taxa é isenta ou qual o valor negociado, respeitando a alçada de autorização quando aplicável).
* **Necessidade Real na Reativação PF:**
  * Quando um cliente PF passa por **Reativação**, ele já paga a taxa de reativação no ato (ou tem sua condição aprovada), portanto o **primeiro carnê `CARNE_PF` (`12+1`) gerado após a reativação NÃO deve cobrar a Taxa de Manutenção Anual** ($A = 0,00$), exatamente como ocorre no 1º carnê de um cliente novo.
  * **Proteção contra conflito com Renegociação:** Um carnê de **`RENEGOCIACAO`** (que pode ocorrer antes ou depois da reativação) **nunca** cobra taxa de manutenção anual e **nunca** consome nem zera a isenção do cliente.
* **Ação no Schema (Modelo Híbrido: Fila + Varredura):**
  * Criar a tabela **`fila_geracao_carnes`** (`id`, `num_adesao`, `tipo_origem` [`ADESAO`, `REATIVACAO`], `parcela_gatilho_id` [`REFERENCES parcelas(id)`], `isento_taxa_manutencao BOOLEAN NOT NULL DEFAULT TRUE`, `status` [`PENDENTE`, `PROCESSADO`, `CANCELADO`], `carne_gerado_numero` [`REFERENCES carnes(numero)`], `created_at`, `processado_em`, `created_by`);
  * **Regra Estrita da Fila e da Remessa de Carnês:**
    * Apenas pedidos de carnê padrão **`12+1` (`tipo_carne = 'CARNE_PF'`)** entram em `fila_geracao_carnes` (disparados automaticamente na quitação da taxa de `ADESAO` ou `REATIVACAO` PF).
    * Boletos de **`ADESAO`** (1 boleto), **`REATIVACAO`** (1 boleto), **`RENEGOCIACAO`** (acordo) e **`SEGUNDA_VIA`** **nunca** entram nessa fila nem na remessa periódica de geração de carnês — são impressos/enviados diretamente ao associado pelo operador no ato da operação.
  * Na geração periódica de carnês (`CARNE_PF`), o sistema combina: (1) os itens `PENDENTE` de `fila_geracao_carnes` (sempre com Taxa de Manutenção Anual $A = 0,00$) e (2) a varredura de renovação dos clientes ativos existentes que atingiram o gatilho da `10/12` quitada dentro da janela de 60 dias (com $A = \text{valor\_taxa\_manutencao\_anual}$ do plano).
  * *(Opcionalmente, manter também `isento_taxa_proxima_renovacao BOOLEAN NOT NULL DEFAULT FALSE` em `clientes_pf` como trava redundante, consumida **exclusivamente** por `tipo_carne = 'CARNE_PF'`.)*

---

### 1.4 Separação entre Vencimento Real da Competência e Vencimento de Registro/Impressão
* **Contexto:** Quando um cliente quita o carnê anterior com meses de atraso, as parcelas retroativas do novo carnê (ex.: março a julho geradas em julho) não podem ser registradas no banco com data de vencimento no passado (bancos rejeitam boletos vencidos na remessa).
* **Regra Crítica de Caixa/Impressão:** A data de vencimento impressa no carnê/boleto **DEVE ser idêntica** à data registrada no banco (CNAB 240), pois divergência entre o papel e o registro bancário faz o caixa/lotérica recusar o recebimento.
* **Necessidade Real e Ação no Schema:**
  * Manter `parcelas.data_vencimento` com o **vencimento real/original** da competência (`anomes`) para controle interno e histórico;
  * Criar **`data_vencimento_remessa DATE`** (opcional, preenchida quando houver ajuste de vencimento passado para o próximo vencimento válido do cliente);
  * Tanto na **remessa CNAB 240** quanto na **impressão do carnê/boleto em PDF**, utilizar obrigatoriamente **`COALESCE(data_vencimento_remessa, data_vencimento)`** como data de vencimento oficial, exibindo a competência original (`anomes` / `MM/AAAA`) no `Nº do Documento` e no campo de observação da lâmina.

---

### 1.5 Identificação Única no Sicoob CNAB 240 (`Nosso Número`, `Nº do Documento`, `Uso da Empresa` e `Informação 3/4`)
* **Verificação no Layout Oficial Sicoob (`Layouts_para_troca_de_informações - cooperativas.xls`, aba `03.Remessa - Opção CNAB240`) e no Boleto Real (`Modelo Boleto.pdf`):**
  1. **`Nosso Número` (Impresso no boleto | Seg. `P` `38..57` / Retorno `T` `38..57`):** Os `10` primeiros bytes são o `NumTitulo` (`7 dígitos` sequenciais via `seq_nosso_numero_sicoob` + `1` DV Módulo 11 `3197`, preenchidos com zeros à esquerda). É **único globalmente por parcela** — nunca se repete entre carnês e é a chave principal de conciliação.
  2. **`Nº do Documento` ("Seu Número" — Impresso no boleto | Seg. `P` `63..77` / Retorno `T` `59..73`):** Suporta **15 caracteres** (usar **somente dígitos numéricos**). Mantém visível no boleto e no carnê a identificação **`num_adesao + anomes(4) + tipo(1 dígito)`** (ex.: adesão `19500`, competência `2610`, carnê regular `1` $\to$ `1950026101`), preservando a leitura imediata da adesão e da competência (`anomes`) e evitando confusão entre mensalidade e acordo na mesma competência:
     * `1` = Carnê Regular PF / Boleto Mensal PJ (`CARNE_PF`, `BOLETO_PJ`)
     * `2` = Taxa de Adesão Inicial (`ADESAO`)
     * `3` = Taxa de Reativação (`REATIVACAO`)
     * `4` = Renegociação / Acordo / Consolidação (`RENEGOCIACAO`, `DEBIT`)
  3. **`Uso Empresa Beneficiário` (Invisível no papel do boleto | Seg. `P` `196..220` / Retorno `T` `106..130`):** Suporta **25 caracteres**, não é impresso para o pagador e é devolvido integralmente pelo Sicoob no arquivo de retorno.
  4. **Mensagem / Observação Impressa no Boleto (Seg. `R`, campos `18.3R Informação 3` [`100..139`, 40 chars] e `19.3R Informação 4` [`140..179`, 40 chars]):** Texto impresso no quadro *"Termo de Responsabilidade do Beneficiário"* do boleto Sicoob (e também nos PDFs próprios de carnê). O sistema **deve preencher automaticamente** esses campos em `Mov = '01'` (já em **MAIÚSCULAS, sem acentos e sem caracteres especiais**, ex.: `"MENSALIDADE 10 2026 CARNE REGULAR"`, `"ACORDO 02 DE 04 REF 10 2026"`, `"TAXA DE REATIVACAO ADESAO 19500"`), dando total clareza ao associado. *(Na Solicitação de Baixa `Mov = '02'` e Abatimento `'04'`/`'05'`, o Segmento `R` é omitido, enviando apenas o par `P` + `Q` com o mesmo código de movimento — ver `04_regras_negocio_financeiro_cnab_arquivos.md` Seção 3.3.)*
* **Diretriz Unificada (Papel + Banco/CNAB):**
  * **`Nosso Número`** identifica unicamente cada título no banco;
  * **`Nº do Documento`** garante a leitura humana clara de **`num_adesao + anomes + tipo`** no boleto/carnê impresso (atendendo ao item **1.2**);
  * **`Informação 3 e 4` (Segmento `R`)** explicam em texto legível no boleto o que é a parcela, sua competência e tipo;
  * **`Uso da Empresa` (25 posições)** grava a chave composta completa **`PadLeftZero(num_carne, 8) + PadLeftZero(num_adesao, 8) + anomes(4)`** (20 dígitos), garantindo conciliação 100% inequívoca no retorno bancário mesmo entre múltiplos carnês do mesmo associado no mesmo ano ou entre mensalidade e acordo no mesmo mês.

---

### 1.6 Suporte a Renegociação / Acordo Parcelado (Relação `N:M` em vez de apenas `N:1`)
* **Estado Atual no SQL Moderno:** `parcelas.parcela_consolidadora_id` aponta para apenas **1** parcela destino (atendendo somente o `'DEBIT'` à vista/`1x`).
* **Necessidade Real:** Permitir que $N$ parcelas vencidas (ex.: 4 parcelas de R\$ 25,00 = R\$ 100,00) sejam renegociadas em $M$ novas parcelas de acordo (ex.: 3x, sendo a 1ª parcela de R\$ 33,34 e as 2 demais de R\$ 33,33, podendo ter valores que não são múltiplos das parcelas originais, além de juros ou descontos).
* **Regra de Arredondamento / Sobra de Centavos (Diferença na 1ª Parcela):** Quando a divisão do valor total negociado ($V_{\text{total}}$) por $M$ parcelas gerar sobra/resíduo de centavos ($V_{\text{base}} = \text{TRUNC}(V_{\text{total}} / M,\; 2)$ e $\text{sobra} = V_{\text{total}} - (M \times V_{\text{base}})$), **essa diferença entra obrigatoriamente na 1ª parcela do acordo (`REN 01/M`)** ($V_1 = V_{\text{base}} + \text{sobra}$ e $V_{2\dots M} = V_{\text{base}}$), garantindo que a soma das $M$ parcelas feche 100% com o valor negociado sem perda de centavos.
* **Ação no Schema e Ciclo de Vida das Parcelas Originais vs. Acordo:**
  * Criar estrutura de vínculo `N:M` (ex.: tabela `renegociacoes` + `renegociacao_itens` ligando as $N$ parcelas originais ao carnê/parcelas do acordo).
  * **No momento em que o acordo é firmado:** As $N$ parcelas originais recebem baixa técnica de substituição com **`valor_pago = 0.00`** e **`situacao_parcela = 'RENEGOCIADA'`** (`origem_baixa = 'RENEGOCIACAO'`), saindo da fila de cobrança individual sem inflar o caixa, enquanto as $M$ novas parcelas do acordo nascem com **`tipo_parcela = 'ACORDO_RENEGOCIACAO'`**, **`situacao_parcela = 'ABERTA'`**, `nosso_numero` próprio, registro CNAB e baixa automática pelo retorno bancário.
  * **No momento em que o cliente quita a última das $M$ parcelas do acordo:** As $N$ parcelas originais vinculadas àquele acordo têm seu status atualizado automaticamente de **`'RENEGOCIADA'`** para **`'QUITADA_POR_ACORDO'`** (permanecendo sempre com **`valor_pago = 0.00`** para jamais duplicar o caixa, já que o dinheiro entrou nas parcelas `ACORDO_RENEGOCIACAO`, funcionando exatamente como o `QUITADA_POR_UNICA`).
  * **Impacto nos Relatórios de Inadimplência:** O Relatório de Clientes Inadimplentes (`REL-03`) terá:
    1. **Filtro Geral de Inadimplentes (Padrão):** Lista todos os clientes com parcelas `ABERTA` e vencidas, englobando tanto mensalidades regulares (`MENSALIDADE_PF` / `FATURA_MENSAL_PJ`) quanto parcelas de acordo vencidas (`ACORDO_RENEGOCIACAO`);
    2. **Filtro Exclusivo de Inadimplência de Renegociações:** Exibe apenas clientes que atrasaram parcelas de acordo (`tipo_parcela = 'ACORDO_RENEGOCIACAO'` com `situacao_parcela = 'ABERTA'` e vencidas);
    3. **Filtro Exclusivo de Mensalidades Regulares:** Exibe apenas inadimplência de parcelas normais, sem acordos.

---

### 1.7 Meio de Pagamento (`forma_pagamento_enum`) e Substituição de `empresas` + `convenios` por `unidades`
* **Descoberta Crítica sobre o Legado:** No sistema legado, a tabela `CONVENIOS` (`COD_CONVENIO` `0..19`) **nunca foi usada para comissionados** — ela já armazena na prática a **Matriz (`JUIZ DE FORA`, ID `4`) e todas as Filiais**.
* **Estrutura Unificada (Decisão Final):**
  * **Remover a tabela `convenios`** e **renomear/transformar `empresas` em `unidades`** (uma única tabela contendo Matriz + Filiais, identificada por `eh_matriz BOOLEAN NOT NULL DEFAULT FALSE`, onde `JUIZ DE FORA` é `TRUE` e concentra CNPJ oficial, Razão Social, Nome Fantasia e Logomarca para boletos/relatórios).
  * `contas_cobranca` fica vinculada à unidade matriz (ou à tabela `unidades`), pois a conta bancária é única na matriz.
  * `clientes_pj` = **Empresas Clientes** (contratantes para funcionários).
  * *(Empresas Credenciadas / Parceiros ainda não modeladas — avaliar separadamente se necessário).*
* **Ação no Schema e ETL:**
  1. Criar `forma_pagamento_enum` (`DINHEIRO`, `PIX`, `CARTAO_DEBITO`, `CARTAO_CREDITO`, `BOLETO_BANCARIO`, `LEGADO`, `OUTRO`) e coluna `forma_pagamento` em `parcelas`.
  2. Migrar `CONVENIOS` (`0..19`) diretamente para **`unidades`** preservando os IDs originais (e mesclar os dados de `EMPRESA` — CNPJ, Razão Social, Logomarca — no registro matriz `id = 4` / `JUIZ DE FORA`). Verificar na migração os dois registros `LEOPOLDINA` (`14` e `15`).
  3. **Substituir todas as referências a `empresas(id)` / `empresa_id` no schema moderno:**
     * `seq_empresa_id` $\to$ `seq_unidade_id` (sincronizada após migração com `MAX(unidades.id) + 1`);
     * `usuarios.empresa_id` (linha 105) $\to$ `unidade_id` *(aceitando `NULL` para perfis externos)*;
     * `adesoes.empresa_id` (linha 168) $\to$ `unidade_id`;
     * `lotes_arquivos.empresa_id` (linha 332) $\to$ `unidade_id` *(avaliar também `conta_cobranca_id` nos lotes bancários)*;
     * `fila_segunda_via.empresa_id` (linha 421) $\to$ `unidade_id`.
  4. Em `clientes_pf`, `convenio_id` passa a se chamar **`unidade_cadastro_id`** (preenchida automaticamente pela unidade do usuário logado no ato do cadastro).
  5. Vincular `usuarios` a `unidade_id` e adicionar `unidade_recebimento_id` (FK -> `unidades.id`) em `parcelas`.
  6. **RBAC por Unidade:** Usuários comuns só visualizam/operam registros da sua própria `unidade_id`; supervisores podem ter acesso regionalizado e Administradores acesso global.

---

### 1.8 Refatoração de `unidades` (ex-`empresas`): Separação da Central de Cobrança e Gestão de Planos/Adicionais
* **Decisões na Tabela `unidades` (Matriz/Filiais):**
  * **Remover `data_proxima_geracao_carne` (`DATA_ARQ`):** O lembrete quinzenal legado foi descartado por decisão de negócio (ignorar `EMPRESAS.DATA_ARQ` no ETL).
  * **Responsável pela Unidade:** Adicionar **`responsavel_usuario_id BIGINT REFERENCES usuarios(id)`** (opcional) para vincular cada matriz/filial ao login do usuário responsável por ela.
  * **Preservação de IDs no Módulo 1:** Como o Módulo 1 (Rede Credenciada) entrará em produção antes da migração do legado (`ABAC.FDB`), as unidades já devem ser cadastradas preservando os mesmos IDs do antigo `CONVENIOS` (`0..19`, sendo `4 = JUIZ DE FORA`) para garantir encaixe sem conflitos no ETL futuro.
  * **Dividir nome em `razao_social` + `nome_fantasia` (e/ou `nome` da unidade):**
    * No ETL, `EMPRESAS.NOME_EMPRESA` migra para `razao_social` da unidade matriz (`eh_matriz = TRUE`).
    * Nos layouts posicionais e CNAB 240 (Header de `REMADESAO`, `REMESSA` e `CNAB 240`), utilizar **`razao_social`** da unidade matriz (nome oficial atrelado ao CNPJ do cedente).
    * Na interface web e relatórios PDF, utilizar `COALESCE(nome_fantasia, razao_social)`.
* **Nova Tabela `contas_cobranca` (Central de Contas Bancárias):**
  * Extrair os parâmetros bancários (`agencia`, `dv_agencia`, `conta`, `dv_conta`, `codigo_cedente`, `carteira`, `modalidade`, `percentual_multa`, `juros_mora_dia`, `codigo_banco`, `nsa_sequencial`, `padrao`, `ativo`, `created_by`, `updated_by`) para tabela própria vinculada à matriz.
  * **Preparação Futura para API Bancária (`API_SICOOB_V3`):** Prever coluna `modo_integracao` (`CNAB_240` [padrão inicial] ou `API_SICOOB_V3`) e campos opcionais (`numero_cliente_sicoob`, `numero_contrato_cobranca`), mantendo credenciais/certificado e-CNPJ fora do banco (cofre de segredos).
  * Permite múltiplos bancos (Sicoob `756`, Caixa `104`, Banco do Brasil `001`, etc.) sem depender de colunas fixas por banco.
  * **Extinguir `banco_cobranca_enum`** e substituir as colunas `clientes_pf.banco_cobranca` e `lotes_arquivos.banco_cobranca` pela chave estrangeira **`conta_cobranca_id REFERENCES contas_cobranca(id)`**.
* **Novas Tabelas de Gestão de Planos, Combos, Benefícios Adicionais e Parâmetros Administrativos:**
  * Extrair os preços únicos (`valor_base_plano_pf`, `valor_adicional_dependente_pf`, `desconto_parcela_unica_percent`) da antiga tabela `empresas`.
  * Criar **`planos`**: cadastro de planos (ex.: *Básico*, *Bronze*, *Plus*), contendo `plano_base_id` (opcional -> `planos(id)`, quando o plano é um pacote montado sobre um plano base), `valor_titular`, `valor_dependente`, **`valor_taxa_adesao`** (matrícula), **`valor_taxa_reativacao`** (retorno de ex-cliente), **`valor_taxa_manutencao_anual`** (nomenclatura oficial que substitui o antigo *"acréscimo de renovação"*, representando a taxa anual cobrada a partir do 2º carnê PF na parcela `'01/12'` e na `'UNICA'`, **sem desconto** na cota única: `UNICA = (mensalidade * 12 * 0,80) + taxa_manutencao`), `desconto_parcela_unica_percent`, `ativo`, `created_by`, `updated_by`. Na criação de pacotes, o sistema soma `plano_base + adicionais` como **sugestão**, permitindo ao Administrador definir um preço final fechado diferente (ex.: desconto de combo).
  * Criar **`beneficios_adicionais`** (ex.: *Seguro Funeral*, *Seguro Casa*, *Cuidado Pet*) e **`plano_beneficios_inclusos`** (N:M ligando quais adicionais já vêm embutidos em um plano pacote), além do vínculo avulso **`cliente_beneficios_adicionais`** (N:M com o cliente), permitindo tanto **pacotes prontos** quanto **plano base + benefícios agregados**.
  * Criar **`configuracoes_sistema`** (área administrativa exclusiva do `ADMINISTRADOR`): armazena parâmetros globais de negócio que não devem ficar soltos na tela do operador, como **`max_parcelas_aberto_renovacao`** (tolerância de parcelas vencidas na renovação de carnês), **`janela_renovacao_carne_dias`** (default `60`) e os parâmetros de cobrança de 2ª via (**`cobrar_segunda_via_carne`** `BOOLEAN DEFAULT FALSE`, **`valor_segunda_via_carne`** `NUMERIC(12,2) DEFAULT 0.00`, **`cobrar_segunda_via_cartao`** `BOOLEAN DEFAULT FALSE`, **`valor_segunda_via_cartao`** `NUMERIC(12,2) DEFAULT 0.00`).

---

### 1.9 Auditoria Direta nas Tabelas (`created_by` e `updated_by`)
* **Estado Atual no SQL Moderno:** As tabelas possuem `created_at` e `updated_at`, mas não possuem colunas diretas de autoria (`created_by` / `updated_by`), ficando a identificação do usuário apenas em `auditoria_eventos` (ou `baixado_por_usuario_id` em `parcelas`).
* **Ação no Schema:** Padronizar **`created_by BIGINT REFERENCES usuarios(id)`** e **`updated_by BIGINT REFERENCES usuarios(id)`** em `unidades` e nas demais tabelas principais de cadastro/negócio (permitindo `NULL` para registros iniciais de seed/ETL legado).

---

### 1.10 Revisão Completa do RBAC em `usuarios` (Ao Final do Mapeamento)
* **Estado Atual no SQL Moderno:** A tabela `usuarios` replica as 14 flags booleanas do legado + 4 novas, incluindo itens que mudaram de significado ou deixaram de existir (`perm_convenios_*` $\to$ unidades, `perm_mudar_conexao`, `perm_emitir_adesao` pré-impressa) e ainda não contempla novas áreas (`unidades`, `planos`, `contas_cobranca`, `reativacao`, `renegociacao`, escopo multi-unidade).
* **Ação no Schema:**
  * Incluir `created_by` e `updated_by` em `usuarios`;
  * **Papel / Perfil de Acesso (`role` / `perfil_usuario_enum`):** Prever **8 perfis oficiais** para isolar completamente ambientes e dados:
    1. **`ADMINISTRADOR`** (acesso global e único autorizado a destravar `bloqueio_divulgacao_valores` do CRM);
    2. **`COLABORADOR`** (acesso restrito à sua `unidade_id` ou unidades autorizadas);
    3. **`ASSOCIADO_PF`** (vê apenas seu contrato, dependentes, carnês e rede);
    4. **`DEPENDENTE_PF`** (vê apenas sua carteirinha, seus dados, suas solicitações e rede);
    5. **`EMPRESA_PJ`** (contato autorizado vê apenas o contrato da sua empresa, faturas e funcionários);
    6. **`FUNCIONARIO_PJ`** (vê apenas sua carteirinha, seus dependentes e rede);
    7. **`DEPENDENTE_PJ`** (vê apenas sua carteirinha e rede);
    8. **`PARCEIRO`** (rede credenciada — vê apenas seus próprios dados, tabelas, patrocínios e futuras autorizações/atendimentos).
  * **Isolamento Total de Dados (Escopo no Servidor + RLS):** Garantir no backend (e reforçar com *Row-Level Security* no PostgreSQL) que cada perfil acesse estritamente os registros vinculados à sua titularidade/unidade/parceiro.
  * **Permissões do Módulo de Parceiros:** Separar visualização (`perm_parceiros_consultar`), edição cadastral (`perm_parceiros_dados`), ajuste de tabelas de preços (`perm_parceiros_precos_editar`) e gestão de destaques (`perm_parceiros_destaques`), mantendo a alteração do cadeado CRM exclusiva de `ADMINISTRADOR`.
  * **Permissão de Alçada Financeira:** Incluir **`perm_autorizar_desconto_perdao`** (atribuída a Administradores e Gerentes de unidade) para autorizar descontos em acordos ou perdão de dívidas antigas em reativações.
  * **Substituir `empresa_id` por `unidade_id`** (`REFERENCES unidades(id)`), já que a antiga tabela `empresas` foi unificada e transformada na tabela `unidades` (que reúne Matriz e Filiais) *(permitindo `NULL` para perfis externos, e obrigatório para `COLABORADOR`)*;
  * **Escopo de Visibilidade por Unidade no RBAC:** Prever flag booleana de **visualização global** (vê todas as unidades) **e/ou** tabela associativa de **permissão regionalizada** (ex.: `usuario_unidades_acesso` listando quais unidades específicas aquele login pode visualizar, ex.: supervisor regional), mantendo como padrão apenas a própria `unidade_id`;
  * **Revisar integralmente a matriz de permissões (RBAC)** ao término da leitura de todas as tabelas e mapeamento das áreas do sistema.

---

### 1.11 Simplificação da Tabela `adesoes`
* **Decisões sobre Colunas:**
  * Manter **`adesoes`** como supertabela de contratos (`PF` e `PJ`) garantindo a unicidade global de `numero` entre `clientes_pf`, `clientes_pj`, `carnes`, `parcelas` e `fila_segunda_via`.
  * **Remover `remessa_adesao`** (e o índice `idx_adesoes_remessa`), pois o sistema novo não gera lotes de números/fichas pré-impressas em branco (`REMADESAO`).
  * **Remover `DEFAULT 'PF_PRE_IMPRESSO'`** de `tipo_contrato` (novos contratos serão apenas `'PF'` ou `'PJ'`).
  * **`empresa_id` $\to$ `unidade_id`:** Indica a unidade de origem do contrato (não aponta para cliente; são `clientes_pf.numero` e `clientes_pj.numero` que apontam para `adesoes.numero`).
  * Manter `data_emissao` (data comercial/contratual) + `created_at` / `created_by` (auditoria técnica exata).
* **ETL:** Listagens antigas de números de adesão pré-impressos não utilizados não precisam ser migradas.

---

### 1.12 Refatoração da Tabela `clientes_pf`
* **Unidade e Plano:**
  * `convenio_id` $\to$ **`unidade_id`** (`REFERENCES unidades(id)`).
  * `banco_cobranca` $\to$ avaliar vínculo com **`conta_cobranca_id`** (`REFERENCES contas_cobranca(id)`).
  * Adicionar **`plano_id`** (`REFERENCES planos(id)`), mantendo **`valor_plano`** como valor mensal consolidado vigente do associado (`plano + adicionais + dependentes`, ou valor histórico migrado), além da tabela N:M `cliente_beneficios_adicionais`.
  * Prever flag `isento_taxa_proxima_renovacao BOOLEAN NOT NULL DEFAULT FALSE` (para reativações).
* **Sexo / Gênero:** Substituir `CHAR(1) IN ('M','F')` por enum abrangente (ex.: `M` = Masculino, `F` = Feminino, `NB` = Não-binário, `O` = Outro, `NI` = Não informado, aceitando `NULL` no legado).
* **Remoção do Campo `rg`:** Remover `rg` de `clientes_pf` (e de `funcionarios_pj`), pois o documento regente atual é o CPF. *(Impacto verificado: no exportador gráfico `REMESSA` / `SEG_VIA` de 350 bytes, posições `86..99` passam a ser preenchidas com 14 espaços em branco).*
* **Telefones:** Substituir `telefone_comercial`, `telefone_residencial_fax`, `telefone_celular` por **`telefone1`**, **`telefone2`**, **`telefone3`**, cada um acompanhado de sua respectiva flag booleana **`telefone1_whatsapp`**, **`telefone2_whatsapp`**, **`telefone3_whatsapp`** (`DEFAULT FALSE`).
* **Dia de Vencimento:** Regra de negócio para novos cadastros restrita a **`5, 10, 15, 20, 25`** (validar na migração se existem dias diferentes no legado antes de impor `CHECK IN (5,10,15,20,25)` no banco).
* **Ciclo de Vida e Auditoria:**
  * Manter `data_inscricao`, `data_cancelamento`, `motivo_cancelamento` e adicionar **`data_reativacao`** (representando o último evento atual);
  * Histórico completo de múltiplos cancelamentos e reativações registrado em `auditoria_eventos` (ou tabela dedicada `historico_clientes_eventos` com tipo, data, motivo e `usuario_id`);
  * `updated_at` e **`updated_by`** guardam a última alteração; o histórico completo de todas as edições fica em `auditoria_eventos`;
  * Adicionar **`created_by`** e **`updated_by`**.

---

### 1.13 Papel de `auditoria_eventos` vs. Histórico de Benefícios e 2ª Via
* **`auditoria_eventos` (Escopo Global Técnico):** Mantida exclusivamente como trilha forense/técnica do sistema inteiro (logins, logouts, criações, edições com `dados_anteriores`/`dados_novos`, baixas, estornos, cancelamentos, reativações, remessas e mudanças de plano/dependentes).
  * **Filtros Obrigatórios de Consulta:** Os logs devem poder ser filtrados por **data**, **intervalo de data**, **login (usuário)**, **tipo de evento** e **entidade**.
* **Histórico de 2ª Via e Uso de Benefícios (Escopo de Negócio/Futuro):**
  * Solicitações de 2ª via de carnê e carteirinha podem ser rastreadas via `fila_segunda_via` (preservando histórico de solicitações, não apenas fila volátil);
  * Quando o módulo de **Parceiros / Empresas Credenciadas** for implementado, criar tabela dedicada de **autorizações / utilização de benefícios** (com parceiro, associado/dependente, valor tabela vs. valor com desconto e economia gerada) para viabilizar o relatório de **economia anual do associado**, sem misturar esses dados de negócio com o log técnico de `auditoria_eventos`.

---

### 1.14 Busca Inteligente por Fragmentos de Nome (`pg_trgm` + `unaccent`)
* **Comportamento Esperado na Busca de Clientes/Dependentes:** Ao digitar múltiplos fragmentos separados por espaço (ex.: `"gus ri car"` ou até meios de palavras como `"tav eir pan"` para localizar `"GUSTAVO RIBEIRO CARPANEZ"`), o backend deve quebrar o termo pelos espaços e aplicar filtro `AND` com `ILIKE '%termo%'` ignorando acentos (`unaccent`), aproveitando os índices `GIN (gin_trgm_ops)`.
* **Ajuste Técnico no Schema:** Avaliar uso de expressão/coluna normalizada (ex.: `unaccent` imutável ou coluna gerada sem acento indexada com `gin_trgm_ops`) para garantir que o índice `GIN` seja usado mesmo com remoção de acentos.

---

### 1.15 Refatoração da Tabela `dependentes_pf` e Benefícios por Dependente
* **Novas Colunas em `dependentes_pf`:**
  * **`ativo BOOLEAN NOT NULL DEFAULT TRUE`**, **`data_exclusao DATE`** e **`motivo_exclusao TEXT`** (exclusão lógica / *soft delete*, substituindo o antigo `DELETE` físico; preserva histórico e libera o CPF imediatamente ao excluir; `created_at` registra a data de inclusão — no ETL do legado, preencher `created_at` com a `data_inscricao` do titular ou data da migração e `data_exclusao = NULL`);
  * `created_by` e `updated_by`;
  * `estado_civil` (padronizar com `clientes_pf` para cobrir: **Solteiro, Casado, Viúvo, Desquitado, Divorciado**);
  * `sexo` (mesmo enum abrangente de `clientes_pf`);
  * `telefone` (opcional, avaliar flag `telefone_whatsapp`) e `email` (opcional);
  * `valor_adicional` (`NUMERIC(12,2) DEFAULT 0.00`, representando o valor somado ao carnê por aquele dependente, incluindo taxa padrão + eventuais benefícios extras contratados individualmente para ele).
* **Benefícios Modulares por Dependente (`dependente_beneficios_adicionais`):**
  * Permitir vincular benefícios extras (ex.: **Plano Funerário** para dependentes não cobertos automaticamente como filhos maiores, pais, sogro/sogra, netos) individualmente por dependente, compondo o cálculo da mensalidade (`clientes_pf.valor_plano`).
* **Regra de Obrigatoriedade Condicional:**
  * Na migração do legado (`ABAC.FDB`), `cpf`, `estado_civil`, `sexo` e `data_nascimento` precisam aceitar `NULL` para não bloquear registros históricos incompletos.
  * No sistema novo, quando o dependente possuir benefício que exija dados completos (ex.: **Seguro Funeral**), **tornar obrigatórios** `cpf`, `estado_civil`, `sexo` e `data_nascimento` na regra de negócio/UI.
* **Novos Índices (Clientes e Dependentes):**
  * Criar índice de **`cpf`** em `dependentes_pf` (`WHERE cpf IS NOT NULL`) — em `clientes_pf`, a própria constraint `UNIQUE (cpf)` já gera índice automático;
  * Criar índices de **telefone** em `clientes_pf` (`telefone1`, `telefone2`, `telefone3`) e `dependentes_pf` (`telefone`), acelerando busca rápida por telefone (especialmente pensando na futura integração com Agenda Médica).

---

### 1.16 Nova Tabela `documentos_adesao` (Anexos Digitais do Cadastro)
* **Objetivo:** Armazenar metadados e ponteiros (no Storage S3/R2/Supabase, **não** `BYTEA` no banco) dos documentos digitalizados do associado/empresa (Ficha de Adesão, Contrato Assinado, CNH/CPF, Termos de Reativação/Cancelamento).
* **Estrutura Prevista:** `id`, `num_adesao` (`REFERENCES adesoes(numero)`), `tipo_documento` (`FICHA_ADESAO`, `CONTRATO_ASSINADO`, `TERMO_REATIVACAO`, `TERMO_CANCELAMENTO`, `DOC_PESSOAL`, `OUTRO`), `nome_arquivo`, `mime_type`, `tamanho_bytes`, `storage_key`, `sha256_hash`, `observacao`, `created_at`, `created_by`.
* **Regra de Segurança Inegociável (Validação de Cabeçalho e Zero Execução no Servidor):**
  * **Verificação de Assinatura Binária (*Magic Bytes*):** Todo documento importado deve ter seu cabeçalho binário inspecionado pelo backend para confirmar que o conteúdo real condiz com a extensão e o `mime_type` permitidos (lista fechada segura, ex.: PDF, JPG, PNG), rejeitando arquivos disfarçados, extensões duplas, executáveis ou scripts.
  * **Armazenamento Isolado e Sem Execução:** Nenhum documento anexado (`documentos_adesao`, `parceiros_documentos`, logomarcas ou banners) é lido, interpretado ou executado pelo servidor — é tratado como blob binário opaco, gravado com `storage_key` aleatório (UUID) em Storage externo isolado (nunca em diretório executável), com limite de tamanho, registro de `sha256_hash` e entrega segura (`X-Content-Type-Options: nosniff` e `Content-Disposition`).

---

### 1.17 Substituição dos Arquivos `.TXT` de Gráfica por PDFs Diretos (`lotes_arquivos`)
* **Decisão Operacional:** Os antigos arquivos `.TXT` de gráfica (`REMESSA_CARNE_PF_TXT`, `REMESSA_BOLETO_PJ_TXT`, `SEG_VIA_CARNE_TXT`, `SEG_VIA_CARTAO_TXT`) serão substituídos pela geração direta de **3 PDFs** no sistema (Carnês com imposição 3-por-página, Etiquetas de Correios e Dados Variáveis de Carteirinhas).
* **Ação no Schema:**
  * Atualizar `tipo_lote_arquivo_enum` para contemplar os lotes em PDF gerados pelo sistema (armazenados em `lotes_arquivos` no Storage) junto aos lotes CNAB 240 e planilhas Excel;
  * Padronizar **`usuario_id` $\to$ `created_by`** em `lotes_arquivos` (mantendo o mesmo padrão de autoria de todo o sistema), além de `empresa_id` $\to$ `unidade_id` e vínculo com `conta_cobranca_id` nos lotes bancários;
  * Permitir **`valor_total` `NULL`** em `lotes_arquivos` (para lotes não-financeiros como etiquetas de correio e carteirinhas);
  * **Remover `conteudo_arquivo BYTEA`** de `lotes_arquivos`, utilizando exclusivamente **`storage_uri`** (Storage em nuvem) para não sobrecarregar o banco de dados.
* **Pendência Futura:** Definir comportamento da imposição 3-por-página quando a quantidade de carnês do lote não for múltipla de 3.

---

### 1.18 Refatoração da Tabela `clientes_pj` e Nova Tabela `clientes_pj_contatos`
* **Novas Colunas e Ajustes em `clientes_pj`:**
  * Adicionar **`nome_fantasia`** (`VARCHAR(100)`);
  * Adicionar **Representante Legal:** `representante_legal_nome`, `representante_legal_cpf` (validado Módulo 11), `representante_legal_telefone` (e flag WhatsApp opcional);
  * **Telefones:** Mesmo padrão de `clientes_pf` — substituir `telefone_comercial`, `telefone_residencial_fax` / `telefone_fax`, `telefone_celular` por **`telefone1`**, **`telefone2`**, **`telefone3`** + **`telefone1_whatsapp`**, **`telefone2_whatsapp`**, **`telefone3_whatsapp`** (`DEFAULT FALSE`), migrando no ETL na mesma ordem (`CELULAR -> 1`, `COMERCIAL -> 2`, `FAX -> 3`);
  * Adicionar **Taxas Contratuais Negociáveis (Adesão/Reativação e Manutenção Anual PJ):** `isento_taxa_adesao BOOLEAN NOT NULL DEFAULT FALSE`, `valor_taxa_adesao_negociado NUMERIC(12,2)` (opcional; quando `NULL` e não isento, usa o padrão da configuração), `isento_taxa_manutencao_anual BOOLEAN NOT NULL DEFAULT FALSE`, `valor_taxa_manutencao_anual_negociado NUMERIC(12,2)` (opcional; permite usar as taxas padrão da configuração como margem comercial de negociação e conceder isenção ou desconto no fechamento do contrato PJ);
  * Adicionar **`created_by`** e **`updated_by`**;
  * Adicionar datas de ciclo de vida: `data_atualizacao`, `data_cancelamento`, `motivo_cancelamento`, `data_reativacao`;
  * Avaliar validação matemática de `cnpj` no ETL (Módulo 11 + dígitos repetidos $\to$ inválido preserva em `cnpj_legado_bruto` e grava `cnpj = NULL`) e unicidade de `cnpj` quando válido;
  * **Novos Índices:** Criar índice trigrama (`GIN gin_trgm_ops`) para **`nome_fantasia`** e índice para **`cidade`** (`(estado, cidade)` ou `(cidade)`).
* **Nova Tabela Auxiliar `clientes_pj_contatos` (Substitui o campo único `contato`):**
  * Permite cadastrar múltiplos contatos por empresa PJ (`+ Adicionar Contato` na UI): `id`, `cliente_pj_numero` (FK -> `clientes_pj.numero`), `nome`, `telefone` (+ `telefone_whatsapp`), `cargo`, `setor` (ex.: Financeiro, RH), `email`, **`responsavel_financeiro BOOLEAN NOT NULL DEFAULT FALSE`** (pode haver 1 ou N marcados; define os destinatários da fatura/boleto mensal), `observacoes`, `ativo`, `created_at`, `updated_at`, `created_by`, `updated_by`.
  * **ETL:** Se `PESSOAJURIDICA.CONTATO` estiver preenchido no legado, migrar como primeiro registro em `clientes_pj_contatos`.

---

### 1.19 Refatoração de `funcionarios_pj` e Protocolo de Movimentações PJ (`solicitacoes_movimentacao_pj`)
* **Padronização de `funcionarios_pj`:**
  * **Remover `rg`**;
  * **`estado_civil`** e **`sexo`** no mesmo padrão abrangente definido para `clientes_pf` / `dependentes_pf`;
  * Adicionar **`cargo`** e **`setor`** (`VARCHAR(60)`);
  * **Telefones:** Mesmo padrão de `clientes_pf` (`telefone1`, `telefone2`, `telefone3` + flags `*_whatsapp`, migrando `CEL -> 1`, `COMERCIAL -> 2`, `RESIDENCIAL -> 3`);
  * **Planos e Benefícios:** Adicionar **`plano_id`** (`REFERENCES planos(id)`), mantendo `valor_plano` calculado/vigente + vínculo N:M `funcionario_pj_beneficios_adicionais` (permitindo configurar planos padrão por empresa/cargo/setor e sobrescrever individualmente);
  * **Ciclo de Vida e Auditoria:** Adicionar `data_atualizacao`, `data_cancelamento`, `motivo_cancelamento`, `data_reativacao`, `created_by` e `updated_by`;
  * **Novos Índices:** Criar índices para **`cpf`** (`WHERE cpf IS NOT NULL`), **`nome` (`GIN gin_trgm_ops`)** e **`telefone1/2/3`** (espelhando `clientes_pf`, para busca rápida e futura Agenda Médica).
* **Nova Tabela Unificada `solicitacoes_movimentacao` (Protocolo de Solicitações PF, Dependentes e PJ):**
  * Generalizar o protocolo de solicitações para atender **todos os públicos** (Empresas PJ, Titulares PF e até **Dependentes PF** solicitando sua própria exclusão do titular) — já preparado para o futuro **aplicativo do associado**:
  * Campos previstos: `id` (protocolo), `num_adesao` (FK -> `adesoes.numero`), `tipo_solicitacao` (`INCLUSAO_DEPENDENTE`, `EXCLUSAO_DEPENDENTE_TITULAR`, `EXCLUSAO_PROPRIO_DEPENDENTE`, `ALTERACAO_DEPENDENTE`, `CANCELAMENTO_PLANO`, `ALTERACAO_PLANO`, `ADESAO_FUNCIONARIO_PJ`, `EXCLUSAO_FUNCIONARIO_PJ`, `OUTRO`), `solicitante_tipo` (`TITULAR_PF`, `DEPENDENTE_PF`, `CONTATO_PJ`, `OPERADOR_INTERNO`), `solicitante_contato_pj_id` (opcional -> `clientes_pj_contatos.id`), `dependente_pf_id` (opcional), `funcionario_pj_id` (opcional), `canal_origem` (`BALCAO`, `APLICATIVO_ASSOCIADO`, `PORTAL_EMPRESA`, `EMAIL`, `WHATSAPP`, `FORMULARIO_ASSINADO`, `TELEFONE`), `data_solicitacao`, `descricao`, **`documento_comprovante_key`** (anexo no Storage: formulário PDF gerado/assinado, print do WhatsApp ou e-mail), `status` (`PENDENTE`, `APROVADA_EXECUTADA`, `REJEITADA`), `executado_por_usuario_id`, `executado_em`, `created_at`, `created_by`.
  * Vincular esse protocolo às movimentações/auditoria para comprovação e rastreabilidade completa.

---

### 1.20 Replicação da Estrutura de `dependentes_pf` para `dependentes_func_pj`
* **Estado Atual no SQL Moderno:** `dependentes_func_pj` possui apenas `id`, `funcionario_pj_id`, `nome`, `parentesco`, `data_nascimento`, `created_at` e `updated_at`.
* **Ação no Schema:** Replicar integralmente o padrão definido para `dependentes_pf` (item **1.15**):
  * Adicionar **`ativo BOOLEAN NOT NULL DEFAULT TRUE`**, **`data_exclusao DATE`** e **`motivo_exclusao TEXT`** (exclusão lógica / *soft delete*, preservando histórico; `created_at` registra a inclusão);
  * Adicionar **`cpf`**, **`cpf_legado_bruto`**, **`estado_civil`** (Solteiro, Casado, Viúvo, Desquitado, Divorciado), **`sexo`** abrangente, **`telefone`** (opcional, avaliar flag WhatsApp), **`email`** (opcional), **`valor_adicional`**, **`created_by`** e **`updated_by`**;
  * Criar vínculo **`dependente_func_pj_beneficios_adicionais`** (mesma regra de obrigatoriedade condicional quando possuir benefício que exija, ex.: Seguro Funeral);
  * Criar índices de **`nome` (`gin_trgm_ops`)**, **`cpf` (`WHERE cpf IS NOT NULL`)** e **`telefone`** (além de `funcionario_pj_id`).

---

### 1.21 Refatoração da Tabela `carnes`
* **Auditoria:** Adicionar **`created_by BIGINT REFERENCES usuarios(id)`** (além de `created_at`).
* **Quantidade Real de Parcelas (`13`) e `tipo_carne`:**
  * No legado (`CARNE.NUM_PARC`), o sistema gravava `12` para carnês PF (apesar de gerar `13` registros em `PARCELAS`: `ÚNICA` + `01/12`..`12/12`) e usava `NUM_PARC = 12` para detectar renovações.
  * No sistema novo, gravar a quantidade **real** de parcelas geradas em `num_parcelas` (`13` para carnê PF, `1` para adesão/reativação/PJ, `M` para renegociação parcelada) e adicionar **`tipo_carne`** (`CARNE_PF`, `BOLETO_PJ`, `ADESAO`, `REATIVACAO`, `RENEGOCIACAO`, `SEGUNDA_VIA`) para distinguir claramente um carnê anual de um acordo parcelado ou cobrança de 2ª via (e na migração do legado, mapear `NUM_PARC = 12` para `tipo_carne = 'CARNE_PF'`).
  * **Preservação da Numeração Visual (`id_parc`):** Apesar de `num_parcelas` registrar `13` no carnê PF, a numeração visual das parcelas em `parcelas.id_parc` **permanece obrigatoriamente como `'UNICA'` e `'01/12'` a `'12/12'`** (jamais `'01/13'..'13/13'`).

---

### 1.22 Demais Ajustes da Tabela `parcelas` (Em Revisão)
* **Auditoria:** Adicionar **`created_by`** e **`updated_by`** (`REFERENCES usuarios(id)`), completando `created_at` e `updated_at`.
* **Campos de Origem e Status (`tipo_parcela` e `situacao_parcela`):**
  * Adicionar **`tipo_parcela tipo_parcela_enum NOT NULL`** (`MENSALIDADE_PF`, `COTA_UNICA_ANUAL`, `FATURA_MENSAL_PJ`, `TAXA_ADESAO`, `TAXA_REATIVACAO`, `TAXA_MANUTENCAO`, `ACORDO_RENEGOCIACAO`, `TAXA_SEGUNDA_VIA`);
  * Adicionar **`situacao_parcela situacao_parcela_enum NOT NULL DEFAULT 'ABERTA'`** (`ABERTA`, `PAGA`, `QUITADA_POR_UNICA`, `RENEGOCIADA`, `QUITADA_POR_ACORDO`, `PERDOADA`, `CANCELADA`);
  * Adicionar **`valor_taxa_manutencao_embutida NUMERIC(12, 2) NOT NULL DEFAULT 0.00`** para registrar, na parcela `'01/12'` e na `'UNICA'` dos carnês de renovação PF, quanto do `valor_nominal` corresponde à **Taxa de Manutenção Anual** ($A$) e quanto corresponde à mensalidade base ($M$).
* **`id_parc`:** Ampliar de `VARCHAR(10)` para **`VARCHAR(15)`** (mantido como rótulo visual impresso no boleto/carnê, sem acento e em maiúsculas). Para carnês PF de `13` registros (`num_parcelas = 13`), manter obrigatoriamente a numeração **`'UNICA'`** e **`'01/12'` a `'12/12'`**. Para parcelas de renegociação parcelada, adotar o padrão **`'REN 01/04'`**, além de `'ADESAO'`, `'REATIVACAO'`, `'MANUTENCAO'`, `'01/01'` (PJ) e `'DEBIT'` (legado 1x).
* **Obrigatoriedade de `baixado_por_usuario_id`:** Avaliar na migração entre:
  1. Atribuir o ID do administrador (ou usuário técnico de migração) a todas as baixas legadas e criar trava no banco garantindo obrigatoriedade **quando paga** (`CHECK (data_pagamento IS NULL OR baixado_por_usuario_id IS NOT NULL)`) — lembrando que parcelas em aberto precisam aceitar `NULL`; **ou**
  2. Manter livre para o histórico legado e exigir obrigatoriedade apenas no backend para todas as novas baixas no sistema novo.
* **Abatimento de Parcelas e Instrução CNAB (`valor_abatimento`):**
  * Adicionar **`valor_abatimento NUMERIC(12, 2) NOT NULL DEFAULT 0.00`** (mantendo o `valor_nominal` original do carnê impresso; o valor líquido a cobrar passa a ser `valor_nominal - valor_abatimento`) e **`abatimento_pendente_cnab BOOLEAN NOT NULL DEFAULT FALSE`** (para enfileirar parcelas já registradas no banco que precisam de instrução CNAB `'04'` Concessão de Abatimento ou `'05'` Cancelamento de Abatimento na próxima remessa ao Sicoob).
* **Código de Barras, Linha Digitável e Boleto Híbrido Pix (`parcelas`):**
  * Armazenar **`codigo_barras VARCHAR(44)`** e **`linha_digitavel VARCHAR(47)`** na tabela `parcelas` (calculados pelo sistema conforme regra oficial Sicoob no modo CNAB 240, ou gravados diretamente do retorno da API v3 no futuro), garantindo reprodutibilidade exata em reimpressões/2ª via;
  * Prever colunas opcionais futuras **`pix_copia_cola TEXT`** e **`txid_pix VARCHAR(60)`** em `parcelas` para armazenar o QR Code Pix retornado pela API v3 do Sicoob e imprimi-lo diretamente nas lâminas dos carnês/boletos em PDF.
* **Blindagem do Status de Registro Bancário CNAB (`status_registro_cnab_enum` — Correção do Bug Legado `S`/`B` $\to$ `N`):**
  * **Causa Raiz Comprovada no Legado (`SGCeFeGe.exe` @ `0x58eeac`):** O único local que gravava `'N'` era o processamento de retorno Sicoob código `'03'` (*Rejeição*), que sobrescrevia `REGISTRADO = 'N'` cegamente sem ler `Motivo da Ocorrência` (`pos 214..223`) nem proteger estados anteriores (rebaixando títulos `'S'` ou `'B'` para `'N'`, inclusive boletos já pagos no banco ou retornados com `'A5'` *"título baixado, liquidado ou quitado"*), além de o código `'06'` (*Liquidação*) deixar títulos pagos no banco presos como `'S'`.
  * **Ação no Schema (`status_registro_cnab_enum`):** Ampliar o enum (hoje `('N', 'S', 'B')`) para **5 estados explícitos**:
    1. **`NAO_REGISTRADO`** (nunca enviado ao banco);
    2. **`REGISTRADO`** (entrada confirmada `'02'` e ativo no banco);
    3. **`BAIXADO`** (retirado do banco por `'09'` ou retorno `'A5'` em parcela paga em carteira/cancelada);
    4. **`LIQUIDADO_BANCO`** (pago diretamente na rede bancária via `'06'`, ou `'A5'` em parcela já paga no banco);
    5. **`REJEITADO`** (recusado na 1ª tentativa de registro `'01'` — acompanha as novas colunas opcionais **`codigo_rejeicao_cnab VARCHAR(20)`** e **`motivo_rejeicao_cnab TEXT`** para exibição e correção).
  * **Regra de Transição ("Caminho Sem Volta" no Backend):** Títulos em `REGISTRADO`, `BAIXADO` ou `LIQUIDADO_BANCO` **jamais** podem voltar para `NAO_REGISTRADO` em retornos `'03'`, `'26'` ou `'30'` (interpretar obrigatoriamente `pos 214..223` conforme regra completa em `04_regras_negocio_financeiro_cnab_arquivos.md` Seção 3.4.A). Travar Remessa `'01'` apenas para `ABERTA` + (`NAO_REGISTRADO` | `REJEITADO`) e Remessa `'02'` apenas para `REGISTRADO`.
  * **Saneamento Automático na Migração (`ABAC.FDB` $\to$ PostgreSQL):** Corrigir na carga os registros históricos rebaixados pelo bug legado:
    * `REGISTRADO = 'B'` $\to$ `'BAIXADO'`;
    * `REGISTRADO = 'S'` com `DTPAG IS NOT NULL AND COALESCE(VALOR_COMP, 0) > 0` $\to$ `'LIQUIDADO_BANCO'`; demais `'S'` $\to$ `'REGISTRADO'`;
    * `REGISTRADO = 'N'` com `DTPAG IS NOT NULL AND COALESCE(VALOR_COMP, 0) > 0` *(~3.597 títulos históricos pagos no banco rebaixados por `'03'`)* $\to$ `'LIQUIDADO_BANCO'`;
    * `REGISTRADO = 'N'` com `DTPAG IS NOT NULL AND COALESCE(VALOR_COMP, 0) = 0` *(ex.: títulos `'A5'` já baixados no banco)* $\to$ `'BAIXADO'`;
    * `REGISTRADO = 'N'` com `DTPAG IS NULL` *(rejeitados em aberto)* $\to$ `'REJEITADO'`;
    * `REGISTRADO IS NULL` $\to$ `'NAO_REGISTRADO'`.

---

### 1.23 Refatoração da Tabela `fila_segunda_via` (Suporte a PJ e Cobrança Futura)
* **Padronização:** `empresa_id` $\to$ **`unidade_id`** e `usuario_id` $\to$ **`created_by`**.
* **Suporte a PJ:** Adicionar **`funcionario_pj_id`** (`REFERENCES funcionarios_pj(id)`) e **`dependente_func_pj_id`** (`REFERENCES dependentes_func_pj(id)`), ampliando `tipo_item` para incluir cartões de funcionários PJ e seus dependentes (`CARTAO_FUNC_PJ`, `CARTAO_DEP_PJ`).
* **Preparação para Cobrança Futura (ex.: Cartão PVC / com Chip):**
  * Adicionar **`cobranca_obrigatoria BOOLEAN NOT NULL DEFAULT FALSE`** (hoje gratuita) e **`parcela_id BIGINT REFERENCES parcelas(id)`** (opcional).
  * A fila lê automaticamente os parâmetros de `configuracoes_sistema` (`cobrar_segunda_via_carne`/`valor_segunda_via_carne` e `cobrar_segunda_via_cartao`/`valor_segunda_via_cartao`) para definir se o item exige pagamento.
  * Quando cobrada no futuro, o pagamento (balcão em dinheiro, Pix, boleto CNAB 240, conferência de extrato) reaproveita integralmente a estrutura de `carnes` (`tipo_carne = 'SEGUNDA_VIA'`) + `parcelas` (`tipo_parcela = 'TAXA_SEGUNDA_VIA'`) — sem duplicar tabelas financeiras — liberando a impressão somente após quitação da parcela vinculada.
* **Novos Índices:**
  * Índice parcial para itens pendentes: `(unidade_id, tipo_item, created_at) WHERE processado = FALSE`;
  * Histórico por contrato: `(num_adesao, created_at DESC)`;
  * Busca por lote gerado: `(lote_arquivo_id) WHERE lote_arquivo_id IS NOT NULL`.

---

### 1.24 Padronização da Tabela `auditoria_eventos`
* **Auditoria:** Padronizar **`usuario_id` $\to$ `created_by`** (e atualizar o índice `idx_auditoria_usuario` para usar `created_by`).
* **Filtros Obrigatórios e Índices de Consulta (`/auditoria`):**
  * Suportar pesquisa combinada por **data**, **intervalo de data** (`created_at`), **login (usuário)** (`created_by` vinculado a `usuarios.apelido`), **tipo de evento** (`acao`) e **entidade** (`entidade` / `entidade_id`).
  * Além de `idx_auditoria_entidade (entidade, entidade_id, created_at DESC)` e `idx_auditoria_usuario (created_by, created_at DESC)`, adicionar:
    * **`idx_auditoria_created_at`** em `(created_at DESC)` para buscas globais por data ou intervalo de datas;
    * **`idx_auditoria_acao`** em `(acao, created_at DESC)` para buscas por tipo de evento no período.
  * **Dicionário Oficial de Tipos de Evento (`acao`):**

| Categoria | Código (`acao`) | O que Registra e Quando é Disparado |
|---|---|---|
| **Segurança e Acesso** | `LOGIN` | Entrada bem-sucedida de qualquer perfil (`ADMINISTRADOR`, `COLABORADOR`, Associado, Dependente, Empresa PJ, Parceiro) |
| **Segurança e Acesso** | `LOGOUT` | Saída voluntária ou encerramento de sessão por expiração |
| **Segurança e Acesso** | `LOGIN_FALHA` | Tentativa de login com usuário/CPF/CNPJ ou senha inválidos (registra `ip_origem` e `user_agent`) |
| **Segurança e Acesso** | `BLOQUEIO_USUARIO` | Bloqueio automático da conta por tentativas massivas de senha errada ou bloqueio manual pelo Administrador |
| **Segurança e Acesso** | `BLOQUEIO_IP` | Bloqueio de endereço IP por tentativas massivas, força bruta ou comportamento suspeito |
| **Segurança e Acesso** | `DESBLOQUEIO_SEGURANCA` | Desbloqueio manual (pelo Administrador) ou automático (após tempo de espera) de usuário ou IP |
| **Segurança e Acesso** | `SENHA_ALTERADA` | Troca de senha realizada pelo próprio usuário *(sem gravar a senha em texto)* |
| **Segurança e Acesso** | `SENHA_REDEFINIDA` | Reset/redefinição de senha feito pelo Administrador ou via fluxo de recuperação de senha |
| **Segurança e Acesso** | `PERMISSAO_ALTERADA` | Alteração de perfil (`role`), unidade(s) autorizada(s) ou permissões RBAC de um usuário |
| **Segurança e Acesso** | `ACESSO_NEGADO` | Tentativa bloqueada de acessar rota, operação ou registro de outra unidade/titularidade sem permissão |
| **Cadastro e LGPD** | `CREATE` | Criação de novo registro (cliente, dependente, empresa PJ, plano, parceiro, usuário, etc.) |
| **Cadastro e LGPD** | `UPDATE` | Edição de registro existente, gravando obrigatoriamente `dados_anteriores` e `dados_novos` |
| **Cadastro e LGPD** | `DELETE` | Exclusão lógica (*soft delete*) ou desativação de registro (ex.: dependente, contato, documento) |
| **Cadastro e LGPD** | `UPLOAD_DOCUMENTO` | Envio de anexo digital (`documentos_adesao`, `parceiros_documentos`) com `sha256_hash` |
| **Cadastro e LGPD** | `DOWNLOAD_DOCUMENTO` | Visualização ou download de documento sensível anexado (rastreabilidade LGPD) |
| **Cadastro e LGPD** | `EXPORTACAO_RELATORIO` | Exportação de relatório em PDF, XLSX ou CSV contendo dados de clientes ou financeiros (LGPD) |
| **Cadastro e LGPD** | `TERMO_LGPD_ACEITO` | Aceite formal de termo de privacidade/LGPD por Parceiro ou Associado (com data/hora e IP) |
| **Financeiro** | `BAIXA` | Liquidação de parcela/título (manual no balcão, retorno CNAB 240 ou planilha) |
| **Financeiro** | `ESTORNO` | Cancelamento de baixa/pagamento anteriormente registrado (incluindo reversão de cascata `'UNICA'`) |
| **Financeiro** | `REMESSA` | Geração de lote de cobrança bancária (CNAB 240) ou lote de impressão em PDF (carnês, etiquetas, carteirinhas) |
| **Financeiro** | `RETORNO_PROCESSADO` | Importação e processamento de arquivo de retorno bancário (`.ret`) ou planilha de baixas |
| **Financeiro** | `RENEGOCIACAO` | Formalização de acordo parcelado ou consolidação de parcelas vencidas |
| **Financeiro** | `AUTORIZACAO_EXCECAO` | Liberação por alçada de Gerente/Administrador (senha presencial ou código único) para desconto ou perdão de dívida |
| **Contratos e Portais** | `CANCELAMENTO` | Cancelamento formal de contrato PF ou PJ (com motivo e quem executou) |
| **Contratos e Portais** | `REATIVACAO` | Reativação de ex-cliente PF ou ex-empresa PJ |
| **Contratos e Portais** | `MUDANCA_PLANO` | Troca de plano ou alteração de benefícios adicionais vinculados ao contrato/dependente |
| **Contratos e Portais** | `SOLICITACAO_ABERTA` | Abertura de protocolo pelo titular PF, dependente PF/PJ, empresa PJ ou operador (`solicitacoes_movimentacao`) |
| **Contratos e Portais** | `SOLICITACAO_APROVADA` | Aprovação/execução de uma solicitação de movimentação pela equipe interna |
| **Contratos e Portais** | `SOLICITACAO_REJEITADA` | Recusa fundamentada de uma solicitação de movimentação |

---

### 1.25 Módulo de Rede Credenciada / Parceiros e Clínicas Próprias (Módulo 1 — Primeira Entrega em Produção)

* **Objetivo Arquitetural:** Criar uma estrutura completa, normalizada e sem ambiguidades para gerenciar **parceiros credenciados** (de comércios locais a redes nacionais, médicos e hospitais) e as **Clínicas Próprias das Unidades da Associação**, servindo como **Módulo 1** a entrar em produção de forma independente sobre o banco oficial PostgreSQL.
* **Convenções Gerais deste Módulo:**
  * **Chaves Primárias:** `BIGSERIAL PRIMARY KEY` nas tabelas principais; **chave primária composta** nas tabelas puras de ligação (`5`, `8`, `10`, `13`), impedindo vínculos duplicados na raiz.
  * **Auditoria Padrão:** Tabelas editáveis possuem `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `created_by BIGINT REFERENCES usuarios(id)`, `updated_by BIGINT REFERENCES usuarios(id)`. Tabelas puras de ligação, anexos e histórico imutável possuem `created_at` e `created_by` (ou `alterado_em`/`alterado_por_usuario_id` no histórico).
  * **Normalização de Texto:** `MAIÚSCULAS, SEM ACENTOS E SEM CARACTERES ESPECIAIS` (`A-Z`, `0-9` e espaços) em campos de texto de negócio, preservando formato original apenas em exceções técnicas (e-mails, URLs, chaves de Storage e redes sociais como `@instagram`).
  * **Comentários no `.sql`:** Ao refatorar o `02_schema_postgresql_moderno.sql`, transcrever as descrições dos campos não óbvios como comentários inline (`-- ...`) e `COMMENT ON COLUMN` / `COMMENT ON TABLE` (Protocolo 3, item 5).

---

#### 1.25.1 Mapa Geral das 18 Tabelas

| Nº | Bloco | Tabela | Papel Resumido | Visibilidade |
| :---: | :--- | :--- | :--- | :--- |
| **1** | Pré-Cadastro | `categorias` | Grandes grupos cadastráveis pelo `ADMINISTRADOR` (ex.: *Saúde*, *Comércio e Serviços*, *Educação*...) com ordem de exibição | Público |
| **2** | Pré-Cadastro | `subcategorias` | Especialidades médicas/odontológicas e ramos comerciais | Público |
| **3** | Pré-Cadastro | `catalogo_procedimentos` | Lista padrão de consultas, exames e serviços (pronta p/ agenda futura) | Misto |
| **4** | Pré-Cadastro | `profissionais` | Cadastro único da pessoa física (CRM/CRO/OAB, CPF e contatos pessoais sigilosos) | Misto *(dados pessoais sigilosos)* |
| **5** | Pré-Cadastro | `profissionais_subcategorias` | Liga o profissional às suas várias especialidades | Público |
| **6** | Pré-Cadastro | `convenios` | Cadastro extensível de convênios/faixas de atendimento (*Particular*, *Associado*, *Parceiro*, *Prefeitura* e futuros) | Misto |
| **7** | Parceiros | `parceiros` | Ficha principal do convênio (Empresa PJ, Autônomo PF ou Clínica Própria), travas CRM e revisão semestral | Misto |
| **8** | Parceiros | `parceiros_subcategorias` | Especialidades **gerais da rede** (valem para **todos** os endereços do parceiro) | Público |
| **9** | Parceiros | `parceiros_locais` | Endereços/filiais de atendimento, telefones públicos, redes sociais (LGPD), horários e mapa | Público |
| **10** | Parceiros | `parceiros_locais_subcategorias` | Especialidades **exclusivas de uma filial** (para filiais que atendem serviços diferentes) | Público |
| **11** | Parceiros | `parceiros_profissionais` | Lista de escala opcional (com `ativo`): liga profissional ao parceiro e, opcionalmente, a uma filial | Público |
| **12** | Parceiros | `parceiros_contatos` | Contatos internos/particulares (secretária, gerente, financeiro) com abrangência geral ou por filiais | **Interno / Sigiloso** |
| **13** | Parceiros | `parceiros_contatos_locais` | Liga um contato interno específico (`abrange_todos_locais = FALSE`) a 1 ou N filiais | **Interno / Sigiloso** |
| **14** | Parceiros | `parceiros_documentos` | Anexos no Storage em nuvem (contrato, termo LGPD, tabela em PDF, logomarca, banner) | Misto |
| **15** | Pré-Cadastro | `tipos_documento_parceiro` | Cadastro extensível de tipos de documentos de parceiros (substitui o antigo ENUM fixo) | Misto |
| **16** | Preços/Guia | `parceiros_precos_beneficios` | Caderno de preços/descontos por `convenio_id`, com `local_id` (todas ou 1 unidade), `profissional_id` e `procedimento_id` opcionais | Controlado pela Trava CRM |
| **17** | Preços/Guia | `parceiros_precos_historico` | Histórico imutável de reajustes de preço/desconto por tabela de preço | **Interno** |
| **18** | Preços/Guia | `parceiros_planos_elegiveis` | *(Futura)* Restringe parceiro ou benefício a planos/adicionais específicos (vazio = todos elegíveis) | Interno / Regra de Guia |
| **19** | Preços/Guia | `parceiros_destaques` | Destaques editoriais ou patrocinados no guia (parceiro e `local_id` opcional, por cidade/categoria/geral) | Público |

---

#### 1.25.2 Listas de Opções Fixas (`ENUM`s do Módulo)

* `tipo_parceiro_enum`: `'ESTABELECIMENTO_PJ'`, `'PROFISSIONAL_PF'`, `'UNIDADE_PROPRIA'`
* `tipo_precificacao_enum`: `'VALOR_FIXO'`, `'PERCENTUAL_DESCONTO'`, `'SOB_CONSULTA'`
* `tipo_destaque_parceiro_enum`: `'EDITORIAL_INTERNO'`, `'PATROCINADO'`
* `escopo_destaque_parceiro_enum`: `'GERAL'`, `'CIDADE'`, `'CATEGORIA'`, `'CIDADE_CATEGORIA'`

---

#### 1.25.3 Especificação Detalhada das 18 Tabelas

##### 1. `categorias`
* **Para que serve:** Agrupa as grandes áreas da rede credenciada (ex.: *Saúde*, *Odontologia*, *Comércio e Serviços*, *Educação*, *Lazer*). **Cadastro livre e gerenciado exclusivamente pelo `ADMINISTRADOR`** (sem `ENUM` fixo).
* **Visibilidade:** Público no Guia.
* **Relacionamento:** 1 Categoria possui várias Subcategorias (`subcategorias.categoria_id`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único da categoria |
| `nome` | `VARCHAR(100)` | `NOT NULL UNIQUE` | Nome da categoria principal (maiúsculas, sem acentos e sem caracteres especiais) |
| `ordem` | `INTEGER` | `NOT NULL DEFAULT 100` | Posição numérica de exibição nas telas, listas e guia público (recomenda-se `10, 20, 30...` para encaixes futuros) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se a categoria aparece para novos cadastros e no guia |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade de criação e última alteração |

* **Travas e Índices:** `UNIQUE (nome)`; índice em `(ativo, ordem, nome)` para ordenação instantânea nas telas e no guia.

---

##### 2. `subcategorias`
* **Para que serve:** Lista padronizada de especialidades médicas/odontológicas e ramos comerciais (evita digitar *Cardiologia*, *Cardio* e *Cardiologista* separados).
* **Visibilidade:** Público no Guia.
* **Relacionamento:** Pertence a 1 Categoria (`categoria_id -> categorias(id)`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único da subcategoria/especialidade |
| `categoria_id` | `BIGINT` | `NOT NULL REFERENCES categorias(id)` | Categoria principal à qual pertence |
| `nome` | `VARCHAR(120)` | `NOT NULL` | Nome da especialidade ou ramo comercial |
| `observacoes` | `TEXT` | Opcional | Notas de uso interno ou descrição complementar |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se está ativa |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** `UNIQUE (categoria_id, nome)`; índice em `(categoria_id)` e índice parcial `WHERE ativo = TRUE`.

---

##### 3. `catalogo_procedimentos`
* **Para que serve:** Pré-cadastro padronizado de consultas, exames e serviços (aproveitando campos já planejados em `ABBAC Cadastro 2026.xlsm` para futura Agenda Médica). Procedimentos genéricos que atendem múltiplas áreas (ex.: `CONSULTA`, `TRATAMENTO DE UNHA ENCRAVADA`) ficam cadastrados **uma única vez** com `subcategoria_id = NULL` e são combinados com a especialidade no momento de precificar — evitando duplicação artificial de nomes (como criar `CONSULTA CARDIOLOGIA`, `CONSULTA OFTALMOLOGIA`, `CONSULTA JURIDICA` etc.).
* **Visibilidade:** Misto (nome e preparo podem ir ao guia; duração auxilia a futura agenda).
* **Relacionamento:** Opcionalmente vinculado a 1 Subcategoria (`subcategoria_id -> subcategorias(id)`), apenas como etiqueta de organização do catálogo (**jamais** como trava rígida que proíba combinar um procedimento com outras especialidades em `parceiros_precos_beneficios`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do procedimento |
| `subcategoria_id` | `BIGINT` | Opcional `REFERENCES subcategorias(id)` | Especialidade associada (opcional para itens genéricos) |
| `nome` | `VARCHAR(160)` | `NOT NULL` | Nome padronizado do procedimento/exame/serviço |
| `duracao_padrao_min` | `INTEGER` | Opcional (`CHECK > 0`) | Duração média em minutos (preparado para futura Agenda Médica) |
| `preparo_necessario` | `TEXT` | Opcional | Instruções de preparo ao paciente (ex.: jejum de 8h) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o procedimento está ativo |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** `UNIQUE NULLS NOT DISTINCT (subcategoria_id, nome)`; índice trigrama (`GIN gin_trgm_ops`) em `nome` para busca rápida por texto.

---

##### 4. `profissionais`
* **Para que serve:** Cadastro único de pessoas físicas que atendem (médicos, dentistas, psicólogos, fisioterapeutas, advogados), evitando duplicar o profissional quando ele atende em várias clínicas.
* **Visibilidade:** Misto — **Nome e Conselho (CRM/CRO/etc.) são públicos**; **CPF, endereço pessoal e telefones pessoais são estritamente internos (LGPD)**.
* **Relacionamento:** Pode ter várias especialidades (`profissionais_subcategorias`) e atender em vários parceiros/locais (`parceiros_profissionais`), além de poder ser titular de um cadastro de Parceiro PF (`parceiros.profissional_titular_id`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do profissional |
| `nome` | `VARCHAR(150)` | `NOT NULL` | Nome completo do profissional |
| `cpf` | `VARCHAR(11)` | Opcional `UNIQUE` | CPF validado (11 dígitos) — uso interno/LGPD |
| `conselho_tipo` | `VARCHAR(20)` | Opcional | Sigla do conselho de classe (`CRM`, `CRO`, `CRP`, `CREFITO`, `CRN`, `OAB`, etc.) |
| `conselho_numero` | `VARCHAR(30)` | Opcional | Número do registro no conselho profissional |
| `conselho_uf` | `CHAR(2)` | Opcional | UF do conselho profissional (ex.: `PR`, `SP`) |
| `endereco_pessoal` | `VARCHAR(200)` | Opcional | Endereço particular do profissional (**interno/sigiloso — nunca exibir no guia**) |
| `cep_pessoal` | `VARCHAR(8)` | Opcional | CEP particular (**interno/sigiloso**) |
| `telefone_pessoal1` | `VARCHAR(20)` | Opcional | Telefone/celular pessoal principal (**interno/sigiloso**) |
| `telefone_pessoal2` | `VARCHAR(20)` | Opcional | Telefone/celular pessoal secundário (**interno/sigiloso**) |
| `email` | `VARCHAR(150)` | Opcional | E-mail de contato interno do profissional (formato original preservado) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o profissional está ativo na base |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** `UNIQUE (cpf)` (permite múltiplos `NULL`); `UNIQUE (conselho_tipo, conselho_numero, conselho_uf)` quando preenchidos; índice parcial `WHERE ativo = TRUE`; índice trigrama (`GIN gin_trgm_ops`) em `nome`.

---

##### 5. `profissionais_subcategorias`
* **Para que serve:** Liga um profissional às suas múltiplas especialidades (ex.: um médico que é *Clínico Geral* e *Cardiologista*).
* **Visibilidade:** Público no Guia.
* **Relacionamento:** Muitos-para-muitos entre `profissionais` e `subcategorias`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `profissional_id` | `BIGINT` | `NOT NULL REFERENCES profissionais(id) ON DELETE CASCADE` | Profissional vinculado |
| `subcategoria_id` | `BIGINT` | `NOT NULL REFERENCES subcategorias(id)` | Especialidade do profissional |
| *Auditoria* | `created_at`, `created_by` | Padrão ligação | Data e usuário que criou o vínculo |

* **Travas e Índices:** `PRIMARY KEY (profissional_id, subcategoria_id)`; **índice invertido** `idx_prof_subcat_subcat_prof ON profissionais_subcategorias (subcategoria_id, profissional_id)` (acelera a busca de todos os profissionais de uma especialidade).

---

##### 6. `convenios`
* **Para que serve:** Cadastro extensível dos convênios/faixas de atendimento praticados por parceiros e Clínicas Próprias (permite criar **N** convênios/faixas no futuro sem alterar a estrutura do banco).
* **Visibilidade:** Misto (controlado por `exibir_guia_publico` + Trava CRM do parceiro).
* **Relacionamento:** 1 Convênio é referenciado por vários itens em `parceiros_precos_beneficios` e `parceiros_precos_historico`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do convênio |
| `codigo` | `VARCHAR(40)` | `NOT NULL UNIQUE` | Código interno fixo (ex.: `PARTICULAR`, `ASSOCIADO`, `PARCEIRO`, `PREFEITURA`) |
| `nome` | `VARCHAR(100)` | `NOT NULL UNIQUE` | Nome de exibição na tela e relatórios (ex.: `PRECO ASSOCIADO`, `ENCAMINHAMENTO PREFEITURA`) |
| `descricao` | `TEXT` | Opcional | Explicação de quando esse convênio/faixa se aplica |
| `uso_exclusivo_unidade_propria` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Quando `TRUE`, aparece por padrão apenas nas Clínicas Próprias (`UNIDADE_PROPRIA`) |
| `exibir_guia_publico` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Indica se esta faixa pode aparecer no guia público (sempre respeitando a Trava Dupla CRM do parceiro) |
| `ordem` | `INTEGER` | `NOT NULL DEFAULT 100` | Ordem de exibição das colunas/linhas na grade de preços (`10, 20, 30...`) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o convênio está ativo |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Seed Inicial Obrigatório:** `PARTICULAR` (ordem 10, geral), `ASSOCIADO` (ordem 20, geral), `PARCEIRO` (ordem 30, exclusivo unidade própria), `PREFEITURA` (ordem 40, exclusivo unidade própria).
* **Travas e Índices:** `UNIQUE (codigo)`, `UNIQUE (nome)`; índice em `(ativo, ordem)`.

---

##### 7. `parceiros`
* **Para que serve:** Ficha principal do convênio/estabelecimento (Empresa PJ, Profissional Autônomo PF ou Clínica Própria da Associação). Centraliza regras de autorização, travas CRM de privacidade de preços e datas de revisão semestral.
* **Visibilidade:** Misto (`nome_fantasia`, `exige_autorizacao` e `observacoes_atendimento` são públicos; `observacoes_internas` e controles contratuais são internos).
* **Relacionamento:** 1 Parceiro possui vários Locais (`parceiros_locais`), Especialidades Gerais (`parceiros_subcategorias`), Profissionais (`parceiros_profissionais`), Contatos (`parceiros_contatos`), Documentos (`parceiros_documentos`), Preços (`parceiros_precos_beneficios`) e Destaques (`parceiros_destaques`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do parceiro |
| `tipo_parceiro` | `tipo_parceiro_enum` | `NOT NULL` | `ESTABELECIMENTO_PJ`, `PROFISSIONAL_PF` ou `UNIDADE_PROPRIA` |
| `unidade_propria_id` | `BIGINT` | Opcional `REFERENCES unidades(id)` | Obrigatório quando `tipo_parceiro = 'UNIDADE_PROPRIA'` (liga à Matriz/Filial da Associação) |
| `profissional_titular_id` | `BIGINT` | Opcional `REFERENCES profissionais(id)` | Obrigatório quando `tipo_parceiro = 'PROFISSIONAL_PF'` (liga ao cadastro pessoal do autônomo) |
| `cpf_cnpj` | `VARCHAR(14)` | Opcional | CPF (11) ou CNPJ (14) validado (somente dígitos) |
| `razao_social` | `VARCHAR(160)` | Opcional | Razão social da empresa ou nome civil |
| `nome_fantasia` | `VARCHAR(160)` | `NOT NULL` | Nome de divulgação no guia e no livreto (ex.: `CLINICA VIDA` ou `CONSULTORIO DR. JOAO SILVA`) |
| `exige_autorizacao` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Indica se o associado precisa retirar guia/autorização prévia antes do atendimento |
| `observacoes_atendimento` | `TEXT` | Opcional | Orientações públicas ao associado (ex.: *"Apresentar carteirinha e documento com foto"*) |
| `observacoes_internas` | `TEXT` | Opcional | Anotações sigilosas da equipe da associação (**nunca exibir no guia**) |
| `bloqueio_divulgacao_valores` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | **Trava CRM (Nível 1):** impede divulgação de preços/descontos no guia público (**somente `ADMINISTRADOR` pode alterar**) |
| `exibir_valores_guia_publico` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | **Trava CRM (Nível 2):** liga/desliga exibição de preços no guia (só pode ser `TRUE` se `bloqueio_divulgacao_valores = FALSE`) |
| `lgpd_aceito_em` | `TIMESTAMPTZ` | Opcional | Data/hora em que o parceiro assinou o termo LGPD |
| `cadastro_atualizado_em` | `TIMESTAMPTZ` | Opcional | Última conferência dos dados cadastrais (gera alerta de revisão a cada 6 meses) |
| `precos_atualizados_em` | `TIMESTAMPTZ` | Opcional | Última conferência da tabela de preços/descontos (gera alerta a cada 6 meses) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o convênio está ativo |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:**
  * `CHECK (NOT exibir_valores_guia_publico OR NOT bloqueio_divulgacao_valores)` (Trava Dupla CRM);
  * `CHECK ((tipo_parceiro <> 'UNIDADE_PROPRIA') OR unidade_propria_id IS NOT NULL)`;
  * `CHECK ((tipo_parceiro <> 'PROFISSIONAL_PF') OR profissional_titular_id IS NOT NULL)`;
  * Índices: parcial `WHERE ativo = TRUE`, trigrama (`GIN gin_trgm_ops`) em `nome_fantasia`, e índices dedicados em `cadastro_atualizado_em` e `precos_atualizados_em` (alertas semestrais).

---

##### 8. `parceiros_subcategorias`
* **Para que serve:** Especialidades/ramos **gerais da rede** — valem automaticamente para **todos** os endereços (`parceiros_locais`) daquele parceiro (ideal para redes com várias filiais que oferecem os mesmos serviços).
* **Visibilidade:** Público no Guia.
* **Relacionamento:** Muitos-para-muitos entre `parceiros` e `subcategorias`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro dono das especialidades gerais |
| `subcategoria_id` | `BIGINT` | `NOT NULL REFERENCES subcategorias(id)` | Especialidade válida para todos os endereços do parceiro |
| *Auditoria* | `created_at`, `created_by` | Padrão ligação | Data e usuário que criou o vínculo |

* **Travas e Índices:** `PRIMARY KEY (parceiro_id, subcategoria_id)`; **índice invertido** `idx_parceiros_subcat_subcat_parceiro ON parceiros_subcategorias (subcategoria_id, parceiro_id)`.

---

##### 9. `parceiros_locais`
* **Para que serve:** Endereços físicos / filiais públicas onde o parceiro atende, com telefones da recepção, horários, redes sociais autorizadas pela LGPD e coordenadas de mapa.
* **Visibilidade:** Público no Guia *(redes sociais só são exibidas se a respectiva flag `permite_divulgar_*` for `TRUE`)*.
* **Relacionamento:** **1 Parceiro possui vários Locais** — cada local aponta para o seu parceiro via `parceiro_id`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do local/filial |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro ao qual este endereço pertence |
| `nome_local` | `VARCHAR(120)` | Opcional | Nome identificador da unidade/filial (ex.: `FILIAL CENTRO`, `MATRIZ`, `UNIDADE BATEL`) |
| `endereco` | `VARCHAR(150)` | `NOT NULL` | Logradouro (rua, avenida) |
| `end_numero` | `VARCHAR(20)` | Opcional | Número do imóvel |
| `complemento` | `VARCHAR(100)` | Opcional | Sala, andar, bloco, referência |
| `bairro` | `VARCHAR(100)` | Opcional | Bairro |
| `cidade` | `VARCHAR(100)` | `NOT NULL` | Cidade de atendimento |
| `estado` | `CHAR(2)` | `NOT NULL` | UF (2 letras) |
| `cep` | `VARCHAR(8)` | Opcional | CEP (8 dígitos) |
| `telefone_publico1` | `VARCHAR(20)` | Opcional | Telefone público principal da recepção |
| `telefone_publico1_whatsapp` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Indica se o telefone 1 atende WhatsApp |
| `telefone_publico2` | `VARCHAR(20)` | Opcional | Telefone público secundário |
| `telefone_publico2_whatsapp` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Indica se o telefone 2 atende WhatsApp |
| `email_publico` | `VARCHAR(150)` | Opcional | E-mail público para agendamento/contato (formato original) |
| `instagram` | `VARCHAR(120)` | Opcional | Perfil do Instagram (formato original) |
| `permite_divulgar_instagram` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Consentimento LGPD (`LGPD.pdf`) para exibir Instagram no guia |
| `facebook` | `VARCHAR(150)` | Opcional | Página do Facebook (formato original) |
| `permite_divulgar_facebook` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Consentimento LGPD para exibir Facebook no guia |
| `whatsapp_divulgacao` | `VARCHAR(20)` | Opcional | Número de WhatsApp específico para divulgação no guia |
| `permite_divulgar_whatsapp` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Consentimento LGPD para exibir WhatsApp de divulgação no guia |
| `horario_funcionamento_texto` | `VARCHAR(250)` | Opcional | Horário legível ao público (ex.: `SEG A SEX 08H AS 18H`) |
| `horario_funcionamento_json` | `JSONB` | Opcional | Horário estruturado para futuro filtro *"Aberto agora"* |
| `latitude` | `NUMERIC(10, 7)` | Opcional | Latitude para futura busca por proximidade no mapa |
| `longitude` | `NUMERIC(10, 7)` | Opcional | Longitude para futura busca por proximidade no mapa |
| `google_maps_url` | `TEXT` | Opcional | Link direto do Google Maps (formato original) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se a filial está ativa |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** Índice em `(parceiro_id)`, índice em `(estado, cidade, bairro)`, índice parcial `WHERE ativo = TRUE`, e índice parcial `(latitude, longitude) WHERE latitude IS NOT NULL AND longitude IS NOT NULL`.

---

##### 10. `parceiros_locais_subcategorias`
* **Para que serve:** Especialidades/ramos **exclusivos de uma filial específica**, permitindo que filiais da mesma empresa atendam especialidades completamente diferentes (ex.: Filial A só *Cardiologia*; Filial B só *Odontologia*).
* **Visibilidade:** Público no Guia.
* **Relacionamento:** Muitos-para-muitos entre `parceiros_locais` e `subcategorias`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `local_id` | `BIGINT` | `NOT NULL REFERENCES parceiros_locais(id) ON DELETE CASCADE` | Filial/endereço específico |
| `subcategoria_id` | `BIGINT` | `NOT NULL REFERENCES subcategorias(id)` | Especialidade oferecida exclusivamente nesta filial |
| *Auditoria* | `created_at`, `created_by` | Padrão ligação | Data e usuário que criou o vínculo |

* **Travas e Índices:** `PRIMARY KEY (local_id, subcategoria_id)`; **índice invertido** `idx_parceiros_locais_subcat_subcat_local ON parceiros_locais_subcategorias (subcategoria_id, local_id)`.

---

##### 11. `parceiros_profissionais`
* **Para que serve:** "Lista de escala" **opcional** que liga profissionais aos parceiros (e, opcionalmente, a uma filial específica), permitindo que um profissional atenda em vários estabelecimentos e preservando o histórico quando ele sai (`ativo = FALSE`).
* **Visibilidade:** Público no Guia *(exibe apenas vínculos com `ativo = TRUE`)*.
* **Relacionamento:** Muitos-para-muitos entre `parceiros` (+ `parceiros_locais` opcional) e `profissionais`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do vínculo de atendimento |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro/clínica onde o profissional atende |
| `local_id` | `BIGINT` | Opcional `REFERENCES parceiros_locais(id) ON DELETE CASCADE` | Se `NULL`, atende em **todas** as unidades do parceiro; se preenchido, atende **apenas nesta filial** |
| `profissional_id` | `BIGINT` | `NOT NULL REFERENCES profissionais(id)` | Profissional vinculado |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | `FALSE` desativa o médico naquela clínica/filial sem apagar histórico |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:**
  * `UNIQUE NULLS NOT DISTINCT (parceiro_id, local_id, profissional_id)` (evita duplicar o mesmo médico na mesma clínica/filial, inclusive quando `local_id IS NULL`);
  * Índices: `(parceiro_id, profissional_id) WHERE ativo = TRUE`, `(local_id, profissional_id) WHERE ativo = TRUE AND local_id IS NOT NULL`, e **índice invertido** `idx_parceiros_prof_prof_parceiro ON parceiros_profissionais (profissional_id, parceiro_id) WHERE ativo = TRUE`.

---

##### 12. `parceiros_contatos`
* **Para que serve:** Contatos **internos/particulares** do parceiro (secretária, gerente, financeiro, comercial), seguindo o mesmo padrão de `clientes_pj_contatos`. Pode valer para toda a rede (`abrange_todos_locais = TRUE`) ou para filiais específicas (`abrange_todos_locais = FALSE` + tabela `13`).
* **Visibilidade:** **Estritamente Interno / Sigiloso (nunca exibir no guia público)**.
* **Relacionamento:** Pertence a 1 Parceiro (`parceiro_id -> parceiros(id)`); quando `abrange_todos_locais = FALSE`, liga-se a 1 ou N locais em `parceiros_contatos_locais`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do contato interno |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro ao qual o contato pertence |
| `abrange_todos_locais` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | `TRUE` = responsável por **todas** as unidades da rede; `FALSE` = responsável apenas pelos locais marcados em `parceiros_contatos_locais` |
| `nome` | `VARCHAR(120)` | `NOT NULL` | Nome da pessoa de contato |
| `telefone` | `VARCHAR(20)` | Opcional | Telefone/celular interno do contato |
| `telefone_whatsapp` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | Indica se o telefone atende WhatsApp |
| `cargo` | `VARCHAR(80)` | Opcional | Cargo (ex.: `GERENTE REGIONAL`, `SECRETARIA`, `PROPRIETARIO`) |
| `setor` | `VARCHAR(80)` | Opcional | Setor (ex.: `FINANCEIRO`, `RECEPCAO`, `COMERCIAL`) |
| `email` | `VARCHAR(150)` | Opcional | E-mail interno do contato (formato original) |
| `observacoes` | `TEXT` | Opcional | Notas sobre horário preferencial de contato, assuntos que resolve, etc. |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o contato ainda trabalha no parceiro |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** Índice em `(parceiro_id) WHERE ativo = TRUE`.

---

##### 13. `parceiros_contatos_locais`
* **Para que serve:** Liga um contato interno específico (`abrange_todos_locais = FALSE`) a **1 ou N filiais** (ex.: secretária de uma unidade ou gerente regional que responde por 3 unidades).
* **Visibilidade:** **Estritamente Interno / Sigiloso**.
* **Relacionamento:** Muitos-para-muitos entre `parceiros_contatos` e `parceiros_locais`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `contato_id` | `BIGINT` | `NOT NULL REFERENCES parceiros_contatos(id) ON DELETE CASCADE` | Contato interno |
| `local_id` | `BIGINT` | `NOT NULL REFERENCES parceiros_locais(id) ON DELETE CASCADE` | Filial sob responsabilidade deste contato |
| *Auditoria* | `created_at`, `created_by` | Padrão ligação | Data e usuário que criou o vínculo |

* **Travas e Índices:** `PRIMARY KEY (contato_id, local_id)`; índice invertido em `(local_id, contato_id)` para listar rapidamente os contatos internos de uma filial específica.

---

##### 14. `parceiros_documentos`
* **Para que serve:** Guarda os metadados e chaves de acesso no Storage em nuvem dos anexos do parceiro (contrato, termo LGPD assinado, tabela de preços em PDF, logomarca, banner), seguindo o mesmo padrão de segurança de `documentos_adesao` (item 1.16).
* **Visibilidade:** Misto (`LOGOMARCA` e `BANNER_PATROCINIO` podem ir ao guia; contratos, termos LGPD e tabelas internas são restritos).
* **Relacionamento:** Pertence a 1 Parceiro (`parceiro_id -> parceiros(id)`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do anexo |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro dono do documento |
| `tipo_documento_id` | `BIGINT` | `NOT NULL REFERENCES tipos_documento_parceiro(id)` | Tipo do documento cadastrado em `tipos_documento_parceiro` |
| `nome_arquivo` | `VARCHAR(255)` | `NOT NULL` | Nome original do arquivo enviado |
| `mime_type` | `VARCHAR(100)` | `NOT NULL` | Tipo validado por assinatura binária (*Magic Bytes*) |
| `tamanho_bytes` | `BIGINT` | `NOT NULL CHECK (tamanho_bytes > 0)` | Tamanho do arquivo em bytes |
| `storage_key` | `VARCHAR(500)` | `NOT NULL UNIQUE` | Chave opaca/UUID no Storage externo isolado (nunca `BYTEA` no banco) |
| `sha256_hash` | `CHAR(64)` | `NOT NULL` | Assinatura de integridade SHA-256 do arquivo |
| `observacao` | `TEXT` | Opcional | Descrição livre do documento |
| *Auditoria* | `created_at`, `created_by` | Padrão imutável | Data e usuário do upload |

* **Travas e Índices:** `UNIQUE (storage_key)`; índice em `(parceiro_id, tipo_documento_id)`.

---

##### 15. `tipos_documento_parceiro`
* **Para que serve:** Cadastro extensível dos tipos de documento que podem ser anexados aos parceiros (substitui o antigo ENUM fixo, permitindo ao Administrador criar novos tipos pela tela sem alterar o banco).
* **Visibilidade:** Misto (controlado por `permite_guia_publico`).
* **Relacionamento:** Referenciado por `parceiros_documentos.tipo_documento_id`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do tipo de documento |
| `codigo` | `VARCHAR(50)` | `NOT NULL UNIQUE` | Código interno único (ex.: `CONTRATO_CREDENCIAMENTO`, `LOGOMARCA`) |
| `nome` | `VARCHAR(100)` | `NOT NULL UNIQUE` | Nome de exibição na tela (ex.: `CONTRATO DE CREDENCIAMENTO`, `TERMO LGPD ASSINADO`) |
| `descricao` | `TEXT` | Opcional | Orientação de uso desse tipo de documento |
| `permite_guia_publico` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | `TRUE` apenas para tipos exibidos no guia público (ex.: `LOGOMARCA`, `BANNER_PATROCINIO`) |
| `ordem` | `INTEGER` | `NOT NULL DEFAULT 100` | Ordem de exibição nas listas suspensas (`10, 20, 30...`) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o tipo está ativo para novos uploads |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Seed Inicial Obrigatório:** `CONTRATO_CREDENCIAMENTO` (`permite_guia_publico = FALSE`), `TERMO_LGPD_ASSINADO` (`FALSE`), `TABELA_PRECOS_PDF` (`FALSE`), `LOGOMARCA` (`TRUE`), `BANNER_PATROCINIO` (`TRUE`), `OUTRO` (`FALSE`).
* **Travas e Índices:** `UNIQUE (codigo)`, `UNIQUE (nome)`; índice em `(ativo, ordem)`.

---

##### 16. `parceiros_precos_beneficios`
* **Para que serve:** Caderno de preços e descontos do parceiro, estruturado por **Convênio (`convenio_id`)** — suportando tanto 2 faixas padrão para credenciados (*Particular* e *Associado*) quanto **N convênios** para Clínicas Próprias (*Particular*, *Associado*, *Parceiro*, *Prefeitura*, etc.). Permite preço geral para toda a rede (`local_id IS NULL`) ou preço específico por unidade (`local_id` preenchido), podendo variar também por médico ou procedimento.
* **Visibilidade:** Controlado pela **Trava Dupla CRM** de `parceiros` + flag `exibir_guia_publico` de `convenios`.
* **Relacionamento:** Pertence a 1 Parceiro (`parceiro_id`) e a 1 Convênio (`convenio_id`), com vínculos opcionais a `parceiros_locais`, `profissionais`, `subcategorias` e `catalogo_procedimentos`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único da regra de preço/desconto |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro dono do caderno de preços |
| `convenio_id` | `BIGINT` | `NOT NULL REFERENCES convenios(id)` | Qual convênio/faixa este valor representa (*Particular*, *Associado*, *Parceiro*, *Prefeitura*, etc.) |
| `local_id` | `BIGINT` | Opcional `REFERENCES parceiros_locais(id) ON DELETE CASCADE` | **Escada Anti-Empate:** se `NULL`, vale para **todas as unidades** da rede (Degrau 1 — exige `profissional_id IS NULL`); se preenchido, vale **apenas para esta unidade** (Degrau 2 ou Degrau 3) |
| `profissional_id` | `BIGINT` | Opcional `REFERENCES profissionais(id)` | Permite diferenciar preço/desconto por profissional **dentro de um local específico** (Degrau 3 — exige `local_id IS NOT NULL` e vínculo ativo em `parceiros_profissionais`) |
| `subcategoria_id` | `BIGINT` | Opcional `REFERENCES subcategorias(id)` | Especialidade/ramo ao qual o benefício se aplica (filtrado no funil pelas especialidades ativas daquele parceiro/local) |
| `procedimento_id` | `BIGINT` | Opcional `REFERENCES catalogo_procedimentos(id)` | Procedimento/exame do catálogo (ex.: `CONSULTA` combinado com `subcategoria_id`, ou exame específico como `ECOCARDIOGRAMA`) |
| `tipo_precificacao` | `tipo_precificacao_enum` | `NOT NULL` | `VALOR_FIXO`, `PERCENTUAL_DESCONTO` ou `SOB_CONSULTA` |
| `valor` | `NUMERIC(12, 2)` | Opcional (`CHECK >= 0`) | Valor em reais (usado quando `tipo_precificacao = 'VALOR_FIXO'`) |
| `percentual_desconto` | `NUMERIC(5, 2)` | Opcional (`CHECK > 0 AND <= 100`) | Percentual de desconto (usado quando `tipo_precificacao = 'PERCENTUAL_DESCONTO'`) |
| `descricao_beneficio` | `VARCHAR(255)` | Opcional | Texto livre quando não há procedimento no catálogo (ex.: *"20% EM MEDICAMENTOS GENERICOS"*) |
| `regras_pagamento` | `VARCHAR(255)` | Opcional | Condições comerciais (ex.: *"SOMENTE NO PIX OU DINHEIRO"*, *"ATE 3X NO CARTAO"*) |
| `observacoes` | `TEXT` | Opcional | Observações complementares |
| `vigencia_inicio` | `DATE` | Opcional | Data a partir da qual o preço/desconto passou a valer |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Indica se o item de preço está vigente |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:**
  * **Consistência de Preço:** `CHECK ((tipo_precificacao = 'VALOR_FIXO' AND valor IS NOT NULL AND percentual_desconto IS NULL) OR (tipo_precificacao = 'PERCENTUAL_DESCONTO' AND percentual_desconto IS NOT NULL AND valor IS NULL) OR (tipo_precificacao = 'SOB_CONSULTA' AND valor IS NULL AND percentual_desconto IS NULL))`;
  * **Trava Anti-Empate (Profissional sempre exige Local):** `CHECK (profissional_id IS NULL OR local_id IS NOT NULL)` — elimina matematicamente qualquer empate entre "preço do profissional sem local" e "preço da filial sem profissional";
  * **Trava Anti-Linha Vazia ("Muda"):** `CHECK (procedimento_id IS NOT NULL OR subcategoria_id IS NOT NULL OR NULLIF(TRIM(descricao_beneficio), '') IS NOT NULL)` — impede cadastrar valor/desconto sem informar a que item/serviço se refere;
  * **Trava Anti-Duplicidade Ativa (PostgreSQL 15+):** `CREATE UNIQUE INDEX uq_parceiros_precos_ativo ON parceiros_precos_beneficios (parceiro_id, convenio_id, local_id, profissional_id, subcategoria_id, procedimento_id, COALESCE(NULLIF(TRIM(descricao_beneficio), ''), '')) NULLS NOT DISTINCT WHERE ativo = TRUE` — impede fisicamente duas regras ativas duplicadas para a mesma combinação;
  * **Validação no Backend (Funil):** Se `local_id` preenchido, confirmar que pertence ao `parceiro_id`; se `profissional_id` preenchido, confirmar vínculo ativo em `parceiros_profissionais` para aquele `parceiro_id` e `local_id` (ou vínculo geral de rede do profissional); se `subcategoria_id` preenchida, confirmar que pertence ao conjunto de especialidades ativas do parceiro/local;
  * Índices: `(parceiro_id, convenio_id) WHERE ativo = TRUE`, `(local_id, convenio_id) WHERE ativo = TRUE AND local_id IS NOT NULL`, `(procedimento_id) WHERE ativo = TRUE AND procedimento_id IS NOT NULL`, `(profissional_id) WHERE ativo = TRUE AND profissional_id IS NOT NULL`.

---

##### 17. `parceiros_precos_historico`
* **Para que serve:** Registro automático e imutável de todos os reajustes de preço ou desconto (além do log técnico em `auditoria_eventos`), facilitando auditoria comercial e histórico de negociações.
* **Visibilidade:** **Estritamente Interno**.
* **Relacionamento:** Vinculado ao item alterado (`preco_beneficio_id`), ao parceiro (`parceiro_id`) e ao convênio (`convenio_id`).

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do registro de histórico |
| `preco_beneficio_id` | `BIGINT` | `NOT NULL REFERENCES parceiros_precos_beneficios(id) ON DELETE CASCADE` | Item de preço que sofreu reajuste |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro correspondente (atalho para relatórios de histórico) |
| `convenio_id` | `BIGINT` | `NOT NULL REFERENCES convenios(id)` | Convênio/faixa afetado (*Particular*, *Associado*, *Prefeitura*, etc.) |
| `tipo_precificacao_anterior` | `tipo_precificacao_enum` | `NOT NULL` | Tipo anterior do preço |
| `tipo_precificacao_novo` | `tipo_precificacao_enum` | `NOT NULL` | Novo tipo do preço |
| `valor_anterior` | `NUMERIC(12, 2)` | Opcional | Valor monetário anterior |
| `valor_novo` | `NUMERIC(12, 2)` | Opcional | Novo valor monetário |
| `percentual_anterior` | `NUMERIC(5, 2)` | Opcional | Percentual de desconto anterior |
| `percentual_novo` | `NUMERIC(5, 2)` | Opcional | Novo percentual de desconto |
| `motivo` | `TEXT` | Opcional | Justificativa do reajuste (ex.: *"REAJUSTE ANUAL 2026"*) |
| `alterado_em` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | Data/hora exata da alteração |
| `alterado_por_usuario_id` | `BIGINT` | `NOT NULL REFERENCES usuarios(id)` | Usuário responsável pela alteração |

* **Travas e Índices:** Índice em `(preco_beneficio_id, alterado_em DESC)` e `(parceiro_id, alterado_em DESC)`.

---

##### 18. `parceiros_planos_elegiveis` *(Preparada para o Futuro)*
* **Para que serve:** Permite restringir no futuro um parceiro ou um benefício específico apenas a associados que pagam determinados **planos da associação** (`planos`, ex.: *Básico*, *Bronze*, *Plus*) ou **benefícios adicionais** (`beneficios_adicionais`, ex.: *Cuidado Pet*, *Seguro Funeral*). **Quando não houver registros para um parceiro/benefício, qualquer associado de qualquer plano/unidade tem direito.**
  * **Atenção — Não confundir com `convenios` (obrigatório documentar no SQL via `COMMENT ON` e comentário inline):** `convenios` define a **faixa de preço no atendimento** (`PARTICULAR`, `ASSOCIADO`, `PARCEIRO`, `PREFEITURA`), usada em `parceiros_precos_beneficios`; já `planos` define o **pacote mensal contratado pelo associado no carnê**. Esta tabela (`parceiros_planos_elegiveis`) controla **quem tem acesso** (ex.: clínica veterinária liberada apenas para quem tem *Plano Plus* ou adicional *Cuidado Pet*).
* **Visibilidade:** Interno / Regra de filtro do Guia.
* **Relacionamento:** Liga `parceiros` (e opcionalmente `parceiros_precos_beneficios`) a `planos` e/ou `beneficios_adicionais`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único da regra de elegibilidade |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro restrito |
| `preco_beneficio_id` | `BIGINT` | Opcional `REFERENCES parceiros_precos_beneficios(id) ON DELETE CASCADE` | Se `NULL`, aplica-se ao parceiro todo; se preenchido, apenas àquele benefício |
| `plano_id` | `BIGINT` | Opcional `REFERENCES planos(id)` | Plano mensal do associado na Associação (ex.: Básico, Plus — **não** é faixa de `convenios`) |
| `beneficio_adicional_id` | `BIGINT` | Opcional `REFERENCES beneficios_adicionais(id)` | Benefício adicional contratado pelo associado/dependente (ex.: Cuidado Pet, Seguro Funeral) |
| *Auditoria* | `created_at`, `created_by` | Padrão ligação | Data e usuário que configurou a regra |

* **Travas e Índices:** `CHECK (plano_id IS NOT NULL OR beneficio_adicional_id IS NOT NULL)`; índice em `(parceiro_id)` e `(preco_beneficio_id) WHERE preco_beneficio_id IS NOT NULL`.
* **Orientação Obrigatória para o Novo SQL (`02_schema_postgresql_moderno.sql`):** Inserir `COMMENT ON TABLE parceiros_planos_elegiveis`, `COMMENT ON COLUMN parceiros_planos_elegiveis.plano_id` e comentário inline explicando explicitamente a diferença entre `planos` (pacote mensal pago pelo associado) e `convenios` (faixa de preço praticada no atendimento).

---

##### 19. `parceiros_destaques`
* **Para que serve:** Gerencia parceiros, filiais, profissionais ou ofertas em destaque (editorial interno ou patrocinado) no guia online/app, com controle de vigência, escopo geográfico/categoria e ordem de exibição.
* **Visibilidade:** Público no Guia *(apenas registros ativos dentro de `data_inicio`..`data_fim`)*.
* **Relacionamento:** Liga-se a `parceiros` (obrigatório) e opcionalmente a `parceiros_locais`, `profissionais`, `parceiros_precos_beneficios` e `subcategorias`.

| Coluna | Tipo PostgreSQL | Obrigatório / Padrão | Significado / Comentário SQL |
| :--- | :--- | :--- | :--- |
| `id` | `BIGSERIAL` | `PRIMARY KEY` | Identificador único do destaque |
| `tipo_destaque` | `tipo_destaque_parceiro_enum` | `NOT NULL` | `EDITORIAL_INTERNO` ou `PATROCINADO` |
| `parceiro_id` | `BIGINT` | `NOT NULL REFERENCES parceiros(id) ON DELETE CASCADE` | Parceiro destacado |
| `local_id` | `BIGINT` | Opcional `REFERENCES parceiros_locais(id) ON DELETE CASCADE` | Se preenchido, destaca especificamente aquela filial da rede |
| `profissional_id` | `BIGINT` | Opcional `REFERENCES profissionais(id)` | Opcional para destacar um médico específico |
| `preco_beneficio_id` | `BIGINT` | Opcional `REFERENCES parceiros_precos_beneficios(id) ON DELETE SET NULL` | Opcional para vincular uma oferta específica (respeitando Trava CRM) |
| `subcategoria_id` | `BIGINT` | Opcional `REFERENCES subcategorias(id)` | Especialidade/ramo onde o destaque aparece (obrigatório nos escopos `CATEGORIA` e `CIDADE_CATEGORIA`) |
| `escopo` | `escopo_destaque_parceiro_enum` | `NOT NULL` | Onde o destaque aparece: `GERAL`, `CIDADE`, `CATEGORIA` ou `CIDADE_CATEGORIA` |
| `cidade` | `VARCHAR(100)` | Opcional | Cidade-alvo (obrigatória nos escopos `CIDADE` e `CIDADE_CATEGORIA`) |
| `estado` | `CHAR(2)` | Opcional | UF-alvo (obrigatória quando `cidade` informada) |
| `nivel_patrocinio` | `INTEGER` | `NOT NULL DEFAULT 0` | Peso/nível do patrocínio (quanto maior, maior prioridade na vitrine) |
| `texto_promocional` | `VARCHAR(255)` | Opcional | Chamada curta exibida no card de destaque |
| `banner_storage_key` | `VARCHAR(500)` | Opcional | Chave no Storage da imagem do banner |
| `ordem` | `INTEGER` | `NOT NULL DEFAULT 100` | Posição numérica de exibição para desempate dentro do mesmo escopo (`10, 20, 30...`) |
| `data_inicio` | `DATE` | `NOT NULL` | Início da vigência do destaque |
| `data_fim` | `DATE` | Opcional | Fim da vigência (`NULL` = sem data de término; se preenchido, `CHECK (data_fim >= data_inicio)`) |
| `ativo` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Permite pausar o destaque manualmente antes do fim da vigência |
| *Auditoria* | `created_at`, `updated_at`, `created_by`, `updated_by` | Padrão do módulo | Rastreabilidade |

* **Travas e Índices:** `CHECK (data_fim IS NULL OR data_fim >= data_inicio)`; índice em `(ativo, escopo, estado, cidade, subcategoria_id, nivel_patrocinio DESC, ordem ASC)` para montagem instantânea da vitrine do guia.

---

#### 1.25.4 Regras de Negócio Consolidadas do Módulo

1. **Múltiplas Especialidades e Independência:** Tanto a rede (`parceiros_subcategorias`), cada filial (`parceiros_locais_subcategorias`) quanto os profissionais (`profissionais_subcategorias`) podem possuir **múltiplas especialidades**, de forma independente (as especialidades da clínica ou filial **não restringem** as dos profissionais vinculados a ela).
2. **Regra da União (`UNION`) por Filial na Pesquisa, Guia e Livreto:** Toda busca por especialidade/ramo (no sistema, no guia online e na geração do livreto) deve avaliar cada filial ativa (`parceiros_locais`) retornando a **união sem duplicatas** entre:
   * **(a)** especialidades gerais do parceiro (`parceiros_subcategorias`);
   * **(b)** especialidades exclusivas daquela filial (`parceiros_locais_subcategorias`);
   * **(c)** especialidades dos profissionais ativos (`profissionais.ativo = TRUE`) vinculados de forma ativa (`parceiros_profissionais.ativo = TRUE`) àquela filial específica **ou** ao parceiro com `local_id IS NULL`.
   * *Resultado garantido:* uma filial que só oferece *Odontologia* nunca aparece numa busca de *Cardiologia*, mesmo que outra filial da mesma empresa ofereça *Cardiologia*.
3. **Escada Anti-Empate de 3 Degraus, Zero Duplicidade e Procedimentos Genéricos (`parceiros_precos_beneficios`):**
   * **Zero Empates (`CHECK (profissional_id IS NULL OR local_id IS NOT NULL)`):** É proibido cadastrar preço de profissional sem informar o `local_id`. A resolução de preço para um dado `convenio_id` segue uma hierarquia estrita em 3 degraus sem sobreposição lateral:
     1. **Degrau 3 (Mais específico — prevalece sempre):** `local_id` preenchido + `profissional_id` preenchido (exceção do profissional naquela filial);
     2. **Degrau 2:** `local_id` preenchido + `profissional_id IS NULL` (padrão da filial);
     3. **Degrau 1 (Mais genérico):** `local_id IS NULL` + `profissional_id IS NULL` (padrão geral da rede).
   * **Zero Duplicidade e Zero Linha Vazia:** Índice único parcial (`NULLS NOT DISTINCT WHERE ativo = TRUE`) bloqueia regras ativas duplicadas, e `CHECK` exige ao menos `procedimento_id`, `subcategoria_id` ou `descricao_beneficio`.
   * **Reuso de Procedimentos Genéricos:** Não exigir lista prévia de procedimentos por filial nem criar procedimentos duplicados por especialidade (ex.: manter um único `CONSULTA` em `catalogo_procedimentos` combinado com `subcategoria_id` no funil de preços).
4. **Trava Dupla CRM (Privacidade de Preços):** Nenhum preço ou desconto aparece no guia público a menos que: `parceiros.bloqueio_divulgacao_valores = FALSE` (alterável apenas por `ADMINISTRADOR`) **E** `parceiros.exibir_valores_guia_publico = TRUE` **E** `convenios.exibir_guia_publico = TRUE`.
5. **Revisão Semestral:** Painel/alerta automático sinaliza parceiros ativos cujas datas `cadastro_atualizado_em` ou `precos_atualizados_em` estejam nulas ou com mais de 6 meses. Cada data é atualizada **automaticamente** quando há alteração na respectiva área (cadastro/locais/contatos $\to$ `cadastro_atualizado_em`; preços/benefícios/PDF de tabela $\to$ `precos_atualizados_em`) e também **manualmente** via botão **"Confirmar como Conferido Hoje"** na ficha do parceiro (quando na conferência semestral não houve alteração).
6. **Segurança de Anexos:** `parceiros_documentos` e banners seguem integralmente a regra de validação de assinatura binária (*Magic Bytes*), Storage isolado sem execução e `sha256_hash` definida no item **1.16**.

---

#### 1.25.5 Regras de Tela e Experiência de Uso (UX)

* **Ficha Única (Mestre-Detalhe) com Botões `+`:** Todo o cadastro do parceiro acontece em uma **única tela** organizada em blocos logo abaixo dos dados principais, com botões **`+`** para adicionar especialidades, endereços (1º endereço já aberto), profissionais, contatos internos, preços/benefícios e documentos — sem obrigar o operador a navegar entre várias telas.
* **Cadastro Unificado para Profissional Autônomo (`PROFISSIONAL_PF`):** Ao escolher *"Profissional Autônomo (Consultório Próprio)"*, a mesma tela exibe o bloco de dados pessoais internos do profissional (ou permite selecionar um profissional já cadastrado) integrado aos dados públicos do consultório; ao salvar, o sistema grava e vincula `profissionais` + `parceiros` + `parceiros_locais` automaticamente.
* **Clareza de Alcance nas Especialidades:**
  * Bloco superior: **"Especialidades da Rede (valem para TODOS os endereços)"** — botão **`+ Adicionar para todos os endereços`**, com texto de apoio orientando a deixar vazio quando as filiais atendem especialidades diferentes.
  * Dentro de cada card de endereço: **"Especialidades exclusivas deste endereço"** — botão **`+ Adicionar só neste endereço`** (exibindo como lembrete visual eventuais especialidades herdadas da rede).
* **Clareza de Alcance nos Contatos Internos:** Ao clicar em `+ Adicionar contato interno`, o operador escolhe entre `(•) Responsável por todos os endereços` (`abrange_todos_locais = TRUE`) ou `( ) Responsável apenas por endereços específicos` (`abrange_todos_locais = FALSE`, abrindo caixas de seleção para marcar 1 ou N filiais).
* **Fluxo em Funil de Precificação (6 Passos — Zero Erros e Zero Empates):** Ao adicionar preços em `parceiros_precos_beneficios`, os seletores pesquisáveis (comboboxes) filtram em cascata no backend e na UI:
  1. **Parceiro** *(já selecionado na ficha)*;
  2. **Local (`local_id`):** *"Todos os Locais (Padrão da Rede)"* (`NULL`) ou uma filial específica daquele parceiro *(se o parceiro possuir apenas 1 local, pré-selecionar automaticamente)*;
  3. **Especialidade / Ramo (`subcategoria_id`, opcional):** lista apenas as especialidades ativas daquele parceiro/local (ou vazio para desconto geral da loja);
  4. **Profissional (`profissional_id`, opcional):** **habilitado somente quando um Local foi escolhido no Passo 2**, listando apenas profissionais ativos naquele local e especialidade *(com botão de conveniência **"Aplicar para todas as filiais onde este profissional atende"**, que grava 1 linha por filial onde o profissional atua sem gerar empates)*;
  5. **Procedimento (`procedimento_id`) ou Descrição Livre (`descricao_beneficio`):** caixa pesquisável do catálogo geral (reaproveitando itens genéricos como `CONSULTA` combinados à especialidade do Passo 3) ou descrição livre (ex.: farmácias/comércios);
  6. **Grade de Convênios e Preços (`convenio_id`):** na ficha de parceiros credenciados, exibe lado a lado as colunas padrão (**Particular** e **Associado**) para digitação rápida; nas Clínicas Próprias (`UNIDADE_PROPRIA`), exibe todos os convênios ativos (**Particular**, **Associado**, **Parceiro**, **Prefeitura** e futuros).

---

### 1.26 Nova Tabela `autorizacoes_financeiras_excecao` (Alçada de Gerente / Código Único do Administrador)
* **Objetivo:** Controlar e auditar solicitações de **desconto em renegociação** ou **perdão de dívida antiga na reativação** quando o operador não possui autonomia (`perm_autorizar_desconto_perdao`).
* **Estrutura Prevista:** `id`, `unidade_id` (`REFERENCES unidades(id)`), `solicitante_usuario_id` (`REFERENCES usuarios(id)`), `tipo_operacao` (`PERDAO_DIVIDA_REATIVACAO`, `DESCONTO_RENEGOCIACAO`), `num_adesao` (`REFERENCES adesoes(numero)`), `valor_original NUMERIC(12,2)`, `valor_desconto_perdao NUMERIC(12,2)`, `motivo_solicitacao TEXT`, `modo_liberacao` (`SENHA_PRESENCIAL_GERENTE`, `CODIGO_UNICO_EMAIL`, `PAINEL_ADMIN`), `codigo_hash VARCHAR(255)` (hash do código aleatório único de uso único e validade curta), `expira_em TIMESTAMPTZ`, `autorizador_usuario_id` (`REFERENCES usuarios(id)`), `status` (`PENDENTE`, `APROVADA`, `REJEITADA`, `EXPIRADA`, `UTILIZADA`), `autorizado_em TIMESTAMPTZ`, `utilizado_em TIMESTAMPTZ`, `created_at TIMESTAMPTZ`.

---

## 2. Pendências Obrigatórias para o ETL de Migração (`Firebird -> PostgreSQL`)

1. **Validação Matemática e Saneamento de CPFs em `CLIENTES`:**
   * Para cada registro legado: aplicar `SomenteNumeros(CPF)` e validar **Módulo 11 + rejeição de dígitos repetidos** (`00000000000`, `11111111111`, etc.).
   * **Se válido (e não duplicado):** gravar os 11 dígitos em `clientes_pf.cpf`.
   * **Se inválido ou vazio:** gravar `clientes_pf.cpf = NULL` e preservar o valor original exato do legado em **`cpf_legado_bruto`** (sinalizando para saneamento cadastral sem perder histórico).
2. **Auditoria de CPFs Duplicados:**
   * Antes da carga final, rodar query de detecção de CPFs válidos duplicados no Firebird (`UNIQUE (cpf)` será aplicado em `clientes_pf`) para decisão/unificação pelo operador.
3. **Migração de Telefones Legados:**
   * Mapear `TELEFONE_CELULAR` $\to$ `telefone1`, `TELEFONE_COMERCIAL` $\to$ `telefone2`, `TELEFONE_FAX` $\to$ `telefone3` (com flags `*_whatsapp = FALSE`).
4. **Verificação de `DIAVENC` Legado:**
   * Checar no `ABAC.FDB` se existem clientes ativos/históricos com `DIAVENC` fora de `(5, 10, 15, 20, 25)` antes de definir `CHECK` rígido no PostgreSQL.
5. **Mapeamento de `PARCELAS` Históricas:**
   * Verificar no banco Firebird atual se existem parcelas com `ANOMES` `'YY98'`, `'YY99'` e taxas `'0000'` para garantir que todas migrem com `origem_baixa = 'LEGADO'` e o status correto.

---

## 3. Protocolo Obrigatório de Execução e Validação de Conformidade

> **Regra para quando formos aplicar as alterações no `02_schema_postgresql_moderno.sql` e demais documentos:**

1. **Leitura Integral e Cruzada Prévia:**
   * Antes de editar qualquer arquivo estrutural, ler **todos** os documentos da pasta `especificacao_tecnica/` (`01` a `08`) e o `DOCUMENTO_REQUISITOS_E_ESPECIFICACAO_SGC.md` para garantir visão completa de coerência e concordância entre banco, regras de negócio, telas, CNAB e relatórios.
2. **Varredura de Impacto em Cada Alteração (Zero Referências Órfãs):**
   * A cada mudança aplicada (ex.: remover ou renomear um `ENUM`, tabela, coluna, `SEQUENCE` ou constraint), varrer **todo o `.sql` e os demais documentos** para atualizar ou eliminar todas as referências dependentes (`DEFAULT`, `REFERENCES`, `INDEX`, `CHECK`, regras financeiras, endpoints e relatórios) — evitando que um item removido continue aparecendo em outro trecho (como remover `'PF_PRE_IMPRESSO'` do enum e esquecê-lo em `DEFAULT` ou em índices/telas).
3. **Interrupção Diante de Quebra de Conformidade (Sem Loop de Revisão):**
   * Se qualquer alteração proposta entrar em conflito com outra tabela, regra financeira, layout bancário, tela ou relatório, **não improvisar nem aplicar silenciosamente**: parar antes da edição, explicar o contexto completo do conflito, orientar com as alternativas e fazer perguntas objetivas ao usuário até fechar uma decisão definitiva.
4. **Conferência Global Pós-Edição:**
   * Ao concluir as atualizações, revisar o `02_schema_postgresql_moderno.sql` de ponta a ponta (tipos, FKs, `DEFAULT`s, `CHECK`s, índices, `SEQUENCE`s e auditoria `created_by`/`updated_by`) e confirmar alinhamento integral com `03`, `04`, `05`, `06`, `07` e `08`.
5. **Documentação Obrigatória de Campos Não Óbvios no `.sql` (`COMMENT ON` e Comentários Inline):**
   * Ao refatorar/gerar o `02_schema_postgresql_moderno.sql`, todo campo, flag, enum ou regra cujo significado ou uso prático não seja imediatamente óbvio pelo nome (ex.: `ordem` em `categorias` e `parceiros_destaques`, `exige_autorizacao`, `bloqueio_divulgacao_valores`, `exibir_valores_guia_publico`, `nivel_patrocinio`, códigos herdados, e a **distinção entre `planos` [pacote mensal do associado em `parceiros_planos_elegiveis`] vs. `convenios` [faixa de preço no atendimento em `parceiros_precos_beneficios`]**, etc.) **deve** receber comentários claros no próprio `.sql` — usando **comentários inline (`-- ...`)** junto à definição da coluna **e/ou** comandos **`COMMENT ON COLUMN` / `COMMENT ON TABLE`** do PostgreSQL, explicando em linguagem direta o que o campo representa e como deve ser usado.
