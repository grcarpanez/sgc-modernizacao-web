-- =============================================================================
-- ESPECIFICAÇÃO TÉCNICA 01: ESQUEMA LEGADO FIREBIRD 2.5 (ABAC.FDB)
-- Sistema: SGC (Gestão de Carnês / Sistema de Gestão de Clientes e Carnês v1.1)
-- Extração: isql.exe -x (Firebird 2.5, SQL Dialect 3, Page Size 16384, Charset NONE)
-- Nota de Privacidade: Nenhum dado pessoal (PII) foi incluído neste arquivo.
-- =============================================================================
--
-- VOLUMETRIA E ESTATÍSTICAS AGREGADAS OBSERVADAS EM PRODUÇÃO (ABAC.FDB):
--   1. PARCELAS ................... 1.030.123 registros
--   2. CARNE ......................   111.242 registros
--   3. DEPENDENTES ................    48.505 registros
--   4. ADESAO .....................    32.996 registros
--   5. CLIENTES ...................    22.706 registros
--   6. DEPFUNCPESSOAJURIDICA ......       101 registros
--   7. FUNCIONARIOSPESSOAJURIDICA .        91 registros
--   8. CONVENIOS ..................        20 registros
--   9. PESSOAJURIDICA .............         9 registros
--  10. USUARIOS ...................         5 registros
--  11. ENDERECOS ..................         2 registros (tabela legada sem uso ativo no EXE)
--  12. EMPRESA ....................         1 registro
--
-- OBSERVAÇÕES CRÍTICAS DE ENGENHARIA REVERSA SOBRE O ESQUEMA LEGADO:
--   - Character Set NONE: textos gravados em codificação ANSI Windows-1252 (CP1252).
--     A migração ETL para PostgreSQL (UTF-8) DEVE decodificar os bytes como 'windows-1252'.
--   - Herança Contratual via ADESAO.NUMERO:
--     Tanto CLIENTES.NUMERO (PF) quanto PESSOAJURIDICA.NUMERO (PJ) possuem FK 1:1 para
--     ADESAO.NUMERO. Assim, um número de adesão pertence a uma PF ou a uma PJ (ou ainda
--     está em branco aguardando cadastramento, caso de fichas pré-impressas).
--   - CONVENIOS.PERC_COM NUMERIC(2, 2):
--     No Firebird Dialect 3, NUMERIC(2,2) limita valores a -0.99..+0.99 no padrão SQL estrito,
--     mas no IBX/Firebird armazena internamente como SMALLINT com escala -2 (permitindo até
--     327.67 no motor interno, porém no DataSet Delphi está declarado Precision=4, Size=2).
--     Em PostgreSQL DEVE ser migrado para NUMERIC(5, 2) para suportar 0.00% a 100.00%.
--   - Índices Redundantes:
--     IDX_PARCELAS_DTPAG_DTVENC_ID e IDX_PARCELAS_VENCIDAS são idênticos:
--     (DTPAG, DTVENC, ID_PARC, NUM_ADESAO).
--   - Tabela USUARIOS sem PRIMARY KEY explícita (possui apenas UNIQUE (APELIDO)) e
--     SENHA VARCHAR(10) cifrada simetricamente via XOR 0xC5 (chave "Acadêmico" em CP1252).
--   - Valores de Domínio Observados:
--     * CLIENTES.SITUACAO / PESSOAJURIDICA.SITUACAO / FUNCIONARIOSPESSOAJURIDICA.SITUACAO:
--       'A' = Ativo, 'C' = Cancelado (há registros legados raros com NULL em CLIENTES).
--     * CLIENTES.BANCO:
--       1 = Caixa Econômica Federal (104), 2 = Sicoob / Bancoob (756) (há raros 0 legados).
--     * CLIENTES.EST_CIVIL:
--       'S' = Solteiro(a), 'C' = Casado(a), 'V' = Viúvo(a), 'D' = Divorciado(a), 'O' = Outros.
--     * CLIENTES.SEXO:
--       'M' = Masculino, 'F' = Feminino.
--     * PARCELAS.ID_PARC:
--       'ADESÃO' (ANOMES='0000'), 'ÚNICA' (ANOMES=YY||'98' ou legado YY||'99'),
--       '01/12'..'12/12' (mensalidades PF, ANOMES=YYMM), 'MM/YY' (boleto mensal PJ, ANOMES=YYMM),
--       'DEBIT' (consolidação de débitos em atraso, ANOMES=YY||'00').
--     * PARCELAS.REGISTRADO:
--       NULL / 'N' = Não registrado no Sicoob, 'S' = Registrado (Entrada 02 confirmada),
--       'B' = Baixado no banco (Retorno movimento 09).
-- =============================================================================

