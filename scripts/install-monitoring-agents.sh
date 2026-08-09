#!/usr/bin/env bash

set -euo pipefail

PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.5.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
NODE_EXPORTER_LISTEN_ADDRESS="${NODE_EXPORTER_LISTEN_ADDRESS:-0.0.0.0:9100}"
INSTALL_NODE_EXPORTER="${INSTALL_NODE_EXPORTER:-true}"

BASE_DIR='/opt/vps-monitoring'
PROMTAIL_DIR="$BASE_DIR/promtail"
PROMTAIL_CONFIG="$PROMTAIL_DIR/config.yml"
PROMTAIL_POSITIONS="$PROMTAIL_DIR/positions"
PROMTAIL_CONTAINER='vps-promtail'
NODE_EXPORTER_CONTAINER='vps-node-exporter'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fail 'this installer must run as root'
command -v docker >/dev/null 2>&1 || fail 'Docker Engine is required on the VPS'
docker info >/dev/null 2>&1 || fail 'Docker Engine is not running or is not accessible'
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
  *"'"*|*$'\n'*|*$'\r'*) fail 'LOKI_PUSH_URL contains unsupported characters' ;;
esac

PROMTAIL_VERSION="${PROMTAIL_VERSION#v}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION#v}"
[[ "$PROMTAIL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'PROMTAIL_VERSION must look like 1.2.3'
PROMTAIL_IMAGE="grafana/promtail:${PROMTAIL_VERSION}"
NODE_EXPORTER_IMAGE="prom/node-exporter:v${NODE_EXPORTER_VERSION}"

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

DOCKER_LOGS_ENABLED='false'
[[ -d /var/lib/docker/containers ]] && DOCKER_LOGS_ENABLED='true'

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
}

write_promtail_config() {
  local config_tmp="$PROMTAIL_CONFIG.tmp"

  cat > "$config_tmp" <<EOF
server:
  http_listen_address: 127.0.0.1
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: '${LOKI_PUSH_URL}'
    external_labels:
      host: '${HOST_LABEL}'

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: '${HOST_LABEL}'
          __path__: /var/log/*.log
      - targets:
          - localhost
        labels:
          job: varlogs
          host: '${HOST_LABEL}'
          __path__: /var/log/messages
EOF

  if [[ "$DOCKER_LOGS_ENABLED" == true ]]; then
    cat >> "$config_tmp" <<EOF
  - job_name: docker
    pipeline_stages:
      - docker: {}
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          host: '${HOST_LABEL}'
          __path__: /var/lib/docker/containers/*/*-json.log
    relabel_configs:
      - source_labels:
          - __path__
        regex: /var/lib/docker/containers/([^/]+)/.*-json.log
        target_label: container_id
EOF
  fi

  chown root:root "$config_tmp"
  chmod 0600 "$config_tmp"
  mv -f "$config_tmp" "$PROMTAIL_CONFIG"
}

remove_direct_promtail() {
  if [[ -f /etc/systemd/system/promtail.service ]]; then
    systemctl disable --now promtail.service 2>/dev/null || true
    rm -f /etc/systemd/system/promtail.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/promtail
}

remove_direct_node_exporter() {
  if [[ -f /etc/systemd/system/node_exporter.service ]]; then
    systemctl disable --now node_exporter.service 2>/dev/null || true
    rm -f /etc/systemd/system/node_exporter.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/node_exporter
}

container_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == 'true' ]]
}

start_promtail() {
  docker pull "$PROMTAIL_IMAGE"
  docker rm -f "$PROMTAIL_CONTAINER" >/dev/null 2>&1 || true

  local volume_args=(
    --volume "$PROMTAIL_CONFIG:/etc/promtail/config.yml:ro"
    --volume "$PROMTAIL_POSITIONS:/var/lib/promtail"
    --volume '/var/log:/var/log:ro'
  )
  if [[ "$DOCKER_LOGS_ENABLED" == true ]]; then
    volume_args+=(--volume '/var/lib/docker/containers:/var/lib/docker/containers:ro')
  fi

  docker run --detach \
    --name "$PROMTAIL_CONTAINER" \
    --restart unless-stopped \
    --user 0:0 \
    --read-only \
    --tmpfs '/tmp:rw,noexec,nosuid,size=64m' \
    --security-opt no-new-privileges=true \
    "${volume_args[@]}" \
    "$PROMTAIL_IMAGE" \
    -config.file=/etc/promtail/config.yml

  container_is_running "$PROMTAIL_CONTAINER" || fail 'Promtail Docker container failed to start'
}

start_node_exporter() {
  remove_direct_node_exporter
  docker pull "$NODE_EXPORTER_IMAGE"
  docker rm -f "$NODE_EXPORTER_CONTAINER" >/dev/null 2>&1 || true

  docker run --detach \
    --name "$NODE_EXPORTER_CONTAINER" \
    --restart unless-stopped \
    --network host \
    --pid host \
    --user 65534:65534 \
    --read-only \
    --security-opt no-new-privileges=true \
    --volume '/:/host:ro,rslave' \
    "$NODE_EXPORTER_IMAGE" \
    --path.rootfs=/host \
    --web.listen-address="$NODE_EXPORTER_LISTEN_ADDRESS"

  container_is_running "$NODE_EXPORTER_CONTAINER" || fail 'Node Exporter Docker container failed to start'
}

prepare_directories
remove_direct_promtail
write_promtail_config
start_promtail

if [[ "$INSTALL_NODE_EXPORTER" == true ]]; then
  start_node_exporter
  printf 'Docker containers %s and %s are active on %s\n' "$PROMTAIL_CONTAINER" "$NODE_EXPORTER_CONTAINER" "$HOST_LABEL"
else
  printf 'Docker container %s is active on %s; Node Exporter was skipped\n' "$PROMTAIL_CONTAINER" "$HOST_LABEL"
fi
