# 08 — Rotinas Operacionais Reais Ainda Não Documentadas no Legado

> **Propósito deste Documento:** Registrar regras e rotinas de trabalho executadas na operação diária da empresa que **não existiam implementadas no sistema legado (`SGCeFeGe.exe`)** — e que, portanto, não constam nos documentos de engenharia reversa (`03`, `04` e `05`). Todas estas rotinas **devem ser implementadas nativamente** no novo sistema web e refletidas na revisão final do `02_schema_postgresql_moderno.sql`.
>
> **Status:** Em construção (atualizado conforme o avanço da leitura dos arquivos `.sql`).

---

## 1. Rotina de Reativação de Cliente PF

### 1.1 Quando Ocorre
* Ex-clientes com cadastro **Cancelado (`'C'`)** ou **Inativo (`'I'`)** que desejam retornar;
* Clientes que, mesmo sem cancelamento formal no sistema, estão **"parados no tempo"** (deixaram de pagar há muito tempo) e retornam mediante **negociação/quitação** do débito ou **perdão da dívida**.

### 1.2 Regras Fundamentais
1. **Sem Novo Cadastro (CPF Único):**
   * Não se deve criar um novo registro de cliente (`clientes_pf`) nem duplicar o CPF no sistema. O cliente retorna no seu cadastro existente, voltando à situação **`'A'` (Ativo)** (não há necessidade de criar um novo valor no `situacao_cadastro_enum`).
2. **Mesmo Rito da Adesão Inicial:**
   * O processo funciona operacionalmente como uma nova adesão:
     * Atualização dos dados cadastrais / nova ficha de contrato;
     * Pagamento presencial (ou faturado) de uma **nova Taxa de Adesão / Reativação**.
3. **Registro Financeiro Obrigatório no Caixa (Correção de Ponto Cego do Legado):**
   * **Como era feito manualmente no legado:** O sistema legado não reconhecia a entrada financeira da reativação. O operador precisava ir direto ao banco, pegar a última parcela do último carnê, alterar manualmente o `ANOMES` e o `DTVENC` para o mês atual, liquidar/baixar os débitos e aguardar o próximo lote de carnês.
   * **Como deve funcionar no novo sistema:** A rotina de reativação deve gerar um lançamento financeiro próprio (ex.: carnê avulso com `id_parc = 'REATIVACAO'` ou equivalente), registrando **data de pagamento, valor recebido e usuário responsável**, para que o dinheiro entre oficialmente nos relatórios de **Caixa / Contas Recebidas** e na trilha de `auditoria_eventos`.
4. **Tratamento das Parcelas Antigas / Carnê Anterior Interrompido:**
   * **Cenário real:** Cliente cancelou em fevereiro com carnê vigente até novembro (tendo parcelas em aberto de março a novembro e a cota `'2699'`). Em julho, ele solicita reativação para começar novo carnê em agosto.
   * **Regra:** Ao reativar:
     * Débitos passados negociados são liquidados conforme o valor pago (ou encerrados por perdão de dívida/negociação, com registro auditável);
     * Parcelas futuras em aberto do carnê anterior (incluindo a `'ÚNICA'` não paga do carnê interrompido) devem ser **canceladas logicamente** (sem `DELETE` físico, preservando histórico) para que não fiquem como pendência em aberto nem colidam com o novo carnê a ser gerado.
5. **Isenção da Taxa de Manutenção Anual no 1º Carnê Pós-Reativação:**
   * **Como era feito manualmente no legado:** Como o cliente já possuía `CARNE` anterior (`NUM_PARC = 12`), o sistema legado enxergava o novo carnê como uma *renovação* e somava automaticamente a taxa de manutenção anual ($A$, ex.: R\$ 12,00) na parcela `'01/12'` e na `'ÚNICA'`. O operador precisava editar o banco manualmente após a geração para remover esse valor.
   * **Como deve funcionar no novo sistema:** O **primeiro carnê gerado após uma reativação deve ter $A = 0,00$** (isento da taxa de manutenção anual na `'01/12'` e na `'ÚNICA'`), comportando-se exatamente como o primeiro carnê de um cliente recém-matriculado. A cobrança da taxa anual volta a ocorrer apenas nas renovações subsequentes (2º carnê pós-reativação em diante).

