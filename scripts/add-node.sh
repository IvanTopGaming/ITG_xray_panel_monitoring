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
