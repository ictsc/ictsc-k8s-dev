# Talos の nocloud ディスクイメージ (raw) をアーカイブとして登録する。
# 実ファイルは `task fetch-talos-image` で talos/image/ 配下にダウンロードしておく。
resource "sakura_archive" "talos" {
  name         = "${local.name}-talos-${var.talos_version}"
  tags         = [var.prefix, local.env, "talos"]
  size         = 20
  archive_file = "${path.module}/../talos/image/nocloud-amd64-${var.talos_version}.raw"

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

# ノードごとの machine config を cloud-init NoCloud (cidata) の ISO として渡す。
# Talos の nocloud プラットフォームはラベル cidata のブロックデバイスから
# user-data / meta-data を読む。ISO は `task talos-config` が生成する。
#
# NOTE: Talos は初回起動時に machine config を STATE パーティションへ保存するため、
#       この CD-ROM はあくまで「初回ブートストラップ用」。
#       構築後の設定変更は `talosctl apply-config` で行うこと。
#
# NOTE: sakura_cdrom は iso_image_file の *中身* が変わっても差分を検知しない
#       (hash 属性は computed で、plan の比較に使われない)。
#       ISO を焼き直しても `No changes` になり、古い config を載せ続けてしまうため、
#       ファイルの md5 を terraform_data に持たせて replace_triggered_by で強制的に
#       貼り直す。
resource "terraform_data" "cidata_hash" {
  for_each = { for n in local.talos_input.nodes : n.hostname => n }

  input = filemd5("${path.module}/../talos/build/${local.name}/iso/${each.key}.iso")
}

resource "sakura_cdrom" "node_config" {
  for_each = { for n in local.talos_input.nodes : n.hostname => n }

  name           = "${each.key}-cidata"
  tags           = [var.prefix, local.env, "talos", "cidata"]
  size           = 5
  iso_image_file = "${path.module}/../talos/build/${local.name}/iso/${each.key}.iso"

  timeouts = {
    create = "1h"
    update = "1h"
    delete = "1h"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.cidata_hash[each.key]]
  }
}
