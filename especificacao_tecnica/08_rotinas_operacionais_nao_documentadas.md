# 08 — Rotinas Operacionais Reais Ainda Não Documentadas no Legado

> **Propósito deste Documento:** Registrar regras e rotinas de trabalho executadas na operação diária da empresa que **não existiam implementadas no sistema legado (`SGCeFeGe.exe`)** — e que, portanto, não constam nos documentos de engenharia reversa (`03`, `04` e `05`). Todas estas rotinas **devem ser implementadas nativamente** no novo sistema web e refletidas na revisão final do `02_schema_postgresql_moderno.sql`.
>
> **Status:** Em construção (atualizado conforme o avanço da leitura dos arquivos `.sql`).

---

## 1. Rotina de Reativação de Cliente (PF e PJ)

### 1.1 Quando Ocorre
* Ex-clientes (**PF ou PJ**) com cadastro **Cancelado (`'C'`)** ou **Inativo (`'I'`)** que desejam retornar;
* Clientes que, mesmo sem cancelamento formal no sistema, estão **"parados no tempo"** (deixaram de pagar há muito tempo) e retornam mediante **negociação/quitação** do débito ou **perdão da dívida** (`situacao_parcela = 'PERDOADA'`).

### 1.2 Regras Fundamentais
1. **Sem Novo Cadastro (CPF / CNPJ Único):**
   * Não se deve criar um novo registro de cliente (`clientes_pf` ou `clientes_pj`) nem duplicar o documento no sistema. O cliente retorna no seu cadastro existente, voltando à situação **`'A'` (Ativo)**.
2. **Mesmo Rito da Adesão Inicial (com Margem Comercial de Negociação / Isenção para PF e PJ):**
   * O processo funciona operacionalmente como uma nova adesão:
     * Atualização dos dados cadastrais / nova ficha de contrato;
     * **Valores Padrão na Configuração + Negociação/Isenção em Tela:** Tanto as taxas de **PF** quanto as de **PJ** (**Taxa de Adesão/Reativação** e **Taxa de Manutenção Anual**) já vêm preenchidas por padrão com o valor definido na configuração administrativa/plano. Na tela de cadastro ou reativação, existe a opção explícita para **isentar** ou **negociar o valor** de cada taxa (dando "gordura comercial" para fechar o contrato mostrando ao cliente/empresa o desconto ou isenção concedida, respeitando a alçada de autorização quando aplicável).
3. **Registro Financeiro Obrigatório no Caixa (Correção de Ponto Cego do Legado):**
   * **Como era feito manualmente no legado:** O sistema legado não reconhecia a entrada financeira da reativação. O operador precisava ir direto ao banco, pegar a última parcela do último carnê, alterar manualmente o `ANOMES` e o `DTVENC` para o mês atual, liquidar/baixar os débitos e aguardar o próximo lote de carnês.
   * **Como deve funcionar no novo sistema:** A rotina de reativação deve gerar um lançamento financeiro próprio (ex.: carnê avulso com `id_parc = 'REATIVACAO'` ou equivalente), registrando **data de pagamento, valor recebido e usuário responsável**, para que o dinheiro entre oficialmente nos relatórios de **Caixa / Contas Recebidas** e na trilha de `auditoria_eventos`.
4. **Tratamento das Parcelas Antigas / Carnê Anterior Interrompido:**
   * **Cenário real:** Cliente cancelou em fevereiro com carnê vigente até novembro (tendo parcelas em aberto de março a novembro e a cota `'2699'`). Em julho, ele solicita reativação para começar novo carnê em agosto.
   * **Regra:** Ao reativar:
     * Débitos passados negociados são liquidados conforme o valor pago (ou encerrados por perdão de dívida/negociação, com registro auditável);
     * Parcelas futuras em aberto do carnê anterior (incluindo a `'ÚNICA'` não paga do carnê interrompido) devem ser **canceladas logicamente** (sem `DELETE` físico, preservando histórico) para que não fiquem como pendência em aberto nem colidam com o novo carnê a ser gerado.
