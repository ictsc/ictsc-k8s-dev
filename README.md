# ictsc-k8s-dev

さくらのクラウド上に Talos Linux で Kubernetes クラスタを立てる、とりあえずの一式。
[ictsc-drove](https://github.com/ictsc/ictsc-drove) の構成をベースに、
OS のプロビジョニング (Ansible + kubeadm) を Talos に置き換えたもの。

## ディレクトリ構成

```plain
ictsc-k8s-dev/
│
├── terraform/  (さくらのクラウドのリソース定義。provider は sacloud/sakura)
├── talos/      (Talos の machine config パッチと生成スクリプト)
├── manifest/   (Kubernetes マニフェスト。Argo CD の app-of-apps)
│
├── aqua.yaml     (CLI のバージョン固定)
└── Taskfile.yaml (タスク定義)
```

## 構成

- **OS**: Talos Linux `v1.13.8` (nocloud イメージ)
- **Kubernetes**: `v1.36.3` / CNI は Cilium (kube-proxy 置き換え)
- **IaC**: Terraform (`sacloud/sakura` v3.12.7) + Terraform workspace で `dev` / `prod` を分離
- **GitOps**: Argo CD (app-of-apps)
- **ノードのスペック**: 全ノード 2コア / 4GB / ディスク 40GB (`terraform/vars.tf`)
  - 使えるサーバスペックの上限が **2コア / 4GB** なので、これ以上は盛れない。
    足りない場合は台数 (`control_plane` / `worker_node`) を増やす方向で対応する

### ネットワーク

| セグメント | 用途 |
| --- | --- |
| ルータ+スイッチ (`sakura_internet`, dev は /28) | 全ノードの eth0。API VIP と LoadBalancer IP もここ |
| vSwitch `192.168.100.0/24` (`sakura_vswitch`) | 全ノードの eth1。etcd のピア通信 |

グローバルIPの割り当て (`terraform/locals.tf`):

```plain
ip_addresses[0 .. cp-1]           control plane
ip_addresses[cp]                  Kubernetes API VIP  (Talos の shared VIP)
ip_addresses[cp+1]                Ingress VIP         (Cilium LB IPAM + L2 Announcement)
ip_addresses[cp+2 ..]             worker node
```

### Talos の設定をどうやってノードに届けるか

さくらのクラウドの「ディスクの修正」(`disk_edit_parameter`) は Talos に対応していない。
そこで **ノードごとの machine config を cloud-init NoCloud (`cidata`) の ISO にして
CD-ROM としてアタッチ**している。Talos の nocloud プラットフォームは
ラベル `cidata` のブロックデバイスから `user-data` を読むので、これで静的IPごと設定が入る。

そのため apply は 2 段構えになっている:

1. `sakura_internet` だけ先に作ってグローバルIPを確定させる
2. その出力から machine config と ISO を生成する
3. 残り (アーカイブ・CD-ROM・ディスク・サーバ) を作る

`task apply` がこの順番を面倒みる。

> [!NOTE]
> CD-ROM はあくまで**初回ブートストラップ用**。Talos は初回起動時に machine config を
> STATE パーティションへ保存するので、構築後の設定変更は `talosctl apply-config` で行うこと。

## 必要なツール

CLI のバージョンは [aqua](https://aquaproj.github.io/) で固定している (`aqua.yaml`)。
ただし **`./init.sh` を動かすのに必要な `aqua` / `task` / `direnv` だけは、
aqua より前に手で入れる**必要がある (`init.sh` が `task init` を叩くため)。

### 1. ブートストラップ用のツール (手で入れる)

```console
$ brew install aqua go-task direnv zstd
```

| ツール | 入れ方 | なぜ aqua 管理外か |
| --- | --- | --- |
| `aqua` | `brew install aqua` / [公式ドキュメント](https://aquaproj.github.io/docs/install) | 以降のツールを入れる本体 |
| `task` | `brew install go-task` / [公式ドキュメント](https://taskfile.dev/ja-JP/installation/) | `init.sh` が `task init` を叩くので `aqua install` より前に要る |
| `direnv` | `brew install direnv` / [公式ドキュメント](https://github.com/direnv/direnv/blob/master/docs/installation.md) | シェルの hook を `.zshrc` に仕込む必要があり、リポジトリ単位の管理に馴染まない |
| `zstd` | `brew install zstd` | aqua の標準レジストリに無い。`talos/scripts/fetch-image.sh` が Talos イメージの展開に使う |

`aqua` と `direnv` はシェルの設定が要る。`.zshrc` (bash なら `.bashrc`) に以下を入れておくこと。

```bash
export PATH="$(aqua root-dir)/bin:$PATH"
eval "$(direnv hook zsh)"
```

> [!NOTE]
> `task` は `aqua.yaml` にも入れてある。上記の PATH を通しておけば、
> `aqua install` 後は aqua 側の `task` (バージョン固定された方) が優先される。
> brew 版はあくまで初回の呼び水。

### 2. aqua で入るツール

`./init.sh` (中身は `task init`) が `aqua install` まで面倒をみるので、通常は個別に叩かなくてよい。

```console
$ aqua install
```

| ツール | バージョン | 備考 |
| --- | --- | --- |
| `talosctl` | v1.13.8 | `Taskfile.yaml` の `TALOS_VERSION` と揃える |
| `terraform` | v1.13.2 | terraform-ictsc-net (CI が 1.13.2 固定) と tfstate を共有するため揃える |
| `tflint` | v0.64.0 | |
| `kubectl` | v1.36.3 | `terraform/vars.tf` の `kubernetes_version` と揃える |
| `helm` | v3.21.3 | Argo CD の repo-server が内蔵する Helm に合わせて v3 系に固定 |
| `task` | v3.52.0 | |
| `jq` | 1.8.2 | |

## 環境変数と direnv

このリポジトリは **direnv 前提**です。API キーやバケット名は `.envrc` に置き、
リポジトリに入った時点で direnv が自動で読み込む。`.envrc` は gitignore してあるので、
**メンバーそれぞれが自分の手元で用意する**（`./init.sh` が対話で作ってくれる）。

`.envrc` はこんな中身になる:

```bash
export KUBECONFIG=./.kube/config
export TALOSCONFIG=./talos/talosconfig

export SAKURACLOUD_ACCESS_TOKEN=...        # さくらのクラウド API キー
export SAKURACLOUD_ACCESS_TOKEN_SECRET=...
export SAKURACLOUD_ZONE=tk1b               # 東京第2

# tfstate 用 (さくらのオブジェクトストレージ)
export TF_STATE_BUCKET=ictsc-void-k8s-dev
export TF_CLI_ARGS_init="-backend-config=bucket=$TF_STATE_BUCKET"
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

# https://cloud.sakura.ad.jp/news/2025/02/04/objectstorage_defectversion/ のワークアラウンド
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
```

`terraform` の `backend "s3"` ブロックは変数展開ができないので、バケット名は
**`TF_CLI_ARGS_init`** 経由で `terraform init` に渡している。
direnv が効いていれば `terraform init` を素で叩くだけでよい。

> [!WARNING]
> direnv が効いていないと `terraform init` が `Enter a value:` でバケット名を聞いてくる。
> `direnv allow` を実行したか、シェルに direnv の hook を入れたかを確認すること。
>
> ```console
> $ direnv allow
> $ echo $TF_CLI_ARGS_init   # -backend-config=bucket=... が出れば OK
> ```

`SAKURACLOUD_ZONE` はサーバを建てるゾーン (`tk1b` = 東京第2)。
tfstate を置くオブジェクトストレージは石狩 (`s3.isk01.sakurastorage.jp` / `jp-north-1`) で、
こちらはサーバのゾーンとは独立している。ゾーンを変える場合は
`terraform/vars.tf` の `nameservers` (ノードが引く再帰DNS) も合わせて変えること。

## 使い方

```console
# 0. ブートストラップ用のツール (「必要なツール」を参照)
$ brew install aqua go-task direnv zstd

# 1. 初期化 (aqua install / .envrc の作成 / terraform init)
$ ./init.sh

# 2. ワークスペースを選ぶ
$ task select-dev

# 3. 構築 -> ブートストラップ -> CNI/Argo CD まで一気に
$ task up
```

`task up` の中身は以下と同じ。詰まったら個別に叩ける。

| task | 内容 |
| --- | --- |
| `task fetch-talos-image` | Image Factory から nocloud の raw イメージを取得 |
| `task apply` | Terraform でインフラを構築 (上記 2 段構えを内包) |
| `task talos-bootstrap` | `talosctl bootstrap` で etcd を初期化 |
| `task kubeconfig` | kubeconfig を `.kube/config` に取得 |
| `task render-env-values` | terraform output を manifest の env 固有値に反映 |
| `task bootstrap-cluster` | Cilium と Argo CD を helm で入れて app-of-apps を適用 |
| `task health` | `talosctl health` でクラスタの健全性を確認 |

> [!NOTE]
> `talosctl health` は「全 k8s ノードが Ready」「全 Pod が Running」まで待つ。
> CNI は `bootstrap-cluster` で後入れするので、**それより前に走らせると絶対に成功せず
> `--wait-timeout` ぶん待たされる**。そのため `talos-bootstrap` では etcd の起動確認までに留め、
> 本来の health チェックは CNI 投入後の `task health` に分けてある。

```console
# Argo CD の初期パスワード
$ task argocd-password
```

## 名前解決 (DNS)

さくらのクラウドに DNS ゾーンは**作っていない**。`ictsc.net` は Cloudflare で管理していて、
VIP のレコードは [terraform-ictsc-net](https://github.com/ictsc/terraform-ictsc-net) の
`k8s-records.tf` が**このリポジトリの tfstate を `terraform_remote_state` で読んで**生成する。

| レコード | 参照する output |
| --- | --- |
| `k8s-dev.ictsc.net` (A) | `ingress_vip` |
| `*.k8s-dev.ictsc.net` (CNAME) | ― (`k8s-dev.ictsc.net` を向く。`argocd.k8s-dev` などを拾う) |
| `k8s.k8s-dev.ictsc.net` (A) | `api_vip` |

VIP は `sakura_internet` を作った時点 (`task apply` の1段目) で確定するので、
**クラスタの構築完了を待たずに terraform-ictsc-net を apply してよい**。

```console
# ictsc-k8s-dev 側で apply したあと
$ cd ../terraform-ictsc-net && terraform apply
```

> [!NOTE]
> terraform-ictsc-net 側のオブジェクトストレージのキーには、
> `TF_STATE_BUCKET` (既定 `ictsc-void-k8s-dev`) の **READ 権限**が要る。

### DNS を使わない場合 (/etc/hosts)

DNS のレコードを作る前に動作確認したいときは、`/etc/hosts` に貼る。

```console
$ task hosts
# --- ictsc-dev (terraform output hosts_entries) ---
203.0.113.3 k8s.k8s-dev.ictsc.net
203.0.113.4 k8s-dev.ictsc.net argocd.k8s-dev.ictsc.net
203.0.113.0 ictsc-dev-cp-1
...

# そのまま追記するなら
$ cd terraform && terraform output -raw hosts_entries | sudo tee -a /etc/hosts
```

> [!WARNING]
> `/etc/hosts` は DNS より優先される。terraform-ictsc-net を apply して Cloudflare 側で
> 引けるようになったら、**`/etc/hosts` の行は消しておくこと**。消し忘れると VIP を
> 変更したときに古いIPを見続けることになる。

ノード名 (`ictsc-dev-cp-1` など) は DNS には登録していないので、
そちらを名前で引きたい場合は `/etc/hosts` を使う。

## 秘密情報

- `.envrc` — さくらのクラウドの API キーなど (gitignore 済み / direnv が読む)
- `talos/secrets.yaml` — **クラスタの PKI。これを失うとクラスタを操作できなくなる**ので
  必ずどこかにバックアップすること (gitignore 済み)
- `talos/talosconfig` — talosctl のクライアント証明書 (gitignore 済み)

## まだやってないこと

- ノード名の DNS 登録 (VIP は Cloudflare に登録済み。ノードは `/etc/hosts` 運用)
- IPv6 (`enable_ipv6 = false`。drove は dual stack)
- ストレージ (Rook/Ceph)
- Ingress Controller / cert-manager / 監視スタック
- OIDC 認証 (dex + kubelogin)
- CI (terraform fmt / tflint / helm lint)
