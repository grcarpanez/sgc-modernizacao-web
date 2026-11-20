# 07 — Pendências de Migração (ETL) e Ajustes no Schema Moderno

> **Propósito deste Documento:** Registrar problemas, lacunas de modelagem e decisões técnicas descobertas durante a revisão conjunta dos schemas (`01_schema_firebird_legado.sql` e `02_schema_postgresql_moderno.sql`). Este arquivo serve como **memória oficial para a IA Agêntica** revisar o `02_schema_postgresql_moderno.sql` antes do congelamento do banco e implementar corretamente o script de migração (`Firebird -> PostgreSQL`).
>
> **Status:** Em construção (atualizado conforme o avanço da leitura dos arquivos `.sql`).

---

## 1. Ajustes Pendentes no Schema (`02_schema_postgresql_moderno.sql`)

### 1.1 Unicidade de CPF em `clientes_pf`
* **Estado Atual no SQL Moderno:** `clientes_pf.cpf` possui apenas um índice simples (`idx_clientes_pf_cpf`), sem constraint `UNIQUE`.
* **Decisão de Negócio:** O sistema **deve impedir** a criação de dois cadastros para o mesmo CPF (ex-clientes que retornam devem passar pelo fluxo de **Reativação** — ver `08_rotinas_operacionais_nao_documentadas.md`).
* **Ação no Schema:**
  * Adicionar `CONSTRAINT uq_clientes_pf_cpf UNIQUE (cpf)` em `clientes_pf`.
  * *Nota técnica PostgreSQL:* `UNIQUE (cpf)` permite múltiplos `NULL` (usado para CPFs inválidos/ausentes do legado preservados em `cpf_legado_bruto`), mas bloqueia estritamente qualquer CPF válido duplicado.

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
  * Como `parcelas` no PostgreSQL já possui `id BIGSERIAL PRIMARY KEY` e `num_carne` (FK para `carnes`), a unicidade estrutural de uma lâmina deve ser vinculada ao **carnê** (`(num_carne, anomes)` ou `(num_carne, id_parc)`), e **não** globalmente a `(num_adesao, anomes)`.
  * Adicionar um campo de **situação/status da parcela** (ex.: `ABERTA`, `PAGA`, `QUITADA_POR_UNICA`, `CONSOLIDADA`, `CANCELADA`) para que parcelas futuras de carnês interrompidos sejam **canceladas logicamente (`CANCELADA`)** em vez de deletadas com `DELETE`, preservando 100% da auditoria.
  * Para manter compatibilidade com chaves de busca de retorno CNAB/Excel que usam `(num_adesao, anomes)`:
    * Criar um **índice único parcial** garantindo apenas **uma parcela ativa/em aberto** por `(num_adesao, anomes)` quando aplicável (ex.: `WHERE situacao = 'ABERTA'`), permitindo múltiplas parcelas `CANCELADA` ou taxas de `REATIVACAO` em carnês distintos; **ou**
    * Definir uma convenção explícita para `anomes` / `id_parc` de taxas de reativação (a ser fechada antes da implementação).

---

### 1.3 Flag de Isenção da Taxa de Manutenção Anual Pós-Reativação
* **Contexto:** Pela regra legada (`04_regras_negocio_financeiro_cnab_arquivos.md`), qualquer cliente que já tenha um `CARNE` anterior com `NUM_PARC = 12` recebe automaticamente o acréscimo de renovação $A$ (default R\$ 12,00) na parcela `01/12` e na `ÚNICA`.
* **Necessidade Real:** Quando um cliente passa por **Reativação**, ele já paga a taxa de adesão/reativação no ato, portanto o **primeiro carnê gerado após a reativação NÃO deve cobrar a taxa de manutenção anual** ($A = 0,00$), exatamente como ocorre no 1º carnê de um cliente novo.
* **Ação no Schema:** Prever mecanismo explícito (ex.: coluna `isento_taxa_proxima_renovacao BOOLEAN NOT NULL DEFAULT FALSE` em `clientes_pf` ou vínculo com registro de reativação) que o gerador de carnês consome e zera após emitir o carnê pós-reativação.

---

### 1.4 Separação entre Vencimento Real da Parcela e Vencimento Enviado na Remessa CNAB
* **Contexto:** Quando um cliente quita o carnê anterior com meses de atraso, as parcelas retroativas do novo carnê (ex.: março a julho geradas em julho) não podem ser registradas no banco com data de vencimento no passado (bancos rejeitam boletos vencidos na remessa).
* **Necessidade Real:** Manter `parcelas.data_vencimento` com o **vencimento real/original** da competência (`anomes`, que também continua visível para o cliente e atendimento identificarem a qual mês a parcela pertence) e, na **geração do arquivo de remessa CNAB**, detectar vencimentos passados e ajustar a data enviada ao banco para o próximo vencimento válido do cliente (eventualmente registrando `data_vencimento_remessa` para rastreabilidade).