5. **Isenção da Taxa de Manutenção Anual no 1º Carnê Pós-Reativação e Fila de Geração:**
   * **Como era feito manualmente no legado:** Como o cliente já possuía `CARNE` anterior (`NUM_PARC = 12`), o sistema legado enxergava o novo carnê como uma *renovação* e somava automaticamente a taxa de manutenção anual ($A$, ex.: R\$ 12,00) na parcela `'01/12'` e na `'ÚNICA'`. O operador precisava editar o banco manualmente após a geração para remover esse valor.
   * **Como deve funcionar no novo sistema:**
     * Ao quitar a taxa de **Adesão** ou de **Reativação**, o sistema insere automaticamente um item na **`fila_geracao_carnes`** (com isenção de taxa anual: $A = 0,00$).
     * O **primeiro carnê padrão `12+1` (`CARNE_PF`) gerado após uma reativação tem $A = 0,00$**, comportando-se exatamente como o primeiro carnê de um cliente recém-matriculado. A cobrança da taxa anual volta a ocorrer apenas nas renovações subsequentes (2º carnê pós-reativação em diante, via varredura de renovação).
     * **Escopo Exclusivo da Remessa de Carnês:** Apenas carnês padrão **`12+1` (`CARNE_PF`)** entram na `fila_geracao_carnes` e na remessa periódica de geração de carnês. Os boletos de **Adesão** (1 boleto), **Reativação** (1 boleto) e **Renegociação** (acordo) **nunca** entram nessa fila nem na remessa de carnês — são impressos/enviados diretamente ao associado pelo operador no ato da operação, e uma renegociação **jamais** consome a isenção pós-reativação.

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
  1. Manter o campo `anomes` e `data_vencimento` no banco guardando a competência e o vencimento real/original para controle interno;
  2. Quando houver parcelas com vencimento no passado, gravar em **`data_vencimento_remessa`** o próximo vencimento válido do cliente;
  3. **Regra Obrigatória de Igualdade (Banco = Papel):** Tanto o registro bancário **CNAB 240** quanto a **impressão do carnê/boleto em PDF** devem usar exatamente a mesma data (**`COALESCE(data_vencimento_remessa, data_vencimento)`**), evitando qualquer recusa no caixa por divergência de vencimento, enquanto `Nº do Documento` e a observação da lâmina deixam claro a qual mês (`anomes`) a parcela se refere.

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
  3. **Quando o acordo é firmado:** O sistema faz a **baixa técnica imediata** das $N$ parcelas originais (`valor_pago = 0.00`, `situacao_parcela = 'RENEGOCIADA'`, vinculadas ao acordo), removendo-as da inadimplência comum sem inflar o caixa;
  4. O sistema gera as **$M$ novas parcelas do acordo** (`tipo_parcela = 'ACORDO_RENEGOCIACAO'`, `situacao_parcela = 'ABERTA'`) com `nosso_numero` próprio, integradas normalmente à remessa CNAB 240 e com **baixa automática via arquivo de retorno bancário**, preservando o vínculo completo entre o acordo, as $M$ parcelas geradas e as $N$ parcelas originais;
  5. **Quando o cliente quita a última das $M$ parcelas do acordo:** As $N$ parcelas originais mudam automaticamente seu status de **`'RENEGOCIADA'`** para **`'QUITADA_POR_ACORDO'`** (permanecendo sempre com `valor_pago = 0.00` para nunca duplicar o valor recebido no caixa, já que o dinheiro real entrou nas parcelas do acordo);
  6. **Regra da Sobra de Centavos na 1ª Parcela:** Sempre que a divisão do valor total do acordo pelas $M$ parcelas não for exata nos centavos (ex.: R\$ 100,00 dividido em 3x $\to$ base de R\$ 33,33 e sobra de R\$ 0,01), **a diferença de centavos deve ser somada obrigatoriamente na 1ª parcela do acordo (`REN 01/M`)** (1ª de R\$ 33,34 e as demais de R\$ 33,33), garantindo que a soma das parcelas bata exatamente com o total negociado;
  7. **Filtros no Relatório de Inadimplentes:** O relatório de inadimplentes contará com um **Filtro Geral** (onde aparecem tanto clientes com mensalidades vencidas quanto clientes com parcelas de renegociação vencidas) e um **Filtro Exclusivo de Inadimplência de Renegociações** (para visualizar apenas acordos em atraso).

