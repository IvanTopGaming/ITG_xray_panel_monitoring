#!/usr/bin/env bash

set -euo pipefail

REPO_SLUG="IvanTopGaming/ITG_xray_panel_monitoring"
ROLES="central agent"
PANEL_ROLES="data cron master node sub bot"

ROLE=""
DIR=""
SOURCE=""
REF="main"
BUNDLE_IN="${MON_BUNDLE:-}"
PANEL_ROLE=""
PANEL_DIR=""
HOST_NAME="${MON_HOST_NAME:-}"
INTERACTIVE=1
START=1

WORK=""
cleanup() {
    spinner_stop 2>/dev/null || true
    [ -n "$WORK" ] && rm -rf "$WORK"
    printf '%b' "$SHOW_CURSOR"
}
trap cleanup EXIT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_ACCENT=$'\033[38;5;111m'; C_OK=$'\033[38;5;114m'
    C_WARN=$'\033[38;5;179m'; C_ERR=$'\033[38;5;203m'
    HIDE_CURSOR=$'\033[?25l'; SHOW_CURSOR=$'\033[?25h'
    TTY=1
else
    C_RESET=""; C_DIM=""; C_BOLD=""
    C_ACCENT=""; C_OK=""; C_WARN=""; C_ERR=""
    HIDE_CURSOR=""; SHOW_CURSOR=""
    TTY=0
fi

RULE_WIDTH=66

slen() {
    LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '
}

rule() {
    local title="${1:-}" line width
    if [ -z "$title" ]; then
        printf '%b\n' "  ${C_DIM}$(printf '─%.0s' $(seq 1 $RULE_WIDTH))${C_RESET}"
        return
    fi
    width=$((RULE_WIDTH - $(slen "$title") - 3))
    [ "$width" -lt 1 ] && width=1
    line=$(printf '─%.0s' $(seq 1 "$width"))
    printf '\n%b\n' "  ${C_DIM}──${C_RESET} ${C_BOLD}${title}${C_RESET} ${C_DIM}${line}${C_RESET}"
}

banner() {
    printf '\n'
    printf '%b\n' "  ${C_ACCENT}${C_BOLD}ITG Panel Monitoring${C_RESET}  ${C_DIM}· installer${C_RESET}"
    printf '%b\n' "  ${C_DIM}central собирает, агенты шлют — наружу никто не слушает${C_RESET}"
    printf '\n'
}

ok()   { printf '%b\n' "    ${C_OK}✓${C_RESET} $*"; }
info() { printf '%b\n' "    ${C_ACCENT}·${C_RESET} $*"; }
warn() { printf '%b\n' "    ${C_WARN}!${C_RESET} $*"; }
note() { printf '%b\n' "  ${C_DIM}$*${C_RESET}"; }

role_line() {
    printf '%b\n' "    ${C_BOLD}$1${C_RESET}  ${C_ACCENT}$(printf '%-9s' "$2")${C_RESET} ${C_DIM}$3${C_RESET}"
}

