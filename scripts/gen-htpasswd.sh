#!/usr/bin/env bash
set -euo pipefail
# Использование: ./scripts/gen-htpasswd.sh <username> <password>
# Печатает строки для node-agent/.env. Хеш выводится с удвоенными '$' ($$),
# т.к. docker compose интерполирует '$' в .env — экранирование обязательно.
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <username> <password>" >&2
  exit 1
fi
USER="$1"; PASS="$2"
HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$PASS")"
ESC="$(printf '%s' "$HASH" | sed 's/\$/$$/g')"
echo "# -> node-agent/.env (вставь обе строки как есть):"
echo "METRICS_USER=$USER"
echo "METRICS_PASSWORD_HASH=$ESC"
