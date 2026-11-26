# 06 — Guia de Execução e Blueprint Arquitetural para IA Agêntica (Python ou Java + Web + PostgreSQL Online)

> **Propósito deste Documento:** Este guia foi projetado especificamente para ser fornecido como **instrução mestra de engenharia (`System / Project Prompt`)** a uma **IA Agêntica de Codificação** encarregada de construir do zero a nova plataforma web do **SGC (Sistema de Gestão de Carnês e Planos Assistenciais)**, substituindo 100% do legado `SGCeFeGe.exe` + `ABAC.FDB` + `Relatorios.rav`.

---

## 1. Regras Inegociáveis para o Agente Construtor (Invariantes do Domínio)

Qualquer agente de IA que implemente este sistema **DEVE** obedecer rigorosamente às 12 regras abaixo:

1. **Aritmética Monetária Exata:** Jamais usar `float` ou `double` binário IEEE-754 para valores monetários, percentuais de comissão ou tarifas. Usar exclusivamente `Decimal` (`Python decimal.Decimal` com `ROUND_HALF_UP`) ou `BigDecimal` (`Java math.BigDecimal` com `RoundingMode.HALF_UP`) e `NUMERIC(12,2)` no PostgreSQL.
2. **Unicidade Global do Número de Adesão (`adesoes.numero`):** O número de adesão é compartilhado entre **Clientes PF (`clientes_pf`)** e **Empresas Clientes PJ (`clientes_pj`)** através da supertabela `adesoes` alimentada por `seq_adesao_numero` (sincronizada após migração com `MAX(NUMERO) + 1`).
3. **Fórmula Exata da Cota Anual `'ÚNICA'`:** Ao gerar um carnê de 12 parcelas com mensalidade base $M = V_{\text{titular}} + (N_{\text{dep}} \times V_{\text{dep}})$ e acréscimo de renovação $A$ ($A = 0$ no 1º carnê; $A = V_{\text{acrescimo}}$ na renovação), gerar **13 parcelas**:
   - `'01/12'` = $M + A$;
   - `'02/12'`..`'12/12'` = $M$;
   - `'ÚNICA'` (`ANOMES = AA + '99'`, mesmo `DTVENC` da `'01/12'`) = $\text{ROUND}(12 \times M \times 0,80 + A,\; 2)$.
4. **Cascata Atômica da `'ÚNICA'`:** A liquidação de qualquer parcela `ID_PARC = 'ÚNICA'` (seja por baixa manual, retorno CNAB 240 ou planilha) deve, **na mesma transação de banco de dados**, quitar todas as parcelas mensais em aberto do mesmo `carne_id` com `dt_pagamento = mesma_data`, `valor_pago = 0.00`, `valor_compensacao = 0.00` e `situacao_parcela = 'QUITADA_POR_UNICA'`. O estorno deve reverter a cascata atomicamente.
5. **Exclusão da `'ÚNICA'` em Inadimplência e Previsão de Recebíveis:** Parcelas com `id_parcela = 'ÚNICA'` jamais podem ser contabilizadas como vencidas/inadimplentes nem somadas em *Contas a Receber*.
6. **Consolidação `'DEBIT'` Sem Inflar Caixa:** Ao consolidar parcelas atrasadas em uma parcela única `'DEBIT'` (`ANOMES = AA + '00'`), as parcelas originais são marcadas como `CONSOLIDADA` com `valor_pago = 0.00` (para saírem da inadimplência sem somar falsamente em *Contas Recebidas*).
7. **Precisão Posicional dos Arquivos Legados e CNAB 240:**
   - `REMADESAO`: exatamente **250 bytes/linha** + `\r\n` (`Windows-1252`).
   - `REMESSA` (PF/PJ) e `SEG_VIA_*`: exatamente **350 bytes/linha** + `\r\n` (`Windows-1252`).
   - CNAB 240 Sicoob (`756`): exatamente **240 bytes/linha** + `\r\n`, com DV do Nosso Número calculado por **Módulo 11 peso cíclico `3197`** sobre os **21 dígitos** `AG(4) + CODCED(10) + NOSSONUMERO(7)`.
8. **Correção dos Bugs Críticos do Legado:**
   - Não truncar `NUM_ADESAO` em 4 dígitos no retorno Caixa `104`;
   - Filtrar `SITUACAO = 'A'` dos funcionários no faturamento mensal PJ;
   - Rejeitar CPFs/CNPJs com dígitos repetidos (`111.111.111-11`) em novos cadastros e na remessa CNAB 240;
   - Aplicar autorização RBAC no servidor em **100% das rotas** (corrigindo os 7 menus desprotegidos do legado).
