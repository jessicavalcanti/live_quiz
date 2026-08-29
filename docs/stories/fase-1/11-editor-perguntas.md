# [F1-11] Editor de quiz: adicionar e editar perguntas em modal

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `frontend`
> **Branch:** `feature/11-editor-perguntas` · **Estimativa:** 8 pontos · **Depende de:** F1-07, F1-10

## 1. Contexto de negócio

Esta é a tela que justifica a fase 1. É aqui que o conteúdo do quiz é efetivamente produzido: o
autor escreve as perguntas, digita as quatro alternativas e indica a resposta correta. Sem ela, o
usuário depende do banco de dados para criar conteúdo — exatamente o que o critério de conclusão da
fase proíbe.

## 2. User story

**Como** usuário autenticado dono de um quiz,
**quero** adicionar perguntas com quatro alternativas e marcar a correta, além de editar as
perguntas já criadas,
**para que** eu monte o conteúdo do meu quiz inteiramente pela interface.

## 3. Escopo

### Dentro
- Lista de perguntas do quiz dentro do editor (`/quizzes/:id/edit`), na ordem de `position`.
- Modal de criação de pergunta em `/quizzes/:id/questions/new`.
- Modal de edição de pergunta em `/quizzes/:id/questions/:question_id/edit`.
- Formulário com o texto da pergunta e as 4 alternativas (A–D), com seleção da correta por radio.
- Validação em tempo real, mensagens de erro por campo e estados de carregamento.
- Bloqueio de novas perguntas ao atingir o limite de 50.

### Fora
- Reordenação e exclusão de perguntas (story F1-12).
- Adicionar ou remover alternativas — sempre 4 (AD-05).
- Imagens, tempo por pergunta, pontuação, pré-visualização do quiz.

## 4. Decisões de arquitetura

- **Salvamento incremental por pergunta**: cada pergunta é persistida individualmente, de forma
  atômica, ao salvar o modal. O quiz não tem um "salvar tudo" — decisão E1 do refinamento.
  Vantagens: nada se perde, os erros ficam localizados e o teste é objetivo.
- **Modais com rota própria** (`live_action`), mantendo URL compartilhável e botão voltar funcional.
- **Radio group para a alternativa correta**: torna estruturalmente impossível marcar duas corretas
  na interface; a validação de servidor continua existindo como autoridade (documento, seção 9.2).
- **Formulário renderizado com `inputs_for`** sobre o changeset de `Question` com `cast_assoc`,
  aproveitando as validações de conjunto já implementadas na F1-07 — a LiveView não replica regra.
- **`LiveComponent` para o formulário da pergunta** (`QuestionFormComponent`), isolando estado do
  formulário do estado da página e permitindo reuso entre criação e edição.
- **Lista recarregada do contexto após cada operação**, em vez de manipulada em memória: a fonte da
  verdade é o banco.

## 5. Modelo de dados e migrations

Nenhuma. Consome `create_question/3`, `update_question/3`, `get_question!/3`, `change_question/2`,
`new_question/0` e `get_quiz_with_questions!/2`.

## 6. Contratos técnicos

### Rotas

```elixir
live "/quizzes/:id/edit", QuizLive.Editor, :edit
live "/quizzes/:id/questions/new", QuizLive.Editor, :new_question
live "/quizzes/:id/questions/:question_id/edit", QuizLive.Editor, :edit_question
```

### `LiveQuizWeb.QuizLive.Editor` (evolução da F1-10)

Assigns adicionais:

| Assign | Conteúdo |
|---|---|
| `:quiz` | quiz com `questions` e `answer_options` pré-carregados e ordenados |
| `:question` | pergunta em edição (ou `new_question/0` na criação), apenas nas `live_action` de modal |

`handle_params/3`:
- `:new_question` → se o quiz já tiver 50 perguntas, faz `push_patch` de volta para
  `/quizzes/:id/edit` com flash de limite atingido; caso contrário, atribui `Quizzes.new_question()`;
- `:edit_question` → `Quizzes.get_question!(scope, quiz, question_id)` (404 se não pertencer).

