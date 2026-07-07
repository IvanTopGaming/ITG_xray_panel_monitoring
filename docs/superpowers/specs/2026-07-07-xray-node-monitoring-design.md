# Мониторинг xray-нод ITG panel — дизайн

**Дата:** 2026-07-07
**Статус:** утверждён к реализации

## Цель

Собрать pull-based систему мониторинга для xray-нод, работающих под управлением
[ITG Xray Panel](https://github.com/IvanTopGaming/ITG_xray_panel). Один центральный
сервер тянет метрики со всех нод. Мониторим: загрузку ноды, трафик, состояние
контейнеров панели, доступность веб-панели и доступность/состояние xray-ядра.
Алерты уходят в Telegram.

## Топология

Один **central pull-сервер** скрейпит **N нод**. Ноды не тащат Grafana/Prometheus —
на них живёт только лёгкий monitoring-agent, который отдаёт метрики по HTTPS.

```
CENTRAL (Prometheus + Grafana + Alertmanager + Blackbox)
   │  HTTPS pull (TLS + basic auth), по каждой ноде
   ├── NODE 1: monitoring-agent (:8443)  рядом с ITG panel
   ├── NODE 2: monitoring-agent (:8443)
   └── NODE N: monitoring-agent (:8443)
```

Панель на ноде **не трогаем** — agent разворачивается отдельным docker-compose
стеком рядом.

## Компоненты

### Central server (`central/`)

Отдельный docker-compose стек:

- **Prometheus** — scrape всех нод + blackbox, хранение TSDB, alerting rules.
  Retention настраивается (дефолт 30d).
- **Grafana** — дашборды, provisioning датасорса и дашбордов из файлов (as-code).
- **Alertmanager** — маршрутизация алертов, нативный `telegram_configs` (бот-бридж
  не нужен). Группировка/дедуп/подавление.
- **Blackbox exporter** — probe панели и xray-портов **снаружи** (независимо от
  того, живой ли agent на ноде): HTTP 200 на :443, TLS cert expiry, TCP-connect
  на inbound-порты xray.

### Node monitoring-agent (`node-agent/`)

Отдельный docker-compose стек на каждой ноде. Экспортёры наружу **не**
публикуются — только через caddy-metrics.

- **node_exporter** — метрики хоста: CPU, RAM, disk, load avg, network I/O,
  filesystem, uptime.
- **cAdvisor** — метрики docker-контейнеров панели (backend, redis, xray, caddy,
  bot): CPU/mem/restart'ы/сеть per-container.
- **xray-exporter** — цепляется к gRPC stats API xray-ядра (адрес/порт задаётся в
  `.env`, API у панели уже включён), отдаёт трафик по inbound/user, uplink/downlink,
  живость ядра.
- **caddy-metrics** — reverse-proxy на выделенном порту (дефолт `:8443`), TLS +
  basic auth. Причина отдельного порта: Caddy панели роутит только по TLS/SNI на
  :443, поэтому переиспользовать его нельзя. Мультиплексит пути:
  - `/node`     → node_exporter
  - `/cadvisor` → cAdvisor
  - `/xray`     → xray-exporter
  TLS-сертификат по умолчанию self-signed (Prometheus скрейпит с
  `insecure_skip_verify: true` + `basic_auth`). Опционально — указать субдомен и
  получить настоящий Let's Encrypt.

## Транспорт и безопасность

- Метрики отдаются только по HTTPS с basic auth. Экспортёры слушают только внутри
  docker-сети agent'а, порты наружу не публикуются.
- Prometheus на central-сервере скрейпит `https://<node>:8443/<path>` с basic_auth
  и (для self-signed) `insecure_skip_verify: true`.
- Креды basic auth и параметры (порт, xray API endpoint) — в `node-agent/.env`.
- Central: Grafana за паролем; Prometheus/Alertmanager не публикуются в интернет
  открыто (доступ по firewall/VPN или через сам Grafana).

## Что мониторим — матрица

| Область | Источник | Ключевые метрики |
|---|---|---|
| Загрузка ноды | node_exporter | CPU util, RAM used/avail, disk used %, load avg, uptime |
| Трафик | node_exporter + xray-exporter | network bytes in/out per iface; uplink/downlink per inbound/user |
| Контейнеры панели | cAdvisor | per-container CPU/mem, рестарты, сеть, up/down |
| Доступность панели | blackbox (снаружи) + cAdvisor | HTTP 200 на :443, TLS cert expiry (дней до истечения), up backend |
| Доступность xray-ядра | blackbox tcp + xray-exporter | TCP-connect на inbound-порты, ядро отвечает по stats API, живость |

## Алерты (Alertmanager → Telegram)

Правила (в `central/prometheus/rules/`):

- **NodeDown** — нода/agent не скрейпится > N мин.
- **PanelDown** — blackbox HTTP на :443 не 200, или backend-контейнер down.
- **PanelCertExpiring** — TLS-сертификат панели истекает < 14 дней.
- **XrayCoreDown** — xray-exporter не отвечает / ядро не отдаёт stats, или
  blackbox tcp на inbound-порт лёг.
- **ContainerRestarting** — контейнер панели рестартит (restart count растёт).
- **DiskAlmostFull** — диск > 85%.
- **HighMemory / HighCPU** — устойчивая высокая нагрузка.
- **TrafficDropAnomaly** — трафик аномально просел (индикатор проблемы с ядром).

Маршрут: все алерты → Telegram receiver (`telegram_configs` с bot token + chat id
из `.env`). Группировка по ноде, разумные `repeat_interval`.

## Дашборды Grafana (provisioning as-code)

- **Nodes Overview** — здоровье всех нод одним взглядом (up/down, CPU/RAM/disk, трафик).
- **Node Detail** — детально по одной ноде: хост-метрики + контейнеры.
- **Xray Traffic** — трафик по inbound/user, uplink/downlink, тренды.
- **Availability** — статусы blackbox-проб панели и xray, cert expiry.

## Структура репозитория

```
central/
  docker-compose.yml
  prometheus/
    prometheus.yml
    rules/alerts.yml
    targets/            # file_sd — сюда добавляются ноды
  alertmanager/
    alertmanager.yml
  grafana/
    provisioning/datasources/
    provisioning/dashboards/
    dashboards/*.json
  blackbox/blackbox.yml
  .env.example
node-agent/
  docker-compose.yml
  Caddyfile
  .env.example
scripts/
  install-central.sh
  install-node.sh
  add-node.sh          # добавить ноду в prometheus file_sd
README.md
```

## Добавление новой ноды (рабочий процесс)

1. На ноде: скопировать `node-agent/`, заполнить `.env` (basic auth creds, xray
   API endpoint, порт), `docker compose up -d`.
2. На central: `scripts/add-node.sh <name> <host:8443>` — дописывает таргет в
   Prometheus file_sd, Prometheus подхватывает без рестарта.

## Допущения и точки проверки

- **xray stats API включён** (подтверждено). Точный адрес/порт gRPC API задаётся в
  `node-agent/.env`; xray-exporter должен иметь сетевой доступ к нему (agent
  подключается к docker-сети панели либо API-порт доступен на хосте).
- **Порт `:8443`** свободен на ноде (конфигурируется).
- Выбор конкретного образа xray-exporter уточняется на этапе плана (несколько
  community-вариантов; берём тот, что работает с gRPC StatsService xray-core).

## Явно вне скоупа (YAGNI)

- Логи (Loki/ELK) — только метрики.
- Long-term storage (Thanos/Cortex) — обычного Prometheus retention хватает.
- Автопровижн нод через Ansible/Terraform — установка скриптами вручную.
- Модификация самой панели.
