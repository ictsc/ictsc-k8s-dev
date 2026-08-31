# WARNING: さくらのクラウドのパケットフィルタは **受信のみ・ステートレス**。
# 戻り通信 (32768-61000) を deny より前に許可する。対象は eth0 のみ。

locals {
  # 50000/50001 は戻り通信レンジ内なので、明示 deny を先に置く。
  pf_deny_talos_api = [
    {
      protocol         = "tcp"
      destination_port = "50000"
      allow            = false
      description      = "apid は上で許可した送信元以外は破棄 (戻り通信レンジに入るため)"
    },
    {
      protocol         = "tcp"
      destination_port = "50001"
      allow            = false
      description      = "trustd も同様"
    },
  ]

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
      # 2番目以降のフラグメントにはポート番号がない。
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

  # Ingress VIP は全ノードに着地しうる。
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

  # 6443 は KubePrism のノード間接続にも使うため、TLS・OIDC・RBAC で保護する。
  pf_kube_api = [
    {
      protocol         = "tcp"
      destination_port = "6443"
      allow            = true
      description      = "kube-apiserver (認証は TLS + OIDC/証明書 + RBAC に任せる)"
    },
  ]

  # apid は踏み台経由の SSH トンネルだけに限定する。
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

  # trustd は証明書発行・更新に必要。クラスタの外部セグメント内だけ許可する。
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
    local.pf_deny_talos_api,
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
    local.pf_deny_talos_api,
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
    local.pf_deny_talos_api,
    local.pf_return,
    local.pf_deny,
  )
}