---

## 6. Rastreabilidade de Caixa e Produção por Unidade, Usuário e Meio de Pagamento (RBAC por Filial)

* **Descoberta Operacional:** A tabela `CONVENIOS` do legado era usada exclusivamente para identificar as **Unidades/Filiais** da associação (controle de produção por unidade), e **não** para comissionados (rotina de comissão não existe na operação e não será implantada). Toda a cobrança bancária é centralizada na **Unidade Matriz (`unidades` com `eh_matriz = TRUE` e suas `contas_cobranca`)**.
* **Comportamento Esperado no Novo Sistema:**
  * Cada **usuário** é vinculado a uma **Unidade/Filial (`unidades`)**;
  * Ao cadastrar um associado, a unidade de origem (`unidade_cadastro_id`) é preenchida automaticamente pela unidade do usuário logado (não mais escolhida em lista de "cadastrantes");
  * Toda baixa manual/presencial registra automaticamente o usuário logado, a unidade de recebimento (`unidade_recebimento_id`) e o meio de pagamento (`DINHEIRO`, `PIX`, `CARTAO_DEBITO`, `CARTAO_CREDITO`);
  * **Controle de Acesso (RBAC por Unidade):** Funcionários comuns enxergam e operam apenas dados da **sua unidade**; **Administradores** têm visão e gestão global de todas as unidades;
  * Permitir fechamento de caixa diário e relatórios de produção filtrados por **Unidade**, **Usuário** e **Meio de Pagamento**.

---

## 7. Catálogo de Planos, Pacotes Prontos e Benefícios Agregados

* **Evolução em Relação ao Legado:** O sistema legado trabalhava com apenas um valor padrão global digitado pelo operador na hora de gerar o carnê (`valor_titular`, `valor_dependente` e `valor_acrescimo`). **No novo sistema, o operador não digita mais esses valores na geração do carnê** — todos os valores vêm automaticamente da configuração administrativa do plano e dos benefícios vinculados a cada cliente.
* **Novo Modelo Desejado:**
  1. **Gestão de Planos e Combos (`planos` + `plano_beneficios_inclusos` + `configuracoes_sistema`):** O Administrador pode cadastrar planos independentes ou montar novos **pacotes/combos** selecionando um **plano base + quaisquer benefícios adicionais** (ex.: *Básico R\$ 26,00 + Pet R\$ 5,00*). O sistema **sugere** o valor final somando as partes, mas o Administrador tem autonomia para definir um **preço fechado diferente da soma** (ex.: *Plano Bronze* fechado em R\$ 30,00 + R\$ 3,50 por dependente), além de configurar os valores padrão de **`valor_taxa_adesao`** (matrícula/entrada), **`valor_taxa_reativacao`** (retorno de ex-cliente) e **`valor_taxa_manutencao_anual`** (cobrada anualmente a partir do 2º carnê PF, sem desconto na `UNICA`, e como referência de tabela para PJ) e `desconto_parcela_unica_percent`. Na tela de cadastro/contrato (PF e PJ), esses valores vêm carregados por padrão, com opção para **isentar** ou **negociar o valor** como margem comercial no fechamento do contrato.
  2. **Benefícios / Serviços Agregados Avulsos (`beneficios_adicionais`):** Possibilidade de cadastrar serviços modulares (ex.: *Seguro Funeral*, *Seguro Residencial*, *Cuidado Pet*) que o associado pode contratar de forma avulsa somados ao seu plano base (ex.: *Plano Básico + Pet*), **inclusive de forma individualizada para dependentes** que não fazem parte da cobertura padrão (ex.: plano funerário cobre titular, cônjuge e filhos menores no valor base, mas filhos maiores, pais, sogro/sogra ou netos podem contratar o funeral individualmente mediante acréscimo de valor e preenchimento obrigatório de CPF, estado civil, sexo e data de nascimento).
  3. **Cálculo de Mensalidade:** Na geração de carnês, a mensalidade base $M$ e a taxa anual $A$ vêm diretamente do plano vinculado ao associado somado aos benefícios adicionais ativos do titular e de cada dependente.

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
  * As **Unidades Próprias da Associação** que possuem clínica médica/odontológica/exames também aparecem na rede credenciada (vinculadas a `unidades`), utilizando a tabela extensível **`convenios`** (nascendo com *Particular*, *Associado*, *Parceiros* e *Encaminhamento Prefeitura*, podendo crescer para N convênios no futuro).
