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
│   ├── base/     (env 共通の Helm values)
│   ├── envs/     (env ごとの Application と生成物。手で編集しない)
│   └── scripts/  (envs/ を terraform output から生成する)
│
├── aqua.yaml     (CLI のバージョン固定)
└── Taskfile.yaml (タスク定義)
```

## 構成

- **OS**: Talos Linux `v1.13.8` (nocloud イメージ)
- **Kubernetes**: `v1.36.3` / CNI は Cilium (kube-proxy 置き換え)
- **IaC**: Terraform (`sacloud/sakura` v3.12.7) + Terraform workspace で `dev` / `prod` を分離
- **GitOps**: Argo CD (app-of-apps)
- **監視**: Prometheus / Alertmanager / Grafana、Grafana Alloy + Loki（Pod ログを 7 日保持）
- **入口**: Cilium Gateway API + cert-manager (Let's Encrypt / HTTP-01)
- **認証**: Dex (GitHub) + oauth2-proxy を Gateway API の ExternalAuth で前段に置く
- **ノードのスペック** (`terraform/vars.tf`)
  - control plane / 踏み台: 2コア / 4GB / ディスク 40GB
  - worker (dev): 6コア / 12GB / ディスク 40GB
  - 以前このドキュメントには「使えるサーバスペックの上限は 2コア / 4GB」と
    書いてあったが**誤り**。2026-08-29 に tk1a で 6コア / 12GB (`cloud/plan/6core-12gb`)
    の worker 3台が問題なく起動することを確認済み。上限で悩んだら実際に apply して試すこと

### ネットワーク

| セグメント | 用途 |
| --- | --- |
| ルータ+スイッチ (`sakura_internet`, dev / prod とも /27) | 全ノードの eth0。API VIP と LoadBalancer IP もここ |
| vSwitch `192.168.100.0/24` (`sakura_vswitch`) | 全ノードの eth1。etcd のピア通信 |

グローバルIPの割り当て (`terraform/locals.tf`):

```plain
ip_addresses[0 .. cp-1]           control plane
ip_addresses[cp]                  Kubernetes API VIP  (Talos の shared VIP)
ip_addresses[cp+1]                Ingress VIP         (Cilium LB IPAM + L2 Announcement)
ip_addresses[cp+2 .. cp+1+wk]     worker node
ip_addresses[cp+2+wk]             踏み台
```

必要なグローバルIP数は `cp + worker + 3` (VIP 2個 + 踏み台 1個)。
netmask は後から変更できない (`terraform/vars.tf` の WARNING を参照) ので余裕を持たせている。

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

aqua 管理外なのは3つだけ。

| ツール | なぜ aqua 管理外か |
| --- | --- |
| `aqua` | 以降のツールを入れる本体 |
| `direnv` | シェルの hook を rc ファイルに仕込む必要があり、リポジトリ単位の管理に馴染まない |
| `zstd` | aqua の標準レジストリに無い。`talos/scripts/fetch-image.sh` が Talos イメージの展開に使う |

`task` も `init.sh` より前に必要だが、**`aqua.yaml` に入れてあるので `aqua install` で入る**
(下記の手順を参照)。別途インストールしなくてよい。

#### macOS

```console
$ brew install aqua direnv zstd
```

#### Linux

**`./init.sh` が全部やる** ので、通常は手で入れるものは無い。中でやっているのは:

1. `direnv` / `zstd` をディストリのパッケージから導入 (apt / dnf / pacman / zypper)
2. `aqua` を [GitHub Releases](https://github.com/aquaproj/aqua/releases) から取得
   (チェックサム検証つき、`~/.local/bin` へ配置)
3. `.bashrc` / `.zshrc` に PATH と direnv hook を追記 (既に書いてあれば触らない)
4. `aqua install` -> `task init`

> [!NOTE]
> `go install github.com/aquaproj/aqua/v2/cmd/aqua@latest` でも入るが、
> **ツールチェーンの再取得とビルドで数 GB の一時領域を使う**ため、`/tmp` が
> 小さい VM では `no space left on device` で落ちる。`init.sh` は
> ビルドしない配布バイナリを取りに行く。

> [!WARNING]
> **空き容量に注意。** このリポジトリは Talos の raw イメージ (約 4GB) を
> ダウンロードしてさくらへアップロードする。aqua が入れるツール類も数百 MB ある。
> `init.sh` は起動時に `/tmp` と `$HOME` の空きを確認して警告する。

手で入れたい場合はこれでよい (arm64 なら `aqua_linux_arm64.tar.gz`)。

```console
$ mkdir -p ~/.local/bin
$ curl -sSfL https://github.com/aquaproj/aqua/releases/download/v2.62.3/aqua_linux_amd64.tar.gz \
    | tar -xz -C ~/.local/bin aqua
