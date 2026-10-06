# NexPinger (Elixir CUI)

English | [日本語](README.ja.md)

A CUI tool in Elixir that keeps monitoring many hosts over ICMP / TCP / UDP. On a TTY, you can switch between "Ping Results" and "Ping Statistics".

Inspired by [ExPing](https://www.woodybells.com/exping.html), a Windows tool that pings many addresses.

## Features (so far)

- Loads hosts and checks (Items) from a YAML config file
- Each Item runs on its own interval
- ICMP ping (no privileges needed)
  - Linux: sends directly over an ICMP datagram socket. If the user's group is not in `net.ipv4.ping_group_range`, falls back to the `ping` command with `LC_ALL=C`
    (to enable: `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"`)
  - Windows: sends via a helper (`priv/bin/icmp_helper.exe`) that calls `IcmpSendEcho2` / `Icmp6SendEcho2`. If the helper is missing or can't run, falls back to `ping.exe` (parsed independently of the display language)
  - Other OSes: runs the OS `ping` command
  - Shows the method in use (and any fallback reason) at startup as `ICMP: ...`
- TCP ping (checks `:gen_tcp.connect` and measures the RTT; see [TCP checks](#tcp-checks))
- UDP ping (sends a DNS / NTP / QUIC request and waits for any reply; see [UDP checks](#udp-checks))
- Streams one line per result (OK in green / NG in red)
- On a TTY, `Tab` switches between the result stream and Ping Statistics
- On a TTY, `Q` quits (`Ctrl+C` also works)
- Ping Statistics shows, per Item: runs, failures, loss rate, latest RTT, average, P95, P99
- RTT window set by `--stats-window` (default: 1000 attempts)
- Results can go to stdout and a log file at the same time
- Log file format: text / TSV / JSON Lines (`--log-format`)
- `--no-stdout` turns off console output
- `--help` shows help, `--version` shows the version
- For on-link targets, shows the MAC address from the neighbor table (ARP / NDP, IPv4 and IPv6; Linux and Windows)

## Download

Prebuilt binaries are on [GitHub Releases](https://github.com/jolly-jive/nexpinger/releases).

- `nexpinger`: escript. Needs Erlang/OTP 27 or later. On Windows, ICMP uses `ping.exe` because an escript can't bundle `icmp_helper.exe`. On Windows, use `nexpinger.exe` instead (see [Known issues](#known-issues))
- `nexpinger.exe`: single Windows executable (Burrito). No Erlang needed, but needs the Microsoft Visual C++ runtime. On first run, it unpacks itself under `%APPDATA%\.burrito`

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

An escript can't bundle `priv/bin/icmp_helper.exe`, so on Windows it uses `ping.exe`.

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

For Linux, use `BURRITO_TARGET=linux_x86_64` or `BURRITO_TARGET=linux_aarch64`.
Without `BURRITO_TARGET`, all targets are built.
The Linux binary bundles a musl-based ERTS, so it doesn't depend on the system's glibc.
On first run, it unpacks itself under `~/.local/share/.burrito`.

```bash
ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache-nexpinger MIX_ENV=prod BURRITO_TARGET=linux_x86_64 mix release
./burrito_out/nexpinger_linux_x86_64 --help
./burrito_out/nexpinger_linux_x86_64 config/hosts.yml
```

## CLI options

- `--log-file PATH`: append results to this file
- `--log-format FORMAT`: log file format (`text` (default) / `tsv` / `jsonl`). Requires `--log-file`
- `--no-stdout`: no console output
- `--stats-window N`: number of recent attempts for average / P95 / P99 (default 1000, min 1)
- `--stats-width N`: stats screen width (80 or 120 columns; picked from the terminal width if omitted)
- `--ping-command`: always use the OS `ping` command for ICMP, not the ICMP socket (Linux) or `icmp_helper.exe` (Windows)
- `--version`: show the version
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

YAML and `/etc/hosts` formats are detected from the content. In hosts format, each valid line's IP address and first host name become an ICMP check. Extra aliases point to the same host, so they are not separate checks. Interval and timeout use the Item defaults (1000 ms each). Use YAML for TCP / UDP checks and other settings.

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

- A host has `name` and `address`, and one or more checks in `items`
- A host's `family` (`ipv4`, `ipv6` or `auto`, default `auto`) sets the address family. For a host name in `address`, `ipv4` looks up the A record and `ipv6` the AAAA record. `auto` looks up the A record, else the AAAA record (if there is an A record, IPv6 is not tried even when IPv4 is unreachable). This order can differ from the OS: where IPv6 is usable, the OS `ping` and other tools usually prefer IPv6 for a name with both records. Set `family: ipv6` to check the IPv6 address. An IP address in `address` that does not match `family` is a config error
- Names are resolved once at startup, and that IP address is checked until exit. Later DNS changes are not followed; restart to resolve again. A host that cannot be resolved at startup is an error and NexPinger exits. If a name has several addresses, the first one is used and a message lists the others
- An Item has `name`, `type` (`icmp`, `tcp` or `udp`), `interval` (ms), and `timeout` (ms, default 1000)
- `port` is required for `type: tcp`
- `service` (`dns`, `ntp` or `quic`) is required for `type: udp`. `port` defaults to the service's standard port (dns: 53, ntp: 123, quic: 443)
- An unknown key is a config error, so a typo is not silently ignored

### ICMP checks

- Sends one Echo Request. OK if the matching Echo Reply comes back within `timeout`
- RTT resolution depends on the method. The ICMP socket and `icmp_helper.exe` measure below 1 ms. The `ping` command's printed value is used as is, so with Windows `ping.exe` the RTT is in whole ms, and `<1ms` counts as 1 ms

### TCP checks

- OK when the 3-way handshake completes. No data is sent or received, and the connection is closed at once. This shows the port accepts connections, not that the service works
- RTT is the time to connect (SYN to SYN/ACK)
- A refused connection (RST), or no connection within `timeout`, is NG
- If a device on the path (a firewall's SYN proxy, a load balancer, etc.) completes the handshake for the target, the OK and the RTT are that device's

### UDP checks

A UDP check sends a request that makes the service reply, and **only checks whether a reply comes back. It does not inspect the reply content.** The goal is network reachability, so a DNS NXDOMAIN or REFUSED, an NTP Kiss-o'-Death, or a malformed reply all count as OK.

| `service` | Request sent |
|---|---|
| `dns` | `. SOA` query, RD=0 (norec), no EDNS |
| `ntp` | NTPv4 client request (mode 3), 48 bytes |
| `quic` | Long header Initial with a reserved, unsupported version (`0x1a2a3a4a`), padded to 1200 bytes. The server replies with Version Negotiation |

- RTT is the time from sending the request to the first reply, including the server's processing time. With RD=0, a DNS resolver answers from its cache (or refuses) without recursing, so the RTT does not include recursion time
- No reply within `timeout` is NG (`timeout`)
- An ICMP Port Unreachable is not a UDP reply, so it is NG (`port unreachable`). This matches TCP, where a RST is NG. It may also come from a firewall (e.g. iptables `REJECT`) rather than the target itself
- Public NTP servers often rate-limit clients that poll too often, and may reply with Kiss-o'-Death or drop requests. So an NTP item's `interval` defaults to 8000 ms, and a warning is shown at startup if it is set under 8000 ms. Use 8000 ms or more for servers you don't run yourself

### hosts format

```text
127.0.0.1 localhost localhost.localdomain
::1       ip6-localhost ip6-loopback
192.168.1.5 nas
```

## Sample output

```
2026-09-16 12:00:00.123 | gateway/ping            (192.168.1.1             ) 00:00:5e:00:53:01 ICMP OK    1.23 ms
2026-09-16 12:00:01.456 | web-server/https:443    (example.com=203.0.113.10)                   TCP  OK   45.67 ms
2026-09-16 12:00:02.789 | dns-server/ping         (192.168.1.10            )                   ICMP NG    timeout
2026-09-16 12:00:03.012 | dns-server/dns:53       (192.168.1.10            )                   UDP  OK    2.34 ms
```

Times are local time, on screen and in files. The MAC address is shown only when found in the neighbor table, which holds on-link hosts only; otherwise the same width is left blank. Lookups are cached per IP for 15 s. When `address` is a host name, the resolved IP is shown with it as `name=IP`. The address column width is set at startup from the config (15 to 24 columns). Text that does not fit is cut: first the name from the right, then the name is dropped, and the IP is cut from the left (keeping the IPv6 interface ID). With `--log-format text` (default), the log file gets the same format, but the address is never cut there. With `--no-stdout`, nothing goes to the console; results go only to the file.

### Log file formats

`--log-format tsv` / `jsonl` write raw data with no padding or units, for easy analysis in Excel and similar tools. Fields, in order:

| Field | Content |
|---|---|
| `timestamp` | Time of the check (local time, `2026-09-30 12:00:00.123`) |
| `host` | Host name |
| `address` | Address |
| `resolved` | IP address used for the check |
| `mac` | MAC address (missing if not found) |
| `item` | Item name |
| `type` | `icmp` / `tcp` / `udp` |
| `port` | Port number (missing for ICMP) |
| `status` | `ok` / `ng` |
| `rtt_ms` | RTT (ms, not rounded; missing on NG) |
| `error` | Failure reason (missing on OK) |

- **TSV**: tab-separated. A header line is written only when the file is empty. Missing values are empty. Tabs and newlines in values become spaces
- **JSON Lines**: one object per line. Missing values are `null`; `port` and `rtt_ms` are numbers

Existing files are appended to without checking their format, so don't mix formats in one file.

```text
timestamp	host	address	resolved	mac	item	type	port	status	rtt_ms	error
2026-09-16 12:00:00.123	gateway	192.168.1.1	192.168.1.1	00:00:5e:00:53:01	ping	icmp		ok	1.23	
2026-09-16 12:00:02.789	dns-server	192.168.1.10	192.168.1.10		ping	icmp		ng		timeout
```

```json
{"timestamp":"2026-09-16 12:00:01.456","host":"web-server","address":"example.com","resolved":"203.0.113.10","mac":null,"item":"https","type":"tcp","port":443,"status":"ok","rtt_ms":45.67,"error":null}
```

There is no built-in graphing. For charts, feed TSV / JSON Lines logs to an external tool (Excel, Livebook, etc.).

## Known issues

- On Windows, the escript (`nexpinger`) shows the Erlang VM's BREAK menu on `Ctrl+C`. Type `a` and Enter to quit. `nexpinger.exe` does not have this problem
- On Windows, `Ctrl+Break` shows the same BREAK menu, in `nexpinger.exe` too. Use `Ctrl+C` or `Q` to quit

## Planned (not started)

- More UDP services (SNMPv3, STUN)

## License

Copyright 2026 Cayenne Ryo

Licensed under the [Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

The release binaries include third-party software (Elixir, Erlang/OTP, yaml_elixir, yamerl, Burrito, etc.). Their licenses are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES), which is also attached to each GitHub Release.
