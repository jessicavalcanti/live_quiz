# [F1-03] Autenticação: cadastro, login, logout, confirmação e redefinição de senha

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `habilitador-tecnico`, `backend`, `frontend`
> **Branch:** `feature/03-autenticacao` · **Estimativa:** 8 pontos · **Depende de:** F1-01

## 1. Contexto de negócio

Todo quiz pertence a uma pessoa. Sem identidade não existe dono, não existe dashboard "meus
quizzes" e não existe autorização. A autenticação é o **core técnico** da aplicação — não é uma
funcionalidade de negócio da sprint, mas é pré-requisito de tudo o que vem depois, inclusive das
fases 2 a 4, onde o host da sala é um usuário autenticado.

## 2. User story

**Como** visitante da plataforma,
**quero** criar uma conta, entrar, sair e recuperar minha senha,
**para que** eu tenha um espaço pessoal e seguro onde meus quizzes ficam salvos.

## 3. Escopo

### Dentro
- Contexto `LiveQuiz.Accounts` com `User`, tokens, sessão e e-mails, gerado por `mix phx.gen.auth`.
- Campo `name` obrigatório no cadastro.
- Telas: cadastro, login, logout, "esqueci minha senha", "redefinir senha", configurações da conta.
- E-mail de confirmação de conta (não bloqueante) e e-mail de redefinição de senha.
- Remoção do fluxo de login por magic link.
- Testes gerados pelo `phx.gen.auth` ajustados e passando.

### Fora
- Landing pública, layout autenticado e proteção das rotas de negócio (story F1-04).
- Autenticação da API JSON / JWT (story F1-13).
- Login social, 2FA, papéis/admin.

## 4. Decisões de arquitetura

- **`mix phx.gen.auth` como base** (AD-02): é a solução oficial, auditada, com hash de senha,
  tokens de sessão em banco, expiração e revogação. Reescrever isso do zero não traz valor.
- **E-mail + senha, sem magic link:** o `phx.gen.auth` do Phoenix 1.8 gera um fluxo em que o
  **cadastro pede apenas o e-mail**, o login primário é por magic link e a senha só é definida
  depois, na tela de configurações, após a confirmação. Esta story **reescreve esse fluxo** para o
  modelo clássico: cadastro com nome, e-mail e senha, autenticação imediata e remoção completa do
  magic link (rotas, LiveViews, funções de contexto e testes), mantendo intacta a infraestrutura de
  tokens usada por confirmação de conta e redefinição de senha. É a maior parte do esforço desta story.
- **Confirmação não bloqueante** (AD-03): o usuário entra e usa a aplicação normalmente após o
  cadastro; a UI apenas sinaliza que o e-mail ainda não foi confirmado.
- **`Scope`:** o gerador cria `LiveQuiz.Accounts.Scope`. Ele é o contrato de identidade usado por
  todas as demais stories (`scope.user`).
- **Sessão:** manter o padrão do gerador, incluindo "manter conectado" (60 dias) e revogação do
  token no logout e na troca de senha.

## 5. Modelo de dados e migrations

Tabelas geradas pelo `phx.gen.auth`, com uma alteração:

### `users`

| Coluna | Tipo | Restrições |
|---|---|---|
| `id` | bigserial | PK |
| `name` | string(80) | **NOT NULL** (adição desta story) |
| `email` | citext | NOT NULL, unique |
| `hashed_password` | string | conforme gerador |
| `confirmed_at` | utc_datetime | nullable |
| `inserted_at` / `updated_at` | timestamps | NOT NULL |

### `users_tokens`

Gerada pelo `phx.gen.auth`, sem alterações nesta story.

> A coluna `name` deve ser adicionada **na própria migration gerada** (projeto novo, ainda sem dados),
> junto com a extensão `citext`.

## 6. Contratos técnicos

### Comando

```bash
mix phx.gen.auth Accounts User users
```

Consultar `mix help phx.gen.auth` para as opções disponíveis na versão instalada. Após a geração,
editar o código para remover o fluxo de magic link.