die() {
    spinner_stop
    printf '\n%b\n\n' "  ${C_ERR}✗${C_RESET} ${C_BOLD}$1${C_RESET}"
    [ $# -gt 1 ] && { printf '%b\n\n' "    ${C_DIM}$2${C_RESET}"; }
    exit 1
}

SPIN_PID=""
spinner_start() {
    [ "$TTY" -eq 1 ] || { printf '%b\n' "    ${C_DIM}·${C_RESET} $1…"; return; }
    printf '%b' "$HIDE_CURSOR"
    ( local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
      while :; do
          i=$(( (i + 1) % 10 ))
          printf '\r    %b%s%b %s…' "$C_ACCENT" "${frames:$i:1}" "$C_RESET" "$1"
          sleep 0.08
      done ) &
    SPIN_PID=$!
}
spinner_stop() {
    [ -n "$SPIN_PID" ] || return 0
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
    printf '\r\033[K'
    printf '%b' "$SHOW_CURSOR"
}

panel_top()  { printf '\n%b\n' "  ${C_ACCENT}╭$(printf '─%.0s' $(seq 1 $RULE_WIDTH))╮${C_RESET}"; }
panel_bot()  { printf '%b\n' "  ${C_ACCENT}╰$(printf '─%.0s' $(seq 1 $RULE_WIDTH))╯${C_RESET}"; }

panel_line() {
    local text="$1" pad spaces=""
    pad=$(( RULE_WIDTH - $(slen "$text") ))
    [ "$pad" -gt 0 ] && spaces="$(printf '%*s' "$pad" '')"
    printf '%b\n' "  ${C_ACCENT}│${C_RESET}${text}${spaces}${C_ACCENT}│${C_RESET}"
}

usage() {
    cat <<EOF

  usage: install.sh [command] [options]

  commands:
    install            поставить central или агент (по умолчанию)
    doctor             проверить установленное: что запущено, доходит ли до central
    upgrade            скачать свежие конфиги и дашборды, пересоздать стек
    update             только образы: docker compose pull + up -d

  options:
    --role ROLE        central | agent
    --dir PATH         куда ставить (по умолчанию: ./itg-monitoring)
    --bundle STRING    строка, которую напечатал central (нужна для агента)
    --panel-role ROLE  роль панели на этом хосте: $PANEL_ROLES
    --panel-dir PATH   каталог деплоя панели (по умолчанию: ./itg-panel)
    --host-name NAME   имя хоста в мониторинге (по умолчанию: домен панели или hostname)
    --source PATH      ставить из локального чекаута, а не с GitHub
    --ref REF          git ref для загрузки (по умолчанию: main)
    --non-interactive  ничего не спрашивать, брать из окружения
    --no-start         записать файлы, но не поднимать
    -h, --help         это

EOF
}

COMMAND="install"
case "${1:-}" in
    install|doctor|update|upgrade) COMMAND="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="${2:-}"; shift 2 ;;
        --dir) DIR="${2:-}"; shift 2 ;;
        --bundle) BUNDLE_IN="${2:-}"; shift 2 ;;
        --panel-role) PANEL_ROLE="${2:-}"; shift 2 ;;
        --panel-dir) PANEL_DIR="${2:-}"; shift 2 ;;
        --host-name) HOST_NAME="${2:-}"; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        --no-start) START=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "неизвестная опция: $1" ;;
    esac
done

[ "$INTERACTIVE" -eq 1 ] && banner

env_get() {
    sed -n "s/^$2=\([^#]*\).*/\1/p" "$1" | head -1 | sed 's/[[:space:]]*$//'
}

env_set() {
    local file="$1" key="$2" value="$3" line rest comment tmp
    tmp="$file.tmp"
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            rest="${BASH_REMATCH[1]}"
            comment=""
            case "$rest" in *"#"*) comment="  #${rest#*#}" ;; esac
            printf '%s=%s%s\n' "$key" "$value" "$comment" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
}

declare -A VALUES=()

render_env() {
    local example="$1" out="$2" line key rest comment
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            comment=""
            case "$rest" in *"#"*) comment="  #${rest#*#}" ;; esac
            if [ -n "${VALUES[$key]+set}" ]; then
                printf '%s=%s%s\n' "$key" "${VALUES[$key]}" "$comment" >> "$out"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$out"
    done < "$example"
}

gen_secret() {
    openssl rand -base64 "${1:-36}" | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

is_ip_literal() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" == *:* ]]
}

ask() {
    local var="$1" prompt="$2" default="${3:-}" validator="${4:-}" answer
    if [ -n "$(printf '%s' "${!var:-}")" ]; then return 0; fi
    if [ "$INTERACTIVE" -eq 0 ]; then
        [ -n "$default" ] || die "--non-interactive задан, но $var не установлена и не имеет значения по умолчанию"
        printf -v "$var" '%s' "$default"
        return 0
    fi
    while :; do
        if [ -n "$default" ]; then
            printf '%b' "    ${C_ACCENT}▸${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET}: "
            read -r answer
            answer="${answer:-$default}"
        else
            printf '%b' "    ${C_ACCENT}▸${C_RESET} ${prompt}: "
            read -r answer
        fi
        [ -z "$answer" ] && { warn "нужно значение"; continue; }
        if [ -n "$validator" ] && ! "$validator" "$answer"; then
            warn "это не похоже на имя хоста"
            continue
        fi
        break
    done
    printf -v "$var" '%s' "$answer"
}

json_field() {
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

has_docker() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

version_of() {
    case "$1" in
        docker) docker --version 2>/dev/null | sed -n 's/Docker version \([^,]*\).*/\1/p' ;;
        openssl) openssl version 2>/dev/null | awk '{print $2}' ;;
        curl) curl --version 2>/dev/null | head -1 | awk '{print $2}' ;;
    esac
}

