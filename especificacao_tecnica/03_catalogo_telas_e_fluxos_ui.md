# 03 — Catálogo Completo de Telas, Fluxos de UI, Permissões (RBAC) e Mapeamento Web

> **Origem da Engenharia Reversa:** Extração integral dos **43 recursos `.dfm`** embutidos no executável `SGCeFeGe.exe` (via `rea-agents` + parser binário de recursos Delphi 7), combinada com a descompilação completa das **36 units de aplicação** (`3.966` procedimentos analisados no `kuna`).

---

## 1. Inventário Geral dos 43 Recursos `.dfm`

O binário `SGCeFeGe.exe` contém **43 recursos `RCData` de formulários/módulos Delphi**:
- **2 DataModules (`TDataModule`):** `TDM` e `TDMPessoaJuridica` (concentram conexões Firebird, transações, `TIBDataSet`, `TIBQuery`, `TADOConnection` para Excel e integrações Rave Reports).
- **33 Formulários Customizados da Aplicação (`TForm`):** Telas operacionais, cadastrais, financeiras, de consulta, diagnóstico e parâmetros de relatórios.
- **8 Diálogos Padrão de Runtime (VCL / Nevrona Rave Reports):** `TLoginDialog`, `TPasswordDialog`, `TCustomPreviewForm`, `TCustomSetupForm`, `TCustomStatusForm`, `TRavePreviewForm`, `TRPSetupForm`, `TRPStatusForm`.

> **Nota sobre ícones `.bmp` na pasta do sistema:** Os arquivos `atualizar.bmp`, `Cancelar.bmp`, `Consultar.bmp`, `Excluir.bmp`, `Fechar.bmp`, `fg.bmp` e `novo.bmp` eram utilizados como glifos de `TBitBtn`/`TSpeedButton` e logotipos na VCL legada. Conforme diretriz do projeto, **não serão utilizados** no novo sistema web, devendo ser substituídos por ícones vetoriais modernos (`Lucide Icons` ou `Heroicons`) com rótulos acessíveis (`aria-label`).

---

## 2. Módulos de Dados (`DataModules`) e Regras Persistentes de `TField`

### 2.1 `TDM` (`01_UDM.c` / `TDM.dfm`)
Módulo central instanciado na inicialização do sistema:
- **`IBADM` (`TIBDatabase`):** Caminho padrão de desenvolvimento `D:\Abac(prog)\ABAC.FDB`, `SQLDialect = 3`, credenciais padrão `user_name=SYSDBA`, `password=masterkey` (sobrescritas em tempo de execução pelo caminho salvo no Registro do Windows).
- **`IBTADM` (`TIBTransaction`):** Isolamento `read_committed`, `rec_version`, `nowait`.
- **`ADOCnt` / `ADOQry` (`TADOConnection` / `TADOQuery`):** Provedor `Microsoft.Jet.OLEDB.4.0; Extended Properties=Excel 8.0` usado exclusivamente na importação de baixas via planilha `.xls`.
- **`RvProject` / `RvSystem` / `RvRenderPDF`:** Aponta em design-time para `D:\Desenvolvimento\SGCeFeGe\CARNE\Relatorios.rav` (em produção carrega `ExtractFilePath(Application.ExeName) + 'Relatorios.rav'`) e expõe **9 conexões `TRvDataSetConnection`**.

#### Regras de `TField` Persistentes em `TDM`:
| Dataset (`TIBDataSet` / `TIBQuery`) | Tabela Base / Gerador (`GeneratorField`) | Campos com `Tag = 1` ou `Required = True` (Validação Obrigatória) | Máscaras (`EditMask` / `DisplayFormat`) e Campos Calculados |
|---|---|---|---|
| `IBDEmpresa` / `IBDEmpresaAtiva` | `EMPRESAS` (sem sequence; PK `CNPJ_EMPRESA`) | `CNPJ_EMPRESA` (`Required`), `NOME_EMPRESA` (`Tag=1`), `ENDERECO` (`Tag=1`), `BAIRRO` (`Tag=1`), `CIDADE` (`Tag=1`), `ESTADO` (`Tag=1`), `CEP` (`Tag=1`), `TELEFONE_COMERCIAL` (`Tag=1`) | `CNPJ_EMPRESA`: `99.999.999/9999-99`; `CEP`: `99999-999`; `PERCENTMULTA` / `JUROSDIA`: `#0.00` |
| `IBDUsuarios` | `USUARIOS` (PK `APELIDO`) | `APELIDO` (`Required`, `Tag=1`), `NOME` (`Tag=1`), `SENHA` (`Tag=1`) + 15 colunas de permissão (`SIM`/`NÃO`) | `SENHA` cifrada em memória/banco via `XOR 0xC5` |
| `IBDConvenios` | `CONVENIOS` (`GEN_CONVENIOS_ID` -> `COD_CONVENIO`, `OnPost`) | `CNPJ` (`Tag=1`), `NOME` (`Required`, `Tag=1`), `ENDERECO` (`Tag=1`), `BAIRRO` (`Tag=1`), `CIDADE` (`Tag=1`), `ESTADO` (`Tag=1`), `CEP` (`Tag=1`), `END_NUMERO` (`Tag=1`), `TELEFONE_COMERCIAL` (`Tag=1`) | `CEP`: `99999-999`; Fones: `!(99)9999-9999;1;_`; `PERC_COM`: percentual de comissão |
| `IBDAdesao` | `ADESAO` (`GEN_NUMERO_ID` -> `NUMERO`, `OnNewRecord`) | `NUMERO` (`Required`) | Inteiro sequencial compartilhado entre PF e PJ |
| `IBDClientes` | `CLIENTES` (PK `NUMERO` -> FK `ADESAO.NUMERO`) | `NUMERO` (`Required`, `Tag=1`), `NOME` (`Tag=1`), `CPF` (`Tag=1`), `RG` (`Tag=1`), `ENDERECO` (`Tag=1`), `BAIRRO` (`Required`, `Tag=1`), `CIDADE` (`Tag=1`), `ESTADO` (`Tag=1`), `CEP` (`Tag=1`), `TELEFONE_COMERCIAL` (`Tag=1`), `TELEFONE_FAX` (`Tag=1`), `DIAVENC` (`Tag=1`), `DATA_NASC` (`Tag=1`), `NOME_MAE` (`Tag=1`), `EST_CIVIL` (`Tag=1`), `SEXO` (`Tag=1`), `SITUACAO` (`Tag=1`), `COD_CONVENIO` (`Required`) | `CPF`: `999.999.999-99;1;_`; `CEP`: `99999-999;1;_`; `DATA_NASC`/`INSCRICAO`: `!99/99/9999;1;_`; Fones: `!(99)9999-9999;1;_`; `VALOR_PLANO`: `R\$ #,##0.00`; Lookup `CASTRANTE` -> `IBDConvenios.NOME` |
| `IBDDependentes` | `DEPENDENTES` (`GEN_DEPENDENTES_ID` -> `CODIGO`, `OnNewRecord`) | `CODIGO` (`Required`), `COD_CLIENTE` (`Required`), `NOME` (`Required`), `PARENTESCO` (`Required`), `DATA_NASC` (`Required`) | `CPF`: `000.000.000-00;1;_`; `DATA_NASC`: `!99/99/9999;1;_` |
| `IBDCarne` | `CARNE` (`GEN_CARNE_ID` -> `NUMERO`, `OnNewRecord`) | `NUMERO` (`Required`), `NUM_ADESAO` (`Required`) | `DATA`: `dd/mm/yyyy` |
| `IBDParcelas` | `PARCELAS` (`GEN_NOSSONUMERO_ID` -> `NOSSONUMERO`, `OnNewRecord`) | `NUM_CARNE`, `NUM_ADESAO`, `ANOMES` | `VALOR`, `VALOR_PAGO`, `VALOR_COMP`: `R\$ #,##0.00`; Calculado (`OnCalcFields` @ `0x55d5dc`): `VALOR LIQUIDO = VALOR_PAGO - VALOR_COMP` |
| `IBDEnderecos` | `ENDERECOS` (`GEN_ENDERECOS_ID` -> `COD_END`) | Tabela órfã (`0` registros no banco real; não possui tela associada) | Descartada na modelagem moderna |

