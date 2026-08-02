# ITG Xray Panel — мониторинг

Push-мониторинг всех хостов [ITG Xray Panel](https://github.com/IvanTopGaming/ITG_xray_panel) 3.x.
На каждом хосте агент собирает метрики локально и шлёт их на central по HTTPS; central хранит,
рисует в Grafana и шлёт алерты в Telegram.

**Хост мониторинга не публикует ни одного порта.** Экспортёры слушают только на `127.0.0.1`,
наружу уходит одно исходящее соединение. Ни firewall-правил под IP central, ни basic-auth на
каждой машине, ни ручной регистрации хоста — он появляется в Grafana сам.

## Что мониторится

| Роль панели | Что снимается |
|---|---|
| все | CPU / RAM / диск / сеть / load, метрики всех контейнеров |
| `master`, `node`, `sub`, `bot`, `cron` | `/healthz` бэкенда изнутри сети панели |
| `node` | трафик Xray по inbound и по юзерам (gRPC Stats API) |
| `data` | Postgres (коннекты, размер БД) и Redis (память, клиенты, отказы) |

Алерты в Telegram: хост перестал слать метрики, бэкенд нездоров, ядро Xray не отвечает,
контейнер исчез, диск/RAM/CPU, всплеск и просадка трафика, Postgres/Redis недоступны или на пределе.

## Установка

**Сначала central** — он печатает bundle-строку, из которой агенты берут адрес и токен:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvanTopGaming/ITG_xray_panel_monitoring/main/install.sh) --role central
```

Спросит домен (на него Caddy выпустит сертификат через ACME — домен должен резолвиться сюда,
`:80` быть открыт из интернета) и данные Telegram-бота. В конце покажет пароль Grafana и bundle.

**Потом агент на каждом хосте панели** — двумя способами, они равнозначны:

```bash
# 1. вместе с установкой панели: installer панели спросит про мониторинг сам
bash <(curl -fsSL .../ITG_xray_panel/main/scripts/install.sh) --mon-bundle '<bundle>'

# 2. отдельно, на уже поднятом хосте
bash <(curl -fsSL .../ITG_xray_panel_monitoring/main/install.sh) \
  --role agent --panel-role node --panel-dir ~/itg-panel --bundle '<bundle>'
```

Агент сам определит docker-сеть панели, цель для `/healthz` и набор экспортёров под свою роль.
На роли `data` он ещё и вытащит пароли Postgres/Redis из `.env` панели рядом.

Дальше тем же скриптом:

| | |
| --- | --- |
| `install.sh doctor` | что запущено и доходит ли до central (агент проверяет токен живым запросом) |
| `install.sh update` | `docker compose pull` + `up -d` |

## Как это устроено

```
хост панели                                   central
┌───────────────────────────────┐             ┌──────────────────────────┐
│ prom-agent (host netns)       │  HTTPS      │ Caddy :443               │
│  ├─ node-exporter  127.0.0.1  │ ──────────► │  ├─ /push → prometheus   │
│  ├─ dockerstats    127.0.0.1  │  Bearer     │  └─ /     → grafana      │
│  ├─ blackbox       127.0.0.1  │             │ alertmanager → Telegram  │
│  ├─ xray-exporter  127.0.0.1  │             └──────────────────────────┘
│  └─ pg/redis       127.0.0.1  │
└───────────────────────────────┘
```

С каждым сэмплом уезжают лейблы `host` и `role` — по ним собраны дашборды и алерты.

Дашборды: `Fleet Overview` (весь флот по ролям), `Host Detail`, `Panel Services`
(здоровье бэкендов и контейнеры панели), `Xray Traffic`, `Data Tier`.

## Безопасность

- Экспортёры публикуются на `127.0.0.1` — снаружи их нет, даже без firewall.
- `/push` на central закрыт Bearer-токеном, всё остальное на домене отдаёт Grafana со своей авторизацией.
- Prometheus, Alertmanager и Grafana портов не публикуют — только Caddy.
- Токен и пароль Grafana генерируются installer'ом и лежат в `central/.env`.

## Чего этот мониторинг не делает

- **Не проверяет сервис снаружи.** Внешних blackbox-проб нет: недоступность видна косвенно —
  по пропаже метрик, по `/healthz` и по исчезновению контейнера `panel-caddy`. Протухающий
  TLS-сертификат не отслеживается вовсе, потому что панель обновляет его сама через ACME.
- **Не собирает логи.** Только метрики.
- На data tier ходит с `sslmode=require` вместо `verify-full`: сертификат выписан на
  `DATA_HOSTNAME`, а экспортёр ходит по внутреннему имени `postgres`. Трафик шифруется,
  но имя не проверяется — соединение не покидает машину.
