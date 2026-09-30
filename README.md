# NexPinger (Elixir CUI)

English | [日本語](README.ja.md)

A CUI tool in Elixir that keeps monitoring many hosts over ICMP / TCP. On a TTY, you can switch between "Ping Results" and "Ping Statistics".

## Features (so far)

- Loads hosts and checks (Items) from a YAML config file
- Each Item runs on its own interval
- ICMP ping (no privileges needed)
  - Linux: sends directly over an ICMP datagram socket. If the user's group is not in `net.ipv4.ping_group_range`, falls back to the `ping` command with `LC_ALL=C`
    (to enable: `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"`)
  - Windows: sends via a helper (`priv/bin/icmp_helper.exe`) that calls `IcmpSendEcho2` / `Icmp6SendEcho2`. If the helper is missing or can't run, falls back to `ping.exe` (parsed independently of the display language)
  - Other OSes: runs the OS `ping` command
  - Shows the method in use (and any fallback reason) at startup as `ICMP: ...`
- TCP ping (checks `:gen_tcp.connect` and measures the RTT)
- Streams one line per result (OK in green / NG in red)
- On a TTY, `Tab` switches between the result stream and Ping Statistics
- On a TTY, `Q` quits (`Ctrl+C` also works)
- Ping Statistics shows, per Item: runs, failures, loss rate, latest RTT, average, P95, P99
- RTT window set by `--stats-window` (default: 1000 attempts)
- Results can go to stdout and a log file at the same time
- Log file format: text / TSV / JSON Lines (`--log-format`)
- `--no-stdout` turns off console output
- `--help` shows help
- For targets on the same IP subnet, shows the MAC address from the neighbor table

## Setup

```bash
mix deps.get
```

## Running

### 1. Run directly with mix

```bash
mix run --no-halt -e 'NexPinger.CLI.main(["config/hosts.yml"])'
```

### 1a. With options

```bash
mix run --no-halt -e 'NexPinger.CLI.main(["--log-file", "/tmp/nexpinger.log", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--no-stdout", "--log-file", "/tmp/nexpinger.log", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--log-file", "/tmp/nexpinger.tsv", "--log-format", "tsv", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--stats-window", "500", "--stats-width", "120", "config/hosts.yml"])'
mix run --no-halt -e 'NexPinger.CLI.main(["--help"])'
```

### 2. Build and run as an escript

```bash
mix escript.build
./nexpinger config/hosts.yml
./nexpinger --log-file /tmp/nexpinger.log config/hosts.yml
./nexpinger --no-stdout --log-file /tmp/nexpinger.log config/hosts.yml
./nexpinger --log-file /tmp/nexpinger.jsonl --log-format jsonl config/hosts.yml
./nexpinger --stats-window 500 --stats-width 120 config/hosts.yml
./nexpinger --help
```

### 3. Build and run as a single executable with Burrito

Burrito can't build on Windows, so build in WSL.
In WSL, the Zig cache must be on the Linux side or the build fails.

The Windows helper `priv/bin/icmp_helper.exe` (source: `c_src/icmp_helper.c`)
is cross-compiled with `zig cc` during `mix compile` and bundled in the release.
Without `zig`, this step is skipped (Windows then uses `ping.exe`).

```bash
ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache-nexpinger MIX_ENV=prod BURRITO_TARGET=windows mix release
```

```powershell
.\burrito_out\nexpinger_windows.exe --help
.\burrito_out\nexpinger_windows.exe config\hosts.yml
```

## CLI options

- `--log-file PATH`: append results to this file
- `--log-format FORMAT`: log file format (`text` (default) / `tsv` / `jsonl`). Requires `--log-file`
- `--no-stdout`: no console output
- `--stats-window N`: number of recent attempts for average / P95 / P99 (default 1000, min 1)
- `--stats-width N`: stats screen width (80 or 120 columns; picked from the terminal width if omitted)
- `--ping-command`: always use the OS `ping` command for ICMP, not the ICMP socket (Linux) or `icmp_helper.exe` (Windows)
- `--help`: show help
- `config file`: path to a config file (at least one; all are loaded if several)