### 2.2 `TDMPessoaJuridica` (`23_UDMPessoaJuridica.c` / `TDMPESSOAJURIDICA.dfm`)
Módulo dedicado à carteira corporativa (Pessoa Jurídica):
- **`IBDPessoaJuridica`:** Tabela `PESSOAJURIDICA`, `GeneratorField` = `GEN_NUMERO_ID -> NUMERO` (`OnNewRecord`). Campos obrigatórios (`Tag=1`): `NUMERO`, `NOME`, `CNPJ` (`99.999.999/9999-99`), `INSCESTADUAL`, `INSCMUNICIPAL`, `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO`, `CEP`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX`, `TELEFONE_CEL`, `DIAVENC`, `SITUACAO`, `INSCRICAO`, `CONTATO`.
- **`IBDFuncionariosPessoaJuridica`:** Tabela `FUNCIONARIOSPESSOAJURIDICA`, `GeneratorField` = `GEN_CODIGOFUNC_ID -> CODIGOFUNC` (`OnNewRecord`). Campos `Tag=1`: `NOME`, `CPF`, `RG`, `DATA_NASC`, `SEXO`, `EST_CIVIL`, `NOME_MAE`, `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO`, `CEP`, `TELEFONE_COMERCIAL`, `TELEFONE_RESIDENCIAL`, `TELEFONE_CEL`, `VALOR_PLANO`, `SITUACAO`, `INSCRICAO`.
- **`IBDDepFuncPessoaJuridica`:** Tabela `DEPFUNCPESSOAJURIDICA`, `GeneratorField` = `GEN_CODIGODEPFUNC_ID -> CODIGODEPFUNC` (`OnNewRecord`).
- **`IBQryRelPessoaJuridica`:** Query pronta mas nunca conectada a relatório visual:
  ```sql
  SELECT PJ.NUMERO, NOME, P.*, (P.VALOR_PAGO - P.VALOR_COMP) AS "VL LIQUIDO"
  FROM PESSOAJURIDICA PJ, PARCELAS P
  WHERE PJ.NUMERO = P.NUM_ADESAO
  ORDER BY P.NUM_ADESAO, P.ANOMES
  ```

---

## 3. Árvore de Menus, Barra de Ferramentas e Colisões de Atalhos

Na janela principal `TFrmPrincipal` (`"Gestão de Carnês"`, `764x515`), há uma barra superior (`BarraBotoes`), um seletor de empresa ativa (`DBEmpresa`), o indicador da próxima geração agendada (`EData` = `EMPRESAS.DATA_ARQ`) e o `MainMenu1`:

| Menu Superior | Item (`Name`) | Rótulo na Tela (`Caption`) | Atalho Legado | Formulário / Ação Disparada | Observações e Bugs Legados |
|---|---|---|---|---|---|
| **Arquivos** | `MEmpresas` | `Empresa` | `Ctrl+E` | `TFrmEmpresas` | Requer `EMPRESAS_CONSULTAR = 'SIM'` |
| **Arquivos** | `MComissionados` | `Comissionados` | *(sem atalho)* | `TFrmConsultaConvenios` -> `TFrmConvenios` | Requer `CONVENIOS_CONSULTAR = 'SIM'` |
| **Arquivos** | `MClientes` | `CLientes` *(sic)* | `Ctrl+C` | `TFrmConsultaClientes` -> `TFrmClientes` | Requer `CLIENTES_CONSULTAR = 'SIM'` (conflita com copiar área de transferência no desktop) |
| **Arquivos** | `MPessoaJurdica` | `Clientes Pessoa Jurídica` | `Ctrl+J` | `TFrmConsultaPessoaJuridica` -> `TFrmCadastroPessoaJuridica` | **BUG RBAC:** Não verificado em `Uprincipal__fn_5b11d8` (sempre habilitado) |
| **Movimentação** | `MAdesao` | `Criar ficha de Adesão` | `Ctrl+Shift+A` | `TFrmAdesao` | Requer `EMITIR_ADESAO = 'SIM'` |
| **Movimentação** | `MGerarCarnes` | `Gerar arquivo de Carnês` | `Ctrl+Shift+C` | `TFrmCarne` | Requer `EMITIR_ARQUIVO = 'SIM'`. **COLISÃO DE ATALHO #1** com `RelatoriogeraldeClientes1` |
| **Movimentação** | `MBoletoBancario` | `Gerar Boleto Bancário` | `Ctrl+Shift+B` | `TFrmBoletoBancario` | **BUG RBAC:** Sempre habilitado |
| **Movimentação** | `RecuperarArquivo1` | `Recuperar Arquivo` | `Ctrl+R` | `TFrmRecuperarArquivo` | **BUG RBAC:** Sempre habilitado. **COLISÃO DE ATALHO #2** com `MContasaReceber` |
| **Movimentação** | `GerarRemessa1` | `Gerar Remessa` | *(sem atalho)* | `TfrmGerarRemessa` | **BUG RBAC:** Sempre habilitado |
| **Movimentação** | `MBaixaManual` | `Baixa Manual` | `Ctrl+M` | `TFrmBaixaManual` | Requer `BAIXA_MANUAL = 'SIM'` |
| **Movimentação** | `BaixaAutomatica` | `Baixa Automática` | `Ctrl+A` | `TFrmBaixaAutomatica` | Requer `BAIXA_AUTOMATICA = 'SIM'`. **COLISÃO DE ATALHO #3** com `MClientesAdimplentes` |
| **Movimentação** | `Cancelamentodeplanos1` | `Cancelamento de planos` | `Ctrl+P` | `TFrmCancelamento` | Menu sempre visível; botão `BCancelar` valida `PerCancelarPlano` (`CANCELAR_PLANO = 'SIM'`) |
| **Movimentação** | `MSegundaVia` | `Segunda Via` | `Ctrl+Shift+S` | `TFrmSegundaVia` | Requer `EMITIR_ARQUIVO = 'SIM'` |
| **Movimentação** | `MDiagnosticodeAdesao` | `Diagnóstico de Clientes/Numero de Adesão` | `Ctrl+Shift+D` | `TFrmDiagnostico` | **BUG RBAC:** Sempre habilitado |
| **Movimentação** | `GerarNossoNumero1` | `Gerar Nosso Numero ` | *(sem atalho)* | Execução direta em `TFrmPrincipal` | **BUG RBAC:** Sempre habilitado; faz backfill de `NOSSONUMERO IS NULL` |
| **Relatórios** | `MContasaReceber` | `Contas a Receber` | `Ctrl+R` | `TFrmRelatoriosContas` (`Tipo='RECEBER'`) | Requer `RELATORIOS = 'SIM'`. **COLISÃO #2** |
| **Relatórios** | `MContasRecebidas` | `Contas Recebidas` | `Ctrl+B` | `TFrmRelatoriosContas` (`Tipo='RECEBIDO'`) | Requer `RELATORIOS = 'SIM'` |
| **Relatórios** | `MComisses` | `Comissões` | *(sem atalho)* | `TFrmRelConvenios` | Requer `RELATORIOS = 'SIM'` |
| **Relatórios** | `RelatoriogeraldeClientes1` | `Geral de Clientes` | `Ctrl+Shift+C` | `TFrmRelGeralClientes` | **BUG RBAC:** Sempre habilitado! **COLISÃO #1** |
| **Relatórios** | `MClientesAdimplentes` | `Clientes Adimplentes` | `Ctrl+A` | `TFrmRelatoriosClientes` (`Tipo='ADIMPLENTES'`) | Requer `RELATORIOS = 'SIM'`. **COLISÃO #3** |
| **Relatórios** | `MClientesInadimplentes` | `Clientes Inadimplentes` | `Ctrl+I` | `TFrmRelatoriosClientes` (`Tipo='INADIMPLENTES'`) | Requer `RELATORIOS = 'SIM'` |
| **Relatórios** | `Relatorio1` | `Pessoa Juridica` | `Ctrl+Shift+J` | *(inacabado)* | `Visible = False` e sem handler `OnClick` no binário |
| **Sistema** | `MSobre` / `spdSobre` | `Sobre...` | `Ctrl+S` | `TFrmSobre` | Sempre habilitado |
| **Sistema** | `MCalculadora` / `spdCalculadora` | `Calculadora` | `F7` | `ShellExecute('calc.exe')` | Descartável na web |
| **Sistema** | `MCalendario` / `spdCalendario` | `Calendário` | `F8` | `TCalendario` | Substituído por datepickers nativos na web |
| **Sistema** | `MUsuarios` | `Usuários` | `Ctrl+U` | `TFrmConsultaUsuarios` -> `TFrmUsuarios` | Requer `USUARIOS_CONSULTAR = 'SIM'` |
| **Sistema** | `MMudarUsuario` / `spdMudarUsuario` | `Mudar de Usuário` | `F2` | `TFrmLogin` | Equivalente a Logout / Trocar sessão |
| **Sistema** | `MBackup` / `spdAlterarSenha` | `Alterar Senha` | `F3` | `TFrmAlterarSenha` | Nota: o `Name` interno do menu é `MBackup`, mas o texto e ação são `Alterar Senha`! |
| **Sistema** | `MMudarConexao` | `Mudar Conexão do Banco` | `Ctrl+X` | `TFrmConectar` | Requer `MUDAR_CONEXAO = 'SIM'`. Descartável no SaaS/Web |
| **Sistema** | `MFechar` / `spdFechar` | `Fechar` | `Ctrl+F4` | `Application.Terminate` | Encerrar sessão na web |

> **Easter Egg Operacional em `TFrmPrincipal.EDataMouseDown` (`0x5b0ea8`):** Ao segurar a tecla **`Shift` + Clique Esquerdo** sobre o campo somente-leitura `EData` no painel superior, o sistema exibe um `InputBox` permitindo alterar manualmente `EMPRESAS.DATA_ARQ` (data agendada para o próximo lote automático de carnês). Na versão web, isso deve ser um campo/ação explícita e auditada na tela de **Configurações da Empresa** (restrito a `perm_empresas_editar`).

---

## 4. Matriz Completa de Controle de Acesso (RBAC) — Legado vs. Web Moderno

A rotina `Uprincipal__fn_5b11d8` (`0x5b11d8..0x5b1590`) lê as 15 colunas `CHAR(3)` (`'SIM'` / `'NÃO'`) da tabela `USUARIOS` após o login e popula variáveis globais booleanas (`PerEmpDados`, `PerCliDados`, `PerUsuariosDados`, `PerConvDados`, `PerCancelarPlano`) além de habilitar/desabilitar itens do `MainMenu1`:

| Coluna em `USUARIOS` (Firebird) | Permissão no PostgreSQL Moderno (`02_schema_postgresql_moderno.sql`) | O que controla no Legado (`SGCeFeGe.exe`) | O que deve controlar na API/Web Moderna |
|---|---|---|---|
| `EMPRESAS_CONSULTAR` | `perm_empresas_consultar` | Habilita menu `MEmpresas` | `GET /api/v1/empresas` e visualização dos parâmetros bancários |
| `EMPRESAS_DADOS` | `perm_empresas_editar` | Habilita botão `BAlterar`/`BSalvar` em `TFrmEmpresas` (`PerEmpDados`) | `PUT /api/v1/empresas/{id}`, upload de logomarca e alteração de `DATA_ARQ` |
| `CLIENTES_CONSULTAR` | `perm_clientes_consultar` | Habilita menu `MClientes` | `GET /api/v1/clientes-pf` e consulta de dependentes/parcelas |
| `CLIENTES_DADOS` | `perm_clientes_editar` | Habilita `BNovo`, `BAlterar`, `BExcluir` em `TFrmConsultaClientes` e edição de dependentes (`PerCliDados`) | `POST/PUT/DELETE /api/v1/clientes-pf` e dependentes |
| *(sem coluna no legado — bug)* | `perm_pj_consultar` | Menu `MPessoaJurdica` ficava aberto a todos | `GET /api/v1/clientes-pj`, funcionários e dependentes PJ |
| *(sem coluna no legado — bug)* | `perm_pj_editar` | Usava parcialmente `PerCliDados` ou ficava aberto | `POST/PUT/DELETE /api/v1/clientes-pj`, funcionários, dependentes e faturamento PJ |
| `CONVENIOS_CONSULTAR` | `perm_convenios_consultar` | Habilita menu `MComissionados` | `GET /api/v1/comissionados` |
| `CONVENIOS_DADOS` | `perm_convenios_editar` | Habilita `BNovo`, `BAlterar`, `BExcluir` em `TFrmConsultaConvenios` (`PerConvDados`) | `POST/PUT/DELETE /api/v1/comissionados` |
| `USUARIOS_CONSULTAR` | `perm_usuarios_consultar` | Habilita menu `MUsuarios` | `GET /api/v1/usuarios` |
| `USUARIOS_DADOS` | `perm_usuarios_editar` | Habilita `BNovo`, `BAlterar`, `BExcluir` em `TFrmConsultaUsuarios` (`PerUsuariosDados`) | `POST/PUT/PATCH /api/v1/usuarios` e gestão de permissões RBAC |
| `EMITIR_ADESAO` | `perm_emitir_adesao` | Habilita menu `MAdesao` | `POST /api/v1/adesoes/lote` e download de `REMADESAO` |
| `EMITIR_ARQUIVO` | `perm_emitir_carne` | Habilita menus `MGerarCarnes` e `MSegundaVia` | `POST /api/v1/carnes/lote`, fila de 2ª via (`SEG_VIA_*`) e reemissão (`Recuperar Arquivo`) |
| *(sem coluna no legado — bug)* | `perm_gerar_remessa_cnab` | Menu `GerarRemessa1` e `GerarNossoNumero1` ficavam abertos a todos | Consolidação `DEBIT`, geração de CNAB 240 Sicoob (`01` e `02`), remessa gráfica avulsa e backfill de Nosso Número |
| `BAIXA_MANUAL` | `perm_baixa_manual` | Habilita menu `MBaixaManual` | Liquidação e estorno manual de parcelas (`POST /api/v1/parcelas/{id}/baixa-manual`, `/estorno`) |
| `BAIXA_AUTOMATICA` | `perm_baixa_automatica` | Habilita menu `BaixaAutomatica` | Upload e processamento de retorno CNAB 240 (Caixa/Sicoob) e planilhas Excel |
| `CANCELAR_PLANO` | `perm_cancelar_plano` | Habilita efetivação em `TFrmCancelamento` (`PerCancelarPlano`) | Cancelamento formal de plano (`POST /api/v1/clientes-pf/{numero}/cancelar`) |
| `RELATORIOS` | `perm_relatorios` | Habilita 5 dos 6 relatórios (exceto `RelatoriogeraldeClientes1`, esquecido aberto) | Todos os 7 relatórios gerenciais/financeiros (incluindo Geral de Clientes e PJ) |
| `MUDAR_CONEXAO` | *(obsoleto na web)* | Habilita `MMudarConexao` (`TFrmConectar`) | Substituído por `perm_auditoria_consultar` para consulta de logs de auditoria |

> **Bug adicional em `TFrmUsuarios` (`TabLicencas`):** Na aba `Licenças`, existe um 16º controle `ComboBox1` (`TComboBox` comum, não `TDBComboBox`!) ao lado do rótulo `"Alterar sua própria Senha"`, sem `DataField` vinculado no banco. Qualquer alteração feita nele pelo administrador era descartada silenciosamente ao salvar. Na aplicação web, todo usuário autenticado pode alterar sua própria senha (ou pode-se adicionar flag explícita `perm_alterar_propria_senha` com default `true`).

---

## 5. Catálogo Detalhado das 33 Telas Customizadas

### Grupo A — Infraestrutura, Sessão e Utilitários

#### T01. `TFrmSplash` (`USplash_and_DPR` — `401x198`)
- **Função Legada:** Tela de abertura exibida durante a criação dos DataModules e formulários, contendo `"Gestão de Carnês"`, `"Versão 1.1.14"` (notar divergência com `"Versão 1.0"` em `TFrmSobre`) e barra `GProgresso`.
- **Equivalente Web:** Desnecessário (substituído por skeleton/loading state do SPA).

#### T02. `TFrmConectar` (`UConectar` — `"Conectar Banco de Dados"`, `303x211`)
- **Controles:** `CConexao` (`Local` | `Remoto`), `EIP` (exibido apenas se `Remoto`), `ECaminho` (seletor de arquivo `.FDB`), `EUsuario` (`"SYSDBA"`), `ESenha` (`"masterkey"`), `BConectar`, `BCancelar`.
- **Regra Legada:** Concatena `{EIP}:{ECaminho}` quando `Remoto`, grava o caminho ofuscado com `ULib__fn_57f498` (`XOR 0xC5`) em `HKCU\Software\FG\SGC\Caminho` e abre `DM.IBADM`.
- **Equivalente Web:** **Eliminado.** A conexão com o PostgreSQL online é gerenciada exclusivamente no backend via variáveis de ambiente (`DATABASE_URL`) e pool de conexões seguro.

#### T03. `TFrmLogin` (`ULogin` — `"Login"`, `285x75`)
- **Controles:** `EUsuario` (`Digite seu Apelido:`), `ESenha` (`MaxLength = 10`), `BOK ("Conectar")`, `BCancelar`.
- **Regra Legada:** Busca `SELECT * FROM USUARIOS WHERE APELIDO = :apelido` (ou `Locate`), aplica `ULib__fn_57f498(ESenha)` e compara com `USUARIOS.SENHA`. Em caso de falha: `"Senha ou Apelido incorretos!"`. Três timers em `TFrmPrincipal` gerenciam reconexão e login inicial.
- **Equivalente Web (`/login`):** Autenticação via `POST /api/v1/auth/login` com `apelido` + `senha` (sem limite artificial de 10 caracteres; mínimo 8 e máximo 128 caracteres), hash **Argon2id/BCrypt**, emissão de **JWT Access Token + Refresh Token HttpOnly**, bloqueio progressivo contra força bruta (rate limiting) e fluxo de troca obrigatória de senha no primeiro acesso pós-migração.

#### T04. `TFrmPrincipal` (`Uprincipal` — `"Gestão de Carnês"`, `764x515`)
- **Controles:** `BarraBotoes` (`Sobre...`, `Calculadora`, `Calendário`, `Alterar Senha`, `Mudar de Usuário`, `Fechar`), `DBEmpresa` (seleciona a empresa ativa em `EMPRESAS`), `EData` (exibe `EMPRESAS.DATA_ARQ`), `StatusBar1` (exibe usuário logado, data/hora via `TTempoTimer`).
- **Regra de Agendamento Automático (`FormShow` / `TConectar`):** Se `Date >= EMPRESAS.DATA_ARQ` e o usuário possuir permissão, pergunta/dispara lembrete de geração periódica de carnês e avança `DATA_ARQ` via `ULib__fn_57f598` (`+15` dias dentro do mês ou dia `15` do mês seguinte quando `Day >= 15`).
- **Equivalente Web (`/dashboard`):** Dashboard executivo com KPIs em tempo real (clientes PF/PJ ativos, inadimplência do mês, contas a receber x recebidas no mês, carnês a vencer e status do próximo ciclo de geração), seletor multiempresa no topo e menu lateral responsivo filtrado por RBAC.

#### T05. `TFrmAlterarSenha` (`UAlterarSenha` — `"Alterar sua própria senha"`, `478x332`)
- **Controles:** `EApelido`, `ESenha` (atual), `ENovaSenha`, `EConfirmacao`, `BConfirmar ("Alterar")`, `BCancelar`.
- **Regra Legada:** Confere `EApelido` + `ESenha` atual, exige `ENovaSenha = EConfirmacao` não vazia, aplica `XOR 0xC5` e faz `Post` + `CommitRetaining` em `USUARIOS`.
- **Equivalente Web (`/perfil/alterar-senha`):** Modal/página autenticada (`POST /api/v1/auth/change-password`) exigindo senha atual e política mínima de complexidade.

#### T06. `TFrmSobre` (`USobre` — `"Sobre"`, `430x320`)
- **Controles:** Exibe metadados legados (`"Versão 1.0"`, Desenvolvedor `"Jayme Barbosa"`, `"jaymebarbosa@gmail.com"`, Empresa `"FGDigital LTDA Tel: (32)3216-3188"`, `"fgdigital@fgdigital.com.br"`) e estatísticas de memória RAM / versão do Windows.
- **Equivalente Web:** Rodapé/modal `"Sobre o Sistema"` exibindo versão da release web, status da API e ambiente.

#### T07–T09. `TCalendario`, `TFrmSetPath`, `TFrmObrigatorios`
- **`TCalendario` (`400x156`):** Utilitário visual `TMonthCalendar`. Substituído por componentes de data HTML5/`shadcn` na web.
- **`TFrmSetPath` (`240x323`):** `TShellTreeView` para escolher `EMPRESAS.DIRARQUIVO`. Na web, arquivos gerados são armazenados em Object Storage/banco (`lotes_arquivos`) e baixados via navegador (`Content-Disposition: attachment`).
- **`TFrmObrigatorios` (`263x350`):** Modal genérico invocado por `ULib__fn_57f1ac` sempre que algum controle/campo com `Tag = 1` ou `Required = True` está em branco ao salvar, listando os rótulos pendentes em `LLista`. Na web, substituir por validação inline por campo (`React Hook Form` + `Zod`) + sumário acessível de erros no formulário.

---

### Grupo B — Cadastros Base (`Arquivos` e `Sistema -> Usuários`)

#### T10. `TFrmEmpresas` (`UEmpresas` — `"Empresa"`, `630x338`)
- **Aba `Dados da Empresa`:**
  - Identificação e Endereço: `CNPJ_EMPRESA` (PK, valida `ValidarCpfCnpj`), `NOME_EMPRESA` (Razão Social), `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO` (UF), `CEP`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX`, `LOGOMARCA` (`TDBImage` `.bmp` carregado via `OpenPictureDialog1`), `DIRARQUIVO`.
  - Grupo `Configurações Sicoob` (`grp1`): `AG_BANCOB` (Agência, 4/5 dígitos), `DVAG` (DV Agência, 1 dígito), `CONTA_BANCOB` (Conta Corrente), `DVCONTA_BANCOB` (DV Conta), `CODCED_BANCOB` (Código do Cedente/Beneficiário — usado no cálculo do DV do Nosso Número Sicoob!), `CARTEIRA_BANCOB` (ex.: `1`), `MODALIDADE_BANCOB` (ex.: `01` ou `02`), `PERCENTMULTA` (`%` de multa após vencimento no Segmento `R`), `JUROSDIA` (`R\$` mora diária no Segmento `P`).
