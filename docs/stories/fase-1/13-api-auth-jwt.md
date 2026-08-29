# [F1-13] Autenticação JWT da API com Guardian

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `api`, `backend`
> **Branch:** `feature/13-api-auth-jwt` · **Estimativa:** 5 pontos · **Depende de:** F1-03

## 1. Contexto de negócio

O documento do projeto prevê que a plataforma seja consumida futuramente por um aplicativo mobile.
Um app não usa sessão por cookie: precisa de um token que possa ser guardado no dispositivo e
enviado a cada requisição. Esta story cria essa porta de entrada, sem a qual nenhum endpoint da API
pode ser protegido.

## 2. User story

**Como** aplicação cliente (app mobile ou integração),
**quero** trocar e-mail e senha por um token de acesso e renová-lo quando expirar,
**para que** eu consiga consumir a API em nome de um usuário sem depender do navegador.

## 3. Escopo

### Dentro
- Dependência e configuração do Guardian.
- Módulo `LiveQuiz.Accounts.Guardian` (implementação do behaviour).
- Endpoints `POST /api/v1/session`, `POST /api/v1/session/refresh` e `DELETE /api/v1/session`.
- Pipeline de autenticação da API e plug que popula o `scope` a partir do token.
- Formato padronizado de resposta e de erro.
- `FallbackController` e views JSON de erro.
- Testes de request.

### Fora
- Endpoints de quizzes, perguntas e alternativas (stories F1-14 e F1-15).
- Documentação OpenAPI (story F1-16).
- Cadastro e recuperação de senha via API, revogação server-side de tokens, rate limiting.

## 4. Decisões de arquitetura

- **JWT via Guardian** (AD-12): biblioteca consolidada no ecossistema Elixir, com pipelines e plugs
  prontos, escolhida no refinamento em vez de token opaco.
- **Access token de 15 minutos + refresh token de 30 dias**, ambos JWT, com `typ` distinto
  (`"access"` e `"refresh"`).
- **Sem `Guardian.DB`**: nenhuma consulta ao banco por requisição e nenhuma tabela adicional. A
  contrapartida — não há revogação imediata de um token vazado antes da expiração — é aceita nesta
  fase e registrada como dívida técnica.
- **`DELETE /api/v1/session` é um encerramento do lado do cliente**: responde `204` e orienta o
  descarte dos tokens. Sem `Guardian.DB` não há como invalidar o JWT no servidor.
- **Reuso do contexto `Accounts`**: a autenticação continua sendo
  `get_user_by_email_and_password/2`; o Guardian apenas emite o token. Nenhuma regra de senha é
  duplicada.
- **`scope` idêntico ao da web**: o plug monta `LiveQuiz.Accounts.Scope` a partir do usuário do
  token, para que os contextos sejam chamados exatamente como no LiveView (AD-01).
- **Envelope `data`/`errors`** (AD-12) em todas as respostas.

## 5. Modelo de dados e migrations

Nenhuma tabela nova. O `sub` do token é o `id` do usuário.

Configuração (`config/config.exs`):

```elixir
config :live_quiz, LiveQuiz.Accounts.Guardian,
  issuer: "live_quiz",
  ttl: {15, :minutes}
# secret_key via variável de ambiente em runtime.exs; valor de dev fixo em dev.exs
```

## 6. Contratos técnicos

### Dependência

```elixir
{:guardian, "~> 2.3"}
```

### `LiveQuiz.Accounts.Guardian`

```elixir
defmodule LiveQuiz.Accounts.Guardian do
  use Guardian, otp_app: :live_quiz

  def subject_for_token(%LiveQuiz.Accounts.User{id: id}, _claims), do: {:ok, to_string(id)}
  def resource_from_claims(%{"sub" => id}), do: # busca o usuário; {:error, :unauthorized} se não existir
end
```

Funções auxiliares:

```elixir
@spec build_tokens(User.t()) :: {:ok, %{access_token: String.t(), refresh_token: String.t(), expires_in: integer()}}
@spec refresh_access_token(String.t()) :: {:ok, map()} | {:error, :invalid_refresh_token}
```

`build_tokens/1` emite access com `ttl: {15, :minutes}` e refresh com `ttl: {30, :days}` e
`token_type: "refresh"`.

### Pipeline e plugs

`lib/live_quiz_web/api/auth_pipeline.ex`

```elixir
defmodule LiveQuizWeb.Api.AuthPipeline do
  use Guardian.Plug.Pipeline, otp_app: :live_quiz, module: LiveQuiz.Accounts.Guardian,
      error_handler: LiveQuizWeb.Api.AuthErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer", claims: %{"typ" => "access"}
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
  plug LiveQuizWeb.Api.AssignScope   # conn.assigns.current_scope = Scope.for_user(user)
end
```

`LiveQuizWeb.Api.AuthErrorHandler` responde `401` com o envelope de erro padrão.

### Router

```elixir
pipeline :api do
  plug :accepts, ["json"]
end

pipeline :api_authenticated do
  plug LiveQuizWeb.Api.AuthPipeline
end

scope "/api/v1", LiveQuizWeb.Api.V1 do
  pipe_through :api

  post "/session", SessionController, :create
  post "/session/refresh", SessionController, :refresh
end

scope "/api/v1", LiveQuizWeb.Api.V1 do
  pipe_through [:api, :api_authenticated]

  delete "/session", SessionController, :delete
  get "/me", SessionController, :me
end
```

### Contratos HTTP

**`POST /api/v1/session`**

```json
{ "email": "ana@example.com", "password": "senha-super-secreta" }
```

`201`:

```json
{
  "data": {
    "access_token": "eyJhbGciOi...",
    "refresh_token": "eyJhbGciOi...",
    "token_type": "Bearer",
    "expires_in": 900,
    "user": { "id": 1, "name": "Ana", "email": "ana@example.com" }
  }
}
```

`401`:

```json
{ "errors": { "detail": "E-mail ou senha inválidos" } }
```

**`POST /api/v1/session/refresh`**

```json
{ "refresh_token": "eyJhbGciOi..." }
```

`200` com um novo `access_token` e `expires_in`; `401` com `{"errors": {"detail": "Refresh token inválido ou expirado"}}`.

**`DELETE /api/v1/session`** → `204 No Content` (requer access token válido).

**`GET /api/v1/me`** → `200` com `{"data": {"id": ..., "name": ..., "email": ..., "confirmed": true|false}}`.

### Erros padronizados

| Situação | Status | Corpo |
|---|---|---|
| Sem header `Authorization` | 401 | `{"errors": {"detail": "Não autenticado"}}` |
| Token inválido, expirado ou com `typ` errado | 401 | `{"errors": {"detail": "Não autenticado"}}` |
| Recurso inexistente ou de outro usuário | 404 | `{"errors": {"detail": "Não encontrado"}}` |
| Changeset inválido | 422 | `{"errors": {"campo": ["mensagem"]}}` |

Implementar em `LiveQuizWeb.Api.FallbackController` + `LiveQuizWeb.Api.ErrorJSON`, para reuso pelas
stories F1-14 e F1-15.

## 7. Regras de negócio e validações

- Credenciais inválidas retornam sempre a mesma mensagem genérica, sem revelar se o e-mail existe.
- Access token expirado é rejeitado com 401, mesmo que a assinatura seja válida.
- Um refresh token **não** é aceito como access token (validação do claim `typ`).
- E-mail não confirmado **não** impede o uso da API (AD-03).
- A `secret_key` do Guardian nunca é versionada em produção; em `runtime.exs` vem de variável de ambiente.
- Nenhum endpoint autenticado da API pode ser alcançado sem passar pela `AuthPipeline`.

