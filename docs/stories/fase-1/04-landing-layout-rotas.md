# [F1-04] Landing pública, layout autenticado e proteção de rotas

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `habilitador-tecnico`, `frontend`
> **Branch:** `feature/04-landing-layout-rotas` · **Estimativa:** 3 pontos · **Depende de:** F1-03

## 1. Contexto de negócio

A aplicação precisa de uma porta de entrada pública que explique o produto e conduza o visitante ao
cadastro, e de um esqueleto visual consistente para todas as telas autenticadas. Além disso,
nenhuma tela de negócio pode ser acessível sem login. Esta story entrega a casca da aplicação e a
garantia de acesso.

## 2. User story

**Como** visitante,
**quero** encontrar uma página inicial que explique a plataforma e me leve ao cadastro ou login,
**e como** usuário autenticado, **quero** navegar em um layout consistente que mostre quem sou e
me permita sair,
**para que** eu entenda o produto e me localize dentro da aplicação.

## 3. Escopo

### Dentro
- Página pública em `/` com proposta de valor e CTAs "Entrar" e "Criar conta".
- Redirecionamento de usuário autenticado de `/` para `/quizzes`.
- Layout autenticado: cabeçalho com nome do usuário, link para configurações e botão "Sair".
- Aviso não bloqueante de e-mail não confirmado.
- Proteção das rotas autenticadas via `live_session` + plugs do `UserAuth`.
- Página 404 amigável em pt-BR.

### Fora
- Conteúdo do dashboard (story F1-09) e do editor (stories F1-10 a F1-12).
- Entrada de participante por código (fase 2).
- Tema escuro, animações, identidade visual elaborada.

## 4. Decisões de arquitetura

- **Landing pública em `/`** em vez de redirect direto para o login: na fase 2 a home será o ponto
  de entrada do participante que digita o código da sala, então a página já nasce preparada.
- **Proteção por `live_session`** com `on_mount` do `UserAuth` gerado pelo `phx.gen.auth`, e não por
  verificação dentro de cada LiveView: a regra fica em um único lugar do router.
- Layout autenticado implementado no `Layouts` do Phoenix 1.8, reaproveitando `core_components`.
- Rotas de negócio ficam sob `/quizzes` (a story F1-09 cria a LiveView correspondente).

## 5. Modelo de dados e migrations

Não se aplica.

## 6. Contratos técnicos

### Router (`lib/live_quiz_web/router.ex`)

```elixir
scope "/", LiveQuizWeb do
  pipe_through [:browser]

  live_session :public,
    on_mount: [{LiveQuizWeb.UserAuth, :mount_current_scope}] do
    live "/", LandingLive, :index
  end
end

scope "/", LiveQuizWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :authenticated,
    on_mount: [{LiveQuizWeb.UserAuth, :require_authenticated}] do
    # /quizzes é declarado na story F1-09
  end
end
```

> Os nomes exatos dos `on_mount` e dos plugs devem seguir o que o `phx.gen.auth` gerou na F1-03.

### Módulos

| Módulo | Responsabilidade |
|---|---|
| `LiveQuizWeb.LandingLive` | Página pública em `/`; se `@current_scope` tiver usuário, `push_navigate` para `/quizzes` |
| `LiveQuizWeb.Layouts` | `app/1` com cabeçalho autenticado; `root/1` sem alterações estruturais |

### Conteúdo da landing

- Título: "Crie quizzes e jogue em tempo real".
- Parágrafo curto explicando a plataforma.
- Botões: "Criar conta" (`/users/register`) e "Entrar" (`/users/log-in`).

### Cabeçalho autenticado

- Nome do usuário (`@current_scope.user.name`);
- link "Minha conta" (`/users/settings`);
- botão "Sair" (`DELETE /users/log-out`);
- banner discreto "Confirme seu e-mail" quando `confirmed_at` for `nil`.

## 7. Regras de negócio e validações

- Visitante não autenticado que acessar qualquer rota autenticada é redirecionado para o login com
  a mensagem "Você precisa entrar para acessar esta página".
- Após o login, o usuário volta para a rota que tentou acessar (comportamento padrão do `UserAuth`).
- Usuário autenticado que acessar `/` vai para `/quizzes`.
- Usuário autenticado que acessar `/users/log-in` ou `/users/register` é redirecionado para `/quizzes`.

## 8. Critérios de aceite

```gherkin
Cenário: Visitante acessa a home
  Dado que não estou autenticado
  Quando acesso "/"
  Então vejo a apresentação da plataforma
  E vejo os botões "Entrar" e "Criar conta"

Cenário: Usuário autenticado acessa a home
  Dado que estou autenticado
  Quando acesso "/"
  Então sou redirecionado para "/quizzes"

Cenário: Rota autenticada sem sessão
  Dado que não estou autenticado
  Quando acesso "/quizzes"
  Então sou redirecionado para a tela de login
  E vejo a mensagem "Você precisa entrar para acessar esta página"

Cenário: Cabeçalho autenticado
  Dado que estou autenticado como "Ana"
  Quando acesso qualquer página autenticada
  Então vejo meu nome no cabeçalho
  E vejo os links "Minha conta" e "Sair"

Cenário: Aviso de e-mail não confirmado
  Dado que estou autenticado e ainda não confirmei meu e-mail
  Quando acesso uma página autenticada
  Então vejo um aviso não bloqueante pedindo a confirmação
  E consigo continuar navegando normalmente

Cenário: Rota inexistente
  Quando acesso "/pagina-que-nao-existe"
  Então vejo uma página 404 em português
```

## 9. Cenários de teste

### LiveView (`test/live_quiz_web/live/landing_live_test.exs`)
- visitante vê o conteúdo público e os dois CTAs;
- usuário autenticado é redirecionado para `/quizzes`.

### Proteção de rotas (`test/live_quiz_web/user_auth_test.exs` ou teste próprio)
- acesso não autenticado a uma rota da `live_session :authenticated` redireciona para o login com flash;
- acesso autenticado renderiza a página normalmente.

### Layout
- cabeçalho exibe o nome do usuário autenticado;
- banner de e-mail não confirmado aparece somente quando `confirmed_at` é `nil`.

## 10. Definition of Ready

- [x] Autenticação disponível (F1-03).
- [x] Decisão de landing pública em `/` tomada.
- [x] Rota de destino pós-login definida (`/quizzes`).

## 11. Definition of Done

- [ ] Landing pública implementada e responsiva a partir de 375px.
- [ ] Layout autenticado com nome, "Minha conta" e "Sair".
- [ ] Todas as rotas autenticadas protegidas no router.
- [ ] 404 traduzida.
- [ ] Testes listados acima passando.
- [ ] Acessibilidade básica: hierarquia de headings, foco visível, links com texto descritivo.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-03** — `UserAuth`, `Scope` e rotas de sessão.
- A rota `/quizzes` só existe a partir da **F1-09**; até lá, usar uma rota temporária ou implementar
  esta story imediatamente antes da F1-09 para evitar link quebrado.

## 13. Riscos e pontos de atenção

- Redirecionar `/` para `/quizzes` antes da F1-09 existir gera erro de rota — coordenar a ordem de merge.
- Não duplicar a regra de autorização dentro das LiveViews; ela pertence ao router.

## 14. Estimativa

**3 pontos** — telas simples, com atenção maior à configuração do router.