SET SQL DIALECT 3;

/* CREATE DATABASE 'ABAC.FDB' PAGE_SIZE 16384 DEFAULT CHARACTER SET NONE */

/* Generators / Sequences (9 no total) */
CREATE GENERATOR GEN_CARNE_ID;          -- Usado para CARNE.NUMERO
CREATE GENERATOR GEN_CODIGODEPFUNC_ID;  -- Usado para DEPFUNCPESSOAJURIDICA.CODIGODEPFUNC
CREATE GENERATOR GEN_CODIGOFUNC_ID;     -- Usado para FUNCIONARIOSPESSOAJURIDICA.CODIGOFUNC
CREATE GENERATOR GEN_CONVENIOS_ID;      -- Usado para CONVENIOS.COD_CONVENIO
CREATE GENERATOR GEN_DEPENDENTES_ID;    -- Usado para DEPENDENTES.CODIGO
CREATE GENERATOR GEN_EMPRESAS_ID;       -- Usado para EMPRESA.CODIGO
CREATE GENERATOR GEN_ENDERECOS_ID;      -- Legado (ENDERECOS.COD_ENDERECO)
CREATE GENERATOR GEN_NOSSONUMERO_ID;    -- Sequencial de 7 dígitos p/ PARCELAS.NOSSONUMERO (Sicoob 756)
CREATE GENERATOR GEN_NUMERO_ID;         -- Usado para ADESAO.NUMERO e PESSOAJURIDICA.NUMERO

/* 1. Tabela: ADESAO (Contratos / Fichas de Adesão numeradas) */
CREATE TABLE ADESAO (
    NUMERO INTEGER NOT NULL,
    COD_EMPRESA INTEGER NOT NULL,
    DATA DATE NOT NULL,
    REMADESAO INTEGER NOT NULL,         -- Nº do lote REMADESAO{n}.TXT (0 quando gerada p/ PJ)
    CONSTRAINT PK_ADESAO PRIMARY KEY (NUMERO)
);

/* 2. Tabela: CARNE (Lotes de emissão de carnês PF, adesão inicial ou boletos PJ) */
CREATE TABLE CARNE (
    NUMERO INTEGER NOT NULL,
    NUM_ADESAO INTEGER NOT NULL,
    DATA DATE NOT NULL,
    NUM_PARC SMALLINT NOT NULL,         -- 1 (Adesão ou Boleto Mensal PJ) ou 12 (Carnê Anual PF c/ 13 registros em PARCELAS)
    REMESSA INTEGER,                    -- Sequencial da remessa gráfica REMESSA{n}.TXT
    CONSTRAINT PK_CARNE PRIMARY KEY (NUMERO)
);