* **Flexibilidade Total de Modelos de Benefício (4 Cenários):**
  1. **Valor Fixo** (por convênio em `convenios`: Particular $\times$ Associado, além de Parceiro e Prefeitura quando aplicável);
  2. **Percentual de Desconto Geral (%)** sobre todo o estabelecimento;
  3. **Percentual de Desconto Variável (%)** por subcategoria/grupo de produtos ou serviços;
  4. **Sob Consulta / Tabela Variável** (sem valor ou % fixo, exibindo orientação clara ao associado).
* **Modelo de Precificação em Funil e Escada Anti-Empate (`parceiros_precos_beneficios`):**
  * **Fluxo em Funil (6 Passos):** Na tela de preços do parceiro, os comboboxes filtram em cascata (1. Parceiro $\to$ 2. Local [Todos da Rede ou 1 Filial] $\to$ 3. Especialidade ativa naquele parceiro/local $\to$ 4. Profissional ativo naquele local/especialidade $\to$ 5. Procedimento do catálogo ou descrição livre $\to$ 6. Convênio e preço), sem exigir cadastro prévio de procedimentos por filial e sem precisar duplicar nomes genéricos no catálogo (um único `CONSULTA` é reutilizado com qualquer especialidade: médica, odontológica, jurídica, etc.).
  * **Escada Anti-Empate de 3 Degraus (Zero Empates):** Preço específico de profissional **sempre exige um local definido** (`profissional_id IS NULL OR local_id IS NOT NULL`), garantindo hierarquia estrita sem empates: **3º Profissional na Filial** $\to$ **2º Padrão da Filial** $\to$ **1º Padrão da Rede** *(com atalho na UI para replicar o preço de um profissional em todas as filiais onde ele atende, gravando 1 linha por filial)*.
  * **Zero Duplicidade e Zero Linha Vazia:** O banco impede duas regras ativas duplicadas para a mesma combinação e exige pelo menos Especialidade, Procedimento ou Descrição preenchidos.
* **Conformidade Legal (CRM e LGPD):**
  * **Regra Crítica do CRM (Proibição de Divulgação Pública de Preços):** O servidor/API **jamais** envia valores (R\$) ou percentuais (%) em rotas públicas ou no Guia PDF enviado ao associado quando o cadeado `bloqueio_divulgacao_valores` estiver ativo (padrão `TRUE` para todo cadastro, destravável **exclusivamente por `ADMINISTRADOR`**). A tabela resumida com menores preços é **estritamente interna**.
  * **Separação LGPD (`LGPD.pdf`):** Dados particulares/pessoais do profissional e contatos internos (`parceiros_contatos`) ficam isolados do guia público; redes sociais (Instagram, Facebook e WhatsApp) possuem permissão individual (`SIM`/`NÃO`) de divulgação, e o sistema deve gerar o **Termo LGPD em PDF** para assinatura e arquivamento em `parceiros_documentos`.
* **Governança e Manutenção da Rede:**
  * Controle de **duas datas independentes** (`cadastro_atualizado_em` e `precos_atualizados_em`) com alertas automáticos de revisão semestral (6 meses) e botão de confirmação quando não houver alteração;
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

---

## 17. Regras de Unicidade Cruzada de CPF e Exclusão Lógica de Dependentes (*Soft Delete*)