## 8. Critérios de aceite

```gherkin
Cenário: Obter token com credenciais válidas
  Dado um usuário cadastrado
  Quando faço POST em "/api/v1/session" com e-mail e senha corretos
  Então recebo 201 com access_token, refresh_token, token_type e expires_in
  E os dados básicos do usuário

Cenário: Credenciais inválidas
  Quando faço POST em "/api/v1/session" com a senha errada
  Então recebo 401 com a mensagem genérica de credenciais inválidas
  E nenhum token é retornado

Cenário: Campos ausentes
  Quando faço POST em "/api/v1/session" sem informar a senha
  Então recebo 422 com o erro no campo password

Cenário: Acessar rota protegida com token válido
  Dado um access token válido
  Quando faço GET em "/api/v1/me" com o header Authorization Bearer
  Então recebo 200 com os dados do meu usuário

Cenário: Acessar rota protegida sem token
  Quando faço GET em "/api/v1/me" sem o header Authorization
  Então recebo 401 com {"errors": {"detail": "Não autenticado"}}

Cenário: Token expirado
  Dado um access token já expirado
  Quando faço GET em "/api/v1/me"
  Então recebo 401

Cenário: Refresh token usado como access token
  Dado um refresh token válido
  Quando o envio como Bearer em "/api/v1/me"
  Então recebo 401

Cenário: Renovar o access token
  Dado um refresh token válido
  Quando faço POST em "/api/v1/session/refresh"
  Então recebo 200 com um novo access_token
  E esse token é aceito em "/api/v1/me"

Cenário: Refresh inválido
  Quando faço POST em "/api/v1/session/refresh" com um token adulterado
  Então recebo 401

Cenário: Encerrar sessão
  Dado um access token válido
  Quando faço DELETE em "/api/v1/session"
  Então recebo 204
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/api/v1/session_controller_test.exs`

- login válido retorna 201 com a estrutura completa do envelope;
- login com senha errada e com e-mail inexistente retornam 401 com a **mesma** mensagem;
- parâmetros ausentes retornam 422;
- `GET /api/v1/me` com token válido retorna 200; sem token, com token malformado, com token expirado
  e com refresh token retornam 401;
- refresh válido gera access token utilizável;
- refresh adulterado ou expirado retorna 401;
- `DELETE /api/v1/session` retorna 204 com token válido e 401 sem token;
- resposta de erro segue exatamente o formato `{"errors": {...}}`.

Criar helper de teste (`test/support/conn_case.ex`) para autenticar uma `conn` com token de um usuário.

## 10. Definition of Ready

- [x] Contexto `Accounts` com autenticação por senha disponível (F1-03).
- [x] Estratégia de token definida (Guardian, access 15min + refresh 30 dias, sem Guardian.DB).
- [x] Formato de erro e envelope definidos.

## 11. Definition of Done

- [ ] Guardian configurado, com secret vindo de variável de ambiente em produção.
- [ ] Endpoints de sessão implementados e respondendo nos formatos especificados.
- [ ] Pipeline de autenticação montando `current_scope` idêntico ao usado na web.
- [ ] `FallbackController` e views de erro reutilizáveis pelas próximas stories.
- [ ] Helper de autenticação disponível no `ConnCase`.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] Dívida técnica de revogação registrada no README ou em issue de backlog.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-03** — usuários e autenticação por senha.

## 13. Riscos e pontos de atenção

- Sem `Guardian.DB` não existe logout real no servidor: deixar isso explícito na documentação da API.
- O claim `typ` precisa ser verificado explicitamente; sem isso um refresh token vira access token.
- Não reaproveitar o `secret_key_base` do Phoenix como segredo do Guardian.
- Testar expiração exige gerar token com TTL curto ou manipular o claim `exp` — prever isso no helper de teste.

## 14. Estimativa

**5 pontos** — configuração de biblioteca, três endpoints e muitos casos de erro.
