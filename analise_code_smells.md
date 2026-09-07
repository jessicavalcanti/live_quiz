# Análise de inconsistências e code smells

> Varredura completa de `lib/`, `config/`, `priv/` e `test/` realizada em 2026-09-06 sobre a
> tag `v1.0.0` (commit `6cc8ed8`, branch `develop`).
>
> **Ferramental estático passa limpo** — `mix compile --warnings-as-errors` sem avisos e
> `mix credo --strict` reportando "no issues" em 68 checks sobre 199 arquivos. Todos os
> pontos abaixo são semânticos e invisíveis para o linter.
>
> Baseline da suíte no momento da análise: **1852 testes** (23 doctests, 1829 testes).

## Índice de correção

| # | Ponto | Severidade | Fase | Status |
|---|---|---|---|---|
| 1 | Filtro `to` de data diverge entre API e UI | 🔴 Alta | 1 | ✅ |
| 2 | `/ranking` resolve identidade diferente dos irmãos | 🔴 Alta | 1 | ✅ |
| 3 | Validação de paginação duplicada com semânticas opostas | 🔴 Alta | 1 | ✅ |
| 4 | `load_summary` do host quebra onde o do player tolera | 🔴 Alta | 1 | ✅ |
| 5 | `closed?/1` significa coisas diferentes em módulos irmãos | 🔴 Alta | 1 | ✅ |
| 6 | `{:question_scored, …}` nunca é emitido em produção | 🟠 Média | 2 | ✅ |
| 7 | API pública viva só pelos próprios testes | 🟠 Média | 2 | ✅ |
| 8 | `due?/1` — 3 cópias byte a byte | 🟡 Baixa | 3 | ✅ |
| 9 | `defp trim/1` — 7 cópias idênticas | 🟡 Baixa | 3 | ✅ |
| 10 | `option_letter/1` — 3 cópias | 🟡 Baixa | 3 | ✅ |
| 11 | Expansão de data duplicada com nomes diferentes | 🟡 Baixa | 3 | ✅ |
| 12 | `load_results/2` e `load_ranking/2` duplicados | 🟡 Baixa | 3 | ✅ |
| 13 | Loop "tenta cada identidade" escrito duas vezes | 🟡 Baixa | 3 | ✅ |
| 14 | `defp scope(conn)` triplicado + acesso inline inconsistente | 🟡 Baixa | 3 | ✅ |
| 15 | N+1 de escrita na pontuação | 🟡 Baixa | 4 | ✅ |
| 16 | N+1 no encerramento (`final_position`) | 🟡 Baixa | 4 | ✅ |
| 17 | Snapshot de perguntas duplicado por participante | 🟡 Baixa | 4 | ✅ |
| 18 | `games.ex` com 3437 linhas | 🔵 Info | 5 | ✅ |
| 19 | Moduledoc de `Games` desatualizado | 🔵 Info | 5 | ✅ |
| 20 | Pares de autorização quase homógrafos | 🔵 Info | 5 | ✅ |
| 21 | `maybe_filter_quiz` sem a cláusula `""` do irmão | 🔵 Info | 1 | ✅ |
| 22 | `mount` com chaves atom, template com chaves string | 🔵 Info | 1 | ✅ |
| 23 | `if` usado só por efeito colateral | 🔵 Info | 5 | ✅ |
| 24 | Aritmética redundante no cálculo de pontos | 🔵 Info | 5 | ✅ |
| 25 | Três idiomas para "agora" | 🔵 Info | 5 | ✅ |
| 26 | `Repo.transact` vs `Repo.transaction` | 🔵 Info | 5 | ✅ |
| 27 | `FallbackController` sem cláusula catch-all | 🔵 Info | 5 | ✅ |
| 28 | Nomenclatura do snapshot inconsistente | 🔵 Info | 5 | ✅ |
| 29 | Comentários misturam idiomas | 🔵 Info | 5 | ✅ |
| 30 | Dois `live_session` com `on_mount` idênticos | 🔵 Info | 5 | ✅ |
| 31 | Dois contratos opostos de paginação inválida na mesma API | 🔴 Alta | 1 | ✅ |
| 32 | `paginate_sessions` conta carregando todas as linhas | 🟡 Baixa | 4 | ✅ |

## Decisões tomadas antes da correção