### Módulos resultantes

```text
lib/live_quiz/accounts.ex
lib/live_quiz/accounts/user.ex
lib/live_quiz/accounts/user_token.ex
lib/live_quiz/accounts/user_notifier.ex
lib/live_quiz/accounts/scope.ex
lib/live_quiz_web/user_auth.ex
lib/live_quiz_web/live/user_live/registration.ex
lib/live_quiz_web/live/user_live/login.ex
lib/live_quiz_web/live/user_live/settings.ex
lib/live_quiz_web/live/user_live/confirmation.ex
lib/live_quiz_web/controllers/user_session_controller.ex
```

### Alterações obrigatórias no código gerado

1. `LiveQuiz.Accounts.User`: incluir `field :name, :string` no schema e no changeset de registro,
   com `validate_required([:name])` e `validate_length(:name, min: 2, max: 80)`.
2. **Cadastro com senha:** o `registration_changeset` do gerador deve exigir `password` (e
   `password_confirmation`) no momento do cadastro, e não apenas nas configurações. O formulário de
   cadastro passa a ter, nesta ordem: Nome, E-mail, Senha e Confirmação de senha.
3. **Autenticação imediata após o cadastro:** o `Registration` LiveView cria o usuário e chama o
   `log_in_user/3` do `UserAuth` no mesmo fluxo, enviando o e-mail de confirmação em paralelo.
4. **Login por senha como caminho único:** a tela de login submete e-mail e senha para o
   `UserSessionController`, usando `LiveQuiz.Accounts.get_user_by_email_and_password/2`.
5. **Remover o magic link por completo:** rotas, LiveViews, funções de contexto (`deliver_login_instructions`
   e equivalentes), textos e testes. Manter `deliver_confirmation_instructions` e
   `deliver_reset_password_instructions`.
6. **Sudo mode:** se a versão gerada exigir reautenticação recente (sudo mode) para trocar e-mail ou
   senha nas configurações, manter o comportamento — ele passa a se apoiar na senha, não no magic link.
7. Traduzir para pt-BR todos os textos de UI e os corpos dos e-mails.

### Rotas esperadas (nomes conforme o gerador da versão instalada)

```text
GET/POST  /users/register
GET/POST  /users/log-in
DELETE    /users/log-out
GET/POST  /users/reset-password
GET/PUT   /users/reset-password/:token
GET       /users/confirm/:token
GET/PUT   /users/settings
```

## 7. Regras de negócio e validações

- `name`: obrigatório, 2 a 80 caracteres.
- `email`: obrigatório, formato válido, único (case-insensitive via `citext`).
- `password`: obrigatório, mínimo 12 caracteres (padrão do gerador), armazenado com hash.
- Login com credenciais inválidas exibe mensagem genérica ("E-mail ou senha inválidos"), sem
  revelar se o e-mail existe.
- Solicitar redefinição para e-mail inexistente exibe a **mesma** mensagem de sucesso (não enumera contas).
- Token de redefinição é de uso único e expira conforme o padrão do gerador.
- Ao redefinir a senha, todas as sessões ativas do usuário são invalidadas.
- Conta não confirmada **não** impede login nem uso da aplicação.

## 8. Critérios de aceite