9. **Idempotência de Lotes e Retornos Bancários:** O reenvio do mesmo arquivo `.ret` CNAB 240 ou planilha Excel não pode duplicar baixas nem sobrescrever baixas já conciliadas sem flag explícita; registrar hash SHA-256 de cada arquivo processado em `lotes_arquivos`.
10. **Zero Uso dos Ícones `.bmp` Legados:** Não importar `atualizar.bmp`, `Cancelar.bmp`, `Consultar.bmp`, `Excluir.bmp`, `Fechar.bmp`, `fg.bmp` ou `novo.bmp`. Utilizar biblioteca moderna de ícones SVG (`lucide-react`).
11. **Segurança no Upload e Armazenamento de Documentos (Zero Execução no Servidor):** Todo documento ou anexo enviado ao sistema (`documentos_adesao`, `parceiros_documentos`, logomarcas e banners) deve passar por validação rigorosa de assinatura binária (*magic bytes*) confirmando que o cabeçalho real do arquivo condiz com a extensão permitida em lista fechada (PDF, JPG, PNG), com limite de tamanho e geração de `sha256_hash`. **Nenhum arquivo anexado é lido, interpretado ou executado pelo servidor**: ele é apenas armazenado com chave aleatória (UUID) em Storage externo isolado (S3/R2/Supabase) e servido com cabeçalhos seguros (`X-Content-Type-Options: nosniff` e `Content-Disposition`).
12. **Precificação de Parceiros Sem Empates e Fluxo em Funil (`parceiros_precos_beneficios`):** O cadastro de preços/descontos da Rede Credenciada e Clínicas Próprias deve seguir obrigatoriamente a **Escada Anti-Empate de 3 Degraus** (`CHECK (profissional_id IS NULL OR local_id IS NOT NULL)` — Degrau 3 Profissional na Filial $\to$ Degrau 2 Padrão da Filial $\to$ Degrau 1 Padrão da Rede), exigir ao menos `procedimento_id`, `subcategoria_id` ou `descricao_beneficio`, bloquear duplicidades ativas (`UNIQUE NULLS NOT DISTINCT ... WHERE ativo = TRUE`), reutilizar procedimentos genéricos (`CONSULTA` com `subcategoria_id = NULL` em `catalogo_procedimentos`) sem duplicar nomes por especialidade, e apresentar o **Fluxo em Funil de 6 Passos** em cascata na UI e validações espelhadas no backend.

---

## 2. Stacks Tecnológicas Recomendadas (Python OU Java 21)

A arquitetura é desacoplada em **Frontend SPA/SSR + API REST Stateless + Worker Assíncrono (opcional para lotes grandes) + PostgreSQL 16+ Online**. Escolha **uma** das duas stacks de backend abaixo conforme preferência da equipe:

### Opção A — Stack Python Moderna (Alta Produtividade e Excelente para ETL/Relatórios)
- **Runtime:** Python `3.12+` gerenciado com `uv` ou `Poetry`.
- **Framework Web:** `FastAPI` + `Uvicorn` / `Gunicorn` (tipagem estrita e OpenAPI 3.1 automático).
- **ORM e Migrações:** `SQLAlchemy 2.0` (Mapped classes tipadas) + `psycopg[binary]` v3 + `Alembic` (aplicando `02_schema_postgresql_moderno.sql`).
- **Validação e Serialização:** `Pydantic v2` (`condecimal(max_digits=12, decimal_places=2)`).
- **Segurança:** `argon2-cffi` (hash de senhas) + `PyJWT` (JWT Access Token 15 min + Refresh Token 7 dias em cookie `HttpOnly; Secure; SameSite=Lax`).
- **Planilhas e Relatórios PDF:** `openpyxl` (`.xlsx`) + `xlrd` (suporte a `.xls` BIFF8 legado) + `WeasyPrint` (templates HTML/CSS paginados `@page { size: A4 }` fiéis aos 7 relatórios do `Relatorios.rav`) ou `ReportLab`.
- **Testes:** `pytest` + `pytest-cov` + `httpx` + `testcontainers-python` (PostgreSQL 16 real).

