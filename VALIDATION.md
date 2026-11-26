# 検証記録

実施済み（生成環境はDebian / Podman未導入）:
- `bash -n setup-host.sh`、`bash -n labctl.sh`: 成功
- `labctl.sh --help`: 成功
- Podmanの応答を模擬する一時モック: lab01作成、check、node01→node02→node01のtest、重複lab拒否、範囲外LAB拒否が成功。
- lab02を含めた一連のモック試験は実行環境のタイムアウトで完了せず。鍵設定、proxy、隔離試験、10人拡張は実機未確認。

モックは処理分岐・期待値比較の検査であり、実Podmanのコマンド互換性・パッケージ導入・権限・SSH・ネットワーク・Pacemakerの実動作を保証しない。実機でREADMEの受入試験を行うこと。