1. **Paginação inválida passa a ser estrita em toda a API** (422 `invalid_filter`). `/api/v1/quizzes`
   deixa de cair no default em silêncio; os dois testes de contrato que assumiam o comportamento
   tolerante são atualizados.
2. **`games.ex` será quebrado em submódulos** (`Games.Lobby`, `Games.Match`, `Games.Scoring`,
   `Games.History`), mantendo `LiveQuiz.Games` como fachada delegadora para não quebrar nenhum
   caller nem teste. Executado por último (fase 6), depois que código morto e duplicação saírem.

## Plano de fases

| Fase | Escopo | Itens |
|---|---|---|
| 1 | Bugs de comportamento | 1, 2, 3, 4, 5, 21, 22, 31 |
| 2 | Código morto e eventos fantasma | 6, 7 |
| 3 | Duplicação estrutural | 8, 9, 10, 11, 12, 13, 14 |
| 4 | Performance | 15, 16, 17, 32 |
| 5 | Menores e consistência | 19, 20, 23, 24, 25, 26, 27, 28, 29, 30 |
| 6 | Split de `games.ex` | 18 |

---

## 🔴 Inconsistências de comportamento

### 1. Filtro `to` de data filtra dias diferentes na API e na UI

A UI expande `to` para o fim do dia; a API converte para meia-noite. O contexto compara com `<=`
(`lib/live_quiz/games.ex:2842`):

- `lib/live_quiz_web/live/game_result_live/index.ex:50` → `"2026-09-06T23:59:59Z"` → inclui o dia inteiro
- `lib/live_quiz_web/api/v1/game_result_controller.ex:194` → `DateTime.new!(date, ~T[00:00:00])` → **exclui quase todo o dia pedido**

Mesmo filtro, mesmo recurso lógico, resultado diferente conforme o cliente.

### 2. `/ranking` resolve identidade diferente dos endpoints irmãos

`lib/live_quiz_web/api/v1/game_result_controller.ex:151` usa precedência simples:

```elixir
defp viewer(conn), do: conn.assigns[:current_scope] || conn.assigns[:current_participant]
```

Já `game_play_controller.ex:346` (`as_viewer/2`) e `participant_controller.ex:188`
(`list_participants/2`) **tentam as duas identidades** e só desistem se ambas recusarem. Os três
estão no mesmo pipeline `:api_participant`.

Consequência: quem está logado numa conta e entrou na sala como convidado (participação sem
`user_id`) recebe 403 em `/ranking`, mas 200 em `/state` e `/participants` — `allowed_to_watch?`
(`games.ex:3293`) reprova o `Scope` e o `Participant` nunca chega a ser testado.

### 3. Validação de paginação duplicada com semânticas opostas

| Camada | `per_page` inválido | data inválida |
|---|---|---|
| `game_result_controller.ex:162` | `{:error, :invalid_filter}` → 422 | 422 |
| `games.ex:2978` (`normalize_result_per_page`) | silenciosamente vira `20` | filtro **ignorado** |

As LiveViews chamam o contexto direto, então a UI aceita calada o que a API rejeita.

### 4. `load_summary` do host quebra onde o do player tolera

```elixir
# lib/live_quiz_web/live/game_session_live/host.ex:184
{:ok, summary} = Games.game_summary(session, scope)   # match duro → crash em {:error, :unauthorized}

# lib/live_quiz_web/live/game_session_live/player.ex:312
case Games.game_summary(session, participant) do
  {:ok, summary} -> assign(socket, :summary, summary)
  {:error, :unauthorized} -> assign(socket, :summary, nil)
end
```

### 5. `closed?/1` significa coisas diferentes em módulos irmãos

- `host.ex:781` → `state == :closed`
- `player.ex:883` → `not pending? and not open?` — trata prazo vencido ainda não fechado como fechado

Mesmo nome, mesma pasta, semânticas divergentes.

---

## 🟠 Código morto e eventos fantasma

### 6. `{:question_scored, session, ranking}` nunca é emitido em produção

Só `score_closed_question/2` (`games.ex:1130`) publica esse evento — e essa função **não é chamada
por nenhum código de produção**, apenas por 8 testes. O caminho real é o privado
`score_and_publish_ranking/1` (`games.ex:1143`), que publica só `{:ranking_updated, …}`.