---

## 2. Histórico Operacional: Substituição Extraordinária de Carnês no Mesmo Ano (`YY99` vs `YY98`)

* **O que aconteceu no passado (2018):** Devido à mudança de banco e à proibição da FEBRABAN de cobrança sem registro, foi necessário cancelar/excluir as parcelas não pagas de carnês já emitidos para o ano e gerar novos carnês a partir de abril do mesmo ano.
* **Por que surgiu o `'YY98'`:** Como os carnês originais já ocupavam `ANOMES = '1899'` (regra da `'ÚNICA'`), a chave primária composta `(NUM_ADESAO, ANOMES)` impediu a criação do novo `'1899'`, forçando a criação emergencial da regra `'AA + 98'`.
* **Diretriz para o Novo Sistema:** O sistema moderno **não deve depender de gambiarras como `'98'`** para reemitir carnês ou reativar clientes no mesmo ano civil. O controle de unicidade deve ser vinculado ao carnê (`num_carne`) e ao status da parcela (conforme detalhado em `07_pendencias_migracao_e_ajustes_schema.md`).

---

## 3. Geração de Carnê em Atraso: Vencimento Real vs. Vencimento de Remessa Bancária

* **Cenário Real:** O carnê anterior terminava em fevereiro, mas o cliente só quitou a 10ª parcela (gatilho de renovação) em julho. Ao gerar o novo carnê em julho, as parcelas de março a julho já estariam com vencimento no passado.
* **Comportamento no Legado:** Como o banco não aceita registrar boletos vencidos, o sistema gerava todas essas parcelas atrasadas diretamente com o próximo vencimento futuro (ex.: agosto). O cliente ficava com várias parcelas no mesmo vencimento, dependendo do campo `ANOMES` para identificar a qual mês cada lâmina pertencia.
* **Diretriz para o Novo Sistema:**
  1. Manter o campo `anomes` como identificador visual da competência para cliente e atendimento;
  2. Gravar no banco de dados o **vencimento real** de cada competência;
  3. **Somente no momento de gerar a remessa CNAB de registro bancário**, a rotina verifica se há parcelas com `data_vencimento` no passado e ajusta a data enviada ao banco para o próximo vencimento válido do cliente (contornando a rejeição bancária sem perder a data real no banco de dados).

---

## 4. Fluxo Moderno de Adesão Inicial e Reativação (Gatilho de Pagamento)

* **Mudança Operacional:** No legado, geravam-se números de adesão pré-impressos em estoque (`PF_PRE_IMPRESSO`). No sistema novo, não haverá mais geração prévia de números em estoque.
* **Regra de Pagamento e Ativação (Adesão e Reativação):**
  * A taxa de **Adesão** ou **Reativação** **NÃO nasce paga** — ela nasce **`ABERTA`** para que seja obrigatoriamente liquidada (manualmente no balcão/caixa ou automaticamente via boleto/Pix no futuro cadastro pelo site/app);
  * O pagamento da taxa continua sendo o **gatilho obrigatório** para efetivar a inscrição/reativação e liberar a geração do carnê;
  * Na UI do atendimento presencial, prever **alerta/lembrete** para o operador não esquecer de registrar a baixa e dar entrada no caixa ao concluir uma adesão ou reativação.

---

## 5. Acordo / Renegociação Parcelada de Dívida (`N` Parcelas em `M` Parcelas)

