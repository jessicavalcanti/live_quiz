# [F1-15] API v1: perguntas e alternativas

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `api`, `backend`
> **Branch:** `feature/15-api-perguntas` · **Estimativa:** 3 pontos · **Depende de:** F1-07, F1-08, F1-13

## 1. Contexto de negócio

Um cliente que só consegue criar o "envelope" do quiz, mas não seu conteúdo, não consegue substituir
a interface web. Esta story completa a API com a escrita de perguntas e alternativas, fechando a
paridade funcional entre os dois canais e comprovando que toda a regra de negócio vive no contexto.

## 2. User story

**Como** aplicação cliente autenticada,
**quero** criar, editar, reordenar e excluir perguntas de um quiz via API,
**para que** eu consiga montar um quiz completo sem usar a interface web.

## 3. Escopo

### Dentro
- Endpoints aninhados de pergunta sob `/api/v1/quizzes/:quiz_id/questions`.
- Endpoints de pergunta por id: detalhe, atualização e exclusão.
- Endpoint de movimentação (`PATCH .../move`).
- Serialização de pergunta com suas 4 alternativas.
- Tratamento do limite de 50 perguntas.
- Testes de request.

### Fora
- Criar ou excluir alternativas isoladamente — sempre 4 por pergunta (AD-05).
- Documentação OpenAPI (story F1-16).

## 4. Decisões de arquitetura

- **Alternativas trafegam sempre aninhadas na pergunta**: como o número é fixo em 4, não existe
  recurso REST independente para alternativa. Criar e atualizar pergunta recebem o array completo.
- **Endpoint de movimentação por direção** (`{"direction": "up"|"down"}`), espelhando
  `move_question/3` (F1-08) e evitando entrada inválida de posição.
- **`position` nunca é aceita do cliente**: é calculada na criação e alterada apenas via `move`.
- **`{:error, :question_limit_reached}` vira `422`** com mensagem específica, e não 400 — é uma
  violação de regra de negócio sobre a entidade.
- Controllers finos, `FallbackController` e envelope idênticos aos da story F1-14 (AD-01, AD-12).

## 5. Modelo de dados e migrations

Nenhuma. Consome `create_question/3`, `update_question/3`, `delete_question/2`, `move_question/3` e
`get_question!/3`.

## 6. Contratos técnicos

### Rotas

```elixir
scope "/api/v1", LiveQuizWeb.Api.V1 do
  pipe_through [:api, :api_authenticated]

  get    "/quizzes/:quiz_id/questions", QuestionController, :index
  post   "/quizzes/:quiz_id/questions", QuestionController, :create
  get    "/quizzes/:quiz_id/questions/:id", QuestionController, :show
  put    "/quizzes/:quiz_id/questions/:id", QuestionController, :update
  patch  "/quizzes/:quiz_id/questions/:id", QuestionController, :update
  delete "/quizzes/:quiz_id/questions/:id", QuestionController, :delete
  patch  "/quizzes/:quiz_id/questions/:id/move", QuestionController, :move
end
```

### Módulos

| Módulo | Arquivo |
|---|---|
| `LiveQuizWeb.Api.V1.QuestionController` | `lib/live_quiz_web/controllers/api/v1/question_controller.ex` |
| `LiveQuizWeb.Api.V1.QuestionJSON` | `lib/live_quiz_web/controllers/api/v1/question_json.ex` |

### `POST /api/v1/quizzes/:quiz_id/questions`

```json
{
  "question": {
    "text": "Qual é a capital do Brasil?",
    "answer_options": [
      { "text": "Rio de Janeiro", "position": 1, "is_correct": false },
      { "text": "Brasília",       "position": 2, "is_correct": true  },
      { "text": "São Paulo",      "position": 3, "is_correct": false },
      { "text": "Salvador",       "position": 4, "is_correct": false }
    ]
  }
}
```

`201`:

```json
{
  "data": {
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
}
```

Erros:

| Situação | Status | Corpo |
|---|---|---|
| Sem alternativa correta | 422 | `{"errors": {"answer_options": ["marque a alternativa correta"]}}` |
| Duas corretas | 422 | `{"errors": {"answer_options": ["marque apenas uma alternativa correta"]}}` |
| Quantidade diferente de 4 | 422 | `{"errors": {"answer_options": ["a pergunta deve ter exatamente 4 alternativas"]}}` |
| Textos repetidos | 422 | `{"errors": {"answer_options": ["as alternativas não podem ter textos repetidos"]}}` |
| Texto da pergunta inválido | 422 | `{"errors": {"text": ["..."]}}` |
| Limite atingido | 422 | `{"errors": {"detail": "Este quiz já atingiu o limite de 50 perguntas"}}` |
| Quiz de outro usuário | 404 | `{"errors": {"detail": "Não encontrado"}}` |

### `PUT/PATCH /api/v1/quizzes/:quiz_id/questions/:id`

Mesmo corpo do `POST`, com o `id` de cada alternativa incluído para atualização em vez de recriação.
`200` com a pergunta atualizada. A `position` não é alterada por este endpoint.

### `PATCH /api/v1/quizzes/:quiz_id/questions/:id/move`

```json
{ "direction": "up" }
```

O controller carrega a pergunta com `get_question!/3`, chama `move_question/3` — que retorna
`{:ok, %Question{}}` ou `{:ok, :unchanged}` — e, em ambos os casos, recarrega a lista de perguntas do
quiz para montar a resposta.

`200` com a lista completa e reordenada das perguntas do quiz:

```json
{ "data": [ { "id": 11, "position": 1, "text": "..." }, { "id": 10, "position": 2, "text": "..." } ] }
```

