# [F1-07] Contexto `Quizzes`: criar e editar pergunta com 4 alternativas

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `backend`
> **Branch:** `feature/07-contexto-perguntas` · **Estimativa:** 5 pontos · **Depende de:** F1-06

## 1. Contexto de negócio

A pergunta é o coração do quiz: é ela que será exibida aos participantes e é sua alternativa correta
que definirá o acerto nas fases 3 e 4. Uma pergunta pela metade — sem alternativas ou sem resposta
correta — tornaria a partida impossível. Por isso a pergunta é tratada como uma **unidade
transacional**: ou nasce completa e válida, ou não nasce.

## 2. User story

**Como** usuário autenticado dono de um quiz,
**quero** adicionar e editar perguntas com quatro alternativas e indicar qual é a correta,
**para que** meu quiz tenha conteúdo pronto para ser jogado.

## 3. Escopo

### Dentro
- `create_question/3` e `update_question/3` no contexto `LiveQuiz.Quizzes`.
- Criação automática das 4 alternativas (posições 1 a 4) junto com a pergunta, em transação.
- Cálculo automático da `position` da nova pergunta (última + 1).
- Validações de conjunto: 4 alternativas, exatamente 1 correta, textos não duplicados.
- Limite de 50 perguntas por quiz.
- `change_question/2` para uso nos formulários.
- Testes de contexto.

### Fora
- Exclusão e reordenação de perguntas (story F1-08).
- Telas (F1-11) e endpoints (F1-15).
- CRUD independente de alternativas — elas não são criadas nem removidas isoladamente (AD-05).

## 4. Decisões de arquitetura

- **A pergunta é a unidade transacional** (AD-11): pergunta e suas 4 alternativas são gravadas com
  `Ecto.Multi` / `Repo.transaction`. Falha em qualquer parte desfaz tudo.
- **Quatro alternativas fixas** (AD-05): não existem operações de adicionar ou remover alternativa.
  `create_question/3` sempre cria 4 registros com `position` 1..4 (rótulos A–D são apresentação).
- **`cast_assoc(:answer_options)`** no changeset da pergunta, com validação de conjunto aplicada
  sobre o changeset pai (quantidade, correta única, duplicidade de texto).
- **Posição calculada no servidor**, nunca recebida do cliente na criação.
- **Escopo por dono**: as funções recebem `scope` e o quiz/pergunta já resolvidos por
  `get_quiz!/2` — a pergunta é sempre buscada com join no quiz do dono (AD-10).
- **Índice único parcial como rede de segurança** (AD-06): a validação do changeset é a primeira
  linha de defesa, o banco é a última.

## 5. Modelo de dados e migrations

Nenhuma migration nova — usa `questions` e `answer_options` da story **F1-05**.

Formato dos atributos aceitos:

```elixir
%{
  "text" => "Qual é a capital do Brasil?",
  "answer_options" => [
    %{"text" => "Rio de Janeiro", "position" => 1, "is_correct" => false},
    %{"text" => "Brasília",       "position" => 2, "is_correct" => true},
    %{"text" => "São Paulo",      "position" => 3, "is_correct" => false},
    %{"text" => "Salvador",       "position" => 4, "is_correct" => false}
  ]
}
```

Na edição, cada alternativa existente deve trafegar com seu `id` para que o `cast_assoc` atualize em
vez de recriar.

## 6. Contratos técnicos

Arquivo: `lib/live_quiz/quizzes.ex`

