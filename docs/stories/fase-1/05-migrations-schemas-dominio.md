# [F1-05] Migrations, schemas e seeds do domínio de quizzes

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `backend`
> **Branch:** `feature/05-migrations-schemas-dominio` · **Estimativa:** 5 pontos · **Depende de:** F1-03

## 1. Contexto de negócio

Todo o conteúdo da plataforma — e das fases 2, 3 e 4 — se apoia em três entidades: o quiz, suas
perguntas e as alternativas de cada pergunta. Esta story cria a estrutura de dados com as
restrições de integridade que impedem estados inválidos no banco, independentemente do que a
aplicação faça.

## 2. User story

**Como** pessoa desenvolvedora,
**quero** as tabelas, schemas e restrições do domínio de quizzes criados e testados,
**para que** as regras de negócio das stories seguintes tenham uma base íntegra e confiável.

## 3. Escopo

### Dentro
- Migrations de `quizzes`, `questions` e `answer_options`.
- Schemas Ecto `LiveQuiz.Quizzes.Quiz`, `LiveQuiz.Quizzes.Question` e `LiveQuiz.Quizzes.AnswerOption`
  com seus changesets de validação.
- Foreign keys em cascata, índices, `NOT NULL`, check constraints e índices únicos (inclusive o parcial).
- Configuração do Gettext em `pt_BR` e tradução das mensagens de erro do Ecto (`errors.po`).
- Dependência `tzdata` e helper de formatação de data/hora em `America/Sao_Paulo`.
- `priv/repo/seeds.exs` com usuário e quizzes de demonstração.
- Testes de schema/changeset e de constraints de banco.

### Fora
- Funções de contexto (`create_quiz`, `create_question`, etc.) — stories F1-06 a F1-08.
- **Validações de conjunto das alternativas** (quantidade, correta única, textos duplicados): o
  changeset de `Question` entregue aqui é o **base** (texto, posição e `cast_assoc`); as validações
  de conjunto são acrescentadas na story F1-07, que é dona dessa regra.
- Qualquer tela ou endpoint.
- Campos das fases 3 e 4 (`time_limit_seconds`, pontuação, status de publicação).

## 4. Decisões de arquitetura

- **Contexto `LiveQuiz.Quizzes`** (plural, convenção Phoenix) contendo os três schemas.
- **`ON DELETE CASCADE` declarado somente no banco** (AD-08, AD-16): excluir um quiz apaga
  perguntas e alternativas, e nenhum órfão é possível nem por acesso direto ao banco. As
  associações Ecto **não** usam `on_delete:` — isso faria a aplicação emitir deletes redundantes
  antes do cascade do Postgres.
- **`position` sequencial `1..n`** com unicidade por pai (AD-07). A constraint é criada como
  `UNIQUE ... DEFERRABLE INITIALLY DEFERRED` para permitir trocas de posição dentro de uma
  transação sem violação intermediária.
- **Exatamente uma alternativa correta** garantida por índice único parcial
  `unique (question_id) WHERE is_correct` (AD-06). O "pelo menos uma" é responsabilidade da
  transação de criação/edição da pergunta (F1-07).
- **Check constraints de tamanho** replicam no banco os limites validados no changeset — validação
  de aplicação não substitui integridade de banco (documento, seção 9.3).
- **Mensagens de erro em pt-BR via Gettext**: o Ecto emite as mensagens em inglês
  (`"can't be blank"`). Como a aplicação é monolíngue em português, a tradução vive em um único
  `errors.po` e serve tanto às LiveViews quanto às views JSON — em vez de `message:` repetido em
  cada validação.
- **Datas em UTC no banco, convertidas apenas na apresentação**: a conversão para
  `America/Sao_Paulo` fica em um helper de formatação usado pelas telas; a API responde ISO 8601 UTC.
- **Sem `type` na pergunta e sem status no quiz** (AD-14, AD-09).

## 5. Modelo de dados e migrations

### `quizzes`

