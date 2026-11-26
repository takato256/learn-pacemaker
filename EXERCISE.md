# Pacemaker の切り替えと切り戻し

以下は lab01 の例です。管理者から受け取った担当環境のノード名、SSHポート、VIPに読み替えます。node01 と node02 に別々の端末から接続しておきます。

## 1. 切り替え前の状態を見る

node01 で実行します。

```bash
printf '%s\n' "$HOSTNAME"
sudo pcs status --full
sudo pcs resource config
ip -4 addr
```

2ノードが Online で、`web-group` の `vip` と `web` が node01 で Started になっていることを確認します。

## 2. VIPの応答を監視する

node02 の端末で次を実行します。切り替え中の応答と時刻を記録します。終了は Ctrl+C です。

```bash
vip=10.200.0.4
while true; do
  printf '%s ' "$(date +%T)"
  curl --noproxy '*' -fsS --max-time 2 "http://$vip/" 2>/dev/null || echo 'HTTP応答なし'
  sleep 1
done
```

応答の `lab01-node01` は、Apache が node01 で動いていることを示します。node02 が VIP を引き継いだ後、この監視は node02 自身の応答を読みます。

## 3. node02 に切り替える

node01 の端末で実行します。

```bash
sudo pcs node standby lab01-node01
sudo pcs status --full
```

HTTP応答が `lab01-node02` に変わるまで待ちます。node01 の VIP が消え、node02 に VIP と Apache が移ったことを確認します。コマンド直後に状態が移行中なら `pcs status` を再実行します。

## 4. node01 に切り戻す

node01 の端末で実行します。

```bash
sudo pcs node unstandby lab01-node01
sudo pcs status --full
```

node01 が Online に戻り、リソースが node02 にとどまることを確認します。稼働中のノードを優先する `resource-stickiness` の効果です。

```bash
sudo pcs node standby lab01-node02
```

HTTP応答が `lab01-node01` に戻ったら、次を実行します。

```bash
sudo pcs node unstandby lab01-node02
sudo pcs status --full
sudo journalctl -u pacemaker --since '10 min ago' --no-pager
```

両ノードが Online で、node01 に VIP と Apache がある状態が演習の終了条件です。

## 5. サービス障害時の違いを観察する（任意）

演習終了時の状態から、node01 で `sudo systemctl stop httpd` を実行します。HTTP応答、`sudo pcs status --full`、Pacemaker のログから、監視が停止を検知してどこでサービスを復旧させたかを確認します。同じノードで再起動する場合もあります。失敗履歴を消して再確認する場合は `sudo pcs resource cleanup web` を実行します。