/* 3. Tabela: CLIENTES (Titulares Pessoa Física) */
CREATE TABLE CLIENTES (
    NUMERO INTEGER NOT NULL,            -- Mesmo ID de ADESAO.NUMERO (relação 1:1)
    NOME VARCHAR(50) NOT NULL,
    CPF VARCHAR(14),                    -- Armazenado com máscara '999.999.999-99'
    RG VARCHAR(16),
    ENDERECO VARCHAR(50) NOT NULL,
    BAIRRO VARCHAR(30) NOT NULL,
    CIDADE VARCHAR(30) NOT NULL,
    ESTADO CHAR(2),
    CEP CHAR(9),                        -- Armazenado com máscara '99999-999'
    END_NUMERO VARCHAR(6),
    COMPLEMENTO VARCHAR(20),
    TELEFONE_COMERCIAL VARCHAR(13),     -- Máscara '(99)9999-9999'
    TELEFONE_FAX VARCHAR(13),           -- Usado na UI como Telefone Residencial / Fax
    DIAVENC SMALLINT,                   -- Dia de vencimento mensal (1..30; UI sugere 1..28/30)
    DATA_NASC DATE,
    NOME_MAE VARCHAR(50),
    EST_CIVIL CHAR(1),                  -- S, C, V, D, O
    SEXO CHAR(1),                       -- M, F
    TELEFONE_CEL VARCHAR(14),
    VALOR_PLANO NUMERIC(8, 2),          -- Valor da mensalidade base + adicionais por dependente
    SITUACAO CHAR(1),                   -- 'A' (Ativo) ou 'C' (Cancelado)
    INSCRICAO DATE,                     -- Data de inscrição/cadastramento do cliente
    COD_CONVENIO INTEGER NOT NULL,      -- FK p/ CONVENIOS (cadastrante/comissionado)
    EMAIL VARCHAR(50),
    BANCO INTEGER NOT NULL,             -- 1 = Caixa (104), 2 = Sicoob/Bancoob (756)
    DATA_ATUALIZACAO DATE,
    CONSTRAINT PK_CLIENTES PRIMARY KEY (NUMERO)
);

/* 4. Tabela: CONVENIOS (Cadastrantes / Representantes Comissionados) */
CREATE TABLE CONVENIOS (
    COD_CONVENIO INTEGER NOT NULL,
    NOME VARCHAR(50) NOT NULL,
    CNPJ VARCHAR(18),                   -- Aceita CPF ou CNPJ na UI
    ENDERECO VARCHAR(50),
    BAIRRO VARCHAR(30),
    CIDADE VARCHAR(30),
    ESTADO CHAR(2),
    CEP CHAR(9),
    END_NUMERO VARCHAR(6),
    COMPLEMENTO VARCHAR(20),
    TELEFONE_COMERCIAL VARCHAR(13),
    TELEFONE_FAX VARCHAR(13),
    PERC_COM NUMERIC(2, 2),             -- Percentual de comissão (%) sobre PARCELAS.VALOR_PAGO
    CONSTRAINT PK_CONVENIOS PRIMARY KEY (COD_CONVENIO)
);

/* 5. Tabela: DEPENDENTES (Dependentes de Clientes Pessoa Física) */
CREATE TABLE DEPENDENTES (
    CODIGO INTEGER NOT NULL,
    COD_CLIENTE INTEGER NOT NULL,
    NOME VARCHAR(50) NOT NULL,
    PARENTESCO VARCHAR(11),             -- Ex.: CONJUGE, FILHO(A), PAI, MAE, SOGRO(A), OUTROS
    DATA_NASC DATE,
    CPF VARCHAR(14),
    CONSTRAINT PK_DEPENDENTES PRIMARY KEY (CODIGO)
);

/* 6. Tabela: DEPFUNCPESSOAJURIDICA (Dependentes de Funcionários de Clientes PJ) */
CREATE TABLE DEPFUNCPESSOAJURIDICA (
    CODIGODEPFUNC INTEGER NOT NULL,
    CODIGOFUNC INTEGER NOT NULL,
    NOME VARCHAR(50) NOT NULL,
    PARENTESCO VARCHAR(11),
    DATA_NASC DATE,
    CONSTRAINT PK_DEPFUNCPESSOAJURIDICA PRIMARY KEY (CODIGODEPFUNC)
);

