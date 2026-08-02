# Развёртывание мониторинга

Пошаговый runbook под ITG Xray Panel 3.x (шесть ролей на шести хостах). Агенты сами шлют
метрики на central; ничего открывать на хостах панели не нужно.

## Требования

- Docker + Docker Compose на central и на каждом хосте панели.
- У central домен, который резолвится на него, и открытый из интернета `:80` — иначе ACME не
  выдаст сертификат. IP тоже сработает, но с самоподписанным сертификатом (installer учтёт это
  в bundle сам).
- Панель на хосте уже поднята: агент цепляется к её docker-сети, чтобы дотянуться до `/healthz`
  и до Xray.

---

## 1. Central

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvanTopGaming/ITG_xray_panel_monitoring/main/install.sh) --role central
```

Спросит:

| Что | Зачем |
|---|---|
| домен central | Grafana и приёмник метрик, на него выпускается сертификат |
| токен Telegram-бота | отправка алертов |
| chat id | куда слать |

Пароль Grafana и токен для агентов генерируются сами и лежат в `central/.env`. В конце
скрипт печатает **bundle** — одну строку с адресом и токеном. Сохрани её: агенты настраиваются
из неё, а второй раз она не печатается (но её всегда можно собрать из `central/.env` вручную).

Проверка: `install.sh doctor --dir <каталог>` и `https://<домен>/` — там Grafana.

---

## 2. Агенты на хостах панели

Способ А — вместе с установкой панели, installer панели спросит сам:

```bash
bash <(curl -fsSL .../ITG_xray_panel/main/scripts/install.sh) --mon-bundle '<bundle>'
```

Способ Б — на уже поднятом хосте:

```bash
bash <(curl -fsSL .../ITG_xray_panel_monitoring/main/install.sh) \
  --role agent --panel-role <роль> --panel-dir ~/itg-panel --bundle '<bundle>'
```

`--panel-role` — одна из `data cron master node sub bot`. Что из этого следует:

| Роль | docker-сеть панели | Цель `/healthz` | Профили compose |
|---|---|---|---|
| `master` | `<проект>_panel-net` | `backend:5000` | `healthz` |
| `node` | `<проект>_panel-net` | `backend:5000` | `healthz,xray` |
| `sub` | `<проект>_sub-net` | `backend:5000` (алиас `panel-sub-backend`) | `healthz` |
| `bot` | `<проект>_bot-net` | `bot-api:5000` | `healthz` |
| `cron` | `<проект>_cron-net` | `cron:5000` | `healthz` |
| `data` | `<проект>_default` | — | `data` |

`<проект>` — имя каталога панели (обычно `itg-panel`). Installer находит сеть через
`docker network ls` сам; если панель стоит в каталоге с другим именем, достаточно указать
`--panel-dir`.

Имя хоста в мониторинге по умолчанию — `PANEL_DOMAIN` из `.env` панели, иначе `hostname`.
Переопределяется флагом `--host-name`.

Проверка: `install.sh doctor --dir ~/itg-monitoring`. Секция «Связь с central» бьёт живым
запросом с токеном: `400` — доехали и авторизовались, `401` — токен не тот, `000` — не пускает сеть.

---

## 3. Data tier — что происходит с секретами

На роли `data` агент читает `POSTGRES_USER/PASSWORD/DB` и `REDIS_PANEL_PASSWORD` из `.env`
панели рядом и собирает из них строки подключения. Ходит он внутрь docker-сети по именам
`postgres` и `redis`, поэтому проверка имени в сертификате отключена:

- Postgres — `sslmode=require`;
- Redis — `REDIS_EXPORTER_SKIP_TLS_VERIFICATION=true`, пользователь `panel`.

Сертификат data tier выписан на `DATA_HOSTNAME`, и по внутреннему имени `verify-full` не прошёл
бы никогда. Соединение при этом шифруется и не покидает машину.

---

## 4. Что приезжает в Grafana

| Дашборд | О чём |
|---|---|
| `Fleet Overview` | все хосты с фильтром по роли: сколько онлайн, CPU/RAM/диск/сеть |
| `Host Detail` | один хост подробно, включая его контейнеры |
| `Panel Services` | `/healthz` бэкендов, состояние контейнеров панели, жив ли xray-exporter |
| `Xray Traffic` | uplink/downlink по inbound, топ-20 юзеров по трафику |
| `Data Tier` | Postgres и Redis |

Алерты уходят в Telegram, группировка по `host` + `alertname`, повтор раз в 3 часа.

Отдельно про `HostDown`: при push-модели падение видно по тому, что данные перестали приходить
(`time() - last_over_time(node_time_seconds[1d]) > 90`). Метрика `node_time_seconds` выбрана не
случайно — её значение и есть время, поэтому формула работает и через сутки после падения, когда
серия давно вне обычного пятиминутного окна.

---

## 5. Миграция со старой pull-схемы

1. На каждой ноде снести старый агент:
   ```bash
   cd <старый репозиторий> && docker compose -f node-agent/docker-compose.yml down -v
   ```
   Заодно можно закрыть в firewall `METRICS_PORT` (8443) — он больше не нужен.
2. На central: `docker compose down` в `central/`, обновить репозиторий, поставить заново через
   `install.sh --role central`.
3. На каждом хосте панели — агент (раздел 2).

Лейблы переехали `node` → `host` + `role`, поэтому старые ряды не склеятся с новыми: дашборды
покажут историю как обрыв. Проще начать с чистого тома Prometheus, а старый оставить рядом,
пока история ещё нужна.

---

## 6. Разбор проблем

| Симптом | Куда смотреть |
|---|---|
| в Grafana нет хоста | `docker logs mon-prom-agent` на хосте: ошибки `remote_write` видны сразу |
| `doctor` показывает `401` | токен разошёлся с central — переустановить агент со свежим bundle |
| `doctor` показывает `000` | DNS/сеть/сертификат: с IP-адресом central нужен `MON_TLS_INSECURE=true` (это ставит bundle) |
| `PanelUnhealthy` на живой панели | агент цепляется не к той сети — проверить `PANEL_NETWORK` в `agent/.env` |
| нет метрик Xray | роль агента не `node` (нет профиля `xray`), либо `XRAY_API_ENDPOINT` не `xray:10085` |
| ACME не выдаёт сертификат | `:80` закрыт снаружи или домен не резолвится на central |
