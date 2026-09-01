#!/usr/bin/env bash
set -euo pipefail

: "${OMNI_DOMAIN:?OMNI_DOMAIN is required}"
: "${AUTH_DOMAIN:?AUTH_DOMAIN is required}"
: "${OMNI_PUBLIC_IP:?OMNI_PUBLIC_IP is required}"
: "${OMNI_ADMIN_EMAIL:?OMNI_ADMIN_EMAIL is required}"
: "${ACME_EMAIL:?ACME_EMAIL is required}"
: "${OMNI_VERSION:=v1.8.0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: rootで実行してください" >&2
  exit 1
fi

for domain in "${OMNI_DOMAIN}" "${AUTH_DOMAIN}"; do
  if ! getent ahostsv4 "${domain}" | awk '{print $1}' | grep -Fxq "${OMNI_PUBLIC_IP}"; then
    echo "ERROR: ${domain} のAレコードが ${OMNI_PUBLIC_IP} を向いていません" >&2
    exit 1
  fi
done

install -d -m 0755 /opt/omni
install -d -m 0700 /var/lib/omni/etcd /var/lib/omni/sqlite /var/lib/omni/gnupg
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
install -m 0644 "${source_dir}/compose.yaml" /opt/omni/compose.yaml

if [ ! -e /etc/letsencrypt/live/omni/fullchain.pem ]; then
  certbot certonly --standalone --non-interactive --agree-tos \
    --email "${ACME_EMAIL}" --cert-name omni \
    -d "${OMNI_DOMAIN}" -d "${AUTH_DOMAIN}"
fi

cat > /usr/local/sbin/omni-sync-tls <<'EOF'
#!/bin/sh
set -eu
install -d -m 0700 -o 1001 -g 1001 /opt/omni/tls
install -m 0400 -o 1001 -g 1001 /etc/letsencrypt/live/omni/privkey.pem /opt/omni/tls/privkey.pem
install -m 0444 -o 1001 -g 1001 /etc/letsencrypt/live/omni/fullchain.pem /opt/omni/tls/fullchain.pem
EOF
chmod 0755 /usr/local/sbin/omni-sync-tls
/usr/local/sbin/omni-sync-tls

if [ ! -s /opt/omni/omni.asc ]; then
  export GNUPGHOME=/var/lib/omni/gnupg
  gpg --batch --passphrase '' --quick-generate-key \
    "Omni (etcd encryption) omni@ictsc.net" rsa4096 cert never
  fingerprint=$(gpg --with-colons --list-keys "omni@ictsc.net" \
    | awk -F: '$1 == "fpr" {print $10; exit}')
  gpg --batch --passphrase '' --quick-add-key "${fingerprint}" rsa4096 encr never
  gpg --export-secret-key --armor "omni@ictsc.net" > /opt/omni/omni.asc
  chmod 0600 /opt/omni/omni.asc
fi

if [ -f /opt/omni/omni.env ]; then
  # shellcheck disable=SC1091
  . /opt/omni/omni.env
else
  OMNI_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
fi

if [ ! -f /opt/omni/dex.yaml ]; then
  read -r -s -p "Omni初期adminのパスワード: " admin_password
  echo
  admin_hash=$(printf '%s\n' "${admin_password}" \
    | docker run --rm -i httpd:2.4-alpine htpasswd -inBC 15 admin \
    | cut -d: -f2)
  unset admin_password

  cat > /opt/omni/dex.yaml <<EOF
issuer: https://${AUTH_DOMAIN}:5556
storage:
  type: memory
web:
  https: 0.0.0.0:5556
  tlsCert: /tls/fullchain.pem
  tlsKey: /tls/privkey.pem
enablePasswordDB: true
staticClients:
  - name: Omni
    id: omni
    secret: ${OMNI_OIDC_CLIENT_SECRET}
    redirectURIs:
      - https://${OMNI_DOMAIN}/oidc/consume
staticPasswords:
  - email: ${OMNI_ADMIN_EMAIL}
    username: admin
    preferredUsername: admin
    hash: '${admin_hash}'
EOF
fi
chown 1001:1001 /opt/omni/dex.yaml
chmod 0400 /opt/omni/dex.yaml

umask 077
cat > /opt/omni/omni.env <<EOF
OMNI_VERSION=${OMNI_VERSION}
OMNI_DOMAIN=${OMNI_DOMAIN}
AUTH_DOMAIN=${AUTH_DOMAIN}
OMNI_PUBLIC_IP=${OMNI_PUBLIC_IP}
OMNI_ADMIN_EMAIL=${OMNI_ADMIN_EMAIL}
OMNI_OIDC_CLIENT_SECRET=${OMNI_OIDC_CLIENT_SECRET}
EOF

cat > /etc/systemd/system/omni.service <<'EOF'
[Unit]
Description=Sidero Omni and Dex
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/omni
ExecStart=/usr/bin/docker compose --env-file /opt/omni/omni.env up -d
ExecStop=/usr/bin/docker compose --env-file /opt/omni/omni.env down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-omni <<'EOF'
#!/bin/sh
/usr/local/sbin/omni-sync-tls
systemctl restart omni.service
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/restart-omni

systemctl daemon-reload
systemctl enable --now omni.service

for _ in $(seq 1 30); do
  if curl -fsS "https://${OMNI_DOMAIN}/" >/dev/null; then
    docker compose --env-file /opt/omni/omni.env -f /opt/omni/compose.yaml ps
    exit 0
  fi
  sleep 2
done

docker compose --env-file /opt/omni/omni.env -f /opt/omni/compose.yaml logs --tail=100
exit 1