$ export PATH="$HOME/.local/bin:$PATH"
```

#### シェルの設定 (macOS / Linux 共通)

`aqua` と `direnv` はどちらもシェルの設定が要る。`.zshrc` (bash なら `.bashrc`) に:

```bash
# zsh の場合 (.zshrc)
export PATH="$HOME/.local/bin:$PATH"        # aqua 本体をここに置いた場合
export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"
eval "$(direnv hook zsh)"
```

```bash
# bash の場合 (.bashrc)
export PATH="$HOME/.local/bin:$PATH"        # aqua 本体をここに置いた場合
export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"
eval "$(direnv hook bash)"
```

2行の PATH は役割が違う。

| PATH | 中身 |
| --- | --- |
| `$HOME/.local/bin` | **`aqua` 本体**の置き場 (`init.sh` はここに置く) |
| `${AQUA_ROOT_DIR:-...}/bin` | **aqua が入れるツール** (`task` / `terraform` / `kubectl` など) |

> [!NOTE]
> PATH は `$(aqua root-dir)` と書いてもよいが、それだと `aqua` 自身が先に PATH に
> 通っている必要がある。上の `${AQUA_ROOT_DIR:-...}` 形式なら aqua を実行せずに
> 展開できるので、`go install` で入れた直後でもそのまま動く。

設定を反映したら、リポジトリ直下で `aqua install` を先に叩く。ここで `task` が入る。

```console
$ aqua install
$ task --version    # aqua 側の task が引ければ OK
```

これで「必要なツール」は揃うので、あとは `./init.sh` に進める。

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
| `gh` | v2.97.0 | `task argocd-repo-key` が deploy key の登録に使う。`gh auth login` 済みであること |
| `task` | v3.52.0 | |
| `jq` | 1.8.2 | |
| `envsubst` | v1.4.3 | `task init-env` が `.envrc.tmpl` を埋めるのに使う (a8m/envsubst) |

## 環境変数と direnv

このリポジトリは **direnv 前提**です。API キーやバケット名は `.envrc` に置き、
リポジトリに入った時点で direnv が自動で読み込む。`.envrc` は gitignore してあるので、
**メンバーそれぞれが自分の手元で用意する**（`./init.sh` が対話で聞いて、
リポジトリに入っている **`.envrc.tmpl`** を `envsubst` で埋めて作ってくれる）。

秘密情報を task が対話で聞き直すことはしない。**task は常に環境変数を見る**ので、
新しい値が要るようになったら `.envrc.tmpl` にプレースホルダを足す。
作り直したいときは `task reset-env`。

`.envrc` に入る値は `.envrc.tmpl` を参照。内訳はこう:

| 変数 | 用途 |
| --- | --- |
| `KUBECONFIG` / `TALOSCONFIG` | kubectl / talosctl の設定をリポジトリ内に閉じる |
| `SAKURACLOUD_ACCESS_TOKEN` / `_SECRET` | さくらのクラウド API キー |
| `SAKURACLOUD_ZONE` | サーバを建てるゾーン (`tk1b` = 東京第2) |
| `TF_STATE_BUCKET` / `TF_CLI_ARGS_init` | tfstate 置き場 (さくらのオブジェクトストレージ) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | 同上のアクセスキー |
| `AWS_REQUEST_CHECKSUM_CALCULATION` | さくらのオブジェクトストレージ側の不具合のワークアラウンド |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | Dex が使う GitHub App。`task auth-secrets` が読む |
| `ACME_EMAIL` | Let's Encrypt の通知先。`task render-env-values` が読む |

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
| `task bootstrap-cluster` | Cilium と Argo CD を helm で入れる |
| `task argocd-repo-key` | deploy key を作って GitHub に登録し、Argo CD に持たせる |
| `task auth-secrets` | Dex / oauth2-proxy / Argo CD の OIDC 用 Secret を作る |
| `task start-gitops` | app-of-apps のルートを適用して Argo CD に引き継ぐ |
| `task health` | `talosctl health` でクラスタの健全性を確認 |

`task auth-secrets` は **`.envrc` の `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`** を読む。
GitHub App (または OAuth App) は `./init.sh` より先に用意しておくこと
(「認証 (Dex + oauth2-proxy)」を参照)。未設定なら task はその場で落ちるので、
`.envrc` に足して `direnv allow` するか `task reset-env` でやり直す。
`argocd-repo-key` は `gh` で deploy key を登録するので、リポジトリの admin 権限が要る。
どちらも作成済みなら status 判定でスキップされる。

> [!WARNING]
> **`terraform apply` がサーバ作成中にタイムアウトや 409 で落ちたら、孤児サーバを疑うこと。**
> ゾーンが混んでいるとサーバ作成に数十分かかることがあり、さくら側では作成が完了して
> いるのに Terraform が ID を state に書く前に落ちる場合がある。再 apply すると
> `res_already_connected` (ディスクが state 外のサーバに繋がっている) で必ず失敗する。
>
> 作り直す必要はない。`terraform state show sakura_disk.worker_node[N]` の `server_id` が
> 孤児サーバの ID なので、実物を API で確認したうえで import すればよい。
>
> ```console
> $ terraform state show 'sakura_disk.worker_node[2]' | grep server_id
> $ terraform import 'sakura_server.worker_node[2]' <その server_id>
> $ terraform plan   # computed 属性と timeouts だけの差分になるので apply して落ち着かせる
> ```

> [!NOTE]
> `manifest/envs/<env>/resources/` は `bootstrap-cluster` では撒かない。
> ClusterIssuer や Certificate は cert-manager の CRD を必要とし、ExternalAuth 付きの
> HTTPRoute は oauth2-proxy より後でなければならないため、順序は Argo CD の
> sync-wave に任せている。

> [!NOTE]
> `talosctl health` は「全 k8s ノードが Ready」「全 Pod が Running」まで待つ。
> CNI は `bootstrap-cluster` で後入れするので、**それより前に走らせると絶対に成功せず
> `--wait-timeout` ぶん待たされる**。そのため `talos-bootstrap` では etcd の起動確認までに留め、
> 本来の health チェックは CNI 投入後の `task health` に分けてある。

```console
# Argo CD の初期パスワード
$ task argocd-password
```

## ログ確認

Grafana の **Explore** でデータソース `Loki` を選ぶと、Alloy が収集した全 namespace の
Pod ログを検索できる。代表的な LogQL は次のとおり。

```logql
{namespace="kube-system"}
{namespace="argocd", container="argocd-server"} |= "error"
{app="httpbin"} | json
```

付与するラベルは `cluster` / `namespace` / `pod` / `container` / `node` / `app` / `job`。
ログは Loki の NFS PVC (5Gi) に保存し、7 日を過ぎたデータを削除する。Alloy は
Kubernetes API 経由で Pod ログを読むため、Talos 自体のサービスログは収集対象外。

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

## 認証 (Dex + oauth2-proxy)

認証を持たないアプリの前段に oauth2-proxy を置き、Cilium Gateway API の
`ExternalAuth` フィルタ (GEP-1494) から認可を問い合わせる。GitHub とのやり取りは
Dex に集約しているので、**GitHub 側に登録する callback は Dex の1本だけ**。

```plain
GitHub App --(callback: dex.<domain>/callback)--> Dex --OIDC--> oauth2-proxy
                                                                    |
                                              ExternalAuth (ext_authz) で問い合わせ
                                                                    v
                                                              保護対象アプリ
