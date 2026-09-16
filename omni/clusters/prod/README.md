# ictsc-prod (Omni + Terraform)

## 管理範囲

- `terraform/` の `prod` workspace: さくらのVM・ディスク・ネットワーク。
- このディレクトリ: `https://omni.ictsc.net` 上のクラスタ・所属ノード・Talosパッチ。
- Talos/Kubernetes のbootstrap・設定反映・upgradeはOmniが実施する。
- Kubernetesアプリケーションは既存のArgo CDで管理する。

Omni本体の `omni/terraform.tfstate` とdevのstateは使用しない。
このrootのstateは `omni/clusters/prod/terraform.tfstate` に分離する。
公式Omni Terraform Providerは `0.1.0-alpha.3` に固定している。
Omni v1.8.0に19リソースのapplyを実施済み。再planは差分なし。

## 規模

Control Plane 3台 (2 CPU / 4 GiB / SSD 40 GiB)、worker 3台
(6 CPU / 12 GiB / SSD 40 GiB + Longhorn SSD 20 GiB)。
外部回線100 Mbps、内部スイッチ、既存構成と同じ復旧用踏み台・NFS 20 GiB。
Talos 1.13.9 / Kubernetes 1.36.4。devの稼働構成を基準にする。

## 構築手順

環境別のAPIキー切り替えには以下のTaskを使う。

```bash
task tf:dev -- plan
task tf:prod -- plan
# 同じ操作を環境変数引数で指定する場合
task tf ENV=prod -- plan
```

`.omni/dev-sakura.env` / `.omni/prod-sakura.env` からキーを読み込み、
`config/sakura-projects.json` のプロジェクトIDとAPIの認証結果を照合する。
ファイルはGit管理外・権限600で保管する。`TF_WORKSPACE` は子プロセス内だけで
切り替わり、state用の `AWS_*` 認証や親シェルのdev設定は変更しない。
既存の `task select-prod` はworkspace選択だけであり、APIキーは切り替えない。
このTaskはさくらインフラ用で、Omni側Terraformは下記の別rootを使用する。

リポジトリルートで実行する。インフラ操作では必ず次を指定し、ローカルの
選択workspaceやdevのkubeconfigに依存させない。

```bash
task tf:prod -- plan \
  -target=sakura_internet.k8s_external -target=sakura_vswitch.k8s_internal \
  -out=../.omni/prod-network.tfplan
task tf:prod -- apply ../.omni/prod-network.tfplan
```

ネットワーク作成後にOmni参加設定と静的アドレスだけをNoCloud媒体へ格納する。
`task up`、`task talos-config`、`task talos-bootstrap` はprodでは使用しない。
devの `talos/secrets.yaml` / `talos/talosconfig` も使用しない。
bootstrap媒体にはHostnameConfig、ResolverConfig、PCI位置で選択するLinkAliasConfig、
LinkConfigとOmni参加設定だけを入れる。クラスタPKIを要求する従来の
`version: v1alpha1` 文書は含めず、生成時に全ノードを `talosctl validate` で検証する。

```bash
umask 077
bin/omnictl --omniconfig .omni/config jointoken machine-config > .omni/prod-join.yaml
task tf:prod -- output -json talos_input > .omni/prod-input.json
python3 omni/scripts/gen-prod-bootstrap.py .omni/prod-input.json
TALOS_VERSION=v1.13.9 bash talos/scripts/fetch-image.sh
task tf:prod -- plan -out=../.omni/prod-infra.tfplan
# 追加対象とサイズを確認してから実行
task tf:prod -- apply ../.omni/prod-infra.tfplan
```

ノード起動後、次のスクリプトでOmniのMachineStatusのhostnameと外部・内部IPを
照合する。6台とも接続済みで、devなど別クラスタに所属していないことを確認して
Terraform用の入力を生成する。

```bash
python3 omni/scripts/bind-prod-machines.py
```

6台のUUIDを `nodes` 入力に設定する。devのUUIDは絶対に割り当てない。
各要素は `machine_id`, `role` (`controlplane` / `worker`), `external_ip`,
`internal_ip` を持つ。キーは `ictsc-prod-cp-1` 等のhostname。
`external_gateway` も入力する。入力JSONは `.omni/prod-cluster.tfvars.json`
に保存する。

Omni管理には承認済みのOperatorサービスアカウント `terraform-ictsc-prod` を使う。
鍵はGit管理外の `.omni/prod-omni.env` に権限600で保存し、Taskから読み込む。

```bash
task tf:omni:prod -- init
task tf:omni:prod -- plan \
  -var-file=../../../.omni/prod-cluster.tfvars.json \
  -out=../../../.omni/prod-cluster.tfplan
task tf:omni:prod -- apply ../../../.omni/prod-cluster.tfplan
```

prod専用kubeconfigは以下で取得・更新する。有効期間は1時間。

```bash
task omni:prod:kubeconfig
kubectl --kubeconfig .kube/prod get nodes
```

OmniがAPIを起動したら、GitOps起動前のネットワークと証明書承認を導入する。

```bash
kubectl --kubeconfig .kube/prod apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml
helm upgrade --install cilium cilium/cilium --version 1.20.1 \
  --kubeconfig .kube/prod --namespace kube-system \
  -f manifest/base/infra/cilium/values.yaml \
  -f manifest/envs/prod/values/cilium.yaml --wait --timeout 10m
kubectl --kubeconfig .kube/prod apply -k omni/clusters/prod/bootstrap/cert-approver
kubectl --kubeconfig .kube/prod get nodes
```

