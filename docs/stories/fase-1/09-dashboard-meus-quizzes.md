# [F1-09] Dashboard "Meus quizzes" com paginação, busca e contagem

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `frontend`
> **Branch:** `feature/09-dashboard-meus-quizzes` · **Estimativa:** 5 pontos · **Depende de:** F1-06

## 1. Contexto de negócio

O dashboard é a primeira tela que o usuário autenticado vê e o ponto de partida de todo o trabalho
na plataforma. É onde ele encontra o que já produziu, avalia o que está pronto para jogar e decide
o próximo passo: criar, editar ou excluir um quiz.

## 2. User story

**Como** usuário autenticado,
**quero** ver a lista dos meus quizzes com suas informações principais e conseguir pesquisá-los,
**para que** eu localize rapidamente o quiz em que quero trabalhar.

## 3. Escopo

### Dentro
- LiveView `/quizzes` listando os quizzes do usuário.
- Colunas: título, descrição, quantidade de perguntas, data de criação e indicador "pronto para jogar".
- Busca por título com estado refletido na URL.
- Paginação de 20 itens por página, também refletida na URL.
- Empty state com chamada para criar o primeiro quiz.
- Botão "Criar quiz" e ação "Editar" (links). **O botão "Excluir" não é renderizado nesta story** — ele chega junto do seu handler, na F1-10.

### Fora
- Criação, edição e exclusão em si (story F1-10).
- Editor de perguntas (stories F1-11 e F1-12).
- Ordenação por coluna, filtros avançados, seleção múltipla.

## 4. Decisões de arquitetura

- **`handle_params` como fonte da verdade** para `page` e `search`: a URL descreve o estado da tela,
  permitindo compartilhar e recarregar o link e fazendo o botão voltar funcionar.
- **Busca com `push_patch` e debounce de 300ms**, evitando uma consulta por tecla digitada.
- **Toda a filtragem e paginação no servidor**, via `Quizzes.list_quizzes/2` — a LiveView não filtra
  listas em memória nem acessa o `Repo`.
- **Contagem de perguntas vinda da própria query de listagem** (`questions_count`), sem consulta
  adicional por linha.
- **Indicador "pronto para jogar"** derivado de `questions_count > 0`, coerente com `playable?/1` (AD-09).
- Tabela em telas largas e cards empilhados em telas estreitas, usando os componentes do Phoenix 1.8.

## 5. Modelo de dados e migrations

Nenhuma. Consome `LiveQuiz.Quizzes.list_quizzes/2` (story F1-06).

## 6. Contratos técnicos

### Rota

```elixir
live "/quizzes", QuizLive.Index, :index
```

Dentro da `live_session :authenticated` criada na story F1-04.

### Módulo

`lib/live_quiz_web/live/quiz_live/index.ex` — `LiveQuizWeb.QuizLive.Index`

Assigns:

| Assign | Conteúdo |
|---|---|
| `:page` | mapa retornado por `list_quizzes/2` (`entries`, `page`, `per_page`, `total_entries`, `total_pages`) |
| `:search` | termo atual da busca (string, pode ser vazia) |
| `:page_title` | "Meus quizzes" |

Eventos:

| Evento | Origem | Efeito |
|---|---|---|
| `"search"` | form de busca com `phx-change` e `phx-debounce="300"` | `push_patch` para `/quizzes?search=<termo>` (volta para a página 1) |
| `"clear_search"` | botão limpar | `push_patch` para `/quizzes` |

`handle_params/3` lê `page` e `search` da URL, chama `Quizzes.list_quizzes(socket.assigns.current_scope, page: ..., per_page: 20, search: ...)` e atribui o resultado.

### Componentes de tela

- Cabeçalho com título "Meus quizzes" e botão primário "Criar quiz" (link para `/quizzes/new`, implementado na F1-10).
- Campo de busca com placeholder "Buscar por título" e botão de limpar quando houver termo.
- Tabela/lista com as colunas descritas no escopo e a ação "Editar" (link para `/quizzes/:id/edit`).
- Paginação: "Anterior"/"Próxima" e indicação "Página X de Y"; oculta quando `total_pages <= 1`.
- Empty states distintos:
  - sem nenhum quiz: "Você ainda não criou nenhum quiz" + botão "Criar quiz";
  - busca sem resultado: "Nenhum quiz encontrado para \"<termo>\"" + botão "Limpar busca".
- Datas formatadas como `dd/mm/aaaa`.

## 7. Regras de negócio e validações

- A lista contém exclusivamente quizzes cujo `owner_id` é o do usuário autenticado.
- Ordenação padrão: `updated_at` decrescente.
- `page` inválida (não numérica, menor que 1 ou acima do total) recai no comportamento definido em
  F1-06, sem erro de tela.
