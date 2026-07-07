# Развёртывание мониторинга

Пошаговый runbook. Central-сервер тянет метрики со всех нод по HTTPS, алерты уходят в Telegram.
Панель ITG при этом **не модифицируется** — agent разворачивается отдельным стеком рядом.

## Требования
- Docker + Docker Compose на central-сервере и на каждой ноде.
- На ноде работает ITG Xray Panel (её gRPC Stats API `xray:10085` включён по умолчанию).
- Сетевой доступ с central-сервера к нодам на порт `METRICS_PORT` (дефолт `8443`).

---

## 1. Central-сервер

```bash
cp central/.env.example central/.env
```

Заполнить `central/.env`:

| Переменная | Что вписать |
|---|---|
| `METRICS_USER` | логин basic-auth для скрейпа нод (напр. `metrics`) |
| `METRICS_PASSWORD` | пароль в **плейнтексте** (тот же, чей хеш пойдёт на ноды) |
| `GRAFANA_ADMIN_PASSWORD` | пароль admin в Grafana |
| `PROM_RETENTION` | срок хранения метрик (дефолт `30d`) |
| `TELEGRAM_BOT_TOKEN` | токен бота (реальный) |
| `TELEGRAM_CHAT_ID` | chat id для алертов (голое число) |

Запуск:

```bash
./scripts/install-central.sh
```

Доступ:
- **Grafana** — `http://<central>:3000` (admin / `GRAFANA_ADMIN_PASSWORD`)
- **Prometheus** (`:9090`) и **Alertmanager** (`:9093`) слушают только `127.0.0.1` —
  ходить через SSH-туннель: `ssh -L 9090:localhost:9090 <central>`

---

## 2. Нода (рядом с панелью)

**Шаг 1.** Узнать точное имя docker-сети панели, где сидит xray (префикс = имя проекта compose):

```bash
docker network ls | grep metrics-xray
# напр.: itg_xray_panel_metrics-xray-net
```

**Шаг 2.** Сгенерить хеш пароля (тот же пароль, что `METRICS_PASSWORD` на central):

```bash
./scripts/gen-htpasswd.sh metrics '<пароль>'
```

**Шаг 3.** Заполнить `node-agent/.env`:

```bash
cp node-agent/.env.example node-agent/.env
```

| Переменная | Что вписать |
|---|---|
| `METRICS_PORT` | порт метрик наружу (дефолт `8443`) |
| `METRICS_USER` | тот же логин, что на central |
| `METRICS_PASSWORD_HASH` | хеш из шага 2 — **вставь строку из `gen-htpasswd.sh` как есть** (там `$` уже удвоены до `$$`; без экранирования docker compose побьёт хеш и Caddy вернёт 401) |
| `XRAY_API_ENDPOINT` | `xray:10085` (подтверждено, менять не надо) |
| `PANEL_NETWORK` | имя сети из шага 1 |

**Шаг 4.** Запуск:

```bash
./scripts/install-node.sh
```

**Шаг 5.** Проверить, что все три эндпоинта отдают метрики:

```bash
curl -sk -u metrics:'<пароль>' https://localhost:8443/node/metrics     | head -3
curl -sk -u metrics:'<пароль>' https://localhost:8443/cadvisor/metrics | head -3
curl -sk -u metrics:'<пароль>' https://localhost:8443/xray/metrics     | head -3
```

Если `/xray/metrics` пустой — проверь `PANEL_NETWORK` и что xray-exporter в этой сети
(`docker logs mon-xray-exporter`).

---

## 3. Файрвол на ноде (обязательно)

Экспортёры не должны торчать в открытый интернет. `caddy-metrics` защищён TLS+basic-auth,
но `node-exporter` в host-режиме биндит `:9100` напрямую — его закрываем обязательно.

```bash
ufw allow from <CENTRAL_IP> to any port 8443 proto tcp
ufw allow from <CENTRAL_IP> to any port 9100 proto tcp
ufw deny 8443
ufw deny 9100
```

---

## 4. Зарегистрировать ноду в мониторинге (на central)

```bash
./scripts/add-node.sh <name> <node-host>          # metrics_port=8443, xray_tcp_port=443 по дефолту
./scripts/add-node.sh <name> <node-host> 9443 443 # если METRICS_PORT нестандартный
```

Скрипт дописывает таргет в три file_sd файла (`central/prometheus/targets/`) и дёргает
Prometheus reload. Ноды в этих файлах изначально закомменчены — добавляй только через скрипт.

---

## Важные нюансы

- **Одна пара кредов.** `METRICS_USER`/`METRICS_PASSWORD` на central (плейнтекст) и
  `METRICS_USER`/`METRICS_PASSWORD_HASH` на ноде (bcrypt того же пароля) — это один секрет.
  Не совпадут — скрейп получит `401`.
- **Панельный `panel-metrics` не трогаем и не скрейпим.** Он нужен встроенной статистике
  панели (backend ходит к нему на `metrics:9100`). Наш стек полностью независим.
- **Self-signed TLS.** По умолчанию `caddy-metrics` отдаёт self-signed cert, Prometheus
  скрейпит с `insecure_skip_verify`. Для настоящего Let's Encrypt — заменить `tls internal`
  на домен в `node-agent/Caddyfile` (нужен свободный `:443`/`:80`, которых на ноде нет —
  поэтому дефолт self-signed).
- **TLS-сертификат панели** мониторится blackbox'ом (`PanelCertExpiring`, алерт < 14 дней).

---

## Проверка после развёртывания

На central:

```bash
# все таргеты UP?
curl -s http://localhost:9090/api/v1/targets | \
  jq -r '.data.activeTargets[] | "\(.labels.job) \(.labels.node // .labels.instance) \(.health)"'

# правила загружены (10, health=ok)?
curl -s http://localhost:9090/api/v1/rules | jq '[.data.groups[].rules[]] | length'

# Alertmanager подхвачен?
curl -s http://localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers | length'
```

В Grafana — папка **ITG Monitoring**, дашборды: Nodes Overview, Node Detail, Xray Traffic, Availability.
