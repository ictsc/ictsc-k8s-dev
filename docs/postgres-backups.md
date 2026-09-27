# PostgreSQL backup / recovery

Issue #12。dev は Barman Cloud plugin chart 0.7.1 (plugin 0.14.0) と
CNPG 1.30 / cluster chart 0.8.1 を使用する。prod は Object Storage API が403のため、
保存先の決定・権限整備が終わるまで有効化しない。失敗する保存先をDBへ設定しない。

## 保存と目標

- dev/prod は専用バケット・専用キーで分離する。Terraform backend 用キーは使わない。
- dev: `s3://ictsc-void-k8s-dev-postgres-backups/cnpg-v1`。
- 毎日03:00 JSTにベースバックアップ、WAL は継続保存、保持期間は14日。
- 目標RPOは5分（archive_timeout=300s）。転送障害中は保証されない。
- 目標RTOは60分。実測値は復元検証後に記録する。これは合意済みSLAではない。
- バケットは `prevent_destroy`。保持削除は Barman に任せ、WALをS3 lifecycleで独自削除しない。
- `PostgresBackupStale`、`PostgresBackupMetricsMissing`、`PostgresWALArchiveFailing` を監視する。

## 初回設定

```bash
task tf:dev -- plan -target=sakura_object_storage_bucket.postgres_backup \
  -target=sakura_object_storage_permission.postgres_backup -out=../.omni/dev-postgres-backup.tfplan
task tf:dev -- apply ../.omni/dev-postgres-backup.tfplan
task postgres-backup-secrets ENV=dev
```

対象限定planは既存ノードを変更せず新規の保存先を先行準備するために使う。
通常のインフラ更新では全体planも確認する。
`postgres_backup_storage` 出力の endpoint/bucket と環境別 values が一致することを確認し、
その後にマニフェストをpushする。Secret値はCLI引数・ファイル・ログへ出さない。
資格情報はremote Terraform stateから再取得できる。stateとその認証情報の復旧も必要。

prodの導入時は保存先を決定したうえで `postgres_backup_enabled.prod`、
prodのBarman Application、DB用backup-valuesと保存先、監視ルールを有効化する。
共通リソース側に保存する場合は先にTerraformの所有stateを決め、prodのAPIキーを流用しない。

## 検証と復旧

```bash
kubectl --kubeconfig .kube/config --context admin@ictsc-dev -n scoreserver get scheduledbackup,backup,objectstore
python3 scripts/postgres-restore-check.py dev --namespace restore-check-dev-20260927
```

復元スクリプトは新しいnamespaceだけを作り、アプリからのIngressを遮断する。
CNPG operatorからの管理用8000/tcpだけを許可し、復元DBを通常のアプリへ公開しない。
元のクラスタ名 `postgres` のアーカイブから別名のDBへ復元し、WAL archiverや
retentionを有効にしない。既存namespaceへの再実行を拒否する。
復元DBでチーム・コンテンツ・提出テーブルを照会し件数と所要時間だけを表示する。
採点等の業務上の整合性と、要求する復旧時点は別途確認すること。

実障害での切り替えはこのスクリプトの対象外。元DBへの書き込みを停止し、
復元データを確認してから接続先を切り替える。元DB/PVCを先に削除しない。
演習後は出力された専用namespace名を確認して削除する。

参考: [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)、
[S3互換ストレージの設定](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/)。
