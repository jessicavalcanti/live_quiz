# [F1-08] Contexto `Quizzes`: excluir e reordenar perguntas

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `backend`
> **Branch:** `feature/08-contexto-reordenar-excluir` · **Estimativa:** 3 pontos · **Depende de:** F1-07

## 1. Contexto de negócio

A ordem das perguntas define a experiência da partida: é nessa sequência que elas serão exibidas aos
participantes nas fases 3 e 4. O autor precisa poder reorganizar o roteiro do quiz e remover
perguntas que não fazem mais sentido, sem que a numeração fique com buracos ou duplicidades.

## 2. User story

**Como** usuário autenticado dono de um quiz,
**quero** excluir perguntas e alterar a ordem em que elas aparecem,
**para que** o roteiro do meu quiz fique exatamente como eu planejei.

## 3. Escopo

### Dentro
- `delete_question/2` com renumeração das perguntas seguintes.
- `move_question/3` (`:up` / `:down`) com troca de posições em transação.
- Garantia de sequência densa e sem duplicidade após qualquer operação.
- Testes de contexto, incluindo concorrência básica.

### Fora
- Telas (story F1-12) e endpoints (story F1-15).
- Reordenação por arraste, movimentação para posição arbitrária, mover pergunta entre quizzes.

## 4. Decisões de arquitetura

- **Sequência densa `1..n`** (AD-07): após excluir a pergunta de posição `k`, todas as perguntas com
  posição maior que `k` são decrementadas em 1, dentro da mesma transação da exclusão.
- **Troca de posições em transação**, apoiada na constraint
  `UNIQUE (quiz_id, position) DEFERRABLE INITIALLY DEFERRED` criada em F1-05: as duas atualizações
  ocorrem sem violação intermediária, sem precisar de posição temporária.
- **`move_question/3` recebe direção, não posição de destino**: a interface da fase 1 usa botões
  ↑/↓, e a direção elimina toda uma classe de entrada inválida.
- **Operação idempotente nas bordas**: mover a primeira pergunta para cima ou a última para baixo é
  um no-op bem-sucedido, não um erro.
- **Bloqueio pessimista** (`FOR UPDATE`) nas perguntas envolvidas para evitar corrida entre duas
  abas do mesmo usuário.

## 5. Modelo de dados e migrations

Nenhuma migration nova. Depende diretamente da constraint deferrable criada em **F1-05**.

## 6. Contratos técnicos

Arquivo: `lib/live_quiz/quizzes.ex`

```elixir
@doc """
Exclui a pergunta e renumera as perguntas seguintes do mesmo quiz,
mantendo a sequência densa 1..n. Executa em transação.
"""
@spec delete_question(Scope.t(), Question.t()) ::
        {:ok, Question.t()} | {:error, Ecto.Changeset.t()}
def delete_question(scope, question)

@doc """
Move a pergunta uma posição para cima ou para baixo dentro do quiz.
Retorna {:ok, :unchanged} quando a pergunta já está na borda correspondente.
"""
@spec move_question(Scope.t(), Question.t(), :up | :down) ::
        {:ok, Question.t()} | {:ok, :unchanged} | {:error, term()}
def move_question(scope, question, direction)
```

### Algoritmo de `delete_question/2`

```text
transaction do
  question = recarrega a pergunta com lock FOR UPDATE, validando o escopo
  Repo.delete(question)                       # alternativas caem por cascata
  from(q in Question,
    where: q.quiz_id == ^question.quiz_id and q.position > ^question.position)
  |> Repo.update_all(inc: [position: -1])
end
```

### Algoritmo de `move_question/3`

```text
transaction do
  target_position = position + 1 (down) ou position - 1 (up)
  vizinha = pergunta do mesmo quiz na target_position (lock FOR UPDATE)
  se não existir -> {:ok, :unchanged}
  senão -> atualiza vizinha para a posição atual e a pergunta para target_position
end
```

## 7. Regras de negócio e validações

- Só o dono do quiz pode excluir ou mover perguntas; caso contrário, `Ecto.NoResultsError`.
- Após qualquer exclusão, as posições do quiz formam a sequência `1..n` sem buracos.
- Após qualquer movimentação, não existem posições duplicadas no quiz.
- Excluir uma pergunta remove suas 4 alternativas (cascata do banco).
- Excluir a última pergunta é permitido; o quiz simplesmente deixa de ser jogável (`playable?/1` falso).
- Mover a primeira para cima ou a última para baixo não altera nada e não é erro.
- As operações não alteram `updated_at` do quiz — apenas das perguntas afetadas.