### `LiveQuizWeb.QuizLive.QuestionFormComponent`

`lib/live_quiz_web/live/quiz_live/question_form_component.ex`

Atributos: `:id`, `:quiz`, `:question`, `:current_scope`, `:action` (`:new` ou `:edit`), `:patch`
(rota de retorno).

Eventos internos:

| Evento | Efeito |
|---|---|
| `"validate"` | `Quizzes.change_question/2` com `action: :validate` e reatribuição do form |
| `"save"` | `create_question/3` ou `update_question/3`. Em sucesso: envia mensagem ao pai, exibe flash e faz `push_patch` para `/quizzes/:id/edit`. Em `{:error, %Ecto.Changeset{}}`: mantém o modal aberto com os erros. Em `{:error, :question_limit_reached}`: fecha o modal e exibe o flash de erro "Este quiz já atingiu o limite de 50 perguntas" |

### Estrutura do formulário

```text
Texto da pergunta            [textarea, obrigatório]

Alternativas (marque a correta)
 ( ) A  [input texto]
 (•) B  [input texto]
 ( ) C  [input texto]
 ( ) D  [input texto]

[Cancelar]  [Salvar pergunta]
```

- Os inputs de alternativa usam `inputs_for :answer_options`, com campo oculto para `id` (edição) e
  para `position`.
- O radio de "correta" escreve `is_correct` como `true` na alternativa escolhida e `false` nas demais
  antes de enviar ao contexto.

### Lista de perguntas no editor

Cada item exibe: número da posição, texto da pergunta (truncado), a alternativa correta destacada e
o botão "Editar". Os controles de ordem e exclusão chegam na story F1-12.
Quando não há perguntas: "Este quiz ainda não tem perguntas" + botão "Adicionar pergunta".

## 7. Regras de negócio e validações

Todas as regras vêm do contexto (F1-07); a interface apenas as expõe:

- texto da pergunta obrigatório, 3–500 caracteres;
- quatro alternativas obrigatórias, cada uma com 1–200 caracteres;
- exatamente uma alternativa correta;
- alternativas não podem ter textos repetidos (comparação com `trim`, case-insensitive);
- máximo de 50 perguntas por quiz — ao atingir o limite, o botão "Adicionar pergunta" fica
  desabilitado com a explicação "Limite de 50 perguntas atingido";
- pergunta criada entra sempre no fim da lista;
- editar uma pergunta não altera sua posição;
- somente o dono acessa os modais; caso contrário, 404.

## 8. Critérios de aceite

```gherkin
Cenário: Adicionar a primeira pergunta
  Dado que estou no editor de um quiz meu sem perguntas
  Quando clico em "Adicionar pergunta"
  Então um modal é aberto e a URL passa a ser "/quizzes/:id/questions/new"
  Quando preencho o texto, as 4 alternativas e marco a alternativa B como correta
  E clico em "Salvar pergunta"
  Então o modal fecha
  E a pergunta aparece na lista como número 1
  E vejo a mensagem "Pergunta adicionada"

Cenário: Perguntas entram no fim da lista
  Dado um quiz meu com 2 perguntas
  Quando adiciono uma nova pergunta
  Então ela aparece como número 3

Cenário: Salvar sem marcar a correta
  Dado que o modal de nova pergunta está aberto
  Quando preencho tudo mas não marco nenhuma alternativa como correta
  E tento salvar
  Então vejo a mensagem "marque a alternativa correta"
  E o modal continua aberto com o que eu havia digitado
  E nenhuma pergunta é criada

Cenário: Alternativa em branco
  Quando deixo a alternativa C vazia e tento salvar
  Então vejo o erro de obrigatoriedade na alternativa C
  E nenhuma pergunta é criada

Cenário: Alternativas repetidas
  Quando informo "Brasil" na alternativa A e "brasil" na alternativa D
  E tento salvar
  Então vejo a mensagem "as alternativas não podem ter textos repetidos"
  E nenhuma pergunta é criada

Cenário: Texto da pergunta muito curto
  Quando informo um texto de 2 caracteres e tento salvar
  Então vejo a mensagem de tamanho mínimo
  E nenhuma pergunta é criada

Cenário: Editar pergunta existente
  Dada uma pergunta minha com a alternativa B correta
  Quando clico em "Editar" nessa pergunta
  Então o modal abre preenchido com o texto e as 4 alternativas
  E a alternativa B aparece marcada como correta
  Quando altero o texto e marco a alternativa D como correta e salvo
  Então a lista exibe o novo texto
  E a alternativa correta passa a ser a D
  E a pergunta permanece na mesma posição

Cenário: Cancelar edição
  Dado que o modal de edição está aberto com alterações não salvas
  Quando clico em "Cancelar"
  Então o modal fecha
  E a pergunta permanece como estava

Cenário: Limite de perguntas
  Dado um quiz meu com 50 perguntas
  Quando abro o editor
  Então o botão "Adicionar pergunta" está desabilitado
  E vejo a explicação de limite atingido

Cenário: Pergunta de quiz alheio
  Quando tento abrir "/quizzes/<id_do_bruno>/questions/<id>/edit"
  Então recebo a página de erro 404
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/live/quiz_live/editor_test.exs`