| Coluna | Tipo | Restrições |
|---|---|---|
| `id` | bigserial | PK |
| `owner_id` | references(:users) | NOT NULL, `on_delete: :delete_all`, indexado |
| `title` | string(120) | NOT NULL, check `char_length(title) BETWEEN 3 AND 120` |
| `description` | text | nullable, check `description IS NULL OR char_length(description) <= 500` |
| `inserted_at` / `updated_at` | timestamps | NOT NULL |

Índices: `index(:quizzes, [:owner_id])`, `index(:quizzes, [:owner_id, :updated_at])` (usado pelo dashboard).

### `questions`

| Coluna | Tipo | Restrições |
|---|---|---|
| `id` | bigserial | PK |
| `quiz_id` | references(:quizzes) | NOT NULL, `on_delete: :delete_all`, indexado |
| `text` | text | NOT NULL, check `char_length(text) BETWEEN 3 AND 500` |
| `position` | integer | NOT NULL, check `position > 0` |
| `inserted_at` / `updated_at` | timestamps | NOT NULL |

Constraint: `UNIQUE (quiz_id, position) DEFERRABLE INITIALLY DEFERRED`.

### `answer_options`

| Coluna | Tipo | Restrições |
|---|---|---|
| `id` | bigserial | PK |
| `question_id` | references(:questions) | NOT NULL, `on_delete: :delete_all`, indexado |
| `text` | string(200) | NOT NULL, check `char_length(text) BETWEEN 1 AND 200` |
| `position` | integer | NOT NULL, check `position BETWEEN 1 AND 4` |
| `is_correct` | boolean | NOT NULL, default `false` |
| `inserted_at` / `updated_at` | timestamps | NOT NULL |

Constraints e índices:
- `UNIQUE (question_id, position) DEFERRABLE INITIALLY DEFERRED`;
- `CREATE UNIQUE INDEX answer_options_single_correct_index ON answer_options (question_id) WHERE is_correct`.

### Exemplo de migration (trechos essenciais)

```elixir
create table(:questions) do
  add :quiz_id, references(:quizzes, on_delete: :delete_all), null: false
  add :text, :text, null: false
  add :position, :integer, null: false
  timestamps(type: :utc_datetime)
end

create index(:questions, [:quiz_id])
create constraint(:questions, :position_must_be_positive, check: "position > 0")
create constraint(:questions, :text_length, check: "char_length(text) between 3 and 500")

execute(
  "ALTER TABLE questions ADD CONSTRAINT questions_quiz_id_position_key UNIQUE (quiz_id, position) DEFERRABLE INITIALLY DEFERRED",
  "ALTER TABLE questions DROP CONSTRAINT questions_quiz_id_position_key"
)
```

```elixir
create unique_index(:answer_options, [:question_id],
  where: "is_correct",
  name: :answer_options_single_correct_index
)
```

## 6. Contratos técnicos

### `LiveQuiz.Quizzes.Quiz`

```elixir
schema "quizzes" do
  field :title, :string
  field :description, :string
  belongs_to :owner, LiveQuiz.Accounts.User
  has_many :questions, LiveQuiz.Quizzes.Question, preload_order: [asc: :position]
  field :questions_count, :integer, virtual: true
  timestamps(type: :utc_datetime)
end

def changeset(quiz, attrs)
```

Validações: `title` obrigatório e 3..120 (com `trim`); `description` até 500;
`assoc_constraint(:owner)`.

### `LiveQuiz.Quizzes.Question`

```elixir
schema "questions" do
  field :text, :string
  field :position, :integer
  belongs_to :quiz, LiveQuiz.Quizzes.Quiz
  has_many :answer_options, LiveQuiz.Quizzes.AnswerOption, preload_order: [asc: :position]
  timestamps(type: :utc_datetime)
end

def changeset(question, attrs)
```

Validações **desta story** (changeset base): `text` obrigatório e 3..500; `position` obrigatório e
maior que zero; `cast_assoc(:answer_options, required: true, with: &AnswerOption.changeset/2)`;
`unique_constraint([:quiz_id, :position], name: :questions_quiz_id_position_key)`.

