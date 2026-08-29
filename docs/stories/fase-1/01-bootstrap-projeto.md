# [F1-01] Bootstrap do projeto Phoenix, ambiente de desenvolvimento e empacotamento de release

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `infra`
> **Branch:** `feature/01-bootstrap-projeto` · **Estimativa:** 8 pontos · **Depende de:** —

## 1. Contexto de negócio

O repositório contém apenas documentação. Nenhuma funcionalidade da fase 1 pode ser construída
antes de existir uma aplicação Phoenix executável, com banco de dados e servidor de e-mail locais.

Além disso, cada fase do projeto termina em uma **entrega demonstrável**: será preciso subir a
aplicação exatamente no estado de uma entrega passada para gravar vídeos de demonstração, meses
depois, sem que o desenvolvimento em curso interfira. Isso exige três coisas desde o primeiro
commit da aplicação: uma **versão declarada**, um **empacotamento reproduzível** e um **comando
único** para levantar qualquer versão já entregue.

Esta story cria a fundação sobre a qual todas as outras rodam.

## 2. User story

**Como** pessoa desenvolvedora do projeto,
**quero** um projeto Phoenix configurado com banco e e-mail locais em containers, versionado e
empacotável em uma imagem executável,
**para que** eu consiga trabalhar nas funcionalidades de negócio e, a qualquer momento, levantar
localmente uma versão já entregue para demonstrá-la.

## 3. Escopo

### Dentro
- Geração do projeto Phoenix na raiz do repositório, com `version: "0.0.1"` no `mix.exs`.
- `docker-compose.yml` com PostgreSQL 16 e Mailpit para o dia a dia.
- Configuração do Ecto (dev/test) e do Swoosh (SMTP em dev, Test em teste).
- `Dockerfile` multi-stage produzindo um **Phoenix release** (`mix release`) executável.
- `docker-compose.demo.yml` que constrói a imagem a partir do código local e sobe a aplicação
  completa (app + banco + e-mail) isolada por versão.
- Script `bin/demo` para levantar qualquer tag já publicada em um comando.
- `.gitignore`, `README.md` com instruções de setup, de release e de demonstração.

### Fora
- Autenticação (story 03), domínio de quizzes (story 05), pipeline de lint/cobertura (story 02).
- Deploy em nuvem, provedor real de e-mail, TLS.
- O workflow `.github/workflows/release.yml` **já existe** no repositório: ele lê a versão do
  `mix.exs`, cria a tag e publica a release a cada merge na `main`. Esta story apenas passa a
  alimentá-lo com um `mix.exs` real — não é preciso escrevê-lo.

## 4. Decisões de arquitetura

- **Aplicação na raiz do repositório**, sem umbrella e sem subpasta: `mix phx.new . --app live_quiz`.
  Projeto único, sem necessidade de isolamento entre apps OTP.
- **Docker Compose** para Postgres e Mailpit: ambiente reproduzível e igual ao usado no CI.
- **Mailpit** como servidor SMTP de desenvolvimento (UI em `http://localhost:8025`), com Swoosh
  usando o adapter SMTP (`gen_smtp`) em `dev` e `Swoosh.Adapters.Test` em `test`.
- Módulos: `LiveQuiz` (domínio) e `LiveQuizWeb` (interface).

### Versionamento e releases

- **O `mix.exs` é a única fonte da verdade da versão.** O workflow de release lê `version:` do
  `mix.exs` a cada merge na `main`, cria a tag `vX.Y.Z` e publica a release. Não existe versão
  escrita em outro lugar.
- **Esquema de versão** (AD-19): cada entrega de fase é um **minor**, e qualquer outro merge na
  `main` é um **patch**.

  | Versão | Significado |
  |---|---|
  | `0.0.x` | desenvolvimento antes da primeira entrega |
  | `0.1.0` | **entrega da Fase 1** — criação e gerenciamento de quizzes |
  | `0.2.0` | **entrega da Fase 2** — sala e lobby em tempo real |
  | `0.3.0` | **entrega da Fase 3** — execução do quiz em tempo real |
  | `1.0.0` | **entrega da Fase 4** — produto completo com ranking e histórico |
  | `0.1.1`, `0.2.3`, … | correções pontuais mergeadas na `main` entre fases |

  A release de fase é sempre reconhecível por terminar em `.0`, e o workflow acrescenta o cabeçalho
  "Entrega da Fase N" às notas.