* **Cenário Real:** Um cliente deve, por exemplo, **R\$ 100,00** (4 parcelas de R\$ 25,00) e negocia pagar essa dívida em **3x** (valores que **não são múltiplos** das parcelas originais, podendo ainda envolver desconto ou acréscimo).
* **Como é feito hoje ("por baixo dos panos"):** O sistema legado só consolida em 1 única parcela `'DEBIT'`. Quando há parcelamento da dívida, a equipe gera boletos avulsos fora do sistema, precisa ficar conferindo manualmente no banco se o cliente pagou e ainda enfrenta a dúvida de quais parcelas originais baixar no sistema quando os valores pagos não batem com múltiplos das parcelas antigas.
* **Como deve funcionar no novo sistema:**
  1. O operador seleciona as $N$ parcelas em aberto que entrarão no acordo;
  2. Define as condições do acordo (valor negociado com eventual desconto/juros, quantidade $M$ de parcelas e datas de vencimento);
  3. O sistema faz a **baixa técnica imediata** das $N$ parcelas originais (`valor_pago = 0.00`, status `'RENEGOCIADA'`, vinculadas ao acordo), removendo-as da inadimplência sem inflar o caixa;
  4. O sistema gera as **$M$ novas parcelas do acordo** com `nosso_numero` próprio, integradas normalmente à remessa CNAB 240 e com **baixa automática via arquivo de retorno bancário**, preservando o vínculo completo entre o acordo, as $M$ parcelas geradas e as $N$ parcelas originais.

---

## 6. Rastreabilidade de Caixa e Produção por Unidade, Usuário e Meio de Pagamento (RBAC por Filial)

* **Descoberta Operacional:** A tabela `CONVENIOS` do legado era usada exclusivamente para identificar as **Unidades/Filiais** da associação (controle de produção por unidade), e **não** para comissionados (rotina de comissão não existe na operação e não será implantada). Toda a cobrança bancária é centralizada em uma **única conta na Matriz (`empresas`)**.
* **Comportamento Esperado no Novo Sistema:**
  * Cada **usuário** é vinculado a uma **Unidade/Filial (`unidades`)**;
  * Ao cadastrar um associado, a unidade de origem (`unidade_cadastro_id`) é preenchida automaticamente pela unidade do usuário logado (não mais escolhida em lista de "cadastrantes");
  * Toda baixa manual/presencial registra automaticamente o usuário logado, a unidade de recebimento (`unidade_recebimento_id`) e o meio de pagamento (`DINHEIRO`, `PIX`, `CARTAO_DEBITO`, `CARTAO_CREDITO`);
  * **Controle de Acesso (RBAC por Unidade):** Funcionários comuns enxergam e operam apenas dados da **sua unidade**; **Administradores** têm visão e gestão global de todas as unidades;
  * Permitir fechamento de caixa diário e relatórios de produção filtrados por **Unidade**, **Usuário** e **Meio de Pagamento**.

---

## 7. Catálogo de Planos, Pacotes Prontos e Benefícios Agregados

* **Evolução em Relação ao Legado:** O sistema legado trabalhava com apenas um valor padrão global digitado na hora de gerar o carnê (`valor_titular` e `valor_dependente`).
* **Novo Modelo Desejado:**
  1. **Gestão de Planos (`planos`):** Possibilidade de cadastrar múltiplos planos distintos (ex.: *Plano 1 - Básico*, *Plano 2 - Plus*, *Plano 3 - Básico + Funeral + Pet*), cada um com suas regras de mensalidade do titular, valor por dependente, taxa de adesão, acréscimo de renovação anual e percentual de desconto da parcela `'ÚNICA'`.
  2. **Benefícios / Serviços Agregados (`beneficios_adicionais`):** Possibilidade de cadastrar serviços modulares (ex.: *Seguro Funeral*, *Seguro Residencial*, *Cuidado Pet*) que o associado pode contratar de forma avulsa somados ao seu plano base (ex.: *Plano 1 + Seguro Funeral + Pet*), **inclusive de forma individualizada para dependentes** que não fazem parte da cobertura padrão (ex.: plano funerário cobre titular, cônjuge e filhos menores no valor base, mas filhos maiores, pais, sogro/sogra ou netos podem contratar o funeral individualmente mediante acréscimo de valor e preenchimento obrigatório de CPF, estado civil, sexo e data de nascimento).
  3. **Cálculo de Mensalidade:** Na geração de carnês, a mensalidade base $M$ do associado considera o plano vinculado ao seu cadastro somado aos benefícios adicionais ativos do titular e de cada dependente.

---

## 8. Central de Contas Bancárias de Cobrança (Multibanco)

* **Necessidade Real:** Os dados bancários pertencem às **contas de cobrança** (e não ao cadastro da empresa matriz), podendo existir múltiplas contas/bancos configurados (ex.: Sicoob `756`, Caixa `104`, Banco do Brasil `001`, etc.) com seus próprios parâmetros de agência, conta, cedente, carteira, multa, juros e controle de remessa.