### Opção B — Stack Java Corporativa Moderna (Java 21 LTS)
- **Runtime:** Java `21 LTS` (Virtual Threads habilitadas: `spring.threads.virtual.enabled=true`).
- **Framework Web:** `Spring Boot 3.4+` (`spring-boot-starter-web`, `spring-boot-starter-validation`).
- **Persistência e Migrações:** `Spring Data JPA` (Hibernate 6) + `JdbcClient` / `jOOQ` para queries analíticas dos relatórios + `Flyway` (`V1__init_schema.sql` = `02_schema_postgresql_moderno.sql`).
- **Segurança:** `Spring Security 6` + `OAuth2 Resource Server (JWT)` + `Argon2PasswordEncoder` (BouncyCastle).
- **Planilhas e Relatórios PDF:** `Apache POI` (`HSSF` para `.xls` e `XSSF` para `.xlsx`) + `OpenHTMLToPDF` / `JasperReports` / `OpenPDF`.
- **Testes:** `JUnit 5` + `AssertJ` + `MockMvc` + `Testcontainers (PostgreSQLContainer)`.

### Frontend Web e Banco Online (Comum a Ambas as Opções)
- **Frontend:** `Next.js 15` (ou `Vite + React 19`) + `TypeScript 5.x` + `Tailwind CSS` + `shadcn/ui` + `TanStack Query v5` + `TanStack Table v8` + `React Hook Form` + `Zod` + `lucide-react`.
- **Banco de Dados Online:** **PostgreSQL 16+** gerenciado em nuvem (ex.: **Supabase**, **Neon**, **Google Cloud SQL**, **AWS RDS** ou **Railway**) com SSL obrigatório (`sslmode=require`), backups diários PITR e encoding `UTF-8`.
- **Armazenamento de Arquivos (`REMESSA`, `CNAB`, `RET`, `LOGOMARCA`):** Bucket compatível com S3 (Cloudflare R2, AWS S3, Supabase Storage ou GCS) referenciado pela tabela `lotes_arquivos`.

---

## 3. Estrutura de Diretórios Recomendada (Monorepo)

```text
sgc-web/
├── docs/                                  # Cópia do pacote especificacao_tecnica/ (01..06 + Master)
├── database/
│   ├── migrations/                        # DDL incremental a partir de 02_schema_postgresql_moderno.sql
│   └── etl_firebird_to_postgres/          # Scripts idempotentes de migração ABAC.FDB -> PostgreSQL
│       ├── migrate.py                     # Extrator Firebird (fdb/firebird-driver) -> PostgreSQL
│       └── verify_reconciliation.sql      # Queries de batimento contábil pós-carga
├── backend/                               # (FastAPI em Python OU Spring Boot em Java 21)
│   ├── src/
│   │   ├── auth/                          # Login JWT, Refresh, Argon2id, Guardas RBAC (18 flags)
│   │   ├── empresas/                      # Multiempresa, parâmetros Sicoob, agendador DATA_ARQ
│   │   ├── usuarios/                      # CRUD operadores e perfis de permissão
│   │   ├── comissionados/                 # CRUD cadastrantes/vendedores e cálculo de comissão
│   │   ├── clientes_pf/                   # Titular PF, Dependentes, Validação Adesão e CPF
│   │   ├── clientes_pj/                   # Empresa PJ, Funcionários Titulares e Dependentes PJ
│   │   ├── financeiro/
│   │   │   ├── adesoes_service            # Lotes de fichas (ANOMES='0000') + REMADESAO (250B)
│   │   │   ├── carnes_pf_service          # Motor 12 parcelas + ÚNICA (80%) + REMESSA (350B)
│   │   │   ├── faturamento_pj_service     # Folha ativa PJ mensal + REMESSA PJ (350B)
│   │   │   ├── consolidacao_debit_service # Agrupamento de atrasados em parcela DEBIT
│   │   │   ├── baixas_service             # Manual, cascata ÚNICA, estorno auditado
│   │   │   ├── cnab240_sicoob_writer      # Gerador 240B (Mov '01' P/Q/R e Mov '02' P + DV 3197)
│   │   │   ├── retorno_bancario_parser    # Parser Sicoob 756 (T/U), Caixa 104 (T/U e G) e Excel
│   │   │   └── segunda_via_service        # Fila persistente SEG_VIA_CARNE / SEG_VIA_CARTAO + PDF
│   │   ├── diagnostico/                   # Motor de diagnóstico de adesão/cliente/carnê
│   │   ├── relatorios/                    # 7 relatórios HTML + PDF A4 + XLSX/CSV
│   │   └── auditoria/                     # Interceptor/Middleware gravando auditoria_eventos
│   └── tests/                             # Testes unitários de fórmulas/layouts e integração API
├── frontend/
│   ├── src/app/                           # Rotas mapeadas na Seção 6 de 03_catalogo_telas_e_fluxos_ui.md
│   ├── src/components/                    # Formulários mascarados, DataTables, Preview de Lotes
│   └── src/lib/                           # Cliente HTTP tipado, validadores CPF/CNPJ, máscaras BR
└── docker-compose.yml                     # PostgreSQL 16 local + Backend + Frontend para dev/CI
```