need() {
    local cmd="$1" hint="$2" version
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd нужен, но не установлен" "$hint"
    version="$(version_of "$cmd")"
    ok "$(printf '%-16s' "$cmd")${C_DIM}${version:-present}${C_RESET}"
}

preflight() {
    [ "$INTERACTIVE" -eq 1 ] && rule "Проверяю машину"
    need openssl "Поставь пакетным менеджером: apt install openssl"
    [ -z "$SOURCE" ] && need curl "Поставь пакетным менеджером: apt install curl"
    if [ "$START" -eq 1 ]; then
        need docker "См. https://docs.docker.com/engine/install/ — installer намеренно не ставит docker сам."
        if docker compose version >/dev/null 2>&1; then
            ok "$(printf '%-16s' "docker compose")${C_DIM}$(docker compose version --short 2>/dev/null)${C_RESET}"
        else
            die "нет плагина docker compose" \
                "Поставь docker-compose-plugin. Старый standalone docker-compose (v1) не поддерживается."
        fi
    fi
    return 0
}

fetch_tree_to() {
    local dest="$1"
    mkdir -p "$dest"
    if [ -n "$SOURCE" ]; then
        if [ ! -d "$SOURCE/central" ] || [ ! -d "$SOURCE/agent" ]; then
            die "$SOURCE не похож на чекаут мониторинга" "Нужны каталоги central/ и agent/."
        fi
        tar -C "$SOURCE" -cf - central agent install.sh README.md DEPLOY.md | tar -C "$dest" -xf -
    else
        curl -fsSL "https://codeload.github.com/$REPO_SLUG/tar.gz/refs/heads/$REF" |
            tar -xz -C "$dest" --strip-components=1 ||
            die "не удалось скачать репозиторий мониторинга" "Пробовал $REPO_SLUG@$REF. Проверь сеть или задай --ref."
    fi
}

fetch_tree() {
    mkdir -p "$DIR"
    DIR="$(cd "$DIR" && pwd)"
    fetch_tree_to "$DIR"
}

new_env_keys() {
    local example="$1" live="$2" key
    [ -f "$example" ] && [ -f "$live" ] || return 0
    while IFS= read -r key; do
        grep -q "^${key}=" "$live" || printf '%s ' "$key"
    done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$example")
}

compose() { ( cd "$COMPOSE_DIR" && docker compose "$@" ); }

compose_show() {
    if [ "$TTY" -eq 1 ]; then
        compose "$@"
    else
        compose "$@" 2>&1 | sed 's/^/    /'
    fi
}

detect_role() {
    DIR="${DIR:-.}"
    [ -d "$DIR" ] || die "$DIR не существует" "Укажи --dir на каталог мониторинга."
    DIR="$(cd "$DIR" && pwd)"
    if [ -f "$DIR/central/.env" ]; then
        ROLE=central; COMPOSE_DIR="$DIR/central"
    elif [ -f "$DIR/agent/.env" ]; then
        ROLE=agent; COMPOSE_DIR="$DIR/agent"
    else
        die "в $DIR нет установленного мониторинга" "Запусти установку здесь или укажи --dir."
    fi
}

install_central() {
    rule "Central"
    note "Домен, по которому будешь открывать Grafana и на который агенты шлют метрики."
    note "Он должен резолвиться сюда, а :80 быть доступен из интернета — иначе ACME не выдаст"
    note "сертификат. IP тоже сработает, но с самоподписанным сертификатом."
    printf '\n'
    ask MON_DOMAIN "домен central-сервера" "" valid_hostname
    ask TELEGRAM_BOT_TOKEN "токен Telegram-бота для алертов"
    ask TELEGRAM_CHAT_ID "chat id для алертов"

    MON_TOKEN="$(gen_secret 36)"
    GRAFANA_ADMIN_PASSWORD="$(gen_secret 15)"

    VALUES[MON_DOMAIN]="$MON_DOMAIN"
    VALUES[MON_TOKEN]="$MON_TOKEN"
    VALUES[GRAFANA_ADMIN_PASSWORD]="$GRAFANA_ADMIN_PASSWORD"
    VALUES[TELEGRAM_BOT_TOKEN]="$TELEGRAM_BOT_TOKEN"
    VALUES[TELEGRAM_CHAT_ID]="$TELEGRAM_CHAT_ID"
    render_env "$DIR/central/.env.example" "$DIR/central/.env"
    ok "конфигурация записана"

    local insecure=0
    if is_ip_literal "$MON_DOMAIN" || [ "${MON_DOMAIN%%.*}" = "$MON_DOMAIN" ]; then
        insecure=1
        warn "домен без точки или IP — Caddy выдаст самоподписанный сертификат"
        note "    Агенты будут слать с MON_TLS_INSECURE=true (это уже учтено в bundle)."
    fi
    printf '{"endpoint":"https://%s/push","token":"%s","insecure":"%s"}' \
        "$MON_DOMAIN" "$MON_TOKEN" "$insecure" > "$WORK/bundle.json"
    MON_BUNDLE_OUT="$(base64 -w0 < "$WORK/bundle.json" 2>/dev/null || base64 < "$WORK/bundle.json" | tr -d '\n')"

    COMPOSE_DIR="$DIR/central"
}

