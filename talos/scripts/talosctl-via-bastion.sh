#!/bin/sh
# 踏み台経由で talosctl を実行する。
#
# apid (50000) と trustd (50001) はパケットフィルタで踏み台からのみに絞ってある
# (terraform/packet-filter.tf)。手元から直接は届かないので、SSH のポート転送で
# 踏み台を経由する。kubectl は 6443 が開いているので素で使える。
#
#   usage: talosctl-via-bastion.sh [talosctl の引数...]
#
#   TALOS_EP        経由する control plane のグローバル IP (既定: 1台目)
#                   upgrade のように「対象ノード以外を経由したい」場合に指定する
#   BASTION_SSH_USER 踏み台の SSH ユーザ (既定: ubuntu)
#   TALOS_TUNNEL_PORT ローカル側の待ち受けポート (既定: 50000)
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
port="${TALOS_TUNNEL_PORT:-50000}"
user="${BASTION_SSH_USER:-ubuntu}"

bastion="$(cd "${root}/terraform" && terraform output -raw bastion_ip)"
ep="${TALOS_EP:-$(cd "${root}/terraform" && terraform output -json control_plane_ips | jq -r '.[0]')}"

# ControlMaster でトンネルを張り、終了時に確実に畳む
ctl="$(mktemp -u "${TMPDIR:-/tmp}/talos-tunnel-XXXXXX")"
cleanup() { ssh -S "${ctl}" -O exit "${user}@${bastion}" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

ssh -M -S "${ctl}" -f -N \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  -L "${port}:${ep}:50000" \
  "${user}@${bastion}"

talosctl -e "127.0.0.1:${port}" "$@"
