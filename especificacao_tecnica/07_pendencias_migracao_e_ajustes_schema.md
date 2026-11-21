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
    * A unicidade rígida do banco passa a ser **`(num_carne, anomes)`** (garantindo que não haja repetição dentro do mesmo carnê);
    * Para evitar cobrança mensal duplicada sem bloquear acordos parcelados no mesmo mês (ex.: mensalidade `2610` + parcela `02/04` do acordo também em `2610`), a restrição de "apenas 1 parcela ativa por mês" aplica-se apenas a **carnês mensais regulares (`CARNE_PF` / `BOLETO_PJ`)**, permitindo a convivência com carnês de `RENEGOCIACAO`;
    * Taxas de adesão (`'0000'`) e reativações (`'REATIVACAO'`) nascem **`ABERTA`** dentro de seu próprio `num_carne` (`ADESAO` / `REATIVACAO`) e exigem liquidação (manual ou automática) como gatilho para efetivar o cliente e liberar a geração do carnê.

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
  2. **`Nº do Documento` ("Seu Número", Seg. `P` `63..77` / Retorno `T` `59..73`):** Suporta **15 caracteres** (usar **somente dígitos numéricos** por segurança e compatibilidade entre qualquer banco). Regra explícita: **`num_adesao + anomes(4) + tipo(1 dígito)`** (ex.: `1950026101`, cabendo até 10 dígitos de `num_adesao`), onde o dígito final identificador do tipo é:
     * `1` = Carnê Regular PF / Boleto Mensal PJ (`CARNE_PF`, `BOLETO_PJ`)
     * `2` = Taxa de Adesão Inicial (`ADESAO`)
     * `3` = Taxa de Reativação (`REATIVACAO`)
     * `4` = Renegociação / Acordo / Consolidação (`RENEGOCIACAO`, `DEBIT`)
  3. **`Uso Empresa Beneficiário` ("Identificação do Título na Empresa", Seg. `P` `196..220` / Retorno `T` `106..130`):** Suporta **25 caracteres**, devolvidos integralmente pelo Sicoob no retorno!
* **Diretriz:** Manter `Nosso Número` sequencial único por parcela (sempre único no banco); usar o campo **`Uso da Empresa` (25 posições)** para gravar a chave composta numérica completa (`PadLeftZero(num_carne, 8) + PadLeftZero(num_adesao, 8) + anomes(4)` = 20 dígitos), garantindo conciliação 100% inequívoca no retorno mesmo entre múltiplos carnês e entre mensalidade + acordo no mesmo mês.

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
  * **Responsável pela Unidade:** Adicionar **`responsavel_usuario_id BIGINT REFERENCES usuarios(id)`** (opcional) para vincular cada matriz/filial ao login do usuário responsável por ela.
  * **Preservação de IDs no Módulo 1:** Como o Módulo 1 (Rede Credenciada) entrará em produção antes da migração do legado (`ABAC.FDB`), as unidades já devem ser cadastradas preservando os mesmos IDs do antigo `CONVENIOS` (`0..19`, sendo `4 = JUIZ DE FORA`) para garantir encaixe sem conflitos no ETL futuro.
  * **Dividir nome em `razao_social` + `nome_fantasia` (e/ou `nome` da unidade):**
    * No ETL, `EMPRESAS.NOME_EMPRESA` migra para `razao_social` da unidade matriz (`eh_matriz = TRUE`).
    * Nos layouts posicionais e CNAB 240 (Header de `REMADESAO`, `REMESSA` e `CNAB 240`), utilizar **`razao_social`** da unidade matriz (nome oficial atrelado ao CNPJ do cedente).
    * Na interface web e relatórios PDF, utilizar `COALESCE(nome_fantasia, razao_social)`.
