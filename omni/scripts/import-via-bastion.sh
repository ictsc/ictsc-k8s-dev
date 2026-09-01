#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
omni_version="${OMNI_VERSION:-v1.8.0}"
mode="${1:---dry-run}"

case "${mode}" in
  --dry-run|--apply) ;;
  *)
    echo "Usage: $0 [--dry-run|--apply]" >&2
    exit 2
    ;;
esac

for path in \
  "${root}/talos/talosconfig" \
  "${root}/.omni/config" \
  "${root}/.omni/keys"; do
  if [ ! -e "${path}" ]; then
    echo "ERROR: ${path} がありません" >&2
    echo "Omni UIからomniconfigを取得し、認証鍵とともに .omni/ に置いてください" >&2
    exit 1
  fi
done

bastion_ip=$(terraform -chdir="${root}/terraform" output -raw bastion_ip)
nodes=$(terraform -chdir="${root}/terraform" output -json talos_input \
  | jq -r '[.nodes[].internal_ip] | join(",")')
remote_dir="/tmp/ictsc-omni-import-$$"
keep_remote_backup=false

cleanup() {
  case "${remote_dir}" in
    /tmp/ictsc-omni-import-*)
      if ${keep_remote_backup}; then
        ssh "ubuntu@${bastion_ip}" \
          "rm -rf -- '${remote_dir}/keys' '${remote_dir}/talosconfig' '${remote_dir}/omniconfig' '${remote_dir}/omnictl' '${remote_dir}/omnictl-linux-amd64' '${remote_dir}/sha256sum.txt'" \
          >/dev/null 2>&1 || true
        echo "WARNING: backupの回収に失敗したため踏み台に保持しました: ${remote_dir}/machine-config-backup.zip" >&2
      else
        ssh "ubuntu@${bastion_ip}" "sudo rm -rf -- '${remote_dir}'" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}
trap cleanup EXIT

ssh "ubuntu@${bastion_ip}" "install -d -m 0700 '${remote_dir}/keys'"
scp "${root}/talos/talosconfig" "ubuntu@${bastion_ip}:${remote_dir}/talosconfig"
scp "${root}/.omni/config" "ubuntu@${bastion_ip}:${remote_dir}/omniconfig"
scp -r "${root}/.omni/keys/." "ubuntu@${bastion_ip}:${remote_dir}/keys/"

ssh "ubuntu@${bastion_ip}" \
  "curl -fsSL -o '${remote_dir}/omnictl-linux-amd64' 'https://github.com/siderolabs/omni/releases/download/${omni_version}/omnictl-linux-amd64' && curl -fsSL -o '${remote_dir}/sha256sum.txt' 'https://github.com/siderolabs/omni/releases/download/${omni_version}/sha256sum.txt' && cd '${remote_dir}' && grep ' omnictl-linux-amd64$' sha256sum.txt | sha256sum -c - && mv omnictl-linux-amd64 omnictl && chmod 0700 omnictl"

import_flags="--dry-run"
if [ "${mode}" = "--apply" ]; then
  import_flags="--backup-output '${remote_dir}/machine-config-backup.zip'"
  keep_remote_backup=true
fi

ssh -t "ubuntu@${bastion_ip}" \
  "OMNICONFIG='${remote_dir}/omniconfig' SIDEROV1_KEYS_DIR='${remote_dir}/keys' TALOSCONFIG='${remote_dir}/talosconfig' '${remote_dir}/omnictl' cluster import --nodes '${nodes}' ${import_flags}"

if [ "${mode}" = "--apply" ]; then
  backup_dir="${root}/.omni/backups"
  backup_path="${backup_dir}/ictsc-dev-machine-config-$(date +%Y%m%d-%H%M%S).zip"
  install -d -m 0700 "${backup_dir}"
  scp "ubuntu@${bastion_ip}:${remote_dir}/machine-config-backup.zip" "${backup_path}"
  chmod 0600 "${backup_path}"
  keep_remote_backup=false
  echo "machine config backup: ${backup_path}"
fi
