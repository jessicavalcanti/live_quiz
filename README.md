# Live Quiz

Plataforma de quiz em tempo real (inspirada no Kahoot), construída com **Elixir + Phoenix +
Phoenix LiveView + PostgreSQL**, com uma **API JSON** paralela para consumo futuro por app mobile.

O projeto é entregue em 4 fases. O plano completo está em
[`plataforma_quiz_4_fases.md`](plataforma_quiz_4_fases.md) e as instruções de trabalho no
repositório estão em [`AGENTS.md`](AGENTS.md).

---

## Pré-requisitos

| Ferramenta | Versão |
|---|---|
| Elixir | 1.20.3 |
| Erlang/OTP | 29 |
| Docker + Docker Compose | v2 |

O PostgreSQL e o servidor de e-mail sobem em containers — não é preciso instalá-los na máquina.

---

## Subindo o ambiente de desenvolvimento

```bash
docker compose up -d   # PostgreSQL 16 + Mailpit
mix setup              # dependências, banco, migrations e assets
mix phx.server         # http://localhost:4000
```

| Serviço | Endereço |
|---|---|
| Aplicação | http://localhost:4000 |
| Mailpit (e-mails de desenvolvimento) | http://localhost:8025 |
| PostgreSQL | `localhost:5432` (`postgres` / `postgres`) |

Todo e-mail enviado em desenvolvimento é entregue ao Mailpit e fica visível na caixa de entrada em
`http://localhost:8025` — nada sai para a internet.

### Portas já ocupadas na sua máquina

As portas do host são configuráveis por variável de ambiente. Se você já tem um PostgreSQL na 5432,
por exemplo:

```bash
DB_PORT=5433 docker compose up -d
DB_PORT=5433 mix setup
DB_PORT=5433 mix phx.server
```

| Variável | Padrão | O que muda |
|---|---|---|
| `DB_PORT` | `5432` | porta do PostgreSQL no host (compose, `dev` e `test`) |
| `SMTP_PORT` | `1025` | porta SMTP do Mailpit |
| `MAILPIT_UI_PORT` | `8025` | porta da caixa de entrada do Mailpit |
| `DEMO_PORT` | `4000` | porta da aplicação nas demonstrações (`bin/demo`) |

Exportar a variável no seu shell (`export DB_PORT=5433`) evita repeti-la em cada comando.

---

## API JSON

A API vive em `/api/v1` e é autenticada por **JWT** (Guardian). Toda resposta usa o envelope
`data` para sucesso e `errors` para falha.

| Rota | Descrição |
|---|---|
| `POST /api/v1/session` | troca e-mail e senha por um par de tokens |
| `POST /api/v1/session/refresh` | troca o refresh token por um novo access token |
| `DELETE /api/v1/session` | encerra a sessão do lado do cliente (204) |
| `GET /api/v1/me` | dados do usuário autenticado |
| `GET /api/v1/quizzes` | lista os quizzes do usuário do token, paginados |
| `POST /api/v1/quizzes` | cria um quiz (201, com header `Location`) |
| `GET /api/v1/quizzes/:id` | detalhe do quiz com perguntas e alternativas |
| `PUT`/`PATCH /api/v1/quizzes/:id` | atualiza o quiz (as duas se comportam igual) |
| `DELETE /api/v1/quizzes/:id` | exclui o quiz e, em cascata, suas perguntas (204) |
| `GET /api/v1/quizzes/:quiz_id/questions` | lista as perguntas do quiz, ordenadas por `position` |
| `POST /api/v1/quizzes/:quiz_id/questions` | cria uma pergunta com suas 4 alternativas (201) |
| `GET /api/v1/quizzes/:quiz_id/questions/:id` | detalhe de uma pergunta |
| `PUT`/`PATCH /api/v1/quizzes/:quiz_id/questions/:id` | atualiza texto e alternativas |
| `PATCH /api/v1/quizzes/:quiz_id/questions/:id/move` | move a pergunta uma casa (`up`/`down`) |
| `DELETE /api/v1/quizzes/:quiz_id/questions/:id` | exclui a pergunta e renumera as seguintes (204) |

