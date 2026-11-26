# 参加者向け演習手順 — Pacemakerの系切り替え

lab01の例。lab02の場合、ホスト名の `lab01` を `lab02`、IPの `10.200.1` を `10.200.2` に読み替える。管理者の指示した方法でnode01・node02・clientに接続する。ノードで実行する管理コマンドは `sudo` を付ける。管理者が `podman exec` で入った場合は既にroot。

## 1. 初期状態の確認 (node01)

```bash
sudo pcs status --full
sudo pcs resource config
sudo pcs constraint config
sudo pcs property config
sudo corosync-quorumtool -s
ip -4 addr
systemctl is-active httpd
```

期待値: 2ノードがOnline、quorumあり、`web-group` の `vip` と `web` がnode01で稼働。node02は待機側だが `pcs node standby` 状態ではない。

## 2. VIP監視 (clientで別ターミナル)

```bash
while true; do
  printf '%s ' "$(date '+%H:%M:%S')"
  curl --noproxy '*' -fsS --max-time 2 http://10.200.1.100/ || echo 'HTTP unavailable'
  sleep 1
done
```

初期応答は `lab01-node01`。Ctrl+Cで終了する。

## 3. 計画系切替 (node01)

```bash
sudo pcs node standby lab01-node01
sudo pcs status --full
```

確認: node01がStandby、VIPとhttpdがnode02へ移動。client応答が `lab01-node02` に変化する。一時的な通信断はあり得る。両ノードで `ip -4 addr` と `systemctl is-active httpd` を確認し、VIPが二重になっていないことを確かめる。

## 4. 切戻し (node02)

```bash
sudo pcs node unstandby lab01-node01
sudo pcs status --full
```

node01が再び配置可能になるが、リソーススティッキネスにより通常はnode02上に残る。

```bash
sudo pcs node standby lab01-node02
sudo pcs status --full
```

clientが `lab01-node01` へ戻るまで確認し、その後node01で次を実行。

```bash
sudo pcs node unstandby lab01-node02
sudo pcs status --full
```

両ノードOnline、node01でweb-group稼働が終了条件。

## 5. 障害検知 (任意、管理者承認のもと)

初期状態でnode01のhttpdを停止し、clientとログで復旧を観察。

```bash
sudo systemctl stop httpd
sudo pcs status --full
sudo journalctl -u pacemaker --since '5 min ago' --no-pager
```

サービス停止を検知して同じノードで再起動する場合がある。停止=必ず系切替ではない。失敗回数やmigration-thresholdなどで挙動は変わる。観察後、管理者と状態を確認し、必要な場合のみ `sudo pcs resource cleanup web` を実行。強制フェンシングやCorosync通信遮断、共有ストレージの検証は今回のPoCの対象外。

## 6. 記録

| 項目 | 観察結果 |
|---|---|
| 切替前Active / VIP | |
| 切替操作コマンド | |
| 切替中HTTPエラー時間（観測間隔1秒以上） | |
| 切替後Active / VIP | |
| standby解除後のActive | |
| 切戻し後のActive | |
| httpd停止時の復旧先 | |
| Pacemakerの主なログ | |

考察: standbyと停止の違い、VIPとサービスのグループ化、リソーススティッキネス、quorum、実運用でSTONITHが必要な理由を説明できること。
