# ictsc-prod (Omni + Terraform)

## 管理範囲

- `terraform/` の `prod` workspace: さくらのVM・ディスク・ネットワーク。
- このディレクトリ: `https://omni.ictsc.net` 上のクラスタ・所属ノード・Talosパッチ。
- Talos/Kubernetes のbootstrap・設定反映・upgradeはOmniが実施する。
- Kubernetesアプリケーションは既存のArgo CDで管理する。

Omni本体の `omni/terraform.tfstate` とdevのstateは使用しない。
このrootのstateは `omni/clusters/prod/terraform.tfstate` に分離する。
公式Omni Terraform Providerは `0.1.0-alpha.3` に固定している。
`terraform validate` は検証済みだが、Omni v1.8.0への実applyは未検証。

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

Omni管理にはOperatorサービスアカウントの明示承認・発行が必要。
鍵は `OMNI_SERVICE_ACCOUNT_KEY` 環境変数に渡し、Gitへ保存しない。

```bash
unset TF_WORKSPACE TF_VAR_talos_version
terraform -chdir=omni/clusters/prod init
terraform -chdir=omni/clusters/prod plan \
  -var-file=../../../.omni/prod-cluster.tfvars.json \
  -out=../../../.omni/prod-cluster.tfplan
terraform -chdir=omni/clusters/prod apply ../../../.omni/prod-cluster.tfplan
```

OmniがAPIを起動したらprod専用kubeconfigを取得し、Ciliumを導入してノードの
Readyを確認する。続いてprod GitOps manifestの修復・render、必要なSecret、
DNS、Argo CDを準備する。現時点の `manifest/envs/prod` には欠落ファイル参照と
古いRegalia Applicationパッチがあり、そのまま同期しないこと。

## 2026-09-17 時点の未完了事項

- `tk1a` のルータ＋スイッチ、内部スイッチ作成がともに
  旧プロジェクトでは `409 limit_count_in_zone` で失敗。
  新しい `ICTSC_yosen` プロジェクトでネットワーク2件のapplyが完了。
  作成後のネットワークplanは差分なし。外部セグメントは `163.43.86.192/27`、
  Ingress用予約IPは `163.43.86.200`。
- Terraform用Omni Operatorサービスアカウントは未作成。
- 6ノード、踏み台、NFS、ディスクの作成は完了。6ノードともOmni接続と
  hostname・外部IP・内部IPの照合を確認済み。サービスアカウントの承認・発行が必要。
- Omniへのマシン登録まで完了。クラスタ割当、CNI、ストレージ、GitOps、
  Regaliaは未検証・未デプロイ。
