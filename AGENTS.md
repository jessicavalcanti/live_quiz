# AGENTS.md — Live Quiz

Instruções operacionais para qualquer pessoa ou agente que for trabalhar neste repositório.
Leia este arquivo **antes** de escrever qualquer linha de código.

---

## 1. O que é este projeto

Plataforma de quiz em tempo real (inspirada no Kahoot) construída com **Elixir + Phoenix + Phoenix
LiveView + PostgreSQL**, com uma **API JSON** paralela para consumo futuro por app mobile.

O projeto é entregue em **4 fases**, cada uma equivalente a uma sprint com funcionalidade de negócio
completa. O plano completo está em [`plataforma_quiz_4_fases.md`](plataforma_quiz_4_fases.md).

| Fase | Entrega |
|---|---|
| 1 | Criação e gerenciamento de quizzes (**em andamento**) |
| 2 | Sala de quiz e lobby em tempo real |
| 3 | Execução do quiz em tempo real |
| 4 | Pontuação, ranking e histórico |

---

## 2. Onde fica o trabalho

| Recurso | Local |
|---|---|
| **Board (GitHub Project)** | https://github.com/users/jessicavalcanti/projects/3 — *Live Quiz — Roadmap* |
| **Issues** | https://github.com/jessicavalcanti/live_quiz/issues |
| **Épico da fase 1** | [issue #1](https://github.com/jessicavalcanti/live_quiz/issues/1) — as 16 stories são sub-issues dele |
| **Stories em markdown** | [`docs/stories/fase-1/`](docs/stories/fase-1/) — mesmo conteúdo das issues, versionado |
| **Convenções globais da fase** | card de épico (stack, nomenclatura, `scope`, DoD global) |

### Estrutura do board

O board tem **4 colunas** (campo `Status`):

```text
Todo  →  Doing  →  Review  →  Done
```

| Coluna | Significado |
|---|---|
| **Todo** | Story refinada e pronta para desenvolvimento |
| **Doing** | Alguém está desenvolvendo, já existe branch |
| **Review** | PR aberto, aguardando revisão |
| **Done** | PR mergeado na `develop` |

Campos adicionais do board: **Fase** (single select), **Pontos** (estimativa em story points) e
**Sub-issues progress** (barra de progresso do épico).

### Visualizações

| View | Layout | Filtro |
|---|---|---|
| Todos os itens | Tabela | — |
| Fase 1 — Quizzes | Board | `label:fase-1` |
| Fase 2 — Sala | Board | `label:fase-2` |
| Fase 3 — Jogo | Board | `label:fase-3` |
| Fase 4 — Ranking | Board | `label:fase-4` |

### Labels

| Grupo | Labels |
|---|---|
| Tipo | `epic`, `user-story` |
| Fase | `fase-1`, `fase-2`, `fase-3`, `fase-4` |
| Camada | `backend`, `frontend`, `api`, `infra`, `documentacao`, `habilitador-tecnico` |

Toda issue nova deve receber **tipo + fase + camada**. É a label de fase que faz o card aparecer na
view correta do board.

---

## 3. Git flow

```text
main ─────────────●────────────────●──────────  produção, protegida
                  ▲                ▲
                  │ PR de release  │
develop ──●───●───●────●───●───●───●──────────  integração
          ▲   ▲        ▲   ▲   ▲
          │   │        │   │   │  PR de story
    feature/… feature/… chore/… fix/…
```

- **`main`** — branch principal/produção. **Nunca** receba commit direto e **nunca** abra PR de uma
  feature para ela. A única origem aceita é a `develop` (há um check de CI que reprova o contrário).
- **`develop`** — branch de integração e **branch default do repositório**. Todo PR de story aponta
  para cá.
- **Branches de trabalho** — sempre criadas **a partir da `develop`**, nunca da `main`.

### Nomenclatura de branch

```text
feature/<numero-da-issue>-<slug>    nova funcionalidade
fix/<numero-da-issue>-<slug>        correção de bug
chore/<numero-da-issue>-<slug>      infraestrutura, build, dependências
docs/<numero-da-issue>-<slug>       documentação
refactor/<numero-da-issue>-<slug>   refatoração sem mudança de comportamento
```

Exemplo: `feature/7-contexto-quiz-crud` para a issue #7.

### Conventional Commits

Todo commit segue [Conventional Commits](https://www.conventionalcommits.org/pt-br/):

```text
<tipo>(<escopo opcional>): <descrição no imperativo, minúscula, sem ponto final>

[corpo opcional explicando o porquê]

[rodapé opcional: Refs #7]
```

Tipos aceitos: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `build`, `ci`, `style`.

```text
feat(quizzes): add quiz context with owner scoping
fix(editor): keep question order after deletion
test(quizzes): cover answer option set validations
chore(ci): raise coverage threshold to 80%
docs(stories): fix playable? contract in F1-06
```

Escreva o commit em **inglês** (código e commits em inglês; UI e issues em pt-BR).

---

## 4. Procedimento padrão para atuar em uma story

Siga **todos** os passos, na ordem. `<N>` é o número da issue.

### 4.1 Antes de começar

```bash
# 1. Mover o card para Doing e assumir a issue
gh issue edit <N> --repo jessicavalcanti/live_quiz --add-assignee jessicavalcanti
# mover no board: ver o comando pronto em "Comandos úteis" abaixo

# 2. Partir sempre da develop atualizada
git checkout develop
git pull origin develop

# 3. Criar a branch da story
git checkout -b feature/<N>-<slug>
```

Leia a issue inteira antes de codificar: ela contém contratos técnicos (assinaturas de função,
rotas, payloads), regras de negócio, critérios de aceite e os cenários de teste obrigatórios.
Se algo na issue conflitar com o código existente, **pare e pergunte** — não invente contrato.

### 4.2 Durante

- Implemente apenas o que está no escopo "Dentro" da story; o que está em "Fora" é de outra issue.
- Regras de negócio vivem nos **contextos**, nunca em LiveView ou Controller.
- Nenhum acesso a `Repo` fora dos contextos.
- Escreva os testes listados na seção "Cenários de teste" da issue — eles são obrigatórios, não sugestão.
- Rode `mix precommit` antes de cada push (formatação, credo, compile sem warnings, testes).

### 4.3 Ao finalizar

```bash
# 1. Push da branch
git push -u origin feature/<N>-<slug>

# 2. Abrir o PR para a develop, associando a issue
gh pr create --base develop \
  --title "feat(quizzes): <resumo no padrão conventional commits>" \
  --body "Closes #<N>

## O que foi feito
- ...

## Como validar
- ...

## Checklist
- [ ] Critérios de aceite da issue atendidos
- [ ] Cenários de teste da issue implementados
- [ ] \`mix precommit\` passa localmente
- [ ] Cobertura acima de 80%"

# 3. Mover o card para Review
```

O corpo do PR **deve** conter `Closes #<N>` para fechar a issue automaticamente no merge.

### 4.4 Regras que valem sempre

1. **Toda movimentação de card no board vem acompanhada de assignee.** Ao mover para `Doing` ou
   `Review`, a issue precisa estar atribuída a `jessicavalcanti`.
2. Uma story por branch, uma branch por PR.
3. PR só vai para `develop`. `main` recebe apenas PR vindo da `develop`.
4. CI verde é pré-requisito de merge — inclui lint e cobertura mínima de 80%.
5. Após o merge, o card vai para `Done` e a branch remota é apagada.

---

## 5. Releases e demonstrações

### Versionamento

A versão é declarada **apenas** em `mix.exs`. Todo merge na `main` dispara
[`.github/workflows/release.yml`](.github/workflows/release.yml), que lê essa versão, cria a tag
`vX.Y.Z` e publica a release com notas geradas a partir dos PRs.

| Versão | Significado |
|---|---|
| `0.0.x` | desenvolvimento antes da primeira entrega |
| `0.1.0` | **entrega da Fase 1** — criação e gerenciamento de quizzes |
| `0.2.0` | **entrega da Fase 2** — sala e lobby em tempo real |
| `0.3.0` | **entrega da Fase 3** — execução do quiz em tempo real |
| `1.0.0` | **entrega da Fase 4** — produto completo |
| `0.1.1`, `0.2.3`, … | correções pontuais mergeadas na `main` entre fases |

Regra: **entrega de fase = minor; qualquer outro merge na `main` = patch.**
Se a versão do `mix.exs` já tiver tag, o workflow não cria release nova — ele avisa e encerra.

### Procedimento de release

```bash
# 1. Subir a versão na develop, via PR normal
git checkout develop && git pull origin develop
git checkout -b chore/bump-0.1.0
# editar mix.exs: version: "0.1.0"
git commit -am "chore(release): bump version to 0.1.0"
gh pr create --base develop --title "chore(release): bump version to 0.1.0"

# 2. Depois do merge, abrir o PR de release para a main
gh pr create --base main --head develop \
  --title "release: v0.1.0 — Fase 1" \
  --body "Entrega da Fase 1. Fecha o épico #1."

# 3. Ao mergear, a tag v0.1.0 e a release são criadas automaticamente
```

> O PR para a `main` **só é aceito a partir da `develop`** — há um job de CI que reprova qualquer
> outra origem.

### Gravar a demonstração de uma versão

```bash
bin/demo list       # lista as versões disponíveis
bin/demo v0.1.0     # sobe a aplicação exatamente naquela versão
bin/demo stop       # encerra
```

O script materializa a tag em um worktree isolado (`.demo/<tag>/`), constrói a imagem daquele código
e sobe app + banco + Mailpit com volume próprio. **Sua branch de trabalho e o banco de
desenvolvimento não são tocados** — dá para desenvolver e demonstrar ao mesmo tempo.

| | Endereço |
|---|---|
| Aplicação da demo | http://localhost:4000 |
| E-mails da demo | http://localhost:8025 |
| Login de demonstração | `demo@livequiz.dev` / `demo123456789` |

> `bin/demo`, o `Dockerfile` e o `docker-compose.demo.yml` são entregues pela story F1-01; só há
> versões demonstráveis a partir da primeira release.

---

## 6. Qualidade e CI

O workflow [`.github/workflows/ci.yml`](.github/workflows/ci.yml) roda em todo push e PR para
`main` e `develop`:

| Etapa | Comando |
|---|---|
| Formatação | `mix format --check-formatted` |
| Compilação sem warnings | `mix compile --warnings-as-errors` |
| Análise estática | `mix credo --strict` |
| Testes + cobertura | `mix coveralls` (mínimo **80%**) |
| Proteção da main | reprova PR para `main` que não venha da `develop` |

> Enquanto a aplicação Phoenix não existir (story F1-01), o job detecta a ausência de `mix.exs` e
> passa sem executar as etapas — mantendo o check verde sem mascarar falhas reais depois.

Localmente, o equivalente é:

```bash
mix precommit   # compile --warnings-as-errors + format + credo --strict + test
mix coveralls   # cobertura
```

---

## 7. Ambiente de desenvolvimento

```bash
docker compose up -d    # PostgreSQL 16 + Mailpit
mix setup               # deps, banco, migrations, assets
mix phx.server          # http://localhost:4000
```

| Serviço | Endereço |
|---|---|
| Aplicação | http://localhost:4000 |
| Mailpit (e-mails de dev) | http://localhost:8025 |
| Swagger UI da API | http://localhost:4000/api/docs |
| PostgreSQL | `localhost:5432` (`postgres` / `postgres`) |

---

## 8. Convenções de código

| Item | Convenção |
|---|---|
| Idioma do código | inglês (módulos, funções, tabelas, colunas, rotas, commits) |
| Idioma da UI e das issues | pt-BR |
| Locale | Gettext `pt_BR`; mensagens de erro do Ecto traduzidas em `errors.po` |
| Datas | persistidas em UTC; exibidas na web em `America/Sao_Paulo`; API sempre em ISO 8601 UTC |
| Contextos | `LiveQuiz.Accounts` (autenticação) e `LiveQuiz.Quizzes` (quiz, perguntas, alternativas) |
| Autorização | toda função pública de contexto recebe `scope` e filtra por dono **na query**; não-dono recebe 404 |
| Arquitetura | `LiveView → Context → Changeset → Repo` e `Controller → Context → Changeset → Repo` |
| Integridade | validação no changeset **e** constraint no banco |

---

## 9. Comandos úteis

```bash
# Listar as stories prontas para desenvolvimento
gh issue list --repo jessicavalcanti/live_quiz --label user-story --state open

# Ler uma story inteira
gh issue view <N> --repo jessicavalcanti/live_quiz

# Assumir uma issue
gh issue edit <N> --repo jessicavalcanti/live_quiz --add-assignee jessicavalcanti

# Mover um card de coluna no board (IDs fixos do projeto)
#   PROJECT=PVT_kwHOBXKAR84Bh1Hz   STATUS_FIELD=PVTSSF_lAHOBXKAR84Bh1HzzhgvZgA
#   Todo=5eda1465  Doing=21d718c9  Review=a0a24ae0  Done=8de548a3
ITEM=$(gh project item-list 3 --owner jessicavalcanti --format json \
  | python3 -c "import json,sys;print([i['id'] for i in json.load(sys.stdin)['items'] if i['content']['number']==<N>][0])")
gh project item-edit --id "$ITEM" \
  --project-id PVT_kwHOBXKAR84Bh1Hz \
  --field-id PVTSSF_lAHOBXKAR84Bh1HzzhgvZgA \
  --single-select-option-id 21d718c9      # Doing

# Ver o progresso do épico
gh issue view 1 --repo jessicavalcanti/live_quiz
```