* **Nova Tabela `contas_cobranca` (Central de Contas Bancárias):**
  * Extrair os parâmetros bancários (`agencia`, `dv_agencia`, `conta`, `dv_conta`, `codigo_cedente`, `carteira`, `modalidade`, `percentual_multa`, `juros_mora_dia`, `codigo_banco`, `nsa_sequencial`, `padrao`, `ativo`, `created_by`, `updated_by`) para tabela própria vinculada à matriz.
  * Permite múltiplos bancos (Sicoob `756`, Caixa `104`, Banco do Brasil `001`, etc.) sem depender de colunas fixas por banco.
  * **Extinguir `banco_cobranca_enum`** e substituir as colunas `clientes_pf.banco_cobranca` e `lotes_arquivos.banco_cobranca` pela chave estrangeira **`conta_cobranca_id REFERENCES contas_cobranca(id)`**.
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
  * **Substituir `empresa_id` por `unidade_id`** (`REFERENCES unidades(id)`), evitando redundância já que `unidades` pertence a `empresas` *(permitindo `NULL` para perfis externos, e obrigatório para `COLABORADOR`)*;
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
  * Adicionar **`cpf`**, **`cpf_legado_bruto`**, **`estado_civil`** (Solteiro, Casado, Viúvo, Desquitado, Divorciado), **`sexo`** abrangente, **`telefone`** (opcional, avaliar flag WhatsApp), **`email`** (opcional), **`valor_adicional`**, **`created_by`** e **`updated_by`**;
  * Criar vínculo **`dependente_func_pj_beneficios_adicionais`** (mesma regra de obrigatoriedade condicional quando possuir benefício que exija, ex.: Seguro Funeral);
  * Criar índices de **`nome` (`gin_trgm_ops`)**, **`cpf` (`WHERE cpf IS NOT NULL`)** e **`telefone`** (além de `funcionario_pj_id`).

---

### 1.21 Refatoração da Tabela `carnes`
* **Auditoria:** Adicionar **`created_by BIGINT REFERENCES usuarios(id)`** (além de `created_at`).
* **Quantidade Real de Parcelas (`13`) e `tipo_carne`:**
  * No legado (`CARNE.NUM_PARC`), o sistema gravava `12` para carnês PF (apesar de gerar `13` registros em `PARCELAS`: `ÚNICA` + `01/12`..`12/12`) e usava `NUM_PARC = 12` para detectar renovações.
  * No sistema novo, gravar a quantidade **real** de parcelas geradas em `num_parcelas` (`13` para carnê PF, `1` para adesão/reativação/PJ, `M` para renegociação parcelada) e adicionar **`tipo_carne`** (`CARNE_PF`, `BOLETO_PJ`, `ADESAO`, `REATIVACAO`, `RENEGOCIACAO`) para distinguir claramente um carnê anual de um acordo parcelado (e na migração do legado, mapear `NUM_PARC = 12` para `tipo_carne = 'CARNE_PF'`).

---

### 1.22 Demais Ajustes da Tabela `parcelas` (Em Revisão)
* **Auditoria:** Adicionar **`created_by`** e **`updated_by`** (`REFERENCES usuarios(id)`), completando `created_at` e `updated_at`.
* **`id_parc`:** Ampliar de `VARCHAR(10)` para **`VARCHAR(15)`**. Para parcelas de renegociação parcelada, adotar o padrão **`'REN 01/04'`** (conversando diretamente com `tipo_carne = 'RENEGOCIACAO'`), além de `'01/12'..'12/12'`, `'ÚNICA'`, `'ADESÃO'`, `'REATIVACAO'`, `'01/01'` (PJ) e `'DEBIT'` (legado 1x).
* **Obrigatoriedade de `baixado_por_usuario_id`:** Avaliar na migração entre:
  1. Atribuir o ID do administrador (ou usuário técnico de migração) a todas as baixas legadas e criar trava no banco garantindo obrigatoriedade **quando paga** (`CHECK (data_pagamento IS NULL OR baixado_por_usuario_id IS NOT NULL)`) — lembrando que parcelas em aberto precisam aceitar `NULL`; **ou**
  2. Manter livre para o histórico legado e exigir obrigatoriedade apenas no backend para todas as novas baixas no sistema novo.

---

### 1.23 Refatoração da Tabela `fila_segunda_via` (Suporte a PJ e Cobrança Futura)
* **Padronização:** `empresa_id` $\to$ **`unidade_id`** e `usuario_id` $\to$ **`created_by`**.
* **Suporte a PJ:** Adicionar **`funcionario_pj_id`** (`REFERENCES funcionarios_pj(id)`) e **`dependente_func_pj_id`** (`REFERENCES dependentes_func_pj(id)`), ampliando `tipo_item` para incluir cartões de funcionários PJ e seus dependentes (`CARTAO_FUNC_PJ`, `CARTAO_DEP_PJ`).
* **Preparação para Cobrança Futura (ex.: Cartão PVC / com Chip):**
  * Adicionar **`cobranca_obrigatoria BOOLEAN NOT NULL DEFAULT FALSE`** (hoje gratuita) e **`parcela_id BIGINT REFERENCES parcelas(id)`** (opcional).
  * Quando cobrada no futuro, o pagamento (balcão em dinheiro, Pix, boleto CNAB 240, conferência de extrato) reaproveita integralmente a estrutura de `carnes` (`tipo_carne = 'SEGUNDA_VIA'`) + `parcelas` — sem duplicar tabelas financeiras — liberando a impressão somente após quitação da parcela vinculada.
