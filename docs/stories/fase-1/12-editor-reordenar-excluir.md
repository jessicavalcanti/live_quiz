# [F1-12] Editor de quiz: reordenar e excluir perguntas

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `frontend`
> **Branch:** `feature/12-editor-reordenar-excluir` · **Estimativa:** 3 pontos · **Depende de:** F1-08, F1-11

## 1. Contexto de negócio

Depois de escrever as perguntas, o autor precisa ajustar o roteiro: subir uma pergunta de aquecimento
para o início, descer a mais difícil para o fim, remover a que ficou fora de contexto. Esta story
entrega o controle final sobre a estrutura do quiz e fecha o critério de conclusão da fase 1.

## 2. User story

**Como** usuário autenticado dono de um quiz,
**quero** mudar a ordem das perguntas e excluir as que não quero mais,
**para que** o quiz fique exatamente na sequência que planejei.

## 3. Escopo

### Dentro
- Botões ↑ e ↓ em cada pergunta da lista do editor.
- Botão de excluir pergunta com modal de confirmação.
- Renumeração visível imediatamente após cada operação.
- Desabilitar ↑ na primeira pergunta e ↓ na última.
- Mensagens de flash de sucesso.

### Fora
- Arrastar e soltar, mover para posição arbitrária, desfazer exclusão, exclusão em lote.

## 4. Decisões de arquitetura

- **Botões ↑/↓ em vez de drag and drop** (decisão E2 do refinamento): sem dependência de JavaScript,
  acessível por teclado e testável com `LiveViewTest`. Arrastar e soltar fica como melhoria futura.
- **Servidor como autoridade da ordem**: cada clique chama `Quizzes.move_question/3` e a lista é
  recarregada do banco; a LiveView nunca reordena a lista em memória.
- **Modal de confirmação para excluir pergunta**, coerente com a exclusão de quiz (F1-10), já que a
  operação é irreversível e remove as 4 alternativas.
- **Botões de borda desabilitados** em vez de ocultos: a posição dos controles não muda entre as
  linhas, o que evita erro de clique.

## 5. Modelo de dados e migrations

Nenhuma. Consome `move_question/3` e `delete_question/2` (story F1-08).

## 6. Contratos técnicos

### `LiveQuizWeb.QuizLive.Editor` (evolução da F1-11)

Eventos adicionais:

| Evento | Parâmetros | Efeito |
|---|---|---|
| `"move_question_up"` | `phx-value-id` | carrega a pergunta com `Quizzes.get_question!(scope, quiz, id)` e chama `Quizzes.move_question(scope, question, :up)`; recarrega o quiz |
| `"move_question_down"` | `phx-value-id` | carrega a pergunta com `Quizzes.get_question!(scope, quiz, id)` e chama `Quizzes.move_question(scope, question, :down)`; recarrega o quiz |
| `"delete_question"` | `phx-value-id` | carrega a pergunta com `Quizzes.get_question!(scope, quiz, id)`, atribui `:question_to_delete` e abre o modal de confirmação |
| `"confirm_delete_question"` | — | `Quizzes.delete_question/2`; flash "Pergunta excluída"; recarrega o quiz |
| `"cancel_delete_question"` | — | fecha o modal |

Após qualquer operação, recarregar com `Quizzes.get_quiz_with_questions!/2`.

> `move_question/3` retorna `{:ok, %Question{}}` ou `{:ok, :unchanged}` (movimento na borda). A
> LiveView trata as duas formas da mesma maneira: recarrega o quiz e não exibe mensagem de erro.
> Como as funções de contexto recebem a **struct** da pergunta e o evento traz apenas o id, o
> carregamento com `get_question!/3` é obrigatório e é também o que garante a autorização (404).

### Controles por linha da lista

```text
[1]  Qual é a capital do Brasil?          ✓ Brasília      [↑] [↓] [Editar] [Excluir]
[2]  Qual é o maior planeta?              ✓ Júpiter       [↑] [↓] [Editar] [Excluir]
```

- `↑` desabilitado quando `position == 1`;
- `↓` desabilitado na última posição;
- ambos com `aria-label` ("Mover pergunta 2 para cima").

### Modal de confirmação