```

### 保護対象アプリを増やす

`task render-env-values` が生成するファイルなので、`manifest/scripts/render-env.sh`
を編集してから再生成すること。GitHub 側の作業は不要。

1. `values/dex.yaml` の `staticClients[].redirectURIs` に `https://<host>/oauth2/callback`
2. `resources/gateway.yaml` の Certificate `dnsNames` に `<host>`
3. `resources/httproutes.yaml` に HTTPRoute を追加
   - `/oauth2` は oauth2-proxy へ素通し (ここを保護すると OAuth が完了できない)
   - それ以外に `ExternalAuth` フィルタを付けて実体へ流す
   - `sync-wave` は oauth2-proxy より後 (下記の注意を参照)

> [!WARNING]
> 認可バックエンドの Service が存在しない状態で `ExternalAuth` 付きの HTTPRoute が
> 生えると、Cilium は ext_authz フィルタを組まず**認証なしで素通しする**。
> `ResolvedRefs=False` はステータスに出るがトラフィックは止まらない。
> 保護対象の HTTPRoute には必ず oauth2-proxy より後の `sync-wave` を付けること。

> [!NOTE]
> oauth2-proxy はログイン後の戻り先を相対パスでしか保持しないため、callback は
> **保護対象ホスト自身**に置く必要がある。別ホスト (auth.<domain> など) に集約すると
> ログイン後に元のアプリへ戻れない。