Resultado: duas cláusulas no-op mantidas para um evento morto —

```elixir
# host.ex:353 e player.ex:506
def handle_info({:question_scored, _session, _ranking}, socket), do: {:noreply, socket}
```

E os testes exercitam um broadcast que produção não faz.

### 7. API pública viva só pelos próprios testes

Zero referências em `lib/`, N referências em `test/`:

| Função | Testes |
|---|---|
| `GameSession.status_changeset/3` (+ `stamp_status_timestamps`, `closed_statuses/0`) | 21 |
| `Games.score_closed_question/2` | 10 |
| `Games.get_current_answer/2` | 9 |
| `Games.engaged_in_session?/1` | 7 |
| `Games.answered_participant_ids/1` | 7 |
| `GameSession.question_closed?/1` | 7 |
| `Games.seconds_until_expiration/2` | 6 |
| `QuizLock.locked_ids/1` | 6 |
| `ParticipantAuth.cookie_name/0` | 5 |
| `Games.host_connection_current?/2` | 5 |
| `Games.get_game_session!/2` | 4 |
| `CoreComponents.translate_errors/2` | 1 |

### Resolução do #7

Ao abrir os testes, a lista se dividiu em dois grupos com destinos opostos, e o critério passou a
ser: **uma função pública só chamada por teste ou é (a) superada por outra implementação que a
aplicação de fato usa — e aí é morta —, ou (b) um acessor somente-leitura de que os testes precisam
para observar um estado que a aplicação altera — e aí é legítima, mas tem de dizer isso no `@doc`
para que o próximo leitor não a "limpe".**

**Removidas (superadas):**

| Função | Substituída por |
|---|---|
| `Games.get_game_session!/2` | `get_hosted_session_by_code!/2` |
| `Games.get_current_answer/2` | `game_state/2` → `my_answer_option_id` |
| `Games.answered_participant_ids/1` | `game_state/2` → `answers_count` |
| `QuizLock.locked_ids/1` | `with_lock_flag/1` (EXISTS correlacionado) |
| `GameSession.question_closed?/1` | `question_open?/1` + status |

**Mantidas e documentadas como seam de observação** — apagá-las teria apagado cobertura de
comportamento vivo, porque os testes as usam para *afirmar* o resultado de outra operação:

| Função | Testes que dependem dela |
|---|---|
| `Games.engaged_in_session?/1` | sair da sala, ser dispensado, regra de uma sala por pessoa |
| `Games.seconds_until_expiration/2` | queda e retorno do host, prazo de ausência |
| `Games.connection_current?/2` e `host_connection_current?/2` | reivindicação de acesso e tomada de controle |
| `GameSession.status_changeset/3` | `test/support/fixtures/games_fixtures.ex` constrói salas em cada estado |
| `CoreComponents.translate_errors/2` | tradução pt-BR das mensagens do Ecto |
| `ParticipantAuth.cookie_name/0` | nome do cookie sem string mágica no teste |

`GameSession.closed_statuses/0` deixou de ser só constante: `close_session/2` agora se guarda com
ela, então um status que não encerra nada não pode ser escrito pelo `UPDATE` que deveria encerrar.

---

## 🟡 Duplicação estrutural

### 8. `due?/1` — 3 cópias byte a byte

```elixir
DateTime.compare(DateTime.utc_now(), ends_at) != :lt
```

`games.ex:2545` (`question_due?`) · `question_timer.ex:234` · `question_timer_supervisor.ex:107`.
`GameSession` já é o dono de `question_open?/1` e `question_closed?/1` — é ali que falta.

### 9. `defp trim/1` — 7 cópias idênticas

`quiz.ex:56` · `question.ex:104` · `answer_option.ex:44` · `game_session.ex:271` ·
`game_session_question.ex:75` · `game_session_answer_option.ex:67` · `participant.ex:202`

### 10. `option_letter/1` — 3 cópias

`question_results.ex:141` · `host.ex:802` · `player.ex:887` — com um módulo `Formatters` já
existente e sem ela.

### 11. Expansão de data duplicada com nomes diferentes

`game_history_live/index.ex:127` (`expand_dates`/`expand_date`) e `game_result_live/index.ex:47`
(`context_filters`/`maybe_expand_date`) são a mesma função renomeada — uma usa `filters[key]` +
interpolação, a outra `Map.get` + `<>`. As duas LiveViews são quase clones (mesmo `@per_page`,
mesmo formulário, mesma paginação).