## 8. Critérios de aceite

```gherkin
Cenário: Excluir pergunta do meio renumera as seguintes
  Dado um quiz meu com perguntas nas posições 1, 2, 3 e 4
  Quando excluo a pergunta da posição 2
  Então restam 3 perguntas
  E suas posições passam a ser 1, 2 e 3, preservando a ordem relativa original

Cenário: Excluir a última pergunta
  Dado um quiz meu com 1 pergunta
  Quando excluo essa pergunta
  Então o quiz fica sem perguntas
  E playable? passa a retornar falso

Cenário: Exclusão remove as alternativas
  Dada uma pergunta minha com 4 alternativas
  Quando excluo a pergunta
  Então nenhuma das 4 alternativas permanece no banco

Cenário: Mover pergunta para baixo
  Dado um quiz meu com as perguntas A (1), B (2) e C (3)
  Quando movo A para baixo
  Então a ordem passa a ser B (1), A (2) e C (3)

Cenário: Mover pergunta para cima
  Dado um quiz meu com as perguntas A (1), B (2) e C (3)
  Quando movo C para cima
  Então a ordem passa a ser A (1), C (2) e B (3)

Cenário: Mover a primeira para cima
  Dado um quiz meu com as perguntas A (1) e B (2)
  Quando movo A para cima
  Então a ordem permanece A (1) e B (2)
  E a operação retorna sucesso sem alteração

Cenário: Mover a última para baixo
  Dado um quiz meu com as perguntas A (1) e B (2)
  Quando movo B para baixo
  Então a ordem permanece A (1) e B (2)
  E a operação retorna sucesso sem alteração

Cenário: Operar pergunta de quiz alheio
  Dada uma pergunta de um quiz de Bruno
  Quando Ana tenta excluí-la ou movê-la
  Então é levantado Ecto.NoResultsError
  E nada é alterado
```

## 9. Cenários de teste

Arquivo: `test/live_quiz/quizzes_questions_test.exs` (ou `quizzes_ordering_test.exs`)

- exclusão do meio, do início e do fim, verificando a sequência resultante em cada caso;
- exclusão remove as alternativas em cascata;
- exclusão de pergunta única deixa o quiz vazio e não jogável;
- movimentação para cima e para baixo em lista de 3 e de 5 perguntas;
- movimentação nas bordas retorna `{:ok, :unchanged}` e não altera o banco;
- após uma sequência de operações (criar 5, excluir 2, mover 3 vezes), as posições continuam sendo
  exatamente `1..n` sem duplicidade — teste de invariante;
- exclusão e movimentação em quiz de outro usuário levantam `Ecto.NoResultsError`;
- a movimentação é atômica: uma falha simulada no meio da transação não deixa posições duplicadas.

## 10. Definition of Ready

- [x] Constraint deferrable disponível (F1-05).
- [x] Contexto de perguntas disponível (F1-07).
- [x] Semântica de borda definida (no-op bem-sucedido).

## 11. Definition of Done

- [ ] `delete_question/2` e `move_question/3` implementadas e transacionais.
- [ ] Invariante de posições `1..n` garantida por teste.
- [ ] Bloqueio pessimista aplicado nas perguntas envolvidas.
- [ ] Todos os cenários do item 9 passando.
- [ ] `@doc` e `@spec` nas funções públicas.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-07** — perguntas criadas e `get_question!/3`.
- **F1-05** — constraint `DEFERRABLE INITIALLY DEFERRED`.

## 13. Riscos e pontos de atenção

- Se a constraint não tiver sido criada como deferrable, a troca de posições falhará: validar isso
  antes de implementar.
- `Repo.update_all` com `inc:` não dispara changesets nem atualiza `updated_at` — comportamento
  aceito e intencional aqui.
- Duas abas do mesmo usuário movendo perguntas simultaneamente é o cenário de corrida mais provável;
  o `FOR UPDATE` cobre isso.

## 14. Estimativa

**3 pontos** — pouco código, mas com invariantes que exigem testes cuidadosos.