Without `--log-file`, nothing is written to a file.

On a TTY, `Tab` switches between Ping Results and Ping Statistics. On the stats screen, scroll with the Up/Down keys or `j`/`k`, and quit with `Q`. Stats are shown per Host/Item. Runs, failures, and loss rate are totals since startup. Average, P95, and P99 use only successful RTTs in the last `N` attempts; failures are excluded. The Latest column shows `OK <RTT>` on success and `NG` on failure. The unit is shown at the top as `RTT: ms`. A bell rings on failure on both screens. Without a TTY, output is the plain result stream.

Percentiles use the nearest-rank method. With no RTT samples, `-` is shown.

Example:

```bash
./nexpinger --log-file ./monitor.log --no-stdout config/hosts.yml
```

This writes results to the file and prints nothing to stdout.

## Config file

YAML and `/etc/hosts` formats are detected from the content. In hosts format, each valid line's IP address and first host name become an ICMP check. Extra aliases point to the same host, so they are not separate checks. Interval and timeout use the Item defaults (1000 ms each). Use YAML for TCP checks and other settings.

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

- A host has `name` and `address`, and one or more checks in `items`
- An Item has `name`, `type` (`icmp` or `tcp`), `interval` (ms), and `timeout` (ms, default 1000)
- `port` is required for `type: tcp`

### hosts format

```text
127.0.0.1 localhost localhost.localdomain
::1       ip6-localhost ip6-loopback
192.168.1.5 nas
```

## Sample output

```
2026-09-16 12:00:00.123 | gateway/ping             (192.168.1.1    ) 00:00:5e:00:53:01 ICMP OK    1.23 ms
2026-09-16 12:00:01.456 | web-server/https:443      (example.com    )                   TCP  OK   45.67 ms
2026-09-16 12:00:02.789 | dns-server/ping           (192.168.1.10   )                   ICMP NG    timeout
```

Times are local time, on screen and in files. The MAC address is shown only when found on the same IP subnet; otherwise the same width is left blank. With `--log-format text` (default), the log file gets the same format. With `--no-stdout`, nothing goes to the console; results go only to the file.

### Log file formats

`--log-format tsv` / `jsonl` write raw data with no padding or units, for easy analysis in Excel and similar tools. Fields, in order:

| Field | Content |
|---|---|
| `timestamp` | Time of the check (local time, `2026-09-30 12:00:00.123`) |
| `host` | Host name |
| `address` | Address |
| `mac` | MAC address (missing if not found) |
| `item` | Item name |
| `type` | `icmp` / `tcp` |
| `port` | Port number (missing for ICMP) |
| `status` | `ok` / `ng` |
| `rtt_ms` | RTT (ms, not rounded; missing on NG) |
| `error` | Failure reason (missing on OK) |

- **TSV**: tab-separated. A header line is written only when the file is empty. Missing values are empty. Tabs and newlines in values become spaces
- **JSON Lines**: one object per line. Missing values are `null`; `port` and `rtt_ms` are numbers

Existing files are appended to without checking their format, so don't mix formats in one file.

```text
timestamp	host	address	mac	item	type	port	status	rtt_ms	error
2026-09-16 12:00:00.123	gateway	192.168.1.1	00:00:5e:00:53:01	ping	icmp		ok	1.23	
2026-09-16 12:00:02.789	dns-server	192.168.1.10		ping	icmp		ng		timeout
```

```json
{"timestamp":"2026-09-16 12:00:01.456","host":"web-server","address":"example.com","mac":null,"item":"https","type":"tcp","port":443,"status":"ok","rtt_ms":45.67,"error":null}
```

## Planned (not started)

- Combined ARP/PING view (4 patterns, including same-subnet check)
- Full-screen CUI
- GUI version

## License

Licensed under the [Apache License 2.0](LICENSE).
