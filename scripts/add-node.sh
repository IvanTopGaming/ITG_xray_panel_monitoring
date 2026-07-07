#!/usr/bin/env bash
set -euo pipefail
# Использование: ./scripts/add-node.sh <name> <host> [metrics_port] [xray_tcp_port]
NAME="${1:?name}"; HOST="${2:?host}"; MPORT="${3:-8443}"; XPORT="${4:-443}"
DIR="$(dirname "$0")/../central/prometheus/targets"

# живые target-файлы gitignored; при первом запуске создаём из .example
for f in nodes blackbox-http blackbox-tcp; do
  [ -f "$DIR/$f.yml" ] || cp "$DIR/$f.yml.example" "$DIR/$f.yml"
done

dedup_guard() { grep -q "\"$1\"" "$2" 2>/dev/null; }

append() { # file, target, extra_labels_yaml
  cat >> "$1" <<EOF
- targets: ["$2"]
  labels:
    node: "$NAME"$3
EOF
}

if dedup_guard "$HOST:$MPORT" "$DIR/nodes.yml"; then
  echo ">> $HOST:$MPORT уже в nodes.yml — пропускаю (дублей не будет)."
  exit 0
fi
append "$DIR/nodes.yml"         "$HOST:$MPORT" ""
append "$DIR/blackbox-http.yml" "https://$HOST" ""
append "$DIR/blackbox-tcp.yml"  "$HOST:$XPORT" $'\n    check: "xray-inbound"'

echo ">> Нода $NAME добавлена. Перезагружаю Prometheus..."
curl -fsS --connect-timeout 5 --max-time 10 -X POST http://localhost:9090/-/reload && echo " reloaded" || \
  echo ">> reload не прошёл (Prometheus не запущен?). file_sd подхватится сам в течение ~1 мин."
