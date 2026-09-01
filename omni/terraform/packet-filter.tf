resource "sakura_packet_filter" "omni" {
  name = local.name
}

resource "sakura_packet_filter_rules" "omni" {
  packet_filter_id = sakura_packet_filter.omni.id

  # さくらのパケットフィルタは受信のみ・ステートレス。
  expression = [
    {
      protocol         = "tcp"
      destination_port = "22"
      allow            = true
      description      = "SSH (公開鍵認証のみ)"
    },
    {
      protocol         = "tcp"
      destination_port = "80"
      allow            = true
      description      = "Let's Encrypt HTTP-01"
    },
    {
      protocol         = "tcp"
      destination_port = "443"
      allow            = true
      description      = "Omni UI / API"
    },
    {
      protocol         = "tcp"
      destination_port = "5556"
      allow            = true
      description      = "Dex OIDC"
    },
    {
      protocol         = "tcp"
      destination_port = "8090-8091"
      allow            = true
      description      = "SideroLink machine API / event sink"
    },
    {
      protocol         = "tcp"
      destination_port = "8100"
      allow            = true
      description      = "Kubernetes proxy"
    },
    {
      protocol         = "udp"
      destination_port = "50180"
      allow            = true
      description      = "SideroLink WireGuard"
    },
    {
      protocol    = "icmp"
      allow       = true
      description = "疎通確認とPath MTU Discovery"
    },
    {
      protocol         = "tcp"
      destination_port = "32768-61000"
      allow            = true
      description      = "戻り: 自分から出したTCPの応答"
    },
    {
      protocol         = "udp"
      destination_port = "32768-61000"
      allow            = true
      description      = "戻り: 自分から出したUDPの応答"
    },
    {
      protocol    = "fragment"
      allow       = true
      description = "フラグメントされたパケット"
    },
    {
      protocol    = "ip"
      allow       = false
      description = "上記以外は破棄"
    },
  ]
}
