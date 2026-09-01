# Omni Infrastructure Provider for Sakura Cloud

Omniのauto-provision `MachineClass`を、さくらのクラウドのServer、SSD、cidata
CD-ROMへ変換するdynamic infrastructure provider。

## Provisioning flow

1. Machine Classのexternal/internal IP poolから未使用の組を選ぶ
2. OmniのSideroLink join configと静的ネットワークpatchをcidata ISOへ格納する
3. 事前登録済みTalos nocloud raw archiveからSSDを複製する
4. eth0をルータ+スイッチ、eth1を内部vSwitchへ接続してServerを起動する
5. `providerID: sakura://<server-id>` patchをOmniへ登録する

deprovisionはServerを停止・削除してから、SSDとcidata CD-ROMを削除する。providerが
作るリソースには `omni-infra-provider=sakura` と `omni-machine=<request>` のtagを付ける。

## Provider registration

OmniのSettings > Infra ProvidersでID `sakura` のproviderを作り、表示されたendpointと
provider keyを保存する。通常のservice account keyではなく、infra provider keyが必要。

`config.example.yaml`を`config.yaml`へコピーする。`bootstrap.enabled: true` の場合、
provider起動時にInternet、内部vSwitch、packet filterを名前で冪等作成し、IP poolも
サブネットから自動計算する。Talos archiveは既存 `archive_id` を指定するか、
`source_archive_id` を指定すると複製する。このファイルはsecretではないが、環境固有のためGitへcommitしない。

providerを動かすホストには次の環境変数を渡す。

```dotenv
OMNI_ENDPOINT=https://<omni-endpoint>
OMNI_SERVICE_ACCOUNT_KEY=<infra-provider-key>
SAKURACLOUD_ACCESS_TOKEN=<token>
SAKURACLOUD_ACCESS_TOKEN_SECRET=<secret>
SAKURACLOUD_ZONE=tk1b
```

## Machine Class example

IP poolはこのprovider専用の範囲にする。既存Terraformノード、API/Ingress VIP、bastion、
Omni VMと重複させない。control planeとworkerでpacket filterを分ける場合はMachine Classも
分ける。

```yaml
apiVersion: infrastructure.omni.siderolabs.io/v1alpha1
kind: MachineClass
metadata:
  name: sakura-dev-worker
spec:
  type: auto-provision
  provider: sakura
  config:
    zone: tk1b
    archive_id: "<sakura_archive.talos ID>"
    cpu: 6
    memory_gib: 12
    disk_gib: 40
    data_disk_gib: 20
    external_switch_id: "<external vSwitch ID>"
    external_ip_pool:
      - 203.0.113.110
      - 203.0.113.111
    external_gateway: 203.0.113.97
    external_netmask: 27
    packet_filter_id: "<worker packet filter ID>"
    internal_switch_id: "<internal vSwitch ID>"
    internal_ip_pool:
      - 192.168.100.111
      - 192.168.100.112
    internal_netmask: 24
    nameservers:
      - 210.188.224.10
      - 210.188.224.11
```

`archive_id`のTalos版・schematicはOmniが要求する初期Talos版と一致させる。現段階では
provider自身によるImage Factory imageのarchive uploadは行わない。

## Development

```bash
cp omni/infra-provider-sakura/config.example.yaml omni/infra-provider-sakura/config.yaml
# config.yamlを編集
task test-omni-infra-provider
docker build -t omni-infra-provider-sakura:dev omni/infra-provider-sakura
```
