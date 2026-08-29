# [F1-10] Criar, editar e excluir quiz pela interface

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `frontend`
> **Branch:** `feature/10-crud-quiz-ui` · **Estimativa:** 5 pontos · **Depende de:** F1-09

## 1. Contexto de negócio

Ter o contexto de quiz implementado não entrega valor enquanto o usuário não conseguir usá-lo. Esta
story fecha o ciclo de vida do quiz pela interface: criar, renomear, ajustar a descrição e excluir —
com confirmação explícita, já que a exclusão leva junto todas as perguntas.

## 2. User story

**Como** usuário autenticado,
**quero** criar um quiz informando título e descrição, alterá-los depois e excluir o quiz quando
não precisar mais dele,
**para que** eu gerencie meu conteúdo do início ao fim sem depender de ninguém.

## 3. Escopo

### Dentro
- Modal de criação de quiz em `/quizzes/new`, sobre o dashboard.
- Botão "Excluir" na lista do dashboard (a story F1-09 entrega a lista sem esse botão).
- Página do editor em `/quizzes/:id/edit` com o formulário de título e descrição do quiz.
- Exclusão de quiz a partir do dashboard, com modal de confirmação informando o impacto.
- Validação em tempo real (`phx-change`) e estados de carregamento (`phx-disable-with`).
- Mensagens de flash de sucesso e de erro.

### Fora
- Lista, adição e edição de perguntas dentro do editor (stories F1-11 e F1-12).
- Duplicação de quiz, publicação, compartilhamento.

## 4. Decisões de arquitetura

- **Criação em modal sobre o dashboard**, com rota própria (`/quizzes/new`) via `live_action`:
  a URL continua compartilhável e o botão voltar fecha o modal.
- **Após criar, redirecionar para `/quizzes/:id/edit`**: o próximo passo natural do usuário é
  adicionar perguntas, e o editor é onde isso acontecerá (F1-11).
- **Edição de título e descrição dentro do editor**, e não em modal no dashboard: evita conflito de
  rota com `/quizzes/:id/edit` e mantém um único lugar para editar o quiz.
- **Exclusão apenas a partir do dashboard**, com modal de confirmação que informa quantas perguntas
  serão removidas — a operação é irreversível (AD-08).
- **Erros de formulário exibidos sem reload**, usando `to_form/2` e o `.input` dos `core_components`.

## 5. Modelo de dados e migrations

Nenhuma. Consome `create_quiz/2`, `update_quiz/3`, `delete_quiz/2`, `get_quiz!/2` e `change_quiz/2`
(story F1-06).

## 6. Contratos técnicos

### Rotas

```elixir
live "/quizzes", QuizLive.Index, :index
live "/quizzes/new", QuizLive.Index, :new          # modal sobre o dashboard
live "/quizzes/:id/edit", QuizLive.Editor, :edit   # página do editor
```

### `LiveQuizWeb.QuizLive.Index` (evolução da F1-09)

- `live_action == :new` → renderiza `<.modal>` com o formulário de criação.
- Eventos:

| Evento | Efeito |
|---|---|
| `"validate_quiz"` | revalida o changeset e reatribui o form |
| `"save_quiz"` | `Quizzes.create_quiz/2`; em sucesso, flash "Quiz criado com sucesso" e `push_navigate` para `/quizzes/:id/edit`; em erro, reatribui o form com os erros |
| `"delete_quiz"` (com `phx-value-id`) | abre o modal de confirmação (assign `:quiz_to_delete`) |
| `"confirm_delete"` | `Quizzes.delete_quiz/2`; flash "Quiz excluído" e recarrega a página atual da lista |
| `"cancel_delete"` | fecha o modal de confirmação |

### `LiveQuizWeb.QuizLive.Editor`

`lib/live_quiz_web/live/quiz_live/editor.ex`

- `mount/3` carrega o quiz com `Quizzes.get_quiz_with_questions!/2` (404 se não for do usuário).
- Renderiza:
  - breadcrumb "Meus quizzes / <título>";
  - formulário de título e descrição com botão "Salvar";
  - área reservada para a lista de perguntas (implementada na F1-11).
- Eventos:

| Evento | Efeito |
|---|---|
| `"validate_quiz"` | revalida o changeset |
| `"save_quiz"` | `Quizzes.update_quiz/3`; flash "Alterações salvas" |

### Modal de confirmação de exclusão

Texto: **"Excluir o quiz \"<título>\"?"**
Corpo: "Esta ação também removerá <N> pergunta(s) e não pode ser desfeita."
Botões: "Cancelar" e "Excluir quiz" (destrutivo).

## 7. Regras de negócio e validações

