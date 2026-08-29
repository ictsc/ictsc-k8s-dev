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
- 監視スタック
- kubelogin (kubectl の OIDC 認証。Dex は導入済み)
- Secret の Git 管理 (SOPS / sealed-secrets)
- CI (terraform fmt / tflint / helm lint)
