# Architecture

English | [日本語](architecture.ja.md)

How NexPinger's processes are laid out and how a result travels from a probe to the screen and the log file.

## Supervision tree

```mermaid
graph TD
    App["NexPinger.Application<br/>(start/2)"] --> Sup["NexPinger.Supervisor<br/>one_for_one"]

    Sup --> Reg["MonitorRegistry<br/>(Registry, unique)"]
    Sup --> MonSup["MonitorSupervisor<br/>(DynamicSupervisor)"]
    Sup --> BC["Broadcaster<br/>(GenServer)"]
    Sup --> SubSup["SubscriberSupervisor<br/>(DynamicSupervisor)"]
    Sup --> IH["IcmpHelper<br/>(GenServer, Windows)"]
    Sup --> MR["MacResolver<br/>(GenServer, owns the ETS table)"]
    Sup -. "Burrito on Linux only" .-> L["Launcher<br/>(GenServer)"]

    MonSup --> R1["Runner {host, item}"]
    MonSup --> R2["Runner ..."]
    SubSup --> CS["ConsoleSubscriber"]
    SubSup --> FS["FileSubscriber"]

    IH --- Port1[["icmp_helper.exe<br/>(port)"]]
    R1 -. "registered via name" .-> Reg
```

- The `Broadcaster` starts before `SubscriberSupervisor`: subscribers subscribe in their `init`.
- Both dynamic supervisors start empty. The CLI adds the subscribers and one `Runner` per item.
- `Launcher` is added, and `SignalHandler` installed, only under Burrito on Linux.

## Startup

```mermaid
sequenceDiagram
    participant App as Application
    participant CLI as CLI.main (caller process)
    participant SubSup as SubscriberSupervisor
    participant MonSup as MonitorSupervisor
    participant TI as TerminalInput

    App->>App: Supervisor.start_link(children)
    alt Burrito
        App->>CLI: CLI.main(argv), inside start/2
    else escript
        Note over CLI: the escript calls CLI.main/1
    end
    CLI->>CLI: parse, prepare (resolve every host once)
    opt --log-file
        CLI->>SubSup: start_child(FileSubscriber, subscribe: true)
    end
    CLI->>CLI: print the banner (ICMP method, etc.)
    opt stdout enabled
        CLI->>SubSup: start_child(ConsoleSubscriber, subscribe: true)
    end
    loop each host × item
        CLI->>MonSup: start_child({Runner, {host, item}})
    end
    CLI->>TI: run() (key input) / wait_for_interrupt() (Ctrl+C on Windows)
    TI-->>CLI: :quit, then System.halt(0)
```

Subscribers start before the runners, so the first results are not missed. The CLI and
`TerminalInput` are not supervised: they run in the calling process, which under Burrito is the
one running `Application.start/2`, and never return.

## Result flow

```mermaid
graph LR
    subgraph "Inside the Runner process (synchronous)"
        R["Runner<br/>(:probe timer)"] --> P["Prober.probe"]
        P --> IS["IcmpSocket<br/>(Linux, :socket + ErrorQueue)"]
        P --> PC["ping command<br/>(port, fallback)"]
        P --> TCP[":gen_tcp.connect"]
        P --> UDP["UdpProbe<br/>(DNS / NTP / QUIC)"]
        R --> MRL["MacResolver.lookup<br/>(reads ETS directly)"]
    end

    P -- "Windows: call" --> IH["IcmpHelper"] <--> EXE[["icmp_helper.exe"]]
    MRL -- "Windows: call" --> IH
    MRL -- "Linux: ip neigh" --> OS[("OS neighbor table")]

    R -- "cast {:publish, ...}" --> BC["Broadcaster"]
    BC -- "send {:item_result, ...}<br/>{:results_dropped, ...}" --> CS["ConsoleSubscriber<br/>max_queue 1000"]
    BC -- "send" --> FS["FileSubscriber<br/>max_queue 100,000"]
    BC -. "Process.monitor" .-> CS
    BC -. "Process.monitor" .-> FS

    CS --> Term["terminal<br/>(result lines / stats screen)"]
    FS --> Log[("log file<br/>opened per line")]
```

