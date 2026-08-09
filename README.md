# VPS Monitoring Agents

This repository deploys Promtail and Prometheus Node Exporter as Docker containers on a Linux VPS through GitHub Actions. The deployment connects over SSH, copies the repository's `docker-compose.yml` and `config/promtail/config.yml`, creates persistent runtime data under `/opt/vps-monitoring`, and starts the containers.

The workflow keeps concerns separate: Compose and Promtail configuration are versioned in this repository, while the VPS-specific `.env` file is generated remotely with restricted permissions.

## GitHub Secrets

Create these repository secrets under **Settings > Secrets and variables > Actions**:

| Secret | Required | Description |
| --- | --- | --- |
| `VPS_HOST` | Yes | VPS hostname or IP address |
| `VPS_PORT` | No | SSH port; defaults to `22` |
| `VPS_USERNAME` | Yes | SSH user with passwordless `sudo` |
| `VPS_SSH_KEY` | Yes | Private key matching the VPS user's authorized key |
| `LOKI_PUSH_URL` | Yes | Full Promtail push URL, for example `https://loki.example.com/loki/api/v1/push` |
| `VPS_NAME` | No | Label used in Loki; defaults to the VPS hostname |
| `NODE_EXPORTER_LISTEN_ADDRESS` | No | Listen address; defaults to `0.0.0.0:9100` |

The VPS must have Docker Engine running, outbound access to Docker Hub, GitHub, and the configured Loki endpoint. The SSH user must be able to run `sudo -n /usr/bin/bash -s` without a password prompt.

## Deploy

1. Open **Actions > Deploy VPS monitoring agents**.
2. Select **Run workflow**.
3. Leave **Install and start Node Exporter** unchecked for a Promtail-only deployment, or enable it when Node Exporter is ready.
4. Keep the defaults or enter the Promtail and Node Exporter versions to install.

The workflow is manual by design so a normal repository push cannot change a VPS unexpectedly.

When enabled, Node Exporter runs as the `vps-node-exporter` container and exposes metrics at `http://VPS_HOST:9100/metrics`. The workflow does not change the VPS firewall; restrict port `9100` to the Prometheus server, or set `NODE_EXPORTER_LISTEN_ADDRESS` to a private or VPN address.

Promtail runs as the `vps-promtail` container. It mounts `/var/log` and Docker's `/var/lib/docker/containers` read-only, so Docker JSON logs from containers such as `game-center-app-1` are sent to Loki. The container runs as root because Docker's container log files are commonly root-owned.

The deployed Compose file is `/opt/vps-monitoring/docker-compose.yml`. The runtime environment is `/opt/vps-monitoring/.env` and contains the Loki URL, so it is not committed to the repository.

Promtail is used because it is explicitly required here. Promtail is no longer receiving upstream feature development, so plan to migrate to Grafana Alloy for new deployments.

SSH host-key verification is disabled in the workflow for simpler setup. Anyone able to intercept the SSH connection could impersonate the VPS, so use a trusted network or restore strict host-key checking for production.