/* 7. Tabela: EMPRESA (Cedente / Operadora do Sistema e Parâmetros Bancários Sicoob) */
CREATE TABLE EMPRESA (
    CODIGO INTEGER NOT NULL,
    CNPJ_EMPRESA VARCHAR(18) NOT NULL,
    NOME_EMPRESA VARCHAR(50) NOT NULL,
    LOGOMARCA BLOB SUB_TYPE 0 SEGMENT SIZE 80, -- Imagem BMP usada nos cabeçalhos do Rave Reports
    ENDERECO VARCHAR(50) NOT NULL,
    BAIRRO VARCHAR(50) NOT NULL,
    CIDADE VARCHAR(50) NOT NULL,
    ESTADO CHAR(2) NOT NULL,
    CEP CHAR(9),
    END_NUMERO VARCHAR(10),
    COMPLEMENTO VARCHAR(50),
    TELEFONE_COMERCIAL VARCHAR(13),
    TELEFONE_FAX VARCHAR(13),
    DIRARQUIVO VARCHAR(500),            -- Diretório local padrão de exportação de arquivos .TXT
    DATA_ARQ DATE,                      -- Data agendada p/ próxima geração em lote de carnês
    AG_BANCOB VARCHAR(4),               -- Agência Sicoob (756), ex: '3069'
    CODCED_BANCOB VARCHAR(7),           -- Código do Beneficiário/Cedente Sicoob
    CONTA_BANCOB VARCHAR(8),            -- Conta Corrente Sicoob
    DVCONTA_BANCOB VARCHAR(1),          -- DV da Conta Corrente Sicoob
    CARTEIRA_BANCOB VARCHAR(2),         -- Carteira Sicoob (ex: '1')
    MODALIDADE_BANCOB VARCHAR(2),       -- Modalidade Sicoob (ex: '01' Simples Com Registro)
    DVAG VARCHAR(1),                    -- DV da Agência Sicoob
    PERCENTMULTA NUMERIC(4, 2) DEFAULT 0, -- Multa percentual p/ Segmento R CNAB 240 Sicoob
    JUROSDIA NUMERIC(8, 2) DEFAULT 0,   -- Juros diário em R$ p/ Segmento P CNAB 240 Sicoob
    PRIMARY KEY (CODIGO)
);

/* 8. Tabela: ENDERECOS (Tabela auxiliar legada de CEPs/Logradouros, sem tela ativa no EXE) */
CREATE TABLE ENDERECOS (
    COD_ENDERECO INTEGER NOT NULL,
    ENDERECO VARCHAR(50) NOT NULL,
    BAIRRO VARCHAR(30) NOT NULL,
    CIDADE VARCHAR(30) NOT NULL,
    ESTADO CHAR(2) NOT NULL,
    CEP CHAR(9),
    CONSTRAINT PK_ENDERECOS PRIMARY KEY (COD_ENDERECO)
);

/* 9. Tabela: FUNCIONARIOSPESSOAJURIDICA (Titulares vinculados a uma Empresa Cliente PJ) */
CREATE TABLE FUNCIONARIOSPESSOAJURIDICA (
    CODIGOFUNC INTEGER NOT NULL,
    CODIGOPESSOAJURIDICA INTEGER NOT NULL,
    NOME VARCHAR(50) NOT NULL,
    CPF VARCHAR(14),
    RG VARCHAR(16),
    ENDERECO VARCHAR(50) NOT NULL,
    BAIRRO VARCHAR(30) NOT NULL,
    CIDADE VARCHAR(30) NOT NULL,
    ESTADO CHAR(2),
    CEP CHAR(9),
    END_NUMERO VARCHAR(6),
    COMPLEMENTO VARCHAR(20),
    TELEFONE_COMERCIAL VARCHAR(13),
    TELEFONE_RESIDENCIAL VARCHAR(13),
    TELEFONE_CEL VARCHAR(13),
    DATA_NASC DATE,
    NOME_MAE VARCHAR(50),
    EST_CIVIL CHAR(1),
    SEXO CHAR(1),
    VALOR_PLANO NUMERIC(8, 2),          -- Somado mensalmente p/ compor o boleto da PJ
    INSCRICAO DATE,
    SITUACAO CHAR(1) NOT NULL,          -- 'A' ou 'C' (Nota: bug legado no SUM de PJ não filtrava SITUACAO='A')
    CONSTRAINT PK_FUNCIONARIOSPESSOAJURIDICA PRIMARY KEY (CODIGOFUNC)
);

