#!/usr/bin/env bash
# Helper do GitHub Project "Live Quiz — Roadmap" (project 3, owner jessicavalcanti).
# Uso:
#   board.sh list                 lista todos os cards: <item-id> | <status> | <issue> | <título>
#   board.sh next                 imprime o número da próxima story em Todo (menor número, ignora o épico)
#   board.sh move <issue> <col>   move o card da issue para Todo|Doing|Review|Done
set -euo pipefail

REPO="jessicavalcanti/live_quiz"
PROJECT_NUMBER=3
PROJECT_OWNER="jessicavalcanti"
PROJECT_ID="PVT_kwHOBXKAR84Bh1Hz"
STATUS_FIELD="PVTSSF_lAHOBXKAR84Bh1HzzhgvZgA"

status_option() {
  case "$1" in
    Todo)   echo "5eda1465" ;;
    Doing)  echo "21d718c9" ;;
    Review) echo "a0a24ae0" ;;
    Done)   echo "8de548a3" ;;
    *)      echo "coluna inválida: $1 (use Todo|Doing|Review|Done)" >&2; exit 1 ;;
  esac
}

items_json() {
  gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --limit 200 --format json
}

cmd_list() {
  items_json | python3 -c '
import json, sys
for i in json.load(sys.stdin)["items"]:
    c = i.get("content") or {}
    if c.get("number") is None:
        continue
    print(i["id"], i.get("status", "-"), c["number"], (c.get("title") or "")[:70], sep=" | ")
'
}

cmd_next() {
  # Stories prontas para desenvolvimento: card em Todo + label user-story.
  local todo ready
  todo=$(items_json | python3 -c '
import json, sys
nums = [ (i.get("content") or {}).get("number")
         for i in json.load(sys.stdin)["items"] if i.get("status") == "Todo" ]
print(" ".join(str(n) for n in sorted(n for n in nums if n)))
')
  ready=$(gh issue list --repo "$REPO" --label user-story --state open --limit 200 \
            --json number --jq '.[].number' | sort -n)
  for n in $todo; do
    if grep -qx "$n" <<<"$ready"; then echo "$n"; return 0; fi
  done
  echo "nenhuma story em Todo" >&2
  exit 1
}

cmd_move() {
  local issue="$1" column="$2" item
  item=$(items_json | python3 -c "
import json, sys
ids = [i['id'] for i in json.load(sys.stdin)['items']
       if (i.get('content') or {}).get('number') == $issue]
print(ids[0] if ids else '')
")
  [ -n "$item" ] || { echo "issue #$issue não está no board" >&2; exit 1; }
  gh project item-edit --id "$item" \
    --project-id "$PROJECT_ID" \
    --field-id "$STATUS_FIELD" \
    --single-select-option-id "$(status_option "$column")" >/dev/null
  echo "issue #$issue → $column"
}

case "${1:-}" in
  list) cmd_list ;;
  next) cmd_next ;;
  move) cmd_move "${2:?informe o número da issue}" "${3:?informe a coluna}" ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