- Busca é case-insensitive e ignora espaços nas pontas; termo vazio equivale a não filtrar.
- Alterar a busca reinicia a paginação na página 1.
- Descrição vazia é exibida como "—".
- Datas exibidas no formato `dd/mm/aaaa`, convertidas de UTC para `America/Sao_Paulo` pelo helper
  `LiveQuizWeb.Formatters.format_date/1` (story F1-05).

## 8. Critérios de aceite

```gherkin
Cenário: Lista com meus quizzes
  Dado que estou autenticado e possuo 3 quizzes
  Quando acesso "/quizzes"
  Então vejo os 3 quizzes com título, descrição, quantidade de perguntas e data de criação

Cenário: Não vejo quizzes de outras pessoas
  Dado que Bruno possui quizzes
  Quando eu, Ana, acesso "/quizzes"
  Então nenhum quiz de Bruno é exibido

Cenário: Contagem de perguntas
  Dado um quiz meu com 5 perguntas
  Quando acesso "/quizzes"
  Então esse quiz exibe "5 perguntas"

Cenário: Indicador de quiz jogável
  Dado um quiz meu sem perguntas e outro com 2 perguntas
  Quando acesso "/quizzes"
  Então o primeiro aparece como "Incompleto"
  E o segundo aparece como "Pronto para jogar"

Cenário: Estado vazio
  Dado que ainda não criei nenhum quiz
  Quando acesso "/quizzes"
  Então vejo a mensagem de que ainda não criei quizzes
  E vejo o botão "Criar quiz"

Cenário: Busca por título
  Dado que possuo os quizzes "Geografia" e "História"
  Quando digito "geo" no campo de busca
  Então a lista exibe apenas "Geografia"
  E a URL passa a conter "search=geo"

Cenário: Busca sem resultados
  Quando busco por "xyz" e nenhum quiz corresponde
  Então vejo a mensagem de nenhum resultado
  E vejo a opção de limpar a busca

Cenário: Paginação
  Dado que possuo 25 quizzes
  Quando acesso "/quizzes"
  Então vejo 20 quizzes e a indicação "Página 1 de 2"
  E ao clicar em "Próxima" vejo os 5 restantes e a URL contém "page=2"

Cenário: Estado compartilhável
  Dado que estou na página 2 com a busca "geo"
  Quando recarrego a URL atual
  Então a mesma busca e a mesma página são exibidas
```

## 9. Cenários de teste

Arquivo: `test/live_quiz_web/live/quiz_live/index_test.exs`

- exige autenticação (usuário deslogado é redirecionado);
- renderiza os quizzes do usuário e não os de outro usuário;
- exibe `questions_count` e o indicador de jogável corretamente;
- exibe o empty state quando não há quizzes;
- busca filtra a lista e atualiza a URL (`assert_patch`);
- busca sem resultados exibe a mensagem específica e o botão de limpar;
- limpar a busca restaura a lista completa;
- paginação exibe 20 itens, navega para a página 2 e reflete na URL;
- acessar diretamente `/quizzes?page=2&search=geo` renderiza o estado correspondente;
- alterar a busca volta para a página 1.

## 10. Definition of Ready

- [x] `list_quizzes/2` com paginação, busca e contagem disponível (F1-06).
- [x] Layout autenticado e proteção de rotas disponíveis (F1-04).
- [x] Colunas, empty states e formato de data definidos.

## 11. Definition of Done

- [ ] LiveView implementada com estado na URL via `handle_params`.
- [ ] Nenhuma chamada ao `Repo` dentro da LiveView.
- [ ] Layout utilizável a partir de 375px de largura.
- [ ] Acessibilidade básica: campo de busca com label, tabela com cabeçalhos, links com texto descritivo.
- [ ] Todos os cenários de teste do item 9 passando.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-06** — contexto de listagem.
- **F1-04** — rota autenticada e layout.
- O link "Criar quiz" aponta para `/quizzes/new`, rota criada na **F1-10**. Para que esta story seja
  mergeável isoladamente, o botão deve ser renderizado como desabilitado enquanto a rota não existir,
  ou a F1-10 deve ser mergeada logo em seguida. **Nunca** renderize um `phx-click` sem
  `handle_event` correspondente: em LiveView isso derruba o processo, não gera apenas um link quebrado.

## 13. Riscos e pontos de atenção

- Sem debounce, a busca dispara uma query por tecla; o `phx-debounce` é obrigatório.
- Cuidado para não perder o termo de busca ao navegar entre páginas (ambos vivem na URL).
- Formatação de data deve usar o helper de fuso da F1-05; formatar direto de `inserted_at` (UTC) exibe a data errada após as 21h de Brasília.

## 14. Estimativa

**5 pontos** — tela com três estados (lista, vazio, sem resultado), busca e paginação sincronizadas na URL.