### Empacotamento e demonstração

- **Phoenix release via `mix release`** dentro de um `Dockerfile` multi-stage: o artefato roda sem
  Elixir instalado, com assets já compilados e sem código-fonte. É o que garante que a versão
  demonstrada é exatamente a versão entregue.
- **Build local a partir do código da tag** (em vez de imagem publicada em registry): não depende de
  registry nem de credenciais, e o `docker-compose.demo.yml` fica versionado junto do código que ele
  constrói. O custo é o tempo de build na primeira vez que cada versão é levantada.
- **`git worktree` em vez de `git checkout`** no script `bin/demo`: a versão antiga é materializada
  em `.demo/<tag>/` e a sua branch de trabalho **não é tocada**. Dá para desenvolver e demonstrar ao
  mesmo tempo.
- **Isolamento por versão**: cada demo usa seu próprio projeto Compose e seu próprio volume de banco,
  então levantar a `v0.1.0` não contamina o banco de desenvolvimento nem o de outra demo.

## 5. Modelo de dados e migrations

Nenhuma tabela de negócio nesta story. Apenas a criação do banco:

```bash
mix ecto.create
```

O contêiner de demonstração executa `LiveQuiz.Release.migrate/0` no boot, e não `mix ecto.migrate`
(o release não tem Mix disponível em tempo de execução).

## 6. Contratos técnicos

### Comando de geração

```bash
mix phx.new . --app live_quiz --module LiveQuiz --database postgres
```

Manter os defaults do Phoenix 1.8 (LiveView, Tailwind, daisyUI, esbuild).

### Arquivos criados/alterados

| Arquivo | Conteúdo |
|---|---|
| `mix.exs` | Projeto `:live_quiz` com `version: "0.0.1"`; adicionar `{:gen_smtp, "~> 1.2"}` |
| `docker-compose.yml` | Serviços `db` (postgres:16-alpine) e `mailpit` (axllent/mailpit) |
| `config/dev.exs` | Repo apontando para `localhost:5432`, usuário/senha `postgres`; Swoosh SMTP em `localhost:1025` |
| `config/test.exs` | Repo `live_quiz_test`, `pool: Ecto.Adapters.SQL.Sandbox`; Swoosh `Test` adapter |
| `config/runtime.exs` | Lê `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` e `PORT` quando `config_env() == :prod` |
| `lib/live_quiz/release.ex` | `LiveQuiz.Release` com `migrate/0` e `seed/0` para uso dentro do release |
| `Dockerfile` | Multi-stage: builder Elixir/Alpine → `mix release` → imagem final enxuta |
| `docker-compose.demo.yml` | Sobe `app` (build local) + `db` + `mailpit` isolados por versão |
| `bin/demo` | Script executável para levantar, listar e parar demonstrações por tag |
| `README.md` | Pré-requisitos, setup, portas, versionamento, releases e como gravar demonstrações |
| `.gitignore` | Gerado pelo Phoenix + `.demo/` |

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

### `lib/live_quiz/release.ex`

```elixir
defmodule LiveQuiz.Release do
  @moduledoc "Tarefas executadas dentro do release, onde o Mix não está disponível."
  @app :live_quiz

  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @spec seed() :: :ok
  def seed
  # executa priv/repo/seeds.exs quando presente no release; no-op caso contrário
end
```

`priv/repo/seeds.exs` deve entrar em `:extra_applications`/`releases` para ser copiado ao release
(`overlays` ou `priv` já é incluído por padrão).

### `Dockerfile` (estrutura esperada)