---

## 4. Catálogo Completo de Endpoints REST (`API v1`)

Todos os endpoints (exceto `/api/v1/auth/login` e `/api/v1/health`) exigem cabeçalho `Authorization: Bearer <jwt>` e cabeçalho `X-Empresa-Id: <uuid>` (ou `empresa_id` embutido no token).

### 4.1 Autenticação e Sessão
- `POST /api/v1/auth/login` — Valida `apelido` + `senha`, retorna `access_token`, perfil e mapa das 18 permissões RBAC. Se `trocar_senha_proximo_login = true`, exige chamada imediata a `change-password`.
- `POST /api/v1/auth/refresh` — Renova token via cookie `HttpOnly`.
- `POST /api/v1/auth/logout` — Revoga sessão e registra logout em `auditoria_eventos`.
- `POST /api/v1/auth/change-password` — Altera a própria senha (`TFrmAlterarSenha`).
- `GET /api/v1/dashboard/resumo` — KPIs da empresa ativa, `dt_proximo_arquivo` (`DATA_ARQ`), alerta se `CURRENT_DATE >= dt_proximo_arquivo`, inadimplência e recebimentos do mês.

### 4.2 Cadastros Base
- `GET /api/v1/empresas` | `POST /api/v1/empresas` | `GET /api/v1/empresas/{id}` | `PUT /api/v1/empresas/{id}` | `PUT /api/v1/empresas/{id}/logomarca` | `PATCH /api/v1/empresas/{id}/data-arquivo`
- `GET /api/v1/usuarios` | `POST /api/v1/usuarios` | `PUT /api/v1/usuarios/{id}` | `PATCH /api/v1/usuarios/{id}/permissoes` | `POST /api/v1/usuarios/{id}/reset-senha`
- `GET /api/v1/comissionados` | `POST /api/v1/comissionados` | `GET /api/v1/comissionados/{id}` | `PUT /api/v1/comissionados/{id}` | `DELETE /api/v1/comissionados/{id}` (soft-delete se houver clientes)
- `GET /api/v1/clientes-pf` (filtros: `q`, `campo`, `situacao`, `convenio_id`, `banco_cobranca`, paginação)
- `POST /api/v1/clientes-pf` (valida `numero_adesao` existente e livre em `adesoes`, ou reserva novo se `gerar_adesao_automatica=true`)
- `GET /api/v1/clientes-pf/{numero}` (retorna titular + dependentes + resumo de carnês)
- `PUT /api/v1/clientes-pf/{numero}`
- `POST /api/v1/clientes-pf/{numero}/dependentes` | `PUT /api/v1/dependentes-pf/{id}` | `DELETE /api/v1/dependentes-pf/{id}`
- `GET /api/v1/clientes-pj` | `POST /api/v1/clientes-pj` (aloca `seq_adesao_numero` + cria `adesoes` automaticamente) | `GET /api/v1/clientes-pj/{numero}` | `PUT /api/v1/clientes-pj/{numero}`
- `POST /api/v1/clientes-pj/{numero}/funcionarios` | `PUT /api/v1/funcionarios-pj/{id}` | `DELETE /api/v1/funcionarios-pj/{id}`
- `POST /api/v1/funcionarios-pj/{id}/dependentes` | `DELETE /api/v1/dependentes-pj/{id}`

