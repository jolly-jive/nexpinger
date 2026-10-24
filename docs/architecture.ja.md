# アーキテクチャ

[English](architecture.md) | 日本語

NexPinger のプロセス構成と、プローブの結果が画面・ログファイルに届くまでの流れ。

## 監視ツリー

```mermaid
graph TD
    App["NexPinger.Application<br/>(start/2)"] --> Sup["NexPinger.Supervisor<br/>one_for_one"]

    Sup --> Reg["MonitorRegistry<br/>(Registry, unique)"]
    Sup --> MonSup["MonitorSupervisor<br/>(DynamicSupervisor)"]
    Sup --> BC["Broadcaster<br/>(GenServer)"]
    Sup --> SubSup["SubscriberSupervisor<br/>(DynamicSupervisor)"]
    Sup --> IH["IcmpHelper<br/>(GenServer, Windows)"]
    Sup --> MR["MacResolver<br/>(GenServer, ETS の所有者)"]
    Sup -. "Burrito + Linux のみ" .-> L["Launcher<br/>(GenServer)"]

    MonSup --> R1["Runner {host, item}"]
    MonSup --> R2["Runner ..."]
    SubSup --> CS["ConsoleSubscriber"]
    SubSup --> FS["FileSubscriber"]

    IH --- Port1[["icmp_helper.exe<br/>(Port)"]]
    R1 -. "via name で登録" .-> Reg
```

- `Broadcaster` は `SubscriberSupervisor` より先に起動する。Subscriber は `init` で subscribe するため
- 2 つの DynamicSupervisor は空で起動する。Subscriber と、項目ごとの `Runner` は CLI が追加する
- `Launcher` の追加と `SignalHandler` の差し替えは、Burrito かつ Linux のときだけ

## 起動

```mermaid
sequenceDiagram
    participant App as Application
    participant CLI as CLI.main（呼び出し元プロセス）
    participant SubSup as SubscriberSupervisor
    participant MonSup as MonitorSupervisor
    participant TI as TerminalInput

    App->>App: Supervisor.start_link(children)
    alt Burrito
        App->>CLI: CLI.main(argv)（start/2 の中で呼ぶ）
    else escript
        Note over CLI: escript が CLI.main/1 を呼ぶ
    end
    CLI->>CLI: parse、prepare（全ホストを一度だけ名前解決）
    opt --log-file
        CLI->>SubSup: start_child(FileSubscriber, subscribe: true)
    end
    CLI->>CLI: バナー表示（ICMP の方式など）
    opt stdout 有効
        CLI->>SubSup: start_child(ConsoleSubscriber, subscribe: true)
    end
    loop host × item ごと
        CLI->>MonSup: start_child({Runner, {host, item}})
    end
    CLI->>TI: run()（キー入力）/ wait_for_interrupt()（Windows の Ctrl+C）
    TI-->>CLI: :quit のあと System.halt(0)
```

Subscriber を Runner より先に起動するので、最初の結果も取りこぼさない。CLI と `TerminalInput` は
監視下にない。呼び出し元のプロセス（Burrito では `Application.start/2` を実行しているプロセス）で動き、
戻らない。

## 結果の流れ

```mermaid
graph LR
    subgraph "Runner プロセス内（同期）"
        R["Runner<br/>(:probe タイマー)"] --> P["Prober.probe"]
        P --> IS["IcmpSocket<br/>(Linux, :socket + ErrorQueue)"]
        P --> PC["ping コマンド<br/>(Port, フォールバック)"]
        P --> TCP[":gen_tcp.connect"]
        P --> UDP["UdpProbe<br/>(DNS / NTP / QUIC)"]
        R --> MRL["MacResolver.lookup<br/>(ETS を直接読む)"]
    end

    P -- "Windows: call" --> IH["IcmpHelper"] <--> EXE[["icmp_helper.exe"]]
    MRL -- "Windows: call" --> IH
    MRL -- "Linux: ip neigh" --> OS[("OS の近隣テーブル")]

    R -- "cast {:publish, ...}" --> BC["Broadcaster"]
    BC -- "send {:item_result, ...}<br/>{:results_dropped, ...}" --> CS["ConsoleSubscriber<br/>max_queue 1000"]
    BC -- "send" --> FS["FileSubscriber<br/>max_queue 100,000"]
    BC -. "Process.monitor" .-> CS
    BC -. "Process.monitor" .-> FS

    CS --> Term["端末<br/>(結果行 / 統計画面)"]
    FS --> Log[("ログファイル<br/>行ごとに open")]
```