---

### 1.5 Identificação Única no Sicoob CNAB 240 (`Nosso Número`, `Nº do Documento` e `Uso da Empresa`)
* **Verificação no Layout Oficial Sicoob (`Layouts_para_troca_de_informações - cooperativas.xls`):**
  1. **`Nosso Número` (Seg. `P` `38..57` / Retorno `T` `38..57`):** Os `10` primeiros bytes são o `NumTitulo` (`7 dígitos` sequenciais via `seq_nosso_numero_sicoob` + `1` DV Módulo 11 `3197`, preenchidos com zeros à esquerda). Como é um sequencial único global por parcela, **não se repete** entre carnês e não deve ser alterado com `num_carne`/`anomes`.
  2. **`Nº do Documento` ("Seu Número", Seg. `P` `63..77` / Retorno `T` `59..73`):** Suporta **15 caracteres (`Alfa`)**. Hoje usa `NUM_ADESAO + ANOMES`; se concatenar `num_carne + num_adesao + anomes` sem cuidado, pode estourar 15 posições quando `num_carne` e `num_adesao` tiverem 6+ dígitos cada.
  3. **`Uso Empresa Beneficiário` ("Identificação do Título na Empresa", Seg. `P` `196..220` / Retorno `T` `106..130`):** Suporta **25 caracteres**, devolvidos integralmente pelo Sicoob no retorno!
* **Diretriz:** Manter `Nosso Número` sequencial único por parcela; usar o campo **`Uso da Empresa` (25 posições)** para gravar a chave composta completa (ex.: `num_carne + num_adesao + anomes` ou `parcelas.id`), garantindo conciliação 100% inequívoca no retorno mesmo entre múltiplos carnês.

---

### 1.6 Suporte a Renegociação / Acordo Parcelado (Relação `N:M` em vez de apenas `N:1`)
* **Estado Atual no SQL Moderno:** `parcelas.parcela_consolidadora_id` aponta para apenas **1** parcela destino (atendendo somente o `'DEBIT'` à vista/`1x`).
* **Necessidade Real:** Permitir que $N$ parcelas vencidas (ex.: 4 parcelas de R\$ 25,00 = R\$ 100,00) sejam renegociadas em $M$ novas parcelas de acordo (ex.: 3x de R\$ 33,33, podendo ter valores que não são múltiplos das parcelas originais, além de juros ou descontos).
* **Ação no Schema:**
  * Criar estrutura de vínculo `N:M` (ex.: tabela `renegociacoes` + `renegociacao_itens` ligando as parcelas originais ao carnê/parcelas do acordo, além de manter `parcela_consolidadora_id` ou `carne_acordo_id` conforme o desenho final).
  * As parcelas originais recebem baixa técnica (`valor_pago = 0.00`, `situacao = 'RENEGOCIADA'` / `origem_baixa = 'CONSOLIDACAO_DEBIT'` ou `'RENEGOCIACAO'`), e as $M$ novas parcelas do acordo passam a ter `nosso_numero` próprio, registro CNAB e baixa automática pelo retorno bancário.

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
  * **Dividir nome em `razao_social` + `nome_fantasia` (e/ou `nome` da unidade):**
    * No ETL, `EMPRESAS.NOME_EMPRESA` migra para `razao_social` da unidade matriz (`eh_matriz = TRUE`).
    * Nos layouts posicionais e CNAB 240 (Header de `REMADESAO`, `REMESSA` e `CNAB 240`), utilizar **`razao_social`** da unidade matriz (nome oficial atrelado ao CNPJ do cedente).
    * Na interface web e relatórios PDF, utilizar `COALESCE(nome_fantasia, razao_social)`.
* **Nova Tabela `contas_cobranca` (Central de Contas Bancárias):**
  * Extrair os parâmetros bancários (`agencia`, `dv_agencia`, `conta`, `dv_conta`, `codigo_cedente`, `carteira`, `modalidade`, `percentual_multa`, `juros_mora_dia`, `codigo_banco`, `nsa_sequencial`, `padrao`, `ativo`) para tabela própria vinculada à matriz.
  * Permite múltiplos bancos (Sicoob `756`, Caixa `104`, Banco do Brasil `001`, etc.) sem depender de colunas fixas por banco.
  * Avaliar substituição/evolução de `banco_cobranca_enum` para referência direta a `conta_cobranca_id` nos cadastros e lotes.