### 4.3 Operações Financeiras, Remessas, Baixas e Atendimento
- `POST /api/v1/adesoes/lote` (`{ quantidade, banco }`) -> Gera fichas + `ANOMES='0000'` + arquivo `REMADESAO{rem:05d}.TXT`.
- `GET /api/v1/adesoes/disponiveis` -> Lista fichas pré-geradas ainda não utilizadas e exporta arquivo `REMADESAO` (`TFrmRecuperarArquivo` opção 2).
- `POST /api/v1/carnes-pf/simular` (`{ valor_titular, valor_dependente, valor_acrescimo_renovacao, max_parcelas_aberto }`) -> Retorna lista de clientes elegíveis, flag `eh_renovacao`, divergências de `valor_plano` e totais.
- `POST /api/v1/carnes-pf/gerar-lote` -> Efetiva os carnês de 13 parcelas (`12` + `'ÚNICA'`), avança `DATA_ARQ` e gera `REMESSA{rem:07d}_{banco}.TXT`.
- `POST /api/v1/faturamento-pj/simular` & `POST /api/v1/faturamento-pj/gerar-lote` (`{ competencia_mes_ano }`) -> Gera faturas PJ somando funcionários `SITUACAO = 'A'` + `REMESSA{rem:07d}.TXT`.
- `GET /api/v1/inadimplencia/candidatos-consolidacao` (`?max_parcelas_aberto=3`) -> Lista clientes inadimplentes elegíveis (`TfrmGerarRemessa` Aba 1).
- `POST /api/v1/inadimplencia/consolidar-debit` (`{ numeros_adesao[], dt_novo_vencimento }`) -> Consolida atrasados em parcela `'DEBIT'`.
- `GET /api/v1/cobranca/boletos-elegiveis` -> Filtra títulos para remessa (`dInicio`, `dFim`, `dtpAdimplencia`, `registrado`, `apenas_cpf_valido`).
- `POST /api/v1/cobranca/cnab240/remessa-registro` (`{ parcela_ids[] }`) -> Gera CNAB 240 Sicoob Mov `'01'` (`P+Q+R`) e marca `registrado = true`.
- `POST /api/v1/cobranca/remessa-grafica-avulsa` (`{ parcela_ids[] }`) -> Gera arquivo gráfico de 350 colunas para parcelas avulsas.
- `GET /api/v1/cobranca/candidatos-baixa-bancaria` & `POST /api/v1/cobranca/cnab240/remessa-baixa` (`{ parcela_ids[] }`) -> Gera CNAB 240 Sicoob Mov `'02'` (`P`).
- `POST /api/v1/parcelas/backfill-nosso-numero` -> Equivalente seguro a `GerarNossoNumero1`.
- `GET /api/v1/lotes-arquivos` & `GET /api/v1/lotes-arquivos/{id}/download` & `POST /api/v1/lotes-arquivos/recuperar` -> Download e regeneração fiel (`TFrmRecuperarArquivo`).
- `GET /api/v1/parcelas/busca` (`?chave=...` aceita `NUM_ADESAO+ANOMES` ou `NOSSONUMERO`).
- `POST /api/v1/parcelas/{id}/baixa-manual` (`{ dt_pagamento, valor_pago, observacao }`) -> Aplica cascata se `'ÚNICA'`.
- `POST /api/v1/parcelas/{id}/estornar-baixa` (`{ motivo }`) -> Reverte liquidação (e cascata `'ÚNICA'`) com auditoria obrigatória.
- `POST /api/v1/baixas-automaticas/preview` (multipart upload de N arquivos `.ret` Caixa/Sicoob ou `.xls`/`.xlsx`/`.csv`) -> Retorna prévia detalhada sem alterar banco.
- `POST /api/v1/baixas-automaticas/confirmar` -> Efetiva lote conciliado de forma idempotente.
- `POST /api/v1/clientes-pf/{numero}/cancelar-plano` (`{ motivo }`) -> Valida `perm_cancelar_plano`, lista parcelas em aberto e define `situacao = 'C'`.
- `GET /api/v1/segunda-via/fila` | `POST /api/v1/segunda-via/fila` | `DELETE /api/v1/segunda-via/fila/{id}` | `POST /api/v1/segunda-via/exportar` (`CARNE` ou `CARTAO`) | `GET /api/v1/carnes/{id}/pdf`
- `GET /api/v1/diagnostico/{numero_adesao}` -> Retorna JSON estruturado + texto idêntico ao `TFrmDiagnostico`.

### 4.4 Relatórios (`JSON` + `PDF` + `XLSX` + `CSV`)
- `GET /api/v1/relatorios/contas-recebidas?data_ini=...&data_fim=...&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/contas-a-receber?data_ini=...&data_fim=...&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/clientes-inadimplentes?ate_data=...&campo=...&texto=...&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/clientes-adimplentes?ate_data=...&apenas_carne_quitado=bool&campo=...&texto=...&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/clientes-geral?modo=GERAL|ANIVERSARIANTES|ADESAO_PENDENTE&mes=1..12&inativos=bool&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/comissoes?data_ini=...&data_fim=...&convenio_id=...&formato=json|pdf|xlsx|csv`
- `GET /api/v1/relatorios/faturamento-pj?data_ini=...&data_fim=...&numero_pj=...&status=...&formato=json|pdf|xlsx|csv`

