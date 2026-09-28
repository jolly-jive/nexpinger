# ExPing Next (Elixir CUI版)

ExPing 後継プロジェクトの Elixir 実装。まずは CUI 版（1行1項目のストリーム出力型）のみ。

## 機能（現時点）

- YAML設定ファイルからホストと監視項目（Item）を読み込み
- Item ごとに独立した間隔（interval）でループ監視
- ICMP Ping（OSの `ping` コマンドを実行、特権不要）
- TCP Ping（`:gen_tcp.connect` で疎通とRTTを計測）
- 1行1項目のストリーム出力（成功=緑 OK / 失敗=赤 NG）
- 監視結果を stdout とログファイルの両方へ出力可能
- `--no-stdout` でコンソール表示を無効化可能
- `--help` でヘルプを表示可能
- 同一 IP サブネット上の監視対象では、近隣テーブルから MAC アドレスを表示

## セットアップ

```bash
mix deps.get
```

## 実行方法

### 1. mix経由で直接実行

```bash
mix run --no-halt -e 'ExPingNext.CLI.main(["config/hosts.yml"])'
```

### 1a. オプション付きで実行

```bash
mix run --no-halt -e 'ExPingNext.CLI.main(["--log-file", "/tmp/exping.log", "config/hosts.yml"])'
mix run --no-halt -e 'ExPingNext.CLI.main(["--no-stdout", "--log-file", "/tmp/exping.log", "config/hosts.yml"])'
mix run --no-halt -e 'ExPingNext.CLI.main(["--help"])'
```

### 2. escriptとしてビルドして実行

```bash
mix escript.build
./exping_next config/hosts.yml
./exping_next --log-file /tmp/exping.log config/hosts.yml
./exping_next --no-stdout --log-file /tmp/exping.log config/hosts.yml
./exping_next --help
```

## CLI オプション

- `--log-file PATH`: 監視結果を指定したファイルへ追記
- `--no-stdout`: コンソールへの出力を抑止
- `--help`: ヘルプを表示
- `config file`: 監視設定ファイルのパス（1つ以上必須。複数指定時はすべて読み込み）

`--log-file` を指定しない場合、ファイル出力は行いません。

例:

```bash
./exping_next --log-file ./monitor.log --no-stdout config/hosts.yml
```

この場合、ファイルへ記録される一方で標準出力には結果が表示されません。

## 設定ファイル

YAML 形式と `/etc/hosts` 形式を内容から自動判定します。hosts 形式では各有効行の IP アドレスと最初のホスト名を使って ICMP 監視を行います。追加の別名は同じホストを指すため個別の監視項目にはなりません。監視間隔とタイムアウトは Item の既定値（各1000ミリ秒）です。TCP 監視など詳細な設定には YAML 形式を使ってください。

### YAML (`config/hosts.yml`)

```yaml
hosts:
  - name: gateway
    address: 192.168.1.1
    items:
      - name: ping
        type: icmp
        interval: 1000

  - name: web-server
    address: example.com
    items:
      - name: https
        type: tcp
        port: 443
        interval: 3000
        timeout: 1000
      - name: http
        type: tcp
        port: 80
        interval: 5000
```

- ホストは `name` と `address` を持ち、`items` に1つ以上の監視項目を定義します
- Item は `name`、`type`（`icmp` または `tcp`）、`interval`（ミリ秒）、`timeout`（ミリ秒、省略時1000）を持ちます
- `port` は `type: tcp` の場合に必須です

### hosts 形式

```text
127.0.0.1 localhost localhost.localdomain
::1       ip6-localhost ip6-loopback
192.168.1.5 nas
```

## 出力例

```
2026-09-16 12:00:00.123 | gateway/ping             (192.168.1.1    ) 08:33:ed:8f:c1:f2 ICMP OK    1.23 ms
2026-09-16 12:00:01.456 | web-server/https:443      (example.com    )                   TCP  OK   45.67 ms
2026-09-16 12:00:02.789 | dns-server/ping           (192.168.1.10   )                   ICMP NG    timeout
```

同一 IP サブネット上で MAC アドレスを取得できた場合だけ表示し、取得できない場合も同じ幅の空白を確保します。ログファイルへは同じ形式で追記されます。`--no-stdout` を付けると、コンソール側には出力されず、ファイルのみに残ります。

## 今後実装したい項目（未着手）

- ARP/PING組み合わせ表示（同一サブネット判定含む4パターン）
- フルスクリーン表示型CUI
- GUI版