* **Novas Tabelas de Gestão de Planos e Benefícios Adicionais:**
  * Extrair os preços únicos (`valor_base_plano_pf`, `valor_adicional_dependente_pf`, `desconto_parcela_unica_percent`).
  * Criar **`planos`**: cadastro de planos (ex.: *Básico*, *Plus*, *Básico + Funeral + Pet*), contendo `valor_titular`, `valor_dependente`, `valor_taxa_adesao`, `valor_acrescimo_renovacao`, `desconto_parcela_unica_percent`, `ativo`.
  * Criar **`beneficios_adicionais`** (ex.: *Seguro Funeral*, *Seguro Casa*, *Cuidado Pet*) e vínculo **`cliente_beneficios_adicionais`** (N:M com o cliente, além de `plano_id` no cadastro do associado), permitindo tanto **pacotes prontos** quanto **plano base + benefícios agregados**.

---

### 1.9 Auditoria Direta nas Tabelas (`created_by` e `updated_by`)
* **Estado Atual no SQL Moderno:** As tabelas possuem `created_at` e `updated_at`, mas não possuem colunas diretas de autoria (`created_by` / `updated_by`), ficando a identificação do usuário apenas em `auditoria_eventos` (ou `baixado_por_usuario_id` em `parcelas`).
* **Ação no Schema:** Padronizar **`created_by BIGINT REFERENCES usuarios(id)`** e **`updated_by BIGINT REFERENCES usuarios(id)`** em `empresas` e nas demais tabelas principais de cadastro/negócio (permitindo `NULL` para registros iniciais de seed/ETL legado).

---

### 1.10 Revisão Completa do RBAC em `usuarios` (Ao Final do Mapeamento)
* **Estado Atual no SQL Moderno:** A tabela `usuarios` replica as 14 flags booleanas do legado + 4 novas, incluindo itens que mudaram de significado ou deixaram de existir (`perm_convenios_*` $\to$ unidades, `perm_mudar_conexao`, `perm_emitir_adesao` pré-impressa) e ainda não contempla novas áreas (`unidades`, `planos`, `contas_cobranca`, `reativacao`, `renegociacao`, escopo multi-unidade).
* **Ação no Schema:**
  * Incluir `created_by` e `updated_by` em `usuarios`;
  * **Papel / Perfil de Acesso (`role` / `perfil_usuario_enum`):** Prever enum identificando o tipo de usuário (**`ADMINISTRADOR`**, **`COLABORADOR`**, **`PARCEIRO`** [rede credenciada], **`ASSOCIADO`** [portal do cliente]) para isolar acessos internos vs. portais externos futuros;
  * **Substituir `empresa_id` por `unidade_id`** (`REFERENCES unidades(id)`), evitando redundância já que `unidades` pertence a `empresas` *(permitindo `NULL` para perfis externos como `PARCEIRO` e `ASSOCIADO`, e obrigatório para `COLABORADOR`)*;
  * **Escopo de Visibilidade por Unidade no RBAC:** Prever flag booleana de **visualização global** (vê todas as unidades) **e/ou** tabela associativa de **permissão regionalizada** (ex.: `usuario_unidades_acesso` listando quais unidades específicas aquele login pode visualizar, ex.: supervisor regional), mantendo como padrão apenas a própria `unidade_id`;
  * **Revisar integralmente a matriz de permissões (RBAC)** ao término da leitura de todas as tabelas e mapeamento das áreas do sistema.

---

## 2. Pendências Obrigatórias para o ETL de Migração (`Firebird -> PostgreSQL`)

1. **Auditoria e Saneamento de CPFs Duplicados em `CLIENTES`:**
   * Antes ou durante a carga de `CLIENTES -> clientes_pf`, executar query de detecção de CPFs duplicados (após normalização `SomenteNumeros`).
   * **Regra:** Como o PostgreSQL terá `UNIQUE (cpf)`, quaisquer registros legados com o mesmo CPF válido devem ser reportados ao operador para decisão (unificação de histórico, correção de digitação ou marcação de `cpf = NULL` + preservação em `cpf_legado_bruto` no cadastro secundário/antigo).
2. **CPFs Inválidos / Dígitos Repetidos:**
   * Migrar preservando o valor original em `cpf_legado_bruto` e gravando `cpf = NULL` quando inválido, evitando violação da constraint `UNIQUE (cpf)` (ex.: múltiplos `'00000000000'`).
3. **Mapeamento de `PARCELAS` Históricas:**
   * Verificar no banco Firebird atual se existem parcelas com `ANOMES` `'YY98'`, `'YY99'` e taxas `'0000'` para garantir que todas migrem com `origem_baixa = 'LEGADO'` e o status correto.