* **Exclusão Lógica (*Soft Delete*) de Dependentes (PF e PJ):**
  * Ao remover um dependente, o sistema **nunca apaga o registro fisicamente** (como ocorria no legado). Ele marca **`ativo = FALSE`**, registra **`data_exclusao`** (e motivo opcional), preserva todo o histórico (inclusive futuro histórico de utilização/economia) e **libera imediatamente o CPF** para outro vínculo.
  * A data de inclusão passa a ser registrada por **`created_at`** (no ETL do legado, preencher com a data de inscrição do titular ou data da migração).
* **Bloqueio Cruzado de CPF Ativo dentro do PF (Válido para Novos Cadastros/Inclusões):**
  * Antes de cadastrar um Titular PF, incluir um Dependente PF ou reativar um cadastro, o backend verifica se o CPF já está **Ativo (`situacao = 'A'`)** em outro vínculo PF (como Titular PF Ativo ou como Dependente PF Ativo de um Titular Ativo);
  * Se estiver ativo em outro lugar, **bloqueia** a operação e orienta que o interessado solicite primeiro sua exclusão/cancelamento no vínculo atual;
  * Se o vínculo anterior já estiver **Cancelado (`'C'`)** ou **Inativo (`'I'`)**, o CPF está **livre** (não trava por eventuais parcelas antigas de carnê interrompido).
* **Cruzamento PF $\times$ PJ (Alerta Forte com Confirmação):**
  * Quando uma empresa PJ incluir um funcionário (ou dependente) cujo CPF já está ativo no PF — ou vice-versa — o sistema **não bloqueia** nem cancela o plano particular automaticamente, mas exibe um **alerta destacado na tela exigindo confirmação** do operador para orientar o associado e evitar cobrança dupla por descuido.
* **Migração do Legado (`ABAC.FDB`):**
  * Contratos antigos já assinados que eventualmente possuam CPF cruzado não serão excluídos na migração; entrarão preservados após o **Relatório Prévio de Saneamento** e serão sinalizados para regularização gradual, aplicando-se a trava rígida a partir dos novos cadastros.

---

## 18. Alçada e Liberação de Desconto / Perdão de Dívida (Presencial ou Remota)

* **Regra Geral:** Atendentes comuns não podem conceder descontos em acordos nem perdoar dívidas antigas em reativações por conta própria. Apenas usuários com a permissão **`perm_autorizar_desconto_perdao`** (Administradores e Gerentes de unidade) têm essa alçada.
* **Os 2 Fluxos de Liberação na Hora da Operação:**
  1. **Liberação Presencial na Unidade ("Estilo Caixa de Supermercado"):**
     * Nas unidades que possuem Gerente local, o gerente aproxima-se da tela da atendente e digita seu próprio login/senha na janela de autorização para liberar imediatamente aquela operação específica.
  2. **Liberação Remota pelo Administrador (Unidades sem Gerente):**
     * Nas unidades sem gerente presencial, o sistema gera uma solicitação vinculada àquela operação e oferece ao Administrador duas vias rápidas:
       * **Painel de Aprovações:** Notificação no painel do Administrador para aprovar ou rejeitar diretamente no sistema; **ou**
       * **Código Aleatório Único por E-mail:** O sistema envia um código numérico/alfanumérico aleatório para o e-mail do Administrador, que repassa o código à colaboradora para validar na tela.
     * **Segurança do Código:** Cada operação gera um **código novo e exclusivo** (nunca reutilizável), com prazo curto de validade (ex.: 15 minutos), que morre imediatamente após ser usado.
* **Auditoria Obrigatória:** Todas as liberações registram quem solicitou, quem autorizou, o modo de liberação, o valor original, o valor perdoado/descontado e o motivo.

---

## 19. Regras Completas de Elegibilidade na Geração/Renovação de Carnês (`CARNE_PF`)