- Título obrigatório, 3–120 caracteres; erro exibido abaixo do campo, em pt-BR.
- Descrição opcional, até 500 caracteres, com contador de caracteres restantes.
- Somente o dono acessa `/quizzes/:id/edit`; caso contrário, 404.
- A exclusão só ocorre após confirmação explícita no modal.
- Excluir um quiz remove suas perguntas e alternativas (cascata).
- Após excluir, o usuário permanece no dashboard, na mesma página e com a mesma busca — exceto
  quando a página deixa de existir, situação em que volta para a página 1.
- Submissões repetidas são evitadas com `phx-disable-with="Salvando..."`.

## 8. Critérios de aceite

```gherkin
Cenário: Criar quiz
  Dado que estou no dashboard
  Quando clico em "Criar quiz"
  Então um modal é aberto e a URL passa a ser "/quizzes/new"
  Quando informo o título "Geografia" e a descrição "Capitais do mundo" e salvo
  Então sou levado para "/quizzes/:id/edit"
  E vejo a mensagem "Quiz criado com sucesso"

Cenário: Criar quiz sem título
  Dado que o modal de criação está aberto
  Quando submeto sem preencher o título
  Então vejo o erro "não pode ficar em branco" abaixo do campo título
  E o modal permanece aberto
  E nenhum quiz é criado

Cenário: Título muito curto
  Quando informo um título com 2 caracteres e submeto
  Então vejo a mensagem de tamanho mínimo
  E nenhum quiz é criado

Cenário: Fechar o modal
  Dado que o modal de criação está aberto
  Quando clico em "Cancelar"
  Então o modal fecha e a URL volta para "/quizzes"

Cenário: Editar título e descrição
  Dado que estou em "/quizzes/:id/edit" de um quiz meu
  Quando altero o título para "Geografia do Brasil" e salvo
  Então vejo a mensagem "Alterações salvas"
  E o novo título aparece no dashboard

Cenário: Editor de quiz alheio
  Dado um quiz de Bruno
  Quando eu, Ana, acesso "/quizzes/<id_do_bruno>/edit"
  Então recebo a página de erro 404

Cenário: Excluir quiz com confirmação
  Dado um quiz meu com 3 perguntas listado no dashboard
  Quando clico em "Excluir"
  Então vejo um modal informando que 3 perguntas serão removidas
  Quando confirmo a exclusão
  Então o quiz desaparece da lista
  E vejo a mensagem "Quiz excluído"

Cenário: Cancelar a exclusão
  Dado que o modal de confirmação está aberto
  Quando clico em "Cancelar"
  Então o modal fecha
  E o quiz continua na lista
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/live/quiz_live/index_test.exs` (complemento) e
`test/live_quiz_web/live/quiz_live/editor_test.exs`

- abrir `/quizzes/new` renderiza o modal de criação;
- submeter formulário válido cria o quiz e redireciona para o editor com flash;
- submeter sem título, com título curto ou com descrição longa exibe os erros e não persiste;
- `phx-change` exibe erro de validação sem submeter;
- fechar o modal retorna para `/quizzes`;
- editor carrega título e descrição atuais;
- salvar alterações válidas persiste e exibe flash;
- salvar alterações inválidas exibe erro e não persiste;
- acessar editor de quiz de outro usuário retorna 404 (`assert_raise Ecto.NoResultsError`);
- clicar em excluir abre o modal com a contagem correta de perguntas;
- confirmar exclusão remove o quiz da lista e do banco;
- cancelar exclusão mantém o quiz;
- excluir o último item da página 2 leva o usuário para uma página válida.

## 10. Definition of Ready

- [x] Contexto de quiz disponível (F1-06).
- [x] Dashboard disponível (F1-09).
- [x] Fluxo pós-criação definido (ir para o editor).
- [x] Texto do modal de confirmação definido.

## 11. Definition of Done

- [ ] Criação, edição e exclusão funcionando ponta a ponta pela interface.
- [ ] Modal de exclusão informando o impacto real.
- [ ] Validação sem reload e estados de carregamento nos botões.
- [ ] Nenhuma regra de negócio na LiveView; nenhum acesso ao `Repo`.
- [ ] Layout utilizável a partir de 375px; foco movido para o primeiro campo com erro.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-09** — dashboard onde os botões vivem.
- **F1-06** — funções de contexto.

## 13. Riscos e pontos de atenção

- Ordem das rotas: hoje não existe `/quizzes/:id` na web, então `/quizzes/new` não conflita com nada.
  Se uma rota `/quizzes/:id` for adicionada em fases futuras, `/quizzes/new` precisa vir antes dela.
- Após excluir, recalcular a paginação para não deixar o usuário em uma página vazia.
- O modal precisa devolver o foco ao elemento que o abriu ao ser fechado (acessibilidade básica).

## 14. Estimativa

**5 pontos** — três fluxos de UI com validação, modal e redirecionamentos.