> As validações de **conjunto** das alternativas (exatamente 4, exatamente 1 correta, sem textos
> duplicados) **não** são implementadas aqui: elas pertencem à story F1-07, que as acrescenta a
> este mesmo changeset. Não antecipe essa implementação.

### `LiveQuiz.Quizzes.AnswerOption`

```elixir
schema "answer_options" do
  field :text, :string
  field :position, :integer
  field :is_correct, :boolean, default: false
  belongs_to :question, LiveQuiz.Quizzes.Question
  timestamps(type: :utc_datetime)
end

def changeset(answer_option, attrs)
```

Validações: `text` obrigatório e 1..200; `position` obrigatório, entre 1 e 4;
`is_correct` obrigatório (default `false`);
`unique_constraint(:question_id, name: :answer_options_single_correct_index, message: "já existe uma alternativa correta")`.

### Gettext e formatação de data

```elixir
# config/config.exs
config :live_quiz, LiveQuizWeb.Gettext, default_locale: "pt_BR", locales: ~w(pt_BR)
# mix.exs
{:tzdata, "~> 1.1"}
# config/config.exs
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
```

Traduzir em `priv/gettext/pt_BR/LC_MESSAGES/errors.po` no mínimo: `can't be blank`,
`should be at least %{count} character(s)`, `should be at most %{count} character(s)`,
`has already been taken`, `is invalid`, `does not match confirmation`.

Criar `LiveQuizWeb.Formatters` (ou função no `CoreComponents`) com:

```elixir
@spec format_date(DateTime.t()) :: String.t()      # "29/08/2026" em America/Sao_Paulo
@spec format_datetime(DateTime.t()) :: String.t()  # "29/08/2026 19:32"
```

### Fixtures de teste

Criar `test/support/fixtures/quizzes_fixtures.ex`:

```elixir
@spec quiz_fixture(Scope.t(), map()) :: Quiz.t()
@spec question_fixture(Scope.t(), Quiz.t(), map()) :: Question.t()  # cria as 4 alternativas válidas
```

Ambas recebem o `scope` (e não o `%User{}`), para espelhar a assinatura das funções de contexto.

### Seeds (`priv/repo/seeds.exs`)

- executar apenas em `:dev`;
- criar usuário `demo@livequiz.dev` / senha `demo123456789` (já confirmado);
- criar 2 quizzes com 3 perguntas completas cada;
- ser idempotente (não duplicar em execuções repetidas).

## 7. Regras de negócio e validações

| Regra | Onde é garantida |
|---|---|
| Quiz sempre tem dono | FK `owner_id` NOT NULL + `assoc_constraint` |
| Título entre 3 e 120 caracteres | changeset + check constraint |
| Descrição opcional, até 500 | changeset + check constraint |
| Pergunta pertence a exatamente um quiz | FK `quiz_id` NOT NULL |
| Alternativa pertence a exatamente uma pergunta | FK `question_id` NOT NULL |
| Posição de pergunta única dentro do quiz | unique constraint deferrable |
| Posição de alternativa única e entre 1 e 4 | unique constraint deferrable + check |
| No máximo uma alternativa correta por pergunta | índice único parcial |
| Excluir quiz remove perguntas e alternativas | `ON DELETE CASCADE` |

## 8. Critérios de aceite

