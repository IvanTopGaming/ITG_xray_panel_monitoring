#!/usr/bin/env bash
set -euo pipefail
# Использование: ./scripts/gen-htpasswd.sh <username> <password>
# Печатает строку METRICS_PASSWORD_HASH для .env (bcrypt через caddy).
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <username> <password>" >&2
  exit 1
fi
USER="$1"; PASS="$2"
HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$PASS")"
echo "METRICS_USER=$USER"
echo "METRICS_PASSWORD_HASH=$HASH"