証明書承認はdevのArgo CD Applicationと同じv0.11.0 / ha構成の1 replica。
GitOps導入後は既存Applicationの管理へ引き継ぐ。
GitOpsの続きは下記の `task gitops:prod` で実行する。

## 2026-09-17 時点の構築状況

- `tk1a` のルータ＋スイッチ、内部スイッチ作成がともに
  旧プロジェクトでは `409 limit_count_in_zone` で失敗。
  新しい `ICTSC_yosen` プロジェクトでネットワーク2件のapplyが完了。
  作成後のネットワークplanは差分なし。外部セグメントは `163.43.86.192/27`、
  Ingress用予約IPは `163.43.86.200`。
- Terraform用Omni Operatorサービスアカウントは作成済み。
- 6ノード、踏み台、NFS、ディスクの作成は完了。6ノードともOmni接続と
  hostname・外部IP・内部IPの照合を確認済み。
- Omniクラスタ作成と6台の割当が完了し、全6ノードReady。
- Gateway API 1.6.1、Cilium 1.20.1を導入済み。CoreDNS・Hubbleが稼働し、
  テストPodからクラスタ内DNS解決を確認済み。
- kubelet証明書承認を導入済み。6台のserving証明書が発行され、Podログ取得も確認済み。
- GitOps基盤を導入済み。Longhorn・NFSのテストPVCで読み書きを確認済み。
- 公開DNS/TLSとGitHub OAuthのprod callbackを設定済み。Regaliaは下記のデモ構成で管理する。

## GitOps

`task gitops:prod` はprod専用kubeconfigを更新し、必要なSecret・Argo CDを
bootstrapして `manifest/root-prod.yaml` を適用する。manifestは先にpushする。
GitOpsの管理元は `main` の `manifest/envs/prod`。

初回のSecret作成だけはdevのread-only deploy keyとGitHub OAuth設定を参照する。
内部OIDCクライアントSecretとcookie keyはprod専用に生成し、既存Secretは上書きしない。
Secret値はGitにもローカルファイルにも保存しない。GitHub OAuthアプリ側には
prodのcallback `https://dex.k8s.ictsc.net/callback` の対応が別途必要。

基盤ApplicationはCilium、Argo CD、cert-manager、Dex、oauth2-proxy、監視・ログ、
Longhorn、NFS CSI、CloudNativePG、metrics-server等。監視データはLonghorn、
Lokiの5Gi PVCはprodのNFSに保存する。RegaliaとDBもGitOps管理する。
ImageUpdaterのRegalia更新対象とDiscordアラート通知はまだ有効化していない。

公開Gateway・証明書・HTTPRouteは `prod-edge` Applicationに分離している。
公開DNS/証明書の待ち状態が、基盤の同期を止めないようにするため。
`*.k8s.ictsc.net` のAレコードを `163.43.86.200` に向ける必要がある。
HTTP-01認証のため80/tcpも必要。Omni経由のkubectlは公開DNSと独立して利用できる。

```bash
task omni:prod:kubeconfig
kubectl --kubeconfig .kube/prod -n argocd get applications
kubectl --kubeconfig .kube/prod get pvc -A
kubectl --kubeconfig .kube/prod -n gateway get gateway,certificate
```

2026-09-17: Longhornの監視用PVC 3個は3 replicaでhealthy、LokiのNFS PVCはBound。
一時Podで両StorageClassの書き込み・読み戻しを検証し、テスト用PVC/Podは削除済み。
公開VIPへのHTTP-01チャレンジはHost指定で200応答を確認。証明書はDNS未設定で発行待ち。

## Regalia demo

今回はprodでもdevと同じデモを公開する。`openapi-prod` は稼働確認済みdevの
backend/frontendイメージdigestを固定し、`ICTSC_DEV_FAKE_MODE=true` と
`ICTSC_DEMO_MODE=true` を設定する。DB/Valkeyはprod専用で、参加者・提出物・
セッションをdevからコピーしない。デモモードは表示上の時計・状態を固定するもので、
サーバー側の提出受付は実時間のまま。

- `https://contest.k8s.ictsc.net/`: 前段のGitHub OAuthなし。Regalia自身のDiscord認証を使用。
- `https://admin-contest.k8s.ictsc.net/`: contestantホストの `/admin/` にリダイレクト。
- `https://longhorn.k8s.ictsc.net/`: GitHub (Dex / oauth2-proxy) 認証付き。
- httpbinはprodから削除済み。

Discord Appには以下のRedirect URLを登録する。

- `https://contest.k8s.ictsc.net/api/v1/auth/discord/callback`
- `https://contest.k8s.ictsc.net/api/v1/admin/auth/discord/callback`

初期コンテンツは `config/regalia/prod-demo-content.json` に保存したdevのサンプル4問、
ルール、48チーム定義。`python3 scripts/regalia/render-prod-demo-seed.py` で
`0003_demo_seed.sql` を生成する。PreSyncのmigrationで初回投入し、既存の
コンテンツ・チーム・編集済みルールは上書きしない。再同期で提出や採点も消さない。
PostgreSQLは3インスタンスで各1GiのLonghorn単一replica、Valkeyは1GiのLonghornを使用。