```bash
curl -s -X POST http://localhost:4000/api/v1/session \
  -H 'Content-Type: application/json' \
  -d '{"email":"voce@example.com","password":"sua-senha"}'

curl -s http://localhost:4000/api/v1/me -H "Authorization: Bearer $ACCESS_TOKEN"

curl -s 'http://localhost:4000/api/v1/quizzes?page=1&per_page=20&search=geo' \
  -H "Authorization: Bearer $ACCESS_TOKEN"

curl -s -X POST http://localhost:4000/api/v1/quizzes \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"quiz":{"title":"Geografia","description":"Capitais do mundo"}}'

curl -s -X POST http://localhost:4000/api/v1/quizzes/1/questions \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"question":{"text":"Qual é a capital do Brasil?","answer_options":[
        {"text":"Rio de Janeiro","position":1,"is_correct":false},
        {"text":"Brasília","position":2,"is_correct":true},
        {"text":"São Paulo","position":3,"is_correct":false},
        {"text":"Salvador","position":4,"is_correct":false}]}}'

curl -s -X PATCH http://localhost:4000/api/v1/quizzes/1/questions/10/move \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"direction":"up"}'
```

A listagem responde com `data` (uma lista pura) e `meta` (`page`, `per_page`, `total_entries`,
`total_pages`). `page` vale 1 por padrão e `per_page`, 20, com **teto de 100** — valores fora da
faixa ou não numéricos voltam para o padrão, sem erro. `search` faz busca por título, sem
diferenciar maiúsculas, e um termo em branco não filtra nada.

Cada quiz traz `questions_count` e `playable` prontos do contexto; o detalhe (`GET
/api/v1/quizzes/:id`) ainda aninha as perguntas ordenadas por `position`, cada uma com suas quatro
alternativas e o campo `is_correct` — o consumidor autenticado é o dono do quiz. Datas saem sempre
em ISO 8601 UTC. Quiz de outro usuário é indistinguível de quiz inexistente: **404**.

Alternativa não tem recurso próprio: como toda pergunta tem exatamente 4, elas trafegam **aninhadas
na pergunta** e são gravadas na mesma transação — uma criação ou edição inválida não deixa registro
parcial. A `position` da pergunta nunca é aceita do cliente: é calculada na criação e só muda pelo
`move`, que responde com a lista inteira e reordenada do quiz (mover a pergunta que já está na borda
é um 200 com a lista inalterada). Na atualização, **envie o `id` de cada alternativa** para que as
linhas existentes sejam atualizadas em vez de substituídas. Erros de conjunto — nenhuma correta, duas
corretas, quantidade diferente de 4, textos repetidos — voltam em **422** sob a chave
`answer_options`, com as mesmas mensagens da interface web, e o 51º cadastro responde 422 com o
limite atingido.

O **access token** dura 15 minutos e o **refresh token**, 30 dias; eles são distinguidos pelo claim
`typ`, e um refresh token não é aceito em rotas protegidas. O segredo de assinatura é independente
do `secret_key_base` do Phoenix e vem de `GUARDIAN_SECRET_KEY` em produção.

> **Dívida técnica — não há revogação de token no servidor.** O projeto não usa `Guardian.DB`, então
> nenhum token é persistido e nenhuma consulta ao banco acontece por requisição. A contrapartida é
> que `DELETE /api/v1/session` só orienta o cliente a descartar os tokens: um token vazado continua
> válido até expirar. Uma revogação real (lista de negação ou `Guardian.DB`) fica para uma fase
> futura.

---

## Qualidade

```bash
mix precommit    # compile --warnings-as-errors + deps.unlock + format + credo --strict + test
mix coveralls    # cobertura de testes (mínimo de 80%)
```

Rode `mix precommit` antes de cada push: é o mesmo conjunto de verificações que o CI executa em todo
PR para a `develop` e para a `main`.

O workflow [`.github/workflows/ci.yml`](.github/workflows/ci.yml) roda, nesta ordem:

| Etapa | Comando |
|---|---|
| Dependências travadas | `mix deps.get --check-locked` |
| Formatação | `mix format --check-formatted` |
| Compilação sem warnings | `mix compile --warnings-as-errors` |
| Análise estática | `mix credo --strict` |
| Testes + cobertura | `mix coveralls` |
| Proteção da main | reprova PR para a `main` que não venha da `develop` |

A `main` é protegida no GitHub: exige PR, exige esses checks verdes e a branch atualizada, e não
aceita `force push` nem exclusão.

A cobertura mede o código que nós escrevemos. O andaime gerado pelo `mix phx.new` (biblioteca de
componentes, layouts, macros de `live_quiz_web.ex`, telemetria) e o código que só roda fora da suíte
(`application.ex`, `release.ex`) ficam de fora — a lista e o motivo estão em
[`coveralls.json`](coveralls.json).

