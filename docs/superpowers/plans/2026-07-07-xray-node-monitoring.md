# Мониторинг xray-нод ITG panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull-based мониторинг xray-нод под ITG Xray Panel — central Prometheus+Grafana+Alertmanager тянет метрики с N нод по HTTPS, алерты в Telegram.

**Architecture:** На каждой ноде — лёгкий docker-compose agent (node_exporter, cAdvisor, xray-exporter), закрытый reverse-proxy Caddy на `:8443` с TLS + basic auth, мультиплексирующим `/node`, `/cadvisor`, `/xray`. Центральный docker-compose стек скрейпит все ноды + blackbox-пробы панели/xray снаружи, правит алерты в Telegram, показывает дашборды в Grafana. Панель не модифицируется.

**Tech Stack:** Docker Compose, Prometheus, Grafana, Alertmanager, Blackbox exporter, node_exporter, cAdvisor, compassvpn/xray-exporter, Caddy.

## Global Constraints

- Панель ITG (её docker-compose, конфиг xray, Caddy) **не модифицируется** ни на одном шаге.
- Экспортёры наружу **не** публикуют порты — доступ только через caddy-metrics с basic auth + TLS.
- Все креды/хосты/порты — через `.env`, в git попадают только `*.env.example`.
- Образы **пиннятся по версии** (кроме xray-exporter, у которого только `:latest`).
- Валидация — «тест» каждой задачи: `docker compose config -q`, `promtool check`, `amtool check-config`, `curl`. Каждая задача заканчивается прохождением своего валидатора.
- Пиннинг образов (использовать ровно эти теги):
  - `prom/prometheus:v3.1.0`
  - `grafana/grafana:11.4.0`
  - `prom/alertmanager:v0.28.0`
  - `prom/blackbox-exporter:v0.26.0`
  - `quay.io/prometheus/node-exporter:v1.8.2`
  - `gcr.io/cadvisor/cadvisor:v0.49.1`
  - `caddy:2-alpine`
  - `ghcr.io/compassvpn/xray-exporter:latest`

---

## File Structure

```
central/
  docker-compose.yml
  .env.example
  prometheus/
    prometheus.yml
    targets/
      nodes.yml           # file_sd: host:8443 по нодам (agent метрики)
      blackbox-http.yml   # file_sd: https-URL панелей
      blackbox-tcp.yml    # file_sd: host:port xray-inbound'ов
    rules/
      alerts.yml
  alertmanager/
    alertmanager.yml
  blackbox/
    blackbox.yml
  grafana/
    provisioning/
      datasources/datasource.yml
      dashboards/dashboards.yml
    dashboards/
      nodes-overview.json
      node-detail.json
      xray-traffic.json
      availability.json
node-agent/
  docker-compose.yml
  Caddyfile
  .env.example
scripts/
  gen-htpasswd.sh
  install-node.sh
  install-central.sh
  add-node.sh
README.md
```

Файлы, меняющиеся вместе, лежат вместе: конфиг Prometheus + таргеты + правила в `central/prometheus/`; всё для ноды в `node-agent/`.

---

## Task 1: Node-agent — экспортёры + Caddy metrics-proxy

**Files:**
- Create: `node-agent/docker-compose.yml`
- Create: `node-agent/Caddyfile`
- Create: `node-agent/.env.example`
- Create: `scripts/gen-htpasswd.sh`

**Interfaces:**
- Produces: HTTPS-эндпоинт `https://<node>:8443` с basic auth, отдающий:
  - `GET /node/metrics`     → node_exporter (host-метрики)
  - `GET /cadvisor/metrics` → cAdvisor (контейнеры)
  - `GET /xray/metrics`     → xray-exporter (stats API)
- Produces: имена env — `METRICS_PORT`, `METRICS_USER`, `METRICS_PASSWORD_HASH`, `XRAY_API_ENDPOINT`, `PANEL_NETWORK`.

- [ ] **Step 1: Создать `scripts/gen-htpasswd.sh`** — генерит bcrypt-хеш для basic auth средствами Caddy.

```bash
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
```

- [ ] **Step 2: Создать `node-agent/.env.example`**

```dotenv
# Порт, на котором caddy-metrics отдаёт метрики наружу (TLS + basic auth)
METRICS_PORT=8443

# Basic auth. Хеш сгенерить: ./scripts/gen-htpasswd.sh <user> <password>
METRICS_USER=metrics
METRICS_PASSWORD_HASH=$2a$14$REPLACE_WITH_BCRYPT_HASH

# gRPC Stats API xray-ядра панели (имя сервиса:порт внутри docker-сети панели).
# Уточнить в docker-compose панели: имя контейнера xray и порт api-inbound.
XRAY_API_ENDPOINT=xray:10085

# Имя внешней docker-сети панели, к которой цепляется xray-exporter,
# чтобы достучаться до XRAY_API_ENDPOINT. Посмотреть: docker network ls
PANEL_NETWORK=itg_panel-net
```

- [ ] **Step 3: Создать `node-agent/Caddyfile`** — TLS (self-signed `tls internal`) + basic auth + мультиплекс путей со срезанием префикса.

```caddyfile
{
	admin off
	auto_https disable_redirects
}

:{$METRICS_PORT} {
	tls internal

	basic_auth {
		{$METRICS_USER} {$METRICS_PASSWORD_HASH}
	}

	handle_path /node/* {
		reverse_proxy node-exporter:9100
	}
	handle_path /cadvisor/* {
		reverse_proxy cadvisor:8080
	}
	handle_path /xray/* {
		reverse_proxy xray-exporter:9550
	}

	respond "ok" 200
}
```

