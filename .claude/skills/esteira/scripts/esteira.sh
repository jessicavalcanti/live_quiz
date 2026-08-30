#!/usr/bin/env bash
# Estado da esteira de stories. Reaproveita o board.sh da skill proxima-story.
# Uso:
#   esteira.sh restantes            lista as stories prontas para puxar: "#N título"
#   esteira.sh iniciar              (re)cria o diário da execução com a fila do momento
#   esteira.sh registrar <issue> <status> <texto>   anota uma linha no diário
#   esteira.sh log                  mostra o diário
set -euo pipefail

REPO="jessicavalcanti/live_quiz"
ROOT="$(git rev-parse --show-toplevel)"
BOARD="$ROOT/.claude/skills/proxima-story/scripts/board.sh"
LOG="$ROOT/.claude/esteira/run.md"

cmd_restantes() {
  local ready
  ready=$(gh issue list --repo "$REPO" --label user-story --state open --limit 200 \
            --json number --jq '.[].number')
  "$BOARD" list \
    | awk -F' \\| ' '$2 == "Todo" { print $3 "|" $4 }' \
    | sort -t'|' -k1,1n \
    | while IFS='|' read -r num title; do
        if grep -qx "$num" <<<"$ready"; then printf '#%s %s\n' "$num" "$title"; fi
      done
}

cmd_iniciar() {
  mkdir -p "$(dirname "$LOG")"
  {
    echo "# Esteira — iniciada em $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "## Fila no início"
    cmd_restantes | sed 's/^/- /'
    echo
    echo "## Andamento"
  } > "$LOG"
  cat "$LOG"
}

cmd_registrar() {
  [ -f "$LOG" ] || cmd_iniciar >/dev/null
  printf -- '- %s | #%s | %s | %s\n' "$(date '+%H:%M')" "$1" "$2" "$3" >> "$LOG"
  tail -n 1 "$LOG"
}

case "${1:-}" in
  restantes) cmd_restantes ;;
  iniciar)   cmd_iniciar ;;
  registrar) cmd_registrar "${2:?informe o número da issue}" "${3:?informe o status}" "${4:?informe o texto}" ;;
  log)       cat "$LOG" ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
