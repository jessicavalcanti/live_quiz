---
name: esteira
description: Roda a skill proxima-story em looping, uma story atrás da outra, até a coluna Todo do board esvaziar. Use quando a pessoa disser "roda o backlog inteiro", "vai puxando story até acabar", "esteira", "não para na próxima, segue até o fim da fase".
---

# Esteira

Encadeia execuções da skill `proxima-story` até não haver mais story para puxar. Esta skill **não
reimplementa** nada do ciclo de story e **não implementa nenhuma story na própria sessão**: ela decide
*quando* puxar a próxima, *quando parar*, mantém o diário da corrida e — para cada story — abre um
**agente novo, sem contexto herdado**, que roda a `proxima-story` inteira e devolve só o relatório
final. As regras de cada story continuam sendo as do `.claude/skills/proxima-story/SKILL.md` e as do
`AGENTS.md`; quem as aplica é sempre o agente novo, nunca a sessão da esteira.

Isso existe porque a corrida é longa: sem isso, o contexto da sessão cresce a cada story (diffs,
saída de `mix test`, `gh pr checks --watch`...) até compactar no meio de um ciclo e perder o fio.
Rodando cada story num agente que nasce em branco, a sessão da esteira nunca acumula esse peso — ela
só orquestra.

Helpers:

- `.claude/skills/esteira/scripts/esteira.sh` (`restantes` | `iniciar` | `registrar` | `log`)
- `.claude/skills/proxima-story/scripts/board.sh` (`list` | `next` | `move`)

O diário fica em `.claude/esteira/run.md`, fora do git. Ele existe porque a corrida é longa e o
contexto pode ser compactado no meio: **é a memória da esteira**, a fonte de estado que substitui a
conversa. É o resumo que cada agente novo recebe — não a sessão que se lembra de nada.

---

## Antes de começar

```bash
./.claude/skills/esteira/scripts/esteira.sh restantes
git status --short
```

- Mostre a fila para a pessoa e diga quantas stories serão puxadas. Se forem mais de 5, confirme
  antes de começar — é muito trabalho para disparar no escuro.
- **Árvore suja → pare.** A esteira só roda a partir de um working tree limpo.
- **Não** leia `proxima-story/SKILL.md` agora, nem carregue as etapas na sua própria cabeça: quem
  vai executá-las é sempre o agente novo de cada volta, não a sessão da esteira. Este passo foi
  removido de propósito — ele era a fonte do vazamento de contexto entre stories.

```bash
./.claude/skills/esteira/scripts/esteira.sh iniciar
```

---

## O laço

A cada volta, a sessão da esteira nunca implementa nada — ela só decide, dispara um agente novo e
registra o que voltou. Não guarde a lista de issues já processadas na sua memória de conversa: releia
o diário (`esteira.sh log`) sempre que precisar checar duplicata, porque é ele que sobrevive à
compactação, não a sua lembrança da volta anterior.

1. **Tem story?**

   ```bash
   ./.claude/skills/proxima-story/scripts/board.sh next
   ```

   Falhou (`nenhuma story em Todo`) → vá para o **Encerramento**.

2. **Já vi essa issue nesta corrida?** Confira no diário (`esteira.sh log`), não de memória. Se o
   número já aparece registrado nesta corrida, algo não moveu o card para fora de Todo. **Pare** e
   relate — isso é um laço infinito começando, não um caso a contornar.

3. **Abra um agente novo para rodar a `proxima-story` inteira** para essa issue — Parte 1 (fechar o
   PR da branch atual) e Parte 2 (abrir a próxima), etapas 1 a 10, sem pular etapa e sem afrouxar
   nada. Use a ferramenta de agente **sem** o modo fork (fork herda esta conversa inteira, que é
   exatamente o que se quer evitar): o agente precisa nascer sem nenhum contexto anterior.

   O prompt para esse agente é autocontido — ele não viu nada desta conversa — e deve trazer:

   - a instrução de ler e seguir `.claude/skills/proxima-story/SKILL.md` (Parte 1 e Parte 2, etapas
     1–10) e o `AGENTS.md` do repositório, à risca;
   - o repositório (`jessicavalcanti/live_quiz`) e, se você já sabe qual é, o número da issue a
     puxar (senão ele mesmo roda `board.sh next`);
   - o **resumo do estado**, e nada além disso: a última linha do diário (`esteira.sh log`, ou o
     resultado do passo 1). Não copie diffs, logs de CI ou histórico de outras stories para o
     prompt — o agente redescobre o estado do repositório sozinho via `git`/`gh`, como a
     `proxima-story` já manda fazer;
   - o pedido de relatório final curto (PR mergeado, story escolhida, o que foi implementado,
     resultado de `mix precommit`/cobertura, link do PR novo — ou o motivo de ter parado).

   Na primeira volta é normal não haver PR aberto — a própria `proxima-story` trata isso.

   Espere o agente terminar e **não leia a transcrição bruta dele** (chamadas de ferramenta, diffs,
   saída de teste) — só o relatório final que ele devolve. Ler a transcrição reintroduz na sessão da
   esteira exatamente o peso que o agente novo existe para evitar.

