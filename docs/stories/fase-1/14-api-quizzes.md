# [F1-14] API v1: CRUD de quizzes com paginação e busca

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `api`, `backend`
> **Branch:** `feature/14-api-quizzes` · **Estimativa:** 3 pontos · **Depende de:** F1-06, F1-13

## 1. Contexto de negócio

O documento do projeto exige que o domínio não fique acoplado ao LiveView e que a plataforma possa
ser consumida por um app mobile no futuro. Expor o CRUD de quizzes em JSON, reaproveitando
exatamente as mesmas funções de contexto usadas pela web, é a prova concreta de que essa separação
foi respeitada.

## 2. User story

**Como** aplicação cliente autenticada,
**quero** listar, consultar, criar, editar e excluir quizzes via API JSON,
**para que** eu ofereça a mesma funcionalidade do site em outro canal, sem duplicar regra de negócio.

## 3. Escopo

### Dentro
- Endpoints REST de quiz sob `/api/v1/quizzes`.
- Paginação (`page`, `per_page`) e busca (`search`) com metadados na resposta.
- Serialização com `questions_count` e `playable`.
- Detalhe do quiz com perguntas e alternativas aninhadas.
- Testes de request.

### Fora
- Escrita de perguntas e alternativas (story F1-15).
- Documentação OpenAPI (story F1-16).
- Rate limiting, cache, filtros adicionais.

## 4. Decisões de arquitetura

- **Controllers finos**: nenhuma regra de negócio; apenas traduzem parâmetros, chamam
  `LiveQuiz.Quizzes` com o `scope` do token e renderizam a view (AD-01).
- **Mesmas funções de contexto do LiveView** — `list_quizzes/2`, `get_quiz!/2`,
  `get_quiz_with_questions!/2`, `create_quiz/2`, `update_quiz/3`, `delete_quiz/2`.
- **`questions_count` e `playable` vêm prontos do contexto** (AD-15): todas as funções de leitura
  preenchem o campo virtual, e `playable` é `Quizzes.playable?/1` serializado. A view JSON não conta
  perguntas nem consulta o banco.
- **`FallbackController`** (criado na F1-13) trata `Ecto.NoResultsError` como 404 e changeset
  inválido como 422, sem `try/rescue` nas actions.
- **Envelope `data` + `meta`**: a paginação vive em `meta`, mantendo `data` como uma lista pura.
- **`PUT` e `PATCH` com o mesmo comportamento** (atualização parcial): simplifica o cliente e é
  suficiente para o recurso.
- **404 para quiz de outro usuário** (AD-10), pelo próprio escopo da query.

## 5. Modelo de dados e migrations

Nenhuma. Consome o contexto da story F1-06.

## 6. Contratos técnicos

### Rotas

```elixir
scope "/api/v1", LiveQuizWeb.Api.V1 do
  pipe_through [:api, :api_authenticated]

  resources "/quizzes", QuizController, except: [:new, :edit]
end
```

Resultado:

```text
GET    /api/v1/quizzes
POST   /api/v1/quizzes
GET    /api/v1/quizzes/:id
PUT    /api/v1/quizzes/:id
PATCH  /api/v1/quizzes/:id
DELETE /api/v1/quizzes/:id
```

### Módulos

| Módulo | Arquivo |
|---|---|
| `LiveQuizWeb.Api.V1.QuizController` | `lib/live_quiz_web/controllers/api/v1/quiz_controller.ex` |
| `LiveQuizWeb.Api.V1.QuizJSON` | `lib/live_quiz_web/controllers/api/v1/quiz_json.ex` |

### `GET /api/v1/quizzes`

Query params: `page` (default 1), `per_page` (default 20, máximo 100), `search` (opcional).

`200`:

```json
{
  "data": [
    {
      "id": 1,
      "title": "Geografia",
      "description": "Capitais do mundo",
      "questions_count": 3,
      "playable": true,
      "inserted_at": "2026-08-29T12:00:00Z",
      "updated_at": "2026-08-29T12:30:00Z"
    }
  ],
  "meta": { "page": 1, "per_page": 20, "total_entries": 1, "total_pages": 1 }
}
```

### `GET /api/v1/quizzes/:id`

`200` com o quiz e suas perguntas aninhadas, ordenadas por `position`:

```json
{
  "data": {
    "id": 1,
    "title": "Geografia",
    "description": "Capitais do mundo",
    "questions_count": 1,
    "playable": true,
    "questions": [
      {
        "id": 10,
        "text": "Qual é a capital do Brasil?",
        "position": 1,
        "answer_options": [
          { "id": 100, "text": "Rio de Janeiro", "position": 1, "is_correct": false },
          { "id": 101, "text": "Brasília",       "position": 2, "is_correct": true  },
          { "id": 102, "text": "São Paulo",      "position": 3, "is_correct": false },
          { "id": 103, "text": "Salvador",       "position": 4, "is_correct": false }
        ]
      }
    ],
    "inserted_at": "2026-08-29T12:00:00Z",
    "updated_at": "2026-08-29T12:30:00Z"
  }
}
```

> `is_correct` é exposto porque o consumidor autenticado é o **dono** do quiz. Endpoints voltados a
> participantes (fases 3 e 4) usarão outra serialização.

