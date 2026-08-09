# VPS Monitoring Agents

This repository deploys Promtail and Prometheus Node Exporter to a Linux VPS through GitHub Actions. The deployment connects over SSH, installs pinned release binaries, verifies their SHA-256 checksums, creates systemd services, and starts both agents.

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

The VPS must be a systemd-based Linux host with outbound access to GitHub and the configured Loki endpoint. The SSH user must be able to run `sudo -n bash -s` without a password prompt.

The installer supports amd64, arm64, and armv7 VPS architectures.

## Deploy

1. Open **Actions > Deploy VPS monitoring agents**.
2. Select **Run workflow**.
3. Keep the defaults or enter the Promtail and Node Exporter versions to install.

The workflow is manual by design so a normal repository push cannot change a VPS unexpectedly.

Node Exporter exposes metrics at `http://VPS_HOST:9100/metrics`. The workflow does not change the VPS firewall; restrict port `9100` to the Prometheus server, or set `NODE_EXPORTER_LISTEN_ADDRESS` to a private or VPN address.

Promtail is installed because it is explicitly required here. Promtail is no longer receiving upstream feature development, so plan to migrate to Grafana Alloy for new deployments.

SSH host-key verification is disabled in the workflow for simpler setup. Anyone able to intercept the SSH connection could impersonate the VPS, so use a trusted network or restore strict host-key checking for production.
