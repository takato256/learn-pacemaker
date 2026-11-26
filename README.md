# Rocky Linux 9 / Podman で学ぶ Pacemaker の系切り替え

参加者ごとに2ノードのクラスタを割り当てます。Pacemaker が仮想IP（VIP）と Apache をまとめて管理し、同じURLにアクセスしたときの応答で稼働系を確認できます。1台の Rocky Linux 9 ホストで最大10組を作成できます。

閉域の専用ホストと信頼できる参加者を前提とします。参加者には担当コンテナ内の sudo 権限を与えます。コマンド例の `sudo bash labctl.sh` はホスト管理者が操作します。演習用に STONITH を無効にしています。

## 1. イメージを準備する（管理者）

インターネットまたは必要なリポジトリに接続できる、閉域ホストと同じCPUアーキテクチャの Rocky Linux 9 環境で実行します。

```bash
sudo bash setup-host.sh
sudo bash labctl.sh build
sudo podman save -o pacemaker-lab.tar localhost/pacemaker-lab:rocky9
```

閉域側にこのファイル群と `pacemaker-lab.tar` をコピーし、次を実行します。ホストに Podman が未導入の場合は、Rocky 9 のローカルリポジトリまたは事前導入済みホストを用意してください。

```bash
sudo bash setup-host.sh
sudo podman load -i pacemaker-lab.tar
```

Podman は rootful、Netavark、cgroup v2 を使用します。SSH 中継にはホスト標準の systemd を利用します。演習用 RPM はイメージに収録され、環境の作成時にイメージ取得や RPM の導入は発生しません。

## 2. 人数分を作る（管理者）

まず1人分をホスト内で試す場合は `sudo bash labctl.sh create` を実行します。参加者が別端末を使う場合は、人数と演習LAN側のホストIPv4を指定します。以下は2人分の例です。`192.168.56.10` は実際のホストIPに置き換えます。

```bash
sudo bash labctl.sh create 2 192.168.56.10
sudo bash labctl.sh check 1
sudo bash labctl.sh check 2
sudo bash labctl.sh isolation 1 2
sudo bash labctl.sh isolation 2 1
```

各参加者には、作成時に表示される担当環境のSSHコマンドとパスワードを伝えます。ユーザー名は `lab`、パスワードは環境ごとに自動発行され、同じ環境の2ノードで共通です。閉域LANのファイアウォールで担当端末から該当するTCPポートへの接続を許可します。待受IPの既定値はホスト内から接続するための `127.0.0.1` です。

| 環境 | node01 のSSHポート | node02 のSSHポート | VIP |
|---|---:|---:|---|
| lab01 | 22011 | 22012 | 10.200.0.4 |
| lab02 | 22021 | 22022 | 10.200.0.12 |

参加者端末が使う宛先IPはホストの1個です。内部には参加者ごとに `/29` のブリッジを1つ作り、ブリッジ、2ノード、VIPに計4アドレスを使います。全10組の範囲は `10.200.0.0〜10.200.0.79` です。既存LANやPodmanのネットワークとの重複を作成前に確認してください。メモリ上限は1ノード1 GiBです。まず少人数で同時切り替えを確認し、ホストに余裕があることを確認して人数を増やします。

## 3. SSHで接続して演習する（参加者）

```bash
ssh -p 22011 lab@192.168.56.10
ssh -p 22012 lab@192.168.56.10
```

コマンドは別々の端末で実行します。初回は管理者から共有されたSSHホスト鍵の指紋と照合します。接続後は [演習手順](EXERCISE.md) に進みます。

## 管理コマンド

```bash
sudo bash labctl.sh list
sudo bash labctl.sh status 1
sudo bash labctl.sh test 1
sudo bash labctl.sh add 3 192.168.56.10
sudo bash labctl.sh reset 1
sudo bash labctl.sh destroy 3
```

`test` は node01 が稼働系の状態から、切り替えと切り戻しを実行します。`reset` は指定環境のコンテナとデータを削除し、同じ待受IPで作り直します。パスワードとSSHホスト鍵は再発行されます。旧構成から移行する場合も、必要なデータを退避してから環境を作り直してください。

ホスト再起動後は `sudo podman start lab01-node01 lab01-node02`、`sudo bash labctl.sh access 1`、`sudo bash labctl.sh check 1` の順で復旧します。他の環境も番号を読み替えます。

SSH接続やクラスタ起動に失敗した場合は、状態とログを確認します。

```bash
sudo podman ps -a
sudo journalctl -u pm-lab01-node01-ssh.socket -u pm-lab01-node01-ssh.service
sudo podman exec lab01-node01 journalctl -u sshd -u corosync -u pacemaker --no-pager -n 50
sudo podman exec lab01-node01 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```
