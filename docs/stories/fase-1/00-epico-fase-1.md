# [ÉPICO] Fase 1 — Criação e gerenciamento de quizzes

> **Labels:** `epic`, `fase-1`
> **Documento de origem:** `plataforma_quiz_4_fases.md` (seção 3)
> **Stories:** 16 · **Total estimado:** 72 pontos

---

## 1. Contexto de negócio

A plataforma será um sistema de quizzes em tempo real inspirado no Kahoot, entregue em 4 fases.
A **Fase 1** entrega o primeiro contexto de negócio: **o gerenciamento de conteúdo**.

Ao final desta fase, uma pessoa autenticada consegue criar, editar, ordenar e excluir quizzes
completos (com perguntas e alternativas) pela interface web, sem nenhuma intervenção manual no
banco de dados. Ainda **não existe multiplayer**: sala, participantes, execução e ranking são
escopo das fases 2, 3 e 4.

A autenticação **não é uma funcionalidade de negócio desta sprint** — é o core técnico que
sustenta todas as fases seguintes, e por isso aparece aqui como *habilitador técnico*.

## 2. Objetivo mensurável

Um usuário recém-cadastrado consegue, em uma única sessão:

1. criar uma conta e autenticar-se;
2. criar um quiz com título e descrição;
3. adicionar até 50 perguntas, cada uma com 4 alternativas e exatamente 1 correta;
4. editar, reordenar e excluir perguntas;
5. editar e excluir o quiz;
6. visualizar seus quizzes em um dashboard paginado e pesquisável;
7. executar as mesmas operações via API JSON autenticada por JWT.

---

## 3. Stack e convenções globais

Estas convenções valem para **todas** as stories desta fase e não são repetidas em cada uma.

| Item | Definição |
|---|---|
| Linguagem | Elixir 1.20+ / Erlang OTP 29 |
| Framework | Phoenix 1.8 + Phoenix LiveView 1.x |
| Banco | PostgreSQL 16 (via Docker Compose) |
| App OTP | `live_quiz` |
| Módulo raiz | `LiveQuiz` (domínio) e `LiveQuizWeb` (interface) |
| Repo | `LiveQuiz.Repo` |
| Estilo | Tailwind + daisyUI + `core_components.ex` gerados pelo Phoenix 1.8 |
| Idioma | UI, mensagens e issues em **pt-BR**; código, tabelas, colunas, rotas e commits em **inglês** |
| Locale | Gettext com `default_locale: "pt_BR"`; mensagens de erro do Ecto traduzidas em `priv/gettext/pt_BR/LC_MESSAGES/errors.po` (story F1-05) |
| Datas | Persistidas em UTC (`:utc_datetime`); exibidas na web convertidas para `America/Sao_Paulo` (dependência `tzdata`); a API sempre responde em ISO 8601 UTC |
| Contextos | `LiveQuiz.Accounts` (auth) e `LiveQuiz.Quizzes` (quiz, perguntas, alternativas) |

> **Decisão de nomenclatura:** o documento de origem chama o contexto de `Quiz`. Adotamos o plural
> `LiveQuiz.Quizzes` para seguir a convenção do Phoenix e evitar `LiveQuiz.Quiz.Quiz`.
> O schema continua sendo `LiveQuiz.Quizzes.Quiz`.

### Escopo de autorização (`scope`)

O `mix phx.gen.auth` do Phoenix 1.8 gera `LiveQuiz.Accounts.Scope`, disponível nas LiveViews e
controllers como `@current_scope` / `conn.assigns.current_scope`, onde `scope.user` é o `%User{}`
autenticado.

**Toda função pública de `LiveQuiz.Quizzes` que lê ou escreve dados recebe `scope` como primeiro
argumento** e filtra por `owner_id == scope.user.id` já na query. Nunca busque primeiro e valide
depois.

### Fluxo de trabalho

O projeto segue **git flow**. O procedimento completo está em [`AGENTS.md`](../../../AGENTS.md) —
leia antes de começar qualquer story.

- `main` = produção, protegida, recebe **apenas** PR vindo da `develop`.
- `develop` = branch de integração e default do repositório; todo PR de story aponta para ela.
- Uma branch por story, criada **a partir da `develop`**: `feature/<numero-da-issue>-<slug>`
  (ou `fix/`, `chore/`, `docs/`, `refactor/`).
- Commits em inglês seguindo **Conventional Commits** (`feat(quizzes): add quiz context`).
- Um PR por story, com `Closes #<N>` no corpo, CI verde e squash merge.
- Movimentação do card no board (`Todo → Doing → Review → Done`) sempre acompanhada de assignee.

### Definition of Done global

Além da DoD específica de cada story:

- [ ] `mix precommit` passa localmente (compile com `--warnings-as-errors`, format, credo, test);
- [ ] cobertura de testes **acima de 80%** (`mix coveralls`);
- [ ] CI verde no PR aberto contra a `develop`;
- [ ] card movido para `Review` e issue atribuída ao responsável;
- [ ] sem warnings de compilação;
- [ ] textos de UI em pt-BR;
- [ ] nenhuma regra de negócio implementada dentro de LiveView ou Controller — sempre no contexto;
- [ ] nenhum acesso a `Repo` fora dos contextos.

---

## 4. Decisões de arquitetura desta fase

| # | Decisão | Motivo |
|---|---|---|
| AD-01 | Domínio isolado da interface: `LiveView → Context → Changeset → Repo` e `Controller → Context → Changeset → Repo` | LiveView e API JSON compartilham 100% das regras (exigência do documento, seção 9.1) |
| AD-02 | Autenticação por e-mail + senha via `phx.gen.auth`, **sem** magic link | O documento exige recuperação e redefinição de senha; magic link dobraria telas e testes |
| AD-03 | Confirmação de e-mail **não bloqueante** | Reduz atrito na demo da fase 1 sem perder a validação do e-mail |
| AD-04 | Autorização apenas por *ownership*; sem papéis | Único requisito real da fase; evita autorização especulativa |
| AD-05 | Pergunta com **exatamente 4 alternativas** criadas junto com ela (A–D) | Elimina o CRUD de alternativas, mantém a pergunta sempre em estado válido e simplifica as fases 3 e 4 |
| AD-06 | Exatamente **1 alternativa correta**, garantida por índice único parcial no banco | "Banco como última camada de integridade" (documento, seção 9.3) |
| AD-07 | `position` inteiro sequencial `1..n`, único por pai, com constraint `DEFERRABLE INITIALLY DEFERRED` | Permite trocar posições dentro de uma transação sem violar a unicidade |
| AD-08 | Hard delete com `ON DELETE CASCADE` | Sem órfãos e sem filtro de `deleted_at` contaminando todas as queries |
| AD-09 | Sem coluna de status no quiz; `playable?/1` derivado | Evita máquina de estados antes da fase 2 definir a regra da sala |
| AD-10 | Não-dono recebe **404**, nunca 403 | Não vaza a existência de recursos de terceiros |
| AD-11 | Quiz pode existir vazio; a **pergunta** é a unidade transacional | Fluxo natural de editor sem persistir pergunta incompleta |
| AD-12 | API em `/api/v1` com envelope `data`/`errors` e autenticação **JWT via Guardian** (access 15min + refresh 30 dias, sem `Guardian.DB`) | Viabiliza o app mobile citado no documento sem sessão por cookie |
| AD-13 | Documentação da API com `open_api_spex` + Swagger UI | Contrato explícito e versionado para o cliente mobile futuro |
| AD-19 | Versão declarada no `mix.exs`; merge na `main` gera tag e release automaticamente. Entrega de fase = minor (`0.1.0`, `0.2.0`, `0.3.0`, `1.0.0`); demais merges = patch | Toda entrega vira um artefato reproduzível e identificável, e a release de fase é reconhecível por terminar em `.0` |
| AD-20 | Release empacotado com `mix release` em imagem Docker, levantável por versão com `bin/demo <tag>` em worktree isolado | Permite gravar a demonstração de uma fase meses depois, sem tocar na branch de trabalho nem no banco de desenvolvimento |
| AD-17 | Git flow com `main` protegida e `develop` como branch de integração e default; PR obrigatório e Conventional Commits | Histórico legível, `main` sempre estável e nenhum PR mirando produção por engano |
| AD-18 | CI reprova cobertura de testes abaixo de 80% (`excoveralls`) | Garante que os cenários de teste obrigatórios de cada story sejam de fato escritos |
| AD-15 | Toda função de leitura de quiz retorna o campo virtual `questions_count` preenchido; `playable?/1` apenas o interpreta | Contrato único para UI e API, sem query adicional por linha do dashboard |
| AD-16 | Cascata de exclusão declarada **somente** no banco (`ON DELETE CASCADE`); as associações Ecto não usam `on_delete:` | Evita que o Ecto emita deletes redundantes a partir da aplicação |
| AD-14 | Sem `time_limit_seconds`, sem pontuação, sem status de publicação, sem duplicação de quiz, sem visibilidade pública | Escopo das fases 3 e 4; migrations futuras são baratas |

---

## 5. Modelo de dados da fase

```text
users (phx.gen.auth + name)
  1 ── N quizzes (owner_id)
          1 ── N questions (quiz_id, position 1..n)
                  1 ── 4 answer_options (question_id, position 1..4, is_correct)
```