/* 10. Tabela: PARCELAS (Títulos Financeiros: Adesões, Mensalidades, Parcela Única, Boletos PJ e DEBIT) */
CREATE TABLE PARCELAS (
    NUM_CARNE INTEGER NOT NULL,
    NUM_ADESAO INTEGER NOT NULL,
    ANOMES VARCHAR(4) NOT NULL,         -- '0000' (Adesão), 'YYMM' (Mensal), 'YY98'/'YY99' (Única), 'YY00' (DEBIT)
    DTEM DATE NOT NULL,                 -- Data de emissão
    DTVENC DATE,                        -- Data de vencimento (NULL em fichas de adesão pré-impressas)
    VALOR NUMERIC(8, 2),                -- Valor nominal do título (NULL em fichas de adesão pré-impressas)
    DTPAG DATE,                         -- Data de pagamento/liquidação (NULL = em aberto)
    VALOR_PAGO NUMERIC(8, 2),           -- Valor bruto pago pelo cliente (0.00 quando quitada por cascata ÚNICA/DEBIT)
    ID_PARC VARCHAR(6),                 -- 'ADESÃO', 'ÚNICA', '01/12'..'12/12', 'MM/YY', 'DEBIT'
    VALOR_COMP NUMERIC(8, 2),           -- Tarifa bancária de compensação/liquidação (VALOR LIQUIDO = VALOR_PAGO - VALOR_COMP)
    REGISTRADO VARCHAR(1),              -- Status CNAB 240 Sicoob: NULL/'N', 'S', 'B'
    NOSSONUMERO INTEGER,                -- Sequencial Sicoob sem DV (7 dígitos, gerado via GEN_NOSSONUMERO_ID)
    CONSTRAINT PK_PARCELAS PRIMARY KEY (NUM_ADESAO, ANOMES)
);

/* 11. Tabela: PESSOAJURIDICA (Empresas Contratantes - Planos Corporativos) */
CREATE TABLE PESSOAJURIDICA (
    NUMERO INTEGER NOT NULL,            -- Mesmo ID de ADESAO.NUMERO (relação 1:1)
    NOME VARCHAR(50) NOT NULL,
    CNPJ VARCHAR(18),
    INSCESTADUAL VARCHAR(20),
    INSCMUNICIPAL VARCHAR(20),
    ENDERECO VARCHAR(50) NOT NULL,
    BAIRRO VARCHAR(30) NOT NULL,
    CIDADE VARCHAR(30) NOT NULL,
    ESTADO CHAR(2),
    CEP CHAR(9),
    END_NUMERO VARCHAR(6),
    COMPLEMENTO VARCHAR(20),
    TELEFONE_COMERCIAL VARCHAR(13),
    TELEFONE_FAX VARCHAR(13),
    DIAVENC SMALLINT,                   -- Obrigatório entre 1 e 28
    TELEFONE_CEL VARCHAR(13),
    SITUACAO CHAR(1),                   -- 'A' (Ativo) ou 'C' (Cancelado)
    INSCRICAO DATE,
    CONTATO VARCHAR(50),
    OBS BLOB SUB_TYPE TEXT SEGMENT SIZE 80,
    CONSTRAINT PK_PESSOAJURIDICA PRIMARY KEY (NUMERO)
);

/* 12. Tabela: USUARIOS (Operadores do Sistema e Matriz RBAC de 14 Permissões 'SIM'/'NÃO') */
CREATE TABLE USUARIOS (
    NOME VARCHAR(50) NOT NULL,
    COD_EMPRESA INTEGER NOT NULL,
    APELIDO VARCHAR(10) NOT NULL,
    SENHA VARCHAR(10) NOT NULL,         -- Cifrada com XOR 0xC5 (chave "Acadêmico")
    EMPRESAS_DADOS CHAR(3) NOT NULL,
    EMPRESAS_CONSULTAR CHAR(3) NOT NULL,
    CLIENTES_CONSULTAR CHAR(3) NOT NULL,
    CLIENTES_DADOS CHAR(3) NOT NULL,
    BAIXA_MANUAL CHAR(3) NOT NULL,
    BAIXA_AUTOMATICA CHAR(3) NOT NULL,
    EMITIR_ARQUIVO CHAR(3) NOT NULL,
    EMITIR_ADESAO CHAR(3) NOT NULL,
    RELATORIOS CHAR(3) NOT NULL,
    MUDAR_CONEXAO CHAR(3) NOT NULL,
    USUARIOS_CONSULTAR CHAR(3) NOT NULL,
    USUARIOS_DADOS CHAR(3) NOT NULL,
    CANCELAR_PLANO CHAR(3) NOT NULL,
    CONVENIOS_DADOS CHAR(3) NOT NULL,
    CONVENIOS_CONSULTAR CHAR(3) NOT NULL,
    CONSTRAINT UK_USUARIOS UNIQUE (APELIDO)
);