* **Novos Índices:**
  * Índice parcial para itens pendentes: `(unidade_id, tipo_item, created_at) WHERE processado = FALSE`;
  * Histórico por contrato: `(num_adesao, created_at DESC)`;
  * Busca por lote gerado: `(lote_arquivo_id) WHERE lote_arquivo_id IS NOT NULL`.

---

### 1.24 Padronização da Tabela `auditoria_eventos`
* **Auditoria:** Padronizar **`usuario_id` $\to$ `created_by`** (e atualizar o índice `idx_auditoria_usuario` para usar `created_by`).

---

### 1.25 Módulo de Rede Credenciada / Parceiros e Clínicas Próprias (Módulo 1 — Primeira Entrega em Produção)
* **Objetivo Arquitetural:** Criar a estrutura completa e normalizada para gerenciar parceiros credenciados (de padarias a médicos/hospitais) **e também as Clínicas Próprias das Unidades da Associação**, servindo como **Módulo 1** a entrar em produção de forma independente sobre o banco oficial PostgreSQL.
* **Pré-Cadastros Padronizados (evitam duplicidade de digitação):**
  1. **`categorias_parceiros`**: Grupos principais (`id`, `nome`, `tipo` [`SAUDE`, `COMERCIO_SERVICOS`, `OUTRO`], `ordem`, `ativo`, auditoria `created_at`/`updated_at`/`created_by`/`updated_by`).
  2. **`subcategorias_parceiros`**: Especialidades médicas/odontológicas e ramos comerciais vinculados a `categorias_parceiros` (`id`, `categoria_id`, `nome`, `observacoes`, `ativo`, auditoria).
  3. **`catalogo_procedimentos`**: Pré-cadastro de procedimentos/serviços/itens (`id`, `subcategoria_id` opcional, `nome`, `duracao_padrao_min` opcional, `preparo_necessario` opcional — aproveitando campos já planejados em `ABBAC Cadastro 2026.xlsm` para futura Agenda Médica —, `ativo`, auditoria).
  4. **`profissionais`**: Cadastro único de profissionais de saúde/autônomos (`id`, `nome`, `cpf`, `conselho_tipo` [CRM/CRO/CRP/CREFITO/OAB/etc.], `conselho_numero`, `conselho_uf`, **dados particulares internos separados** [`endereco_pessoal`, `cep_pessoal`, `telefone_pessoal1`, `telefone_pessoal2`], `email`, `ativo`, auditoria) + tabela N:M **`profissional_subcategorias`** (especialidades do profissional).
