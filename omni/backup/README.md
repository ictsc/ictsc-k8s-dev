# Omni 本体のバックアップと復旧

Issue #14。これは管理対象Kubernetesのetcdバックアップとは別の、Omni VMの復旧用。
実機へは未導入。sudo操作の承認と外部保存先が決まるまでtimerを有効にしない。

## 導入前提

- 現在のOmni/embedded etcdのバージョンを確認し、同じmajor/minorの `etcdctl` / `etcdutl` を導入する。
- VMに `restic`、Python 3、`flock` が必要。
- VM外の専用restic repositoryを作り、読み書きできる限定キーを用意する。
- resticのパスワードは `/etc/omni-backup.password` (root:root、0600) 等に置き、
  **別の承認済み保管庫にも復旧用コピーを保存する**。VMだけに置くとVM喪失時に復号できない。
- root:root、0600の `/etc/omni-backup.env` に `RESTIC_REPOSITORY`、`RESTIC_PASSWORD_FILE`、
  S3なら専用の `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` を設定する。値をGitやログへ書かない。
- backend bucket、PostgreSQL backup bucketと認証情報を共用しない。
- `restic init` は保存先が空であることを確認して初回のみ実施する。

## 取得と自動化

`scripts/backup.sh` を `/usr/local/sbin/omni-backup` に0750で配置する。
etcd APIのsnapshot、SQLite Online Backup API、設定・復号鍵・TLSを取得し、
resticで暗号化して外部へ転送する。稼働中のDBディレクトリを単純コピーしない。
取得はサービス無停止だが、etcdとSQLiteはそれぞれの整合したsnapshotであり、
両DBを横断する同一時点の保証はない。Omniの変更・鍵ローテーション中は実施を避ける。
最初の復元演習で、この組み合わせが現行Omniに適合することを確認してから定期化する。

```bash
# sudoで実施。設定をロードしたrootシェル内で手動取得・確認する。
set -a
. /etc/omni-backup.env
set +a
/usr/local/sbin/omni-backup
restic snapshots --host ictsc-omni --tag omni-recovery
bash verify-backup.sh SNAPSHOT_ID /var/tmp/omni-restore-check-YYYYMMDD
```

確認後にservice/timerを `/etc/systemd/system/` へ配置して
`systemctl daemon-reload && systemctl enable --now omni-backup.timer` を実施する。
目標RPOは1時間5分、目標RTOは60分（未実測、SLAではない）。
運用監視では `systemctl --failed` と `/var/lib/omni-backup/last-success` の経過時間を確認し、
最終成功から2時間以上なら障害扱いとする。外部通知への接続は未実施。

保存期限はまず削除なしで開始する。復元成功を確認した後に
`restic forget --host ictsc-omni --tag omni-recovery --group-by host,tags --keep-hourly 48 --keep-daily 30 --dry-run`
で対象をレビューして保持削除を有効化する。自動pruneはこの変更には含めない。

## 災害復旧

1. 別マシンで保管庫からrestic認証とパスワードを取得する。
2. `verify-backup.sh` で新しい空ディレクトリに復元し、etcd restoreとSQLite integrityを検証する。
3. 外部通信を遮断した演習VMを用意する。復元Omniを本番ノードへ接続しない。
4. 本番と同じOmniバージョン、compose、UID/GIDで、復元したetcdデータ・SQLite・設定・鍵を配置する。
   etcdのmember名・advertise URLは実機と整合させる。証明書の期限と復号鍵の一致を確認する。
5. 隔離環境でログインとクラスタ/マシン管理データを確認し、復旧時間を記録する。
6. 実災害では旧Omniを停止/隔離して二重稼働を防いでからIP/DNSを切り替える。
   一度に全ノードの管理設定を変更しない。

`verify-backup.sh` は構造とDB整合性の検査までであり、ログイン/管理機能の復旧確認を代替しない。
管理対象クラスタのetcd保存先・最終成功・復旧鍵もOmni UI/APIで別途確認する。
Omni停止中のbreak-glassは事前発行・保管した緊急用Talos/Kubernetes認証で行う。
devの認証をprodへ流用せず、Omniだけを唯一の認証情報保管先にしない。

参考: [Omni DB backup](https://docs.siderolabs.com/omni/self-hosted/back-up-omni-db)。
