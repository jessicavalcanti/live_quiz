---
name: proxima-story
description: Mergeia o PR aberto da branch atual na develop e implementa a próxima story do backlog até abrir o novo PR. Use quando a pessoa disser "mergeia e vai pra próxima", "próxima story", "fecha esse PR e começa o próximo item", ou pedir para continuar o backlog da fase.
---

# Próxima story

Fecha o ciclo da story atual e abre o ciclo da próxima, seguindo à risca as seções 3, 4 e 6 do
`AGENTS.md`. São duas partes: **fechar** (etapas 1–4) e **abrir** (etapas 5–10).

Helper do board: `.claude/skills/proxima-story/scripts/board.sh` (`list` | `next` | `move <issue> <coluna>`).
Ele já carrega os IDs do projeto — nunca monte a chamada do `gh project item-edit` na mão.

Repositório: `jessicavalcanti/live_quiz` · assignee: `jessicavalcanti`.

---

## Parte 1 — Fechar a story atual

### 1. Situar o PR

```bash
git branch --show-current
gh pr view --json number,title,state,baseRefName,mergeable,statusCheckRollup
```

- Se não houver PR aberto para a branch atual, **não crie um**: pule para a Parte 2 e avise que não
  havia nada para mergear.
- Se `baseRefName` não for `develop`, **pare e pergunte**. PR de story só vai para a `develop`
  (`AGENTS.md` §3).

### 2. Esperar o CI

Os checks obrigatórios são **Lint e cobertura** e **Proteção da main** (`AGENTS.md` §6).

```bash
gh pr checks --watch --fail-fast
```

- **Verde** → siga para a etapa 3.
- **Vermelho** → **pare aqui, não mergeie.** Traga o log do job que quebrou
  (`gh run view <run-id> --log-failed`), explique a causa e pergunte se deve corrigir. Corrigir o CI
  não faz parte desta skill sem pedido explícito.
- Se o PR estiver com conflito (`mergeable: CONFLICTING`), pare e relate — resolver conflito é
  decisão de quem revisa.

### 3. Mergear

Squash merge, apagando a branch remota (`AGENTS.md` §4.4.5):

```bash
gh pr merge <N> --squash --delete-branch
```

O corpo do PR contém `Closes #<N>`, então a issue fecha sozinha.

### 4. Arrumar o board e o local

```bash
./.claude/skills/proxima-story/scripts/board.sh move <N> Done
git checkout develop && git pull origin develop
git branch -d <branch-da-story>
```

---

## Parte 2 — Abrir a próxima story

### 5. Escolher a story

```bash
./.claude/skills/proxima-story/scripts/board.sh next
```

Retorna a menor issue em **Todo** com label `user-story` — o épico e os cards sem label de story
ficam de fora. Se a pessoa nomeou uma issue específica no pedido, use a dela e ignore o helper.
Se não houver nenhuma story em Todo, pare e avise que o backlog da coluna acabou.

### 6. Ler a story inteira antes de codificar

```bash
gh issue view <M> --repo jessicavalcanti/live_quiz
```

A issue é a **versão definitiva** da story (`AGENTS.md` §2): contratos técnicos, regras de negócio,
critérios de aceite e os cenários de teste obrigatórios vivem só lá. Leia também o card do épico
(`gh issue view 1`) quando a story depender de convenção global.

> Se algo na issue conflitar com o código existente, **pare e pergunte**. Não invente contrato.

### 7. Assumir e preparar a branch

```bash
gh issue edit <M> --repo jessicavalcanti/live_quiz --add-assignee jessicavalcanti
./.claude/skills/proxima-story/scripts/board.sh move <M> Doing
git checkout develop && git pull origin develop
git checkout -b <tipo>/<M>-<slug>
```

O prefixo vem da natureza da story, não do gosto: `feature/`, `fix/`, `chore/`, `docs/`,
`refactor/` (`AGENTS.md` §3). O slug é curto, em inglês e com hífens.

### 8. Implementar

Regras que não se negociam (`AGENTS.md` §4.2 e §8):

- Só o que está no escopo **"Dentro"** da story. O que está em "Fora" é de outra issue.
- Regra de negócio mora no **contexto** — nunca em LiveView nem em Controller.
- Nenhum acesso a `Repo` fora dos contextos.
- Toda função pública de contexto recebe `scope` e filtra por dono **na query**; não-dono recebe 404.
- Validação no changeset **e** constraint no banco.
- Código, módulos, tabelas e commits em **inglês**; UI e mensagens em **pt-BR** (Gettext `pt_BR`).
- Os **cenários de teste da issue são obrigatórios** — escreva todos, não uma amostra.

Antes de qualquer push:

```bash
mix precommit    # compile --warnings-as-errors + deps.unlock --unused + format + credo --strict + test
mix coveralls    # cobertura mínima de 80%
```

Se o banco local não subir, lembre que as portas 5432 e 4000 podem estar ocupadas por outro projeto —
use `DB_PORT`/`PORT` ou `docker compose up -d`.

### 9. Commitar e abrir o PR

Conventional Commits em inglês (`AGENTS.md` §3):

```bash
git commit -m "feat(quizzes): add quiz context with owner scoping" -m "Refs #<M>"
git push -u origin <tipo>/<M>-<slug>

gh pr create --base develop \
  --title "feat(quizzes): <resumo no padrão conventional commits>" \
  --body "Closes #<M>

## O que foi feito
- ...

## Como validar
- ...

## Checklist
- [ ] Critérios de aceite da issue atendidos
- [ ] Cenários de teste da issue implementados
- [ ] \`mix precommit\` passa localmente
- [ ] Cobertura acima de 80%"
```

O corpo **precisa** conter `Closes #<M>`. Preencha "O que foi feito" e "Como validar" com o que
realmente foi feito — nada de placeholder. Marque no checklist só o que você de fato verificou.

### 10. Fechar o ciclo

```bash
./.claude/skills/proxima-story/scripts/board.sh move <M> Review
```

Depois relate, em poucas linhas: qual PR foi mergeado, qual story foi escolhida e por quê, o que foi
implementado, o resultado do `mix precommit` e da cobertura, e o link do PR novo. Se algo do escopo
ficou de fora, diga explicitamente o quê e por quê.

---

## Limites

- **Nunca** mergeie com CI vermelho, nem force merge para contornar check.
- **Nunca** abra PR de feature para a `main` (`AGENTS.md` §3) — há check de CI que reprova.
- **Nunca** mexa em issue ou card que não seja o da story atual ou o da próxima.
- Uma story por branch, uma branch por PR.
