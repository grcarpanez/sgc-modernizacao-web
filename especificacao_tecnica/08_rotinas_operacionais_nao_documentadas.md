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

## 4. Fluxo Moderno de Adesão Inicial (Fim do Estoque Pré-Impresso em Aberto)

* **Mudança Operacional:** No legado, geravam-se números de adesão pré-impressos em estoque (`PF_PRE_IMPRESSO`), deixando parcelas `'0000'` em aberto até a venda/pagamento.
* **Diretriz para o Novo Sistema:** Não haverá mais geração prévia de números de adesão em estoque. Toda nova adesão já nasce vinculada ao pagamento imediato da taxa de matrícula/adesão no ato, não ficando em aberto (exceto em eventual fluxo futuro específico de reativação se configurado para cobrança posterior).

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
  2. **Benefícios / Serviços Agregados (`beneficios_adicionais`):** Possibilidade de cadastrar serviços modulares (ex.: *Seguro Funeral*, *Seguro Residencial*, *Cuidado Pet*) que o associado pode contratar de forma avulsa somados ao seu plano base (ex.: *Plano 1 + Seguro Funeral + Pet*).
  3. **Cálculo de Mensalidade:** Na geração de carnês, a mensalidade base $M$ do associado considera o plano vinculado ao seu cadastro somado aos benefícios adicionais ativos contratados por ele (e seus dependentes).

---

## 8. Central de Contas Bancárias de Cobrança (Multibanco)

* **Necessidade Real:** Os dados bancários pertencem às **contas de cobrança** (e não ao cadastro da empresa matriz), podendo existir múltiplas contas/bancos configurados (ex.: Sicoob `756`, Caixa `104`, Banco do Brasil `001`, etc.) com seus próprios parâmetros de agência, conta, cedente, carteira, multa, juros e controle de remessa.
