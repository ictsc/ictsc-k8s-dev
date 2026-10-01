# Longhorn の容量不足とディスク移行

## 現在の方針

2026-10-01のユーザー指定により、物理ディスクは既存の20 GiBを維持する。
有料ディスクの追加・拡張は実施しない。以下の拡張案は未採用の検討記録。
ログは7日、Prometheusのメトリクスは15日・8 GB上限を維持する。
ユーザー承認のもと、worker 1のOS領域へ停止済みPrometheus replicaをコピーし、
全7ファイルのバイト単位の一致を確認してからPrometheusのPVCを再作成した。
旧メトリクスは通常の画面からは参照できない。
退避先はworker 1の `/var/longhorn-recovery/20261001-prometheus-worker1`、
一致確認記録は同階層の `.verified` ファイル。
これは障害時replicaのコピーであり、アプリケーションとしての復元検証は未実施。
OSディスクと同時に失われるため恒久バックアップとして扱わない。
この退避先はLonghornへ登録していない。

追加確認で `postgres-3` が `pg_wal/RECOVERYHISTORY` のfsync時に
`No space left on device` で再起動していた。primaryとpostgres-2はReady。
DBのファイルシステム内の満杯とLonghorn物理ディスク満杯は分けて確認する。
空き容量が戻った後も旧primaryのpostgres-1にはI/O errorが残ったため、
standby 2台のSQL応答・同一WAL再生位置を確認してからPodを再起動した。
postgres-2がprimaryへ昇格し、postgres-1/3のstreamingと全3台Readyを確認済み。
DBのPVCは削除していない。Longhorn全7volumeがhealthyへ復旧した。

Omniのクラスタetcd定期バックアップは `s3 store is not initialized` で失敗していた。
prod CPから手動snapshotを取得し、SHA-256チェックサムを検証してから
Kubernetes 1.36.4→1.36.5の更新をapplyした。
更新完了後、全6nodeのv1.36.5/Ready、Omni ready、DB 3/3 Ready、
全7volume healthy、scoreserver frontend/backend各2/2 Ready、Prometheus 2/2 Readyを確認した。
Omni Terraformの再planは差分なし。
snapshotはGit除外の `.omni/backups/ictsc-prod-before-k8s-1.36.5-20261001.snapshot`
（mode 600）。Omni本体のバックアップとは別物。定期バックアップ先の設定は未解決。

Discord通知先は `monitoring/alertmanager-discord` とさくらSecret Managerの
`prod-discord-webhook` をユーザー指定の値へ更新し、Alertmanagerへの読み込みを確認した。
Webhookの値はGitへ保存しない。Longhorn容量・degraded/faultedの4ルールを追加し、
評価正常と3disk・7volumeのメトリクス収集を確認済み。
送信先切替後にDiscord通知カウンターが16→17へ増加し、失敗カウンターは全理由0。
復旧中に停止したroot／kube-prometheus-stackのArgo CD自動同期は元へ戻した。

## 2026-10-01 の prod 障害

worker 1/3 の専用 SSD (各20 GiB) が満杯になり、Prometheus の10 GiBボリューム
`pvc-72e7dca7-ccc8-437e-8c90-774e53a187ad` が detached / faulted になった。
worker 1 の当該replicaはスナップショット込みで約19 GiBを使用している。
worker 2には約8.6 GiBの空きがあるが、Prometheus replicaは再構築未完了で
`healthyAt` が空。これを復旧元にはしない。
この時点でPostgreSQLは3/3 Ready、DBの3ボリュームはhealthy。
これは確認時点の記録であり、操作前には必ず再確認する。

容量予約率やPVC容量の変更だけでは、物理ディスクの空きは増えない。
Longhornのsnapshot purgeも一時的な空き領域を必要とするため、満杯のディスクで
実行しない。replicaディレクトリ内のファイルを直接削除してはいけない。

## 移行前の確認

- インフラは `bash scripts/terraform-env.sh prod ...`、クラスタ操作は
  `kubectl --context ictsc-prod ...` を使用する。
- 新ディスク容量と追加費用を決める。東京ゾーンSSDの月額税込は20 GBが770円、
  40 GBが1,540円、100 GBが3,850円（2026-10-01の公式料金）。
  3台の置換完了・旧ディスク撤去後の差額は40 GBで2,310円、100 GBで9,240円。
  旧ディスク保持中は新ディスク分が追加課金される。
- 全volume/replicaの状態・配置・disk UUIDを保存する。DBバックアップと
  CNPGの健全性を確認する。faulted volumeの元replicaを削除しない。
- ディスクの `size` だけを変更してapplyしない。provider 3.12.7のplanで
  `3 to add, 3 to destroy` を確認済み。既存リソースは `prevent_destroy` で保護する。

## データを保持する移行方針（未実施）

1. 元ディスクを保持する別Terraformリソースとして、大きいコピー先を用意する。
   コピーは対象workerの書き込みを停止してから実施する。
2. worker 1を最初の候補とし、実際のDB・replica配置を再確認して1台だけ退避・停止する。
   PDBやLonghornの保護で停止する場合は強制drainせず、配置を解決する。
3. 停止中の専用データディスクをクラウドのディスクコピーで複製する。
   コピー完了・サイズ・元IDを確認後、OSディスクを維持してデータディスクだけ切り替える。
   元ディスクは切り離して保持し、同じUUIDのコピーと同時接続しない。
4. GPT/パーティションとXFSの拡張方法をコピー先で検証する。
   Talosの `grow: true` は既存パーティションの拡張を保証しない。
   さくらのパブリックアーカイブ向け「ディスク修正」をTalosへそのまま適用しない。
   実機コマンドはデバイス・パーティション開始位置・ラベルを確認してから確定する。
5. 再起動後、TalosのマウントとLonghornのdisk UUID・実容量を確認する。
   コピー先のreplicaでPrometheusのsalvage可否を確認し、履歴と読み書きを検証する。
   空き容量が戻っても破損データの回復までは保証されない。
6. 再構築完了を確認してから残りのworkerを1台ずつ移行する。
   元ディスクの削除は全ボリュームhealthy・アプリ正常・バックアップ確認後に別途判断する。
7. 最終構成をTerraformへ反映し、意図しない置換・削除がないplanを確認する。

## 復旧後の再発防止

- Prometheusは既に保持量8 GB・15日、PVCは10 GiB。Longhornのsnapshotはこの制限の外。
- 障害時はrecurring jobがなく、snapshot max countは250。
  system snapshotの毎時整理・filesystem trimの毎日実行をmanifestに準備済み。
  定期処理の登録は別途承認待ち。復旧前のsnapshot削除やtrimによる追加負荷は避ける。
- Longhornの物理空き容量・volume actual size・degraded/faultedを監視し、
  更新前は退避先の空き容量と再構築余力も確認する。
- Prometheus自身が停止すると通知できないため、外部からの死活監視も用意する。

## 参考

- [さくらのディスク料金](https://cloud.sakura.ad.jp/products/disk/)
- [さくらのディスクコピーによる拡張](https://manual.sakura.ad.jp/cloud/design-pattern/tips/disk-expand.html)
- [Longhorn: 容量不足からの復旧](https://longhorn.io/kb/manual-recovery-of-nodes-with-insufficient-space/)
- [Talos 1.13 User Volumes](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/user)
