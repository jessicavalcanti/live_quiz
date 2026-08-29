# [F1-06] Contexto `Quizzes`: CRUD de quiz com escopo por dono

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `backend`
> **Branch:** `feature/06-contexto-quiz-crud` · **Estimativa:** 3 pontos · **Depende de:** F1-05

## 1. Contexto de negócio

O quiz é a unidade de conteúdo da plataforma: é ele que, nas fases seguintes, será aberto em uma
sala e jogado por vários participantes. Esta story entrega as operações de negócio de quiz — criar,
listar, consultar, editar e excluir — sempre restritas ao seu dono, para serem consumidas tanto pela
interface LiveView quanto pela API JSON.

## 2. User story

**Como** usuário autenticado,
**quero** criar, consultar, editar e excluir os meus quizzes,
**para que** eu tenha controle total sobre o conteúdo que produzo, sem acessar o conteúdo de outras pessoas.

## 3. Escopo

### Dentro
- Funções públicas de quiz no contexto `LiveQuiz.Quizzes`.
- Listagem paginada com busca por título e contagem de perguntas.
- Escopo obrigatório por dono em todas as operações.
- `playable?/1`.
- Testes de contexto.

### Fora
- Perguntas e alternativas (stories F1-07 e F1-08).
- Telas (F1-09 a F1-12) e endpoints (F1-14).

## 4. Decisões de arquitetura

- **`scope` como primeiro argumento** de toda função pública, filtrando por
  `owner_id == scope.user.id` **dentro da query** (AD-10). Nunca `Repo.get` seguido de comparação:
  a autorização é parte da consulta.
- **404 para não-dono**: `get_quiz!/2` levanta `Ecto.NoResultsError` quando o quiz não pertence ao
  escopo, resultando em 404 tanto no LiveView quanto na API.
- **Paginação por offset** (`page`/`per_page`), suficiente para o volume da fase e igual na UI e na API.
- **Busca com `ILIKE`** sobre o título, sanitizando `%` e `_` do termo informado.
- **Contagem de perguntas por subquery agregada**, evitando N+1 (decisão F3 do refinamento). A
  listagem paginada usa **duas** consultas: uma para a página de dados (com o `COUNT` agregado por
  quiz) e uma para o `total_entries`. O que se elimina é a consulta **por linha**, não a de total.
- **`questions_count` sempre preenchido** (AD-15): `list_quizzes/2`, `get_quiz!/2` e
  `get_quiz_with_questions!/2` retornam o campo virtual populado. Nenhum consumidor precisa saber
  como a contagem foi obtida.
- **`playable?/1` derivado** de `questions_count` em vez de coluna de status (AD-09); a função não
  executa query própria.

## 5. Modelo de dados e migrations

Nenhuma migration nova. Usa as tabelas criadas em **F1-05**.
O índice `index(:quizzes, [:owner_id, :updated_at])` sustenta a ordenação da listagem.

## 6. Contratos técnicos

Arquivo: `lib/live_quiz/quizzes.ex`

