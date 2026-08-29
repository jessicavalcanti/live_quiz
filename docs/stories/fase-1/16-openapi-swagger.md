# [F1-16] Documentação OpenAPI e Swagger UI

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `api`, `documentacao`
> **Branch:** `feature/16-openapi-swagger` · **Estimativa:** 3 pontos · **Depende de:** F1-14, F1-15

## 1. Contexto de negócio

A API existe para ser consumida por um cliente que ainda não foi construído — o app mobile das fases
seguintes. Um contrato descrito apenas em texto de issue envelhece rápido e não é verificável. Esta
story publica a especificação da API junto do código, para que quem for integrar saiba exatamente o
que enviar e o que esperar.

## 2. User story

**Como** pessoa desenvolvedora de um cliente da API,
**quero** uma especificação OpenAPI navegável e sempre atualizada,
**para que** eu implemente a integração sem precisar ler o código do servidor.

## 3. Escopo

### Dentro
- Dependência e configuração do `open_api_spex`.
- Schemas OpenAPI para `Quiz`, `Question`, `AnswerOption`, `Session`, erros e metadados de paginação.
- Anotação (`operation/2`) de todos os endpoints das stories F1-13, F1-14 e F1-15.
- Endpoint `GET /api/openapi` com a especificação em JSON.
- Swagger UI em `/api/docs`.
- Teste que valida a especificação gerada.

### Fora
- Geração de SDK cliente, publicação externa da documentação, versionamento de contrato (v2),
  exemplos executáveis contra o ambiente de produção.

## 4. Decisões de arquitetura

- **`open_api_spex`** por ser a solução idiomática em Phoenix: a especificação é derivada do próprio
  router e dos módulos de schema, ficando versionada junto ao código.
- **Especificação gerada em tempo de execução** a partir das anotações, e não um arquivo YAML
  mantido à mão — assim ela não diverge silenciosamente da implementação.
- **Swagger UI habilitado em todos os ambientes**: a API não expõe dados sem autenticação, e a
  documentação acessível facilita a integração. Restringir a `dev` fica registrado como possibilidade futura.
- **Segurança declarada como `bearerAuth` (JWT)**, refletindo a decisão AD-12.
- **Teste de contrato** garantindo que a especificação é gerada e é válida — a documentação passa a
  ser verificada pelo CI.

## 5. Modelo de dados e migrations

Nenhuma.

## 6. Contratos técnicos

### Dependência

```elixir
{:open_api_spex, "~> 3.18"}
```

### Módulos

| Módulo | Arquivo | Responsabilidade |
|---|---|---|
| `LiveQuizWeb.ApiSpec` | `lib/live_quiz_web/api_spec.ex` | Monta a `%OpenApi{}` com info, servers e `securitySchemes` |
| `LiveQuizWeb.Api.V1.Schemas` | `lib/live_quiz_web/controllers/api/v1/schemas.ex` | Schemas de request e response |

### `LiveQuizWeb.ApiSpec`

```elixir
%OpenApi{
  info: %Info{title: "Live Quiz API", version: "1.0.0", description: "API da plataforma de quizzes em tempo real"},
  servers: [Server.from_endpoint(LiveQuizWeb.Endpoint)],
  paths: Paths.from_router(LiveQuizWeb.Router),
  components: %Components{
    securitySchemes: %{"bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer", bearerFormat: "JWT"}}
  },
  security: [%{"bearerAuth" => []}]
}
```

### Schemas a definir

- `SessionRequest`, `SessionResponse`, `RefreshRequest`, `UserResponse` (usado também por `GET /api/v1/me`);
- `Quiz`, `QuizRequest`, `QuizResponse`, `QuizListResponse` (com `meta`);
- `Question`, `QuestionRequest`, `QuestionResponse`, `QuestionListResponse`, `MoveRequest`;
- `AnswerOption`;
- `PaginationMeta` (`page`, `per_page`, `total_entries`, `total_pages`);
- `ErrorResponse` (`{"errors": {...}}`) e `ValidationErrorResponse`.

Cada schema deve conter `description` e `example` — é o que torna a documentação útil.

### Anotação dos controllers

```elixir
use OpenApiSpex.ControllerSpecs

tags ["Quizzes"]
security [%{"bearerAuth" => []}]

operation :index,
  summary: "Lista os quizzes do usuário autenticado",
  parameters: [
    page: [in: :query, type: :integer, description: "Página (padrão 1)"],
    per_page: [in: :query, type: :integer, description: "Itens por página (padrão 20, máximo 100)"],
    search: [in: :query, type: :string, description: "Filtra pelo título"]
  ],
  responses: [
    ok: {"Lista de quizzes", "application/json", Schemas.QuizListResponse},
    unauthorized: {"Não autenticado", "application/json", Schemas.ErrorResponse}
  ]
```