- `Prober` と `MacResolver.lookup` は `Runner` 自身のプロセスで動く。`MacResolver` のプロセスは
  ETS のキャッシュ（IP ごとに 15 秒）を持つだけ。他プロセスへの call は Windows の `IcmpHelper` だけ
- `Runner` はプローブや MAC 取得の失敗をクラッシュにせず NG の結果にする。クラッシュが続いて
  `MonitorSupervisor` が再起動の上限に達するのを防ぐため
- `Broadcaster` は `cast` で受けて `send` で配るので、プローブは出力を待たない。Subscriber ごとに
  `message_queue_len` を見て、上限に達したら結果を捨てて対象ごとに数える。半分まで減ったら
  `{:results_dropped, ...}` を送り、配信を再開する
- 再起動した Subscriber は pid が変わる。`Broadcaster` は `:DOWN` で古い pid を外し、新しいプロセスが
  自分で subscribe し直す（`subscribe: true`）

## キー入力と終了

```mermaid
graph TD
    Key["キー入力 (raw mode)"] --> TI["TerminalInput.input_loop<br/>(CLI のプロセス)"]
    TI -- "Tab: cast toggle_view" --> CS["ConsoleSubscriber"]
    TI -- "j / k / ↑ / ↓: cast scroll" --> CS
    TI -- "q / Ctrl+C / EOF" --> Q[":quit"]
    Q --> End["after: call end_stats_view、stty を復元"] --> Halt["System.halt(0)"]

    SIG["SIGTERM"] --> SH["SignalHandler<br/>(:erl_signal_server の gen_event ハンドラ)"] --> Stop["Launcher.stop/0"]
    Parent["Burrito ランチャーの終了<br/>(親 PID の変化)"] --> L["Launcher<br/>(1 秒ごとに /proc を確認)"] --> Stop
    Stop --> Restore["TerminalInput.restore<br/>(stdout ではなく TTY に書く)"] --> Halt
```

- 通常の終了は CLI のプロセス内で完結し、`after` 節で端末を戻す
- SIGTERM とランチャーの終了は別プロセスから来る。保存済みの stty 設定と統計画面のフラグを
  `:persistent_term` から読み、stdout のパイプが壊れている場合に備えて TTY デバイスに書く

## プロセス一覧

| プロセス | 種別 | 個数 | 役割 | 主な相手 |
|---|---|---|---|---|
| `Runner` | GenServer | host × item ごと | 決まったスケジュールでプローブし、結果を publish | `Prober`（同一プロセス）、`Broadcaster` |
| `Broadcaster` | GenServer | 1 | 結果を Subscriber に配る。遅い相手の分は捨てる | Runner（受信）、Subscriber（送信・monitor） |
| `ConsoleSubscriber` | GenServer | 0 か 1 | 結果行と統計画面 | `Broadcaster`、`TerminalInput` |
| `FileSubscriber` | GenServer | 0 か 1 | text / tsv / jsonl のログファイル | `Broadcaster` |
| `IcmpHelper` | GenServer + Port | 1 | Windows の ICMP Echo と MAC 取得 | Runner（呼び出し元） |
| `MacResolver` | GenServer（ETS の所有者） | 1 | MAC の 15 秒キャッシュ | Runner が ETS を直接読む |
| `Launcher` | GenServer | 0 か 1 | Burrito ランチャーの終了時に BEAM を止める | — |
| `SignalHandler` | gen_event ハンドラ | 0 か 1 | SIGTERM で静かに終了 | — |
| `CLI` / `TerminalInput` | 普通の関数（呼び出し元プロセス） | 1 | 起動、キー入力、終了 | 各 Supervisor、`ConsoleSubscriber` |