```gherkin
Cenário: Estrutura criada
  Quando executo "mix ecto.migrate"
  Então as tabelas quizzes, questions e answer_options existem com suas restrições

Cenário: Exclusão em cascata
  Dado um quiz com 2 perguntas e 8 alternativas
  Quando o quiz é excluído diretamente pelo Repo
  Então nenhuma pergunta e nenhuma alternativa daquele quiz permanece no banco

Cenário: Duas alternativas corretas são rejeitadas pelo banco
  Dada uma pergunta com uma alternativa correta
  Quando tento inserir uma segunda alternativa com is_correct verdadeiro para a mesma pergunta
  Então o banco recusa a operação por violação de índice único

Cenário: Posição duplicada é rejeitada
  Dado um quiz com uma pergunta na posição 1
  Quando tento inserir outra pergunta na posição 1 no mesmo quiz
  Então o banco recusa a operação ao final da transação

Cenário: Troca de posições dentro de uma transação
  Dado um quiz com perguntas nas posições 1 e 2
  Quando dentro de uma única transação eu troco as posições das duas
  Então a transação é concluída com sucesso graças à constraint deferrable

Cenário: Título inválido é rejeitado
  Quando tento inserir um quiz com título de 2 caracteres
  Então o changeset é inválido
  E o banco também recusaria a inserção pela check constraint

Cenário: Mensagens de erro em português
  Quando um changeset de quiz é inválido por título em branco
  Então a mensagem traduzida é "não pode ficar em branco"

Cenário: Seeds
  Dado o ambiente de desenvolvimento
  Quando executo "mix run priv/repo/seeds.exs" duas vezes
  Então existe um usuário demo com 2 quizzes completos
  E nenhum registro é duplicado
```

## 9. Cenários de teste

### Schemas (`test/live_quiz/quizzes/*_test.exs`)
- changeset de quiz válido e inválido (título curto, título longo, descrição longa, título ausente);
- changeset de pergunta válido e inválido (texto curto/longo, posição ausente, posição zero ou negativa);
- changeset de alternativa válido e inválido (texto vazio, texto longo, posição fora de 1..4).

### Constraints de banco (mesmo arquivo ou `quizzes_constraints_test.exs`)
- inserir duas alternativas corretas na mesma pergunta retorna erro de constraint;
- inserir duas perguntas com a mesma posição no mesmo quiz retorna erro ao commitar;
- trocar posições dentro de uma transação funciona;
- excluir quiz remove perguntas e alternativas em cascata;
- inserir pergunta com `quiz_id` inexistente retorna erro de FK.

### Fixtures
- `quiz_fixture/2` e `question_fixture/3` geram registros válidos e são usadas pelas stories seguintes.

### Tradução e formatação
- mensagem de campo obrigatório traduzida para "não pode ficar em branco";
- mensagens de tamanho mínimo e máximo traduzidas;
- `format_date/1` converte um `DateTime` UTC das 23h para a data do dia anterior em São Paulo.

## 10. Definition of Ready

- [x] Campos, tipos e limites definidos.
- [x] Regra de 4 alternativas fixas e 1 correta definida.
- [x] Estratégia de `position` e de exclusão definida.
- [x] Contexto `Accounts` disponível para a FK de `owner_id` (F1-03).

## 11. Definition of Done

- [ ] Migrations aplicam e revertem sem erro (`mix ecto.migrate` e `mix ecto.rollback`).
- [ ] Schemas e changesets implementados com as validações listadas.
- [ ] Todas as constraints do item 5 presentes no banco.
- [ ] Fixtures de teste disponíveis em `test/support/fixtures/quizzes_fixtures.ex`.
- [ ] Gettext em `pt_BR` configurado e `errors.po` traduzido.
- [ ] `tzdata` instalado e helper de formatação de data implementado.
- [ ] Nenhuma associação Ecto usando `on_delete:` (cascata só no banco).
- [ ] Changeset de `Question` entregue **sem** as validações de conjunto (escopo da F1-07).
- [ ] Seeds idempotentes rodando em dev.
- [ ] Testes de schema e de constraint passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-03** — tabela `users` para a FK `owner_id`.

## 13. Riscos e pontos de atenção

- `ALTER TABLE ... DEFERRABLE` precisa ser feito via `execute/2` com o comando de rollback explícito,
  pois `create unique_index` não suporta a opção.
- Ecto pode não reconhecer automaticamente o nome da constraint criada por `execute/2`: declarar o
  `name:` explicitamente no `unique_constraint/3` do changeset.
- O índice parcial impede duas corretas, mas **não** garante que exista uma — isso é regra da transação (F1-07).
- Seeds usam o contexto `Accounts` para criar o usuário com senha hasheada; não inserir direto no Repo.

## 14. Estimativa

**5 pontos** — três tabelas com constraints não triviais, testes de integridade e a configuração de locale/fuso.