Aplicar em **todas** as actions de `SessionController`, `QuizController` e `QuestionController`,
incluindo as respostas de erro 401, 404 e 422.

### Rotas

```elixir
scope "/api" do
  pipe_through :api
  get "/openapi", OpenApiSpex.Plug.RenderSpec, []
end

scope "/api/docs" do
  pipe_through :browser
  get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
end
```

Adicionar `plug OpenApiSpex.Plug.PutApiSpec, module: LiveQuizWeb.ApiSpec` na pipeline `:api`.

### README

Seção "API" apontando para `/api/docs` e explicando como obter e usar o token.

## 7. Regras de negócio e validações

- A especificação deve refletir exatamente os contratos implementados nas stories F1-13, F1-14 e F1-15.
- Todos os endpoints autenticados declaram `bearerAuth`; os de login e refresh, não.
- Todas as operações documentam pelo menos uma resposta de sucesso e as de erro aplicáveis.
- A documentação não expõe segredos, tokens reais ou dados de usuários.

## 8. Critérios de aceite

```gherkin
Cenário: Especificação disponível
  Quando faço GET em "/api/openapi"
  Então recebo 200 com um documento OpenAPI 3 em JSON
  E ele contém os caminhos de sessão, quizzes e perguntas

Cenário: Swagger UI acessível
  Quando acesso "/api/docs"
  Então vejo a interface do Swagger listando as operações agrupadas por tag

Cenário: Autenticação documentada
  Quando abro a especificação
  Então existe o security scheme "bearerAuth" do tipo http/bearer com formato JWT
  E os endpoints autenticados exigem esse esquema

Cenário: Erros documentados
  Quando consulto a operação de criação de pergunta
  Então vejo documentadas as respostas 201, 401, 404 e 422

Cenário: Paginação documentada
  Quando consulto a operação de listagem de quizzes
  Então vejo os parâmetros page, per_page e search
  E o schema de resposta inclui o objeto meta

Cenário: Especificação válida no CI
  Quando a suíte de testes é executada
  Então o teste de contrato confirma que a especificação é gerada e é válida
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/api_spec_test.exs`

- `GET /api/openapi` retorna 200 e um JSON com `openapi`, `info` e `paths`;
- a especificação contém todos os caminhos implementados: `/api/v1/session` (POST e DELETE),
  `/api/v1/session/refresh`, `/api/v1/me`, `/api/v1/quizzes`, `/api/v1/quizzes/{id}`,
  `/api/v1/quizzes/{quiz_id}/questions`, `/api/v1/quizzes/{quiz_id}/questions/{id}` e `.../move`;
- `OpenApiSpex.OpenApi.to_map/1` gera a especificação sem levantar exceção (validação estrutural);
- operações autenticadas declaram `security` com `bearerAuth`;
- `GET /api/docs` responde 200 com o HTML do Swagger UI.

## 10. Definition of Ready

- [x] Endpoints implementados e estáveis (F1-14, F1-15).
- [x] Formato de envelope, erros e paginação definidos.
- [x] Esquema de autenticação definido (Bearer JWT).

## 11. Definition of Done

- [ ] `open_api_spex` configurado e especificação servida em `/api/openapi`.
- [ ] Swagger UI acessível em `/api/docs`.
- [ ] Todas as operações da API anotadas, com respostas de sucesso e de erro.
- [ ] Schemas com `description` e `example`.
- [ ] Teste de contrato rodando no CI.
- [ ] README com a seção "API".
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-14** e **F1-15** — endpoints a documentar.
- **F1-13** — esquema de autenticação.

## 13. Riscos e pontos de atenção

- Anotações desatualizadas são pior do que ausência de documentação: qualquer alteração futura de
  contrato deve atualizar a `operation/2` correspondente — incluir isso na DoD das stories de API das
  próximas fases.
- O `SwaggerUI` do `open_api_spex` precisa passar pela pipeline `:browser` (por causa do CSP e do
  HTML), enquanto a spec vai pela pipeline `:api`.
- A `CSP` do Phoenix pode bloquear os assets do Swagger UI; ajustar se necessário.

## 14. Estimativa

**3 pontos** — trabalho volumoso porém mecânico, sobre contratos já definidos.