- **Ações:** `BAlterar` (habilita `TabDados` se `PerEmpDados`), `BSalvar` (`F5`), `BCancelar` (`ESC`), `BFechar`. Note que não há botão `Novo` ou `Excluir` na tela legada — a empresa era pré-cadastrada e apenas editada, embora o banco suporte múltiplas empresas. Na web (`/empresas`), permitir CRUD multiempresa para administradores globais.

#### T11 & T12. `TFrmConsultaUsuarios` (`550x291`) e `TFrmUsuarios` (`"Usuários"`, `625x340`)
- **Fluxo de Consulta (`TFrmConsultaUsuarios`):** Filtro dinâmico por `CCampo` (`NOME` ou `APELIDO`) + `ETexto` (`UPPER(campo) LIKE UPPER('%texto%')`), grade `DBGrid1` (`NOME`, `APELIDO`) e botões `BNovo (Insert)`, `BAlterar (Home)`, `BExcluir (Delete)`, `BFiltrar (F3)`, `BConfirmar (F5)`, `BFechar (ESC)`.
- **Fluxo de Edição (`TFrmUsuarios`):**
  - `TabDados`: `NOME` (Nome Completo), `APELIDO` (Login único, PK), `ESenha` (campo de edição que grava em `SENHA` cifrado com `XOR 0xC5`).
  - `TabLicencas`: 6 grupos de `TDBComboBox` (`SIM` / `NÃO`):
    - **Movimentação:** `BAIXA_MANUAL`, `BAIXA_AUTOMATICA`, `EMITIR_ARQUIVO`, `EMITIR_ADESAO`, `CANCELAR_PLANO`.
    - **Empresa:** `EMPRESAS_CONSULTAR`, `EMPRESAS_DADOS`.
    - **Clientes:** `CLIENTES_CONSULTAR`, `CLIENTES_DADOS`.
    - **Usuários:** `USUARIOS_CONSULTAR`, `USUARIOS_DADOS`, além do `ComboBox1` órfão (`Alterar sua própria Senha`).
    - **Sistema:** `RELATORIOS`, `MUDAR_CONEXAO`.
    - **Conveniados:** `CONVENIOS_CONSULTAR`, `CONVENIOS_DADOS`.
