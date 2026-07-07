#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../node-agent"
if [ ! -f .env ]; then
  cp .env.example .env
  echo ">> Заполни node-agent/.env (METRICS_*, XRAY_API_ENDPOINT, PANEL_NETWORK) и перезапусти."
  echo ">> Хеш пароля: ../scripts/gen-htpasswd.sh <user> <password> (выведет готовый \$\$-хеш)"
  exit 1
fi
docker compose pull
docker compose up -d
echo ">> Agent поднят. Проверь: curl -sk -u USER:PASS https://localhost:\${METRICS_PORT}/node/metrics | head"