central_report() {
    panel_top
    panel_line ""
    panel_line "  Grafana — показано один раз, лежит в central/.env"
    panel_line ""
    panel_line "    https://${MON_DOMAIN}/"
    panel_line "    admin / ${GRAFANA_ADMIN_PASSWORD}"
    panel_line ""
    panel_bot

    panel_top
    panel_line ""
    panel_line "  Строка ниже — адрес и токен этого central. Вставь её в"
    panel_line "  installer на каждом хосте панели (свой или панельный),"
    panel_line "  и агент настроится сам."
    panel_line ""
    panel_bot
    printf '\n%s\n\n' "$MON_BUNDLE_OUT"
}

healthz_target_for() {
    case "$1" in
        master|node|sub) printf 'backend:5000' ;;
        bot) printf 'bot-api:5000' ;;
        cron) printf 'cron:5000' ;;
        data) printf '' ;;
    esac
}

profiles_for() {
    case "$1" in
        node) printf 'healthz,xray' ;;
        data) printf 'data' ;;
        *) printf 'healthz' ;;
    esac
}

network_suffix_for() {
    case "$1" in
        master|node) printf 'panel-net' ;;
        sub) printf 'sub-net' ;;
        bot) printf 'bot-net' ;;
        cron) printf 'cron-net' ;;
        data) printf 'default' ;;
    esac
}

detect_panel_network() {
    local project="$1" suffix="$2" found
    has_docker || { printf '%s_%s' "$project" "$suffix"; return 0; }
    found="$(docker network ls --format '{{.Name}}' | grep -x "${project}_${suffix}" || true)"
    [ -z "$found" ] && found="$(docker network ls --format '{{.Name}}' | grep -E "_${suffix}\$" | head -1 || true)"
    [ -n "$found" ] || die "не нашёл docker-сеть панели (${project}_${suffix})" \
        "Панель роли '$PANEL_ROLE' поднята на этом хосте? Смотри: docker network ls"
    printf '%s' "$found"
}

host_name_from_panel() {
    local penv="$1" role="$2" name=""
    case "$role" in
        master|node) name="$(env_get "$penv" PANEL_DOMAIN 2>/dev/null || true)" ;;
        sub) name="$(env_get "$penv" SUB_DOMAIN 2>/dev/null || true)" ;;
        bot) name="$(env_get "$penv" BOT_DOMAIN 2>/dev/null || true)" ;;
    esac
    [ -n "$name" ] || name="$(hostname -s 2>/dev/null || hostname)"
    printf '%s' "$name"
}

detect_xray_logs_volume() {
    local project="$1" found=""
    if has_docker; then
        found="$(docker volume ls --format '{{.Name}}' | grep -x "${project}_xray_logs" || true)"
        [ -z "$found" ] && found="$(docker volume ls --format '{{.Name}}' | grep -E '_xray_logs$' | head -1 || true)"
    fi
    if [ -z "$found" ]; then
        warn "не нашёл том с логами Xray (${project}_xray_logs)" >&2
        note "    Метрики по доменам и гео не поедут; трафик по inbound и юзерам не зависит от них." >&2
        found="${project}_xray_logs"
    fi
    printf '%s' "$found"
}