`422` quando `direction` for diferente de `"up"` ou `"down"`.
Movimento na borda retorna `200` com a lista inalterada.

### `DELETE /api/v1/quizzes/:quiz_id/questions/:id`

`204 No Content`; as perguntas seguintes são renumeradas pelo contexto.

### `GET /api/v1/quizzes/:quiz_id/questions`

`200` com todas as perguntas do quiz ordenadas por `position`, cada uma com suas alternativas.
Sem paginação — o limite de 50 torna a lista naturalmente pequena.

## 7. Regras de negócio e validações

Todas herdadas dos contextos (F1-07 e F1-08):

- pergunta pertence a um quiz do usuário do token; caso contrário, 404;
- exatamente 4 alternativas, exatamente 1 correta, sem textos repetidos;
- texto da pergunta 3–500; texto da alternativa 1–200;
- máximo de 50 perguntas por quiz;
- `position` calculada pelo servidor na criação e alterada somente por `move`;
- exclusão mantém a sequência densa `1..n`;
- criação e atualização são atômicas: falha não deixa registro parcial.

## 8. Critérios de aceite

```gherkin
Cenário: Criar pergunta completa
  Dado um quiz meu sem perguntas
  Quando faço POST em "/api/v1/quizzes/:quiz_id/questions" com texto e 4 alternativas válidas
  Então recebo 201 com a pergunta na posição 1 e suas 4 alternativas

Cenário: Criar pergunta sem alternativa correta
  Quando faço POST sem marcar nenhuma alternativa como correta
  Então recebo 422 com a mensagem "marque a alternativa correta"
  E nenhuma pergunta é criada

Cenário: Criar pergunta com duas corretas
  Quando faço POST marcando duas alternativas como corretas
  Então recebo 422 com a mensagem "marque apenas uma alternativa correta"

Cenário: Criar pergunta com 3 alternativas
  Quando faço POST enviando apenas 3 alternativas
  Então recebo 422 informando que a pergunta deve ter exatamente 4 alternativas

Cenário: Limite de perguntas
  Dado um quiz meu com 50 perguntas
  Quando faço POST de mais uma pergunta
  Então recebo 422 com a mensagem de limite atingido

Cenário: Listar perguntas
  Dado um quiz meu com 3 perguntas
  Quando faço GET em "/api/v1/quizzes/:quiz_id/questions"
  Então recebo as 3 perguntas ordenadas por position, com suas alternativas

Cenário: Atualizar pergunta
  Dada uma pergunta minha com a alternativa 2 correta
  Quando faço PUT alterando o texto e marcando a alternativa 4 como correta
  Então recebo 200 com os dados atualizados
  E a posição da pergunta permanece a mesma

Cenário: Mover pergunta
  Dado um quiz meu com as perguntas A (1), B (2) e C (3)
  Quando faço PATCH em ".../questions/<id_de_B>/move" com direction "up"
  Então recebo 200 com a lista na ordem B, A, C

Cenário: Mover na borda
  Quando movo a primeira pergunta para cima
  Então recebo 200 com a lista inalterada

Cenário: Direção inválida
  Quando faço PATCH em ".../move" com direction "left"
  Então recebo 422

Cenário: Excluir pergunta
  Dado um quiz meu com as perguntas nas posições 1, 2 e 3
  Quando excluo a pergunta da posição 2
  Então recebo 204
  E as perguntas restantes passam a ocupar as posições 1 e 2

Cenário: Pergunta de quiz alheio
  Quando faço qualquer operação em uma pergunta de um quiz de Bruno
  Então recebo 404

Cenário: Sem autenticação
  Quando faço POST de pergunta sem token
  Então recebo 401
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/api/v1/question_controller_test.exs`

- todas as actions retornam 401 sem token e 404 para quiz/pergunta de outro usuário;
- `create` válido retorna 201, com posição correta e alternativas ordenadas;
- `create` cobre todos os erros 422 da tabela do item 6, sempre assertando que nada foi persistido;
- `create` ignora `position` enviada pelo cliente;
- limite de 50 perguntas retorna 422 com a mensagem específica;
- `index` retorna as perguntas ordenadas com suas alternativas;
- `show` retorna a pergunta; id inexistente retorna 404;
- `update` altera texto e alternativa correta preservando ids e posição; inválido retorna 422;
- `move` up e down reordena e retorna a lista completa; borda retorna 200 com a lista inalterada
  (tratando `{:ok, :unchanged}`); direção inválida ou ausente retorna 422;
- `delete` retorna 204, remove as alternativas e renumera as perguntas seguintes.

## 10. Definition of Ready

- [x] Contextos de pergunta e de ordenação disponíveis (F1-07, F1-08).
- [x] Autenticação e padrões de erro da API disponíveis (F1-13).
- [x] Formato de payload aninhado definido.

## 11. Definition of Done

- [ ] Endpoints implementados conforme os contratos do item 6.
- [ ] Nenhuma regra de negócio no controller; nenhum acesso ao `Repo`.
- [ ] Mensagens de erro idênticas às da interface web (mesma fonte: o changeset).
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-07** e **F1-08** — funções de contexto.
- **F1-13** — autenticação, fallback e views de erro.
- **F1-14** — padrão de controller e serialização já estabelecidos.

## 13. Riscos e pontos de atenção

- Erros de conjunto vivem no changeset pai: garantir que apareçam sob a chave `answer_options` e não
  se percam na serialização de erros.
- Atualização sem os `id`s das alternativas recria os registros — documentar isso no contrato.
- `move` retornando a lista completa evita que o cliente precise refazer um GET; manter esse
  comportamento consistente com o descrito.

## 14. Estimativa

**3 pontos** — endpoints diretos sobre contexto pronto, com muitos casos de erro já especificados.
