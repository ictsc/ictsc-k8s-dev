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
# direnv / zstd
########################################
for t in direnv zstd; do
  if have "${t}"; then
    info "${t} は導入済み"
  else
    info "${t} を導入します"
    pkg_install "${t}"
  fi
done

########################################
# aqua
########################################
# aqua が入れるツールの置き場。aqua 自身を実行せずに展開できる形で書く
# (aqua root-dir を使うと aqua が先に PATH に居る必要がある)。
AQUA_BIN="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/aquaproj-aqua}/bin"
GOPATH_BIN=""

if have aqua; then
  info "aqua は導入済み ($(command -v aqua))"
else
  info "aqua を導入します"
  case "${PM}" in
    brew)
      brew install aqua
      ;;
    *)
      have go || die "aqua の導入には Go が必要です。Go を入れるか、
  https://github.com/aquaproj/aqua/releases からバイナリを PATH の通った場所に置いてください"
      go install github.com/aquaproj/aqua/v2/cmd/aqua@latest
      # go install は $(go env GOPATH)/bin に置く。ここが PATH に無いと直後に叩けない
      GOPATH_BIN="$(go env GOPATH)/bin"
      PATH="${GOPATH_BIN}:${PATH}"
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
  if [ -n "${GOPATH_BIN}" ]; then
    # GOPATH/bin は $GOPATH/bin と $(go env GOPATH)/bin の両方の書き方がありうる
    { rc_has 'GOPATH)/bin' || rc_has '$GOPATH/bin'; } || NEED="${NEED} gopath"
  fi

  if [ -z "${NEED}" ]; then
    info "${RC} は設定済み"
  else
    info "${RC} に追記します:${NEED}"
    {
      echo ""
      echo "${MARK}"
      case "${NEED}" in *gopath*)      echo 'export PATH="$(go env GOPATH)/bin:$PATH"' ;; esac
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