data_tier_values() {
    local penv="$1" pg_user pg_pass pg_db redis_pass redis_user
    [ -f "$penv" ] || die "нет $penv" "Для роли data нужен .env панели — укажи --panel-dir."
    pg_user="$(env_get "$penv" POSTGRES_USER)"
    pg_pass="$(env_get "$penv" POSTGRES_PASSWORD)"
    pg_db="$(env_get "$penv" POSTGRES_DB)"
    redis_user="monitoring"
    redis_pass="$(env_get "$penv" REDIS_MONITORING_PASSWORD)"
    if [ -z "$redis_pass" ]; then
        redis_user="panel"
        redis_pass="$(env_get "$penv" REDIS_PANEL_PASSWORD)"
        warn "в .env панели нет REDIS_MONITORING_PASSWORD — беру пароль panel"
        note "    Этот ACL-юзер не может INFO, поэтому метрик Redis не будет. Обнови панель"
        note "    и перезапусти на этом хосте redis, затем переустанови агент."
    fi
    if [ -z "$pg_pass" ] || [ -z "$redis_pass" ]; then
        die "в $penv нет POSTGRES_PASSWORD/REDIS_*_PASSWORD" "Это точно каталог роли data?"
    fi
    VALUES[PG_DSN]="postgresql://${pg_user:-panel}:${pg_pass}@postgres:5432/${pg_db:-panel}?sslmode=require"
    VALUES[REDIS_ADDR]="rediss://redis:6379"
    VALUES[REDIS_USER]="$redis_user"
    VALUES[REDIS_PASSWORD]="$redis_pass"
    ok "секреты data tier взяты из .env панели ${C_DIM}(redis: $redis_user)${C_RESET}"
}

install_agent() {
    if [ -z "$PANEL_ROLE" ]; then
        [ "$INTERACTIVE" -eq 0 ] && die "--panel-role обязателен при --non-interactive" "Одна из: $PANEL_ROLES"
        rule "Какую роль панели держит эта машина?"
        printf '\n'
        role_line 1 data   "Postgres + Redis"
        role_line 2 cron   "фоновые задачи"
        role_line 3 master "админка"
        role_line 4 node   "Xray"
        role_line 5 sub    "подписки"
        role_line 6 bot    "Telegram-бот"
        printf '\n'
        while :; do
            ask PANEL_ROLE_CHOICE "роль, номером или именем"
            case "$PANEL_ROLE_CHOICE" in
                1|data) PANEL_ROLE=data ;; 2|cron) PANEL_ROLE=cron ;; 3|master) PANEL_ROLE=master ;;
                4|node) PANEL_ROLE=node ;; 5|sub) PANEL_ROLE=sub ;; 6|bot) PANEL_ROLE=bot ;;
                *) warn "выбери 1-6 или имя роли"; PANEL_ROLE_CHOICE=""; continue ;;
            esac
            break
        done
    fi
    case " $PANEL_ROLES " in *" $PANEL_ROLE "*) ;; *) die "неизвестная роль панели '$PANEL_ROLE'" "Одна из: $PANEL_ROLES" ;; esac

    if [ -z "$BUNDLE_IN" ]; then
        [ "$INTERACTIVE" -eq 0 ] && die "агенту нужна bundle-строка central" "Передай --bundle или задай MON_BUNDLE."
        rule "Bundle central-сервера"
        note "Длинная строка, которую напечатал installer на central. Вставь целиком."
        printf '\n'
        ask BUNDLE_IN "bundle"
    fi
    printf '%s' "$BUNDLE_IN" | base64 -d > "$WORK/bundle.json" 2>/dev/null ||
        die "это не похоже на bundle" "Скопируй строку целиком, без переносов."
    grep -q '"endpoint"' "$WORK/bundle.json" ||
        die "этот bundle выдан не этим installer'ом" "Перезапусти installer на central, чтобы получить свежий."

    local endpoint token insecure panel_dir project suffix network healthz
    endpoint="$(json_field "$WORK/bundle.json" endpoint)"
    token="$(json_field "$WORK/bundle.json" token)"
    insecure="$(json_field "$WORK/bundle.json" insecure)"

    panel_dir="${PANEL_DIR:-./itg-panel}"
    [ -d "$panel_dir" ] || die "каталог панели $panel_dir не найден" "Укажи --panel-dir."
    panel_dir="$(cd "$panel_dir" && pwd)"
    project="$(basename "$panel_dir")"
    suffix="$(network_suffix_for "$PANEL_ROLE")"
    network="$(detect_panel_network "$project" "$suffix")"
    healthz="$(healthz_target_for "$PANEL_ROLE")"

    if [ -z "$HOST_NAME" ]; then
        HOST_NAME="$(host_name_from_panel "$panel_dir/.env" "$PANEL_ROLE")"
    fi

    rule "Агент"
    ok "хост      ${C_BOLD}${HOST_NAME}${C_RESET} ${C_DIM}роль ${PANEL_ROLE}${C_RESET}"
    ok "сеть      ${C_DIM}${network}${C_RESET}"
    ok "central   ${C_DIM}${endpoint}${C_RESET}"

    VALUES[MON_HOST_NAME]="$HOST_NAME"
    VALUES[MON_ROLE]="$PANEL_ROLE"
    VALUES[MON_ENDPOINT]="$endpoint"
    VALUES[MON_TOKEN]="$token"
    VALUES[MON_TLS_INSECURE]="$([ "$insecure" = "1" ] && printf 'true' || printf 'false')"
    VALUES[PANEL_NETWORK]="$network"
    VALUES[HEALTHZ_TARGET]="${healthz:-backend:5000}"
    VALUES[COMPOSE_PROFILES]="$(profiles_for "$PANEL_ROLE")"
    [ "$PANEL_ROLE" = "node" ] && VALUES[XRAY_LOGS_VOLUME]="$(detect_xray_logs_volume "$project")"

    [ "$PANEL_ROLE" = "data" ] && data_tier_values "$panel_dir/.env"

    render_env "$DIR/agent/.env.example" "$DIR/agent/.env"
    ok "конфигурация записана"

    COMPOSE_DIR="$DIR/agent"
}