### `POST /api/v1/quizzes`

```json
{ "quiz": { "title": "Geografia", "description": "Capitais do mundo" } }
```

`201` com `Location: /api/v1/quizzes/:id` e o quiz criado no envelope `data`.
`422` com `{"errors": {"title": ["não pode ficar em branco"]}}`.

### `PUT/PATCH /api/v1/quizzes/:id`

Mesmo corpo do `POST`; `200` com o quiz atualizado.

### `DELETE /api/v1/quizzes/:id`

`204 No Content`.

## 7. Regras de negócio e validações

- Todos os endpoints exigem access token válido; sem ele, 401.
- Toda operação é restrita aos quizzes do usuário do token; quiz de terceiros retorna 404.
- `owner_id` enviado no corpo é ignorado.
- Validações de título e descrição são as mesmas da web (F1-06).
- `page` e `per_page` inválidos caem nos defaults, sem erro.
- `search` em branco equivale a não filtrar.
- Excluir quiz remove perguntas e alternativas (cascata).

## 8. Critérios de aceite

```gherkin
Cenário: Listar meus quizzes
  Dado que estou autenticado por token e possuo 2 quizzes
  Quando faço GET em "/api/v1/quizzes"
  Então recebo 200 com os 2 quizzes em "data"
  E "meta" traz page, per_page, total_entries e total_pages

Cenário: Listagem não expõe quizzes de terceiros
  Dado que Bruno possui quizzes
  Quando Ana faz GET em "/api/v1/quizzes"
  Então nenhum quiz de Bruno aparece na resposta

Cenário: Paginação
  Dado que possuo 25 quizzes
  Quando faço GET em "/api/v1/quizzes?page=2&per_page=20"
  Então recebo 5 quizzes e meta.total_pages igual a 2

Cenário: Busca
  Dado que possuo os quizzes "Geografia" e "História"
  Quando faço GET em "/api/v1/quizzes?search=geo"
  Então recebo apenas "Geografia"

Cenário: Detalhe com perguntas
  Dado um quiz meu com 2 perguntas
  Quando faço GET em "/api/v1/quizzes/:id"
  Então recebo o quiz com as perguntas ordenadas por position
  E cada pergunta traz suas 4 alternativas com is_correct

Cenário: Detalhe de quiz alheio
  Quando faço GET em um quiz de Bruno
  Então recebo 404 com {"errors": {"detail": "Não encontrado"}}

Cenário: Criar quiz
  Quando faço POST em "/api/v1/quizzes" com título válido
  Então recebo 201 com o quiz criado
  E o header Location aponta para o novo recurso

Cenário: Criar quiz inválido
  Quando faço POST sem título
  Então recebo 422 com o erro no campo title

Cenário: Atualizar quiz
  Quando faço PATCH em um quiz meu alterando o título
  Então recebo 200 com o título atualizado

Cenário: Excluir quiz
  Quando faço DELETE em um quiz meu
  Então recebo 204
  E o quiz deixa de existir

Cenário: Sem autenticação
  Quando faço GET em "/api/v1/quizzes" sem token
  Então recebo 401
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/api/v1/quiz_controller_test.exs`

- todas as actions retornam 401 sem token;
- `index` lista apenas os quizzes do dono, com `meta` correto;
- `index` respeita `page`, `per_page` (incluindo o teto de 100) e `search`;
- `index` retorna lista vazia e `total_pages: 0` quando não há quizzes;
- `show` retorna o quiz com perguntas e alternativas ordenadas, e com `questions_count` e `playable`
  preenchidos corretamente (inclusive `0`/`false` para quiz vazio);
- `show` de id inexistente e de quiz alheio retorna 404 no formato padrão;
- `create` válido retorna 201, com `Location`, e persiste com o dono correto;
- `create` ignora `owner_id` enviado no corpo;
- `create` inválido retorna 422 no formato padrão;
- `update` válido retorna 200; inválido retorna 422; de quiz alheio retorna 404;
- `delete` retorna 204 e remove perguntas e alternativas; de quiz alheio retorna 404.

## 10. Definition of Ready

- [x] Contexto de quiz disponível (F1-06).
- [x] Autenticação da API disponível (F1-13).
- [x] Formato de envelope, erro e paginação definidos.

## 11. Definition of Done

- [ ] Endpoints implementados conforme os contratos do item 6.
- [ ] Controller sem regra de negócio e sem acesso ao `Repo`.
- [ ] `FallbackController` tratando 404 e 422.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] Contratos documentados no README (até a story F1-16 assumir a documentação).
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-06** — funções de contexto.
- **F1-13** — pipeline de autenticação, `FallbackController` e views de erro.

## 13. Riscos e pontos de atenção

- Datas serializadas em ISO 8601 **UTC** (a conversão para America/Sao_Paulo é exclusiva da web).
- `questions_count` no `show` depende de `get_quiz_with_questions!/2` preencher o campo virtual
  (F1-06); sem isso o campo sai `null` — cobrir com teste.
- `per_page` sem teto permite consultas pesadas; o limite de 100 é obrigatório.
- Manter a serialização em um único módulo JSON evita divergência entre `index` e `show`.

## 14. Estimativa

**3 pontos** — CRUD direto sobre contexto já pronto e testado.