---

## 5. Playbook de Migração de Dados (`ABAC.FDB` Firebird 2.5 -> PostgreSQL 16+)

O banco real `ABAC.FDB` fornecido na pasta do projeto utiliza `ODS 11.2` (Firebird 2.5) e charset `NONE` com strings gravadas em **`Windows-1252` (`cp1252`)**. O script de ETL (`migrate.py`) deve executar os passos abaixo em transação controlada:

1. **Leitura Segura do Firebird:** Conectar em modo *read-only* no `ABAC.FDB` com `charset='WIN1252'` (decodificando qualquer byte inválido residual com `errors='replace'`, removendo caracteres NUL `\x00` e aplicando `.strip()` em colunas `CHAR` com padding de espaços, como `APELIDO` e flags `'SIM'`/`'NÃO'`).
2. **Ordem Estrita de Carga (Respeitando FKs de `02_schema_postgresql_moderno.sql`):**
   1. `EMPRESAS` -> `empresas` (converter `LOGOMARCA` `.bmp` em `PNG` otimizado mantendo cópia ou bytes originais).
   2. `USUARIOS` -> `usuarios`:
      - Decifrar `SENHA` aplicando `[b ^ 0xC5 for b in raw_bytes].decode('cp1252')`, gerar hash **Argon2id** da senha decifrada (permitindo transição transparente para os operadores atuais!) **e** definir `trocar_senha_proximo_login = TRUE` para forçar atualização para senha forte no primeiro acesso web.
      - Converter `'SIM'` -> `TRUE` e qualquer outro valor -> `FALSE` nas permissões. Para administradores (`USUARIOS_DADOS = 'SIM'` e `EMPRESAS_DADOS = 'SIM'`), habilitar também as novas flags `perm_pj_consultar`, `perm_pj_editar`, `perm_gerar_remessa_cnab` e `perm_auditoria_consultar`.
   3. `CONVENIOS` -> `convenios` (preservar `COD_CONVENIO` explícito no `id`).
   4. `ADESAO` -> `adesoes`:
      - Carregar todos os `ADESAO.NUMERO`.
      - **Saneamento Preventivo:** Caso exista algum registro histórico em `CLIENTES`, `PESSOAJURIDICA`, `CARNE` ou `PARCELAS` cujo `NUMERO`/`NUM_ADESAO` não esteja em `ADESAO`, inserir automaticamente o número faltante em `adesoes` com `origem_tipo = 'MIGRACAO_SANEADA'` antes de carregar as tabelas filhas.
   5. `CLIENTES` -> `clientes_pf` (mapear `BANCO` `'1'`/`'2'`, normalizar `CPF` apenas dígitos + coluna formatada se desejado, sinalizar `cpf_valido` via `ValidarCpfCnpj` estrito sem descartar nenhum registro!).
   6. `DEPENDENTES` -> `dependentes_pf` (preservar `CODIGO`).
   7. `PESSOAJURIDICA` -> `clientes_pj` (preservar `NUMERO`).
   8. `FUNCIONARIOSPESSOAJURIDICA` -> `funcionarios_pj` (preservar `CODIGOFUNC`).
   9. `DEPFUNCPESSOAJURIDICA` -> `dependentes_func_pj` (preservar `CODIGODEPFUNC`).
   10. `CARNE` -> `carnes` (preservar `NUMERO`, classificar `tipo_carne`: se `NUM_PARC = 1` e houver parcela `'0000'` -> `'ADESAO'`; se pertencer a PJ -> `'FATURA_PJ'`; se parcela `'DEBIT'` -> `'CONSOLIDACAO_DEBIT'`; senão `'CARNE_PF_12M'`).
   11. `PARCELAS` -> `parcelas`:
       - Preservar `NOSSONUMERO` original;
       - Classificar `situacao_parcela`:
         - Se `DTPAG IS NULL`: `'ABERTA'`;
         - Se `DTPAG IS NOT NULL` e `VALOR_PAGO > 0`: `'PAGA'`;
         - Se `DTPAG IS NOT NULL` e `COALESCE(VALOR_PAGO, 0) = 0`: se no mesmo `NUM_CARNE` houver `'ÚNICA'` paga -> `'QUITADA_POR_UNICA'`, senão -> `'CONSOLIDADA'`.
