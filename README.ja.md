# NexPinger (Elixir CUI版)

[English](README.md) | 日本語

複数のホストを ICMP / TCP / UDP で継続監視する、Elixir 製の CUI ツール。TTY では「Ping結果」と「Ping統計」を切り替えて表示できます。

複数のアドレスへ ping を実行する Windows 用ツール [ExPing](https://www.woodybells.com/exping.html) に触発されて作りました。

## 機能（現時点）

- YAML設定ファイルからホストと監視項目（Item）を読み込み
- Item ごとに独立した間隔（interval）でループ監視
- ICMP Ping（特権不要）
  - Linux: ICMP datagram ソケットで直接送信。`net.ipv4.ping_group_range` に実行ユーザーのグループが含まれていない場合は `LC_ALL=C` を付けた `ping` コマンドにフォールバック
    （有効にする例: `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"`）
  - Windows: `IcmpSendEcho2` / `Icmp6SendEcho2` を呼ぶ補助プログラム（`priv/bin/icmp_helper.exe`）で送信。補助プログラムが無い・実行できない場合は `ping.exe` にフォールバック（表示言語に依存しない方法で結果を読み取る）
  - その他の OS: OS の `ping` コマンドを実行
  - 起動時に使用する方法（とフォールバックの理由）を `ICMP: ...` として表示
- TCP Ping（`:gen_tcp.connect` で疎通とRTTを計測）
- UDP Ping（DNS / NTP / QUIC の要求を送り、応答の有無を確認。[UDP 監視](#udp-監視)を参照）
- 1行1項目のストリーム出力（成功=緑 OK / 失敗=赤 NG）
- TTY で `Tab` を押すと Ping結果の追記表示と Ping統計を切り替え
- TTY で `Q` を押すと終了（`Ctrl+C` でも終了可能）
- Ping統計で Item ごとの実施回数、失敗回数、失敗率、最新 RTT、平均、P95、P99を表示
- RTT の集計窓は `--stats-window` で指定（既定値1000試行）
- 監視結果を stdout とログファイルの両方へ出力可能
- ログファイルの形式を text / TSV / JSON Lines から選択可能（`--log-format`）
- `--no-stdout` でコンソール表示を無効化可能
- `--help` でヘルプを表示可能
- 同一 IP サブネット上の監視対象では、近隣テーブルから MAC アドレスを表示

## ダウンロード

ビルド済みのバイナリは [GitHub Releases](https://github.com/jolly-jive/nexpinger/releases) にあります。

- `nexpinger`: escript。Erlang/OTP 27 以降が必要。escript には `icmp_helper.exe` を同梱できないため、Windows では ICMP に `ping.exe` を使う
- `nexpinger.exe`: Windows 用の単体実行ファイル（Burrito）。Erlang は不要だが、Microsoft Visual C++ ランタイムが必要。初回起動時に `%APPDATA%\.burrito` 配下へ展開される

## セットアップ

```bash
mix deps.get
```

## 実行方法

### 1. mix経由で直接実行

```bash
mix run --no-halt -e 'NexPinger.CLI.main(["config/hosts.yml"])'
```

### 1a. オプション付きで実行

```bash
mix run --no-halt -e 'NexPinger.CLI.main(["--log-file", "/tmp/nexpinger.log", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--no-stdout", "--log-file", "/tmp/nexpinger.log", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--log-file", "/tmp/nexpinger.tsv", "--log-format", "tsv", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--stats-window", "500", "--stats-width", "120", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--help"])'
```

### 2. escriptとしてビルドして実行

```bash
mix escript.build
./nexpinger config/hosts.yml
./nexpinger --log-file /tmp/nexpinger.log config/hosts.yml
./nexpinger --no-stdout --log-file /tmp/nexpinger.log config/hosts.yml
./nexpinger --log-file /tmp/nexpinger.jsonl --log-format jsonl config/hosts.yml
./nexpinger --stats-window 500 --stats-width 120 config/hosts.yml
./nexpinger --help
```

escript には `priv/bin/icmp_helper.exe` を同梱できないため、Windows では `ping.exe` を使う。

### 3. Burrito で単体実行ファイルとしてビルドして実行

Burrito は Windows 上でのビルドに対応していないため、WSL でビルドする。
WSL では Zig のキャッシュを Linux 側に置かないとビルドに失敗する。

Windows 用の補助プログラム `priv/bin/icmp_helper.exe`（ソースは `c_src/icmp_helper.c`）は、
`mix compile` の際に `zig cc` でクロスコンパイルされ、リリースに同梱される。
`zig` が無い環境ではビルドを省略する（その場合 Windows では `ping.exe` を使う）。

```bash
ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache-nexpinger MIX_ENV=prod BURRITO_TARGET=windows mix release
```

```powershell
.\burrito_out\nexpinger_windows.exe --help
.\burrito_out\nexpinger_windows.exe config\hosts.yml
```

## CLI オプション

- `--log-file PATH`: 監視結果を指定したファイルへ追記
- `--log-format FORMAT`: ログファイルの形式（`text`（既定）/ `tsv` / `jsonl`）。`--log-file` と併せて指定する（単独指定はエラー）
- `--no-stdout`: コンソールへの出力を抑止
- `--stats-window N`: 平均・P95・P99 を計算する直近試行数（既定値1000、1以上）
- `--stats-width N`: 統計画面の幅（80または120桁、省略時は端末幅から選択）
- `--ping-command`: ICMP ソケット（Linux）や `icmp_helper.exe`（Windows）を使わず、常に OS の `ping` コマンドで ICMP 監視を行う
- `--help`: ヘルプを表示
- `config file`: 監視設定ファイルのパス（1つ以上必須。複数指定時はすべて読み込み）

`--log-file` を指定しない場合、ファイル出力は行いません。

TTY では `Tab` で Ping結果と Ping統計を切り替え、統計画面では上下キーまたは `j`/`k` で一覧をスクロールし、`Q` で終了します。統計は Host/Item ごとに表示し、実施回数・失敗回数・失敗率は起動中の累計です。平均・P95・P99 は直近 `N` 回の試行に含まれる成功 RTT のみで計算し、失敗試行は RTT 統計から除外します。最新欄は成功時に `OK <RTT>`、失敗時に `NG` と表示します。単位は画面上部に `RTT: ms` と表示します。失敗時のベル通知はどちらの画面でも行われます。TTY が使えない場合は従来の追記出力になります。

統計のパーセンタイルは nearest-rank 方式で計算します。RTT サンプルがない場合は `-` を表示します。

例:

```bash
./nexpinger --log-file ./monitor.log --no-stdout config/hosts.yml
```

この場合、ファイルへ記録される一方で標準出力には結果が表示されません。

## 設定ファイル

YAML 形式と `/etc/hosts` 形式を内容から自動判定します。hosts 形式では各有効行の IP アドレスと最初のホスト名を使って ICMP 監視を行います。追加の別名は同じホストを指すため個別の監視項目にはなりません。監視間隔とタイムアウトは Item の既定値（各1000ミリ秒）です。TCP / UDP 監視など詳細な設定には YAML 形式を使ってください。

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

  - name: dns-server
    address: 192.168.1.10
    items:
      - name: dns
        type: udp
        service: dns
        interval: 2000
      - name: ntp
        type: udp
        service: ntp
        interval: 10000
```

- ホストは `name` と `address` を持ち、`items` に1つ以上の監視項目を定義します
- Item は `name`、`type`（`icmp`、`tcp` または `udp`）、`interval`（ミリ秒）、`timeout`（ミリ秒、省略時1000）を持ちます
- `port` は `type: tcp` の場合に必須です
- `service`（`dns`、`ntp` または `quic`）は `type: udp` の場合に必須です。`port` を省略するとサービスの標準ポート（dns: 53、ntp: 123、quic: 443）を使います

### UDP 監視

UDP 監視では、サービスが応答する要求を送り、**応答の有無のみを判定します。応答の内容は検査しません。** 目的はネットワーク的な到達性の確認なので、DNS の NXDOMAIN や REFUSED、NTP の Kiss-o'-Death、形式の崩れた応答も OK として扱います。

| `service` | 送信内容 |
|---|---|
| `dns` | `. SOA` の問い合わせ。RD=0（norec）、EDNS なし |
| `ntp` | NTPv4 クライアント要求（mode 3）、48 バイト |
| `quic` | 予約済みの未対応バージョン（`0x1a2a3a4a`）を持つ Long Header Initial。1200 バイトまで埋める。サーバは Version Negotiation を返す |

- RTT は要求の送信から最初の応答までの時間です。RD=0 のため、DNS フルリゾルバは再帰問い合わせをせずキャッシュから応答（または拒否）し、RTT に再帰の時間は含まれません
- `timeout` までに応答がなければ NG（`timeout`）です
- ICMP Port Unreachable は UDP の応答ではないため NG（`port unreachable`）とします。TCP で RST を NG とするのと同じ扱いです。対象ホスト自身ではなくファイアウォール（iptables の `REJECT` など）が返すこともあります
- 公開 NTP サーバの多くは問い合わせ頻度を制限しており、頻繁に問い合わせると Kiss-o'-Death を返したり要求を破棄したりします。そのため NTP の Item の `interval` は省略時 8000 ミリ秒とし、8000 ミリ秒未満を指定した場合は起動時に警告を表示します。自分で管理していないサーバには 8000 ミリ秒以上を指定してください

### hosts 形式

```text
127.0.0.1 localhost localhost.localdomain
::1       ip6-localhost ip6-loopback
192.168.1.5 nas
```

## 出力例

```
2026-09-16 12:00:00.123 | gateway/ping             (192.168.1.1    ) 00:00:5e:00:53:01 ICMP OK    1.23 ms
2026-09-16 12:00:01.456 | web-server/https:443      (example.com    )                   TCP  OK   45.67 ms
2026-09-16 12:00:02.789 | dns-server/ping           (192.168.1.10   )                   ICMP NG    timeout
2026-09-16 12:00:03.012 | dns-server/dns:53         (192.168.1.10   )                   UDP  OK    2.34 ms
```

時刻は画面・ファイルとも実行環境のローカル時刻です。同一 IP サブネット上で MAC アドレスを取得できた場合だけ表示し、取得できない場合も同じ幅の空白を確保します。`--log-format text`（既定）ではログファイルへも同じ形式で追記されます。`--no-stdout` を付けると、コンソール側には出力されず、ファイルのみに残ります。

### ログファイル形式

`--log-format tsv` / `jsonl` では、Excel などで解析しやすいよう整形や単位を付けない生データを出力します。項目は次の順です。

| 項目 | 内容 |
|---|---|
| `timestamp` | 計測時刻（ローカル時刻、`2026-09-30 12:00:00.123` 形式） |
| `host` | ホスト名 |
| `address` | アドレス |
| `mac` | MAC アドレス（取得できない場合は欠損） |
| `item` | Item 名 |
| `type` | `icmp` / `tcp` / `udp` |
| `port` | ポート番号（ICMP では欠損） |
| `status` | `ok` / `ng` |
| `rtt_ms` | RTT（ミリ秒、丸めなし。NG では欠損） |
| `error` | 失敗理由（OK では欠損） |

- **TSV**: タブ区切り。ファイルが空のときだけ先頭にヘッダ行を出力します。欠損値は空文字です。値に含まれるタブ・改行は空白に置き換えます
- **JSON Lines**: 1行に1オブジェクト。欠損値は `null`、`port` と `rtt_ms` は数値です

既存ファイルへは形式を確認せずに追記するため、異なる形式を同じファイルへ混在させないでください。

```text
timestamp	host	address	mac	item	type	port	status	rtt_ms	error
2026-09-16 12:00:00.123	gateway	192.168.1.1	00:00:5e:00:53:01	ping	icmp		ok	1.23	
2026-09-16 12:00:02.789	dns-server	192.168.1.10		ping	icmp		ng		timeout
```

```json
{"timestamp":"2026-09-16 12:00:01.456","host":"web-server","address":"example.com","mac":null,"item":"https","type":"tcp","port":443,"status":"ok","rtt_ms":45.67,"error":null}
```

グラフ表示などの可視化機能は内蔵していません。TSV / JSON Lines のログを外部ツール（Excel、Livebook など）に読み込んで行う想定です。

## 今後実装したい項目（未着手）

- UDP 監視のサービス追加（SNMPv3、STUN）

## ライセンス

[Apache License 2.0](LICENSE) で公開しています。