### kubectl を GitHub SSO で使う

`kubectl` も同じ Dex を OIDC プロバイダとして使う。証明書ベースの管理者 kubeconfig
(`task kubeconfig` が取るもの) とは独立して動くので、**Dex が落ちても締め出されない**。

```plain
kubectl --> kubelogin --> ブラウザ --> Dex --> GitHub (org: ictsc)
                                        |
                                    ID Token
                                        v
                                 kube-apiserver が検証
```

`ictsc` org の `ictsc2026` team のメンバーに `cluster-admin` が付く
(`manifest/envs/<env>/resources/rbac-oidc.yaml`)。

> [!NOTE]
> Kubernetes 1.35 で `--oidc-*` フラグは**削除**された。そのため apiserver へは
> `AuthenticationConfiguration` をファイルで渡している。Talos v1.13 には専用の
> 設定フィールドが無い (`authConfig` / `authenticationConfig` はどちらも
> unknown key) ので、`machine.files` で置いて `extraVolumes` で読ませている。
> 生成は `talos/scripts/gen-config.sh`。

#### 使い方

`aqua install` で `kubelogin` が入る (`kubectl oidc-login` として呼ばれる)。
自分の kubeconfig に context を足す:

```console
$ kubectl config set-credentials oidc \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-command=kubectl \
    --exec-interactive-mode=IfAvailable \
    --exec-arg=oidc-login \
    --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url=https://dex.k8s-dev.ictsc.net \
    --exec-arg=--oidc-client-id=kubernetes \
    --exec-arg=--oidc-extra-scope=profile \
    --exec-arg=--oidc-extra-scope=email \
    --exec-arg=--oidc-extra-scope=groups

$ kubectl config set-context ictsc-dev-sso \
    --cluster=ictsc-dev --user=oidc

$ kubectl config use-context ictsc-dev-sso
$ kubectl get nodes          # ブラウザが開いて GitHub 認証 -> 成功すれば完了
```

`--cluster` の名前は `kubectl config get-clusters` で確認すること
(`task kubeconfig` が作る context 名は workspace 名 = `dev`)。

> [!WARNING]
> 上のコマンドには落とし穴が2つある。
>
> - **`--exec-interactive-mode` は必須。** `client.authentication.k8s.io/v1` には
>   既定値が無く、省略すると
>   `interactiveMode must be specified for oidc to use exec authentication plugin`
>   で `kubectl` が何もできなくなる (`v1beta1` なら既定値があるので出ない)。
> - **`--exec-arg` の値にカンマを書かない。** `set-credentials` はカンマを引数の
>   区切りとして解釈するため、`--oidc-extra-scope=profile,email,groups` は
>   `--oidc-extra-scope=profile` / `email` / `groups` の3引数に分解されて壊れる。
>   スコープは1つずつ `--exec-arg` を並べること。

トークンは `~/.kube/cache/oidc-login/` にキャッシュされる。作り直したいときは:

```console
$ rm -rf ~/.kube/cache/oidc-login
```

#### 権限を渡す team を増やす

Dex の github connector は `orgs` に `teams` を書いていなくても、groups claim を
**`<org>:<team>` 形式**で返す。org 名だけの `ictsc` は返ってこないので、
RBAC には team を列挙する必要がある (ワイルドカードは書けない)。

新しい team を作ったら `manifest/scripts/render-env.sh` の `rbac-oidc.yaml` の
`subjects` に `oidc:<org>:<team>` を足して `task render-env-values`。

