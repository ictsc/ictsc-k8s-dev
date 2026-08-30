#!/bin/sh
# ブートストラップ用ツールを環境に応じて揃えてから task init に渡す。
#
# aqua 管理外なのは aqua / direnv / zstd の3つだけ。
# task も init より前に必要だが aqua.yaml に入っているので aqua install で入る。
#
# 何度実行してもよい (入っているものは飛ばす)。
set -eu

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

########################################
# 環境の判定
########################################
OS="$(uname -s)"
PM=""
case "${OS}" in
  Darwin)
    have brew || die "Homebrew が必要です: https://brew.sh"
    PM="brew"
    ;;
  Linux)
    if   have apt-get; then PM="apt"
    elif have dnf;     then PM="dnf"
    elif have pacman;  then PM="pacman"
    elif have zypper;  then PM="zypper"
    else
      warn "対応するパッケージマネージャが見つかりません"
      warn "direnv と zstd を手で入れてから、もう一度実行してください"
      PM="none"
    fi
    ;;
  *) die "未対応の OS です: ${OS}" ;;
esac
info "OS=${OS} パッケージマネージャ=${PM}"

# このリポジトリは Talos の raw イメージ (約 4GB) を落として さくら へ上げる。
# aqua が入れるツール類も数百 MB あるため、空きが少ないと途中で必ず失敗する。
check_space() {
  # $1 = 対象パス, $2 = 必要な GB
  avail_kb="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
  [ -z "${avail_kb}" ] && return 0
  need_kb=$(( $2 * 1024 * 1024 ))
  if [ "${avail_kb}" -lt "${need_kb}" ]; then
    warn "$1 の空きが $(( avail_kb / 1024 / 1024 ))GB しかありません (目安 $2GB)"
    return 1
  fi
  return 0
}
SPACE_OK=0
check_space "${TMPDIR:-/tmp}" 2 || SPACE_OK=1
check_space "${HOME}" 10 || SPACE_OK=1
if [ "${SPACE_OK}" -ne 0 ]; then
  warn "容量不足のまま進めると、ツールの展開や Talos イメージの取得で失敗します"
  warn "不要なファイルを消すか、ディスクを増やしてから実行し直してください"
fi

# sudo が要るか (root なら不要)
SUDO=""
[ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

pkg_install() {
  # $@ = パッケージ名
  case "${PM}" in
    brew)   brew install "$@" ;;
    apt)    ${SUDO} apt-get update -qq && ${SUDO} apt-get install -y "$@" ;;
    dnf)    ${SUDO} dnf install -y "$@" ;;
    pacman) ${SUDO} pacman -S --needed --noconfirm "$@" ;;
    zypper) ${SUDO} zypper install -y "$@" ;;
    none)   die "$* を手でインストールしてください" ;;
  esac
}

########################################
# direnv / zstd / ISO 作成コマンド
########################################
for t in direnv zstd; do
  if have "${t}"; then
    info "${t} は導入済み"
  else
    info "${t} を導入します"
    pkg_install "${t}"
  fi
done

# talos/scripts/build-iso.sh が cidata の ISO を焼くのに使う。
# macOS は hdiutil が標準で入っているので何もしなくてよい。
if have xorrisofs || have genisoimage || have mkisofs || have hdiutil; then
  info "ISO 作成コマンドは導入済み"
else
  info "xorriso を導入します (cidata の ISO 生成に使う)"
  pkg_install xorriso
fi

########################################
# aqua
########################################
# aqua が入れるツールの置き場。aqua 自身を実行せずに展開できる形で書く
# (aqua root-dir を使うと aqua が先に PATH に居る必要がある)。
AQUA_BIN="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/aquaproj-aqua}/bin"
LOCAL_BIN=""

if have aqua; then
  info "aqua は導入済み ($(command -v aqua))"