```elixir
@doc "Busca uma pergunta do quiz informado, dentro do escopo do dono."
@spec get_question!(Scope.t(), Quiz.t(), integer() | String.t()) :: Question.t()
def get_question!(scope, quiz, id)   # com answer_options pré-carregadas e ordenadas

@doc """
Cria uma pergunta com exatamente 4 alternativas, em transação.
A posição é calculada como (maior posição existente no quiz) + 1.
"""
@spec create_question(Scope.t(), Quiz.t(), map()) ::
        {:ok, Question.t()} | {:error, Ecto.Changeset.t()} | {:error, :question_limit_reached}
def create_question(scope, quiz, attrs)

@doc "Atualiza o texto da pergunta e as 4 alternativas, em transação."
@spec update_question(Scope.t(), Question.t(), map()) ::
        {:ok, Question.t()} | {:error, Ecto.Changeset.t()}
def update_question(scope, question, attrs)

@doc "Changeset para formulários; monta 4 alternativas vazias quando a pergunta é nova."
@spec change_question(Question.t(), map()) :: Ecto.Changeset.t()
def change_question(question, attrs \\ %{})

@doc "Retorna uma pergunta nova com 4 alternativas em branco nas posições 1..4."
@spec new_question() :: Question.t()
def new_question()
```

> A story F1-05 entregou o changeset **base** de `Question` (texto, posição e `cast_assoc`).
> Esta story **acrescenta** a ele as validações de conjunto abaixo — não crie um segundo changeset.

### Validações de conjunto (acrescentadas ao changeset de `Question`)

```elixir
|> cast_assoc(:answer_options, required: true, with: &AnswerOption.changeset/2)
|> validate_answer_options_count()      # exatamente 4
|> validate_single_correct_option()     # exatamente 1 com is_correct == true
|> validate_unique_option_texts()       # sem textos repetidos (trim + downcase)
```

Mensagens de erro (pt-BR), aplicadas no changeset pai:

| Regra violada | Mensagem |
|---|---|
| Quantidade diferente de 4 | "a pergunta deve ter exatamente 4 alternativas" |
| Nenhuma correta | "marque a alternativa correta" |
| Mais de uma correta | "marque apenas uma alternativa correta" |
| Texto repetido | "as alternativas não podem ter textos repetidos" |

### Limite de perguntas

`create_question/3` verifica a contagem atual dentro da transação; se já houver 50 perguntas,
retorna `{:error, :question_limit_reached}` e não persiste nada.

## 7. Regras de negócio e validações

- Pergunta pertence a exatamente um quiz, e esse quiz pertence ao usuário do escopo.
- Texto da pergunta: obrigatório, 3–500 caracteres, com `trim`.
- Exatamente 4 alternativas, com `position` 1, 2, 3 e 4.
- Texto de cada alternativa: obrigatório, 1–200 caracteres, com `trim`.
- Exatamente 1 alternativa com `is_correct == true`.
- Textos de alternativas não podem se repetir dentro da mesma pergunta (comparação com `trim` e
  case-insensitive).
- Máximo de 50 perguntas por quiz.
- `position` da pergunta é sempre calculada pelo servidor na criação e **não** é alterada por `update_question/3`.
- Tentativa de editar pergunta de quiz de outra pessoa resulta em `Ecto.NoResultsError`.
- Falha em qualquer validação não deixa registro parcial no banco.

## 8. Critérios de aceite