自分のトークンに何が入っているかは、ログイン後にこれで見られる:

```console
$ cat ~/.kube/cache/oidc-login/* | jq -r .id_token \
    | cut -d. -f2 | base64 -d 2>/dev/null | jq '{email, groups}'
{
  "email": "you@example.com",
  "groups": ["ictsc:ictsc2026"]
}
```

> [!WARNING]
> apiserver に渡すファイルは **`permissions: 0o444`** でなければならない。
> apiserver は非 root (UID 65534) で動くため、`0o400` にすると読めずに
> exit 1 で crashloop する。また `op:` は **`create`** を使うこと。
> `overwrite` は既存ファイル前提なので、初回は
> `file must exist: ...` で `writeUserFiles` ごと失敗し、
> **kubelet も etcd も起動しなくなる**。

> [!WARNING]
> この設定変更は control plane の**再起動を伴う**。必ず **1台ずつ**
> `talosctl apply-config` して、`kubectl get pod -n kube-system | grep apiserver` が
> `1/1 Running` になったのを確認してから次へ進むこと。3台同時にやると
> etcd の quorum を失う。

## talosctl は踏み台経由で使う

`apid` (50000) と `trustd` (50001) はパケットフィルタで**踏み台からのみ**に絞ってある
(`terraform/packet-filter.tf`)。手元から直接は届かないので、ラッパー経由で叩く。

```console
$ ./talos/scripts/talosctl-via-bastion.sh -n 192.168.100.1 version
$ ./talos/scripts/talosctl-via-bastion.sh -n 192.168.100.1 dmesg
```

SSH のポート転送で踏み台を経由し、終わったらトンネルを畳む。`-e` は指定しない
(スクリプトが `127.0.0.1` に差し替える)。`Taskfile.yaml` の talosctl 呼び出しは
すべてこれを通しているので、`task health` などはそのまま使える。

| 環境変数 | 既定 | 用途 |
| --- | --- | --- |
| `TALOS_EP` | control plane の1台目 | 経由する control plane のグローバル IP。`upgrade-talos` は「対象ノード以外」を経由するためにこれを指定している |
| `BASTION_SSH_USER` | `ubuntu` | 踏み台の SSH ユーザ |
| `TALOS_TUNNEL_PORT` | `50000` | ローカル側の待ち受けポート |

**`kubectl` はトンネル不要。** 6443 は送信元を絞っていない (認証は TLS + OIDC/証明書
+ RBAC に任せている)。

> [!WARNING]
> **戻り通信の許可レンジ (32768-61000) は apid/trustd のポートを含んでしまう。**
> さくらのパケットフィルタはステートレスなので、自分から出した通信の戻りを
> destination port で許可するしかない。ところが 50000 / 50001 はそのレンジの内側に
> あるため、素直に書くと「踏み台のみ許可」のつもりが**全世界から apid に届く**。
> 許可ルールの後、戻り通信の許可より**前**に 50000 / 50001 の明示的な deny を
> 置くこと (`local.pf_deny_talos_api`)。順序が意味を持つ。
>
> 確認は踏み台の外から:
>
> ```console
> $ nc -z -G 6 <control plane のグローバルIP> 50000   # 失敗すれば正しい
> ```

## アップグレード

> [!CAUTION]
> **`terraform/vars.tf` の `talos_version` / `kubernetes_version` を上げても
> 稼働中のクラスタは上がらない。** これらは「これから作るノード」の指定であって、
> 既存ノードには効かない。
>
> しかも `talos_version` は、素のままだと **全ディスクを作り直す** plan を作る
> (`source_archive_id` が変わるため)。ディスクを作り直すと etcd も Talos の
> STATE パーティション (machine config 本体) も消えるので、クラスタは全損する。
> いまは `sakura_disk` に `ignore_changes = [source_archive_id]` を入れて
> 防いであるが、**この lifecycle ブロックを外さないこと**。

更新の経路は3系統ある。それぞれ独立していて、Terraform は OS/Kubernetes の
更新に一切関与しない。

| 対象 | やり方 |
| --- | --- |
| Talos OS | `task upgrade-talos TO=v1.13.9` |
| Kubernetes | `task upgrade-k8s TO=1.36.4` |
| Cilium / cert-manager などの Helm チャート | `manifest/envs/<env>/*.yaml` の `targetRevision` を上げて push (Argo CD が反映) |

