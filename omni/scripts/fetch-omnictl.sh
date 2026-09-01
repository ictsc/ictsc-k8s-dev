#!/usr/bin/env bash
set -euo pipefail

version="${OMNI_VERSION:-v1.8.0}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${root}/bin/omnictl"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "${out}")"
asset="omnictl-${os}-${arch}"
curl -fsSL -o "${out}.tmp" \
  "https://github.com/siderolabs/omni/releases/download/${version}/${asset}"
curl -fsSL -o "${out}.sha256sum.tmp" \
  "https://github.com/siderolabs/omni/releases/download/${version}/sha256sum.txt"

expected=$(awk -v asset="${asset}" '$2 == asset {print $1}' "${out}.sha256sum.tmp")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "${out}.tmp" | awk '{print $1}')
else
  actual=$(shasum -a 256 "${out}.tmp" | awk '{print $1}')
fi
rm -f "${out}.sha256sum.tmp"

if [ -z "${expected}" ] || [ "${actual}" != "${expected}" ]; then
  rm -f "${out}.tmp"
  echo "ERROR: omnictlのSHA-256検証に失敗しました" >&2
  exit 1
fi

chmod 0755 "${out}.tmp"
mv "${out}.tmp" "${out}"
"${out}" --version
