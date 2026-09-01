#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: rootで実行してください" >&2
  exit 1
fi

for path in /opt/omni/compose.yaml /opt/omni/omni.env /opt/omni/infra-provider-sakura.env; do
  if [ ! -f "${path}" ]; then
    echo "ERROR: ${path} がありません" >&2
    exit 1
  fi
done

cat > /etc/systemd/system/omni-infra-provider.service <<'EOF'
[Unit]
Description=Omni Sakura Cloud infrastructure provider
Requires=docker.service omni.service
After=docker.service omni.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/omni
ExecStartPre=/usr/bin/docker compose --env-file /opt/omni/omni.env --profile infra-provider pull sakura-infra-provider
ExecStart=/usr/bin/docker compose --env-file /opt/omni/omni.env --profile infra-provider up -d sakura-infra-provider
ExecStop=/usr/bin/docker compose --env-file /opt/omni/omni.env --profile infra-provider stop sakura-infra-provider
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now omni-infra-provider.service
docker compose --env-file /opt/omni/omni.env --profile infra-provider ps sakura-infra-provider