cmd_install() {
    if [ -z "$ROLE" ]; then
        [ "$INTERACTIVE" -eq 0 ] && die "--role обязателен при --non-interactive"
        rule "Что ставим на этой машине?"
        printf '\n'
        role_line 1 central "Prometheus + Grafana + Alertmanager · ставится первым"
        role_line 2 agent   "сбор метрик рядом с ролью панели"
        printf '\n'
        while :; do
            ask ROLE_CHOICE "роль, номером или именем"
            case "$ROLE_CHOICE" in
                1|central) ROLE=central ;; 2|agent) ROLE=agent ;;
                *) warn "выбери 1 или 2"; ROLE_CHOICE=""; continue ;;
            esac
            break
        done
    fi
    case " $ROLES " in *" $ROLE "*) ;; *) die "неизвестная роль '$ROLE'" "Одна из: $ROLES" ;; esac

    preflight

    DIR="${DIR:-./itg-monitoring}"
    mkdir -p "$DIR"
    DIR="$(cd "$DIR" && pwd)"
    [ -f "$DIR/central/.env" ] && die "$DIR/central/.env уже существует" \
        "Installer не перетирает живую установку. Убери её или укажи другой --dir."
    [ -f "$DIR/agent/.env" ] && die "$DIR/agent/.env уже существует" \
        "Installer не перетирает живую установку. Убери её или укажи другой --dir."

    rule "Скачиваю"
    spinner_start "читаю $([ -n "$SOURCE" ] && echo "$SOURCE" || echo "$REPO_SLUG@$REF")"
    fetch_tree
    spinner_stop
    ok "файлы на месте"

    case "$ROLE" in
        central) install_central ;;
        agent) install_agent ;;
    esac

    if [ "$START" -eq 1 ]; then
        rule "Поднимаю"
        if compose_show up -d; then
            printf '\n'
            ok "работает в ${C_BOLD}${COMPOSE_DIR}${C_RESET}"
            note "  логи:   cd $COMPOSE_DIR && docker compose logs -f"
            note "  проверка: install.sh doctor --dir $DIR"
        else
            printf '\n'
            warn "docker compose up не прошёл — конфигурация записана, стек не поднят"
            note "  подними вручную: cd $COMPOSE_DIR && docker compose up -d"
        fi
    else
        rule "Записано, но не запущено"
        note "  старт: cd $COMPOSE_DIR && docker compose up -d"
    fi

    [ "$ROLE" = "central" ] && central_report
    printf '\n'
}