* **Parâmetros Administrativos:** A tolerância máxima de parcelas vencidas (`max_parcelas_aberto_renovacao`) e a janela de antecipação (`60 dias`) são configuradas exclusivamente pelo **Administrador** em área administrativa (`configuracoes_sistema`), sem edição livre na tela de geração de carnês.
* **Critérios Obrigatórios para Renovação Automática (`CARNE_PF` `12+1`):**
  1. Cliente Ativo (`situacao = 'A'`) e sem carnê `CARNE_PF` futuro já emitido para o próximo período;
  2. **Quitação até a 10ª Parcela:** As parcelas `01/12` até `10/12` do último carnê `CARNE_PF` devem estar quitadas (manualmente, via banco ou por cascata da `'ÚNICA'`), impedindo geração infinita de carnês para quem parou de pagar;
  3. **Janela Máxima de 60 Dias à Frente:** O vencimento previsto da `01/12` do próximo carnê deve ser $\le \text{Hoje} + 60\text{ dias}$ — garantindo que clientes que quitam a `'ÚNICA'` ou adiantam o carnê não recebam o próximo carnê com meses/ano de antecedência;
  4. **Tolerância de Parcelas Comuns Vencidas:** Quantidade de parcelas comuns vencidas em aberto $\le$ tolerância configurada pelo Administrador;
  5. **Bloqueio por Débito em Renegociação (`RENEGOCIACAO`):** Se o cliente possuir qualquer parcela vencida em aberto de acordo/renegociação, a geração automática do carnê é **bloqueada**.
* **Relatório Imediato de Carnês Bloqueados e Reavaliação Contínua:**
  * Ao rodar a geração de carnês, o sistema gera imediatamente um **Relatório de Carnês Bloqueados na Geração** listando cada cliente impedido e o motivo exato (ex.: *débito em negociação em aberto*, *inadimplência acima da tolerância*) para a equipe entrar em contato;
  * Esses clientes **permanecem elegíveis/pendentes** para a próxima geração: assim que regularizarem a pendência, a varredura seguinte os inclui normalmente, sem precisar de intervenção manual.

---

## 20. Remoção de Dependente com Carnê em Andamento (Abatimento via CNAB `'04'`)

* **Contexto Real:** Quando um associado exclui um dependente (por falecimento ou outro motivo) enquanto já possui um carnê anual em andamento com parcelas futuras em aberto e já registradas no banco, o valor mensal daquele dependente precisa deixar de ser cobrado nas parcelas restantes.
* **Comportamento Esperado no Sistema Novo:**
  1. Ao confirmar a exclusão do dependente, o sistema detecta automaticamente as parcelas futuras em aberto (`ABERTA` e não vencidas) do carnê `CARNE_PF` vigente e calcula o valor total a abater (ex.: $7 \text{ parcelas} \times \text{valor do dependente}$).
  2. O atendente escolhe entre duas opções na tela:
     * **Abatimento distribuído nas parcelas futuras (Padrão Ideal):** Aplica `valor_abatimento` igual ao valor do dependente em cada parcela futura em aberto (e proporcionalmente na `'UNICA'`, se ainda em aberto, aplicando o desconto de 20% sobre o valor mensal abatido).
     * **Abatimento concentrado na próxima parcela:** Soma o total a abater em uma única parcela (a próxima em aberto), mantendo as demais no valor cheio.
  3. **Envio Automático ao Sicoob (CNAB 240 — Movimento `'04'`):** Para todas as parcelas afetadas que já estavam registradas no banco (`registrado = 'S'`), o sistema marca-as para envio na próxima remessa CNAB 240 com **Código de Movimento `'04'` (Concessão de Abatimento)** — gerando o par obrigatório **`P` + `Q` ambos com código `'04'`** (sem Segmento `R`, conforme regra validada no Validador Sicoob em `04_regras_negocio_financeiro_cnab_arquivos.md`) e preenchendo o campo `Valor do Abatimento` (posições `181..195` do Segmento `P`), permitindo que o associado pague com o valor corrigido diretamente no banco/lotérica/Pix usando o boleto original, reimpresso ou enviado por WhatsApp.

---

## 21. Visão Futura: Integração Direta via API Sicoob Cobrança Bancária v3 (Tempo Real + Boleto Híbrido Pix)

> **Status:** Planejado como **evolução futura** (pós-estabilização do sistema com CNAB 240). Mantido documentado para implementação segura quando a cooperativa liberar o acesso e houver validação completa em ambiente de homologação.

