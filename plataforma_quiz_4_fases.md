# Plataforma de Quiz em Tempo Real — Plano de Implementação em 4 Fases

## 1. Objetivo do projeto

Construir uma plataforma web de quizzes em tempo real, inspirada em produtos como o Kahoot, utilizando:

- **Elixir**
- **Phoenix**
- **Phoenix LiveView** para a aplicação web
- **Phoenix Controllers / JSON API** para permitir futuramente o consumo por aplicativos mobile
- **PostgreSQL** como banco de dados
- **WebSockets / Phoenix PubSub** para comunicação em tempo real

O sistema permitirá que uma pessoa crie e conduza uma sessão de quiz enquanto outras pessoas entram na sessão utilizando um código e respondem às perguntas em tempo real.

O projeto será desenvolvido em **exatamente 4 fases**, cada uma representando uma sprint.

### Regra fundamental das fases

Cada fase precisa entregar uma **funcionalidade de negócio completa e utilizável**, envolvendo obrigatoriamente:

1. alteração real no **banco de dados**;
2. implementação de regras/contextos no **backend**;
3. implementação de comportamento/telas no **frontend**.

**Autenticação não é uma funcionalidade de sprint.**

Login, logout, recuperação/reset de senha, cadastro de usuário, sessão e autorização fazem parte do **core técnico da aplicação** e devem estar implementados na primeira fase para suportar as funcionalidades de negócio seguintes.

---

# 2. Visão geral das 4 fases

| Fase | Funcionalidade de negócio | Resultado ao final da fase |
|---|---|---|
| **1** | Criação e gerenciamento de quizzes | Usuário autenticado consegue criar um quiz completo com perguntas e alternativas |
| **2** | Sala de quiz e lobby em tempo real | Usuário consegue abrir um quiz em uma sala e participantes conseguem entrar por código |
| **3** | Execução do quiz em tempo real | Host consegue conduzir perguntas e participantes conseguem responder com sincronização em tempo real |
| **4** | Pontuação, ranking e histórico de partidas | Partida possui pontuação, ranking em tempo real e resultado/histórico persistido |

A progressão foi pensada para que cada sprint seja demonstrável isoladamente:

- **Sprint 1:** existe um produto para criar quizzes.
- **Sprint 2:** existe uma experiência multiplayer de entrada em uma sala.
- **Sprint 3:** existe efetivamente um quiz multiplayer jogável.
- **Sprint 4:** existe competição completa, com pontuação, ranking e histórico.

---

# 3. Fase 1 — Criação e gerenciamento de quizzes

## 3.1 Objetivo

Entregar o primeiro contexto de negócio da aplicação: **o gerenciamento de quizzes**.

Ao final da fase, um usuário autenticado deverá conseguir:

- criar um quiz;
- informar título e descrição;
- adicionar perguntas;
- adicionar alternativas;
- definir a alternativa correta;
- editar perguntas e alternativas;
- remover perguntas;
- remover alternativas;
- visualizar seus quizzes;
- editar informações do quiz;
- excluir um quiz.

Ainda não existe multiplayer nesta fase.

O objetivo é estabelecer o núcleo de conteúdo sobre o qual as demais fases serão construídas.

---

## 3.2 Banco de dados

### Tabelas principais

#### `users`

Tabela de usuários da aplicação.

Campos conceituais:

- `id`
- `name`
- `email`
- `hashed_password`
- timestamps

A estrutura pode ser baseada no sistema de autenticação escolhido para Phoenix.

#### `quizzes`

Representa um quiz criado por um usuário.

Campos:

- `id`
- `owner_id` — FK para `users`
- `title`
- `description`
- timestamps

Relacionamento:

```text
users 1 ───── N quizzes
```

#### `questions`

Representa uma pergunta pertencente a um quiz.

Campos:

- `id`
- `quiz_id` — FK para `quizzes`
- `text`
- `position`
- timestamps

`position` permite preservar a ordem das perguntas.

Relacionamento:

```text
quizzes 1 ───── N questions
```

#### `answer_options`

Representa uma alternativa de uma pergunta.

Campos:

- `id`
- `question_id` — FK para `questions`
- `text`
- `position`
- `is_correct`
- timestamps

Relacionamento:

```text
questions 1 ───── N answer_options
```

### Integridade

O banco deverá possuir:

- foreign keys;
- índices nas foreign keys;
- `NOT NULL` nos campos obrigatórios;
- constraints coerentes para evitar estados inválidos;
- ordenação por `position`.