- `Prober` and `MacResolver.lookup` run in the `Runner`'s own process. The `MacResolver`
  process only owns the ETS cache (15 s per IP). The only call to another process is to
  `IcmpHelper`, on Windows.
- `Runner` turns any failure in a probe or a MAC lookup into an NG result rather than crashing,
  so repeated crashes cannot exhaust `MonitorSupervisor`.
- The `Broadcaster` takes results by `cast` and passes them on by `send`, so probes never wait
  for output. It checks each subscriber's `message_queue_len`: at the cap it drops and counts
  results per target; once the mailbox is down to half the cap, it sends
  `{:results_dropped, ...}` and then results again.
- A restarted subscriber has a new pid. The `Broadcaster` drops the old one on `:DOWN`, and the
  new one subscribes again itself (`subscribe: true`).
- A restarted `Broadcaster` has no subscribers (the supervisor is `one_for_one`, so the
  subscribers keep running). Subscribers subscribe with `Broadcaster.follow/1`, which also
  monitors the `Broadcaster`; on its `:DOWN` they subscribe to the new one, retrying every
  100 ms until it is registered. Results in the old one's mailbox are lost.

## Key input and exit

```mermaid
graph TD
    Key["key input (raw mode)"] --> TI["TerminalInput.input_loop<br/>(CLI process)"]
    TI -- "Tab: cast toggle_view" --> CS["ConsoleSubscriber"]
    TI -- "j / k / ↑ / ↓: cast scroll" --> CS
    TI -- "q / Ctrl+C / EOF" --> Q[":quit"]
    Q --> End["after: call end_stats_view, restore stty"] --> Halt["System.halt(0)"]

    SIG["SIGTERM"] --> SH["SignalHandler<br/>(gen_event handler on :erl_signal_server)"] --> Stop["Launcher.stop/0"]
    Parent["Burrito launcher gone<br/>(parent PID changed)"] --> L["Launcher<br/>(checks /proc every second)"] --> Stop
    Stop --> Restore["TerminalInput.restore<br/>(writes to the TTY, not stdout)"] --> Halt
```

- A normal quit stays in the CLI process and restores the terminal in its `after` clauses.
- SIGTERM and a lost launcher come from other processes. They read the saved stty settings and
  the stats screen flag from `:persistent_term`, and write to the TTY device because the stdout
  pipe may be broken.

## Processes at a glance

| Process | Kind | Count | Role | Talks to |
|---|---|---|---|---|
| `Runner` | GenServer | one per host × item | Probes on a fixed schedule and publishes the result | `Prober` (in process), `Broadcaster` |
| `Broadcaster` | GenServer | 1 | Fans results out to subscribers; drops for slow ones | runners (in), subscribers (out, monitored) |
| `ConsoleSubscriber` | GenServer | 0 or 1 | Result lines and the stats screen | `Broadcaster`, `TerminalInput` |
| `FileSubscriber` | GenServer | 0 or 1 | Log file in text / tsv / jsonl | `Broadcaster` |
| `IcmpHelper` | GenServer + port | 1 | ICMP Echo and MAC lookup on Windows | runners (callers) |
| `MacResolver` | GenServer (ETS owner) | 1 | 15 s MAC cache | runners read the ETS table directly |
| `Launcher` | GenServer | 0 or 1 | Stops the BEAM when the Burrito launcher dies | — |
| `SignalHandler` | gen_event handler | 0 or 1 | Quiet exit on SIGTERM | — |
| `CLI` / `TerminalInput` | plain functions (caller process) | 1 | Startup, key input, exit | the supervisors, `ConsoleSubscriber` |