- [ ] **Step 4: Создать `node-agent/docker-compose.yml`**

```yaml
name: itg-mon-agent

networks:
  agent-net:
    driver: bridge
  panel-net:
    external: true
    name: ${PANEL_NETWORK}

services:
  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.8.2
    container_name: mon-node-exporter
    restart: unless-stopped
    command:
      - --path.rootfs=/host
      - --collector.systemd
      - --collector.processes
    pid: host
    network_mode: host
    volumes:
      - /:/host:ro,rslave

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: mon-cadvisor
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    networks:
      - agent-net

  xray-exporter:
    image: ghcr.io/compassvpn/xray-exporter:latest
    container_name: mon-xray-exporter
    restart: unless-stopped
    command:
      - --xray-endpoint=${XRAY_API_ENDPOINT}
      - --listen=:9550
      - --metrics-path=/metrics
    networks:
      - agent-net
      - panel-net

  caddy-metrics:
    image: caddy:2-alpine
    container_name: mon-caddy-metrics
    restart: unless-stopped
    environment:
      METRICS_PORT: ${METRICS_PORT}
      METRICS_USER: ${METRICS_USER}
      METRICS_PASSWORD_HASH: ${METRICS_PASSWORD_HASH}
    ports:
      - "${METRICS_PORT}:${METRICS_PORT}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    networks:
      - agent-net

volumes:
  caddy-data:
```

> Примечание: `node-exporter` в `network_mode: host` не резолвится по имени внутри `agent-net`. Caddy проксирует его через host-порт — см. Step 5 (правка reverse_proxy на `host.docker.internal:9100` / IP шлюза). Разрешаем это здесь же.

- [ ] **Step 5: Поправить проксирование node-exporter** (host-network) — в `node-agent/Caddyfile` заменить target на адрес хоста из контейнера Caddy.

Заменить блок `/node/*`:

```caddyfile
	handle_path /node/* {
		reverse_proxy host.docker.internal:9100
	}
```

И добавить в сервис `caddy-metrics` в `node-agent/docker-compose.yml` (после `networks:`):

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

- [ ] **Step 6: Валидация конфига compose**

Run:
```bash
cd node-agent && cp .env.example .env && \
sed -i 's#\$2a\$14\$REPLACE_WITH_BCRYPT_HASH#$2a$14$abcdefghijklmnopqrstuv#' .env && \
docker compose config -q && echo OK
```
Expected: `OK` (без ошибок парсинга/подстановки переменных).

- [ ] **Step 7: Smoke-тест на живой ноде** (выполняется на ноде с панелью; в dev — пропустить с пометкой)

Run:
```bash
cd node-agent && docker compose up -d && sleep 8 && \
curl -sk -u "$METRICS_USER:PLAINTEXT_PASS" https://localhost:8443/node/metrics | head -3 && \
curl -sk -u "$METRICS_USER:PLAINTEXT_PASS" https://localhost:8443/cadvisor/metrics | head -3 && \
curl -sk -u "$METRICS_USER:PLAINTEXT_PASS" https://localhost:8443/xray/metrics | head -3
```
Expected: по три строки метрик из каждого эндпоинта (`# HELP ...`). Если `/xray` пустой — проверить `XRAY_API_ENDPOINT` и что xray-exporter в сети `panel-net`.

- [ ] **Step 8: Commit**

```bash
git add node-agent/ scripts/gen-htpasswd.sh
git commit -m "feat: node-agent stack (экспортёры + caddy metrics-proxy)"
```

---

## Task 2: Central — Prometheus + scrape нод

**Files:**
- Create: `central/docker-compose.yml`
- Create: `central/.env.example`
- Create: `central/prometheus/prometheus.yml`
- Create: `central/prometheus/targets/nodes.yml`

**Interfaces:**
- Consumes: эндпоинты Task 1 (`/node/metrics`, `/cadvisor/metrics`, `/xray/metrics`) с basic auth.
- Produces: работающий Prometheus на `:9090`, job'ы `node`, `cadvisor`, `xray`, читающие таргеты из `targets/nodes.yml` (file_sd).
- Produces: env — `METRICS_USER`, `METRICS_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `PROM_RETENTION`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.

- [ ] **Step 1: Создать `central/.env.example`**

```dotenv
# Basic auth для скрейпа нод (совпадает с METRICS_USER/паролем в node-agent)
METRICS_USER=metrics
METRICS_PASSWORD=REPLACE_WITH_PLAINTEXT_PASSWORD

# Grafana
GRAFANA_ADMIN_PASSWORD=REPLACE_ME

# Prometheus retention
PROM_RETENTION=30d

# Alertmanager → Telegram
TELEGRAM_BOT_TOKEN=REPLACE_WITH_BOT_TOKEN
TELEGRAM_CHAT_ID=REPLACE_WITH_CHAT_ID
```

- [ ] **Step 2: Создать `central/prometheus/targets/nodes.yml`** — file_sd со списком нод. Одна запись на ноду, метка `node` для человекочитаемого имени.

```yaml
- targets:
    - "node1.example.com:8443"
  labels:
    node: "node1"
