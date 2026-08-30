# パケットフィルタ (eth0 = グローバル側のみ)
#
# WARNING: さくらのクラウドのパケットフィルタは **受信のみ・ステートレス**。
#          自分から出した通信の戻りパケットも明示的に許可しないと落ちる。
#          (マニュアル: TCP/UDP の 32768-61000 を許可すること)
#          忘れると DNS・NTP・イメージ pull・ACME・apiserver から Dex への
#          問い合わせが全て死ぬ。末尾の deny より前に local.pf_return を必ず置く。
#
# NOTE: 内部セグメント (eth1) にはフィルタを付けない。etcd のピア通信 (2379/2380)
#       と kubelet はそちらを通る。apiserver から kubelet への接続も
#       kubelet-preferred-address-types で InternalIP を優先させてある。

locals {
  # 戻り通信。ステートレスなので必須 (上の WARNING を参照)
  pf_return = [
    {
      protocol         = "tcp"
      destination_port = "32768-61000"
      allow            = true
      description      = "戻り: 自分から出した TCP の応答 (イメージ pull / ACME / Dex)"
    },
    {
      protocol         = "udp"
      destination_port = "32768-61000"
      allow            = true
      description      = "戻り: 自分から出した UDP の応答 (DNS / NTP)"
    },
    {
      # 2番目以降のフラグメントにはポート番号が無いため、
      # 明示的に通さないと大きな UDP 応答 (DNS) などが落ちる
      protocol    = "fragment"
      allow       = true
      description = "フラグメントされたパケット"
    },
  ]

  pf_icmp = [
    {
      protocol    = "icmp"
      allow       = true
      description = "疎通確認と Path MTU Discovery"
    },
  ]

  pf_deny = [
    {
      protocol    = "ip"
      allow       = false
      description = "上記以外は破棄 (etcd メトリクス 2381 や cilium-envoy 9964 もここで塞がる)"
    },
  ]

  # Ingress VIP は Cilium の L2 Announcement でノード間を移動するため、
  # cp / worker のどのノードにも着地しうる。全ノードで開けておく。
  pf_ingress = [
    {
      protocol         = "tcp"
      destination_port = "80"
      allow            = true
      description      = "Ingress VIP (ACME HTTP-01 のチャレンジもここ)"
    },
    {
      protocol         = "tcp"
      destination_port = "443"
      allow            = true
      description      = "Ingress VIP (Argo CD / Dex / httpbin)"
    },
  ]

  # 6443 は送信元を絞らない。
  #
  # 主防御は TLS + クライアント証明書 / OIDC + RBAC であって送信元 IP ではない。
  # 絞ると (a) メンバーの回線が変わるたびに締め出される (b) KubePrism の
  # endpoints には control plane の *グローバル* IP も含まれる
  # (talosctl get kubeprismendpoints で確認できる) ため、ノード間の接続まで
  # 巻き込んで壊す、という運用コストの方が大きい。
  pf_kube_api = [
    {
      protocol         = "tcp"
      destination_port = "6443"
      allow            = true
      description      = "kube-apiserver (認証は TLS + OIDC/証明書 + RBAC に任せる)"
    },
  ]

  # 一方 apid (50000) はノードを直接操作でき、reset でディスクまで消せる。
  # ここは踏み台からのみに絞る。
  #
  # 作業端末の IP を許可する変数も用意していたが、tfstate は共有されているのに
  # 変数はマシンごとのローカルファイルだったため、apply したマシンによって
  # ルールが増えたり消えたりしていた (CI から apply すると必ず消える)。
  # 手元から talosctl を打つときは踏み台経由の SSH トンネルを使う。
  #
  # NOTE: さくらのパケットフィルタは SourceNetwork のマスク長を 0〜31 しか
  #       受け付けない。単一ホストは "/32" を付けずに書くこと (API が 400 を返す)。
  pf_talos_api = [
    {
      protocol         = "tcp"
      source_network   = local.bastion_ip
      destination_port = "50000"
      allow            = true
      description      = "talosctl (apid) — 踏み台からのみ"
    },
  ]

  # trustd。worker が control plane から証明書を受け取るのに使う。
  # apid のサーバ証明書の更新にも必要なので、塞ぐと後から静かに壊れる。
  # 外に出す必要はないため、送信元はクラスタのセグメント自身に限定する。
  pf_trustd = [
    {
      protocol         = "tcp"
      source_network   = local.external_cidr
      destination_port = "50001"
      allow            = true
      description      = "ノード間の trustd (証明書の受け渡し)"
    },
  ]
}

########################################
# Control Plane
########################################

resource "sakura_packet_filter" "control_plane" {
  name = "${local.name}-cp"
}

resource "sakura_packet_filter_rules" "control_plane" {
  packet_filter_id = sakura_packet_filter.control_plane.id

  expression = concat(
    local.pf_icmp,
    local.pf_kube_api,
    local.pf_talos_api,
    local.pf_trustd,
    local.pf_ingress,
    local.pf_return,
    local.pf_deny,
  )
}

########################################
# Worker Node
########################################

resource "sakura_packet_filter" "worker" {
  name = "${local.name}-worker"
}

resource "sakura_packet_filter_rules" "worker" {
  packet_filter_id = sakura_packet_filter.worker.id

  expression = concat(
    local.pf_icmp,
    local.pf_talos_api,
    local.pf_trustd,
    local.pf_ingress,
    local.pf_return,
    local.pf_deny,
  )
}

########################################
# 踏み台
########################################

resource "sakura_packet_filter" "bastion" {
  name = "${local.name}-bastion"
}

resource "sakura_packet_filter_rules" "bastion" {
  packet_filter_id = sakura_packet_filter.bastion.id

  expression = concat(
    [
      {
        # 踏み台はここから入るための唯一の入口なので送信元は絞らない。
        # SSH のパスワード認証は無効 (公開鍵のみ) にしてある。
        protocol         = "tcp"
        destination_port = "22"
        allow            = true
        description      = "SSH (公開鍵認証のみ)"
      },
    ],
    local.pf_icmp,
    local.pf_return,
    local.pf_deny,
  )
}