- editor lista as perguntas ordenadas por posição, com a alternativa correta destacada;
- empty state quando o quiz não tem perguntas;
- abrir `/quizzes/:id/questions/new` renderiza o modal com 4 campos de alternativa vazios;
- salvar pergunta válida cria a pergunta, fecha o modal, atualiza a lista e exibe flash;
- cada caso inválido (sem correta, alternativa vazia, textos repetidos, pergunta curta, pergunta
  longa) mantém o modal aberto, exibe a mensagem correta e não persiste nada;
- `phx-change` exibe erros sem submeter;
- abrir modal de edição carrega os valores atuais e marca a alternativa correta;
- salvar edição atualiza texto e alternativa correta, preservando a posição e os ids das alternativas;
- cancelar fecha o modal sem alterar dados;
- com 50 perguntas, o botão de adicionar está desabilitado; o acesso direto a
  `/quizzes/:id/questions/new` redireciona para o editor com o flash de limite; e um `save` que
  receba `{:error, :question_limit_reached}` exibe o flash sem quebrar a tela;
- acesso a modal de pergunta de outro usuário levanta `Ecto.NoResultsError`.

## 10. Definition of Ready

- [x] Contexto de perguntas disponível (F1-07).
- [x] Editor de quiz existente com título e descrição (F1-10).
- [x] Regra de 4 alternativas fixas e radio para a correta definida.
- [x] Textos das mensagens de erro definidos (F1-07, item 6).

## 11. Definition of Done

- [ ] Criação e edição de perguntas funcionando ponta a ponta pela interface.
- [ ] Nenhuma validação duplicada na LiveView — todas vêm do changeset do contexto.
- [ ] Modal preserva os dados digitados quando a validação falha.
- [ ] Radio group impede marcar duas corretas na interface.
- [ ] Acessibilidade básica: labels nos campos, `fieldset`/`legend` no grupo de alternativas, foco no
      primeiro erro, modal fechável por Esc.
- [ ] Layout utilizável a partir de 375px.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-07** — funções de contexto de pergunta.
- **F1-10** — página do editor e rota `/quizzes/:id/edit`.

## 13. Riscos e pontos de atenção

- `inputs_for` com `cast_assoc` exige que os `id` e `position` das alternativas trafeguem no
  formulário; sem isso, a edição recria os registros.
- O radio de "correta" precisa converter a seleção em `is_correct` para as quatro alternativas antes
  de chamar o contexto; enviar apenas a marcada deixa as outras com o valor antigo.
- Erros de conjunto (correta ausente, textos repetidos) ficam no changeset **pai**: exibi-los apenas
  nos campos filhos faz o usuário não ver a mensagem — renderizar também um bloco de erro no topo do modal.
- Modal com formulário longo em telas pequenas precisa de rolagem interna.

## 14. Estimativa

**8 pontos** — formulário aninhado, muitos estados de erro e a tela mais complexa da fase.