/* Índices secundários originais */
CREATE INDEX IDX_CARNE_NUMERO ON CARNE (NUMERO, REMESSA);
CREATE INDEX IDX_CLIENTES_PRINCIPAL ON CLIENTES (NUMERO, SITUACAO, COD_CONVENIO);
CREATE INDEX IDX_CLIENTES_SITUACAO ON CLIENTES (SITUACAO, NUMERO);
CREATE INDEX IDX_PARCELAS_ANOMES_DTPAG ON PARCELAS (NUM_ADESAO, ANOMES, DTPAG, ID_PARC);
CREATE INDEX IDX_PARCELAS_DTPAG_DTVENC_ID ON PARCELAS (DTPAG, DTVENC, ID_PARC, NUM_ADESAO);
CREATE INDEX IDX_PARCELAS_NUM_ADESAO ON PARCELAS (NUM_ADESAO, DTPAG, DTVENC);
CREATE INDEX IDX_PARCELAS_PAGAS ON PARCELAS (DTPAG, NUM_ADESAO, DTVENC, ID_PARC);
CREATE INDEX IDX_PARCELAS_VENCIDAS ON PARCELAS (DTPAG, DTVENC, ID_PARC, NUM_ADESAO);

/* Chaves Estrangeiras (11 FKs) */
ALTER TABLE ADESAO ADD CONSTRAINT FK_ADESAO_EMPRESA FOREIGN KEY (COD_EMPRESA) REFERENCES EMPRESA (CODIGO) ON UPDATE CASCADE;
ALTER TABLE CARNE ADD CONSTRAINT FK_CARNE_ADESAO FOREIGN KEY (NUM_ADESAO) REFERENCES ADESAO (NUMERO) ON UPDATE CASCADE;
ALTER TABLE CLIENTES ADD CONSTRAINT FK_CLIENTES_ADESAO FOREIGN KEY (NUMERO) REFERENCES ADESAO (NUMERO) ON UPDATE CASCADE;
ALTER TABLE CLIENTES ADD CONSTRAINT FK_CLIENTES_CONVENIOS FOREIGN KEY (COD_CONVENIO) REFERENCES CONVENIOS (COD_CONVENIO) ON UPDATE CASCADE;
ALTER TABLE DEPENDENTES ADD CONSTRAINT FK_CLIENTES_DEPENDENTES FOREIGN KEY (COD_CLIENTE) REFERENCES CLIENTES (NUMERO) ON UPDATE CASCADE;
ALTER TABLE DEPFUNCPESSOAJURIDICA ADD CONSTRAINT FK_DEPFUNCPESSOAJURIDICA FOREIGN KEY (CODIGOFUNC) REFERENCES FUNCIONARIOSPESSOAJURIDICA (CODIGOFUNC) ON DELETE CASCADE;
ALTER TABLE FUNCIONARIOSPESSOAJURIDICA ADD CONSTRAINT FK_FUNCPESSOAJURIDICA FOREIGN KEY (CODIGOPESSOAJURIDICA) REFERENCES PESSOAJURIDICA (NUMERO) ON DELETE CASCADE;
ALTER TABLE PARCELAS ADD CONSTRAINT FK_PARCELAS_ADESAO FOREIGN KEY (NUM_ADESAO) REFERENCES ADESAO (NUMERO) ON UPDATE CASCADE;
ALTER TABLE PARCELAS ADD CONSTRAINT FK_PARCELAS_CARNE FOREIGN KEY (NUM_CARNE) REFERENCES CARNE (NUMERO) ON UPDATE CASCADE;
ALTER TABLE PESSOAJURIDICA ADD CONSTRAINT FK_PESSOAJURIDICA_ADESAO FOREIGN KEY (NUMERO) REFERENCES ADESAO (NUMERO) ON UPDATE CASCADE;
ALTER TABLE USUARIOS ADD CONSTRAINT FK_USUARIOS_EMPRESAS FOREIGN KEY (COD_EMPRESA) REFERENCES EMPRESA (CODIGO) ON UPDATE CASCADE;
