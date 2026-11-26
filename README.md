# Pacemaker / Podman 系切り替え Sandbox (PoC)

対象: Rocky Linux 9 VM、rootful Podman / Netavark / cgroup v2。2人分を構築し、最大10人に拡張できる設計。各labは2ノードHAクラスタと確認用クライアントの3コンテナで構成する。

**検証状況:** スクリプトの静的検査・モック試験のみ。Rocky Linux VM上でのイメージビルド、クラスタ起動、VIP切替、SSH、ネットワーク隔離の実動作は未検証。初回は専用VMで管理者が1人分から試すこと。10人への公開前に全項目を検証する。

**安全上の前提:** 信頼できる社内・検証参加者向け。rootfulコンテナ内にsudo権限を与え、ノードにはNET_ADMIN等を追加するため、悪意ある利用者向けの強い隔離境界ではない。ホストのカーネルを共有する。特権コンテナ、ホストPID/ネットワーク共有、ホストディレクトリやPodmanソケットのマウントは使わない。SELinuxは有効のまま。外部公開せず、専用VM・閉域網を使用。STONITHは学習用に無効化するため、通信分断・共有ストレージ・実機フェンシングを安全に検証できる環境ではない。

## 1. 構成

| 項目 | 2人PoC | 10人 |
|---|---:|---:|
| vCPU (目安) | 4 | 8〜16 |
| RAM (目安) | 8 GiB | 16〜32 GiB |
| SSD (目安) | 50 GB | 100 GB |
| クラスタノード | 4 | 20 |
| client | 2 | 10 |

ノード制限: RAM 1 GiB、CPU 1、PID 512。client制限: RAM 512 MiB、CPU 0.5、PID 256。10人分のメモリ上限合計は25 GiBなので、全コンテナが上限まで使う前提なら32 GiB以上を推奨する。CPU制限は予約ではない。実測して調整する。

| 用途 | lab01 | lab02 |
|---|---|---|
| bridge | lab01-net | lab02-net |
| subnet | 10.200.1.0/24 | 10.200.2.0/24 |
| host側bridge IP | 10.200.1.1 | 10.200.2.1 |
| node01 | 10.200.1.11 | 10.200.2.11 |
| node02 | 10.200.1.12 | 10.200.2.12 |
| client | 10.200.1.20 | 10.200.2.20 |
| VIP | 10.200.1.100 | 10.200.2.100 |
| cluster | lab01-cluster | lab02-cluster |
| SSH proxy (任意) | 22011/22012/22013 | 22021/22022/22023 |

各コンテナの名前とホスト名は `lab01-node01` のように一意。各labは `--internal --opt isolate=true` のbridgeを使用し、コンテナ間は固定IPと `/etc/hosts` を使用する。デフォルトルートや外部NATは不要。Podmanのpodは使わない（通常pod内はネットワーク名前空間を共有するため）。

## 2. 構築 (管理者)

専用Rocky 9 VMを用意し、コンソールまたはSSHで接続。ホストはイメージ・RPMの取得にインターネット接続が必要。`10.200.1.0/24`〜`10.200.10.0/24` が既存のLAN/VPN/Podmanネットワークと重複しないことを先に `ip route` と `sudo podman network ls` / `inspect` で確認する。

```bash
unzip pacemaker-podman-lab.zip
cd pacemaker-podman-lab
chmod +x *.sh
sudo ./setup-host.sh
sudo ./labctl.sh build
sudo ./labctl.sh create 2
sudo ./labctl.sh list
```

初回は `create 1` で切替試験し、`add 2` でもよい。`create 2` は既存labを上書きしない。途中で失敗した場合はログを採取してから対象labのみ `reset` する。エラー時に環境は自動削除されない。構築・削除・リセット操作は同一VMで並行実行しない。異なるlabの演習・チェックは並行実行可能。

イメージにsystemd、pcsd、Pacemaker、Corosync、OCF resource agents、httpd、SSHを導入。起動時に各ノードの `hacluster` パスワードをlab単位でランダム生成し、pcs認証を設定する。`httpd` はOS自動起動ではなくPacemakerが管理。VIPとWebを `web-group` にまとめ、初期状態はnode01で稼働、node02はオンラインかつリソースなし（pcsのstandbyフラグは解除済み）。