### Talos OS

```console
$ task upgrade-talos TO=v1.13.9
```

`talosctl upgrade` を **control plane から1台ずつ** 実行する。cp を並列で落とすと
etcd の quorum を失うため、1台が Ready に戻るまで次へ進まない。
cordon と evict は `talosctl upgrade` が自前でやる (`--drain` が既定 true)。
対象ノード自身を endpoint にすると再起動で経路が切れるので、別の cp を経由する。

machine config は STATE パーティションに残るので消えない。

> [!NOTE]
> schematic に system extension を足した場合は、installer イメージを
> `ghcr.io/siderolabs/installer` ではなく
> `factory.talos.dev/installer/<schematic>` に変える必要がある。
> 現在の schematic は `customization: {}` (拡張なし) なので素の installer で等価。

### Kubernetes

```console
$ task upgrade-k8s TO=1.36.4
```

`talosctl upgrade-k8s` は **1回叩くだけで全ノードを面倒みる**。ノードの自動検出、
Talos とのバージョン互換性チェック、イメージの事前 pull、
apiserver → controller-manager → scheduler → kubelet の順序まで自前でやるので、
ノードごとにループする必要はない。task は実行前に `--dry-run` の結果を表示する。

- **マイナーは1つずつ** (1.36 → 1.37 → 1.38)。飛ばせない
- **パッチは飛ばしてよい** (1.36.1 → 1.36.4)

> [!WARNING]
> `--to` を省くと talosctl 自身が持つ既定値になる。talosctl v1.13.8 の既定は
> **1.36.2** で、いま動いているのは 1.36.3 のため、省略すると *ダウングレード* になる。
> そのため `TO` は必須にしてある。

### リンク名が変わることがある (実例: v1.13.8 -> v1.13.9)

Talos は OS のバージョンでネットワークインターフェースの名前を変えることがある。
実際 **v1.13.9 で `eth0`/`eth1` から `ens3`/`ens4` に変わった**。
名前に依存した設定は、OS を上げた瞬間に静かに壊れる。

**machine config 側**は名前ではなく **PCI バスパス**で選んでいる
(`talos/scripts/gen-config.sh`)。バスパスは Terraform が NIC を繋ぐ順序
(0 = グローバル / 1 = 内部) で決まり、Talos のバージョンでは変わらない。

```yaml
- deviceSelector:
    busPath: "0000:00:03.0"   # グローバル (eth0 / ens3)
- deviceSelector:
    busPath: "0000:00:04.0"   # 内部 (eth1 / ens4)
```

MAC でも選べるが、MAC はサーバを作った後にしか分からない。ISO を先に焼くこの構成
(`apply-network` -> `talos-config` -> `apply-terraform`) では使えない。

> [!WARNING]
> **Cilium はインターフェースを名前でしか選べない。**
> `manifest/envs/<env>/resources/cilium-l2-announcement.yaml` の `interfaces` は
> `^(eth0|ens3)$` のように新旧どちらも許容しておくこと。
> 片方だけだと全ノードを上げ終わった瞬間に Ingress VIP の広報が止まり、
> **外部から一切到達できなくなる**。しかも Gateway の `PROGRAMMED` は `True` の
> ままなので気づきにくい。

名前で書いてしまっていた場合、上げたノードはこうなる。**ノード自体は正常に
起動していて apid も応答する**ので、ハングと勘違いしやすい。

| 症状 | 理由 |
| --- | --- |
| グローバル IP に ping も talosctl も通らない | 静的アドレスがどのリンクにも適用されず、グローバル側が素のまま |
| `kubectl get node` が NotReady | kubelet が API にも DNS にも届かない |
| 内部セグメントの DHCP レンジ (`192.168.100.200-250`) に居る | 設定が当たらず DHCP にフォールバックし、踏み台からリースを貰う |
| `talosctl --insecure` が `tls: certificate required` | maintenance mode ではなく、config は入っている |

復旧は **再起動不要**。踏み台から DHCP レンジを ping で走査してノードを見つけ、
バスパス版の config を当てるだけでよい。

```console
$ ssh <踏み台> 'for i in $(seq 200 250); do ping -c1 -W1 192.168.100.$i >/dev/null 2>&1 && echo 192.168.100.$i; done'
$ talosctl -n <見つけたIP> -e <別のcpのグローバルIP> apply-config -f talos/build/<cluster>/config/<hostname>.yaml
```