```dockerfile
# --- builder
FROM hexpm/elixir:1.20.3-erlang-29.0-alpine-3.20 AS builder
ENV MIX_ENV=prod
WORKDIR /app
RUN apk add --no-cache build-base git
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY priv priv
COPY assets assets
COPY lib lib
RUN mix assets.deploy && mix compile && mix release

# --- runtime
FROM alpine:3.20 AS app
RUN apk add --no-cache libstdc++ openssl ncurses-libs
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/live_quiz ./
ENV PHX_SERVER=true
EXPOSE 4000
CMD ["bin/live_quiz", "start"]
```

### `docker-compose.demo.yml`

```yaml
name: live_quiz_demo

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: live_quiz_demo
    volumes: ["demo_pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 10

  mailpit:
    image: axllent/mailpit
    ports: ["8025:8025"]

  app:
    build: .
    depends_on:
      db: { condition: service_healthy }
    environment:
      DATABASE_URL: ecto://postgres:postgres@db/live_quiz_demo
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:-demo-secret-key-base-com-no-minimo-64-caracteres-para-a-demonstracao-local}
      PHX_HOST: localhost
      PORT: "4000"
      SMTP_HOST: mailpit
    ports: ["4000:4000"]
    command: >
      sh -c "bin/live_quiz eval 'LiveQuiz.Release.migrate(); LiveQuiz.Release.seed()' &&
             bin/live_quiz start"

volumes:
  demo_pgdata:
```

### `bin/demo`

Script executável (`chmod +x`) com três subcomandos:

```bash
bin/demo <tag>    # levanta a aplicação naquela versão em http://localhost:4000
bin/demo list     # lista as tags/releases disponíveis
bin/demo stop     # derruba a demonstração em execução e libera as portas
```

Comportamento de `bin/demo <tag>`:

1. `git fetch --tags` e valida que a tag existe (erro claro se não existir);
2. cria (ou reaproveita) um worktree isolado em `.demo/<tag>` apontando para a tag —
   **a branch de trabalho atual não é alterada**;
3. sobe `docker compose -f docker-compose.demo.yml --project-name live_quiz_demo_<tag_sanitizada> up --build -d`
   a partir daquele worktree, com volume de banco próprio;
4. aguarda o healthcheck e imprime as informações da demonstração:

```text
✓ Live Quiz v0.1.0 (Fase 1 — Criação e gerenciamento de quizzes)
  Aplicação : http://localhost:4000
  E-mails   : http://localhost:8025
  Login demo: demo@livequiz.dev / demo123456789
  Encerrar  : bin/demo stop
```

`.demo/` entra no `.gitignore`.

### Setup documentado no README

```bash
# desenvolvimento
docker compose up -d
mix setup
mix phx.server   # http://localhost:4000

# demonstrar uma versão já entregue
bin/demo v0.1.0
bin/demo stop
```

## 7. Regras de negócio e validações

- A versão declarada em `mix.exs` é a única fonte da verdade; o workflow de release não aceita
  versão em outro formato que não `X.Y.Z`.
- Um merge na `main` cuja versão já tenha tag **não** gera release nova (o workflow apenas avisa).
- Entregas de fase usam `0.1.0`, `0.2.0`, `0.3.0` e `1.0.0`; os demais merges usam patch.
- A demonstração de uma versão nunca altera a árvore de trabalho nem o banco de desenvolvimento.
- Duas demonstrações de versões diferentes não compartilham volume de banco.

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

Cenário: Versão declarada
  Quando eu inspeciono o mix.exs
  Então existe um campo version no formato X.Y.Z
  E é a partir dele que a tag de release é gerada

Cenário: Imagem de release executável
  Quando eu executo "docker build ."
  Então a imagem é construída com sucesso
  E o container inicia a aplicação sem Elixir instalado no ambiente final

Cenário: Levantar uma versão entregue
  Dada a tag v0.1.0 publicada no repositório
  Quando eu executo "bin/demo v0.1.0"
  Então a aplicação daquela versão responde em http://localhost:4000
  E o banco está migrado e populado com os dados de demonstração
  E a minha branch de trabalho permanece intacta

Cenário: Encerrar a demonstração
  Dada uma demonstração em execução
  Quando eu executo "bin/demo stop"
  Então os containers são derrubados e a porta 4000 é liberada

