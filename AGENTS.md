# AGENTS.md — Live Quiz

Instruções operacionais para qualquer pessoa ou agente que for trabalhar neste repositório.
Leia este arquivo **antes** de escrever qualquer linha de código.

---

## 1. O que é este projeto

Plataforma de quiz em tempo real (inspirada no Kahoot) construída com **Elixir + Phoenix + Phoenix
LiveView + PostgreSQL**, com uma **API JSON** paralela para consumo futuro por app mobile.

O projeto é entregue em **4 fases**, cada uma equivalente a uma sprint com funcionalidade de negócio
completa. O plano completo está em [`plataforma_quiz_4_fases.md`](plataforma_quiz_4_fases.md).

| Fase | Entrega |
|---|---|
| 1 | Criação e gerenciamento de quizzes (**em andamento**) |
| 2 | Sala de quiz e lobby em tempo real |
| 3 | Execução do quiz em tempo real |
| 4 | Pontuação, ranking e histórico |

---

## 2. Onde fica o trabalho

| Recurso | Local |
|---|---|
| **Board (GitHub Project)** | https://github.com/users/jessicavalcanti/projects/3 — *Live Quiz — Roadmap* |
| **Issues** | https://github.com/jessicavalcanti/live_quiz/issues |
| **Épico da fase 1** | [issue #1](https://github.com/jessicavalcanti/live_quiz/issues/1) — as 16 stories são sub-issues dele |
| **Convenções globais da fase** | card de épico (stack, nomenclatura, `scope`, DoD global) |

> **A issue no GitHub é a versão definitiva de uma story.** Não existe cópia em markdown no
> repositório: refinamento, contratos técnicos e critérios de aceite vivem só na issue, e é lá que
> qualquer mudança de escopo deve ser registrada. Leia com `gh issue view <N>`.

### Estrutura do board

O board tem **4 colunas** (campo `Status`):

```text
Todo  →  Doing  →  Review  →  Done
```

| Coluna | Significado |
|---|---|
| **Todo** | Story refinada e pronta para desenvolvimento |
| **Doing** | Alguém está desenvolvendo, já existe branch |
| **Review** | PR aberto, aguardando revisão |
| **Done** | PR mergeado na `develop` |

Campos adicionais do board: **Fase** (single select), **Pontos** (estimativa em story points) e
**Sub-issues progress** (barra de progresso do épico).

### Visualizações

| View | Layout | Filtro |
|---|---|---|
| Todos os itens | Tabela | — |
| Fase 1 — Quizzes | Board | `label:fase-1` |
| Fase 2 — Sala | Board | `label:fase-2` |
| Fase 3 — Jogo | Board | `label:fase-3` |
| Fase 4 — Ranking | Board | `label:fase-4` |

### Labels

| Grupo | Labels |
|---|---|
| Tipo | `epic`, `user-story` |
| Fase | `fase-1`, `fase-2`, `fase-3`, `fase-4` |
| Camada | `backend`, `frontend`, `api`, `infra`, `documentacao`, `habilitador-tecnico` |

Toda issue nova deve receber **tipo + fase + camada**. É a label de fase que faz o card aparecer na
view correta do board.

---

## 3. Git flow

```text
main ─────────────●────────────────●──────────  produção, protegida
                  ▲                ▲
                  │ PR de release  │
develop ──●───●───●────●───●───●───●──────────  integração
          ▲   ▲        ▲   ▲   ▲
          │   │        │   │   │  PR de story
    feature/… feature/… chore/… fix/…
```

- **`main`** — branch principal/produção. **Nunca** receba commit direto e **nunca** abra PR de uma
  feature para ela. A única origem aceita é a `develop` (há um check de CI que reprova o contrário).
- **`develop`** — branch de integração e **branch default do repositório**. Todo PR de story aponta
  para cá.
- **Branches de trabalho** — sempre criadas **a partir da `develop`**, nunca da `main`.

### Nomenclatura de branch

```text
feature/<numero-da-issue>-<slug>    nova funcionalidade
fix/<numero-da-issue>-<slug>        correção de bug
chore/<numero-da-issue>-<slug>      infraestrutura, build, dependências
docs/<numero-da-issue>-<slug>       documentação
refactor/<numero-da-issue>-<slug>   refatoração sem mudança de comportamento
```

Exemplo: `feature/7-contexto-quiz-crud` para a issue #7.

### Conventional Commits

Todo commit segue [Conventional Commits](https://www.conventionalcommits.org/pt-br/):

```text
<tipo>(<escopo opcional>): <descrição no imperativo, minúscula, sem ponto final>

[corpo opcional explicando o porquê]

[rodapé opcional: Refs #7]
```

Tipos aceitos: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `build`, `ci`, `style`.

```text
feat(quizzes): add quiz context with owner scoping
fix(editor): keep question order after deletion
test(quizzes): cover answer option set validations
chore(ci): raise coverage threshold to 80%
docs(stories): fix playable? contract in F1-06
```

Escreva o commit em **inglês** (código e commits em inglês; UI e issues em pt-BR).

---

## 4. Procedimento padrão para atuar em uma story

Siga **todos** os passos, na ordem. `<N>` é o número da issue.

### 4.1 Antes de começar

```bash
# 1. Mover o card para Doing e assumir a issue
gh issue edit <N> --repo jessicavalcanti/live_quiz --add-assignee jessicavalcanti
# mover no board: ver o comando pronto em "Comandos úteis" abaixo

# 2. Partir sempre da develop atualizada
git checkout develop
git pull origin develop

# 3. Criar a branch da story
git checkout -b feature/<N>-<slug>
```

Leia a issue inteira antes de codificar: ela contém contratos técnicos (assinaturas de função,
rotas, payloads), regras de negócio, critérios de aceite e os cenários de teste obrigatórios.
Se algo na issue conflitar com o código existente, **pare e pergunte** — não invente contrato.

### 4.2 Durante

- Implemente apenas o que está no escopo "Dentro" da story; o que está em "Fora" é de outra issue.
- Regras de negócio vivem nos **contextos**, nunca em LiveView ou Controller.
- Nenhum acesso a `Repo` fora dos contextos.
- Escreva os testes listados na seção "Cenários de teste" da issue — eles são obrigatórios, não sugestão.
- Rode `mix precommit` antes de cada push (formatação, credo, compile sem warnings, testes).

### 4.3 Ao finalizar

```bash
# 1. Push da branch
git push -u origin feature/<N>-<slug>

# 2. Abrir o PR para a develop, associando a issue
gh pr create --base develop \
  --title "feat(quizzes): <resumo no padrão conventional commits>" \
  --body "Closes #<N>

## O que foi feito
- ...

## Como validar
- ...

## Checklist
- [ ] Critérios de aceite da issue atendidos
- [ ] Cenários de teste da issue implementados
- [ ] \`mix precommit\` passa localmente
- [ ] Cobertura acima de 80%"

# 3. Mover o card para Review
```

O corpo do PR **deve** conter `Closes #<N>` para fechar a issue automaticamente no merge.

### 4.4 Regras que valem sempre

1. **Toda movimentação de card no board vem acompanhada de assignee.** Ao mover para `Doing` ou
   `Review`, a issue precisa estar atribuída a `jessicavalcanti`.
2. Uma story por branch, uma branch por PR.
3. PR só vai para `develop`. `main` recebe apenas PR vindo da `develop`.
4. CI verde é pré-requisito de merge — inclui lint e cobertura mínima de 80%.
5. Após o merge, o card vai para `Done` e a branch remota é apagada.

---

## 5. Releases e demonstrações

### Versionamento

A versão é declarada **apenas** em `mix.exs`. Todo merge na `main` dispara
[`.github/workflows/release.yml`](.github/workflows/release.yml), que lê essa versão, cria a tag
`vX.Y.Z` e publica a release com notas geradas a partir dos PRs.

| Versão | Significado |
|---|---|
| `0.0.x` | desenvolvimento antes da primeira entrega |
| `0.1.0` | **entrega da Fase 1** — criação e gerenciamento de quizzes |
| `0.2.0` | **entrega da Fase 2** — sala e lobby em tempo real |
| `0.3.0` | **entrega da Fase 3** — execução do quiz em tempo real |
| `1.0.0` | **entrega da Fase 4** — produto completo |
| `0.1.1`, `0.2.3`, … | correções pontuais mergeadas na `main` entre fases |

Regra: **entrega de fase = minor; qualquer outro merge na `main` = patch.**
Se a versão do `mix.exs` já tiver tag, o workflow não cria release nova — ele avisa e encerra.

### Procedimento de release

```bash
# 1. Subir a versão na develop, via PR normal
git checkout develop && git pull origin develop
git checkout -b chore/bump-0.1.0
# editar mix.exs: version: "0.1.0"
git commit -am "chore(release): bump version to 0.1.0"
gh pr create --base develop --title "chore(release): bump version to 0.1.0"

# 2. Depois do merge, abrir o PR de release para a main
gh pr create --base main --head develop \
  --title "release: v0.1.0 — Fase 1" \
  --body "Entrega da Fase 1. Fecha o épico #1."

# 3. Ao mergear, a tag v0.1.0 e a release são criadas automaticamente
```

> O PR para a `main` **só é aceito a partir da `develop`** — há um job de CI que reprova qualquer
> outra origem.

### Gravar a demonstração de uma versão

```bash
bin/demo list       # lista as versões disponíveis
bin/demo v0.1.0     # sobe a aplicação exatamente naquela versão
bin/demo stop       # encerra
```

O script materializa a tag em um worktree isolado (`.demo/<tag>/`), constrói a imagem daquele código
e sobe app + banco + Mailpit com volume próprio. **Sua branch de trabalho e o banco de
desenvolvimento não são tocados** — dá para desenvolver e demonstrar ao mesmo tempo.

| | Endereço |
|---|---|
| Aplicação da demo | http://localhost:4000 |
| E-mails da demo | http://localhost:8025 |
| Login de demonstração | `demo@livequiz.dev` / `demo123456789` |

> `bin/demo`, o `Dockerfile` e o `docker-compose.demo.yml` são entregues pela story F1-01; só há
> versões demonstráveis a partir da primeira release.

---

## 6. Qualidade e CI

O workflow [`.github/workflows/ci.yml`](.github/workflows/ci.yml) roda em todo push e PR para
`main` e `develop`:

| Etapa | Comando |
|---|---|
| Formatação | `mix format --check-formatted` |
| Compilação sem warnings | `mix compile --warnings-as-errors` |
| Análise estática | `mix credo --strict` |
| Testes + cobertura | `mix coveralls` (mínimo **80%**) |
| Proteção da main | reprova PR para `main` que não venha da `develop` |

> Enquanto a aplicação Phoenix não existir (story F1-01), o job detecta a ausência de `mix.exs` e
> passa sem executar as etapas — mantendo o check verde sem mascarar falhas reais depois.

Localmente, o equivalente é:

```bash
mix precommit   # compile --warnings-as-errors + format + credo --strict + test
mix coveralls   # cobertura
```

---

## 7. Ambiente de desenvolvimento

```bash
docker compose up -d    # PostgreSQL 16 + Mailpit
mix setup               # deps, banco, migrations, assets
mix phx.server          # http://localhost:4000
```

| Serviço | Endereço |
|---|---|
| Aplicação | http://localhost:4000 |
| Mailpit (e-mails de dev) | http://localhost:8025 |
| Swagger UI da API | http://localhost:4000/api/docs |
| PostgreSQL | `localhost:5432` (`postgres` / `postgres`) |

---

## 8. Convenções de código

| Item | Convenção |
|---|---|
| Idioma do código | inglês (módulos, funções, tabelas, colunas, rotas, commits) |
| Idioma da UI e das issues | pt-BR |
| Locale | Gettext `pt_BR`; mensagens de erro do Ecto traduzidas em `errors.po` |
| Datas | persistidas em UTC; exibidas na web em `America/Sao_Paulo`; API sempre em ISO 8601 UTC |
| Contextos | `LiveQuiz.Accounts` (autenticação) e `LiveQuiz.Quizzes` (quiz, perguntas, alternativas) |
| Autorização | toda função pública de contexto recebe `scope` e filtra por dono **na query**; não-dono recebe 404 |
| Arquitetura | `LiveView → Context → Changeset → Repo` e `Controller → Context → Changeset → Repo` |
| Integridade | validação no changeset **e** constraint no banco |

---

## 9. Comandos úteis

```bash
# Listar as stories prontas para desenvolvimento
gh issue list --repo jessicavalcanti/live_quiz --label user-story --state open

# Ler uma story inteira
gh issue view <N> --repo jessicavalcanti/live_quiz

# Assumir uma issue
gh issue edit <N> --repo jessicavalcanti/live_quiz --add-assignee jessicavalcanti

# Mover um card de coluna no board (IDs fixos do projeto)
#   PROJECT=PVT_kwHOBXKAR84Bh1Hz   STATUS_FIELD=PVTSSF_lAHOBXKAR84Bh1HzzhgvZgA
#   Todo=5eda1465  Doing=21d718c9  Review=a0a24ae0  Done=8de548a3
ITEM=$(gh project item-list 3 --owner jessicavalcanti --format json \
  | python3 -c "import json,sys;print([i['id'] for i in json.load(sys.stdin)['items'] if i['content']['number']==<N>][0])")
gh project item-edit --id "$ITEM" \
  --project-id PVT_kwHOBXKAR84Bh1Hz \
  --field-id PVTSSF_lAHOBXKAR84Bh1HzzhgvZgA \
  --single-select-option-id 21d718c9      # Doing

# Ver o progresso do épico
gh issue view 1 --repo jessicavalcanti/live_quiz
```

---

## 10. Guia de stack (gerado pelo Phoenix)

A partir daqui estão as diretrizes de uso de Elixir, Phoenix, Ecto e LiveView instaladas pelo
`mix phx.new` e mantidas por `mix usage_rules.sync`. Elas complementam — e nunca substituem — as
regras de processo das seções anteriores.

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->