4. **Registre o resultado** a partir do relatório do agente, e diga em uma linha, no chat, o que
   aconteceu:

   ```bash
   ./.claude/skills/esteira/scripts/esteira.sh registrar <M> OK "PR #<A> mergeado; PR #<B> aberto"
   ```

5. Volte ao passo 1.

---

## Quando parar

A issue repetida (passo 2) é a própria sessão da esteira quem detecta, antes de abrir qualquer
agente. As demais são o agente da volta atual quem vê — ele que está rodando a `proxima-story` e
vendo o CI, o `mergeable`, o `mix precommit`. Em qualquer um dos casos, a sessão da esteira para na
**primeira** ocorrência, sem tentar contornar e sem disparar a story seguinte:

| Situação | O que fazer |
|---|---|
| `board.sh next` não retorna nada | Encerramento normal |
| CI vermelho no PR a ser mergeado | Registre `BLOQUEADO`, traga o log do job que quebrou, pare |
| PR com conflito (`mergeable: CONFLICTING`) | Registre `BLOQUEADO`, pare |
| PR de story com base diferente de `develop` | Registre `BLOQUEADO`, pare |
| A issue conflita com o código existente | Registre `DÚVIDA`, faça a pergunta, pare |
| `mix precommit` ou `mix coveralls` não passa e você não consegue resolver dentro do escopo da story | Registre `BLOQUEADO`, pare |
| A issue voltou repetida (passo 2) | Registre `BLOQUEADO`, pare |

Toda parada anormal usa `esteira.sh registrar <M> BLOQUEADO "<motivo em uma linha>"` antes de você
falar com a pessoa. O trabalho já feito **fica como está**: não desfaça branch, não feche PR, não
mova card para trás. Diga com clareza em que ponto parou e o que falta para retomar.

---

## Encerramento

Quando a fila esvaziar, ainda sobra o PR da última story, que nenhuma iteração vai mergear. Feche-o
do mesmo jeito das outras voltas — um agente novo, sem contexto herdado, com prompt autocontido —
mas pedindo **só a Parte 1** da `proxima-story` (etapas 1 a 4: situar o PR, esperar o CI, squash
merge, mover o card para Done e voltar para a `develop` atualizada). Valem os mesmos limites: CI
vermelho ou conflito param a esteira em vez de virar merge forçado.

Depois entregue o relatório final, curto:

- quantas stories entraram e quais (número e título);
- os PRs mergeados, na ordem;
- o que ficou fora de escopo em alguma story, se ficou;
- o estado final: branch atual, board sem nada em Doing/Review, working tree limpo;
- se parou antes do fim: onde parou e por quê.

Anexe `./.claude/skills/esteira/scripts/esteira.sh log` se a corrida tiver sido longa.

---

## Limites

- A esteira **não relaxa nenhuma regra** da `proxima-story` nem do `AGENTS.md`. Rodar em série não é
  desculpa para pular teste, cobertura ou revisão de escopo.
- A sessão da esteira **nunca implementa uma story diretamente** (sem passar por um agente novo),
  mesmo que pareça mais rápido resolver uma pendência pequena ali mesmo. Se fizer isso, a story em
  questão carrega o contexto acumulado da esteira inteira — exatamente o que o agente novo por volta
  existe para evitar.
- Nunca pule uma story bloqueada para "aproveitar" a corrida. A ordem do board é a ordem.
- Nunca mergeie com CI vermelho, nem force merge, nem abra PR de story para a `main`.
- Uma story por branch, uma branch por PR — mesmo rodando dez seguidas.
- O diário `.claude/esteira/run.md` não entra em commit.