---

## 9. Pendências de Revisão Jurídica / Documentos Associativos

* **Contratos e Termos de Adesão:** Os documentos associativos atuais não preveem a contratação modular de **bloquinhos de benefícios adicionais** (nem para o titular, nem individualmente por dependente, como cobertura funerária avulsa para pais, sogros, filhos maiores e netos).
* **Ação Necessária:** Antes de colocar os novos pacotes/benefícios em produção, revisar os contratos e fichas de adesão da associação para contemplar formalmente essas coberturas adicionais, regras de elegibilidade por parentesco e valores.

---

## 10. Visão Futura: Agenda Médica e Vínculo Paciente $\leftrightarrow$ Associado/Dependente

* **Contexto Atual:** Hoje os cadastros de **pacientes** (agenda médica) e **associados/dependentes** são mantidos em sistemas/bases separados, gerando contatos desatualizados na associação — já que o associado comparece com muito mais frequência às consultas médicas do que ao atendimento administrativo de carnês.
* **Diretriz Futura (para quando o módulo de Agenda Médica for construído):**
  1. Um paciente na agenda pode ser um **Associado Titular** (`clientes_pf`), um **Dependente** (`dependentes_pf`) ou um **Paciente Particular/Avulso** (não associado);
  2. Quando for associado ou dependente, haverá **vínculo direto** entre o prontuário/agenda e o cadastro associativo (e na implantação da agenda, prever mesclagem dos cadastros separados);
  3. Qualquer atualização de telefone ou contato feita na recepção durante o agendamento/consulta atualiza automaticamente o cadastro associativo correspondente (aproveitando índices de busca por telefone e CPF).

---

## 11. Geração de Documentos em PDF e Digitalização Integrada no Cadastro

* **Como é hoje:** Os documentos contratuais (Ficha de Adesão e Contrato) são gerados fora do sistema (em Excel), impressos para assinatura e digitalizados avulsamente junto com CPF/CNH.
* **Como deve funcionar no novo sistema:**
  1. O sistema gera automaticamente a **Ficha de Adesão e o Contrato em PDF** com os dados do associado, plano e benefícios contratados (substituindo o Excel);
  2. Já durante o fluxo de cadastro/reativação (e na aba **"Documentos"** da ficha do cliente), o atendente pode anexar/digitalizar o contrato assinado e os documentos pessoais (CPF, CNH), mantendo todo o dossiê digital vinculado ao `num_adesao`.

---

## 12. Impressão Direta em PDF (Fim da Dependência da Gráfica no `.TXT`)

* **Como é hoje:** O sistema legado gera um `.TXT` posicional de 350 colunas (`REMESSA*.TXT`) que é enviado a uma gráfica específica, a qual converte esse arquivo em 3 PDFs para impressão e montagem dos kits de envio pelos Correios.
* **Como deve funcionar no novo sistema (geração direta em PDF, sem depender do `.TXT`):**
  1. **PDF de Carnês com Imposição de Guilhotina (*Cut-and-Stack*, 3 boletos por página):**
     * Em vez de imprimir um carnê atrás do outro, o sistema agrupa os carnês **de 3 em 3** ao longo de **13 páginas**:
       * Posição 1 (topo) das páginas 1 a 13 = todas as 13 lâminas do Carnê 1 (`ÚNICA` + `01/12`..`12/12`);
       * Posição 2 (meio) das páginas 1 a 13 = todas as 13 lâminas do Carnê 2;
       * Posição 3 (base) das páginas 1 a 13 = todas as 13 lâminas do Carnê 3.
     * Ao passar as 13 páginas na guilhotina, os 3 carnês já saem montados e ordenados, sem necessidade de intercalar páginas manualmente.
     * **Pendência a definir na etapa de implementação:** Como tratar o lote quando a quantidade de carnês **não for múltipla de 3** (para evitar desperdício de folhas/espaços em branco — ex.: alerta na prévia, ajuste manual de lote ou layout alternativo para o resto).
  2. **PDF de Etiquetas de Correios:** Geração direta da folha de etiquetas adesivas de endereçamento (padrão do arquivo de referência `Etiquetas ABBAC.pdf`), seguindo a mesma ordenação dos carnês para postagem.
  3. **PDF de Dados Variáveis das Carteirinhas:** Geração direta do PDF de dados variáveis para impressão sobre as carteirinhas pré-impressas coloridas (padrão do arquivo de referência `OS157100_ABBAC_Cartão_Rem 351.pdf`), contendo titular e dependentes na mesma ordem dos carnês para montagem rápida do kit *Carnê + Carteirinhas* no envelope.
  * **Arquivos de Referência Locais (`documentos_auxiliares/`):** Os arquivos reais de exemplo (`REMESSA0000351_&SICOOB.TXT`, `Etiquetas ABBAC.pdf`, `OS157100_ABBAC_Cartão_Rem 351.pdf`) ficam na pasta local `documentos_auxiliares/` (protegida no `.gitignore` por conter dados reais de clientes). Caso não estejam presentes no momento da implementação dos geradores de PDF, solicitar ao usuário.