Regras garantidas no banco:

- FKs com `on_delete: :delete_all` em toda a cadeia;
- `NOT NULL` em todos os campos obrigatórios;
- `unique (quiz_id, position)` e `unique (question_id, position)`, ambos `DEFERRABLE INITIALLY DEFERRED`;
- `unique (question_id) WHERE is_correct` — no máximo uma correta por pergunta;
- check constraints de tamanho de texto e de faixa de `position`.

---

## 6. Escopo

### Dentro

- Bootstrap do projeto, Docker Compose (Postgres + Mailpit), seeds e CI.
- Autenticação completa: cadastro, login, logout, confirmação de e-mail, recuperação e redefinição de senha.
- Landing pública, layout autenticado e proteção de rotas.
- Contexto `Quizzes` completo: quiz, perguntas, alternativas, reordenação e exclusão.
- Dashboard paginado com busca e contagem de perguntas.
- Editor de quiz em LiveView com perguntas em modal.
- API JSON `/api/v1` com JWT, paginação e OpenAPI.
- Testes de contexto, de LiveView e de API.

### Fora (não implementar nesta fase)

- Sala, código de acesso, participantes, lobby, execução, timer, respostas, pontuação, ranking, histórico (fases 2–4).
- Papéis/admin, colaboração em quiz, quiz público, duplicação de quiz.
- Tempo por pergunta e peso/pontos por pergunta.
- Upload de imagem em pergunta ou alternativa.
- Rate limiting, suporte a múltiplos idiomas (o projeto é monolíngue pt-BR), provedor real de e-mail em produção.

---

## 7. Stories

| # | Story | Tipo | Depende de | Pts |
|---|---|---|---|---|
| 01 | Bootstrap do projeto Phoenix, ambiente de desenvolvimento e empacotamento de release | infra | — | 8 |
| 02 | Pipeline de CI e alias `mix precommit` | infra | 01 | 2 |
| 03 | Autenticação: cadastro, login, logout, confirmação e redefinição de senha | habilitador | 01 | 8 |
| 04 | Landing pública, layout autenticado e proteção de rotas | habilitador | 03 | 3 |
| 05 | Migrations, schemas e seeds do domínio de quizzes | backend | 03 | 5 |
| 06 | Contexto `Quizzes`: CRUD de quiz com escopo por dono | backend | 05 | 3 |
| 07 | Contexto `Quizzes`: criar e editar pergunta com 4 alternativas | backend | 06 | 5 |
| 08 | Contexto `Quizzes`: excluir e reordenar perguntas | backend | 07 | 3 |
| 09 | Dashboard "Meus quizzes" com paginação, busca e contagem | frontend | 04, 06 | 5 |
| 10 | Criar, editar e excluir quiz pela interface | frontend | 09 | 5 |
| 11 | Editor de quiz: adicionar e editar perguntas em modal | frontend | 07, 10 | 8 |
| 12 | Editor de quiz: reordenar e excluir perguntas | frontend | 08, 11 | 3 |
| 13 | Autenticação JWT da API com Guardian | api | 03 | 5 |
| 14 | API v1: CRUD de quizzes com paginação e busca | api | 06, 13 | 3 |
| 15 | API v1: perguntas e alternativas | api | 07, 08, 13 | 3 |
| 16 | Documentação OpenAPI e Swagger UI | api | 14, 15 | 3 |

Ordem sugerida de execução: **01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12 → 13 → 14 → 15 → 16**.
As trilhas `frontend` (09–12) e `api` (13–16) podem correr em paralelo depois da story 08.

---

## 8. Entrega da fase

A fase 1 é entregue quando a `develop` for mergeada na `main` com `version: "0.1.0"` no `mix.exs`,
gerando automaticamente a tag `v0.1.0` e a release **"v0.1.0 — Fase 1: Criação e gerenciamento de
quizzes"**. A demonstração é gravada a partir de `bin/demo v0.1.0`.

---

## 9. Critério de conclusão do épico

- [ ] autenticação funcionando (cadastro, login, logout, reset de senha);
- [ ] usuário cria quiz;
- [ ] usuário adiciona perguntas;
- [ ] usuário define a alternativa correta;
- [ ] dados persistidos com integridade garantida no banco;
- [ ] usuário edita quiz e perguntas;
- [ ] usuário reordena perguntas;
- [ ] usuário exclui quiz e perguntas;
- [ ] API v1 disponível e documentada;
- [ ] testes de backend e de frontend existem e passam no CI;
- [ ] nenhuma operação da fase exige intervenção manual no banco;
- [ ] release `v0.1.0` publicada e `bin/demo v0.1.0` sobe a aplicação entregue.