- **Equivalente Web (`/usuarios`):** Listagem paginada com busca instantânea, perfis pré-definidos (ex.: *Administrador*, *Financeiro*, *Atendimento*, *Somente Consulta*) que preenchem automaticamente os 18 switches granulares de permissão, e inativação lógica (`ativo = false`) em vez de exclusão física quando houver eventos auditados.

#### T13 & T14. `TFrmConsultaConvenios` (`565x337`) e `TFrmConvenios` (`"Cadastrantes"`, `638x362`)
- **Domínio:** Apesar da tabela chamar-se `CONVENIOS`, na interface e nos relatórios a entidade é denominada **Comissionados / Cadastrantes** (vendedores, representantes ou parceiros comerciais que angariam clientes PF e recebem percentual sobre as mensalidades pagas).
- **Campos (`TFrmConvenios`):** `CNPJ` (Rótulo `"Cnpj/CPF"` — aceita CPF de 11 dígitos ou CNPJ de 14 dígitos validado por `ValidarCpfCnpj`!), `NOME` (`"Razão Social"`), `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO`, `CEP`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX`, `PERC_COM` (`"Comissão (%)"`, ex.: `5,00` ou `10,00`). `COD_CONVENIO` é gerado por `GEN_CONVENIOS_ID`.
- **Regra de Exclusão:** Bloqueada por FK `FK_CLIENTES_1` caso existam clientes vinculados ao cadastrante (na web, oferecer inativação lógica e mensagem amigável listando quantos clientes estão vinculados).
- **Equivalente Web (`/comissionados`):** CRUD completo com máscara dinâmica CPF/CNPJ e histórico de clientes captados e comissões geradas.

#### T15 & T16. `TFrmConsultaClientes` (`558x313`) e `TFrmClientes` (`"Cadastro de Clientes"`, `711x337`)
- **Fluxo de Consulta (`TFrmConsultaClientes`):**
  - Grade com 23 colunas (`NUMERO`, `NOME`, `CPF`, `RG`, `ENDERECO`, `BAIRRO`, `CIDADE`, `ESTADO`, `CEP`, `END_NUMERO`, `COMPLEMENTO`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX`, `TELEFONE_CEL`, `DIAVENC`, `DATA_NASC`, `NOME_MAE`, `EST_CIVIL`, `SEXO`, `VALOR_PLANO`, `SITUACAO`, `INSCRICAO`, `CASTRANTE`).
  - Busca parametrizável por qualquer campo `Tag=1` em `CCampo` + `ETexto`.