---

## 13. Gestão de Múltiplos Contatos PJ e Envio de Fatura Mensal

* **Necessidade Real:** Empresas clientes (`clientes_pj`) frequentemente possuem interlocutores distintos (ex.: um contato no **RH** que envia a relação mensal de funcionários ativos/desligados e um ou mais contatos no **Financeiro** que recebem os boletos/faturas mensais).
* **Como deve funcionar no novo sistema:** Cadastro dinâmico de contatos vinculados à empresa PJ (`clientes_pj_contatos`), com marcação booleana **`responsavel_financeiro`** (podendo haver 1 ou N responsáveis), utilizada pelo faturamento mensal PJ para saber exatamente para quais e-mails enviar a fatura/boleto da empresa.

---

## 14. Protocolo Unificado de Movimentações (PF, Dependentes, PJ e Futuro App)

* **Planos por Cargo/Setor (PJ):** Permitir que uma empresa cliente (`clientes_pj`) tenha planos padrão configurados por **setor** ou **cargo**, com liberdade para ajustar o plano ou adicionar benefícios extras individualmente por funcionário (`funcionarios_pj`).
* **Protocolo Único de Solicitações e Formulários (`solicitacoes_movimentacao`):**
  * Mapeia dentro do sistema todas as solicitações formais de **PJ**, **Titulares PF** e **Dependentes PF** (incluindo alteração/inclusão/exclusão de dependentes, cancelamento de plano e **formulário específico para o próprio dependente solicitar sua exclusão do vínculo com um titular**);
  * Cada solicitação gera um **protocolo** com geração/impressão de formulário em PDF quando presencial, anexo de comprovante (formulário assinado, e-mail ou print de WhatsApp), identificação de quem pediu e canal de origem;
  * **Preparado para o Futuro Aplicativo do Associado:** Quando o aplicativo for lançado, o próprio associado/dependente abrirá solicitações diretamente nessa mesma estrutura (entrando com status pendente para validação/execução ou aprovação automática conforme a regra).

---

## 15. Gestão da Rede Credenciada, Clínicas Próprias e Guia PDF (Módulo 1 — Primeira Entrega em Produção)

* **Estratégia Modular de Implantação:** O novo sistema será desenvolvido e colocado em produção **por módulos independentes**, todos compartilhando o mesmo banco de dados oficial PostgreSQL. O **Módulo 1** a entrar no ar será o de **Rede Credenciada / Parceiros** (substituindo as planilhas atuais de listagem e listagem resumida), sendo integrado posteriormente aos módulos de Associados, Financeiro, Autorizações, Clínicas Próprias/Agenda Médica e Portal/App.
* **Abrangência e Clínicas Próprias:**
  * Qualquer associado de qualquer unidade pode utilizar qualquer parceiro da rede (não há restrição geográfica por unidade do associado); apenas no futuro poderá haver restrição por **plano ou benefício adicional** contratado.
  * As **Unidades Próprias da Associação** que possuem clínica médica/odontológica/exames também aparecem na rede credenciada (vinculadas a `unidades`), utilizando até **4 faixas de preço internas**: *Particular*, *Associado*, *Parceiros* e *Encaminhamento Prefeitura*.