Deve ser considerada a regra de negócio de que uma pergunta precisa possuir pelo menos uma alternativa correta e que uma alternativa pertence a exatamente uma pergunta.

### Exclusão

Deve ser definido comportamento de exclusão em cascata:

```text
quiz
 └── questions
      └── answer_options
```

Ao excluir um quiz, suas perguntas e alternativas não podem permanecer órfãs.

---

## 3.3 Backend

### Contextos

Sugestão de separação utilizando os contextos do Phoenix:

```text
Accounts
Quiz
```

`Accounts` representa o core de autenticação.

`Quiz` concentra:

- criação de quizzes;
- consulta;
- atualização;
- exclusão;
- criação/edição/exclusão de perguntas;
- criação/edição/exclusão de alternativas.

### Casos de uso

O backend deverá expor operações equivalentes a:

```text
create_quiz/2
get_quiz!/2
list_user_quizzes/1
update_quiz/3
delete_quiz/2

create_question/2
update_question/3
delete_question/2

create_answer_option/2
update_answer_option/3
delete_answer_option/2
```

Os nomes são apenas sugestivos; a modelagem final deve seguir as convenções do projeto.

### Regras de negócio

O backend deverá validar:

- usuário autenticado é o proprietário do quiz;
- título obrigatório;
- pergunta pertence ao quiz correto;
- alternativa pertence à pergunta correta;
- `position` não pode gerar ordem inválida;
- somente o proprietário pode alterar seu quiz;
- somente o proprietário pode excluir seu quiz;
- uma pergunta não pode possuir múltiplas alternativas marcadas como corretas caso o modo escolhido seja de resposta única.

### Transações

Operações compostas deverão utilizar transações quando necessário.

Exemplo:

```text
criar quiz
  ├── criar perguntas
  │    ├── criar alternativas
  │    └── ...
  └── ...
```

Se a aplicação permitir salvar um quiz inteiro de uma vez, a operação deve ser atômica.

### API REST

Embora o frontend utilize LiveView, os casos de uso devem ser estruturados de maneira que possam ser reutilizados pelos controllers JSON.

Exemplos conceituais:

```http
GET    /api/quizzes
POST   /api/quizzes
GET    /api/quizzes/:id
PUT    /api/quizzes/:id
DELETE /api/quizzes/:id
```

E posteriormente:

```http
POST   /api/quizzes/:quiz_id/questions
PUT    /api/questions/:id
DELETE /api/questions/:id
```

A API não precisa necessariamente ser o foco principal da UI nesta sprint, mas a camada de domínio não deve ficar acoplada ao LiveView.

---

## 3.4 Frontend

### Autenticação

Como parte do core da aplicação, a primeira fase deverá conter:

- tela de cadastro;
- tela de login;
- logout;
- recuperação de senha;
- redefinição de senha;
- proteção de rotas/páginas autenticadas;
- manutenção da sessão.

Esses itens **não constituem uma funcionalidade de negócio da sprint**.

### Dashboard

Criar uma página inicial autenticada contendo:

- lista de quizzes criados;
- título;
- descrição;
- quantidade de perguntas;
- data de criação;
- ações de editar;
- ação de excluir;
- botão "Criar quiz".

### Editor de quiz

Criar interface para:

1. informar título;
2. informar descrição;
3. adicionar pergunta;
4. adicionar alternativas;
5. marcar alternativa correta;
6. ordenar perguntas;
7. ordenar alternativas;
8. editar;
9. remover;
10. salvar.

Um fluxo possível:

```text
Quiz
 ├── Pergunta 1
 │    ├── Alternativa A
 │    ├── Alternativa B ✓
 │    ├── Alternativa C
 │    └── Alternativa D
 │
 ├── Pergunta 2
 │    ├── Alternativa A
 │    ├── Alternativa B
 │    └── Alternativa C ✓
```

### UX

O LiveView pode proporcionar:

- adição dinâmica de perguntas;
- adição dinâmica de alternativas;
- validação sem reload;
- atualização da lista após salvar;
- confirmação antes de exclusão;
- mensagens de erro;
- estados de loading.

### Critério de conclusão

A fase está concluída quando um usuário consegue criar e manter um quiz completo sem qualquer intervenção manual no banco.

---

# 4. Fase 2 — Sala de quiz e lobby em tempo real

## 4.1 Objetivo

Transformar o conteúdo criado na fase anterior em uma **experiência multiplayer inicial**.

O usuário poderá selecionar um quiz e criar uma sessão/sala.

