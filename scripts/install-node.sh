#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../node-agent"
if [ ! -f .env ] || [ ! -f caddy-auth.env ]; then
  [ -f .env ] || cp .env.example .env
  [ -f caddy-auth.env ] || cp caddy-auth.env.example caddy-auth.env
  echo ">> Заполни node-agent/.env (METRICS_USER, METRICS_PORT, XRAY_API_ENDPOINT, PANEL_NETWORK)"
  echo ">> и node-agent/caddy-auth.env (METRICS_PASSWORD_HASH), затем перезапусти."
  echo ">> Хеш пароля: ../scripts/gen-htpasswd.sh <user> <password>"
  exit 1
fi
docker compose pull
docker compose up -d
echo ">> Agent поднят. Проверь: curl -sk -u USER:PASS https://localhost:\${METRICS_PORT}/node/metrics | head"