```gherkin
Cenário: Criar pergunta completa
  Dado um quiz meu sem perguntas
  Quando crio uma pergunta com texto válido e 4 alternativas, marcando a segunda como correta
  Então a pergunta é persistida na posição 1
  E as 4 alternativas são persistidas nas posições 1 a 4
  E apenas a segunda alternativa está marcada como correta

Cenário: Posição sequencial automática
  Dado um quiz meu com 2 perguntas
  Quando crio uma nova pergunta
  Então ela é persistida na posição 3

Cenário: Pergunta sem alternativa correta
  Quando tento criar uma pergunta sem marcar nenhuma alternativa como correta
  Então recebo o erro "marque a alternativa correta"
  E nenhuma pergunta ou alternativa é persistida

Cenário: Pergunta com duas alternativas corretas
  Quando tento criar uma pergunta marcando duas alternativas como corretas
  Então recebo o erro "marque apenas uma alternativa correta"
  E nada é persistido

Cenário: Pergunta com menos de 4 alternativas
  Quando tento criar uma pergunta enviando 3 alternativas
  Então recebo o erro "a pergunta deve ter exatamente 4 alternativas"
  E nada é persistido

Cenário: Alternativas com texto repetido
  Quando tento criar uma pergunta com duas alternativas escritas "Brasil" e "brasil"
  Então recebo o erro "as alternativas não podem ter textos repetidos"
  E nada é persistido

Cenário: Alternativa em branco
  Quando tento criar uma pergunta com uma das alternativas vazia
  Então recebo erro de obrigatoriedade naquela alternativa
  E nada é persistido

Cenário: Editar pergunta trocando a alternativa correta
  Dada uma pergunta minha com a alternativa 2 correta
  Quando atualizo marcando a alternativa 4 como correta
  Então apenas a alternativa 4 fica correta
  E as demais alternativas mantêm seus ids originais

Cenário: Limite de perguntas
  Dado um quiz meu com 50 perguntas
  Quando tento criar mais uma
  Então recebo o erro de limite atingido
  E o quiz continua com 50 perguntas

Cenário: Pergunta de quiz alheio
  Dada uma pergunta de um quiz de Bruno
  Quando Ana tenta obtê-la ou atualizá-la
  Então é levantado Ecto.NoResultsError
```

## 9. Cenários de teste

Arquivo: `test/live_quiz/quizzes_questions_test.exs`

- criação válida persiste pergunta e 4 alternativas com posições corretas;
- posição incrementa a cada nova pergunta;
- criação inválida (sem correta, duas corretas, 3 alternativas, 5 alternativas, texto duplicado,
  alternativa vazia, texto da pergunta curto/longo) retorna changeset inválido **e** não persiste
  nada — assertar a contagem de `questions` e `answer_options` após a falha;
- atualização altera texto da pergunta e das alternativas mantendo os mesmos ids;
- atualização troca a alternativa correta sem violar o índice único parcial;
- atualização não altera a `position` da pergunta;
- limite de 50 perguntas retorna `{:error, :question_limit_reached}`;
- `get_question!/3` levanta `Ecto.NoResultsError` para pergunta de outro dono e para id inexistente;
- `new_question/0` devolve 4 alternativas em branco nas posições 1..4;
- alternativas são sempre retornadas ordenadas por `position`.

## 10. Definition of Ready

- [x] Regra de 4 alternativas fixas e 1 correta definida.
- [x] Limite de 50 perguntas definido.
- [x] Contexto de quiz disponível (F1-06).
- [x] Mensagens de erro em pt-BR definidas.

## 11. Definition of Done

- [ ] Funções implementadas conforme o item 6, todas transacionais.
- [ ] Validações de conjunto implementadas com as mensagens especificadas.
- [ ] Nenhum caminho de código cria ou remove alternativa isoladamente.
- [ ] Todos os cenários de teste do item 9 passando, incluindo as asserções de "nada persistido".
- [ ] `@doc` e `@spec` nas funções públicas.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-06** — `get_quiz!/2` e o padrão de escopo.

## 13. Riscos e pontos de atenção

- Trocar a alternativa correta em uma única operação pode colidir com o índice único parcial se as
  atualizações forem aplicadas em ordem desfavorável: garantir que a desmarcação ocorra antes da
  marcação dentro da mesma transação (o `cast_assoc` com `Repo.update` em bloco costuma resolver,
  mas o cenário precisa de teste explícito).
- `cast_assoc` sem os `id`s das alternativas na edição recria os registros e quebra a rastreabilidade
  — os formulários devem enviar o `id` de cada alternativa.
- A verificação do limite de 50 deve ocorrer **dentro** da transação para evitar corrida.

## 14. Estimativa

**5 pontos** — regra composta, transação e muitos casos de erro a cobrir.