* **Flexibilidade Total de Modelos de Benefício (4 Cenários):**
  1. **Valor Fixo** (Particular $\times$ Associado, além de Parceiro e Prefeitura quando aplicável);
  2. **Percentual de Desconto Geral (%)** sobre todo o estabelecimento;
  3. **Percentual de Desconto Variável (%)** por subcategoria/grupo de produtos ou serviços;
  4. **Sob Consulta / Tabela Variável** (sem valor ou % fixo, exibindo orientação clara ao associado).
  * Um mesmo parceiro pode combinar modelos, ter preços diferentes por **local de atendimento (cidade/filial)** e/ou por **profissional** dentro do mesmo estabelecimento.
* **Conformidade Legal (CRM e LGPD):**
  * **Regra Crítica do CRM (Proibição de Divulgação Pública de Preços):** O servidor/API **jamais** envia valores (R\$) ou percentuais (%) em rotas públicas ou no Guia PDF enviado ao associado quando o cadeado `bloqueio_divulgacao_valores` estiver ativo (padrão `TRUE` para todo cadastro, destravável **exclusivamente por `ADMINISTRADOR`**). A tabela resumida com menores preços é **estritamente interna**.
  * **Separação LGPD (`LGPD.pdf`):** Dados particulares/pessoais do profissional e contatos internos (`parceiros_contatos`) ficam isolados do guia público; redes sociais (Instagram, Facebook e WhatsApp) possuem permissão individual (`SIM`/`NÃO`) de divulgação, e o sistema deve gerar o **Termo LGPD em PDF** para assinatura e arquivamento em `parceiros_documentos`.
* **Governança e Manutenção da Rede:**
  * Controle de **duas datas independentes** (`dados_atualizados_em` e `tabela_atualizada_em`) com alertas automáticos de revisão semestral (6 meses);
  * Permissão interna segregada para alteração de tabelas de preços (todos os colaboradores autorizados visualizam valores internos, mas apenas perfis com permissão podem alterar);
  * **Histórico dedicado de reajustes** (`parceiros_precos_historico`) além da auditoria geral;
  * **Destaques:** Separação entre **Destaque Editorial Interno** (menores preços / mais procurados) e **Destaque Patrocinado** (propaganda paga com escopo geral ou por cidade/categoria e data de validade automática);
  * **Guia PDF (estilo Guia Unimed para WhatsApp):** Geração limpa e legível no celular com filtros combinados, sem divulgação monetária no guia público, exibindo data de geração e filtros aplicados no cabeçalho/rodapé;
  * **Preparação para Mapa por Proximidade (Futuro):** `parceiros_locais` já prevê `latitude`, `longitude` (preenchidos de forma automática/opcional a partir do endereço ou link do Google Maps, jamais digitados manualmente), `google_maps_url` e horário de funcionamento estruturado para futuro mapa próprio estilo Google Maps.

---

## 16. Regra Arquitetural Obrigatória: Isolamento Total de Ambiente e Dados por Perfil (Multi-Perfil / RLS)

* **Diretriz Inegociável de Segurança:** O sistema atenderá **8 perfis distintos** (`ADMINISTRADOR`, `COLABORADOR`, `ASSOCIADO_PF`, `DEPENDENTE_PF`, `EMPRESA_PJ`, `FUNCIONARIO_PJ`, `DEPENDENTE_PJ` e `PARCEIRO`), com **separação estrita de ambiente e dados** aplicada obrigatoriamente no **backend** e reforçada no banco PostgreSQL (**RLS — *Row-Level Security***):
  * Cada usuário enxerga e opera **exclusivamente** os registros vinculados à sua própria titularidade, contrato, empresa, unidade(s) autorizada(s) ou cadastro de parceiro;
  * Perfis externos nunca têm acesso a dados internos (contatos particulares, observações internas, tabelas de preço bloqueadas pelo CRM ou registros de terceiros);
  * No futuro módulo de **Autorizações**, a área do `PARCEIRO` exibirá apenas os atendimentos/autorizações emitidos especificamente para aquele parceiro.