else
  info "aqua を導入します"
  case "${PM}" in
    brew)
      brew install aqua
      ;;
    *)
      # 配布バイナリを取る。go install だとツールチェーンの再取得とビルドが走り、
      # /tmp が小さい環境では "no space left on device" で落ちる。
      # aqua 自身のバージョンはここで固定する (以降のツールは aqua.yaml が固定)。
      AQUA_VERSION="v2.62.3"
      case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "未対応の CPU アーキテクチャです: $(uname -m)" ;;
      esac
      TARBALL="aqua_linux_${ARCH}.tar.gz"
      URL="https://github.com/aquaproj/aqua/releases/download/${AQUA_VERSION}/${TARBALL}"

      have curl || die "curl が必要です"
      mkdir -p "${HOME}/.local/bin"
      TMPD="$(mktemp -d)"
      # shellcheck disable=SC2064
      trap "rm -rf '${TMPD}'" EXIT

      info "aqua ${AQUA_VERSION} (${ARCH}) を取得します"
      curl -sSfL -o "${TMPD}/${TARBALL}" "${URL}" \
        || die "aqua の取得に失敗しました: ${URL}"

      # 配布物のチェックサムを検証する (照合ツールが無ければ飛ばす)
      SUMS="aqua_${AQUA_VERSION#v}_checksums.txt"
      if curl -sSfL -o "${TMPD}/${SUMS}" \
           "https://github.com/aquaproj/aqua/releases/download/${AQUA_VERSION}/${SUMS}" 2>/dev/null; then
        if have sha256sum; then
          ( cd "${TMPD}" && grep " ${TARBALL}\$" "${SUMS}" | sha256sum -c - >/dev/null ) \
            || die "aqua のチェックサムが一致しません"
          info "チェックサム OK"
        elif have shasum; then
          ( cd "${TMPD}" && grep " ${TARBALL}\$" "${SUMS}" | shasum -a 256 -c - >/dev/null ) \
            || die "aqua のチェックサムが一致しません"
          info "チェックサム OK"
        else
          warn "sha256sum / shasum が無いのでチェックサムの検証を飛ばします"
        fi
      else
        warn "チェックサムファイルを取得できないので検証を飛ばします"
      fi

      tar -xzf "${TMPD}/${TARBALL}" -C "${HOME}/.local/bin" aqua \
        || die "aqua の展開に失敗しました"
      chmod +x "${HOME}/.local/bin/aqua"
      LOCAL_BIN="${HOME}/.local/bin"
      PATH="${LOCAL_BIN}:${PATH}"
      export PATH
      ;;
  esac
fi

have aqua || die "aqua が PATH に見つかりません"

########################################
# シェルの rc に PATH と direnv hook を追記
########################################
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "${SHELL_NAME}" in
  zsh)  RC="${HOME}/.zshrc"  ;;
  bash) RC="${HOME}/.bashrc" ;;
  *)    RC="" ;;
esac

MARK="# --- ictsc-k8s-dev (aqua / direnv) ---"

# 既に手で書いてある場合もあるので、マーカーではなく中身の有無で判定する。
# そうしないと同じ設定を何度も積み増してしまう。
rc_has() { [ -n "${RC}" ] && grep -qF "$1" "${RC}" 2>/dev/null; }

if [ -z "${RC}" ]; then
  warn "シェル ${SHELL_NAME} の rc ファイルが分からないので、設定は手で入れてください"
else
  NEED=""
  # aqua のツール置き場は "aqua root-dir" 形式で書かれていることもある
  { rc_has "aquaproj-aqua" || rc_has "aqua root-dir"; } || NEED="${NEED} aqua-path"
  rc_has "direnv hook"   || NEED="${NEED} direnv-hook"
  if [ -n "${LOCAL_BIN}" ]; then
    rc_has '.local/bin' || NEED="${NEED} local-bin"
  fi

  if [ -z "${NEED}" ]; then
    info "${RC} は設定済み"
  else
    info "${RC} に追記します:${NEED}"
    {
      echo ""
      echo "${MARK}"
      case "${NEED}" in *local-bin*)   echo 'export PATH="$HOME/.local/bin:$PATH"' ;; esac
      case "${NEED}" in *aqua-path*)   echo 'export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"' ;; esac
      case "${NEED}" in *direnv-hook*) echo "eval \"\$(direnv hook ${SHELL_NAME})\"" ;; esac
    } >> "${RC}"
    warn "追記しました。この後 'source ${RC}' するか、新しいシェルを開いてください"
  fi
fi

########################################
# aqua でツールを入れる (ここで task が入る)
########################################
info "aqua install"
aqua install

# このスクリプト内でも aqua のツールを使えるようにする
PATH="${AQUA_BIN}:${PATH}"
export PATH

have task || die "task が見つかりません。'source ${RC}' してからもう一度実行してください"

########################################
# 本体
########################################
info "task init"
task init

info "完了しました"
if [ -n "${RC}" ]; then
  echo "    新しいシェルを開くか 'source ${RC}' を実行してください"
fi
