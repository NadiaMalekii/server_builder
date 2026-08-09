#!/usr/bin/env bash

set -euo pipefail

PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.5.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
NODE_EXPORTER_LISTEN_ADDRESS="${NODE_EXPORTER_LISTEN_ADDRESS:-0.0.0.0:9100}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fail 'this installer must run as root'
command -v systemctl >/dev/null 2>&1 || fail 'systemd is required'
[[ -n "${LOKI_PUSH_URL:-}" ]] || fail 'LOKI_PUSH_URL is required'

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
[[ "$NODE_EXPORTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'NODE_EXPORTER_VERSION must look like 1.2.3'
[[ "$NODE_EXPORTER_LISTEN_ADDRESS" =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || fail 'NODE_EXPORTER_LISTEN_ADDRESS contains unsupported characters'

HOST_LABEL="${VPS_NAME:-$(hostname -s)}"
[[ "$HOST_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'VPS_NAME must contain only letters, numbers, dots, underscores, or hyphens'

case "$(uname -m)" in
  x86_64|amd64)
    PROMTAIL_ARCH='amd64'
    NODE_EXPORTER_ARCH='amd64'
    ;;
  aarch64|arm64)
    PROMTAIL_ARCH='arm64'
    NODE_EXPORTER_ARCH='arm64'
    ;;
  armv7l)
    PROMTAIL_ARCH='arm'
    NODE_EXPORTER_ARCH='armv7'
    ;;
  *)
    fail "unsupported CPU architecture: $(uname -m); supported architectures are amd64, arm64, and armv7"
    ;;
esac

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl gzip tar unzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gzip tar unzip
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gzip tar unzip
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl gzip tar unzip
  else
    fail 'supported package manager not found; install curl, tar, gzip, and unzip first'
  fi
}

ensure_service_user() {
  local user="$1"
  local nologin

  nologin="$(command -v nologin || true)"
  nologin="${nologin:-/bin/false}"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell "$nologin" --user-group "$user"
  fi
}

download() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 "$1" --output "$2"
}

verify_checksum() {
  local checksum_file="$1"
  local asset_name="$2"
  local asset_path="$3"
  local expected

  expected="$(awk -v asset="$asset_name" '$2 == asset { print $1; exit }' "$checksum_file")"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "checksum for $asset_name was not found"
  printf '%s  %s\n' "$expected" "$asset_path" | sha256sum -c -
}

install_promtail() {
  local asset="promtail-linux-${PROMTAIL_ARCH}.zip"
  local archive="$DOWNLOAD_DIR/$asset"
  local checksums="$DOWNLOAD_DIR/promtail-SHA256SUMS"
  local extracted_binary

  download "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/${asset}" "$archive"
  download "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/SHA256SUMS" "$checksums"
  verify_checksum "$checksums" "$asset" "$archive"

  mkdir -p "$DOWNLOAD_DIR/promtail"
  unzip -q "$archive" -d "$DOWNLOAD_DIR/promtail"
  extracted_binary="$(find "$DOWNLOAD_DIR/promtail" -type f -name 'promtail*' -print -quit)"
  [[ -n "$extracted_binary" ]] || fail 'Promtail binary was not found in the release archive'
  install -o root -g root -m 0755 "$extracted_binary" /usr/local/bin/promtail
}

install_node_exporter() {
  local asset="node_exporter-${NODE_EXPORTER_VERSION}.linux-${NODE_EXPORTER_ARCH}.tar.gz"
  local archive="$DOWNLOAD_DIR/$asset"
  local checksums="$DOWNLOAD_DIR/node-exporter-sha256sums.txt"
  local extracted_binary

  download "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${asset}" "$archive"
  download "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/sha256sums.txt" "$checksums"
  verify_checksum "$checksums" "$asset" "$archive"

  tar -xzf "$archive" -C "$DOWNLOAD_DIR"
  extracted_binary="$DOWNLOAD_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-${NODE_EXPORTER_ARCH}/node_exporter"
  [[ -f "$extracted_binary" ]] || fail 'Node Exporter binary was not found in the release archive'
  install -o root -g root -m 0755 "$extracted_binary" /usr/local/bin/node_exporter
}

write_promtail_config() {
  local config_tmp='/etc/promtail/config.yml.tmp'

  install -d -m 0750 -o root -g promtail /etc/promtail
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
  chown root:promtail "$config_tmp"
  chmod 0640 "$config_tmp"
  mv -f "$config_tmp" /etc/promtail/config.yml
}

write_service_units() {
  local supplementary_groups=''
  local groups=()

  if getent group adm >/dev/null 2>&1; then
    groups+=(adm)
  fi
  if getent group systemd-journal >/dev/null 2>&1; then
    groups+=(systemd-journal)
  fi
  if ((${#groups[@]} > 0)); then
    supplementary_groups="SupplementaryGroups=${groups[*]}"
  fi

  cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail log shipper
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=promtail
Group=promtail
${supplementary_groups}
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/promtail

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${NODE_EXPORTER_LISTEN_ADDRESS}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
}

install_dependencies
ensure_service_user promtail
ensure_service_user node_exporter
usermod -a -G adm promtail 2>/dev/null || true

install -d -m 0750 -o promtail -g promtail /var/lib/promtail
touch /var/lib/promtail/positions.yaml
chown promtail:promtail /var/lib/promtail/positions.yaml
chmod 0640 /var/lib/promtail/positions.yaml

DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
install_promtail
install_node_exporter
write_promtail_config
write_service_units

systemctl daemon-reload
systemctl enable promtail.service node_exporter.service
systemctl restart promtail.service
systemctl restart node_exporter.service
systemctl is-active --quiet promtail.service || fail 'Promtail failed to start'
systemctl is-active --quiet node_exporter.service || fail 'Node Exporter failed to start'

printf 'Promtail %s and Node Exporter %s are active on %s\n' "$PROMTAIL_VERSION" "$NODE_EXPORTER_VERSION" "$HOST_LABEL"
