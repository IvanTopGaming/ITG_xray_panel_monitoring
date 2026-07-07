#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../central"
if [ ! -f .env ]; then
  cp .env.example .env
  echo ">> Заполни central/.env (METRICS_*, GRAFANA_ADMIN_PASSWORD, TELEGRAM_*) и перезапусти."
  exit 1
fi
# живые target-файлы gitignored (чтобы git pull/reset не стирал список нод) — сеем из примеров
for f in nodes blackbox-http blackbox-tcp; do
  [ -f "prometheus/targets/$f.yml" ] || cp "prometheus/targets/$f.yml.example" "prometheus/targets/$f.yml"
done
docker compose pull
docker compose up -d
echo ">> Central поднят: Grafana :3000, Prometheus :9090, Alertmanager :9093"