> [!NOTE]
> 上げる前に、**全ノードへ先にバスパス版の config を当てておく**と壊れない。
> config の適用は再起動を伴わず、古い Talos (eth0/eth1) でも同じ NIC にマッチする。

### 更新後にバージョン表記を揃える

実体の更新とは別に、以下も同じ値にしておくこと。**揃えなくてもクラスタは動くが、
次にノードを増やしたときだけ古いバージョンで作られる**という分かりにくい状態になる。

| ファイル | 項目 |
| --- | --- |
| `aqua.yaml` | `siderolabs/talos` (talosctl 本体)、`kubernetes/kubernetes/kubectl` |
| `Taskfile.yaml` | `TALOS_VERSION` (イメージ取得) |
| `terraform/vars.tf` | `talos_version`、`kubernetes_version` |

`talosctl` のバージョンは `upgrade` / `upgrade-k8s` の既定値を決めるので、
先に `aqua.yaml` を上げて `aqua install` しておくとよい。

## 2台目以降のマシンでセットアップする

tfstate は さくらのオブジェクトストレージ (石狩) の S3 backend に置いてあるので、
**マシン間で共有されている**。`terraform` 関連で持ち回るものは無い。

git に入っていないので手で持ち込む必要があるのは次の2つだけ。

| ファイル | 入手方法 |
| --- | --- |
| `.envrc` | `./init.sh` が対話で聞いて作る (API キーなどを手元で入力) |
| **`talos/secrets.yaml`** | **既存クラスタを構築したマシンからコピーする** |

```console
$ ./init.sh
$ scp <構築したマシン>:<リポジトリ>/talos/secrets.yaml talos/secrets.yaml
$ task select-dev      # workspace は default から始まるので必ず選ぶ
```

`talosconfig` と `.kube/config` は `secrets.yaml` から再生成されるので、
コピーしなくてよい (`task talos-config` / `task kubeconfig`)。

> [!CAUTION]
> **`talos/secrets.yaml` はクラスタの PKI 本体。** これが無い状態で
> `task talos-config` を走らせると、gen-config.sh は「初回構築だ」と判断して
> **別のクラスタの秘密情報を新規生成する**。そのまま apply すると CD-ROM が
> 別 CA で署名された machine config で上書きされ、ノードが再ブートストラップした
> 瞬間にクラスタへ参加できなくなる。talosctl も一切通らなくなる。
>
> 現在は `task talos-config` の冒頭で「tfstate にサーバが在るのに
> secrets.yaml が無い」場合に停止するようにしてあるが、**そもそも先に
> コピーしておくこと**。

> [!NOTE]
> `secrets.yaml` を紛失すると既存クラスタを操作する手段が完全に失われる。
> 構築したマシン以外にもバックアップを取っておくこと。

## 秘密情報

- `.envrc.tmpl` — `.envrc` の雛形 (これはコミットする)
- `.envrc` — さくらのクラウドの API キーなど (gitignore 済み / direnv が読む)
- `talos/secrets.yaml` — **クラスタの PKI。これを失うとクラスタを操作できなくなる**ので
  必ずどこかにバックアップすること (gitignore 済み)
- `talos/talosconfig` — talosctl のクライアント証明書 (gitignore 済み)

Secret は Git に置かないので、クラスタに直接作る (Argo CD の管理外)。
`task up` が下記を呼ぶので、通常は手で作る必要はない。

| task | 作る Secret |
| --- | --- |
| `task auth-secrets` | `dex/dex-secrets` `oauth2-proxy/oidc` `argocd/argocd-oidc` |
| `task argocd-repo-key` | `argocd/repo-<repo>` (deploy key。GitHub 側にも登録する) |

## まだやってないこと

- ノード名の DNS 登録 (VIP は Cloudflare に登録済み。ノードは `/etc/hosts` 運用)
- IPv6 (`enable_ipv6 = false`。drove は dual stack)
- ストレージ (Rook/Ceph)
- kubelogin (kubectl の OIDC 認証。Dex は導入済み)
- Secret の Git 管理 (SOPS / sealed-secrets)
- CI (terraform fmt / tflint / helm lint)