Um host terá uma sala aberta e participantes poderão entrar utilizando um código.

Ao final da fase, ainda não é necessário executar perguntas. O objetivo é entregar o conceito completo de:

> **quiz + partida + sala + participantes + lobby em tempo real**

---

## 4.2 Banco de dados

### `game_sessions`

Representa uma execução específica de um quiz.

Campos:

- `id`
- `quiz_id`
- `host_id`
- `join_code`
- `status`
- `started_at`
- `finished_at`
- timestamps

Possíveis estados:

```text
waiting
in_progress
finished
cancelled
```

Nesta fase, o estado principal utilizado será `waiting`.

Relacionamentos:

```text
users 1 ───── N game_sessions
quizzes 1 ───── N game_sessions
```

Importante: uma sessão é diferente do quiz.

O quiz representa o **conteúdo reutilizável**.

A sessão representa uma **execução específica daquele conteúdo**.

### `participants`

Representa uma pessoa que entrou em uma sessão.

Campos:

- `id`
- `game_session_id`
- `user_id` — opcional, caso seja permitido participante anônimo
- `nickname`
- `joined_at`
- `left_at`
- timestamps

Relacionamentos:

```text
game_sessions 1 ───── N participants
users         1 ───── N participants
```

A possibilidade de `user_id` ser nulo permite que o jogador participe sem criar uma conta.

### Índices e constraints

Criar:

- índice em `join_code`;
- índice em `game_session_id`;
- índice em `user_id` quando aplicável;
- unicidade do código enquanto a sessão estiver ativa, conforme estratégia escolhida;
- proteção contra nickname duplicado dentro da mesma sessão, se essa for a regra definida.

---

## 4.3 Backend

### Novo contexto

Criar um contexto específico:

```text
Game
```

Responsável por:

- criar sessões;
- gerar códigos;
- consultar sessão por código;
- entrar na sessão;
- remover participante;
- listar participantes;
- alterar estado da sessão.

### Casos de uso

Exemplos:

```text
create_game_session/2
get_game_session!/1
get_game_session_by_code/1
join_game_session/2
leave_game_session/2
list_participants/1
start_game_session/2
cancel_game_session/2
```

### Geração do código

O código deverá ser:

- curto;
- fácil de digitar;
- suficientemente imprevisível;
- não conflitante com outra sessão ativa.

Exemplo:

```text
K7P4Q
```

A geração deve ser validada contra o banco.

### Autorização

Regras:

- somente o host pode iniciar a sessão;
- somente o host pode cancelar a sessão;
- participantes não podem alterar a sessão;
- uma sessão encerrada não aceita novos participantes;
- uma sessão em andamento não deve permitir entrada, salvo regra explícita definida posteriormente.

### Tempo real

O backend deverá utilizar:

- Phoenix PubSub;
- Channels e/ou LiveView PubSub, conforme arquitetura escolhida.

Cada sessão deverá possuir um tópico lógico:

```text
game_session:<session_id>
```

Eventos possíveis:

```text
participant_joined
participant_left
game_started
game_cancelled
```

Ao entrar uma pessoa:

```text
Banco
  ↓
Participant criado
  ↓
PubSub.broadcast
  ↓
LiveViews inscritos recebem evento
  ↓
Lobby é atualizado
```

### API REST

Exemplos:

```http
POST /api/game-sessions
GET  /api/game-sessions/:id
POST /api/game-sessions/:id/join
POST /api/game-sessions/:id/start
POST /api/game-sessions/:id/cancel
GET  /api/game-sessions/:id/participants
```

A API deve reutilizar o mesmo contexto `Game`.

---

## 4.4 Frontend

### Tela "Meus quizzes"

Adicionar ação:

```text
[Iniciar partida]
```

Ao clicar:

```text
Quiz selecionado
       ↓
Nova Game Session
       ↓
Lobby
```

### Tela do host

Mostrar:

- nome do quiz;
- código da sala;
- quantidade de participantes;
- lista de participantes;
- botão iniciar;
- botão cancelar.

Exemplo:

```text
┌─────────────────────────────┐
│       CÓDIGO DA SALA        │
│           K7P4Q             │
│                             │
│ Participantes: 5            │
│                             │
│ João                        │
│ Maria                       │
│ Pedro                       │
│ Ana                         │
│ Carlos                      │
│                             │
│        [ INICIAR ]          │
└─────────────────────────────┘
```

### Tela de entrada

Criar uma página pública:

```text
Entrar em uma partida

Código:
[ K7P4Q ]

Apelido:
[ João ]

[ ENTRAR ]
```

### Lobby do participante

Após entrar:

- mostrar nome do quiz;
- mostrar próprio nickname;
- mostrar mensagem de aguardando host;
- atualizar a quantidade/lista de participantes em tempo real;
- reagir ao início da partida.

### LiveView

A entrada de um participante deverá provocar atualização imediata para o host e para os demais participantes.

Não deve ser necessário:

```text
F5
```

para visualizar novas entradas.

### Critério de conclusão

A fase está concluída quando:

1. host seleciona um quiz;
2. sistema cria uma sessão persistida;
3. sistema gera um código;
4. outra pessoa acessa a aplicação;
5. informa código e nickname;
6. participante é persistido;
7. host vê o participante imediatamente;
8. demais clientes recebem a atualização;
9. host consegue iniciar a partida.

---

# 5. Fase 3 — Execução do quiz em tempo real

## 5.1 Objetivo

Entregar o núcleo mais importante da aplicação:

> **uma partida de quiz realmente jogável em tempo real.**

Ao final da sprint:

- host inicia a partida;
- sistema apresenta uma pergunta;
- participantes recebem a pergunta;
- participantes enviam respostas;
- sistema registra respostas;
- host controla avanço;
- todos os clientes acompanham o estado da partida em tempo real.

A pontuação final e ranking podem ser finalizados na fase 4, mas a estrutura de respostas deve ser persistida nesta fase.

---

## 5.2 Banco de dados

### Alteração em `game_sessions`

Adicionar campos para representar o estado atual:

- `current_question_position`
- `current_question_started_at`
- `current_question_ends_at`

Opcionalmente:

- `question_duration_seconds`

### `game_session_questions`

É recomendável criar um snapshot das perguntas utilizadas na partida.

Campos:

- `id`
- `game_session_id`
- `question_id`
- `position`
- `question_text`
- timestamps

O snapshot é importante porque o quiz original pode ser alterado posteriormente.

A partida precisa continuar utilizando exatamente o conteúdo que existia quando foi iniciada.

Estrutura:

```text
quiz
  ↓
questions

game_session
  ↓
game_session_questions
```

### `game_session_answer_options`

Snapshot das alternativas utilizadas na partida.

Campos:

- `id`
- `game_session_question_id`
- `original_answer_option_id`
- `text`
- `position`
- `is_correct`

Assim, a execução da partida fica independente de alterações futuras no quiz.

### `answers`

Representa a resposta de um participante.

Campos:

- `id`
- `game_session_id`
- `game_session_question_id`
- `participant_id`
- `game_session_answer_option_id`
- `answered_at`
- timestamps

Relacionamentos:

```text
participant
     ↓
   answer
     ↓
session_question
     ↓
session_answer_option
```

### Constraints

Criar uma constraint para impedir múltiplas respostas para a mesma pergunta pelo mesmo participante:

```text
UNIQUE(
  participant_id,
  game_session_question_id
)
```

Isso é importante tanto para integridade quanto para segurança contra chamadas duplicadas.

---

## 5.3 Backend

### Evolução do contexto `Game`

Adicionar operações:

```text
start_game_session/1
load_question/2
start_question/2
answer_question/3
close_question/2
advance_question/2
finish_game_session/1
```

### Snapshot

Ao iniciar uma sessão, o backend deve gerar o snapshot:

```text
Quiz
 ├── Question
 │    ├── Option
 │    └── Option
 └── Question
      ├── Option
      └── Option

        ↓

GameSession
 ├── GameSessionQuestion
 │    ├── GameSessionAnswerOption
 │    └── GameSessionAnswerOption
 └── GameSessionQuestion
      ├── GameSessionAnswerOption
      └── GameSessionAnswerOption
```

Essa operação deve ser transacional.

### Máquina de estados

A partida deve possuir estados claros.

Exemplo:

```text
waiting
   ↓
in_progress
   ↓
question_open
   ↓
question_closed
   ↓
question_open
   ↓
...
   ↓
finished
```

Pode ser implementada utilizando recursos idiomáticos do Elixir ou uma biblioteca de state machine, mas o domínio deve possuir regras explícitas de transição.

### Controle do host

Somente o host poderá:

- iniciar partida;
- abrir pergunta;
- encerrar pergunta;
- avançar;
- finalizar partida.

### Resposta do participante

Ao responder:

1. validar participante;
2. validar sessão;
3. validar pergunta atual;
4. validar que a pergunta está aberta;
5. validar alternativa;
6. impedir resposta duplicada;
7. persistir resposta;
8. publicar evento.

### Eventos PubSub

Exemplos:

```text
game_started
question_started
answer_submitted
question_closed
next_question
game_finished
```

Os eventos devem carregar apenas os dados necessários para os clientes.

### Concorrência

Essa fase deve tratar explicitamente concorrência.

Exemplo:

Dois participantes podem responder simultaneamente.

O sistema não pode:

- perder respostas;
- sobrescrever respostas;
- criar duas respostas para a mesma pessoa;
- aceitar respostas depois do encerramento.

A constraint do banco deve ser utilizada como última camada de proteção.

### API REST

Endpoints conceituais:

```http
POST /api/game-sessions/:id/start
POST /api/game-sessions/:id/questions/:question_id/open
POST /api/game-sessions/:id/questions/:question_id/answers
POST /api/game-sessions/:id/questions/:question_id/close
POST /api/game-sessions/:id/next
```

---

## 5.4 Frontend

### Tela do host

Durante a partida:

```text
Pergunta 2 de 10

Qual é a capital do Brasil?

[A] São Paulo
[B] Brasília
[C] Rio de Janeiro
[D] Salvador

Respostas: 17 / 25

[ENCERRAR PERGUNTA]
[PRÓXIMA]
```

O host deverá visualizar:

- pergunta atual;
- número da pergunta;
- alternativas;
- quantidade de respostas recebidas;
- estado da pergunta;
- controles da partida.

### Tela do participante

Mostrar:

```text
Pergunta 2 de 10

Qual é a capital do Brasil?

┌─────────────┐
│ São Paulo   │
└─────────────┘

┌─────────────┐
│ Brasília    │
└─────────────┘

┌─────────────┐
│ Rio Janeiro │
└─────────────┘

┌─────────────┐
│ Salvador    │
└─────────────┘
```

Após responder:

- bloquear novas respostas;
- indicar que a resposta foi registrada;
- aguardar fechamento;
- reagir ao próximo evento.

### Sincronização

Se o host abrir uma pergunta:

```text
Host LiveView
      ↓
PubSub
      ↓
Todos os participantes
      ↓
Renderização da pergunta
```

Se o host avançar:

```text
Host
 ↓
Backend
 ↓
Banco
 ↓
PubSub
 ↓
Todos os clientes
```

### Timer

Opcionalmente, nesta fase pode ser implementado timer visual para cada pergunta.

Se implementado, o **backend deve ser a autoridade sobre o tempo**, e não o JavaScript.

O frontend apenas apresenta a contagem regressiva.

### Critério de conclusão

A fase está concluída quando uma partida completa pode ser executada:

```text
Host cria partida
       ↓
Participantes entram
       ↓
Host inicia
       ↓
Pergunta 1
       ↓
Participantes respondem
       ↓
Pergunta fecha
       ↓
Pergunta 2
       ↓
...
       ↓
Última pergunta
       ↓
Partida finaliza
```

Todas as respostas devem estar persistidas no banco.

---

# 6. Fase 4 — Pontuação, ranking e histórico

## 6.1 Objetivo

Transformar a execução da fase 3 em uma experiência competitiva completa.

A sprint adicionará:

- cálculo de pontuação;
- ranking;
- classificação em tempo real;
- resultado final;
- histórico de partidas;
- consulta de resultados anteriores.

Ao final, o produto terá um ciclo completo:

```text
Criar quiz
   ↓
Abrir sala
   ↓
Participantes entram
   ↓
Jogar
   ↓
Responder
   ↓
Pontuar
   ↓
Ranking
   ↓
Resultado
   ↓
Histórico
```

---

## 6.2 Banco de dados

### Alteração em `participants`

Adicionar:

- `score`
- `correct_answers`
- `incorrect_answers`
- `final_position`

A posição final pode ser calculada ao término da partida e persistida.

### `game_results`

Representa o resultado consolidado de uma partida.

Campos:

- `id`
- `game_session_id`
- `participant_id`
- `score`
- `correct_answers`
- `incorrect_answers`
- `average_response_time`
- `final_position`
- timestamps

Relacionamentos:

```text
game_session
     ↓
game_results
     ↓
participant
```

Uma alternativa é utilizar diretamente `participants` como resultado. Entretanto, uma tabela específica de resultados cria uma separação clara entre participante durante a execução e resultado consolidado.

### Índices

Criar índices para:

- `game_session_id`;
- `participant_id`;
- `final_position`;
- `score`.

---

## 6.3 Backend

### Cálculo de pontuação

Definir uma política de pontuação.

Exemplo:

```text
Resposta correta:
    pontos_base = 1000

Bônus de velocidade:
    quanto menor o tempo,
    maior a pontuação

Resposta incorreta:
    0 pontos
```

Uma função conceitual:

```text
score = calculate_score(
  correct?,
  response_time,
  question_duration
)
```

A regra deve estar isolada do LiveView.

### Determinação da resposta correta

A informação de correção vem do snapshot:

```text
game_session_answer_options.is_correct
```

Não deve depender do quiz original.

### Ranking

Depois de cada pergunta, o sistema pode recalcular:

```text
1º João      4200
2º Maria     3900
3º Pedro     3100
4º Ana       2700
```

Critérios de desempate devem ser definidos na inception/refinamento.

Possíveis critérios:

1. maior pontuação;
2. maior quantidade de respostas corretas;
3. menor tempo total de resposta;
4. critério determinístico final.

### Atualização em tempo real

Depois de cada resposta ou encerramento de pergunta:

```text
Answer
 ↓
Score calculation
 ↓
Participant score updated
 ↓
Ranking recalculated
 ↓
PubSub
 ↓
All clients
```

### Finalização

Ao finalizar a última pergunta:

1. encerrar sessão;
2. calcular pontuação final;
3. determinar posições;
4. persistir resultados;
5. publicar evento `game_finished`.

A operação de fechamento deve ser idempotente.

### Histórico

Criar operações:

```text
list_user_game_results/1
get_game_result/2
list_quiz_game_history/2
```

Dependendo do escopo, o histórico pode ser:

- histórico do participante;
- histórico do host;
- histórico de um quiz específico.

### API REST

Exemplos:

```http
GET /api/game-sessions/:id/ranking
GET /api/game-sessions/:id/results
GET /api/users/me/game-results
GET /api/quizzes/:id/game-history
```

---

## 6.4 Frontend

### Ranking durante a partida

Após o encerramento de cada pergunta, mostrar:

```text
🏆 Ranking

1. João       4200
2. Maria      3900
3. Pedro      3100
4. Ana        2700
```

O ranking deve ser atualizado sem refresh.

### Resultado final

Ao terminar:

```text
PARTIDA FINALIZADA

🥇 João
2. Maria
3. Pedro
4. Ana

Sua posição: 2º
Sua pontuação: 3900
Acertos: 8/10

[VER DETALHES]
```

### Histórico do participante

Criar uma página:

```text
Minhas partidas

Quiz                 Data          Pontuação   Posição
-------------------------------------------------------
Elixir Fundamentals  28/08/2026   3900        2º
AWS Quiz             25/08/2026   5200        1º
Phoenix Quiz         21/08/2026   2800        5º
```

### Histórico do host

O criador do quiz poderá consultar:

- partidas realizadas;
- quantidade de participantes;
- vencedor;
- data;
- resultados.

### Detalhes

Uma página de resultado pode apresentar:

- pontuação;
- posição;
- respostas corretas;
- respostas incorretas;
- tempo médio;
- perguntas respondidas;
- evolução da pontuação.

### Critério de conclusão

A fase está concluída quando uma partida apresenta:

1. respostas persistidas;
2. pontuação calculada;
3. ranking atualizado em tempo real;
4. classificação final;
5. resultado persistido;
6. participante consegue consultar seu histórico.

---

# 7. Arquitetura de contexto sugerida

Ao final das quatro fases, uma organização possível dos contextos será:

```text
MyApp
│
├── Accounts
│   ├── User
│   ├── Registration
│   ├── Session
│   └── PasswordReset
│
├── Quiz
│   ├── Quiz
│   ├── Question
│   └── AnswerOption
│
└── Game
    ├── GameSession
    ├── Participant
    ├── GameSessionQuestion
    ├── GameSessionAnswerOption
    ├── Answer
    └── GameResult
```

A separação importante é:

```text
Quiz
 =
 conteúdo reutilizável

Game
 =
 execução do conteúdo
```

Essa distinção é fundamental para permitir que o mesmo quiz seja utilizado em várias partidas.

---

# 8. Arquitetura de tempo real

A aplicação deverá utilizar Phoenix como camada de comunicação em tempo real.

Uma estratégia possível:

```text
                   ┌───────────────┐
                   │    Browser    │
                   │    Host       │
                   └───────┬───────┘
                           │
                     LiveView
                           │
                           ▼
                    ┌────────────┐
                    │   Game     │
                    │  Context   │
                    └─────┬──────┘
                          │
                    PostgreSQL
                          │
                    PubSub broadcast
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
       Participant A            Participant B
          LiveView                 LiveView
```

O ponto central é que **o banco de dados representa o estado persistente**, enquanto **PubSub distribui as mudanças para os clientes conectados**.

O PubSub não deve ser tratado como banco de dados.

---

# 9. Princípios arquiteturais para todas as fases

## 9.1 Domínio independente da interface

As regras de negócio devem estar nos contextos Elixir.

Evitar:

```text
LiveView
  ↓
Repo diretamente
```

Preferir:

```text
LiveView
   ↓
Context
   ↓
Schema / Changeset
   ↓
Repo
```

E para API:

```text
Controller
   ↓
Context
   ↓
Schema / Changeset
   ↓
Repo
```

Assim:

```text
LiveView ──┐
           ├──> Context ──> Ecto ──> PostgreSQL
API ───────┘
```

---

## 9.2 Backend como autoridade

Especialmente nas fases 3 e 4:

- frontend não decide se uma resposta é válida;
- frontend não decide a pontuação;
- frontend não decide se uma pergunta está aberta;
- frontend não decide quando a partida terminou;
- frontend não deve ser a autoridade do timer.

O cliente apenas solicita ações.

O backend valida e altera o estado.

---

## 9.3 Banco como última camada de integridade

Regras importantes também devem ser protegidas por:

- foreign keys;
- unique constraints;
- check constraints quando aplicável;
- índices;
- transações.

Validação no backend não substitui integridade no banco.

---

# 10. Estratégia de API REST

Embora a aplicação web seja construída com LiveView, os contextos não devem depender de LiveView.

A arquitetura deve permitir:

```text
                     ┌── Phoenix LiveView
                     │
Domain Context ──────┤
                     │
                     └── Phoenix JSON API
                              │
                              ▼
                         Mobile App
```

A API deve ser adicionada progressivamente nas fases, conforme os contextos de negócio surgirem.

Não é necessário criar uma API artificialmente completa antes de existir domínio para ela.

---

# 11. Testes por fase

Cada sprint deve possuir testes relacionados à funcionalidade entregue.

## Fase 1

### Backend

Testar:

- criação de quiz;
- edição;
- exclusão;
- criação de pergunta;
- criação de alternativas;
- autorização do proprietário;
- validações;
- transações.

### Frontend

Testar:

- criação;
- edição;
- validações;
- navegação;
- exclusão.

---

## Fase 2

Testar:

- criação de sessão;
- geração de código;
- entrada;
- nickname duplicado;
- entrada em sessão encerrada;
- autorização do host;
- broadcast de participante;
- início da sessão.

---

## Fase 3

Testar:

- snapshot;
- abertura de pergunta;
- resposta;
- resposta duplicada;
- resposta fora do período;
- avanço;
- encerramento;
- concorrência;
- eventos PubSub.

---

## Fase 4

Testar:

- cálculo de pontuação;
- ranking;
- desempates;
- persistência do resultado;
- finalização idempotente;
- histórico;
- eventos de ranking.

---

# 12. Definição de pronto por sprint

## Sprint 1 — Quiz

A sprint está pronta quando:

- [ ] autenticação está funcionando;
- [ ] usuário consegue criar quiz;
- [ ] usuário consegue adicionar perguntas;
- [ ] usuário consegue adicionar alternativas;
- [ ] usuário consegue definir respostas corretas;
- [ ] dados estão persistidos;
- [ ] usuário consegue editar;
- [ ] usuário consegue excluir;
- [ ] API inicial está disponível;
- [ ] testes principais existem.

## Sprint 2 — Sala

A sprint está pronta quando:

- [ ] quiz pode gerar uma sessão;
- [ ] sessão possui código;
- [ ] participante entra por código;
- [ ] participante é persistido;
- [ ] host vê participantes;
- [ ] atualização é em tempo real;
- [ ] host pode iniciar;
- [ ] host pode cancelar;
- [ ] API de sessão está disponível;
- [ ] testes principais existem.

## Sprint 3 — Jogo

A sprint está pronta quando:

- [ ] sessão cria snapshot;
- [ ] host inicia partida;
- [ ] pergunta é transmitida;
- [ ] participante responde;
- [ ] resposta é persistida;
- [ ] respostas duplicadas são bloqueadas;
- [ ] host controla avanço;
- [ ] todos os clientes são sincronizados;
- [ ] partida chega ao fim;
- [ ] API de execução está disponível;
- [ ] testes principais existem.