* **Base URL Oficial:** `https://api.sicoob.com.br/cobranca-bancaria/v3`
* **Pré-Requisitos de Produção:**
  * Habilitação do serviço de API de Cobrança junto à cooperativa do Sicoob;
  * Cadastro da aplicação no Portal Sicoob Developers (`client_id`) + certificado digital da Associação (**e-CNPJ A1** / certificado mTLS) armazenado com segurança fora do código-fonte (em cofre de segredos / variáveis de ambiente).
* **Ganho Operacional no Balcão ("Cadastro $\to$ Carnê com Pix na Hora"):**
  * O associado chega na unidade, realiza o cadastro e quita a Taxa de Adesão;
  * O sistema registra imediatamente as **13 parcelas** (`UNICA` + `01/12`..`12/12`) via `POST /boletos` com **`codigoCadastrarPIX`** ativado;
  * O Sicoob retorna na hora o código de barras, linha digitável e o **QR Code Pix (Pix Copia e Cola)** de cada parcela;
  * O sistema gera o **PDF do carnê completo na mesma hora** já com o QR Code Pix impresso em cada lâmina, permitindo que o associado saia do balcão com o carnê pronto para pagamento imediato.
* **Mapeamento Completo dos Endpoints da API v3:**
  1. **Inclusão / Registro Instantâneo (`POST /boletos`):** Registra boletos individuais ou de novos carnês em tempo real, com suporte a `codigoCadastrarPIX` (boleto híbrido Pix) e opção `gerarPdf`.
  2. **Alteração e Abatimento em Tempo Real (`PATCH /boletos/{nossoNumero}`, modelo `BoletoAlteracao`):** Aplica instantaneamente **abatimentos** (ex.: remoção de dependente no meio do carnê), prorrogação de vencimento (`prorrogacaoVencimento`), alteração de valor nominal (`valorNominal`), desconto, multa, juros de mora e Pix — sem aguardar remessa do dia seguinte.
  3. **Baixa / Cancelamento Imediato (`POST /boletos/{nossoNumero}/baixar`):** Ao receber pagamento no balcão (dinheiro/cartão/maquininha) ou cancelar contrato, comanda a baixa imediata no Sicoob para evitar pagamento em duplicidade.
  4. **Consultas e 2ª Via (`GET /boletos`, `GET /boletos/segunda-via`, `GET /pagadores/{numeroCpfCnpj}/boletos`, `GET /boletos/faixas-nosso-numero`):** Consulta situação real do título no banco, faixas de nosso número e emissão de 2ª via.
  5. **Atualização de Pagador (`PUT /pagadores`):** Sincroniza alterações de endereço/e-mail do associado com o banco.
  6. **Baixa Automática em Tempo Real (`POST /webhooks` + `GET /boletos/movimentacoes`):**
     * **Webhook:** O Sicoob notifica nosso servidor automaticamente assim que qualquer boleto/Pix é liquidado, disparando a baixa automática (inclusive cascata da `'UNICA'`);
     * **Movimentações (`POST /boletos/movimentacoes` / `/download`):** Rotina agendada diária de conferência ("rede de segurança") para garantir que nenhuma liquidação deixou de ser conciliada caso algum webhook falhe.
  7. **Negativação e Protesto (Opcional Futuro):** Endpoints `/boletos/{nossoNumero}/negativacoes` e `/protestos` disponíveis caso a associação adote essa régua no futuro.
* **Cuidados Arquiteturais Obrigatórios:**
  * **Fila Assíncrona para Lotes Grandes:** Na geração em massa de renovações (centenas/milhares de boletos), enfileirar os envios em segundo plano (*worker*/fila) com controle de taxa (*rate limit*) e retentativas idempotentes para não travar a interface nem sofrer bloqueio da API;
  * **Convivência Híbrida com CNAB 240:** Manter `CNAB_240` como modo padrão inicial e contingência em `contas_cobranca` (`modo_integracao`), permitindo ativar `API_SICOOB_V3` por conta quando estiver 100% homologado.