## 3. PoCの受入試験 (管理者)

```bash
sudo ./labctl.sh check 1
sudo ./labctl.sh check 2
sudo ./labctl.sh isolation 1 2
sudo ./labctl.sh isolation 2 1
sudo ./labctl.sh test 1
sudo ./labctl.sh check 2
sudo ./labctl.sh test 2
sudo ./labctl.sh check 1
```

`check` は2ノードmembership、quorum、HTTP応答、VIPが1ノードのみで応答ノードと一致することを検査。`test` は両系の手動往復切替を自動実行し、途中失敗時はその状態を残す。`isolation` は通常状態のclientから別labのpcsd/VIPへのTCP接続を試す。これらは悪意あるroot利用者からの隔離を保証する試験ではない。

同時操作の追加試験: 2端末で `sudo ./labctl.sh test 1` と `sudo ./labctl.sh test 2` を別々に実行する（同じlabの管理操作は並行実行しない）。この2コマンドは異なるlabのクラスタにのみ作用する。`podman stats --no-stream` でリソースを測定。`test` 実行前はnode01をActiveに戻しておく。

| 確認項目 | 合格条件 |
|---|---|
| 初期状態 | 各labでnode01がVIPを持つ、node02はOnline |
| 手動切替 | node02にVIP/httpdが移動しHTTP応答が変わる |
| 切戻し | node01に戻る、両ノードOnline |
| 独立性 | 別labのActive、サービスに意図しない変化がない |
| ネットワーク | client間の別lab TCP到達不可、外部default routeなし |
| SSH | 別lab鍵で認証失敗、自lab鍵で成功、ホストの管理権限なし |
| リセット | 対象labのみ再作成、別labに影響なし |
| 同時実行 | 2lab同時切替が成功、OOMやCorosync token timeoutなし |

実測結果は手元で記録し、10人拡張前に判定する。

## 4. 接続方法

### A. 管理者のPoC用 (すぐ試せる)

```bash
sudo ./labctl.sh shell 1 node01
sudo ./labctl.sh shell 1 node02
sudo ./labctl.sh shell 1 client
```

別ターミナルでそれぞれ起動。`podman exec` はホスト管理者向けであり、参加者にホストsudoやPodman権限を与えない。

### B. 参加者SSH (公開鍵認証)

参加者各自が自端末で `ssh-keygen -t ed25519` を実行し、公開鍵 `.pub` のみを管理者へ渡す。秘密鍵は渡さない。参加者ごとに異なる鍵を使用する。

管理者:

```bash
sudo ./labctl.sh key 1 /path/to/person01.pub
sudo ./labctl.sh key 2 /path/to/person02.pub
# ホストからの確認（内部IPに直接接続できる場合）
# ssh lab@10.200.1.11
```

各labの3台で `lab` ユーザーのauthorized_keysを設定し、SSHを起動する（鍵設定は上書き）。ノード2台のlabユーザーは `sudo` 可能、clientは一般ユーザー。root SSH・パスワード認証・SSH転送は無効化。SSHホスト鍵は各コンテナで生成し、公開鍵指紋を管理者が参加者に伝える。例: `sudo podman exec lab01-node01 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`。

外部端末から直接利用するには、任意のTCPプロキシをホスト上で起動する。初期状態では無効。`--internal` bridgeではPodmanのポート公開に頼らず、hostから内部IPに接続するsocatを使う。

```bash
sudo dnf install -y socat
# まずホストloopbackのみで検証
sudo ./labctl.sh proxy 1
sudo ./labctl.sh proxy 2
# VM上で自分の鍵を持つ場合、ssh -p 22011 lab@127.0.0.1 で検証
# 外部接続は閉域のVM IPを指定する。以下は例、実IPに変更すること。
sudo ./labctl.sh unproxy 1
sudo ./labctl.sh unproxy 2
sudo ./labctl.sh proxy 1 192.168.56.10
sudo ./labctl.sh proxy 2 192.168.56.10
```

