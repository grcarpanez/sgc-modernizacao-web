-- =============================================================================
-- ESPECIFICAÇÃO TÉCNICA 02: ESQUEMA MODERNO POSTGRESQL 16+ (ONLINE / WEB)
-- Destino: Banco de Dados Relacional Online (PostgreSQL 16+, UTF-8)
-- Objetivo: Preservar 100% da semântica, chaves negociais (NUM_ADESAO, ANOMES,
--           NOSSONUMERO, REMESSA) e compatibilidade com migração integral do
--           ABAC.FDB (~1.03M parcelas), eliminando fragilidades legadas e
--           adicionando auditoria, rastreabilidade de lotes/arquivos e segurança.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "unaccent";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- =============================================================================
-- 1. TIPOS ENUMERADOS / DOMÍNIOS DE NEGÓCIO
-- =============================================================================

CREATE TYPE situacao_cadastro_enum AS ENUM ('A', 'C', 'I'); -- A = Ativo, C = Cancelado, I = Inativo
CREATE TYPE tipo_contrato_enum AS ENUM ('PF_PRE_IMPRESSO', 'PF', 'PJ');
CREATE TYPE banco_cobranca_enum AS ENUM ('CAIXA_104', 'SICOOB_756', 'INDEFINIDO');
CREATE TYPE status_registro_cnab_enum AS ENUM ('N', 'S', 'B'); -- N = Não Registrado, S = Registrado, B = Baixado no Banco
CREATE TYPE origem_baixa_enum AS ENUM (
    'LEGADO',
    'MANUAL',
    'CNAB_CAIXA_104_TU',
    'CNAB_CAIXA_104_G',
    'CNAB_SICOOB_756_TU',
    'PLANILHA_EXCEL',
    'CASCATA_PARCELA_UNICA',
    'CONSOLIDACAO_DEBIT'
);
CREATE TYPE tipo_lote_arquivo_enum AS ENUM (
    'REMADESAO_TXT',
    'REMESSA_CARNE_PF_TXT',
    'REMESSA_BOLETO_PJ_TXT',
    'SEG_VIA_CARNE_TXT',
    'SEG_VIA_CARTAO_TXT',
    'CNAB240_SICOOB_REMESSA_ENTRADA',
    'CNAB240_SICOOB_REMESSA_BAIXA',
    'CNAB240_CAIXA_RETORNO',
    'CNAB240_SICOOB_RETORNO',
    'IMPORTACAO_EXCEL_BAIXA'
);

-- =============================================================================
-- 2. SEQUENCES (SINCRONIZADAS PÓS-ETL COM OS GENERATORS DO FIREBIRD)
-- =============================================================================

CREATE SEQUENCE seq_empresa_id START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_convenio_id START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_adesao_numero START WITH 1 INCREMENT BY 1;       -- Equivale a GEN_NUMERO_ID
CREATE SEQUENCE seq_carne_numero START WITH 1 INCREMENT BY 1;        -- Equivale a GEN_CARNE_ID
CREATE SEQUENCE seq_dependente_id START WITH 1 INCREMENT BY 1;       -- Equivale a GEN_DEPENDENTES_ID
CREATE SEQUENCE seq_funcionario_pj_id START WITH 1 INCREMENT BY 1;   -- Equivale a GEN_CODIGOFUNC_ID
CREATE SEQUENCE seq_dep_func_pj_id START WITH 1 INCREMENT BY 1;      -- Equivale a GEN_CODIGODEPFUNC_ID
CREATE SEQUENCE seq_nosso_numero_sicoob START WITH 1 INCREMENT BY 1; -- Equivale a GEN_NOSSONUMERO_ID (máx 7 dígitos: 1..9999999)
CREATE SEQUENCE seq_remessa_adesao START WITH 1 INCREMENT BY 1;      -- Substitui MAX(REMADESAO)+1 com segurança concorrente
CREATE SEQUENCE seq_remessa_grafica START WITH 1 INCREMENT BY 1;     -- Substitui MAX(CARNE.REMESSA)+1 com segurança concorrente
CREATE SEQUENCE seq_nsa_cnab_sicoob START WITH 1 INCREMENT BY 1;     -- NSA sequencial de remessa CNAB 240 Sicoob

-- =============================================================================
-- 3. TABELA: empresas (Cedente / Operadora e Parâmetros Bancários)
-- =============================================================================

