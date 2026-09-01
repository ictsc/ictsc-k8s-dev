# Self-hosted Omni

`ictsc-dev` と将来の `ictsc-prod` を管理するOmniを、Kubernetesクラスタの外にある
専用Ubuntu VMで動かす。Omniが停止しても既存クラスタは稼働を続ける。

## 構成

- Omni `v1.8.0` + embedded etcd
- Dex `v2.41.1`（初回はstatic password。GitHub連携は稼働確認後に追加）
- 2 vCPU / 8 GiB / 250 GiB SSD
- `omni.ictsc.net` / `auth.omni.ictsc.net`
- グローバルIP: devルータ+スイッチの未使用アドレス `.109`
- TLS: Let's Encrypt HTTP-01

OmniのTerraform stateは `omni/terraform.tfstate` とし、クラスタ本体のworkspaceから
分離する。Omniのetcd暗号鍵、Dex設定、OIDC secretはVMの `/opt/omni`、etcdとSQLiteは
`/var/lib/omni` に保存し、GitやTerraform stateには入れない。

## 1. plan

```bash
task plan-omni
```

作成される有料リソースは、Ubuntu VM 1台と250 GiB SSD 1台。既存の
`ictsc-dev-external` に接続するため、ルータ+スイッチは追加しない。

東京第1ゾーンの公開価格APIで確認した月額（税込）は、2Core/8GBが7,480円、
250GB SSDが9,625円、合計17,105円。6ノードだけを管理する初期構成なら、SSDを
100GB（月3,850円、合計11,330円）へ下げる選択肢もある。

plan確認後、明示的に実行する。

```bash
task apply-omni
```

## 2. DNS

```bash
task omni-dns
```

表示された2つのAレコードを `terraform-ictsc-net` に追加する。両方の名前がOmni IPを
返すまで、次のセットアップは進めない。

## 3. Omniを起動

```bash
task configure-omni OMNI_ADMIN_EMAIL=<admin-email>
```

初回adminのパスワードを対話入力する。セットアップは証明書、etcd暗号鍵、Dexの
OIDC secretをVM上で生成し、systemdの `omni.service` としてDocker Composeを起動する。
EULAまたは組織契約の確認は最初にUIを開いた時点で完了する。

既存devクラスタのDexで使っているGitHub AppをOmniのDexでも使う場合は、対象クラスタの
kubeconfig contextを選んでから次を実行する。Client Secretは表示せずVMへ転送される。

```bash
task configure-omni-github-sso
```

GitHub Appにはcallback URLとして
`https://auth.omni.ictsc.net:5556/callback`を登録しておく。ローカルadminログインは
復旧経路として残る。

## 4. omnictlを準備

```bash
task fetch-omnictl
mkdir -p .omni/keys
```

Omni UIから取得したomniconfigを `.omni/config`、認証鍵を `.omni/keys/` に置く。
どちらも `.gitignore` 済み。

## 5. 既存devクラスタをdry-run import

```bash
task health
task omni-import-dry-run
```

Talos APIは踏み台以外から遮断されているため、Taskは一時的にomniconfig、認証鍵、
talosconfigを踏み台へ転送してdry-runし、終了時に削除する。

import時のバージョン基準はノードから検出した現行版を使う。

- Talos: `1.13.9`
- Kubernetes: `1.36.4`

Omni v1.8.0は `--initial-talos-version` / `--initial-kubernetes-version` の入力を
import内部で参照しないため、これらの引数は指定しない。

dry-runの差分では、少なくとも次を確認する。

- API VIPと内部 `192.168.100.0/24` のネットワーク設定が保持される
- `etcd.advertisedSubnets` と `kubelet.nodeIP.validSubnets` が内部セグメントのまま
- Longhorn用UserVolumeとsystem extensionsが保持される
- kube-proxy無効化、KubePrism、OIDC AuthenticationConfigurationが保持される
- Image Factory schematicが現在のものとして認識される

## 6. 管理移管

dry-runのレビュー後にのみ、同じ引数から `--dry-run` を外してimportする。import直後の
クラスタは `locked` であり、Omniはまだ構成変更を行わない。Omni UIのConfig/Patchesと
全ノードの接続を確認してからunlockする。

```bash
task omni-import
```

Taskはimportが出力したmachine config backupを `.omni/backups/` へ回収する。
回収に失敗した場合は、認証情報を削除した上でbackupのみを踏み台に保持する。

unlock後にKubernetesとワークロードの健全性を確認できるまで、次を削除しない。

- `talos/secrets.yaml`
- `talos/talosconfig`
- importが出力したmachine config backup
- ノードへ接続中のcidata CD-ROM

移行完了後の別変更で、cidata生成・CD-ROM attachment・手動upgrade Taskを撤去し、
Omni cluster templateをGit上の正とする。

## 7. 新規ノードの自動払い出し

既存クラスタのimportとは別に、Omniのauto-provision Machine Classからさくらのクラウドの
Serverを作成するdynamic infrastructure providerを `infra-provider-sakura/` に実装している。
OmniでID `sakura` のInfra Providerを作成し、発行されたprovider keyを使って起動する。

```bash
task test-omni-infra-provider
task configure-omni-infra-provider OMNI_VM_IP=<omni-vm-ip> OMNI_INFRA_PROVIDER_KEY=<provider-key>
```

GitHub Actionsがmainへの変更から、このリポジトリのGHCRへproviderイメージを発行する。
利用時は `OMNI_INFRA_PROVIDER_IMAGE` でイメージ名を指定できる。

providerの共有defaultsは `omni/infra-provider-sakura/config.yaml` に置く。Terraformのstateや
実行環境は不要で、bootstrapを有効にすればInternet、vSwitch、packet filter、IP poolを
providerが冪等に準備する。Talos archiveは既存IDを指定するか、source archive IDから複製する。

Machine Classの設定例、IP poolの非重複要件、事前登録が必要なTalos archiveについては
[`infra-provider-sakura/README.md`](infra-provider-sakura/README.md) を参照。

## バックアップ

最低限、VMスナップショットに次を含める。

- `/var/lib/omni/etcd`
- `/var/lib/omni/sqlite`
- `/opt/omni/omni.asc`
- `/opt/omni/omni.env`
- `/opt/omni/dex.yaml`
- `/etc/letsencrypt`

etcdの整合したバックアップ手順と復元テストは、dev import前に別途確認する。
