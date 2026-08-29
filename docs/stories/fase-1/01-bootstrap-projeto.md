# [F1-01] Bootstrap do projeto Phoenix e ambiente de desenvolvimento

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `infra`
> **Branch:** `feature/01-bootstrap-projeto` · **Estimativa:** 3 pontos · **Depende de:** —

## 1. Contexto de negócio

O repositório contém apenas o documento de planejamento. Nenhuma funcionalidade da fase 1 pode ser
construída antes de existir uma aplicação Phoenix executável, com banco de dados e servidor de
e-mail locais. Esta story cria a fundação sobre a qual todas as outras rodam.

## 2. User story

**Como** pessoa desenvolvedora do projeto,
**quero** um projeto Phoenix já configurado com banco e e-mail locais em containers,
**para que** eu consiga subir a aplicação com poucos comandos e trabalhar nas funcionalidades de negócio.

## 3. Escopo

### Dentro
- Geração do projeto Phoenix na raiz do repositório.
- `docker-compose.yml` com PostgreSQL 16 e Mailpit.
- Configuração do Ecto (dev/test) e do Swoosh (SMTP em dev, Test em teste).
- `.gitignore`, `README.md` com instruções de setup e primeiro commit da aplicação.

### Fora
- Autenticação (story 03), domínio de quizzes (story 05), CI (story 02).
- Configuração de produção, deploy, Dockerfile de release.

## 4. Decisões de arquitetura

- **Aplicação na raiz do repositório**, sem umbrella e sem subpasta: `mix phx.new . --app live_quiz`.
  Projeto único, sem necessidade de isolamento entre apps OTP.
- **Docker Compose** para Postgres e Mailpit: ambiente reproduzível e igual ao usado no CI.
- **Mailpit** como servidor SMTP de desenvolvimento (UI em `http://localhost:8025`), com Swoosh
  usando o adapter SMTP (`gen_smtp`) em `dev` e `Swoosh.Adapters.Test` em `test`.
  Produção fica apenas como placeholder comentado.
- Módulos: `LiveQuiz` (domínio) e `LiveQuizWeb` (interface).

## 5. Modelo de dados e migrations

Nenhuma tabela de negócio nesta story. Apenas a criação do banco:

```bash
mix ecto.create
```

## 6. Contratos técnicos

### Comando de geração

```bash
mix phx.new . --app live_quiz --module LiveQuiz --database postgres
```

Manter os defaults do Phoenix 1.8 (LiveView, Tailwind, daisyUI, esbuild).

### Arquivos criados/alterados

| Arquivo | Conteúdo |
|---|---|
| `mix.exs` | Projeto `:live_quiz`; adicionar `{:gen_smtp, "~> 1.2"}` |
| `docker-compose.yml` | Serviços `db` (postgres:16-alpine) e `mailpit` (axllent/mailpit) |
| `config/dev.exs` | Repo apontando para `localhost:5432`, usuário/senha `postgres`; Swoosh SMTP em `localhost:1025` |
| `config/test.exs` | Repo `live_quiz_test`, `pool: Ecto.Adapters.SQL.Sandbox`; Swoosh `Test` adapter |
| `README.md` | Pré-requisitos, passo a passo de setup, portas e comandos úteis |
| `.gitignore` | Gerado pelo Phoenix, sem alterações |

### `docker-compose.yml` esperado

```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: live_quiz_dev
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

  mailpit:
    image: axllent/mailpit
    ports: ["1025:1025", "8025:8025"]

volumes:
  pgdata:
```

### Configuração do Swoosh em `config/dev.exs`

```elixir
config :live_quiz, LiveQuiz.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "localhost",
  port: 1025,
  auth: :never,
  tls: :never
```

### Setup documentado no README

```bash
docker compose up -d
mix setup
mix phx.server   # http://localhost:4000
```

## 7. Regras de negócio e validações

Não se aplica — story de infraestrutura.

## 8. Critérios de aceite

```gherkin
Cenário: Subir a aplicação do zero
  Dado um clone limpo do repositório
  Quando eu executo "docker compose up -d" e "mix setup"
  E executo "mix phx.server"
  Então a aplicação responde em http://localhost:4000
  E a página inicial padrão do Phoenix é exibida

Cenário: Banco de desenvolvimento disponível
  Dado o container "db" em execução
  Quando eu executo "mix ecto.create"
  Então o banco "live_quiz_dev" é criado sem erros

Cenário: Suíte de testes executável
  Dado o ambiente configurado
  Quando eu executo "mix test"
  Então a suíte roda e todos os testes gerados passam

Cenário: Servidor de e-mail local acessível
  Dado o container "mailpit" em execução
  Quando eu acesso http://localhost:8025
  Então a caixa de entrada do Mailpit é exibida
```

## 9. Cenários de teste

- **Automatizados:** apenas os testes gerados pelo `mix phx.new` (`PageControllerTest`, `ErrorHTMLTest`, `ErrorJSONTest`) devem passar.
- **Manuais:** subir containers, `mix setup`, `mix phx.server`, abrir `localhost:4000` e `localhost:8025`.

## 10. Definition of Ready

- [x] Nome do app e dos módulos definidos (`live_quiz` / `LiveQuiz`).
- [x] Versões de Elixir, Phoenix e Postgres definidas.
- [x] Decisão de app na raiz do repositório tomada.
- [x] Estratégia de e-mail em dev definida (Mailpit).

## 11. Definition of Done

- [ ] Projeto Phoenix gerado e compilando sem warnings.
- [ ] `docker-compose.yml` versionado e funcional.
- [ ] `mix setup` cria o banco e as dependências sem intervenção manual.
- [ ] `mix test` verde.
- [ ] README com instruções completas de setup em pt-BR.
- [ ] DoD global do épico atendida.

## 12. Dependências

Nenhuma. É a primeira story da fase e bloqueia todas as demais.

## 13. Riscos e pontos de atenção

- Conflito de porta 5432 com um Postgres já instalado na máquina — documentar no README como alterar a porta exposta.
- `mix phx.new .` em diretório não vazio pede confirmação; o markdown de planejamento e a pasta `docs/` devem ser preservados.
- Versão do Phoenix instalada localmente pode estar desatualizada: rodar `mix archive.install hex phx_new` antes.

## 14. Estimativa

**3 pontos** — trabalho conhecido, sem incerteza de domínio.