- **Fluxo de Cadastro/Edição (`TFrmClientes`):**
  - **Aba 1 — `Titular` (`TabTitular`):**
    - **`NUMERO` (`Nº Adesão`):** **NÃO é gerado automaticamente aqui!** O operador digita o número impresso na ficha física pré-gerada em `Criar ficha de Adesão`. No evento `DBAdesaoExit`, o sistema executa três validações críticas:
      1. Verifica se `NUMERO` existe na tabela `ADESAO` (`SELECT * FROM ADESAO WHERE NUMERO = :num`). Se não existir -> erro `"Número de adesão inválido / não encontrado!"`.
      2. Verifica se `NUMERO` já está em uso em `CLIENTES` (outro titular PF) ou em `PESSOAJURIDICA`.
    - **Dados Pessoais e Contato:** `NOME`, `CPF` (`ValidarCpfCnpj` no `DBCpfCnpjExit` + verificação de duplicidade em `CLIENTES`), `RG`, `DATA_NASC`, `SEXO` (`M` = Masculino, `F` = Feminino), `EST_CIVIL` (`Solteiro`, `Casado`, `Outro`), `NOME_MAE`, `EMAIL`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX` (rótulo na tela: **`Residencial`**!), `TELEFONE_CEL`.
    - **Endereço:** `CEP`, `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO` (`AC..TO`).
    - **Dados Contratuais e Cobrança:**
      - `DIAVENC`: Combo `1` a `28` (nunca permite `29`, `30` ou `31` para evitar estouro em fevereiro!).
      - `VALOR_PLANO`: Valor informativo do plano (o cálculo real na geração de carnês usa `ValorTitular + N_Dep * ValorDep`, mas `VALOR_PLANO` aparece nos relatórios cadastrais e tela de cancelamento).
      - `SITUACAO`: RadioGroup `&Ativo` (`A`) / `&Inativo` (`I`). *(Nota: quando cancelado via `TFrmCancelamento`, assume `'C'`, que não consta no RadioGroup da tela de cadastro — na web, exibir claramente os 3 estados `Ativo`, `Inativo` e `Cancelado`).*
      - `INSCRICAO`: Preenchido automaticamente com a data corrente na inclusão (`Enabled = False`), e `DATA_ATUALIZACAO` atualizado no salvamento.
      - `COD_CONVENIO` (`Cadastrante`): `TDBLookupComboBox` apontando para `CONVENIOS`.
      - `BANCO` (`Cobrança` — `Rbanco`): Itens legados `["&SICAP", "&SIGCB"]` mapeados para `'1'` (Caixa Econômica Federal) e `'2'` (Sicoob/Bancoob). *(Documentado no catálogo de peculiaridades: na tela de cliente o desenvolvedor manteve os nomes antigos dos convênios Caixa `SICAP`/`SIGCB` nos dois botões de rádio, onde a 1ª opção grava `'1'` e a 2ª opção grava `'2'` = Sicoob! Na web, rotular explicitamente `1 - Caixa Econômica` e `2 - Sicoob`).*
  - **Aba 2 — `Dependentes` (`TabSheet1`):**
    - Grade `DBGrid1` (`NOME`, `CPF`, `DATA_NASC`, `PARENTESCO`) filtrada por `COD_CLIENTE = CLIENTES.NUMERO`.
    - Controles de inclusão rápida: `ENome`, `medtEcpf` (valida CPF se preenchido), `ENasc` (`!99/99/9999`), `CParentesco` (`CÔNJUGE`, `PAI/MÃE`, `TIO(A)`, `FILHO(A)`, `NETO(A)`, `IRMÃO(A)`, `PRIMO(A)`, `SOGRO(A)`, `NORA/GENRRO` *(corrigir grafia para `NORA/GENRO` na UI mantendo compatibilidade)*, `CUNHADO(A)`, `OUTRO`), botões `BAdcionarItem ("Adcionar")` e `RemoverItem ("Remover")`.
- **Equivalente Web (`/clientes-pf` e `/clientes-pf/:numero`):** Visão 360º do cliente PF com abas **Dados do Titular**, **Dependentes**, **Carnês e Parcelas** (histórico financeiro completo), **2ª Via** e **Diagnóstico**, além de busca automática de CEP (ViaCEP) e opção de reservar automaticamente um novo `NUMERO` de adesão caso o cliente esteja sendo cadastrado diretamente online sem ficha física pré-impressa.

#### T17, T18 & T19. `TFrmConsultaPessoaJuridica` (`562x343`), `TFrmCadastroPessoaJuridica` (`723x438`) e `TFrmCadastroFuncPessoaJuridica` (`711x413`)
- **Fluxo de Consulta (`TFrmConsultaPessoaJuridica`):** Grade de empresas clientes (`PESSOAJURIDICA`) com filtro dinâmico `CCampo`/`ETexto` e ações `Novo`, `Alterar`, `Excluir`, `Filtrar`.
- **Fluxo de Cadastro PJ (`TFrmCadastroPessoaJuridica` — 3 Abas):**
  - **Aba 1 — `Empresa Cliente` (`TabTitular`):**
    - Diferente de PF, ao clicar em `Novo`, o próprio sistema gera `PESSOAJURIDICA.NUMERO` via `GEN_NUMERO_ID` **e insere automaticamente o registro correspondente na tabela `ADESAO`** (`INSERT INTO ADESAO (NUMERO) VALUES (:num)`) para satisfazer a integridade referencial das parcelas!
    - Campos: `NUMERO` (somente leitura), `CNPJ` (validado), `NOME` (Razão Social), `INSCESTADUAL`, `INSCMUNICIPAL`, `CONTATO`, `DIAVENC` (`1..28`), `SITUACAO` (`A`/`I`), `INSCRICAO`, `ENDERECO`, `END_NUMERO`, `COMPLEMENTO`, `BAIRRO`, `CIDADE`, `ESTADO`, `CEP`, `TELEFONE_COMERCIAL`, `TELEFONE_FAX`, `TELEFONE_CEL` (`Fone Contato`), `OBS` (`TDBMemo`).
  - **Aba 2 — `Funcionario (Titular)` (`TabFuncionarios`):**
    - Lista todos os funcionários vinculados (`CODIGOPESSOAJURIDICA = PESSOAJURIDICA.NUMERO`) com filtro próprio e botões `Novo`, `Alterar`, `Excluir` que abrem o modal **`TFrmCadastroFuncPessoaJuridica` (`T19`)**.
    - Campos de `TFrmCadastroFuncPessoaJuridica`: `CODIGOFUNC` (auto via `GEN_CODIGOFUNC_ID`), `NOME`, `CPF` (validado), `RG`, `DATA_NASC`, `SEXO`, `EST_CIVIL`, `NOME_MAE`, `VALOR_PLANO` (**valor individual mensal deste funcionário que compõe a fatura da empresa PJ!**), `SITUACAO` (`A`/`I`), `INSCRICAO` e endereço/telefones completos (`TELEFONE_RESIDENCIAL`, `TELEFONE_COMERCIAL`, `TELEFONE_CEL`).
  - **Aba 3 — `Dependentes` (`TabDependentes`):**
    - Seletor `CFuncionario` (escolhe qual funcionário titular da empresa PJ está selecionado) + grade `DBGrid1` (`DEPFUNCPESSOAJURIDICA` onde `CODIGOFUNC = selecionado`) + inclusão rápida (`ENome`, `ENasc`, `CParentesco`, `BAdcionarItem`, `RemoverItem`).
- **Equivalente Web (`/clientes-pj` e `/clientes-pj/:numero`):** Gestão hierárquica em 3 níveis (Empresa PJ -> Funcionários Titulares com resumo da folha mensal ativa -> Dependentes por funcionário) + aba financeira de faturas PJ.

---

### Grupo C — Movimentação Financeira, Geração de Arquivos e Cobrança

#### T20. `TFrmAdesao` (`UAdesao` — `"Criar Ficha de Adesao"`, `386x192`)
- **Controles:** `EQuantidade` (inteiro > 0), `DBEdit1` (`DIRARQUIVO`), `Rbanco` (`&SICOOB`), `BConfirmar (F5)`, `BFechar (ESC)`, `GProgresso`.
- **Fluxo Exato (`BConfirmarClick` @ `0x5937b0`):**
  1. Calcula próximo número de remessa de adesão: `SELECT MAX(REMESSA) FROM CARNE WHERE NUM_PARC = 1` -> `rem = COALESCE(MAX, 0) + 1`.
  2. Para `i = 1..Quantidade`:
     - Insere registro em `ADESAO` (`NUMERO` gerado por `GEN_NUMERO_ID`).
     - Insere registro em `CARNE` com `NUM_ADESAO = ADESAO.NUMERO`, `DATA = Date`, `NUM_PARC = 1`, `REMESSA = rem`.
     - Insere parcela de adesão em `PARCELAS` com `NUM_CARNE = CARNE.NUMERO`, `NUM_ADESAO = ADESAO.NUMERO`, `ANOMES = '0000'`, `ID_PARC = 'ADESÃO'`, `DTEM = Date`, `NOSSONUMERO` via `GEN_NOSSONUMERO_ID` (`DTVENC` e `VALOR` nulos — pois a ficha será preenchida em campo pelo vendedor).
  3. Grava o arquivo posicional de 250 colunas `REMADESAO{rem:05d}.TXT` em `DIRARQUIVO`.
- **Equivalente Web (`/adesoes/gerar-lote`):** Gera lote transacional no PostgreSQL, armazena o arquivo em `lotes_arquivos` e disponibiliza download imediato e histórico de lotes gerados.

#### T21. `TFrmCarne` (`UCarne` — `"Criar Arquivo de carnê"`, `408x276`)
- **Controles e Valores Default:**
  - `DBEdit1` (`DIRARQUIVO`), `Rbanco` (`&SICOOB`).
  - `eValorTitular`: default `"12,00"` (R\$ 12,00).
  - `eValorDep`: default `"2,00"` (R\$ 2,00 por dependente cadastrado em `DEPENDENTES`).
  - `edtParcelasEmAberto`: default `"0"` (tolerância máxima de parcelas vencidas em aberto para renovação de carnê).
  - `EValorAcrescimo`: default `"12,00"` (R\$ 12,00 somados apenas à **1ª parcela `01/12`** quando se trata de **renovação**, isto é, quando o cliente já possui carnê anterior de 12 parcelas!).
- **Fluxo Exato (`BConfirmarClick` @ `0x594698`):** Detalhado integralmente em `04_regras_negocio_financeiro_cnab_arquivos.md` (elegibilidade, cálculo de `12` parcelas mensais + `13ª` parcela `ÚNICA` com 20% de desconto e geração de `REMESSA{rem:07d}_{banco}.TXT` de 350 bytes/linha).
- **Equivalente Web (`/carnes/gerar-lote`):** Wizard obrigatório em 2 etapas (sempre aguardando confirmação do operador antes de executar a rotina): **1) Exibição das Configurações e Simulação/Prévia** (exibe os parâmetros vigentes do sistema/planos — valores de planos, Taxa de Manutenção Anual, desconto da `UNICA` aplicado apenas às mensalidades, tolerância de inadimplência — e lista quantos e quais clientes entrarão no lote, se é 1º carnê, pós-reativação isento ou renovação com Taxa de Manutenção Anual, valor da mensalidade e da parcela `UNICA`) -> **2) Confirmação Explícita e Geração dos PDFs** (carnês, etiquetas e carteirinhas).

#### T22. `TFrmBoletoBancario` (`UBoletoBancario` — `"Gerar Boleto Bancario"`, `409x232`)
- **Controles:** `DBEdit1` (`DIRARQUIVO`), `EMesAno` (`!99/99`, ex.: `10/26` para Outubro/2026), `BConfirmar (F5)`, `BFechar (ESC)`.
- **Fluxo Exato (`BConfirmarClick` @ `0x5a2f34`):** Faturamento mensal das empresas de `PESSOAJURIDICA` com `SITUACAO = 'A'`. Cria 1 carnê (`NUM_PARC = 1`) e 1 parcela (`ANOMES = AAMM`, `ID_PARC = '01/01'`, `DTVENC = DIAVENC/MM/20AA`, `VALOR = SUM(VALOR_PLANO dos funcionários)`) por empresa PJ elegível, gerando `REMESSA{rem:07d}.TXT` (350 bytes/linha) contendo registro `01` da empresa PJ, registros `02` dos funcionários (`TITULAR`) e seus dependentes, e registro `03` da fatura mensal.
- **Equivalente Web (`/faturamento-pj`):** Tela com prévia da folha por empresa PJ (corrigindo o bug legado para somar apenas funcionários com `SITUACAO = 'A'`) e geração do arquivo de cobrança/remessa CNAB.

#### T23. `TFrmRecuperarArquivo` (`URecuperaArquivo` — `"Recuperar Arquivo"`, `397x229`)
- **Controles:** `RadioGroupTipoRem`:
  - `0`: `Remessa de carne` -> Regrava `REMESSA{rem:07d}_{banco}.TXT` a partir de `CARNE WHERE REMESSA = :rem AND NUM_PARC = 12`.
  - `1`: `Remessa de adesão` -> Regrava `REMADESAO{rem:05d}.TXT` a partir de `CARNE WHERE REMESSA = :rem AND NUM_PARC = 1`.
  - `2`: `Números não usados (Adesão)` -> Exporta arquivo `REMADESAO` contendo todas as fichas em `ADESAO` que ainda não foram vinculadas nem a `CLIENTES` nem a `PESSOAJURIDICA`!
- **Equivalente Web (`/remessas/historico`):** Repositório central de todos os lotes gerados (download do arquivo original idêntico ou regeneração sob demanda + relatório de fichas de adesão disponíveis em estoque).

#### T24. `TfrmGerarRemessa` (`UArquivoRemessa` — `"Gerar Arquivo de Remessa"`, `682x415`)
Tela multifuncional crítica introduzida na migração para boletos registrados FEBRABAN/Sicoob, dividida em **3 abas**:
1. **Aba 1 — `Clientes Inadimplentes` (`ts1`):**
   - Filtra clientes ativos que possuem entre `1` e `edtParcelasEmAberto` (default `3`) parcelas vencidas em aberto (`DTPAG IS NULL AND DTVENC < CURRENT_DATE AND ID_PARC <> 'ÚNICA'`), usando `WITH cte_totalParcelasEmAberto AS (...)`.
   - Ao marcar `chkGerar ("Gerar parcela unica com total débitos em aberto.")`, habilita `dtpVencimento` (default `Hoje + 20 dias`) e `btnCalcularDebitosAgora ("Processar")`.
   - O processamento liquida contabilmente as parcelas atrasadas com `DTPAG = Hoje` e `VALOR_PAGO = 0` (para retirá-las da inadimplência sem inflar o caixa recebido!) e cria um novo carnê/parcela consolidada com `ANOMES = AA + '00'` (ex.: `'2600'`), `ID_PARC = 'DEBIT'`, `DTVENC = dtpVencimento` e `VALOR = soma das parcelas consolidadas`.
2. **Aba 2 — `Gerar Arquivo de Remessa` (`tsGerarRemessaGrafica`):**
   - Filtros: `dInicio`..`dFim` (intervalo de `DTVENC`), `dtpAdimplencia` (`Parcelas Quitadas Até:` — exclui clientes que possuam qualquer parcela comum não paga com `DTVENC < dtpAdimplencia`!), `rgOpcao` (`0 = Registrados` [`p.registrado = 'S'`], `1 = Não Registrados` [`p.registrado IS NULL OR p.registrado = 'N'`]).
   - Menu de contexto `pm1` na `GridBoletos`: `Selecionar Tudo` e **`Selecionar todos com CPF Válido`** (essencial porque o Sicoob rejeita no CNAB 240 registrado qualquer título cujo pagador tenha CPF inválido ou em branco!).
   - Botão `btnBConfirmar ("Gerar Remessa Banco")`: Abre `dlgSave` (default `C:\REMESSA001.txt`), gera arquivo **CNAB 240 Sicoob (`756`)** com movimento `'01'` (Entrada de Títulos — Segmentos `P`, `Q` e `R`) e marca `PARCELAS.REGISTRADO = 'S'` nos títulos selecionados.
   - Botão `BitBtn1 ("Gerar Remessa Gráfica")`: Gera arquivo posicional de 350 bytes para impressão avulsa apenas das parcelas selecionadas na grade (`00` Header + pares `01` Cliente e `03` Parcela + `99` Trailer).
3. **Aba 3 — `Gerar Remessa Baixa` (`tsGerarRemessaBaixa`):**
   - Filtros: `DInicioBaixa`..`DFimBaixa` (`DTVENC`), `chkPagos ("Somente Parcelas e recebidas em carteira")` (`VALOR_COMP = 0 AND DTPAG IS NOT NULL` — ou seja, pagas no balcão da empresa e que precisam ser baixadas no banco para evitar protesto/cobrança duplicada!), `EnumRemessa` (`CARNE.REMESSA = N`), sempre exigindo `PARCELAS.REGISTRADO = 'S'`.
   - Menu de contexto `pm2` (`Selecionar Tudo`) e botão `BitBtn3 ("Gerar Remessa Banco")`: Gera arquivo **CNAB 240 Sicoob (`756`)** com movimento **`'02'` (Solicitação de Baixa)**. *(Nota de engenharia reversa corrigida em teste real no Validador Sicoob: o binário legado `SGCeFeGe.exe` apresentava bug ao emitir `P = '02'` acompanhado de `Q = '01'`, `R = '01'`, protesto `'100'` e `NSA` fixo `'000001'`. No novo sistema web, gerar obrigatoriamente **Segmentos `P` + `Q` ambos com código `'02'`** — exigido pelo Validador Sicoob — **sem Segmento `R`**, protesto `'300'`, `NSA` sequencial, extensão `.REM` e textos limpos sem acentos/caracteres especiais.)*

#### T25. `TFrmBaixaManual` (`UBaixaManual` — `"Baixa manual"`, `642x333`)
- **Controles:** `ENossoNum` (campo de busca onde o operador digita ou lê no código de barras a chave `NUM_ADESAO + ANOMES`, ex.: `12345` + `2601` -> `123452601`, onde os últimos 4 dígitos são `ANOMES` e o prefixo é `NUM_ADESAO`!), campos informativos somente-leitura (`NOME`, `CPF`, `RG`, `NUM_CARNE`, `ANOMES`, `NUM_ADESAO`, `DTEM`, `DTVENC`, `VALOR`), campos editáveis `DBDTPag` (`DTPAG`) e `DBValorPago` (`VALOR_PAGO`), botões `BSalvar (F5)`, `BCancelar ("Cancelar" / Ctrl+Delete)` e `BFechar (ESC)`.
- **Regras Críticas:**
  - Na liquidação manual (`BSalvar`): grava `DTPAG`, `VALOR_PAGO` e zera `VALOR_COMP = 0` (pois não houve tarifa bancária de compensação).
  - **Cascata da Parcela `ÚNICA`:** Se a parcela baixada tiver `ID_PARC = 'ÚNICA'` (ou `ANOMES` terminar em `'99'`), o sistema quita automaticamente todas as outras 12 parcelas daquele mesmo `NUM_CARNE` com `DTPAG = mesma data` e `VALOR_PAGO = 0,00`!
  - **Estorno (`BCancelar`):** Limpa `DTPAG = NULL`, `VALOR_PAGO = NULL`, `VALOR_COMP = NULL` (e se for `ÚNICA`, estorna também as parcelas `01/12..12/12` vinculadas com `VALOR_PAGO = 0`).
- **Equivalente Web (`/baixas/manual`):** Busca inteligente por `NUM_ADESAO + ANOMES`, `NOSSONUMERO`, CPF ou Nome do Cliente, alerta visual claro quando se tratar de parcela `ÚNICA`, e exigência de motivo/auditoria em caso de estorno.

#### T26. `TFrmBaixaAutomatica` (`UBaixaAutomatica` — `"Baixa Automatica"`, `399x305`)
- **Aba 1 — `Retorno Banco` (`ts1`):** Permite selecionar múltiplos arquivos `.ret`/`.txt` simultaneamente (`LFiles`). Identifica automaticamente pelo código do banco nas posições `1..3` se o arquivo é **Caixa Econômica Federal (`104`)** (suportando tanto Cobrança Segmentos `T`/`U` quanto Arrecadação/SIGCB Segmento `G`) ou **Sicoob (`756`)** (Segmentos `T`/`U`, processando ocorrências `'02'` Confirmação de Entrada, `'03'` Rejeição, `'09'` Baixa Comandada e `'06'` Liquidação). Ao final, exibe resumo de títulos liquidados, entradas confirmadas, baixados e rejeitados/não encontrados.
- **Aba 2 — `Arquivo Excel` (`ts2`):** Seleciona arquivo `.xls`, lista as abas (`GetTableNames` em `Listbox1`) e importa 3 colunas posicionais (`Col 0 = Data Pagamento`, `Col 1 = NUM_ADESAO (9 dígitos) + ANOMES (4 dígitos)`, `Col 2 = Valor Pago`).
- **Equivalente Web (`/baixas/automatica`):** Upload drag-and-drop de múltiplos arquivos `.ret`/`.rem`/`.xls`/`.xlsx`/`.csv`, processamento idempotente com pré-visualização conciliação linha a linha (conciliados, já baixados, divergência de valor, não localizados) e relatório detalhado exportável.

#### T27. `TFrmCancelamento` (`UCancelamento` — `"Cancelamento"`, `640x410`)
- **Controles:** `ENumAdesao` + `BitBtn1 ("Consultar")`, dados somente-leitura do titular (`NOME`, `NOME_MAE`, `INSCRICAO`, `RG`, `CPF`, `VALOR_PLANO`, `DATA_NASC`), grade `DBGrid3 ("Parcelas em atrazo:")` (`SELECT * FROM PARCELAS WHERE NUM_ADESAO = :num AND DTPAG IS NULL AND DTVENC < CURRENT_DATE AND ID_PARC <> 'ÚNICA'`) e botão `BCancelar ("Cancelar plano")`.
- **Regra:** Verifica `PerCancelarPlano`; após confirmação do operador, altera `CLIENTES.SITUACAO = 'C'` (não apaga histórico de parcelas nem carnês).

#### T28. `TFrmSegundaVia` (`UsegundaVia` — `"Segunda Via"`, `773x495`)
- **Aba 1 — `Carnê` (`TabSheet3`):** Pesquisa cliente por `ENumeroCliente` ou combo `CCliente`, exibe seus carnês (`DBGrid1`) e respectivas parcelas (`DBGrid2`). O botão `BAdcionarCarne` empilha o carnê selecionado na fila em memória (`Memo1`), `BitBtn2 ("Limpar")` esvazia a fila e `BitBtn1 ("Gravar Arquivo")` gera `SEG_VIA_CARNE.TXT` (350 bytes/linha) em `DIRARQUIVO`.
- **Aba 2 — `Carteira` (`TabSheet4`):** Pesquisa cliente (`ENumeroClienteCartao` / `CClienteCartao`), exibe seus dependentes (`DBGrid3`). Permite enfileirar o cartão de identificação do **Titular** (`BAddCliente`), de **um Dependente específico** (`BAddDep`) ou de **todos os Dependentes** (`BAddTodosDeps`) na fila (`Memo2`), gerando `SEG_VIA_CARTÃO.TXT` (350 bytes/linha) ao clicar em `BSalvar ("Gravar Arquivo")`.
- **Equivalente Web (`/segunda-via`):** Fila persistente no banco de dados (`fila_segunda_via` em `02_schema_postgresql_moderno.sql`), permitindo que vários atendentes adicionem solicitações ao longo do dia antes do fechamento do arquivo único para a gráfica, além de geração de boleto PDF individual com linha digitável/PIX imediato para envio por WhatsApp/e-mail!

#### T29. `TFrmDiagnostico` (`Udiagnostico` — `"Diagnosticar Situação"`, `559x302`)
- **Controles:** `ENumeroCliente`, `CCliente`, `BConfirmar ("Diagnosticar")`, `Memo` (relatório textual).
- **Árvore de Decisão Exata (`0x5ab700..0x5abad8`):**
  1. `SELECT * FROM ADESAO WHERE NUMERO = :num` -> Se vazio: `"Este Número de Adesão não existe."` (FIM).
  2. Exibe `"Número de Adesão: {num}"`. Busca `CLIENTES WHERE NUMERO = :num`:
     - Se vazio: `"Nenhum Cliente Cadastrado com este Numero de Adesão."`
     - Se encontrado: exibe `"Cliente: {NOME}"`, `"Data do castramento do cliente: {INSCRICAO}"` e, se `SITUACAO = 'C'`, `"*** Cliente Cancelado ***"`.
  3. Busca `PARCELAS WHERE NUM_ADESAO = :num AND DTPAG IS NOT NULL AND ANOMES = '0000'`:
     - Se vazio: `"A parcela de adesão ainda não foi paga."`
     - Se encontrado: `"Data de pagamento da adesão: {DTPAG}"`.
  4. Busca `CARNE WHERE NUM_ADESAO = :num AND NUM_PARC = 12` (posiciona no último registro `.Last`):
     - Se vazio: `"O arquivo de carne deste cliente ainda não foi criado, será criado na próxima geração de carnês."`
     - Se encontrado: `"Ultimo carnê deste cliente foi criado em: {DATA}"` e `"Número do arquivo de remessa: {REMESSA}"`.

---

### Grupo D — Parâmetros e Consultas de Relatórios

#### T30. `TFrmRelatoriosContas` (`URelatoriosContas` — `"Relatorios"`, `244x252`)
- **Reuso:** Instanciado tanto para **Contas a Receber** (`Caption = "Relatorio - Contas a receber"`) quanto para **Contas Recebidas** (`Caption = "Relatorio - Contas recebidas"`).
- **Controles:** `DDataIni` (`De:`), `DDataFim` (`Até:`), `BConfirmar (F5)` -> executa query agregada diária (`IBDContasReceber` ou `IBDContasRecebidas`), passa parâmetros `DATAINI` e `DATAFIM` para `RvProject` e executa `RelContasAReceber` ou `RelContasRecebidas`.

#### T31. `TFrmRelatoriosClientes` (`URelatoriosClientes` — `"Relatorio/Consulta de Cliientes"`, `593x372`)
- **Reuso Duplo (Consulta Interativa + Impressão Rave):** Usado para **Clientes Adimplentes** e **Clientes Inadimplentes**.
- **Controles:**
  - `DData ("Até a data:")`: Data de corte de vencimento (`DTVENC <= :data`).
  - `CCampo` + `ETexto`: Permite filtrar por qualquer campo cadastral de `CLIENTES` ou por `"NOME DO CADASTRANTE"` (`CONVENIOS.NOME`).
  - `ChkCarneCompleto ("Apenas Clientes Com Carnê Quitado")`: Visível/aplicável no modo Adimplentes — restringe a clientes que pagaram a 12ª parcela (`ANOMES LIKE '%12' AND DTPAG IS NOT NULL`) e não possuem outra 12ª parcela em aberto!
  - **3 Abas de Drill-Down em Tela:** `Titular` (`DBGrid1`), `Dependentes` (`DBGrid2`) e `Parcelas` (`DBGrid3` incluindo `VALOR_COMP` e `VALOR LIQUIDO`).
  - `BFiltrar (F3)` atualiza as 3 grades em tela; `BConfirmar (F5)` dispara a impressão Rave (`RelClientesAdimplentes` ou `RelClientesInadimplentes`).

#### T32. `TFrmRelGeralClientes` (`URelGeralClientes` — `"Relatorio de Clientes"`, `284x378`)
- **Controles:**
  - `RadioGroup1`:
    - `0`: `Geral de clientes` (`TITULO = 'Relatório Geral de Clientes'`)
    - `1`: `De aniversariantes do mês` (`EXTRACT(MONTH FROM C.DATA_NASC) = :mes_atual`, `TITULO = 'Relatório de Clientes Aniversariantes do mês MM'`)
    - `2`: `De clientes que não pagaram a adesão` (`EXISTS / JOIN PARCELAS P ON P.NUM_ADESAO = C.NUMERO WHERE P.ANOMES = '0000' AND P.VALOR_PAGO IS NULL`, `TITULO = 'Relatório de Clientes que não pagaram a adesão'`)
  - `CCampo` + `ETexto` (filtro adicional opcional) + `chkInativos ("Visualizar Inativos")` (alterna filtro `C.SITUACAO = 'I'` vs `C.SITUACAO = 'A'`).
  - `BConfirmar (F5)` -> executa `RelClientesGeral`.

#### T33. `TFrmRelConvenios` (`URelConvenios` — `"Relatorio de Comissões de Cadastrantes"`, `448x226`)
- **Controles:** `ECodCadastrante` + `C1` (`TDBLookupComboBox` sobre `CONVENIOS`; se em branco, lista todos os cadastrantes), `DDataIni`..`DDataFim` (inicializados automaticamente com o 1º e o último dia do mês corrente via `ULib__fn_57f688`).
- **Ação (`BConfirmar`):** Executa `IBQryRelConvenio` filtrando parcelas pagas no período (`P.DTPAG BETWEEN :ini AND :fim AND P.VALOR_PAGO > 0`), calcula `<COMISSÃO> = P.VALOR_PAGO * CONV.PERC_COM / 100` e imprime `RelConvenios`.

---

## 6. Mapa Completo de Rotas da Nova Aplicação Web (SPA Moderna)

| Rota Frontend (React / Next.js) | Tela(s) Legada(s) Equivalente(s) | Permissão Necessária | Descrição Funcional na Web |
|---|---|---|---|
| `/login` | `TFrmLogin`, `TFrmConectar` | Pública | Login seguro (JWT), recuperação/troca obrigatória de senha inicial |
| `/perfil/senha` | `TFrmAlterarSenha` | Autenticado | Alteração da própria senha com validação de força |
| `/dashboard` | `TFrmPrincipal` | Autenticado | Indicadores financeiros, status de `DATA_ARQ`, alertas de carnês a gerar e atalhos rápidos |
| `/empresas` | `TFrmEmpresas`, `TFrmSetPath` | `perm_empresas_consultar` / `editar` | Cadastro multiempresa, upload de logomarca PNG/SVG, parâmetros Sicoob e agendamento `DATA_ARQ` |
| `/usuarios` | `TFrmConsultaUsuarios`, `TFrmUsuarios` | `perm_usuarios_consultar` / `editar` | Gestão de operadores, presets de perfil e matriz de 18 permissões RBAC |
| `/comissionados` | `TFrmConsultaConvenios`, `TFrmConvenios` | `perm_convenios_consultar` / `editar` | CRUD de cadastrantes/vendedores (CPF ou CNPJ) e percentual de comissão |
| `/clientes-pf` | `TFrmConsultaClientes`, `TFrmClientes` | `perm_clientes_consultar` / `editar` | Listagem avançada + Ficha 360º do Titular PF, Dependentes, Carnês e Parcelas |
| `/clientes-pj` | `TFrmConsultaPessoaJuridica`, `TFrmCadastroPessoaJuridica`, `TFrmCadastroFuncPessoaJuridica` | `perm_pj_consultar` / `editar` | Listagem PJ + Visão em abas de Empresa Cliente, Funcionários Titulares e Dependentes |
| `/adesoes` | `TFrmAdesao`, `TFrmRecuperarArquivo` (opções 1 e 2) | `perm_emitir_adesao` | Estoque de fichas de adesão, geração de lotes `REMADESAO` e listagem de números não utilizados |
| `/carnes/gerar` | `TFrmCarne` | `perm_emitir_carne` | Simulação prévia e geração em lote de carnês PF (12 parcelas + `ÚNICA`) e arquivo gráfico `REMESSA` |
| `/faturamento-pj` | `TFrmBoletoBancario` | `perm_pj_editar` | Fechamento mensal de faturas PJ por competência `MM/AAAA` com memória de cálculo por funcionário ativo |
| `/cobranca/remessas` | `TfrmGerarRemessa`, `TFrmRecuperarArquivo` (opção 0) | `perm_gerar_remessa_cnab` | 3 fluxos integrados: Consolidação de Inadimplentes (`DEBIT`), Remessa CNAB 240 Sicoob (`01` Registro / `02` Baixa) + Remessa Gráfica Avulsa e Histórico de Lotes |
| `/baixas/manual` | `TFrmBaixaManual` | `perm_baixa_manual` | Liquidação e estorno manual com busca rápida por código de barras/Nosso Número/Adesão+AnoMês e cascata `ÚNICA` |
| `/baixas/automatica` | `TFrmBaixaAutomatica` | `perm_baixa_automatica` | Conciliação em lote de retornos CNAB 240 (Caixa `104` / Sicoob `756`) e planilhas `.xls`/`.xlsx`/`.csv` |
| `/cancelamentos` | `TFrmCancelamento` | `perm_cancelar_plano` | Consulta de débitos pendentes e cancelamento formal de contrato PF/PJ com registro de motivo |
| `/segunda-via` | `TFrmSegundaVia` | `perm_emitir_carne` | Fila compartilhada para `SEG_VIA_CARNE.TXT` e `SEG_VIA_CARTÃO.TXT` + emissão instantânea de PDF |
| `/diagnostico` | `TFrmDiagnostico` | `perm_clientes_consultar` | Linha do tempo completa e diagnóstico automático da situação cadastral, adesão e último carnê do cliente |
| `/relatorios/contas-a-receber` | `TFrmRelatoriosContas` + `RelContasAReceber` | `perm_relatorios` | Previsão diária/analítica de recebíveis no período com exportação PDF, XLSX e CSV |
| `/relatorios/contas-recebidas` | `TFrmRelatoriosContas` + `RelContasRecebidas` | `perm_relatorios` | Caixa diário/analítico (Bruto, Tarifa de Compensação e Valor Líquido) com PDF, XLSX e CSV |
| `/relatorios/clientes-adimplentes` | `TFrmRelatoriosClientes` + `RelClientesAdimplentes` | `perm_relatorios` | Consulta drill-down + relatório agrupado por cliente (com filtro de carnê 12/12 quitado) |
| `/relatorios/clientes-inadimplentes` | `TFrmRelatoriosClientes` + `RelClientesInadimplentes` | `perm_relatorios` | Consulta drill-down + relatório de cobrança agrupado por cliente com telefones e total devido |
| `/relatorios/clientes-geral` | `TFrmRelGeralClientes` + `RelClientesGeral` | `perm_relatorios` | Geral Ativos/Inativos, Aniversariantes do Mês e Clientes com Adesão Pendente (`0000`) |
| `/relatorios/comissoes` | `TFrmRelConvenios` + `RelConvenios` | `perm_relatorios` | Apuração de comissões de cadastrantes sobre parcelas pagas no período |
| `/relatorios/faturamento-pj` | `Relatorio1` / `IBQryRelPessoaJuridica` *(novo/concluído)* | `perm_relatorios` | Relatório financeiro de faturas, pagamentos e inadimplência da carteira Pessoa Jurídica |
| `/auditoria` | *(novo requisito web)* | `perm_auditoria_consultar` | Trilha completa de auditoria (`auditoria_eventos`) conforme dicionário oficial de eventos em `07_pendencias_migracao_e_ajustes_schema.md` (item `1.24`), com filtros por data, intervalo de data, login (usuário), tipo de evento e entidade |
| `/parceiros` | *(Módulo 1 — novo requisito web)* | `perm_parceiros_consultar` / `dados` / `precos_editar` | Gestão da Rede Credenciada e Clínicas Próprias em tela única Mestre-Detalhe com **Fluxo em Funil de Precificação** (Parceiro $\to$ Local $\to$ Especialidade $\to$ Profissional [exige Local] $\to$ Procedimento/Descrição $\to$ Convênio/Preço), Trava Dupla CRM, revisão semestral (`cadastro_atualizado_em`/`precos_atualizados_em`) e geração de Guia PDF |