```elixir
@doc "Lista os quizzes do usuário do escopo, paginados, com a contagem de perguntas."
@spec list_quizzes(Scope.t(), keyword()) :: %{
        entries: [Quiz.t()],
        page: pos_integer(),
        per_page: pos_integer(),
        total_entries: non_neg_integer(),
        total_pages: non_neg_integer()
      }
def list_quizzes(scope, opts \\ [])
# opts: [page: 1, per_page: 20, search: nil]
# cada entry recebe o campo virtual questions_count

@doc """
Busca um quiz do escopo, com questions_count preenchido.
Levanta Ecto.NoResultsError se não existir ou não pertencer ao usuário.
"""
@spec get_quiz!(Scope.t(), integer() | String.t()) :: Quiz.t()
def get_quiz!(scope, id)

@doc """
Igual a get_quiz!/2, porém com as perguntas e alternativas pré-carregadas e ordenadas por position.
Também retorna questions_count preenchido.
"""
@spec get_quiz_with_questions!(Scope.t(), integer() | String.t()) :: Quiz.t()
def get_quiz_with_questions!(scope, id)

@spec create_quiz(Scope.t(), map()) :: {:ok, Quiz.t()} | {:error, Ecto.Changeset.t()}
def create_quiz(scope, attrs)

@spec update_quiz(Scope.t(), Quiz.t(), map()) :: {:ok, Quiz.t()} | {:error, Ecto.Changeset.t()}
def update_quiz(scope, quiz, attrs)

@spec delete_quiz(Scope.t(), Quiz.t()) :: {:ok, Quiz.t()} | {:error, Ecto.Changeset.t()}
def delete_quiz(scope, quiz)

@spec change_quiz(Quiz.t(), map()) :: Ecto.Changeset.t()
def change_quiz(quiz, attrs \\ %{})

@doc """
Indica se o quiz já pode ser jogado: possui ao menos uma pergunta.

Lê o campo virtual questions_count, que todas as funções de leitura desta lista preenchem.
Não executa query. Recebendo um quiz com questions_count nil (montado à mão), levanta ArgumentError.
"""
@spec playable?(Quiz.t()) :: boolean()
def playable?(quiz)
```

### Campo virtual

Adicionar em `LiveQuiz.Quizzes.Quiz`:

```elixir
field :questions_count, :integer, virtual: true
```

### Query de listagem (referência)

```elixir
from q in Quiz,
  where: q.owner_id == ^scope.user.id,
  left_join: qs in assoc(q, :questions),
  group_by: q.id,
  order_by: [desc: q.updated_at, desc: q.id],
  select: %{q | questions_count: count(qs.id)}
```

Busca: `where: ilike(q.title, ^"%#{escaped_term}%")`, aplicada apenas quando `search` for uma string
não vazia após `String.trim/1`.

### Contrato de paginação

- `page` default `1`, mínimo `1`;
- `per_page` default `20`, mínimo `1`, máximo `100`;
- valores inválidos ou não numéricos caem no default;
- `total_pages` é `0` quando não há resultados;
- `page` além do total retorna `entries: []` sem erro.

## 7. Regras de negócio e validações

- `owner_id` é sempre `scope.user.id`; nunca aceitar `owner_id` vindo de `attrs`.
- `update_quiz/3` e `delete_quiz/2` só operam sobre quiz já obtido via `get_quiz!/2` (portanto já do dono).
- Título obrigatório, 3–120 caracteres, com `trim` antes de validar.
- Descrição opcional, até 500 caracteres; string vazia é normalizada para `nil`.
- Excluir quiz remove perguntas e alternativas em cascata (garantido no banco).
- `playable?/1` é `true` quando `questions_count > 0` — toda pergunta persistida já é válida e
  completa por construção (F1-07).
- `questions_count` é sempre um inteiro nas structs devolvidas pelo contexto; nunca `nil`.

## 8. Critérios de aceite