CREATE TABLE empresas (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_empresa_id'),
    cnpj VARCHAR(14) NOT NULL,                      -- Somente dígitos (validado no backend; formatado na UI)
    razao_social VARCHAR(100) NOT NULL,
    nome_fantasia VARCHAR(100),
    logomarca_bytes BYTEA,                          -- Logomarca p/ cabeçalho de relatórios PDF
    logomarca_mime VARCHAR(50) DEFAULT 'image/bmp',
    endereco VARCHAR(100) NOT NULL,
    end_numero VARCHAR(10),
    complemento VARCHAR(50),
    bairro VARCHAR(50) NOT NULL,
    cidade VARCHAR(50) NOT NULL,
    estado CHAR(2) NOT NULL,
    cep VARCHAR(8),                                 -- Somente dígitos (8 posições)
    telefone_comercial VARCHAR(15),
    telefone_fax VARCHAR(15),
    -- Parâmetros Bancários Sicoob / Bancoob (756)
    agencia_sicoob VARCHAR(4),
    dv_agencia_sicoob VARCHAR(1),
    codigo_cedente_sicoob VARCHAR(10),
    conta_corrente_sicoob VARCHAR(12),
    dv_conta_sicoob VARCHAR(1),
    carteira_sicoob VARCHAR(2),
    modalidade_sicoob VARCHAR(2),
    percentual_multa NUMERIC(5, 2) NOT NULL DEFAULT 0.00 CHECK (percentual_multa >= 0),
    juros_mora_dia NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (juros_mora_dia >= 0),
    -- Parâmetros de Preço Padrão (configuráveis em vez de apenas digitados em tela)
    valor_base_plano_pf NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    valor_adicional_dependente_pf NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    desconto_parcela_unica_percent NUMERIC(5, 2) NOT NULL DEFAULT 20.00,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 4. TABELA: usuarios (Autenticação Segura + Permissões RBAC Granulares)
-- =============================================================================

CREATE TABLE usuarios (
    id BIGSERIAL PRIMARY KEY,
    empresa_id INTEGER NOT NULL REFERENCES empresas(id) ON UPDATE CASCADE,
    nome VARCHAR(100) NOT NULL,
    apelido VARCHAR(30) NOT NULL UNIQUE,            -- Login único (case-insensitive via índice funcional)
    email VARCHAR(120),
    senha_hash VARCHAR(255) NOT NULL,               -- Argon2id ou BCrypt (migrado do XOR 0xC5 no ETL)
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    -- 14 Permissões Originais Mapeadas 1:1 + 4 Novas Permissões p/ Fechar Brechas Legadas
    perm_empresas_consultar BOOLEAN NOT NULL DEFAULT FALSE,
    perm_empresas_dados BOOLEAN NOT NULL DEFAULT FALSE,
    perm_clientes_consultar BOOLEAN NOT NULL DEFAULT FALSE,
    perm_clientes_dados BOOLEAN NOT NULL DEFAULT FALSE,
    perm_convenios_consultar BOOLEAN NOT NULL DEFAULT FALSE,
    perm_convenios_dados BOOLEAN NOT NULL DEFAULT FALSE,
    perm_usuarios_consultar BOOLEAN NOT NULL DEFAULT FALSE,
    perm_usuarios_dados BOOLEAN NOT NULL DEFAULT FALSE,
    perm_emitir_adesao BOOLEAN NOT NULL DEFAULT FALSE,
    perm_emitir_arquivo BOOLEAN NOT NULL DEFAULT FALSE,
    perm_baixa_manual BOOLEAN NOT NULL DEFAULT FALSE,
    perm_baixa_automatica BOOLEAN NOT NULL DEFAULT FALSE,
    perm_cancelar_plano BOOLEAN NOT NULL DEFAULT FALSE,
    perm_relatorios BOOLEAN NOT NULL DEFAULT FALSE,
    perm_mudar_conexao BOOLEAN NOT NULL DEFAULT FALSE, -- Mantido por compatibilidade histórica / admin de sistema
    -- Novas permissões que no legado estavam desprotegidas no menu principal:
    perm_pessoa_juridica_consultar BOOLEAN NOT NULL DEFAULT FALSE,
    perm_pessoa_juridica_dados BOOLEAN NOT NULL DEFAULT FALSE,
    perm_remessa_cnab BOOLEAN NOT NULL DEFAULT FALSE,
    perm_consolidar_debitos BOOLEAN NOT NULL DEFAULT FALSE,
    ultimo_login_em TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_usuarios_apelido_lower ON usuarios (LOWER(apelido));

-- =============================================================================
-- 5. TABELA: convenios (Cadastrantes / Comissionados)
-- =============================================================================

CREATE TABLE convenios (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_convenio_id'), -- COD_CONVENIO legado
    nome VARCHAR(100) NOT NULL,
    cpf_cnpj VARCHAR(14),                           -- Somente dígitos (11 CPF ou 14 CNPJ)
    endereco VARCHAR(100),
    end_numero VARCHAR(10),
    complemento VARCHAR(30),
    bairro VARCHAR(50),
    cidade VARCHAR(50),
    estado CHAR(2),
    cep VARCHAR(8),
    telefone_comercial VARCHAR(15),
    telefone_fax VARCHAR(15),
    percentual_comissao NUMERIC(5, 2) NOT NULL DEFAULT 0.00 CHECK (percentual_comissao >= 0 AND percentual_comissao <= 100),
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 6. TABELA: adesoes (Raiz Contratual Numerada p/ PF Pré-Impressa, PF e PJ)
-- =============================================================================

CREATE TABLE adesoes (
    numero INTEGER PRIMARY KEY DEFAULT nextval('seq_adesao_numero'), -- ADESAO.NUMERO legado
    empresa_id INTEGER NOT NULL REFERENCES empresas(id) ON UPDATE CASCADE,
    data_emissao DATE NOT NULL DEFAULT CURRENT_DATE,
    remessa_adesao INTEGER NOT NULL DEFAULT 0,      -- ADESAO.REMADESAO (lote de gráfica das fichas em branco)
    tipo_contrato tipo_contrato_enum NOT NULL DEFAULT 'PF_PRE_IMPRESSO',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_adesoes_remessa ON adesoes (remessa_adesao);
CREATE INDEX idx_adesoes_tipo ON adesoes (tipo_contrato);

-- =============================================================================
-- 7. TABELA: clientes_pf (Titulares Pessoa Física - 1:1 com adesoes.numero)
-- =============================================================================

CREATE TABLE clientes_pf (
    numero INTEGER PRIMARY KEY REFERENCES adesoes(numero) ON UPDATE CASCADE, -- CLIENTES.NUMERO legado
    convenio_id INTEGER NOT NULL REFERENCES convenios(id) ON UPDATE CASCADE,
    nome VARCHAR(100) NOT NULL,
    cpf VARCHAR(11),                                -- Somente dígitos (11 dígitos; aceita NULL p/ legado inválido higienizado)
    cpf_legado_bruto VARCHAR(20),                   -- Preserva valor original caso CPF legado seja inválido no ETL
    rg VARCHAR(20),
    data_nascimento DATE,
    nome_mae VARCHAR(100),
    estado_civil CHAR(1) CHECK (estado_civil IN ('S', 'C', 'V', 'D', 'O') OR estado_civil IS NULL),
    sexo CHAR(1) CHECK (sexo IN ('M', 'F') OR sexo IS NULL),
    endereco VARCHAR(100) NOT NULL,
    end_numero VARCHAR(10),
    complemento VARCHAR(30),
    bairro VARCHAR(50) NOT NULL,
    cidade VARCHAR(50) NOT NULL,
    estado CHAR(2),
    cep VARCHAR(8),
    telefone_comercial VARCHAR(15),
    telefone_residencial_fax VARCHAR(15),           -- Equivale a CLIENTES.TELEFONE_FAX
    telefone_celular VARCHAR(15),
    email VARCHAR(120),
    dia_vencimento SMALLINT CHECK (dia_vencimento BETWEEN 1 AND 31),
    valor_plano NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (valor_plano >= 0),
    banco_cobranca banco_cobranca_enum NOT NULL DEFAULT 'SICOOB_756',
    situacao situacao_cadastro_enum NOT NULL DEFAULT 'A',
    data_inscricao DATE,
    data_atualizacao DATE,
    data_cancelamento DATE,
    motivo_cancelamento TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_clientes_pf_situacao ON clientes_pf (situacao, numero);
CREATE INDEX idx_clientes_pf_convenio ON clientes_pf (convenio_id);
CREATE INDEX idx_clientes_pf_cpf ON clientes_pf (cpf);
CREATE INDEX idx_clientes_pf_nome_trgm ON clientes_pf USING gin (nome gin_trgm_ops);
CREATE INDEX idx_clientes_pf_cep_rota ON clientes_pf (estado, cidade, bairro, endereco, cep, nome);

-- =============================================================================
-- 8. TABELA: dependentes_pf (Dependentes de Titular Pessoa Física)
-- =============================================================================

CREATE TABLE dependentes_pf (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_dependente_id'), -- DEPENDENTES.CODIGO legado
    cliente_numero INTEGER NOT NULL REFERENCES clientes_pf(numero) ON UPDATE CASCADE ON DELETE CASCADE,
    nome VARCHAR(100) NOT NULL,
    parentesco VARCHAR(20),
    data_nascimento DATE,
    cpf VARCHAR(11),
    cpf_legado_bruto VARCHAR(20),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_dependentes_pf_cliente ON dependentes_pf (cliente_numero, id);
CREATE INDEX idx_dependentes_pf_nome_trgm ON dependentes_pf USING gin (nome gin_trgm_ops);

-- =============================================================================
-- 9. TABELA: clientes_pj (Empresas Contratantes - 1:1 com adesoes.numero)
-- =============================================================================

CREATE TABLE clientes_pj (
    numero INTEGER PRIMARY KEY REFERENCES adesoes(numero) ON UPDATE CASCADE, -- PESSOAJURIDICA.NUMERO legado
    nome_razao_social VARCHAR(100) NOT NULL,
    cnpj VARCHAR(14),
    cnpj_legado_bruto VARCHAR(20),
    inscricao_estadual VARCHAR(30),
    inscricao_municipal VARCHAR(30),
    contato VARCHAR(100),
    endereco VARCHAR(100) NOT NULL,
    end_numero VARCHAR(10),
    complemento VARCHAR(30),
    bairro VARCHAR(50) NOT NULL,
    cidade VARCHAR(50) NOT NULL,
    estado CHAR(2),
    cep VARCHAR(8),
    telefone_comercial VARCHAR(15),
    telefone_fax VARCHAR(15),
    telefone_celular VARCHAR(15),
    dia_vencimento SMALLINT NOT NULL CHECK (dia_vencimento BETWEEN 1 AND 28),
    situacao situacao_cadastro_enum NOT NULL DEFAULT 'A',
    data_inscricao DATE,
    observacoes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_clientes_pj_situacao ON clientes_pj (situacao, numero);
CREATE INDEX idx_clientes_pj_cnpj ON clientes_pj (cnpj);
CREATE INDEX idx_clientes_pj_nome_trgm ON clientes_pj USING gin (nome_razao_social gin_trgm_ops);

-- =============================================================================
-- 10. TABELA: funcionarios_pj (Titulares vinculados a Clientes PJ)
-- =============================================================================

CREATE TABLE funcionarios_pj (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_funcionario_pj_id'), -- CODIGOFUNC legado
    cliente_pj_numero INTEGER NOT NULL REFERENCES clientes_pj(numero) ON UPDATE CASCADE ON DELETE CASCADE,
    nome VARCHAR(100) NOT NULL,
    cpf VARCHAR(11),
    cpf_legado_bruto VARCHAR(20),
    rg VARCHAR(20),
    data_nascimento DATE,
    nome_mae VARCHAR(100),
    estado_civil CHAR(1) CHECK (estado_civil IN ('S', 'C', 'V', 'D', 'O') OR estado_civil IS NULL),
    sexo CHAR(1) CHECK (sexo IN ('M', 'F') OR sexo IS NULL),
    endereco VARCHAR(100) NOT NULL,
    end_numero VARCHAR(10),
    complemento VARCHAR(30),
    bairro VARCHAR(50) NOT NULL,
    cidade VARCHAR(50) NOT NULL,
    estado CHAR(2),
    cep VARCHAR(8),
    telefone_comercial VARCHAR(15),
    telefone_residencial VARCHAR(15),
    telefone_celular VARCHAR(15),
    valor_plano NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (valor_plano >= 0),
    data_inscricao DATE,
    situacao situacao_cadastro_enum NOT NULL DEFAULT 'A',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_funcionarios_pj_empresa ON funcionarios_pj (cliente_pj_numero, situacao);

-- =============================================================================
-- 11. TABELA: dependentes_func_pj (Dependentes de Funcionários PJ)
-- =============================================================================

CREATE TABLE dependentes_func_pj (
    id INTEGER PRIMARY KEY DEFAULT nextval('seq_dep_func_pj_id'), -- CODIGODEPFUNC legado
    funcionario_pj_id INTEGER NOT NULL REFERENCES funcionarios_pj(id) ON UPDATE CASCADE ON DELETE CASCADE,
    nome VARCHAR(100) NOT NULL,
    parentesco VARCHAR(20),
    data_nascimento DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_dep_func_pj_func ON dependentes_func_pj (funcionario_pj_id);

-- =============================================================================
-- 12. TABELA: lotes_arquivos (Rastreabilidade e Armazenamento Online de Remessas/Retornos)
--     Substitui a dependência de pastas locais (EMPRESA.DIRARQUIVO) na versão Web!
-- =============================================================================

CREATE TABLE lotes_arquivos (
    id BIGSERIAL PRIMARY KEY,
    empresa_id INTEGER NOT NULL REFERENCES empresas(id),
    usuario_id BIGINT REFERENCES usuarios(id),
    tipo_lote tipo_lote_arquivo_enum NOT NULL,
    numero_remessa INTEGER,                         -- Ex: REMADESAO, CARNE.REMESSA ou NSA CNAB
    banco_cobranca banco_cobranca_enum,
    nome_arquivo VARCHAR(255) NOT NULL,
    hash_sha256 CHAR(64) NOT NULL,                  -- Impede reprocessamento acidental duplicado de retornos/planilhas
    tamanho_bytes BIGINT NOT NULL,
    quantidade_registros INTEGER NOT NULL DEFAULT 0,
    valor_total NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    conteudo_arquivo BYTEA,                         -- Ou referência p/ Object Storage (S3 / GCS)
    storage_uri VARCHAR(500),
    resumo_processamento JSONB,                     -- Contadores de liquidados, rejeitados, baixados, erros por linha
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_lotes_arquivos_tipo_remessa ON lotes_arquivos (tipo_lote, numero_remessa);
CREATE INDEX idx_lotes_arquivos_hash ON lotes_arquivos (hash_sha256);

-- =============================================================================
-- 13. TABELA: carnes (Lotes de Carnê/Boleto por Contrato - Equivale a CARNE)
-- =============================================================================

CREATE TABLE carnes (
    numero INTEGER PRIMARY KEY DEFAULT nextval('seq_carne_numero'), -- CARNE.NUMERO legado
    num_adesao INTEGER NOT NULL REFERENCES adesoes(numero) ON UPDATE CASCADE,
    data_geracao DATE NOT NULL DEFAULT CURRENT_DATE,
    num_parcelas SMALLINT NOT NULL,                 -- 1 (Adesão / Boleto PJ) ou 12 (Carnê PF)
    remessa INTEGER,                                -- Número do lote gráfico REMESSA{n}.TXT
    lote_arquivo_id BIGINT REFERENCES lotes_arquivos(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_carnes_adesao ON carnes (num_adesao);
CREATE INDEX idx_carnes_remessa ON carnes (remessa, numero);

-- =============================================================================
-- 14. TABELA: parcelas (Títulos Financeiros - Equivale a PARCELAS, ~1.03M linhas)
-- =============================================================================

CREATE TABLE parcelas (
    id BIGSERIAL PRIMARY KEY,                       -- Surrogate PK para APIs REST modernas
    num_adesao INTEGER NOT NULL REFERENCES adesoes(numero) ON UPDATE CASCADE,
    anomes VARCHAR(4) NOT NULL,                     -- Chave negocial composta única: (num_adesao, anomes)
    num_carne INTEGER NOT NULL REFERENCES carnes(numero) ON UPDATE CASCADE,
    id_parc VARCHAR(10),                            -- 'ADESÃO', 'ÚNICA', '01/12'..'12/12', 'MM/YY', 'DEBIT'
    data_emissao DATE NOT NULL,                     -- DTEM
    data_vencimento DATE,                           -- DTVENC
    valor_nominal NUMERIC(12, 2) CHECK (valor_nominal >= 0), -- VALOR
    data_pagamento DATE,                            -- DTPAG (NULL = em aberto)
    valor_pago NUMERIC(12, 2) CHECK (valor_pago >= 0),       -- VALOR_PAGO
    valor_compensacao NUMERIC(12, 2) DEFAULT 0.00 CHECK (valor_compensacao >= 0), -- VALOR_COMP (tarifa bancária)
    valor_liquido NUMERIC(12, 2) GENERATED ALWAYS AS (
        CASE
            WHEN data_pagamento IS NULL THEN NULL
            ELSE COALESCE(valor_pago, 0.00) - COALESCE(valor_compensacao, 0.00)
        END
    ) STORED,
    registrado status_registro_cnab_enum NOT NULL DEFAULT 'N',
    nosso_numero INTEGER,                           -- Sequencial Sicoob 7 dígitos sem DV
    nosso_numero_dv CHAR(1),                        -- DV Mod-11 Sicoob pré-calculado p/ auditoria rápida
    origem_baixa origem_baixa_enum,
    baixado_por_usuario_id BIGINT REFERENCES usuarios(id),
    baixado_em TIMESTAMPTZ,
    lote_retorno_id BIGINT REFERENCES lotes_arquivos(id),
    parcela_consolidadora_id BIGINT REFERENCES parcelas(id), -- Preenchido quando quitada por ÚNICA ou DEBIT
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_parcelas_adesao_anomes UNIQUE (num_adesao, anomes)
);

-- Índices de Alta Performance para > 1 Milhão de Parcelas:
CREATE INDEX idx_parcelas_carne ON parcelas (num_carne, data_vencimento, valor_nominal DESC);
CREATE INDEX idx_parcelas_nosso_numero ON parcelas (nosso_numero) WHERE nosso_numero IS NOT NULL;
CREATE INDEX idx_parcelas_abertas_vencimento ON parcelas (data_vencimento, num_adesao, id_parc)
    WHERE data_pagamento IS NULL;
CREATE INDEX idx_parcelas_pagas_periodo ON parcelas (data_pagamento, num_adesao)
    WHERE data_pagamento IS NOT NULL;
CREATE INDEX idx_parcelas_cnab_pendentes ON parcelas (registrado, data_vencimento, num_adesao)
    WHERE data_pagamento IS NULL;
CREATE INDEX idx_parcelas_cnab_baixa_balcao ON parcelas (data_vencimento, num_carne)
    WHERE registrado = 'S' AND data_pagamento IS NOT NULL AND COALESCE(valor_compensacao, 0) = 0;

-- =============================================================================
-- 15. TABELA: fila_segunda_via (Substitui o Estado Volátil em Memória de TFrmSegundaVia)
-- =============================================================================

CREATE TABLE fila_segunda_via (
    id BIGSERIAL PRIMARY KEY,
    empresa_id INTEGER NOT NULL REFERENCES empresas(id),
    usuario_id BIGINT NOT NULL REFERENCES usuarios(id),
    tipo_item VARCHAR(15) NOT NULL CHECK (tipo_item IN ('CARNE', 'CARTAO_TITULAR', 'CARTAO_DEP')),
    num_adesao INTEGER NOT NULL REFERENCES adesoes(numero),
    num_carne INTEGER REFERENCES carnes(numero),
    dependente_pf_id INTEGER REFERENCES dependentes_pf(id),
    processado BOOLEAN NOT NULL DEFAULT FALSE,
    lote_arquivo_id BIGINT REFERENCES lotes_arquivos(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 16. TABELA: auditoria_eventos (Trilha Completa p/ Operações Financeiras e Cadastrais)
-- =============================================================================

CREATE TABLE auditoria_eventos (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id),
    entidade VARCHAR(60) NOT NULL,
    entidade_id VARCHAR(60) NOT NULL,
    acao VARCHAR(40) NOT NULL,                      -- CREATE, UPDATE, DELETE, BAIXA, ESTORNO, CANCELAMENTO, REMESSA
    dados_anteriores JSONB,
    dados_novos JSONB,
    ip_origem INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_auditoria_entidade ON auditoria_eventos (entidade, entidade_id, created_at DESC);
CREATE INDEX idx_auditoria_usuario ON auditoria_eventos (usuario_id, created_at DESC);
