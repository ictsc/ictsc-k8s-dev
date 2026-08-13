#!/usr/bin/env bash
# Talos の nocloud ディスクイメージ (raw) を Image Factory から取得して展開する。
# さくらのクラウドのアーカイブは raw イメージを要求するので zstd を解凍しておく。
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:?TALOS_VERSION is required (e.g. v1.13.8)}"
# 拡張機能なしの標準スキーマ ID
# curl -X POST --data-binary 'customization: {}' https://factory.talos.dev/schematics
TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
image_dir="${script_dir}/../image"
mkdir -p "${image_dir}"

raw="${image_dir}/nocloud-amd64-${TALOS_VERSION}.raw"
zst="${raw}.zst"
url="https://factory.talos.dev/image/${TALOS_SCHEMATIC}/${TALOS_VERSION}/nocloud-amd64.raw.zst"

if [ -f "${raw}" ]; then
  echo "==> ${raw} は取得済みなのでスキップ"
  exit 0
fi

for cmd in curl zstd; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} が必要です (macOS: brew install ${cmd})" >&2
    exit 1
  fi
done

echo "==> ダウンロード: ${url}"
# Image Factory は初回リクエスト時にイメージをビルドするので時間がかかることがある
curl -fSL --retry 5 --retry-all-errors --retry-delay 10 -o "${zst}" "${url}"

echo "==> 展開: ${raw}"
zstd -d -f "${zst}" -o "${raw}"
rm -f "${zst}"

ls -lh "${raw}"