```gherkin
Cenário: Criar quiz válido
  Dado que estou autenticado como "Ana"
  Quando crio um quiz com título "Geografia" e descrição "Capitais"
  Então o quiz é persistido com Ana como proprietária

Cenário: Criar quiz sem título
  Quando tento criar um quiz sem título
  Então recebo um changeset inválido com erro no campo título
  E nada é persistido

Cenário: Listar apenas os meus quizzes
  Dado que Ana possui 2 quizzes e Bruno possui 3
  Quando Ana lista seus quizzes
  Então vejo exatamente os 2 quizzes de Ana

Cenário: Listagem traz a contagem de perguntas
  Dado um quiz de Ana com 3 perguntas
  Quando Ana lista seus quizzes
  Então o quiz retornado informa questions_count igual a 3

Cenário: Listagem paginada
  Dado que Ana possui 25 quizzes
  Quando Ana lista a página 2 com 20 por página
  Então recebo 5 quizzes, total_entries 25 e total_pages 2

Cenário: Busca por título
  Dado que Ana possui os quizzes "Geografia" e "História"
  Quando Ana busca por "geo"
  Então recebo apenas o quiz "Geografia"

Cenário: Acessar quiz de outra pessoa
  Dado um quiz pertencente a Bruno
  Quando Ana tenta obtê-lo por get_quiz!/2
  Então é levantado Ecto.NoResultsError

Cenário: Editar quiz
  Dado um quiz meu com título "Geografia"
  Quando atualizo o título para "Geografia do Brasil"
  Então a alteração é persistida e updated_at é atualizado

Cenário: Excluir quiz com perguntas
  Dado um quiz meu com 2 perguntas e 8 alternativas
  Quando excluo o quiz
  Então o quiz, suas perguntas e suas alternativas deixam de existir

Cenário: Contagem também no detalhe
  Dado um quiz meu com 3 perguntas
  Quando obtenho o quiz por get_quiz!/2 ou por get_quiz_with_questions!/2
  Então o quiz retornado informa questions_count igual a 3

Cenário: Quiz jogável
  Dado um quiz sem perguntas
  Então playable? retorna falso
  E ao adicionar uma pergunta completa, playable? passa a retornar verdadeiro
```

## 9. Cenários de teste

Arquivo: `test/live_quiz/quizzes_test.exs`

- `create_quiz/2` com dados válidos e com dados inválidos (título ausente, curto, longo; descrição longa);
- `create_quiz/2` ignora `owner_id` enviado nos atributos;
- `list_quizzes/2` retorna somente os quizzes do escopo;
- `list_quizzes/2` ordena por `updated_at` decrescente;
- `list_quizzes/2` calcula `questions_count` corretamente, inclusive `0`;
- `list_quizzes/2` pagina corretamente (primeira página, última página, página além do total);
- `list_quizzes/2` filtra por `search`, é case-insensitive e ignora termo em branco;
- `list_quizzes/2` não gera N+1: com 10 quizzes, o número de queries é constante (duas — dados e
  total), independente da quantidade de linhas — assertar via `telemetry` ou log de queries;
- `get_quiz!/2` e `get_quiz_with_questions!/2` retornam `questions_count` preenchido (inclusive `0`);
- `get_quiz!/2` levanta `Ecto.NoResultsError` para id inexistente e para quiz de outro usuário;
- `get_quiz_with_questions!/2` retorna perguntas e alternativas ordenadas por `position`;
- `update_quiz/3` atualiza e valida;
- `delete_quiz/2` remove em cascata;
- `playable?/1` para quiz vazio e quiz com pergunta.

## 10. Definition of Ready

- [x] Schemas e constraints disponíveis (F1-05).
- [x] Contrato de paginação e busca definido.
- [x] Regra de autorização (404 para não-dono) definida.

## 11. Definition of Done

- [ ] Funções implementadas conforme as assinaturas do item 6.
- [ ] Nenhuma função aceita `owner_id` externo.
- [ ] Listagem resolvida em duas queries no total (dados + total), sem consulta por linha.
- [ ] `questions_count` preenchido por todas as funções de leitura de quiz.
- [ ] Todos os cenários de teste do item 9 implementados e passando.
- [ ] `@doc` e `@spec` em todas as funções públicas.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-05** — schemas, constraints e fixtures.

## 13. Riscos e pontos de atenção

- Ao usar `group_by` com `select: %{q | questions_count: ...}`, garantir que todas as colunas
  selecionadas estejam no `group_by` (agrupar por `q.id` é suficiente no Postgres por conta da PK).
- Escapar `%` e `_` no termo de busca para evitar padrões inesperados de `ILIKE`.
- Paginação por offset degrada em volumes altos; aceitável nesta fase, registrar como dívida técnica.

## 14. Estimativa

**3 pontos** — CRUD direto, com atenção à query de listagem.
