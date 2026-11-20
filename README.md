# SGC Web — Modernização de Sistema Legado de Gestão de Planos e Cobrança Recorrente

> **Estudo de Caso de Engenharia de Software & Modernização de Legado (Legacy Modernization)**  
> Reengenharia completa de um sistema desktop financeiro e cadastral em produção desde 2008 (**Borland Delphi 7 + Firebird 2.5 + Rave Reports**, com mais de **1,03 milhão de parcelas** históricas) para uma arquitetura **Web Cloud-Native Moderna** com **PostgreSQL 16+**.

---

## Visão Geral do Projeto

O **SGC (Sistema de Gestão de Carnês e Planos Assistenciais)** gerencia todo o ciclo de vida comercial, cadastral e financeiro de planos assistenciais recorrentes para **Pessoas Físicas (Titulares e Dependentes)** e **Pessoas Jurídicas (Contratos Corporativos, Funcionários e Dependentes)**.

### O Desafio Real
O sistema original operava exclusivamente offline na matriz, exigindo a pré-geração física de lotes de números de adesão para as filiais, exportação local de arquivos posicionais para gráfica e conciliação bancária desktop. Após mais de 15 anos de operação contínua, o banco de dados acumulou:
- **+1.030.000** parcelas financeiras (`PARCELAS`);
- **+111.000** carnês e faturas emitidos (`CARNE`);
- **+71.000** vidas cadastradas entre titulares PF, dependentes e funcionários corporativos PJ.

### A Solução e Modernização Arquitetural
1. **De Offline (Papel/Matriz) para 100% Online Multiunidade:** Eliminação do fluxo manual de pré-geração de lotes de fichas em branco (`ADESAO`), permitindo cadastro direto em tempo real pelas filiais (e autosserviço web futuro) com numeração sequencial atômica gerenciada pelo PostgreSQL.
2. **Saneamento e Evolução do Modelo de Dados (`Firebird 2.5 -> PostgreSQL 16+`):**
   - Higienização de mais de 10 mil registros de fichas em branco não utilizadas no legado;
   - Tipagem forte com `ENUMs` de domínio, precisão monetária estrita (`NUMERIC(12,2)`), coluna calculada automática de receita líquida (`valor_liquido = valor_pago - valor_compensacao`) e índices parciais otimizados para consultas abaixo de `300 ms` sobre mais de 1 milhão de títulos;
   - Rastreabilidade completa de arquivos gerados/importados (`lotes_arquivos` com validação `SHA-256` contra reprocessamento duplicado) e trilha de auditoria (`auditoria_eventos`).
3. **Motor Financeiro e Integração Bancária FEBRABAN CNAB 240:**
   - Geração de carnês anuais PF com **12 parcelas mensais + 13ª cota anual (`ÚNICA`) com 20% de desconto** e baixa automática em cascata;
   - Faturamento mensal corporativo PJ baseado na folha ativa;
   - Cobrança registrada **CNAB 240 Sicoob (`756`)** (cálculo de dígito verificador Módulo 11 com peso cíclico `3197`) e conciliação multicanal (**Sicoob `756`**, **Caixa Econômica Federal `104`** e importação de planilhas);
   - Correção de **10 bugs históricos** identificados na engenharia reversa do binário legado.

---

## Nota de Privacidade e Conformidade (LGPD)

Este repositório foi estruturado seguindo práticas rigorosas de **Privacy by Design**:
- **Nenhum dado pessoal (PII)** de clientes, CPFs, endereços, senhas ou arquivos de banco de dados reais (`*.FDB`, `*.GBK`, remessas `.TXT`/`.RET` ou planilhas) é versionado neste repositório (protegido via [`.gitignore`](.gitignore)).
- Todos os esquemas SQL e documentos técnicos contêm exclusivamente a **estrutura de metadados (DDL)**, regras matemáticas e especificações funcionais.

---

## Estrutura da Documentação Técnica

Todo o levantamento de engenharia reversa e a especificação da nova plataforma estão documentados em detalhes:

- **[Documento Mestre de Requisitos e Especificação (`DOCUMENTO_REQUISITOS_E_ESPECIFICACAO_SGC.md`)](DOCUMENTO_REQUISITOS_E_ESPECIFICACAO_SGC.md)**  
  *Sumário executivo, glossário do domínio de negócio, diagramas de arquitetura e fluxo financeiro, catálogo de 32 Requisitos Funcionais (`RF-001` a `RF-032`) e 15 Requisitos Não Funcionais (`RNF-001` a `RNF-015`).*

### Volumes Especializados (`especificacao_tecnica/`)
1. **[`01_schema_firebird_legado.sql`](especificacao_tecnica/01_schema_firebird_legado.sql)**  
   *Estrutura original extraída do banco Firebird 2.5 (`ABAC.FDB`), com análise de volumetria, relacionamentos e particularidades de codificação (`Windows-1252`).*
2. **[`02_schema_postgresql_moderno.sql`](especificacao_tecnica/02_schema_postgresql_moderno.sql)**  
   *Novo esquema relacional moderno para PostgreSQL 16+, remodelado para operação online sem lotes prévios de adesão, com auditoria, controle de lotes de arquivos e índices de alta performance.*
3. **[`03_catalogo_telas_e_fluxos_ui.md`](especificacao_tecnica/03_catalogo_telas_e_fluxos_ui.md)**  
   *Mapeamento das 33 telas do sistema legado, matriz de controle de acesso (18 permissões RBAC) e desenho das novas telas Web.*
4. **[`04_regras_negocio_financeiro_cnab_arquivos.md`](especificacao_tecnica/04_regras_negocio_financeiro_cnab_arquivos.md)**  
   *Fórmulas financeiras exatas, regras de cascata da parcela única, consolidação de inadimplência (`DEBIT`), catálogo de bugs corrigidos e layouts posicionais de arquivos (CNAB 240 e gráfica).*
5. **[`05_especificacao_relatorios_rave.md`](especificacao_tecnica/05_especificacao_relatorios_rave.md)**  
   *Especificação completa das consultas SQL, agrupamentos e fórmulas dos relatórios gerenciais e financeiros.*
6. **[`06_guia_execucao_ia_agentica.md`](especificacao_tecnica/06_guia_execucao_ia_agentica.md)**  
   *Guia arquitetural de implementação da aplicação Web, endpoints da API REST, estratégia de migração de dados (ETL) e plano de testes.*