# Добавлять ноды сюда (или через scripts/add-node.sh):
# - targets: ["node2.example.com:8443"]
#   labels: { node: "node2" }
```

- [ ] **Step 3: Создать `central/prometheus/prometheus.yml`** — три job'а на один и тот же file_sd с разными `metrics_path`, basic auth и `insecure_skip_verify` (self-signed).

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: node
    scheme: https
    metrics_path: /node/metrics
    basic_auth:
      username: ${METRICS_USER}
      password: ${METRICS_PASSWORD}
    tls_config:
      insecure_skip_verify: true
    file_sd_configs:
      - files: ["/etc/prometheus/targets/nodes.yml"]

  - job_name: cadvisor
    scheme: https
    metrics_path: /cadvisor/metrics
    basic_auth:
      username: ${METRICS_USER}
      password: ${METRICS_PASSWORD}
    tls_config:
      insecure_skip_verify: true
    file_sd_configs:
      - files: ["/etc/prometheus/targets/nodes.yml"]

  - job_name: xray
    scheme: https
    metrics_path: /xray/metrics
    basic_auth:
      username: ${METRICS_USER}
      password: ${METRICS_PASSWORD}
    tls_config:
      insecure_skip_verify: true
    file_sd_configs:
      - files: ["/etc/prometheus/targets/nodes.yml"]
```

> `${METRICS_USER}`/`${METRICS_PASSWORD}` Prometheus подставляет из окружения при старте с флагом `--enable-feature=expand-external-labels`? Нет — для basic_auth Prometheus поддерживает подстановку env начиная с v2.53 через синтаксис `${VAR}` только если запущен с `--config.expand-env`... В v3 такой подстановки нет. Решение в Step 4: рендерим prometheus.yml через `envsubst` в entrypoint.

- [ ] **Step 4: Создать `central/docker-compose.yml`** (пока только Prometheus + Grafana-заглушка добавится в Task 6). Prometheus рендерит конфиг через envsubst перед стартом.

```yaml
name: itg-mon-central

networks:
  mon-net:
    driver: bridge

services:
  prometheus:
    image: prom/prometheus:v3.1.0
    container_name: mon-prometheus
    restart: unless-stopped
    env_file: .env
    entrypoint:
      - /bin/sh
      - -c
      - |
        apk add --no-cache gettext >/dev/null 2>&1 || true
        envsubst '$$METRICS_USER $$METRICS_PASSWORD' \
          < /etc/prometheus/prometheus.tmpl.yml > /tmp/prometheus.yml
        exec /bin/prometheus \
          --config.file=/tmp/prometheus.yml \
          --storage.tsdb.path=/prometheus \
          --storage.tsdb.retention.time=$${PROM_RETENTION} \
          --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.tmpl.yml:ro
      - ./prometheus/targets:/etc/prometheus/targets:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - mon-net

volumes:
  prometheus-data:
```

> `prom/prometheus` образ на busybox/nobody — `apk` может быть недоступен. Если `envsubst` нет, Step 4b даёт fallback.

- [ ] **Step 4b: Гарантировать `envsubst`** — заменить entrypoint на использование sidecar-рендера через `alpine`. Заменить сервис `prometheus` целиком:

```yaml
  prom-render:
    image: alpine:3.20
    container_name: mon-prom-render
    env_file: .env
    command:
      - /bin/sh
      - -c
      - |
        apk add --no-cache gettext >/dev/null
        envsubst '$$METRICS_USER $$METRICS_PASSWORD' \
          < /in/prometheus.yml > /out/prometheus.yml
    volumes:
      - ./prometheus/prometheus.yml:/in/prometheus.yml:ro
      - prom-config:/out
    networks:
      - mon-net

  prometheus:
    image: prom/prometheus:v3.1.0
    container_name: mon-prometheus
    restart: unless-stopped
    env_file: .env
    depends_on:
      prom-render:
        condition: service_completed_successfully
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROM_RETENTION}
      - --web.enable-lifecycle
    volumes:
      - prom-config:/etc/prometheus
      - ./prometheus/targets:/etc/prometheus/targets:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - mon-net
```

И добавить в блок `volumes:` в конце файла:

```yaml
  prom-config:
```

- [ ] **Step 5: Создать пустой каталог правил-заглушку**, чтобы Prometheus стартовал до Task 4.

Run:
```bash
mkdir -p central/prometheus/rules && \
printf 'groups: []\n' > central/prometheus/rules/alerts.yml
```

- [ ] **Step 6: Валидация prometheus.yml через promtool** (рендерим env вручную для проверки).

Run:
```bash
cd central && cp .env.example .env && \
sed -i 's/REPLACE_WITH_PLAINTEXT_PASSWORD/testpass/' .env && \
export METRICS_USER=metrics METRICS_PASSWORD=testpass && \
envsubst '$METRICS_USER $METRICS_PASSWORD' < prometheus/prometheus.yml > /tmp/prom-check.yml && \
docker run --rm -v /tmp/prom-check.yml:/p.yml -v "$PWD/prometheus/targets":/t:ro \
  -v "$PWD/prometheus/rules":/r:ro prom/prometheus:v3.1.0 \
  promtool check config /p.yml
```
Expected: `SUCCESS: ... /p.yml is valid prometheus config file` и валидные file_sd/rule_files.

- [ ] **Step 7: Валидация compose**

Run: `cd central && docker compose config -q && echo OK`
Expected: `OK`.

- [ ] **Step 8: Commit**

```bash
git add central/docker-compose.yml central/.env.example central/prometheus/
git commit -m "feat: central Prometheus + scrape нод (file_sd, envsubst-рендер)"
```

---

## Task 3: Central — Blackbox exporter + пробы панели/xray снаружи

