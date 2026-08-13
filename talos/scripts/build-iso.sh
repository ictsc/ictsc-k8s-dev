#!/usr/bin/env bash
# ディレクトリからボリュームラベル cidata の ISO9660 イメージを作る。
# Talos の nocloud プラットフォームはラベル cidata/CIDATA のデバイスを探して
# user-data / meta-data を読み込む。
#
#   usage: build-iso.sh <src-dir> <out.iso>
set -euo pipefail

src="${1:?usage: build-iso.sh <src-dir> <out.iso>}"
out="${2:?usage: build-iso.sh <src-dir> <out.iso>}"

mkdir -p "$(dirname "${out}")"
rm -f "${out}"

if command -v xorrisofs >/dev/null 2>&1; then
  xorrisofs -quiet -output "${out}" -volid cidata -joliet -rational-rock "${src}"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -output "${out}" -volid cidata -joliet -rock "${src}"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -output "${out}" -volid cidata -joliet -rock "${src}"
elif command -v hdiutil >/dev/null 2>&1; then
  # macOS 標準。-o に .iso を付けると そのままのファイル名で出力される
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "${out}" "${src}"
else
  echo "ERROR: ISO を作るコマンドが見つかりません" >&2
  echo "  Linux : apt install xorriso / genisoimage" >&2
  echo "  macOS : hdiutil (標準) があるはずですが見つかりませんでした" >&2
  exit 1
fi