3. **Sincronização das Sequences no PostgreSQL:**
   ```sql
   SELECT setval('seq_convenios_id', COALESCE((SELECT MAX(id) FROM convenios), 1), true);
   SELECT setval('seq_adesao_numero', COALESCE((SELECT MAX(numero) FROM adesoes), 1), true);
   SELECT setval('seq_dependentes_pf_id', COALESCE((SELECT MAX(id) FROM dependentes_pf), 1), true);
   SELECT setval('seq_funcionarios_pj_id', COALESCE((SELECT MAX(id) FROM funcionarios_pj), 1), true);
   SELECT setval('seq_dep_func_pj_id', COALESCE((SELECT MAX(id) FROM dependentes_func_pj), 1), true);
   SELECT setval('seq_carne_numero', COALESCE((SELECT MAX(numero_carne) FROM carnes), 1), true);
   SELECT setval('seq_nosso_numero', COALESCE((SELECT MAX(nosso_numero) FROM parcelas), 1), true);
   ```
4. **Conferência Contábil Obrigatória Pós-Migração (`Gate Check`):**
   - Contagem de linhas idêntica nas 11 tabelas ativas (`EMPRESAS`, `USUARIOS`, `CONVENIOS`, `ADESAO`, `CLIENTES`, `DEPENDENTES`, `PESSOAJURIDICA`, `FUNCIONARIOSPESSOAJURIDICA`, `DEPFUNCPESSOAJURIDICA`, `CARNE`, `PARCELAS`).
   - Diferença **zero (`R\$ 0,00`)** nas somas globais de `PARCELAS`: `SUM(VALOR)`, `SUM(VALOR_PAGO)` e `SUM(VALOR_COMP)`.

---

## 6. Roteiro de Implementação em 8 Marcos Determinísticos (Milestones para a IA)

Para construir o sistema sem alucinações nem regressões, a IA agêntica deve executar na ordem:

- **Marco 1 — Banco de Dados e Migração:** Subir PostgreSQL 16, aplicar `02_schema_postgresql_moderno.sql`, implementar e rodar o script de ETL sobre `ABAC.FDB` (em ambiente local seguro) e validar 100% dos totalizadores contábeis.
- **Marco 2 — Autenticação, Segurança, RBAC e Auditoria:** Implementar login JWT, Argon2id, middleware das 18 permissões RBAC, interceptor de `auditoria_eventos` e CRUD de Empresas e Usuários.
- **Marco 3 — Cadastros Comerciais (Comissionados, Clientes PF e Carteira PJ):** Implementar APIs e telas de Comissionados, Clientes PF + Dependentes (com validação de ficha de adesão e CPF/CNPJ estrito) e Clientes PJ + Funcionários + Dependentes.
- **Marco 4 — Motores de Emissão e Layouts Gráficos (250B e 350B):** Implementar geração de Adesões (`REMADESAO` 250B), Carnês PF de 13 parcelas (`REMESSA` 350B), Faturamento Mensal PJ corrigido (`REMESSA` 350B), Fila de 2ª Via (`SEG_VIA_CARNE` e `SEG_VIA_CARTÃO` 350B) e Recuperação de Arquivos, com testes automatizados de comprimento exato de linha e posição de cada campo.
- **Marco 5 — Cobrança Registrada CNAB 240 Sicoob e Consolidação `'DEBIT'`:** Implementar `SicoobNossoNumeroDV` (`3197`), Consolidação de Inadimplentes (`DEBIT`), Remessa CNAB 240 Sicoob Mov `'01'` (`P+Q+R`) e Mov `'02'` (`P`).
- **Marco 6 — Conciliação de Baixas (Manual, Retorno CNAB 240 Sicoob/Caixa e Planilhas):** Implementar Baixa Manual + Estorno, cascata atômica da `'ÚNICA'`, parser CNAB 240 Sicoob `756` e Caixa `104` (sem truncamento de 4 dígitos!) e importador `.xls`/`.xlsx`/`.csv`.
- **Marco 7 — Diagnóstico e os 7 Relatórios Gerenciais (`HTML + PDF A4 + XLSX`):** Implementar o Diagnóstico de Adesão e todos os 7 relatórios especificados em `05_especificacao_relatorios_rave.md` com cabeçalho institucional e exportação PDF/Excel.
- **Marco 8 — Polimento UX, Testes E2E e Deploy Cloud:** Revisão de acessibilidade, responsividade desktop/tablet, suíte E2E Playwright e configuração de deploy containerizado (`Dockerfile` + CI/CD).