check_uplink() {
    local envf="$COMPOSE_DIR/.env" endpoint token code
    endpoint="$(env_get "$envf" MON_ENDPOINT)"
    token="$(env_get "$envf" MON_TOKEN)"
    [ -n "$endpoint" ] || { note "  этот хост ничего никуда не шлёт"; return 0; }
    code="$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST -H "Authorization: Bearer $token" "$endpoint" 2>/dev/null || printf '000')"
    case "$code" in
        400) ok "central   ${C_DIM}${endpoint} принимает — токен подходит${C_RESET}" ;;
        401|403) warn "central   ${C_DIM}${endpoint} отвечает ${code} — токен не подходит${C_RESET}" ;;
        000) warn "central   ${C_DIM}${endpoint} недостижим (сеть, DNS или сертификат)${C_RESET}" ;;
        *) warn "central   ${C_DIM}${endpoint} ответил ${code}${C_RESET}" ;;
    esac
    return 0
}

cmd_doctor() {
    rule "Установка"
    ok "роль      ${C_BOLD}${ROLE}${C_RESET}  ${C_DIM}${COMPOSE_DIR}${C_RESET}"
    if [ "$ROLE" = "agent" ]; then
        ok "хост      ${C_DIM}$(env_get "$COMPOSE_DIR/.env" MON_HOST_NAME) · роль панели $(env_get "$COMPOSE_DIR/.env" MON_ROLE)${C_RESET}"
    else
        ok "домен     ${C_DIM}$(env_get "$COMPOSE_DIR/.env" MON_DOMAIN)${C_RESET}"
    fi

    rule "Контейнеры"
    if has_docker; then
        local out
        out="$(compose ps --format '{{.Service}} {{.State}} {{.Status}}' 2>/dev/null || true)"
        if [ -z "$out" ]; then
            warn "здесь ничего не запущено"
        else
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    *running*) ok "$line" ;;
                    *) warn "$line" ;;
                esac
            done <<< "$out"
        fi
    else
        note "  docker недоступен, пропускаю"
    fi

    if [ "$ROLE" = "agent" ]; then
        rule "Связь с central"
        check_uplink
    fi
    printf '\n'
}

cmd_upgrade() {
    rule "Обновляю файлы"
    note "  central/ и agent/ заменяются целиком — ручные правки в них будут потеряны."
    note "  Файлы .env сохраняются."
    printf '\n'

    spinner_start "читаю $([ -n "$SOURCE" ] && echo "$SOURCE" || echo "$REPO_SLUG@$REF")"
    fetch_tree_to "$WORK/tree"
    spinner_stop

    local saved="$WORK/env" part
    mkdir -p "$saved"
    for part in central agent; do
        [ -f "$DIR/$part/.env" ] && cp "$DIR/$part/.env" "$saved/$part.env"
    done

    rm -rf "$DIR/central" "$DIR/agent"
    tar -C "$WORK/tree" -cf - central agent | tar -C "$DIR" -xf -
    for part in central agent; do
        [ -f "$saved/$part.env" ] && cp "$saved/$part.env" "$DIR/$part/.env"
    done
    ok "конфигурация обновлена, .env на месте"

    if [ -f "$WORK/tree/install.sh" ]; then
        cp "$WORK/tree/install.sh" "$DIR/.install.sh.new"
        chmod +x "$DIR/.install.sh.new"
        mv "$DIR/.install.sh.new" "$DIR/install.sh"
        ok "install.sh обновлён"
    fi

    local missing
    missing="$(new_env_keys "$COMPOSE_DIR/.env.example" "$COMPOSE_DIR/.env")"
    if [ -n "$missing" ]; then
        warn "в новой версии появились переменные: ${C_BOLD}${missing}${C_RESET}"
        note "    Допиши их в $COMPOSE_DIR/.env — без них стек может не подняться."
    fi

    if [ "$START" -eq 0 ]; then
        rule "Не перезапускаю"
        note "  примени: cd $COMPOSE_DIR && docker compose up -d --force-recreate"
        printf '\n'
        return 0
    fi

    rule "Перезапускаю"
    has_docker || die "docker недоступен" "Файлы обновлены; подними стек сам."
    compose_show pull
    compose_show up -d --force-recreate --remove-orphans
    printf '\n'
    ok "обновлено"
    printf '\n'
}

cmd_update() {
    rule "Обновляю образы"
    has_docker || die "docker недоступен"
    compose_show pull
    compose_show up -d
    printf '\n'
    ok "обновлено"
    printf '\n'
}

WORK="$(mktemp -d)"

case "$COMMAND" in
    install) cmd_install ;;
    doctor) detect_role; cmd_doctor ;;
    update) detect_role; cmd_update ;;
    upgrade) detect_role; cmd_upgrade ;;
esac