---

## Versionamento e releases

A versão é declarada **apenas** em `mix.exs`. Todo merge na `main` dispara
[`.github/workflows/release.yml`](.github/workflows/release.yml), que lê essa versão, cria a tag
`vX.Y.Z` e publica a release com notas geradas a partir dos PRs.

| Versão | Significado |
|---|---|
| `0.0.x` | desenvolvimento antes da primeira entrega |
| `0.1.0` | entrega da Fase 1 — criação e gerenciamento de quizzes |
| `0.2.0` | entrega da Fase 2 — sala e lobby em tempo real |
| `0.3.0` | entrega da Fase 3 — execução do quiz em tempo real |
| `1.0.0` | entrega da Fase 4 — produto completo |
| `0.1.1`, `0.2.3`, … | correções pontuais mergeadas na `main` entre fases |

**Entrega de fase = minor; qualquer outro merge na `main` = patch.** Se a versão do `mix.exs` já
tiver tag, o workflow não cria release nova — ele avisa e encerra.

Para subir a versão, edite `version:` no `mix.exs` em um PR normal para a `develop` e, depois do
merge, abra o PR de release da `develop` para a `main`.

---

## Empacotamento

O [`Dockerfile`](Dockerfile) é multi-stage e produz um **Phoenix release** (`mix release`): o
artefato final roda em uma imagem Alpine enxuta, com os assets já compilados, sem código-fonte e sem
Elixir instalado.

```bash
docker build -t live_quiz .
```

O container executa as migrations pelo módulo [`LiveQuiz.Release`](lib/live_quiz/release.ex)
(`migrate/0` e `seed/0`), e não por tarefas Mix — elas não existem dentro de um release.

Variáveis lidas em tempo de execução (`config/runtime.exs`):

| Variável | Obrigatória | Padrão |
|---|---|---|
| `DATABASE_URL` | sim | — |
| `SECRET_KEY_BASE` | sim | — |
| `PHX_HOST` | não | `example.com` |
| `PORT` | não | `4000` |
| `SMTP_HOST` / `SMTP_PORT` | não | `localhost` / `1025` |

---

## Gravar a demonstração de uma versão

Cada fase termina em uma entrega demonstrável. O script [`bin/demo`](bin/demo) levanta qualquer
versão já publicada, exatamente como ela foi entregue:

```bash
bin/demo list       # lista as versões disponíveis
bin/demo v0.1.0     # sobe a aplicação naquela versão
bin/demo stop       # encerra e libera as portas
```

O script materializa a tag em um **worktree isolado** (`.demo/<tag>/`, ignorado pelo git), constrói
a imagem daquele código e sobe app + banco + Mailpit com projeto Compose e volume próprios. **Sua
branch de trabalho e o banco de desenvolvimento não são tocados** — dá para desenvolver e demonstrar
ao mesmo tempo.

| | Endereço |
|---|---|
| Aplicação da demo | http://localhost:4000 |
| E-mails da demo | http://localhost:8025 |
| Login de demonstração | `demo@livequiz.dev` / `demo123456789` |

O primeiro `bin/demo <tag>` de cada versão leva alguns minutos para construir a imagem; o cache do
Docker resolve as execuções seguintes. Só é possível demonstrar tags a partir da primeira release,
que é quando o `Dockerfile` e o `docker-compose.demo.yml` passam a existir no código versionado.

> O `SECRET_KEY_BASE` padrão da demonstração é um valor fixo de conveniência e não deve ser
> reutilizado fora do ambiente local.

---

## Estrutura

```text
lib/live_quiz/       domínio: contextos, schemas e tarefas de release
lib/live_quiz_web/   interface: router, controllers, LiveViews e componentes
config/              configuração por ambiente (dev, test, prod, runtime)
priv/repo/           migrations e seeds
```

Regras de negócio vivem nos **contextos** (`LiveQuiz.Accounts`, `LiveQuiz.Quizzes`), nunca em
LiveView ou Controller, e nenhum acesso ao `Repo` acontece fora deles.

---

## Documentação

- [Plano das 4 fases](plataforma_quiz_4_fases.md)
- [Instruções de trabalho no repositório](AGENTS.md)
- [Stories da Fase 1](https://github.com/jessicavalcanti/live_quiz/issues/1) — o épico e suas 16 sub-issues

O refinamento de cada story vive na issue correspondente no GitHub, que é a versão definitiva:
`gh issue view <N> --repo jessicavalcanti/live_quiz`.