---

## 7. Casos de Teste Automatizados Obrigatórios (Critérios de Aceite)

A implementação só deve ser considerada concluída pela IA agêntica quando todos os testes abaixo passarem automaticamente:

1. **`test_sicoob_nosso_numero_dv_mod11_3197`:**
   - **Dado** `AG_BANCOB = "4033"`, `CODCED_BANCOB = "12345"`, `NOSSONUMERO = 185` -> string de 21 dígitos `"403300000123450000185"`;
   - **Quando** calculado pelos pesos `[3,1,9,7,...]`;
   - **Então** retorna exatamente o dígito verificador esperado (tratando restos `0` e `1` como DV `0`) e formata `pos 38..47` do Segmento `P` com 10 caracteres numéricos.
2. **`test_carne_pf_13_parcelas_primeiro_vs_renovacao`:**
   - **Dado** titular ativo com adesão `'0000'` paga, `2` dependentes, `ValorTitular = 12.00`, `ValorDep = 2.00` ($M = 16.00$), `Acrescimo = 12.00`;
   - **Quando** gerado **1º carnê**: cria 13 parcelas onde `'01/12' = 16.00`, `'02/12'..'12/12' = 16.00` e `'ÚNICA'` (`AA99`) `= 153.60`;
   - **Quando** gerado **carnê de renovação**: cria 13 parcelas onde `'01/12' = 28.00`, `'02/12'..'12/12' = 16.00` e `'ÚNICA'` (`AA99`) `= 165.60`.
3. **`test_baixa_parcela_unica_cascata_e_estorno`:**
   - **Dado** carnê de 13 parcelas em aberto;
   - **Quando** liquidada a parcela `'ÚNICA'` por `R\$ 165,60` com tarifa `R\$ 2,50`;
   - **Então** `'ÚNICA'` fica `PAGA` (`valor_liquido = 163.10`), as 12 mensais `'01/12'..'12/12'` ficam `QUITADA_POR_UNICA` com `valor_pago = 0.00`, o relatório *Contas Recebidas* soma exatamente `R\$ 165,60` bruto / `R\$ 163,10` líquido (sem duplicar!), e o relatório *Contas a Receber* retorna `R\$ 0,00` para este carnê. Ao estornar `'ÚNICA'`, todas as 13 voltam para `ABERTA`.
4. **`test_consolidacao_debit_nao_infla_recebidos`:**
   - **Dado** cliente com 3 parcelas vencidas de `R\$ 16,00`;
   - **Quando** consolidado para novo vencimento;
   - **Então** as 3 parcelas originais ficam com `dt_pagamento = hoje` e `valor_pago = 0.00` (`CONSOLIDADA`), nasce 1 parcela `'DEBIT'` (`AA00`) de `R\$ 48,00`, e *Contas Recebidas* de hoje permanece `R\$ 0,00`.
5. **`test_faturamento_pj_ignora_funcionarios_inativos`:**
   - **Dado** empresa PJ ativa com 3 funcionários ativos (`R\$ 20,00` cada) e 2 funcionários inativos (`R\$ 20,00` cada);
   - **Quando** faturada a competência `10/2026`;
   - **Então** o valor gerado na parcela `'01/01'` (`ANOMES = '2610'`) é exatamente **`R\$ 60,00`** (e não `R\$ 100,00` como ocorria no bug legado).
6. **`test_layouts_posicionais_250_350_240_colunas`:**
   - **Quando** gerados `REMADESAO`, `REMESSA` PF, `REMESSA` PJ, `SEG_VIA_CARNE`, `SEG_VIA_CARTÃO` e `CNAB 240 Sicoob` (`Mov 01` e `Mov 02`);
   - **Então** 100% das linhas possuem exatamente `250`, `350` ou `240` bytes em `Windows-1252` (excluindo `\r\n`), e os contadores dos registros Trailer (`99`, `5` e `9`) batem exatamente com a quantidade de linhas/títulos.
7. **`test_retorno_caixa_104_adesao_5_digitos`:**
   - **Dado** arquivo retorno CNAB 240 Caixa `104` contendo liquidação de cliente com `NUM_ADESAO = 19450` (`> 9999`);
   - **Quando** importado em *Baixa Automática*;
   - **Então** localiza e liquida corretamente a parcela da adesão `19450` (corrigindo o bug de 4 dígitos do legado).