Título: **"Excluir esta pergunta?"**
Corpo: texto da pergunta (truncado em 120 caracteres) + "As 4 alternativas também serão removidas. Esta ação não pode ser desfeita."
Botões: "Cancelar" e "Excluir pergunta" (destrutivo).

## 7. Regras de negócio e validações

- Somente o dono do quiz reordena ou exclui perguntas; caso contrário, 404.
- Após excluir, a numeração exibida é recalculada e permanece densa (`1..n`).
- Excluir a última pergunta restante deixa o quiz sem perguntas e passa a exibir o empty state.
- Movimentos nas bordas não produzem alteração nem mensagem de erro.
- Excluir uma pergunta libera espaço no limite de 50 (o botão "Adicionar pergunta" volta a ficar ativo).

## 8. Critérios de aceite

```gherkin
Cenário: Mover pergunta para cima
  Dado um quiz meu com as perguntas "A" (1), "B" (2) e "C" (3)
  Quando clico na seta para cima da pergunta "B"
  Então a lista passa a exibir "B" (1), "A" (2) e "C" (3)

Cenário: Mover pergunta para baixo
  Dado um quiz meu com as perguntas "A" (1), "B" (2) e "C" (3)
  Quando clico na seta para baixo da pergunta "A"
  Então a lista passa a exibir "B" (1), "A" (2) e "C" (3)

Cenário: Controles de borda
  Dado um quiz meu com 3 perguntas
  Quando abro o editor
  Então a seta para cima da primeira pergunta está desabilitada
  E a seta para baixo da última pergunta está desabilitada

Cenário: Excluir pergunta com confirmação
  Dado um quiz meu com 3 perguntas
  Quando clico em "Excluir" na segunda pergunta
  Então vejo um modal de confirmação com o texto dessa pergunta
  Quando confirmo
  Então restam 2 perguntas numeradas como 1 e 2
  E vejo a mensagem "Pergunta excluída"

Cenário: Cancelar exclusão
  Dado que o modal de confirmação está aberto
  Quando clico em "Cancelar"
  Então o modal fecha e a pergunta permanece na lista

Cenário: Excluir a única pergunta
  Dado um quiz meu com 1 pergunta
  Quando excluo essa pergunta
  Então vejo o estado vazio com o botão "Adicionar pergunta"

Cenário: Ordem persiste após recarregar
  Dado que reordenei as perguntas
  Quando recarrego a página do editor
  Então a nova ordem é mantida

Cenário: Excluir libera o limite
  Dado um quiz meu com 50 perguntas e o botão de adicionar desabilitado
  Quando excluo uma pergunta
  Então o botão "Adicionar pergunta" volta a ficar habilitado
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/live/quiz_live/editor_test.exs` (complemento)

- clicar em ↑ e em ↓ altera a ordem exibida e a ordem persistida;
- setas de borda renderizadas como desabilitadas;
- clicar em excluir abre o modal com o texto da pergunta;
- confirmar exclui do banco, renumera a lista e exibe flash;
- cancelar mantém a pergunta;
- excluir a única pergunta mostra o empty state;
- excluir libera o botão de adicionar quando o quiz estava no limite;
- eventos disparados para pergunta de outro usuário levantam `Ecto.NoResultsError`;
- após múltiplas operações, as posições exibidas são exatamente `1..n`.

## 10. Definition of Ready

- [x] `move_question/3` e `delete_question/2` disponíveis (F1-08).
- [x] Lista de perguntas renderizada no editor (F1-11).
- [x] Texto do modal de confirmação definido.

## 11. Definition of Done

- [ ] Reordenação e exclusão funcionando pela interface, com a ordem persistida no banco.
- [ ] Botões de borda desabilitados e com `aria-label` descritivo.
- [ ] Modal de confirmação implementado.
- [ ] Nenhuma reordenação feita em memória na LiveView.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-08** — funções de contexto de reordenação e exclusão.
- **F1-11** — lista de perguntas no editor.

## 13. Riscos e pontos de atenção

- Cliques rápidos e sucessivos nas setas podem gerar operações concorrentes: o lock pessimista da
  F1-08 protege o dado, mas convém desabilitar o botão durante a operação (`phx-disable-with`).
- Recarregar o quiz inteiro a cada movimento é aceitável no volume desta fase (máximo de 50 perguntas).

## 14. Estimativa

**3 pontos** — interface simples apoiada em contexto já testado.