VMのfirewalld/上位FWで、許可済み参加者の送信元IPから対応する3ポートだけを許可する。全インターネットへの公開禁止。firewall設定は環境依存のため自動変更しない。管理者が別labポートとホストサービスへのアクセス制限を確認する。proxyはsystemd transient service（nobody）なのでVM再起動で再設定が必要。`proxy` 再実行前に `unproxy` する。

参加者01 (VM IPは例):

```bash
ssh -p 22011 lab@192.168.56.10  # node01
ssh -p 22012 lab@192.168.56.10  # node02
ssh -p 22013 lab@192.168.56.10  # client
```

参加者02は22021/22022/22023。初回SSH接続時は管理者から入手したホスト鍵の指紋と照合する。reset後はホスト鍵も変わるので再照合する。SSH host key checkingを無効化しない。

## 5. 演習・運用

詳細は `EXERCISE.md`。初期化は次のとおり。resetは指定labの書き込みデータ・公開鍵・ホスト鍵・proxyを削除する。

```bash
sudo ./labctl.sh reset 1
# 必要なら key と proxy を再実行
sudo ./labctl.sh destroy 1  # 完全削除
sudo ./labctl.sh destroy 2
```

10人に拡張 (既存2人分を維持):

```bash
for n in {3..10}; do sudo ./labctl.sh add "$n" || break; done
sudo ./labctl.sh list
```

新規VMで最初から10人なら `sudo ./labctl.sh create 10`。IPは10.200.N.0/24、SSHポートは22000+N×10+1/2/3。VMの再起動後、コンテナが自動起動する設定は含まれない。管理者が `podman start` で各labの3台を起動し、`check` を再実行する（クラスタサービスはenable済み）。

## 6. トラブルシューティング

```bash
sudo podman info --format '{{.Host.NetworkBackend}} {{.Host.CgroupVersion}}'
sudo podman ps -a
sudo podman logs lab01-node01
sudo podman exec lab01-node01 systemctl --failed
sudo podman exec lab01-node01 journalctl -b -u pcsd -u corosync -u pacemaker --no-pager
sudo podman exec lab01-node01 pcs status --full
sudo podman exec lab01-node01 ip -4 addr
sudo podman network inspect lab01-net
sudo podman stats --no-stream
sudo ausearch -m AVC -ts recent  # auditが利用可能な場合
```

- systemdが動かない: cgroup v2、crun/runc、SELinux AVCを確認。公式Podmanの説明に沿い、必要と判断した場合だけ専用VMで `sudo setsebool -P container_manage_cgroup on` を設定する（ホスト全体に影響するので事前に値を記録）。SELinuxの無効化はしない。
- Corosync: `journalctl -u corosync` で realtime scheduling、memlock、knet、名前解決を確認。SYS_NICE/IPC_LOCK/SYS_RESOURCEを追加済み。CPU不足・OOMも確認する。
- VIP: `pcs resource config vip`、`ip addr`、`pcs resource failures`、ログを確認。NET_ADMINが必要。IPaddr2はARP更新を行うためbridge上のARP到達を確認する。
- pcs認証: `/etc/hosts`、pcsdの2224/TCP、サービス状態を確認。パスワードを出力しない。
- SSH: `journalctl -u sshd` と `sshd -T`、公開鍵パーミッションを確認。rootfulコンテナ内のPAM/SELinux差異で認証失敗する場合がある。
- proxy: `sudo journalctl -u pm-lab01-node01-ssh`、`ss -lntp`、hostからの内部IP接続、firewallを確認。
- Capabilities/SELinuxの制約で動かない場合: 原因を切り分け、安易な `--privileged`、`--security-opt label=disable`、ホスト名前空間の共有をしない。必要なら演習用ノードをVMへ切り替える。

参考:
- Rocky Linux HA: https://docs.rockylinux.org/9/ja/books/web_services/07-high-availability/
- Podman run: https://docs.podman.io/en/stable/markdown/podman-run.1.html
- Podman network: https://docs.podman.io/en/stable/markdown/podman-network-create.1.html
- RHEL 9 HA: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_and_managing_high_availability_clusters/index
