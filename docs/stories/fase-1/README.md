# Fase 1 — Criação e gerenciamento de quizzes

Refinamento completo da fase 1, pronto para virar issues no GitHub.

| Arquivo | Card | Tipo | Depende de | Pts |
|---|---|---|---|---|
| [00-epico-fase-1.md](00-epico-fase-1.md) | **[ÉPICO] Fase 1** | épico | — | 72 |
| [01-bootstrap-projeto.md](01-bootstrap-projeto.md) | Bootstrap do projeto Phoenix, ambiente de desenvolvimento e empacotamento de release | infra | — | 8 |
| [02-ci-pipeline.md](02-ci-pipeline.md) | Pipeline de CI e alias `mix precommit` | infra | 01 | 2 |
| [03-autenticacao.md](03-autenticacao.md) | Autenticação: cadastro, login, logout, confirmação e redefinição de senha | habilitador | 01 | 8 |
| [04-landing-layout-rotas.md](04-landing-layout-rotas.md) | Landing pública, layout autenticado e proteção de rotas | habilitador | 03 | 3 |
| [05-migrations-schemas-dominio.md](05-migrations-schemas-dominio.md) | Migrations, schemas e seeds do domínio de quizzes | backend | 03 | 5 |
| [06-contexto-quiz-crud.md](06-contexto-quiz-crud.md) | Contexto `Quizzes`: CRUD de quiz com escopo por dono | backend | 05 | 3 |
| [07-contexto-perguntas.md](07-contexto-perguntas.md) | Contexto `Quizzes`: criar e editar pergunta com 4 alternativas | backend | 06 | 5 |
| [08-contexto-reordenar-excluir.md](08-contexto-reordenar-excluir.md) | Contexto `Quizzes`: excluir e reordenar perguntas | backend | 07 | 3 |
| [09-dashboard-meus-quizzes.md](09-dashboard-meus-quizzes.md) | Dashboard "Meus quizzes" com paginação, busca e contagem | frontend | 04, 06 | 5 |
| [10-crud-quiz-ui.md](10-crud-quiz-ui.md) | Criar, editar e excluir quiz pela interface | frontend | 09 | 5 |
| [11-editor-perguntas.md](11-editor-perguntas.md) | Editor de quiz: adicionar e editar perguntas em modal | frontend | 07, 10 | 8 |
| [12-editor-reordenar-excluir.md](12-editor-reordenar-excluir.md) | Editor de quiz: reordenar e excluir perguntas | frontend | 08, 11 | 3 |
| [13-api-auth-jwt.md](13-api-auth-jwt.md) | Autenticação JWT da API com Guardian | api | 03 | 5 |
| [14-api-quizzes.md](14-api-quizzes.md) | API v1: CRUD de quizzes com paginação e busca | api | 06, 13 | 3 |
| [15-api-perguntas.md](15-api-perguntas.md) | API v1: perguntas e alternativas | api | 07, 08, 13 | 3 |
| [16-openapi-swagger.md](16-openapi-swagger.md) | Documentação OpenAPI e Swagger UI | api | 14, 15 | 3 |

Ordem sugerida: 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12 → 13 → 14 → 15 → 16.
As trilhas de frontend (09–12) e de API (13–16) podem correr em paralelo após a story 08.

As convenções globais (stack, nomenclatura, `scope`, fluxo de git e Definition of Done comum a
todas as stories) estão no card de épico e **não** se repetem em cada story.
