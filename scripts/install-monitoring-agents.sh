#!/usr/bin/env bash

set -euo pipefail

PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.5.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
NODE_EXPORTER_LISTEN_ADDRESS="${NODE_EXPORTER_LISTEN_ADDRESS:-0.0.0.0:9100}"
INSTALL_NODE_EXPORTER="${INSTALL_NODE_EXPORTER:-true}"
COMPOSE_SOURCE="${COMPOSE_SOURCE:-/tmp/vps-monitoring-docker-compose.yml}"
PROMTAIL_CONFIG_SOURCE="${PROMTAIL_CONFIG_SOURCE:-/tmp/vps-monitoring-promtail-config.yml}"

BASE_DIR='/opt/vps-monitoring'
PROMTAIL_DIR="$BASE_DIR/promtail"
PROMTAIL_CONFIG="$PROMTAIL_DIR/config.yml"
PROMTAIL_POSITIONS="$PROMTAIL_DIR/positions"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"
PROMTAIL_CONTAINER='vps-promtail'
NODE_EXPORTER_CONTAINER='vps-node-exporter'
COMPOSE_COMMAND=()

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fail 'this installer must run as root'
command -v docker >/dev/null 2>&1 || fail 'Docker Engine is required on the VPS'
docker info >/dev/null 2>&1 || fail 'Docker Engine is not running or is not accessible'

if docker compose version >/dev/null 2>&1; then
  COMPOSE_COMMAND=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_COMMAND=(docker-compose)
else
  fail 'Docker Compose is required on the VPS'
fi

[[ -f "$COMPOSE_SOURCE" ]] || fail "Compose file was not copied to $COMPOSE_SOURCE"
[[ -f "$PROMTAIL_CONFIG_SOURCE" ]] || fail "Promtail config was not copied to $PROMTAIL_CONFIG_SOURCE"
[[ -n "${LOKI_PUSH_URL:-}" ]] || fail 'LOKI_PUSH_URL is required'

case "$INSTALL_NODE_EXPORTER" in
  true|false) ;;
  *) fail 'INSTALL_NODE_EXPORTER must be true or false' ;;
esac

case "$LOKI_PUSH_URL" in
  http://*|https://*) ;;
  *) fail 'LOKI_PUSH_URL must be an http or https URL' ;;
esac
case "$LOKI_PUSH_URL" in
  *"'"*|*'"'*|*$'\n'*|*$'\r'*) fail 'LOKI_PUSH_URL contains unsupported characters' ;;
esac

PROMTAIL_VERSION="${PROMTAIL_VERSION#v}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION#v}"
[[ "$PROMTAIL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'PROMTAIL_VERSION must look like 1.2.3'

if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
  [[ "$NODE_EXPORTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'NODE_EXPORTER_VERSION must look like 1.2.3'
  case "$NODE_EXPORTER_LISTEN_ADDRESS" in
    ''|*$'\n'*|*$'\r'*|*[[:space:]]*|*'%'*|*'"'*)
      fail 'NODE_EXPORTER_LISTEN_ADDRESS contains unsupported characters'
      ;;
  esac
fi

HOST_LABEL="${VPS_NAME:-$(hostname -s)}"
[[ "$HOST_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'VPS_NAME must contain only letters, numbers, dots, underscores, or hyphens'

prepare_directories() {
  install -d -m 0755 "$BASE_DIR"
  install -d -m 0750 "$PROMTAIL_DIR"
  install -d -m 0750 "$PROMTAIL_POSITIONS"

  # Reuse positions from an earlier direct Promtail installation if present.
  if [[ -f /var/lib/promtail/positions.yaml && ! -f "$PROMTAIL_POSITIONS/positions.yaml" ]]; then
    cp /var/lib/promtail/positions.yaml "$PROMTAIL_POSITIONS/positions.yaml"
  fi
  touch "$PROMTAIL_POSITIONS/positions.yaml"
  chown -R root:root "$PROMTAIL_POSITIONS"
  chmod 0600 "$PROMTAIL_POSITIONS/positions.yaml"

  install -o root -g root -m 0644 "$COMPOSE_SOURCE" "$COMPOSE_FILE"
  install -o root -g root -m 0600 "$PROMTAIL_CONFIG_SOURCE" "$PROMTAIL_CONFIG"
}

write_runtime_environment() {
  local env_tmp="$ENV_FILE.tmp"

  cat > "$env_tmp" <<EOF
PROMTAIL_VERSION='${PROMTAIL_VERSION}'
NODE_EXPORTER_VERSION='${NODE_EXPORTER_VERSION}'
NODE_EXPORTER_LISTEN_ADDRESS='${NODE_EXPORTER_LISTEN_ADDRESS}'
LOKI_PUSH_URL='${LOKI_PUSH_URL}'
VPS_NAME='${HOST_LABEL}'
EOF
  chown root:root "$env_tmp"
  chmod 0600 "$env_tmp"
  mv -f "$env_tmp" "$ENV_FILE"
}

remove_direct_promtail() {
  if [[ -f /etc/systemd/system/promtail.service ]]; then
    systemctl disable --now promtail.service 2>/dev/null || true
    rm -f /etc/systemd/system/promtail.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/promtail
  rm -rf /etc/promtail /var/lib/promtail
}

remove_direct_node_exporter() {
  if [[ -f /etc/systemd/system/node_exporter.service ]]; then
    systemctl disable --now node_exporter.service 2>/dev/null || true
    rm -f /etc/systemd/system/node_exporter.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/node_exporter
}

start_monitoring() {
  local compose_args=(--env-file "$ENV_FILE" -f "$COMPOSE_FILE")

  if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
    compose_args+=(--profile node-exporter)
    remove_direct_node_exporter
  fi

  docker rm -f "$PROMTAIL_CONTAINER" >/dev/null 2>&1 || true
  if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
    docker rm -f "$NODE_EXPORTER_CONTAINER" >/dev/null 2>&1 || true
  fi

  "${COMPOSE_COMMAND[@]}" "${compose_args[@]}" config --quiet
  "${COMPOSE_COMMAND[@]}" "${compose_args[@]}" up -d --pull always --remove-orphans

  [[ "$(docker inspect -f '{{.State.Running}}' "$PROMTAIL_CONTAINER" 2>/dev/null || true)" == 'true' ]] || fail 'Promtail Docker Compose service failed to start'
  if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
    [[ "$(docker inspect -f '{{.State.Running}}' "$NODE_EXPORTER_CONTAINER" 2>/dev/null || true)" == 'true' ]] || fail 'Node Exporter Docker Compose service failed to start'
  fi
}

prepare_directories
remove_direct_promtail
write_runtime_environment
start_monitoring

if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
  printf 'Docker Compose services %s and %s are active on %s\n' "$PROMTAIL_CONTAINER" "$NODE_EXPORTER_CONTAINER" "$HOST_LABEL"
else
  printf 'Docker Compose service %s is active on %s; Node Exporter was skipped\n' "$PROMTAIL_CONTAINER" "$HOST_LABEL"
fi
