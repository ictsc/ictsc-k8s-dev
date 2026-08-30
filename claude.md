# 設計決定事項と背景

このファイルはエージェント向けの設計メモです。README に書ききれない背景や経緯、トレードオフを残しています。

---

## 全ノードの eth0 でグローバル IP が割り当てられる理由

### 事実
さくらのクラウドでは `sakura_internet` にサーバを接続すると、IP プールから自動的にグローバル IP が割り当てられます。すべてのノードが `sakura_internet` に繋がっているため、全ノードに個別のグローバル IP が付きます。

### なぜ繋ぐ必要があるか
API VIP（Talos shared VIP）と Ingress VIP（Cilium LB IPAM + L2 Announcement）は**同一 L2 上で ARP を打つ必要がある**ため、全ノードの eth0 は `sakura_internet` に繋がっている必要があります。

### しかし「外部から到達できる必要があるのは VIP（2個）と踏み台（1個）だけ」

個別のノード IP がインターネットから自由に到達できる必要はありません。そこで、**パケットフィルタで各ノードの管理ポート（50000/tcp 等）を踏み台に制限**しています。

### 代替案（将来の検討事項）

| 案 | 概要 | ＋ | − |
|---|---|---|---|
| **踏み台NAT** | 踏み台のみグローバルIP、他は全プライベート | グローバルIPが最小（3個のみ） | TalosのNAT越し動作要検証、踏み台がSPOF/ボトルネック |
| **ELB + プライベート** | ELBにグローバルIP、ノードはvSwitchのみ | SPOFなし、IP最小化 | ELB追加コスト、L2 VIPが使えなくなる |
| **VPCルータ** | さくらVPCルータでNAT/ルーティング | AWS的なNW構成が可能 | コスト・管理工数増、L2 VIP要件との検証要 |

現状は「最もシンプルで検証済み」な選択ですが、セキュリティ要件/コストが厳しくなれば ELB 導入によるプライベート化が次のステップです。

---

## Talos の設定投入経路

### 初回ブート：CD-ROM (cidata ISO) 経由

Talos はさくらのクラウド「ディスク修正」に非対応。そこで **NoCloud (cidata) の ISO を CD-ROM としてアタッチ**し、静的 IP 含む machine config を注入しています。

```
gen-config.sh → machine config YAML → build-iso.sh → ISO
                                    ↓
                              sakura_cdrom でアップロード
                                    ↓
                         サーバ作成時に cdrom_id でマウント
```

- **初回のみ** ISO から `user-data` を読み込み、STATE パーティションに保存
- 構築後の変更は `talosctl apply-config` で行う
- ISO はあくまでブートストラップ用（README 注記参照）

### 構築後運用：talosctl 経由

```bash
# TALOSCONFIG は talos/talosconfig
talosctl -n <cp-ip> -e <cp-ip> apply-config -f xxx.yaml
```

エンドポイントには**全 control plane の external_ip を登録**（`config endpoints`）。従来 `config endpoint` で1台のみだったが、フェイルオーバーが効かないため複数化した。

### 踏み台の役割

「maintenance mode の Talos が eth1 で DHCP アドレスを掴む → 踏み台から `talosctl apply-config --insecure` を打つ」という経路を用意している。

通常フローでは ISO から正常起動するため踏み台は不要だが、**config が壊れて maintenance mode に陥った緊急時**に使う。

---

## Talos ベストプラクティス（公式 v1.13 ベース）

参考: https://docs.siderolabs.com/talos/v1.13/getting-started/prodnotes

### Control Plane
- **奇数台**（3 or 5）。2台は最悪（quorum を取れず片方落ちると停止）
- etcd 性能が slow → 台数増やさず**垂直スケール**
- Node 入替時は「壊れたノードを先に remove → 新しいノードを後に add」

### Machine Config
- **パッチを Git で管理**し、base は `talosctl gen config` で再生成
- **multi-document patch** で小さな変更を積み重ねる
- `talosctl validate` で事前検証（現状は実装済み）
- `gen-config.sh` では `--talos-version` を明示（将来の互換性保護）

### Multihoming
`etcd.advertisedSubnets` と `kubelet.nodeIP.validSubnets` は**同じサブネットに揃える**。揃わないと `talosctl health` が通らない、CNI 経路が不安定になる。

現状では内部セグメント `192.168.100.0/24` に統一。

### Talos API（port 50000）のセキュリティ
> maintenance mode の Talos API は未認証。— ネットワークレベルで保護するか、ブート時に user-data で config を注入するか、ファイアウォールルールで制限すべき

→ **インターネットに直接晒すのは避ける**。現状では `sakura_packet_filter` で踏み台 IP のみ許可。

### talosctl endpoint
```bash
# ❌ bad: 単一ノード
config endpoint <ip>

# ✅ good: 全CP登録（自動 LB & fail-over）
config endpoints <ip1> <ip2> <ip3>
```

---

## Secret 管理

現状は **Git に置かず、クラスタ内に直接作成**している。`task up` → `task start-gitops` の依存で `task auth-secrets` + `task argocd-repo-key` が自動実行される。

### OIDC 認証（Dex 連携）
- `argocd` namespace の Secret `argocd-oidc`
- values: `clientSecret: $argocd-oidc:clientSecret`（Argo CD Helm Chart の機能）
- 作成元: `task auth-secrets`

### Git リポジトリ認証（Deploy Key）
- `argocd` namespace の Secret `repo-<repo-name>`
- Argo CD が private repo（このリポジトリ自身）を読むための SSH deploy key
- 作成元: `task argocd-repo-key`

### 未導入
SOPS / sealed-secrets 等の Git 管理は README の「まだやってないこと」に記載。将来的に導入を検討。

---

## パケットフィルタ設計

全ノード（CP / Worker / Bastion）の eth0（グローバル側）に `sakura_packet_filter` を適用。

### Control Plane
| proto | src | dst port | action |
|---|---|---|---|
| icmp | any | - | allow |
| tcp | bastion/32 | 50000 | allow |
| tcp | bastion/32 | 6443 | allow |
| ip | any | - | deny |

### Worker
| proto | src | dst port | action |
|---|---|---|---|
| icmp | any | - | allow |
| tcp | bastion/32 | 50000 | allow |
| ip | any | - | deny |

### Bastion
| proto | src | dst port | action |
|---|---|---|---|
| tcp | any | 22 | allow |
| icmp | any | - | allow |
| ip | any | - | deny |

意図:
- Talos API（50000）は maintenance mode で未認証のため、**踏み台以外からは完全遮断**
- kube-apiserver（6443）は緊急時の踏み台経由アクセスのみ許可
- Bastion は SSH（22）のみ。パスワード認証は無効で鍵認証のみ
