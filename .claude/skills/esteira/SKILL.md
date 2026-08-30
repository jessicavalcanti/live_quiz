---
name: esteira
description: Roda a skill proxima-story em looping, uma story atrás da outra, até a coluna Todo do board esvaziar. Use quando a pessoa disser "roda o backlog inteiro", "vai puxando story até acabar", "esteira", "não para na próxima, segue até o fim da fase".
---

# Esteira

Encadeia execuções da skill `proxima-story` até não haver mais story para puxar. Esta skill **não
reimplementa** nada do ciclo de story: ela decide *quando* rodar a `proxima-story`, *quando parar* e
mantém o diário da corrida. As regras de cada story continuam sendo as do
`.claude/skills/proxima-story/SKILL.md` e as do `AGENTS.md`.

Helpers:

- `.claude/skills/esteira/scripts/esteira.sh` (`restantes` | `iniciar` | `registrar` | `log`)
- `.claude/skills/proxima-story/scripts/board.sh` (`list` | `next` | `move`)

O diário fica em `.claude/esteira/run.md`, fora do git. Ele existe porque a corrida é longa e o
contexto pode ser compactado no meio: **é a memória da esteira**, não um enfeite.

---

## Antes de começar

```bash
./.claude/skills/esteira/scripts/esteira.sh restantes
git status --short
```

- Mostre a fila para a pessoa e diga quantas stories serão puxadas. Se forem mais de 5, confirme
  antes de começar — é muito trabalho para disparar no escuro.
- **Árvore suja → pare.** A esteira só roda a partir de um working tree limpo.
- Carregue as instruções da story uma única vez, agora, invocando a skill `proxima-story`. Você vai
  segui-las em toda iteração sem recarregar.

```bash
./.claude/skills/esteira/scripts/esteira.sh iniciar
```

---

## O laço

Mantenha uma lista das issues já processadas nesta corrida. A cada volta:

1. **Tem story?**

   ```bash
   ./.claude/skills/proxima-story/scripts/board.sh next
   ```

   Falhou (`nenhuma story em Todo`) → vá para o **Encerramento**.

2. **Já vi essa issue nesta corrida?** Se o número voltar repetido, algo não moveu o card para fora
   de Todo. **Pare** e relate — isso é um laço infinito começando, não um caso a contornar.

3. **Rode a `proxima-story` inteira** para essa issue: Parte 1 (fechar o PR da branch atual) e
   Parte 2 (abrir a próxima), etapas 1 a 10, sem pular etapa e sem afrouxar nada. Na primeira volta é
   normal não haver PR aberto — a própria skill trata isso.

   Se você não tiver mais as etapas em mente (o contexto foi compactado), releia
   `.claude/skills/proxima-story/SKILL.md` antes de seguir.

4. **Registre o resultado** e diga em uma linha, no chat, o que aconteceu:

   ```bash
   ./.claude/skills/esteira/scripts/esteira.sh registrar <M> OK "PR #<A> mergeado; PR #<B> aberto"
   ```

5. Volte ao passo 1.

---

## Quando parar

A esteira para na **primeira** ocorrência de qualquer uma destas, sem tentar contornar e sem pular
para a story seguinte:

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
rodando **só a Parte 1** da `proxima-story` (etapas 1 a 4: situar o PR, esperar o CI, squash merge,
mover o card para Done e voltar para a `develop` atualizada). Valem os mesmos limites: CI vermelho ou
conflito param a esteira em vez de virar merge forçado.

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
- Nunca pule uma story bloqueada para "aproveitar" a corrida. A ordem do board é a ordem.
- Nunca mergeie com CI vermelho, nem force merge, nem abra PR de story para a `main`.
- Uma story por branch, uma branch por PR — mesmo rodando dez seguidas.
- O diário `.claude/esteira/run.md` não entra em commit.
