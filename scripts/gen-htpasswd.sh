#!/usr/bin/env bash
set -euo pipefail
# Использование: ./scripts/gen-htpasswd.sh <username> <password>
# METRICS_USER -> node-agent/.env ; METRICS_PASSWORD_HASH -> node-agent/caddy-auth.env
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <username> <password>" >&2
  exit 1
fi
USER="$1"; PASS="$2"
HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$PASS")"
echo "# -> node-agent/.env"
echo "METRICS_USER=$USER"
echo "# -> node-agent/caddy-auth.env"
echo "METRICS_PASSWORD_HASH=$HASH"