Cenário: Tag inexistente
  Quando eu executo "bin/demo v9.9.9"
  Então recebo uma mensagem de erro clara informando que a versão não existe
  E nenhum container é iniciado

Cenário: Demonstração não interfere no desenvolvimento
  Dado que estou com o ambiente de desenvolvimento rodando
  Quando eu levanto uma demonstração de outra versão
  Então o banco de desenvolvimento permanece inalterado
```

## 9. Cenários de teste

- **Automatizados:** os testes gerados pelo `mix phx.new` (`PageControllerTest`, `ErrorHTMLTest`,
  `ErrorJSONTest`) devem passar.
- **Manuais (obrigatórios antes de fechar a story):**
  1. `docker compose up -d`, `mix setup`, `mix phx.server` → aplicação em `localhost:4000`;
  2. Mailpit acessível em `localhost:8025`;
  3. `docker build -t live_quiz:teste .` conclui e `docker run` sobe o release;
  4. `bin/demo list` lista as tags existentes;
  5. `bin/demo <tag>` sobe a aplicação e `bin/demo stop` a derruba (testável com a primeira tag
     gerada após o merge desta story);
  6. `git status` limpo depois de rodar e parar uma demonstração.

## 10. Definition of Ready

- [x] Nome do app e dos módulos definidos (`live_quiz` / `LiveQuiz`).
- [x] Versões de Elixir, Phoenix e Postgres definidas.
- [x] Decisão de app na raiz do repositório tomada.
- [x] Estratégia de e-mail em dev definida (Mailpit).
- [x] Esquema de versionamento definido (fase = minor, demais merges = patch).
- [x] Mecanismo de demonstração definido (build local a partir da tag, em worktree isolado).
- [x] Workflow `release.yml` já existente no repositório.

## 11. Definition of Done

- [ ] Projeto Phoenix gerado e compilando sem warnings.
- [ ] `docker-compose.yml` versionado e funcional.
- [ ] `mix setup` cria o banco e as dependências sem intervenção manual.
- [ ] `mix test` verde.
- [ ] `mix.exs` com `version: "0.0.1"`.
- [ ] `Dockerfile` construindo o release e o container subindo a aplicação.
- [ ] `docker-compose.demo.yml` e `bin/demo` funcionando (`<tag>`, `list`, `stop`).
- [ ] `LiveQuiz.Release.migrate/0` e `seed/0` implementados.
- [ ] `.demo/` no `.gitignore`.
- [ ] README com instruções completas de setup, versionamento e demonstração, em pt-BR.
- [ ] DoD global do épico atendida.

## 12. Dependências

Nenhuma. É a primeira story da fase e bloqueia todas as demais.

## 13. Riscos e pontos de atenção

- Conflito de porta 5432 com um Postgres já instalado na máquina — documentar no README como alterar a porta exposta.
- `mix phx.new .` em diretório não vazio pede confirmação; o markdown de planejamento e a pasta `docs/` devem ser preservados.
- Versão do Phoenix instalada localmente pode estar desatualizada: rodar `mix archive.install hex phx_new` antes.
- O `bin/demo` só consegue levantar tags cujo código **já contenha** o `Dockerfile` e o
  `docker-compose.demo.yml` — ou seja, da primeira release em diante. Não há como demonstrar commits
  anteriores a esta story, o que é irrelevante na prática.
- O build da imagem na primeira execução de cada versão leva alguns minutos; o cache do Docker
  resolve as execuções seguintes.
- `SECRET_KEY_BASE` da demonstração é um valor fixo de conveniência e **não** deve ser reutilizado
  fora do ambiente local.
- Como o release roda em `MIX_ENV=prod`, os seeds precisam estar disponíveis dentro do artefato;
  confirmar que `priv/` foi incluído.

## 14. Estimativa

**8 pontos** — o bootstrap em si é trivial, mas o Dockerfile de release, o compose de demonstração e o script `bin/demo` concentram o esforço e exigem validação manual ponta a ponta.
