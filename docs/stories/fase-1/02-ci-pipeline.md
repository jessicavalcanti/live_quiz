# [F1-02] Pipeline de CI e alias `mix precommit`

> **Épico:** Fase 1 — Criação e gerenciamento de quizzes · **Labels:** `fase-1`, `infra`
> **Branch:** `feature/02-ci-pipeline` · **Estimativa:** 2 pontos · **Depende de:** F1-01

## 1. Contexto de negócio

Todas as stories seguintes serão entregues em PRs isolados. Sem um portão automatizado de
qualidade, formatação, warnings e testes quebrados chegam à `main` e o custo de correção sobe.
Esta story cria esse portão logo no início, quando ainda é barato.

## 2. User story

**Como** pessoa responsável pela qualidade do projeto,
**quero** que todo PR execute formatação, análise estática e testes automaticamente,
**para que** nenhuma alteração quebre a `main` e o padrão de código seja garantido sem revisão manual.

## 3. Escopo

### Dentro
- Workflow do GitHub Actions rodando em `push` na `main` e em `pull_request`.
- Serviço Postgres no CI.
- Verificações: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.
- Dependência `credo` e alias `mix precommit`.
- Cache de dependências e de build.

### Fora
- Dialyzer, `sobelow`, cobertura de testes, deploy, publicação de artefatos.

## 4. Decisões de arquitetura

- **GitHub Actions** por ser onde as issues e PRs deste projeto vivem.
- **Sem Dialyzer** nesta fase: tempo de CI alto e ruído elevado em projeto novo.
- **Sem meta de cobertura**: a qualidade é garantida pelos cenários de teste obrigatórios definidos
  em cada story, não por percentual.
- `mix precommit` existe para que o mesmo conjunto de verificações rode localmente antes do push.

## 5. Modelo de dados e migrations

Não se aplica.

## 6. Contratos técnicos

### `mix.exs`

```elixir
defp deps do
  [
    # ...
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end

defp aliases do
  [
    # ...
    precommit: [
      "compile --warnings-as-errors",
      "format",
      "credo --strict",
      "test"
    ]
  ]
end
```

### `.credo.exs`

Gerar com `mix credo.gen.config`. Ajustes permitidos: desabilitar checks que conflitem com o código
gerado pelo Phoenix, documentando o motivo em comentário no próprio arquivo.

### `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      db:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: live_quiz_test
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 5s
          --health-timeout 5s --health-retries 10
    env:
      MIX_ENV: test
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.20"
          otp-version: "29"
      - uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: mix credo --strict
      - run: mix test
```

### README

Adicionar seção "Qualidade" explicando `mix precommit` e o que o CI verifica.

## 7. Regras de negócio e validações

Não se aplica.

## 8. Critérios de aceite

```gherkin
Cenário: PR com código formatado e testes passando
  Dado um PR aberto contra a main
  Quando o workflow de CI executa
  Então todas as etapas passam e o PR fica apto ao merge

Cenário: PR com código mal formatado
  Dado um PR com um arquivo fora do padrão do "mix format"
  Quando o workflow de CI executa
  Então a etapa "mix format --check-formatted" falha
  E o PR é bloqueado

Cenário: PR com warning de compilação
  Dado um PR que introduz uma variável não utilizada
  Quando o workflow de CI executa
  Então a etapa "mix compile --warnings-as-errors" falha

Cenário: Verificação local
  Dado o projeto na máquina do desenvolvedor
  Quando eu executo "mix precommit"
  Então formatação, análise estática e testes são executados na mesma ordem do CI
```

## 9. Cenários de teste

- **Manuais/verificáveis no PR desta story:** abrir o próprio PR e observar o CI verde; opcionalmente
  criar um commit temporário com código desformatado para confirmar a falha, revertendo em seguida.
- Não há teste automatizado próprio desta story.

## 10. Definition of Ready

- [x] Story F1-01 concluída (projeto Phoenix existe).
- [x] Conjunto de verificações do CI definido.
- [x] Decisão de não incluir Dialyzer registrada.

## 11. Definition of Done

- [ ] `.github/workflows/ci.yml` versionado e executando com sucesso no PR desta story.
- [ ] `credo` instalado, `.credo.exs` versionado e `mix credo --strict` sem apontamentos.
- [ ] Alias `precommit` disponível e documentado no README.
- [ ] Proteção da branch `main` exigindo o check de CI configurada no repositório.
- [ ] DoD global do épico atendida.

## 12. Dependências

- **F1-01** — precisa do projeto Phoenix e do `mix.exs`.

## 13. Riscos e pontos de atenção

- `mix credo --strict` costuma apontar itens no código gerado pelo Phoenix: ajustar `.credo.exs` em
  vez de desabilitar a verificação inteira.
- Versões de Elixir/OTP do CI devem espelhar as usadas em desenvolvimento.

## 14. Estimativa

**2 pontos** — configuração pequena e bem conhecida.