## Sprint 4 — Ranking

A sprint está pronta quando:

- [ ] pontuação é calculada;
- [ ] ranking é atualizado;
- [ ] ranking é transmitido em tempo real;
- [ ] posição final é calculada;
- [ ] resultado é persistido;
- [ ] tela de resultado existe;
- [ ] histórico existe;
- [ ] API de resultados existe;
- [ ] testes principais existem.

---

# 13. Fluxo completo após as 4 fases

```text
                    AUTENTICAÇÃO
                         │
                         ▼
                  ┌─────────────┐
                  │  Dashboard  │
                  └──────┬──────┘
                         │
                  Criar/editar quiz
                         │
                         ▼
                  ┌─────────────┐
                  │    Quiz     │
                  │  Perguntas  │
                  │ Alternativas│
                  └──────┬──────┘
                         │
                    Iniciar jogo
                         │
                         ▼
                  ┌─────────────┐
                  │ Game Session│
                  │    Lobby    │
                  └──────┬──────┘
                         │
                  Participantes
                         │
                         ▼
                  ┌─────────────┐
                  │    Jogo     │
                  │  Pergunta   │
                  │   Resposta  │
                  └──────┬──────┘
                         │
                    Pontuação
                         │
                         ▼
                  ┌─────────────┐
                  │   Ranking   │
                  └──────┬──────┘
                         │
                    Finalização
                         │
                         ▼
                  ┌─────────────┐
                  │  Resultado  │
                  │  Histórico  │
                  └─────────────┘
```

---

# 14. Pontos que devem ser refinados durante a inception

Este documento propositalmente funciona como **matéria-prima**, e não como especificação definitiva.

Durante a inception, os seguintes pontos devem ser decididos:

### Quiz

- Uma pergunta pode ter uma ou várias respostas corretas?
- Existem tipos diferentes de pergunta?
- Existe limite de alternativas?
- Existe limite de perguntas?
- Quiz pode ser público/privado?
- Quiz pode ser duplicado?
- Quiz pode ser publicado/despublicado?

### Participantes

- Participante precisa de conta?
- Nickname pode se repetir?
- O participante pode reconectar?
- O participante pode trocar de nickname?
- Existe limite de participantes?

### Partida

- Quanto tempo cada pergunta fica aberta?
- Host pode pausar?
- Host pode voltar para uma pergunta anterior?
- O que acontece se o host perder conexão?
- O que acontece se um participante perder conexão?

### Pontuação

- Pontuação depende da velocidade?
- Existe bônus?
- Como funciona empate?
- Resposta errada perde pontos?
- Resposta em branco pontua?
- Ranking aparece depois de toda pergunta ou apenas no final?

### Tempo real

- Qual é a estratégia de reconexão?
- O estado da partida será recuperado após reconnect?
- Como tratar eventos perdidos?
- O servidor será sempre a fonte de verdade?

### API

- Como será autenticação mobile?
- JWT ou sessão/token?
- Versionamento (`/api/v1`)?
- Paginação?
- Rate limiting?
- Formato padrão de erros?

---

# 15. Resumo executivo

A divisão proposta evita que as quatro sprints sejam apenas divisões técnicas como "backend", "frontend" ou "WebSocket".

Cada sprint adiciona um **contexto de negócio observável**:

```text
FASE 1
"Eu consigo criar um quiz."
        ↓
FASE 2
"Eu consigo abrir uma sala e receber jogadores."
        ↓
FASE 3
"Eu consigo jogar o quiz em tempo real."
        ↓
FASE 4
"Eu consigo competir, ver minha pontuação e consultar meus resultados."
```

Essa estrutura também cria uma progressão técnica interessante para um projeto acadêmico em Elixir/Phoenix:

```text
Fase 1
Ecto + Contexts + LiveView + Auth
        ↓
Fase 2
Domínio multiplayer + PubSub
        ↓
Fase 3
Estado distribuído + concorrência + tempo real
        ↓
Fase 4
Processamento de eventos + ranking + persistência de resultados
```

O resultado final é uma aplicação pequena o suficiente para ser desenvolvida em um TCC, mas com complexidade suficiente para demonstrar conceitos relevantes de Elixir e Phoenix, especialmente **processos concorrentes, comunicação em tempo real, PubSub, modelagem de domínio, persistência transacional e separação entre interface web e API**.