* **Cadastro Principal, Locais, Vínculos, Contatos Internos e Documentos:**
  5. **`parceiros`**:
     * `id`, `tipo_parceiro` (`ESTABELECIMENTO_PJ`, `PROFISSIONAL_PF`, `UNIDADE_PROPRIA`), `unidade_propria_id` (opcional -> `unidades(id)`), `profissional_titular_id` (opcional -> `profissionais(id)`), `cpf_cnpj`, `razao_social`, `nome_fantasia`, `exige_autorizacao BOOLEAN NOT NULL DEFAULT FALSE`, `observacoes_atendimento` (público), `observacoes_internas` (privado);
     * **Trava Dupla CRM (Privacidade de Preços):** `bloqueio_divulgacao_valores BOOLEAN NOT NULL DEFAULT TRUE` (**somente `ADMINISTRADOR` pode alterar**) e `exibir_valores_guia_publico BOOLEAN NOT NULL DEFAULT FALSE` com constraint `CHECK (NOT exibir_valores_guia_publico OR NOT bloqueio_divulgacao_valores)` (garantindo que nunca vaze preço/desconto de médico ou item bloqueado no guia público);
     * **Controle de Vigência e Revisão Semestral:** `lgpd_aceito_em`, `dados_atualizados_em TIMESTAMPTZ`, `tabela_atualizada_em TIMESTAMPTZ` + **índices dedicados** em `dados_atualizados_em` e `tabela_atualizada_em` para alertas de conferência a cada 6 meses;
     * `ativo`, auditoria (`created_at`, `updated_at`, `created_by`, `updated_by`).
  6. **`parceiros_subcategorias`**: Vínculo N:M entre `parceiros` e `subcategorias_parceiros`.
  7. **`parceiros_locais`** (Locais Públicos de Atendimento — 1:N com `parceiros`):
     * `id`, `parceiro_id`, `nome_local`, `endereco`, `end_numero`, `complemento`, `bairro`, `cidade`, `estado`, `cep`;
     * **Contatos Públicos:** `telefone_publico1` (+ `telefone_publico1_whatsapp`), `telefone_publico2` (+ `telefone_publico2_whatsapp`), `email_publico`;
     * **Redes Sociais com Consentimento LGPD Individual (`LGPD.pdf`):** `instagram`, `permite_divulgar_instagram BOOLEAN NOT NULL DEFAULT FALSE`, `facebook`, `permite_divulgar_facebook BOOLEAN NOT NULL DEFAULT FALSE`, `whatsapp_divulgacao`, `permite_divulgar_whatsapp BOOLEAN NOT NULL DEFAULT FALSE`;
     * **Horário e Geolocalização Futura (Mapa por Proximidade):** `horario_funcionamento_texto`, `horario_funcionamento_json JSONB` (opcional, p/ futuro filtro "Aberto agora"), `latitude NUMERIC(10, 7)` (opcional, preenchida automaticamente via geocodificação/link), `longitude NUMERIC(10, 7)` (opcional), `google_maps_url` (opcional);
     * `ativo`, auditoria + índices em `(estado, cidade, bairro)` e `(latitude, longitude) WHERE latitude IS NOT NULL AND longitude IS NOT NULL`.
  8. **`parceiros_profissionais`**: Vínculo **opcional** N:M entre `parceiros`, `parceiros_locais` (opcional) e `profissionais`, permitindo que um estabelecimento adicione os profissionais que atendem lá (sem ser obrigatório) e que um mesmo profissional atenda em múltiplos estabelecimentos/unidades.
  9. **`parceiros_contatos`**: Tabela dedicada (mesma estrutura de `clientes_pj_contatos`) para múltiplos contatos **internos/particulares** do parceiro (secretária, gerente, financeiro) — **nunca** expostos no guia público.
  10. **`parceiros_documentos`**: Anexos no Storage em nuvem (`CONTRATO_CREDENCIAMENTO`, `TERMO_LGPD_ASSINADO`, `TABELA_PRECOS_PDF`, `LOGOMARCA`, `BANNER_PATROCINIO`, `OUTRO`) no mesmo padrão de `documentos_adesao`.
* **Tabelas de Preços/Descontos (4 Cenários + 4 Faixas das Unidades Próprias), Histórico e Destaques:**
  11. **`parceiros_precos_beneficios`**:
      * `id`, `parceiro_id`, `local_id` (opcional -> `parceiros_locais(id)`, permite preços diferentes por cidade/filial), `profissional_id` (opcional -> `profissionais(id)`, permite preços/descontos diferentes por médico dentro da mesma clínica), `subcategoria_id` (opcional), `procedimento_id` (opcional -> `catalogo_procedimentos(id)`);
      * `tipo_precificacao` (`VALOR_FIXO`, `PERCENTUAL_DESCONTO`, `SOB_CONSULTA`);
      * **Até 4 Faixas Monetárias (opcionais):** `valor_particular`, `valor_associado`, `valor_parceiro`, `valor_prefeitura` (`NUMERIC(12,2)`);
      * `percentual_desconto NUMERIC(5,2)`, `descricao_beneficio`, `regras_pagamento`, `observacoes`, `vigencia_inicio DATE`, `ativo`, auditoria.
  12. **`parceiros_precos_historico`**: Tabela dedicada para histórico de reajustes (`id`, `preco_beneficio_id`, `parceiro_id`, valores/percentuais anteriores e novos, `motivo`, `alterado_em`, `alterado_por_usuario_id`) — além do log técnico em `auditoria_eventos`.
  13. **`parceiros_planos_elegiveis`** *(preparado para o futuro)*: Vínculo opcional entre `parceiro_id`/`preco_beneficio_id` e `plano_id`/`beneficio_adicional_id`. Quando vazio, qualquer associado de qualquer unidade tem direito; quando preenchido no futuro, restringe benefícios exclusivos a determinados planos/adicionais.
  14. **`parceiros_destaques`**: `id`, `tipo_destaque` (`EDITORIAL_INTERNO`, `PATROCINADO`), `parceiro_id`, `profissional_id` (opcional), `preco_beneficio_id` (opcional), `subcategoria_id` (opcional), `escopo` (`GERAL`, `CIDADE`, `CATEGORIA`, `CIDADE_CATEGORIA`), `cidade` (opcional), `estado` (opcional), `nivel_patrocinio`, `texto_promocional`, `banner_storage_key`, `ordem`, `data_inicio`, `data_fim`, `ativo`, auditoria.

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