**Files:**
- Create: `central/blackbox/blackbox.yml`
- Create: `central/prometheus/targets/blackbox-http.yml`
- Create: `central/prometheus/targets/blackbox-tcp.yml`
- Modify: `central/docker-compose.yml` (добавить сервис blackbox)
- Modify: `central/prometheus/prometheus.yml` (добавить job'ы blackbox)

**Interfaces:**
- Consumes: публичные адреса панели (https) и xray-inbound'ов (tcp).
- Produces: метрики `probe_success`, `probe_ssl_earliest_cert_expiry`, `probe_http_status_code` с меткой `node`.

- [ ] **Step 1: Создать `central/blackbox/blackbox.yml`**

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: [200, 204, 301, 302, 401, 403]
      method: GET
      fail_if_not_ssl: true
      tls_config:
        insecure_skip_verify: false
      preferred_ip_protocol: ip4
  tcp_connect:
    prober: tcp
    timeout: 8s
    tcp:
      preferred_ip_protocol: ip4
```

> Панель за Caddy может отдавать 401/403 на корне без креды — это всё равно «жива». Cert expiry берём из `probe_ssl_earliest_cert_expiry`.

- [ ] **Step 2: Создать `central/prometheus/targets/blackbox-http.yml`**

```yaml
- targets:
    - "https://node1.example.com"
  labels:
    node: "node1"
```

- [ ] **Step 3: Создать `central/prometheus/targets/blackbox-tcp.yml`** — xray inbound-порты (публичные), проверка TCP-connect.

```yaml
- targets:
    - "node1.example.com:443"
  labels:
    node: "node1"
    check: "xray-inbound"
```

- [ ] **Step 4: Добавить сервис blackbox в `central/docker-compose.yml`** (перед `volumes:`).

```yaml
  blackbox:
    image: prom/blackbox-exporter:v0.26.0
    container_name: mon-blackbox
    restart: unless-stopped
    command:
      - --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox/blackbox.yml:ro
    networks:
      - mon-net
```

- [ ] **Step 5: Добавить job'ы blackbox в `central/prometheus/prometheus.yml`** (в конец `scrape_configs`). Классический relabel-паттерн blackbox.

```yaml
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files: ["/etc/prometheus/targets/blackbox-http.yml"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files: ["/etc/prometheus/targets/blackbox-tcp.yml"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

- [ ] **Step 6: Валидация**

Run:
```bash
cd central && export METRICS_USER=metrics METRICS_PASSWORD=testpass && \
envsubst '$METRICS_USER $METRICS_PASSWORD' < prometheus/prometheus.yml > /tmp/prom-check.yml && \
docker run --rm -v /tmp/prom-check.yml:/p.yml -v "$PWD/prometheus/targets":/t:ro \
  -v "$PWD/prometheus/rules":/r:ro prom/prometheus:v3.1.0 promtool check config /p.yml && \
docker compose config -q && echo OK
```
Expected: `SUCCESS ... is valid` + `OK`.

- [ ] **Step 7: Commit**

```bash
git add central/blackbox central/prometheus/prometheus.yml central/prometheus/targets central/docker-compose.yml
git commit -m "feat: blackbox-пробы доступности панели и xray-инбаундов"
```

---

## Task 4: Central — правила алертов

**Files:**
- Modify: `central/prometheus/rules/alerts.yml` (заменить заглушку)

**Interfaces:**
- Consumes: метрики job'ов `node`, `cadvisor`, `xray`, `blackbox-http`, `blackbox-tcp`.
- Produces: алерты по именам из спеки; порог TrafficSpike вынесен в выражение (5e9 бит/с = ~5 Гбит/с; редактируется тут).

- [ ] **Step 1: Заменить содержимое `central/prometheus/rules/alerts.yml`**

```yaml
groups:
  - name: availability
    rules:
      - alert: NodeDown
        expr: up{job="node"} == 0
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "Нода {{ $labels.node }} не скрейпится"
          description: "Prometheus не может собрать метрики agent'а > 3 мин."

      - alert: PanelDown
        expr: probe_success{job="blackbox-http"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "Панель {{ $labels.node }} недоступна"
          description: "Blackbox HTTP-проба панели не проходит > 2 мин."

      - alert: PanelCertExpiring
        expr: (probe_ssl_earliest_cert_expiry{job="blackbox-http"} - time()) / 86400 < 14
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: "TLS-сертификат панели {{ $labels.node }} истекает"
          description: "Осталось {{ printf \"%.0f\" (div (sub $value 0) 1) }} дн. (< 14)."

      - alert: XrayCoreDown
        expr: up{job="xray"} == 0 or probe_success{job="blackbox-tcp"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "Xray-ядро на {{ $labels.node }} не отвечает"
          description: "xray-exporter не отдаёт stats ИЛИ TCP на inbound-порт лёг."

  - name: containers
    rules:
      - alert: ContainerRestarting
        expr: increase(container_start_time_seconds{name=~"panel.*|.*xray.*|.*caddy.*|.*redis.*|.*bot.*"}[10m]) > 0
        for: 0m
        labels: { severity: warning }
        annotations:
          summary: "Контейнер {{ $labels.name }} на {{ $labels.node }} рестартнул"
          description: "container_start_time вырос за последние 10 мин."

  - name: resources
    rules:
      - alert: DiskAlmostFull
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100 > 85
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Диск на {{ $labels.node }} заполнен > 85%"
          description: "{{ $labels.mountpoint }}: {{ printf \"%.1f\" $value }}%."

      - alert: HighMemory
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Память на {{ $labels.node }} > 90%"
          description: "Использование RAM устойчиво высокое."

      - alert: HighCPU
        expr: (1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100 > 90
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "CPU на {{ $labels.node }} > 90%"
          description: "Загрузка CPU устойчиво высокая > 15 мин."

  - name: traffic
    rules:
      - alert: TrafficSpike
        expr: sum by (node) (rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m]) * 8) > 5e9
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Аномальный всплеск трафика на {{ $labels.node }}"
          description: "Входящий трафик > 5 Гбит/с ({{ printf \"%.2f\" (div $value 1e9) }} Гбит/с). DDoS/абьюз?"

      - alert: TrafficDropAnomaly
        expr: |
          sum by (node) (rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m]))
          < 0.05 * sum by (node) (rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[1h] offset 1h))
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "Трафик на {{ $labels.node }} аномально просел"
          description: "Текущий трафик < 5% от среднего за прошлый час. Проблема с ядром?"
```

- [ ] **Step 2: Валидация правил через promtool**

Run:
```bash
cd central && docker run --rm -v "$PWD/prometheus/rules":/r:ro \
  prom/prometheus:v3.1.0 promtool check rules /r/alerts.yml
```
Expected: `SUCCESS: ... alerts.yml` и `Found N rules` (N ≈ 10).

- [ ] **Step 3: Commit**

```bash
git add central/prometheus/rules/alerts.yml
git commit -m "feat: правила алертов (down/cert/xray/ресурсы/трафик spike+drop)"
```

---

## Task 5: Central — Alertmanager → Telegram

**Files:**
- Create: `central/alertmanager/alertmanager.yml`
- Modify: `central/docker-compose.yml` (добавить сервис alertmanager + рендер env)

**Interfaces:**
- Consumes: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` из `.env`.
- Produces: приёмник алертов на `:9093`, слушающий Prometheus (job `alerting` из Task 2).

- [ ] **Step 1: Создать `central/alertmanager/alertmanager.yml`** — нативный Telegram receiver.

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: telegram
  group_by: ["node", "alertname"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 3h

receivers:
  - name: telegram
    telegram_configs:
      - bot_token: ${TELEGRAM_BOT_TOKEN}
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: HTML
        send_resolved: true
        message: |
          <b>{{ .Status | toUpper }}</b> {{ if eq .Status "firing" }}🔥{{ else }}✅{{ end }}
          {{ range .Alerts }}<b>{{ .Labels.alertname }}</b> — {{ .Labels.severity }}
          node: {{ .Labels.node }}
          {{ .Annotations.summary }}
          {{ .Annotations.description }}
          {{ end }}
```

> `chat_id` в telegram_configs — число (int64). В `.env` задать голым числом; envsubst подставит.

- [ ] **Step 2: Добавить рендер+сервис alertmanager в `central/docker-compose.yml`**. Расширить `prom-render` (Task 2 Step 4b), чтобы он рендерил и alertmanager. Заменить `command` у `prom-render`:

```yaml
    command:
      - /bin/sh
      - -c
      - |
        apk add --no-cache gettext >/dev/null
        envsubst '$$METRICS_USER $$METRICS_PASSWORD' \
          < /in/prometheus.yml > /out/prometheus.yml
        envsubst '$$TELEGRAM_BOT_TOKEN $$TELEGRAM_CHAT_ID' \
          < /in/alertmanager.yml > /out/alertmanager.yml
```

Добавить в volumes сервиса `prom-render`:

```yaml
      - ./alertmanager/alertmanager.yml:/in/alertmanager.yml:ro
```

Добавить сервис `alertmanager` (перед `volumes:`):

```yaml
  alertmanager:
    image: prom/alertmanager:v0.28.0
    container_name: mon-alertmanager
    restart: unless-stopped
    depends_on:
      prom-render:
        condition: service_completed_successfully
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
    volumes:
      - prom-config:/etc/alertmanager
    ports:
      - "9093:9093"
    networks:
      - mon-net
```

> `prom-config` volume уже содержит отрендеренный `alertmanager.yml` (тот же out-каталог, что и prometheus.yml). Alertmanager читает `/etc/alertmanager/alertmanager.yml` — примонтирован тот же volume.

- [ ] **Step 3: Валидация alertmanager.yml через amtool**

Run:
```bash
cd central && export TELEGRAM_BOT_TOKEN=123:abc TELEGRAM_CHAT_ID=100500 && \
envsubst '$TELEGRAM_BOT_TOKEN $TELEGRAM_CHAT_ID' < alertmanager/alertmanager.yml > /tmp/am.yml && \
docker run --rm -v /tmp/am.yml:/am.yml prom/alertmanager:v0.28.0 amtool check-config /am.yml
```
Expected: `Checking '/am.yml'  SUCCESS` + `Found ... 1 receivers`.

- [ ] **Step 4: Валидация compose**

Run: `cd central && docker compose config -q && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add central/alertmanager central/docker-compose.yml
git commit -m "feat: Alertmanager с нативной отправкой алертов в Telegram"
```

---

## Task 6: Central — Grafana provisioning + дашборды

**Files:**
- Create: `central/grafana/provisioning/datasources/datasource.yml`
- Create: `central/grafana/provisioning/dashboards/dashboards.yml`
- Create: `central/grafana/dashboards/nodes-overview.json`
- Create: `central/grafana/dashboards/node-detail.json`
- Create: `central/grafana/dashboards/xray-traffic.json`
- Create: `central/grafana/dashboards/availability.json`
- Modify: `central/docker-compose.yml` (добавить сервис grafana)

**Interfaces:**
- Consumes: Prometheus datasource на `http://prometheus:9090`.
- Produces: Grafana на `:3000` с автоподхватом 4 дашбордов.

- [ ] **Step 1: Создать `central/grafana/provisioning/datasources/datasource.yml`**

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    uid: prometheus
```

- [ ] **Step 2: Создать `central/grafana/provisioning/dashboards/dashboards.yml`**

```yaml
apiVersion: 1
providers:
  - name: ITG-mon
    orgId: 1
    folder: "ITG Monitoring"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 3: Создать `central/grafana/dashboards/nodes-overview.json`** — обзор всех нод (up/down, CPU/RAM/disk, суммарный трафик). Минимальный валидный дашборд с шаблонной переменной `node`.

```json
{
  "uid": "nodes-overview",
  "title": "Nodes Overview",
  "tags": ["itg", "nodes"],
  "timezone": "browser",
  "schemaVersion": 39,
  "time": { "from": "now-6h", "to": "now" },
  "templating": { "list": [
    { "name": "node", "type": "query", "datasource": { "type": "prometheus", "uid": "prometheus" },
      "query": "label_values(up{job=\"node\"}, node)", "includeAll": true, "multi": true, "current": {} }
  ]},
  "panels": [
    { "id": 1, "type": "stat", "title": "Nodes Up", "gridPos": {"h":4,"w":6,"x":0,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"count(up{job=\"node\"} == 1)","refId":"A"}] },
    { "id": 2, "type": "stat", "title": "Nodes Down", "gridPos": {"h":4,"w":6,"x":6,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"count(up{job=\"node\"} == 0) or vector(0)","refId":"A"}] },
    { "id": 3, "type": "timeseries", "title": "CPU % by node", "gridPos": {"h":8,"w":12,"x":0,"y":4},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"(1 - avg by (node) (rate(node_cpu_seconds_total{mode=\"idle\",node=~\"$node\"}[5m]))) * 100","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 4, "type": "timeseries", "title": "RAM % by node", "gridPos": {"h":8,"w":12,"x":12,"y":4},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"(1 - (node_memory_MemAvailable_bytes{node=~\"$node\"} / node_memory_MemTotal_bytes{node=~\"$node\"})) * 100","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 5, "type": "timeseries", "title": "Network in (bit/s)", "gridPos": {"h":8,"w":24,"x":0,"y":12},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "fieldConfig": {"defaults": {"unit": "bps"}, "overrides": []},
      "targets": [{"expr":"sum by (node) (rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*|br-.*\",node=~\"$node\"}[5m]) * 8)","refId":"A","legendFormat":"{{node}}"}] }
  ]
}
```

- [ ] **Step 4: Создать `central/grafana/dashboards/node-detail.json`** — детально по одной ноде (хост + контейнеры).

```json
{
  "uid": "node-detail",
  "title": "Node Detail",
  "tags": ["itg", "nodes"],
  "schemaVersion": 39,
  "time": { "from": "now-6h", "to": "now" },
  "templating": { "list": [
    { "name": "node", "type": "query", "datasource": {"type":"prometheus","uid":"prometheus"},
      "query": "label_values(up{job=\"node\"}, node)", "includeAll": false, "multi": false, "current": {} }
  ]},
  "panels": [
    { "id": 1, "type": "timeseries", "title": "Load average", "gridPos": {"h":8,"w":12,"x":0,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"node_load1{node=~\"$node\"}","refId":"A","legendFormat":"load1"},{"expr":"node_load5{node=~\"$node\"}","refId":"B","legendFormat":"load5"}] },
    { "id": 2, "type": "timeseries", "title": "Disk used %", "gridPos": {"h":8,"w":12,"x":12,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "fieldConfig": {"defaults": {"unit": "percent"}, "overrides": []},
      "targets": [{"expr":"(1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\",node=~\"$node\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\",node=~\"$node\"})) * 100","refId":"A","legendFormat":"{{mountpoint}}"}] },
    { "id": 3, "type": "timeseries", "title": "Container CPU", "gridPos": {"h":8,"w":12,"x":0,"y":8},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"sum by (name) (rate(container_cpu_usage_seconds_total{name!=\"\",node=~\"$node\"}[5m]))","refId":"A","legendFormat":"{{name}}"}] },
    { "id": 4, "type": "timeseries", "title": "Container memory", "gridPos": {"h":8,"w":12,"x":12,"y":8},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "fieldConfig": {"defaults": {"unit": "bytes"}, "overrides": []},
      "targets": [{"expr":"sum by (name) (container_memory_usage_bytes{name!=\"\",node=~\"$node\"})","refId":"A","legendFormat":"{{name}}"}] }
  ]
}
```

- [ ] **Step 5: Создать `central/grafana/dashboards/xray-traffic.json`** — трафик по inbound/user из xray-exporter. Имена метрик xray-exporter: `xray_uplink_bytes_total`, `xray_downlink_bytes_total` с метками `source`/`name` (уточнить по факту скрейпа `/xray/metrics`; запросы используют `__name__=~"xray_.*link.*"`-совместимые имена ниже, при расхождении поправить legend/expr).

```json
{
  "uid": "xray-traffic",
  "title": "Xray Traffic",
  "tags": ["itg", "xray"],
  "schemaVersion": 39,
  "time": { "from": "now-6h", "to": "now" },
  "templating": { "list": [
    { "name": "node", "type": "query", "datasource": {"type":"prometheus","uid":"prometheus"},
      "query": "label_values(up{job=\"xray\"}, node)", "includeAll": true, "multi": true, "current": {} }
  ]},
  "panels": [
    { "id": 1, "type": "timeseries", "title": "Uplink rate (bit/s)", "gridPos": {"h":8,"w":12,"x":0,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "fieldConfig": {"defaults": {"unit": "bps"}, "overrides": []},
      "targets": [{"expr":"sum by (node) (rate(xray_uplink_bytes_total{node=~\"$node\"}[5m]) * 8)","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 2, "type": "timeseries", "title": "Downlink rate (bit/s)", "gridPos": {"h":8,"w":12,"x":12,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "fieldConfig": {"defaults": {"unit": "bps"}, "overrides": []},
      "targets": [{"expr":"sum by (node) (rate(xray_downlink_bytes_total{node=~\"$node\"}[5m]) * 8)","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 3, "type": "table", "title": "Top traffic by source", "gridPos": {"h":10,"w":24,"x":0,"y":8},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"topk(20, sum by (source) (rate(xray_downlink_bytes_total{node=~\"$node\"}[5m]) * 8))","refId":"A","format":"table","instant":true}] }
  ]
}
```

- [ ] **Step 6: Создать `central/grafana/dashboards/availability.json`** — blackbox-пробы + cert expiry.

```json
{
  "uid": "availability",
  "title": "Availability",
  "tags": ["itg", "availability"],
  "schemaVersion": 39,
  "time": { "from": "now-24h", "to": "now" },
  "panels": [
    { "id": 1, "type": "state-timeline", "title": "Panel HTTP up", "gridPos": {"h":8,"w":24,"x":0,"y":0},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"probe_success{job=\"blackbox-http\"}","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 2, "type": "state-timeline", "title": "Xray inbound TCP up", "gridPos": {"h":8,"w":24,"x":0,"y":8},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"probe_success{job=\"blackbox-tcp\"}","refId":"A","legendFormat":"{{node}}"}] },
    { "id": 3, "type": "table", "title": "TLS cert days left", "gridPos": {"h":8,"w":24,"x":0,"y":16},
      "datasource": {"type":"prometheus","uid":"prometheus"},
      "targets": [{"expr":"(probe_ssl_earliest_cert_expiry{job=\"blackbox-http\"} - time()) / 86400","refId":"A","format":"table","instant":true,"legendFormat":"{{node}}"}] }
  ]
}
```

- [ ] **Step 7: Добавить сервис grafana в `central/docker-compose.yml`** (перед `volumes:`).

```yaml
  grafana:
    image: grafana/grafana:11.4.0
    container_name: mon-grafana
    restart: unless-stopped
    env_file: .env
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
    networks:
      - mon-net
    depends_on:
      - prometheus
```

Добавить в блок `volumes:` в конце файла:

```yaml
  grafana-data:
```

- [ ] **Step 8: Валидация JSON дашбордов**

Run:
```bash
cd central && for f in grafana/dashboards/*.json; do \
  docker run --rm -v "$PWD/$f":/d.json:ro alpine:3.20 \
    sh -c "apk add -q jq && jq -e '.uid and .title and .panels' /d.json >/dev/null" \
  && echo "$f OK" || echo "$f FAIL"; done
```
Expected: по строке `... OK` на каждый из 4 файлов.

- [ ] **Step 9: Валидация compose**

Run: `cd central && docker compose config -q && echo OK`
Expected: `OK`.

- [ ] **Step 10: Commit**

```bash
git add central/grafana central/docker-compose.yml
git commit -m "feat: Grafana provisioning + 4 дашборда (nodes/detail/xray/availability)"
```

---

## Task 7: Скрипты установки + README

**Files:**
- Create: `scripts/install-node.sh`
- Create: `scripts/install-central.sh`
- Create: `scripts/add-node.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: `node-agent/`, `central/` из предыдущих задач.
- Produces: `add-node.sh <name> <host:port>` дописывает таргеты в 3 file_sd файла и перезагружает Prometheus через lifecycle API.

- [ ] **Step 1: Создать `scripts/install-node.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../node-agent"
if [ ! -f .env ]; then
  cp .env.example .env
  echo ">> Заполни node-agent/.env (METRICS_*, XRAY_API_ENDPOINT, PANEL_NETWORK) и перезапусти."
  echo ">> Хеш пароля: ../scripts/gen-htpasswd.sh <user> <password>"
  exit 1
fi
docker compose pull
docker compose up -d
echo ">> Agent поднят. Проверь: curl -sk -u USER:PASS https://localhost:\${METRICS_PORT}/node/metrics | head"
```

- [ ] **Step 2: Создать `scripts/install-central.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../central"
if [ ! -f .env ]; then
  cp .env.example .env
  echo ">> Заполни central/.env (METRICS_*, GRAFANA_ADMIN_PASSWORD, TELEGRAM_*) и перезапусти."
  exit 1
fi
docker compose pull
docker compose up -d
echo ">> Central поднят: Grafana :3000, Prometheus :9090, Alertmanager :9093"
```

- [ ] **Step 3: Создать `scripts/add-node.sh`** — добавляет ноду в 3 file_sd + reload.

```bash
#!/usr/bin/env bash
set -euo pipefail
# Использование: ./scripts/add-node.sh <name> <host> [metrics_port] [xray_tcp_port]
NAME="${1:?name}"; HOST="${2:?host}"; MPORT="${3:-8443}"; XPORT="${4:-443}"
DIR="$(dirname "$0")/../central/prometheus/targets"

append() { # file, target, extra_labels_yaml
  cat >> "$1" <<EOF
- targets: ["$2"]
  labels:
    node: "$NAME"$3
EOF
}

append "$DIR/nodes.yml"         "$HOST:$MPORT" ""
append "$DIR/blackbox-http.yml" "https://$HOST" ""
append "$DIR/blackbox-tcp.yml"  "$HOST:$XPORT" $'\n    check: "xray-inbound"'

echo ">> Нода $NAME добавлена. Перезагружаю Prometheus..."
curl -fsS -X POST http://localhost:9090/-/reload && echo " reloaded" || \
  echo ">> reload не прошёл (Prometheus не запущен?). file_sd подхватится сам в течение ~1 мин."
```

- [ ] **Step 4: Создать `README.md`** — как разворачивать central и ноды, как добавлять ноды, требования.

```markdown
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
```

- [ ] **Step 5: Сделать скрипты исполняемыми и проверить синтаксис**

Run:
```bash
chmod +x scripts/*.sh && for s in scripts/*.sh; do bash -n "$s" && echo "$s OK"; done
```
Expected: `scripts/add-node.sh OK`, `scripts/gen-htpasswd.sh OK`, `scripts/install-central.sh OK`, `scripts/install-node.sh OK`.

- [ ] **Step 6: Тест add-node.sh** (на копии, без Prometheus)

Run:
```bash
cp central/prometheus/targets/nodes.yml /tmp/nodes.bak && \
./scripts/add-node.sh testnode test.example.com 8443 443 || true && \
grep -q "test.example.com:8443" central/prometheus/targets/nodes.yml && \
grep -q "https://test.example.com" central/prometheus/targets/blackbox-http.yml && \
echo "ADD-NODE OK" && \
docker run --rm -v "$PWD/central/prometheus/targets":/t:ro prom/prometheus:v3.1.0 \
  promtool check config /t/../prometheus.yml 2>/dev/null; \
git checkout central/prometheus/targets/ 2>/dev/null || true
```
Expected: `ADD-NODE OK` (таргеты дописались, YAML остаётся валидным).

- [ ] **Step 7: Commit**

```bash
git add scripts/ README.md
git commit -m "feat: скрипты установки (install-node/central, add-node) + README"
```

---

## Task 8: End-to-end проверка стека central

**Files:** нет новых — только запуск и проверка.

**Interfaces:**
- Consumes: весь `central/` стек.
- Produces: подтверждение, что стек стартует, Prometheus видит job'ы, Grafana отдаёт дашборды, Alertmanager принял конфиг.

- [ ] **Step 1: Поднять central локально**

Run:
```bash
cd central && cp -n .env.example .env && \
sed -i 's/REPLACE_WITH_PLAINTEXT_PASSWORD/testpass/; s/REPLACE_ME/admin123/; s/REPLACE_WITH_BOT_TOKEN/123:abc/; s/REPLACE_WITH_CHAT_ID/100500/' .env && \
docker compose up -d && sleep 15
```
Expected: контейнеры `mon-prometheus`, `mon-grafana`, `mon-alertmanager`, `mon-blackbox` в `Up`.

- [ ] **Step 2: Prometheus поднял конфиг и правила**

Run:
```bash
curl -fsS http://localhost:9090/-/ready && echo && \
curl -fsS http://localhost:9090/api/v1/rules | docker run --rm -i alpine:3.20 sh -c "apk add -q jq && jq '.data.groups | length'"
```
Expected: `Prometheus Server is Ready.` и число групп правил `4`.

- [ ] **Step 3: Job'ы присутствуют**

Run:
```bash
curl -fsS 'http://localhost:9090/api/v1/label/job/values' | docker run --rm -i alpine:3.20 sh -c "apk add -q jq && jq -r '.data[]'"
```
Expected: среди значений — `blackbox-http`, `blackbox-tcp`, `cadvisor`, `node`, `prometheus`, `xray`.

- [ ] **Step 4: Alertmanager принят Prometheus'ом**

Run:
```bash
curl -fsS http://localhost:9090/api/v1/alertmanagers | docker run --rm -i alpine:3.20 sh -c "apk add -q jq && jq '.data.activeAlertmanagers | length'"
```
Expected: `1`.

- [ ] **Step 5: Grafana отдаёт дашборды**

Run:
```bash
curl -fsS -u admin:admin123 http://localhost:3000/api/search?query=Nodes | docker run --rm -i alpine:3.20 sh -c "apk add -q jq && jq -r '.[].title'"
```
Expected: в списке `Nodes Overview` (и остальные при query без фильтра).

- [ ] **Step 6: Погасить стек**

Run: `cd central && docker compose down`
Expected: контейнеры остановлены и удалены.

- [ ] **Step 7: Финальный commit (если были правки)**

```bash
git add -A && git commit -m "test: e2e-проверка central-стека" --allow-empty
```

---

## Self-Review (выполнено при написании)

- **Покрытие спеки:** топология (Task 2 file_sd, Task 7 add-node) ✓; node_exporter/cAdvisor/xray-exporter (Task 1) ✓; caddy TLS+auth на отдельном порту (Task 1) ✓; blackbox доступность панели+xray+cert (Task 3) ✓; все алерты включая TrafficSpike 5 Гбит/с и TrafficDropAnomaly (Task 4) ✓; Alertmanager→Telegram (Task 5) ✓; 4 дашборда (Task 6) ✓; структура репо + скрипты + README (Task 7) ✓; «панель не трогаем» — соблюдено (agent отдельным стеком, xray-endpoint через .env) ✓.
- **Точки риска, требующие проверки при исполнении:** (1) точные имена метрик xray-exporter (`xray_uplink_bytes_total`/`xray_downlink_bytes_total` и метки `source`) — свериться с реальным выводом `/xray/metrics` в Task 1 Step 7 и поправить expr дашборда Task 6 Step 5; (2) имя внешней сети панели и адрес xray API — задаются в `.env` по факту ноды; (3) доступность `apk` в prom-образе решена sidecar-рендером на alpine (Task 2 Step 4b).
