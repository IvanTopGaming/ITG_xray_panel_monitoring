# ITG Xray Panel — мониторинг

Pull-based мониторинг xray-нод под [ITG Xray Panel](https://github.com/IvanTopGaming/ITG_xray_panel).
Central Prometheus+Grafana+Alertmanager тянет метрики с N нод по HTTPS, алерты — в Telegram.

## Что мониторится
- Загрузка ноды: CPU/RAM/disk/load/network (node_exporter)
- Контейнеры панели: CPU/mem/рестарты (cAdvisor)
- Трафик xray по inbound/user (xray-exporter через gRPC Stats API)
- Доступность панели (HTTP 200 + TLS cert expiry) и xray-инбаундов (TCP) — blackbox снаружи
- Алерты в Telegram: нода/панель/ядро down, cert expiring, диск/RAM/CPU, всплеск/просадка трафика

## Требования
- Docker + Docker Compose на central-сервере и на каждой ноде.
- На ноде включён gRPC Stats API xray (у ITG panel включён по умолчанию).
- Порт `METRICS_PORT` (дефолт 8443) открыт на ноде для IP central-сервера (firewall).

## Установка central
1. `cp central/.env.example central/.env` и заполнить.
2. `./scripts/install-central.sh`
3. Grafana: http://<central>:3000 (admin / GRAFANA_ADMIN_PASSWORD).

## Установка ноды
1. Скопировать репо на ноду.
2. Хеш пароля: `./scripts/gen-htpasswd.sh metrics <password>` → в `node-agent/.env`.
3. Заполнить `node-agent/.env`: `XRAY_API_ENDPOINT`, `PANEL_NETWORK` (см. `docker network ls`).
4. `./scripts/install-node.sh`

## Добавить ноду в мониторинг
На central: `./scripts/add-node.sh <name> <host> [metrics_port] [xray_tcp_port]`

## Безопасность
Экспортёры наружу не публикуются — только через Caddy на `METRICS_PORT` с TLS + basic auth.
Дефолтный cert self-signed (Prometheus скрейпит с insecure_skip_verify). Для настоящего LE —
заменить `tls internal` на домен в `node-agent/Caddyfile`.