```gherkin
Cenário: Cadastro bem-sucedido
  Dado que estou na página de cadastro
  Quando preencho nome, e-mail válido e senha com pelo menos 12 caracteres
  E confirmo o cadastro
  Então minha conta é criada
  E eu fico autenticado na aplicação
  E um e-mail de confirmação é enviado para o meu endereço

Cenário: Cadastro com e-mail já utilizado
  Dado que já existe uma conta com o e-mail "ana@example.com"
  Quando tento me cadastrar com o mesmo e-mail
  Então vejo uma mensagem de erro no campo de e-mail
  E nenhuma conta nova é criada

Cenário: Cadastro sem nome
  Dado que estou na página de cadastro
  Quando deixo o campo nome em branco e submeto
  Então vejo a mensagem de erro "não pode ficar em branco" no campo nome

Cenário: Login com credenciais válidas
  Dado que possuo uma conta ativa
  Quando informo meu e-mail e minha senha corretos
  Então sou autenticado e redirecionado para a área autenticada

Cenário: Login com senha incorreta
  Dado que possuo uma conta ativa
  Quando informo a senha errada
  Então continuo na tela de login
  E vejo uma mensagem genérica de credenciais inválidas

Cenário: Logout
  Dado que estou autenticado
  Quando clico em "Sair"
  Então minha sessão é encerrada
  E o token de sessão é removido do banco

Cenário: Recuperação de senha
  Dado que possuo uma conta com o e-mail "ana@example.com"
  Quando solicito a redefinição de senha para esse e-mail
  Então recebo um e-mail com o link de redefinição
  E ao abrir o link e informar uma nova senha válida, consigo entrar com ela

Cenário: E-mail inexistente na recuperação
  Quando solicito redefinição para um e-mail que não existe
  Então vejo a mesma mensagem de sucesso exibida no caso válido
  E nenhum e-mail é enviado

Cenário: Confirmação não bloqueia o uso
  Dado que acabei de me cadastrar e ainda não confirmei meu e-mail
  Quando navego pela aplicação autenticada
  Então consigo usá-la normalmente
```

## 9. Cenários de teste

### Contexto (`test/live_quiz/accounts_test.exs`)
- registra usuário com dados válidos;
- rejeita e-mail duplicado, e-mail inválido, senha curta e nome ausente;
- autentica com senha correta e falha com senha incorreta;
- gera, valida e expira token de sessão;
- gera token de reset, redefine a senha e invalida o token após o uso;
- redefinição de senha invalida as sessões existentes.

### LiveView (`test/live_quiz_web/live/user_live/*_test.exs`)
- renderiza formulários de cadastro, login e recuperação;
- cadastro válido autentica e redireciona;
- cadastro inválido exibe erros sem reload;
- login inválido exibe mensagem genérica;
- fluxo completo de redefinição de senha via token.

### Controller
- `DELETE /users/log-out` encerra a sessão e redireciona.

### E-mail
- `Swoosh.Adapters.Test` confirma o envio dos e-mails de confirmação e de redefinição, com o token no corpo.

## 10. Definition of Ready

- [x] Modelo de autenticação decidido (e-mail + senha, sem magic link).
- [x] Política de confirmação de e-mail decidida (não bloqueante).
- [x] Campo `name` obrigatório definido (2–80 caracteres).
- [x] Ambiente de e-mail local disponível (F1-01).

## 11. Definition of Done

- [ ] Fluxos de cadastro, login, logout, confirmação e redefinição funcionando ponta a ponta com o Mailpit.
- [ ] Nenhum resquício de código, rota ou teste de magic link.
- [ ] Textos de UI e e-mails em pt-BR.
- [ ] Testes de contexto e de LiveView listados acima passando.
- [ ] `LiveQuiz.Accounts.Scope` disponível para as demais stories.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-01** — projeto Phoenix e Mailer configurados.

## 13. Riscos e pontos de atenção

- **Risco principal:** o fluxo gerado pelo Phoenix 1.8 é substancialmente diferente do que esta
  story descreve (cadastro só com e-mail, magic link, senha definida depois). Conferir o código
  gerado antes de estimar prazo e comparar com este documento antes de começar a editar.
- A remoção do magic link precisa ser cirúrgica: os módulos de token são compartilhados com
  confirmação e reset de senha.
- Os testes gerados pelo `phx.gen.auth` cobrem o magic link e o cadastro sem senha; boa parte
  precisará ser reescrita, não apenas ajustada.
- `citext` exige `CREATE EXTENSION IF NOT EXISTS citext` na migration (o gerador já inclui).
- Não versionar credenciais; o `secret_key_base` de dev é gerado pelo `phx.new`.

## 14. Estimativa

**8 pontos** — reescrita relevante do fluxo gerado (cadastro com senha, remoção do magic link) e da suíte de testes correspondente.
