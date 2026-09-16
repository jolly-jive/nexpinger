# ExPing Next (Elixir CUI版)

ExPing 後継プロジェクトの Elixir 実装。まずは CUI 版（1行1項目のストリーム出力型）のみ。

## 機能（現時点）

- YAML設定ファイルからホスト一覧を読み込み
- ホストごとに独立した間隔（interval）でループ監視
- ICMP Ping（OSの `ping` コマンドを実行、特権不要）
- TCP Ping（`:gen_tcp.connect` で疎通とRTTを計測）
- 1行1項目のストリーム出力（成功=緑 OK / 失敗=赤 NG）

## セットアップ

```bash
mix deps.get
```

## 実行方法

### 1. mix経由で直接実行

```bash
mix run --no-halt -e 'ExPingNext.CLI.main(["config/hosts.yml"])'
```

### 2. escriptとしてビルドして実行

```bash
mix escript.build
./exping_next config/hosts.yml
```

## 設定ファイル (`config/hosts.yml`)

```yaml
hosts:
  - name: gateway
    address: 192.168.1.1
    type: icmp
    interval: 1000

  - name: web-service
    address: example.com
    type: tcp
    port: 443
    interval: 3000
    timeout: 1000
```

- `type`: `icmp` または `tcp`
- `interval`: 監視間隔（ミリ秒）
- `timeout`: 応答待ちタイムアウト（ミリ秒、省略時1000）
- `port`: `type: tcp` の場合は必須

## 出力例

```
2026-09-16 12:00:00.123 | gateway         (192.168.1.1    ) ICMP OK    1.23 ms
2026-09-16 12:00:01.456 | web-service     (example.com    ) TCP  OK   45.67 ms
2026-09-16 12:00:02.789 | dns-server      (192.168.1.10   ) ICMP NG    timeout
```

## 今後実装したい項目（未着手）

- ARP/PING組み合わせ表示（同一サブネット判定含む4パターン）
- フルスクリーン表示型CUI
- GUI版