### 12. `load_results/2` e `load_ranking/2` duplicados

Entre `host.ex:143,154,165` e `player.ex:266,277,288` — diferem só em qual assign é o viewer
(`current_scope` vs `participant`), sendo que `Games` já aceita os dois polimorficamente.

### 13. Loop "tenta cada identidade" escrito duas vezes

`game_play_controller.ex:346` (`as_viewer/2`) e `participant_controller.ex:188`
(`list_participants/2`).

### 14. `defp scope(conn)` triplicado + acesso inline inconsistente

`defp scope(conn), do: conn.assigns.current_scope` em `quiz_controller.ex:159`,
`question_controller.ex:232` e `game_result_controller.ex:152`, enquanto `game_play`,
`game_session` e `session` acessam inline — e `game_session_controller.ex:204` usa
`conn.assigns[:current_scope]` (bracket) contra `conn.assigns.current_scope` (ponto) nas linhas
165/252/278 do mesmo arquivo.

---

## 🟡 Performance

### 15. N+1 de escrita na pontuação

`games.ex:1027` (`score_participants`): um `Repo.update!` por participante **mais** um
`stamp_response_time` por resposta, dentro da transação com `lock_match`. Com 25 participantes são
até 50 `UPDATE`s serializados por pergunta.

### 16. N+1 no encerramento

`games.ex:2741`: um `Repo.update_all` por participante só para gravar `final_position`. Além
disso `Enum.with_index(participants, 1)` é recalculado nas linhas 2741 e 2754.

### 17. Snapshot de perguntas duplicado por participante

`question_result_snapshot/2` (`games.ex:2790`) grava o texto da pergunta e **todas as
alternativas** dentro do `question_results` de *cada* `game_result`. 25 participantes × N
perguntas = o mesmo JSON replicado 25 vezes.

---

## 🔵 Menores

### 18. `games.ex` com 3437 linhas

6× o segundo maior módulo do contexto, ~230 funções. Fronteiras naturais já visíveis: lobby /
entrada, execução da partida, pontuação / ranking, resultados / histórico.

**Resolvido.** `LiveQuiz.Games` passou de 3437 para 1449 linhas, mantendo-se como fachada: a
superfície pública do módulo perdeu exatamente as 3 funções removidas no #7 e não ganhou nenhuma,
então nenhum controller, LiveView, teste ou fixture precisou mudar.

| Módulo | Linhas | O que é |
|---|---|---|
| `LiveQuiz.Games` | 1449 | a sala em volta da partida: abrir, entrar, sair, encerrar — e a fachada |
| `Games.Match` | 1374 | a partida sendo jogada: começar, avançar, responder, apurar, terminar |
| `Games.Scoring` | 374 | quanto vale uma pergunta encerrada e o ranking que ela produz |
| `Games.History` | 297 | o que sobra de uma partida depois que ela acaba |
| `Games.Access` | 92 | quem pode ver o quê de uma sala |
| `Games.Room` | 91 | primitivas da linha da sala (recarregar, filtrar vivas, liberar, relógios) |
| `Games.Locks` | 67 | as classes de advisory lock e a ordem em que são tomadas |
| `Games.Topic` | 62 | o tópico único de PubSub e as duas portas de entrada |

A ordem foi deliberada: primeiro os cortes autocontidos (`History`, `Topic`), depois a fundação
compartilhada (`Locks`, `Access`, `Room`), e só então `Scoring` e `Match` — que dependem dela. Duas
guardas de estado da partida (`ensure_running/1`, `ensure_question_settled/2`) migraram para
`GameSession`, ao lado de `question_open?/1` e `question_due?/1`, que é onde predicados sobre a
struct já moravam.

### 19. Moduledoc de `Games` desatualizado

`games.ex:96-120`:

- *"Neither of them scores anything; there is no point, bonus or position in phase 3"* — a fase 4
  adicionou pontuação, bônus de velocidade e posição ao mesmo módulo.
- A tabela "Events of a running match" lista 5 eventos; o módulo publica 13.

### 20. Pares de autorização quase homógrafos

`allowed_to_watch?`/`took_part?` (`games.ex:3293`) vs `allowed_to_list?`/`taking_part?`
(`games.ex:3366`) diferem **só** pelo filtro `is_nil(p.released_at)`. Os nomes não sinalizam a
diferença.

### 21. `maybe_filter_quiz` sem a cláusula `""` que o irmão tem

`games.ex:2866` cai direto no `where`, enquanto `maybe_filter_session_quiz` (`games.ex:2854`)
trata `""`. Hoje não quebra só porque `GameResultLive.Index` faz `clean_filters` — mas
`GameHistoryLive.Index:17` **não** faz.

### 22. `mount` com chaves atom, template com chaves string

`game_result_live/index.ex:14` assina `%{quiz_id: "", from: "", to: ""}`, o template lê
`@filters["quiz_id"]` (`:87`). O `GameHistoryLive` nem assina `filters` no mount.

### 23. `if` usado só por efeito colateral

`games.ex:1035`: `if answered?, do: stamp_response_time(answer, response_time)` sem `else`,
resultado descartado.

### 24. Aritmética redundante no cálculo de pontos

`games.ex:955`: `min(div(1_000 * remaining_ms, duration * 1_000), 1_000)` é
`div(remaining_ms, duration)`; o `min` nunca é atingido porque `elapsed_time_ms` já faz clamp em 0.

### 25. Três idiomas para "agora"

`DateTime.truncate(DateTime.utc_now(), :second)` (`games.ex:3432`), `DateTime.utc_now(:second)`
(`user.ex:148`, `quizzes.ex:394`) e `DateTime.utc_now()` cru. Em `persist_final_results`
(`games.ex:2782`) `now()` é chamado duas vezes por linha, podendo cair em segundos diferentes.

### 26. `Repo.transact` vs `Repo.transaction`

`accounts.ex` (3×) usa um, `games.ex`/`quizzes.ex` (12×) usam o outro.

### 27. `FallbackController` sem cláusula catch-all

Qualquer átomo de erro novo vira `FunctionClauseError` → 500. O cruzamento de todos os
`{:error, :atom}` dos contextos mostra cobertura completa hoje (`transaction_aborted`,
`already_confirmed`, `not_due`, `timer_unavailable` não alcançam controllers), mas não há rede.

### 28. Nomenclatura do snapshot inconsistente

`Question.text` vira `GameSessionQuestion.question_text`, mas `AnswerOption.text` continua
`GameSessionAnswerOption.text`. E `GameSessionQuestion` valida `min: 1` onde `Question` exige
`min: 3`, contrariando o próprio moduledoc ("*accepts anything the question of phase 1 accepts*").

### 29. Comentários misturam idiomas

Moduledocs em inglês (114 arquivos), comentários de `config/test.exs` em pt-BR sem acento
("expiracao", "nao", "proposito"), strings de usuário em pt-BR acentuado.

### 30. Dois `live_session` com `on_mount` idênticos

`:current_user` e `:participant` (`router.ex:158,171`). Sem custo funcional hoje (a entrada no
player é redirect de controller), mas são um só.

### 31. Dois contratos opostos de paginação inválida na mesma API

Descoberto durante a fase 1, ao unificar os filtros. Há uma **terceira** implementação de
paginação em `LiveQuiz.Quizzes` (`quizzes.ex:556-570`, `normalize_page`/`normalize_per_page`),
com contrato oposto ao da fase 4:

| Requisição | Resposta |
|---|---|
| `GET /api/v1/quizzes?per_page=101` | **200**, `per_page` volta como `20` |
| `GET /api/v1/quizzes?page=abc&per_page=-3` | **200**, `page: 1, per_page: 20` |
| `GET /api/v1/users/me/game-results?per_page=101` | **422** `invalid_filter` |

Os dois comportamentos estão cobertos por teste, então a divergência é intencional em cada lado e
acidental no conjunto. Resolvido pela decisão 1 acima.

### 32. `paginate_sessions` conta carregando todas as linhas

`games.ex:2932`: `total = query |> Repo.all() |> length()`. A query tem `group_by`, então um
`Repo.aggregate(:count)` direto não serve — mas carregar o resultado inteiro em memória só para
medir o tamanho custa a página inteira do histórico a cada request. O caminho é
`Repo.aggregate(subquery(query), :count)`. Compare com `paginate_results` (`games.ex:2908`), que
já faz a contagem no banco.
