# Restore plan — the lost `/usr/bin` + `/usr/sbin` router scripts

The 2026-09 sysupgrade wiped every hand-written script that lived under
`/usr/bin` and `/usr/sbin` on flint (`10.10.10.1`) but was **not** in
`files/` or `/etc/sysupgrade.conf`. Cron entries survive (they are config),
so cron has been calling files that no longer exist.

## Why they vanished

Two independent keep mechanisms, easy to confuse (see `README.md`):

| Mechanism | Where | Survives sysupgrade |
|---|---|---|
| `files/` in this repo | baked into the image | yes |
| `/etc/sysupgrade.conf` keep list | on the live router | yes |

`agh-archive.sh` was in `files/` → survived. `crowdsec-watchdog.sh` and
`qosmate-ipv6-sync` were in `sysupgrade.conf` → survived. The neigh6 tools and
`dhcp-metrics.sh` were in **neither** → lost on the first flash.

## Inventory — what cron expects vs what exists

| Cron entry | Existed on flint | Recoverable | Source |
|---|---|---|---|
| `30 3 * * *  /usr/bin/agh-archive.sh` | yes | n/a | `files/usr/bin/agh-archive.sh` |
| `*/15 * * * *  /usr/bin/crowdsec-watchdog.sh` | yes | n/a | `sysupgrade.conf` |
| `* * * * *  /usr/bin/neigh6-hosts` | **no** | **yes — recovered** | `files/usr/bin/neigh6-hosts` |
| `*/5 * * * *  /usr/bin/neigh6-agh-sync` | **no** | **yes — recovered** | `files/usr/bin/neigh6-agh-sync` |
| `*/15 * * * *  /usr/bin/qosmate-ipv6-sync` | yes | n/a | `sysupgrade.conf` |
| `*/5 * * * *  /usr/sbin/dhcp-metrics.sh` | **no** | **yes** | `files/usr/sbin/dhcp-metrics.sh` |

Not in cron, also lost:

| Script | Recoverable | Source / disposition |
|---|---|---|
| `/usr/bin/neigh6-agh-new` | no — **recreate** | spec below; ran once 2026-08-01 |
| `/usr/bin/whodis` | no — **recreate** | spec below |

The two cron scripts were recovered verbatim from the OpenCode session
database (`~/.local/share/opencode/opencode.db`, a 2026-08-07 session that
`cat`'d them). `/opt/neigh6/db` and `/etc/neigh6.conf` were on the overlay and
are also gone; `/opt/neigh6/db` rebuilds itself from the live neighbour table
within a minute of `neigh6-hosts` first running (the 48 h history is lost, the
AdGuard client ids it had pushed already live in AdGuard).

## Recovered scripts (already staged in this repo)

- `files/usr/bin/neigh6-hosts` — merges the live IPv6/IPv4 neighbour table into
  the persistent TSV `/opt/neigh6/db` (addr, mac, name, last_seen), prunes
  beyond `RETENTION_HOURS` (48), writes IPv6 `-6.lan` names to
  `/tmp/hosts/neigh6`, SIGHUPs dnsmasq on change.
- `files/usr/bin/neigh6-agh-sync` — pushes recorded addresses into the `ids` of
  every AdGuard persistent client that carries a MAC id, via the HTTP API;
  infers a MAC anchor for IP-only clients; owns only what it pushed
  (`/opt/neigh6/managed`), `--adopt` takes over hand-added IP ids, `-n` dry-run.
- `files/usr/sbin/dhcp-metrics.sh` — emits `lan_client_info` /
  `lan_client_mac` textfile metrics for Prometheus.

All three are LF-only and re-verified against the recovered byte content.

## Steps

### 1. Restore the scripts to the router (works now, before any flash)

```powershell
$repo = "$env:USERPROFILE\Documents\Claudio\GL-MT6000\files"
$r = "$env:USERPROFILE\.local\bin\invoke-remote.ps1"
scp "$repo\usr\bin\neigh6-hosts"      flint:/usr/bin/
scp "$repo\usr\bin\neigh6-agh-sync"   flint:/usr/bin/
scp "$repo\usr\sbin\dhcp-metrics.sh"  flint:/usr/sbin/
& $r -Target flint -Command 'chmod 755 /usr/bin/neigh6-hosts /usr/bin/neigh6-agh-sync /usr/sbin/dhcp-metrics.sh'
```

### 2. Recreate `/etc/neigh6.conf`

Copy `files/etc/neigh6.conf.example` → `/etc/neigh6.conf`, fill `AGH_USER` /
`AGH_PASS` from `npm-site/.env` (`ADGUARD_USER` / `ADGUARD_PASS`), `chmod 600`.
Without `AGH_PASS`, `neigh6-agh-sync` stays silent (by design).

### 3. Recreate `neigh6-agh-new` (one-shot, not in cron)

Behaviour to reproduce (from `router-dns-ptr.md`): for every *named* device in
`/opt/neigh6/db` that has no AdGuard persistent client, create one anchored on
its MAC plus every recorded address, then append `name<TAB>addr` rows to
`/opt/neigh6/managed` so `neigh6-agh-sync` takes over. Group **by hostname, not
MAC** (one device may hold several reservations; AdGuard client names must be
unique). Skip hostnames in `NEW_CLIENT_SKIP`. `-n` dry-runs. API quirk:
`POST /control/clients/add` wants `blocked_services` as a **flat array of
strings**, not the nested object the on-disk YAML uses — the object form returns
`HTTP 400 cannot unmarshal object into Go struct field clientJSON.blocked_services of type []string`.
Model it on `neigh6-agh-sync`'s login/curl plumbing.

### 4. Recreate `whodis` (interactive, not in cron)

`whodis`, `whodis <substring>`, `whodis -m <mac>` — reads the **live** neighbour
table only (`ip -6 neigh` + `ip -4 neigh`), maps addr → MAC → DHCPv4 hostname
from `/tmp/dhcp.leases` / `dhcp-host=` lines, prints a table. Covers IPv4 too.
No DB, no persistence.

### 5. Make the whole set survive the next flash

- Baked into the image: already done for the three recovered scripts — they
  sit under `files/` and the custom image copies `files/` over `/`.
- Belt-and-braces keep list: add the same paths to
  `files/etc/sysupgrade.conf` (done in this commit) so a plain OpenWrt
  sysupgrade keeps them even without a custom image rebuild:

```
/usr/bin/neigh6-hosts
/usr/bin/neigh6-agh-sync
/usr/bin/neigh6-agh-new
/usr/bin/whodis
/usr/sbin/dhcp-metrics.sh
/etc/neigh6.conf
```

`/etc/neigh6.conf` holds a password, so it must **not** go into `files/`
(public repo) — keep-list only, or restore by hand.

### 6. Cron

`/etc/crontabs/root` already has the entries and survives as config. Verify
after restore:

```sh
crond -l 8   # or just: logread -f | grep neigh6
/usr/bin/neigh6-hosts && head /opt/neigh6/db
/usr/bin/neigh6-agh-sync -n
```

### 7. Verify

- `/opt/neigh6/db` fills within a minute, `/tmp/hosts/neigh6` non-empty.
- `dig @10.10.10.1 <name>-6.lan` resolves; `dig documents.lan AAAA` stays empty.
- `neigh6-agh-sync -n` prints no unexpected changes once settled.
- `rm /var/prometheus/dhcp.prom` then wait for the 5-min cron: file reappears.

## Firewall rule that follows a rotating MAC — implemented

The iPad block (`firewall.@rule[13]` `iPad-Gabriele`) matches `ether saddr`,
and the iPad's iOS private MAC rotates, so the rule goes stale. Solved with
`files/usr/bin/neigh6-fw-sync`, which follows the **device hostname**, not a
pinned MAC.

Why this shape (options considered):

| Option | Verdict |
|---|---|
| Hotplug on `/etc/hotplug.d/dhcp` rewriting the MAC | rejected — new mechanism, the router has no custom dhcp hotplug, and it duplicates what the neighbour DB already knows |
| Static DHCP reservation by hostname + `ip saddr` block | simplest, but needs a raw `dhcp-host=iPad,<ip>` line (OpenWrt's `config host` is MAC-oriented) and a unique DHCP name |
| **`neigh6-fw-sync` keyed on device name** | **chosen** — reuses `/opt/neigh6/db` and the `qosmate-ipv6-sync` pattern already deployed |

The trap this avoids: keying on a hardcoded MAC (as `qosmate-ipv6-sync` does
for the PC) is circular for the iPad — the MAC is the value that rotates. The
DB gets the *new* MAC within a minute, so a fixed `MAC` filter would never
match. `neigh6-fw-sync` matches column 3 (hostname) instead.

Behaviour: reads every MAC seen for `iPad` in `/opt/neigh6/db` within
`FRESH_SECS` (2 h), rewrites `src_mac` as a uci list, `fw4 reload` only on
change (state in `/tmp/.neigh6-fw-*`). Empty result leaves the rule untouched
so a transient gap does not open the block. `-n` dry-runs. Rule section is
resolved by name, not a hardcoded `@rule[N]`.

Also cleaned up by hand during rollout: the dead duplicate `firewall.@rule[41]`
`iPad Gabriele` (`ca:da:aa:1d:04:c8`, no live lease) was removed.

### iPad AdGuard client — fixed with a name-keyed mapping

`neigh6-agh-sync` is normally **MAC-anchored**: it manages a client whose `ids`
already contain a MAC, or infers one from an IP id that is *currently* in the
DB. That cannot work for the iPad — its MAC rotates, and its client held only
the stale IP `10.10.10.212`, so inference failed (verified 2026-09-25: the sync
updated 4 other clients, not this one).

Fix: `neigh6-agh-sync` now reads `AGH_NAME_MAP` from `/etc/neigh6.conf`, a
`;`-separated list of `AdGuard client name|dhcp hostname` pairs. A client named
there is resolved by the device **hostname** in `/opt/neigh6/db` instead of by
MAC, and is fully owned (its IP ids are reset to the current recorded addresses
each run, so stale hand-added ones like `10.10.10.212` are retired). MAC
clients keep the original behaviour untouched. `-n` dry-runs.

Router config: `AGH_NAME_MAP="iPad Gabriele|iPad"`. Result:
`iPad Gabriele` ids = `10.10.10.234`, the current global IPv6 and ULA; rerun is
a no-op. The device can rotate its MAC or its addresses freely — the sync picks
up the new set from the neighbour DB within ~5 min.

(For the firewall block the equivalent name-keyed logic lives in
`neigh6-fw-sync`, above.)

## Open items

- `neigh6-agh-new` and `whodis` source is **not** recoverable from anywhere on
  this machine — they need recreating from the specs above.
- Confirm `AGH_USER`/`AGH_PASS` still valid (used by `neigh6-agh-sync`); the
  router's AdGuard admin credentials are in `npm-site/.env`, not in git.

## Rollout log (2026-09-25)

Done on flint:

- Backed up `/etc/config/firewall` and `/etc/crontabs/root` to
  `*.bak-20260925-170943`.
- Deployed `neigh6-hosts`, `neigh6-agh-sync`, `neigh6-fw-sync` to `/usr/bin`
  and `dhcp-metrics.sh` to `/usr/sbin` (mode 755, LF).
- Added cron `*/5 * * * * /usr/bin/neigh6-fw-sync`; restarted cron. All 7
  entries now point at real files.
- Deleted the dead `firewall.@rule[41]` `iPad Gabriele`.
- Ran `neigh6-hosts`: `/opt/neigh6/db` rebuilt (55 rows), `/tmp/hosts/neigh6`
  written (22 names), dnsmasq SIGHUP'd.
- Ran `neigh6-fw-sync`: rule `iPad-Gabriele` `src_mac` set to
  `0a:6c:bf:03:ee:45`; `nft` confirms `ether saddr 0a:6c:bf:03:ee:45 ... jump
  reject_to_wan`. Second run is a no-op.
- Wrote `/etc/neigh6.conf` (chmod 600) from `npm-site/.env`; ran
  `neigh6-agh-sync`, which updated 4 clients (Salvatore-PC, OPPO-Find-X9-Pro,
  POCO-X7-Pro, TV Gabriele).
- Extended `neigh6-agh-sync` with the name-keyed `AGH_NAME_MAP` branch and set
  `AGH_NAME_MAP="iPad Gabriele|iPad"`. Re-ran: `iPad Gabriele` ids now
  `10.10.10.234` + current IPv6/ULA; stale `10.10.10.212` retired; rerun is a
  no-op. Original script kept at `/usr/bin/neigh6-agh-sync.bak-*` on the router
  and in the repo history.
- Fixed `dhcp-metrics.sh`: it wrote to `/var/prometheus` (tmpfs, wiped each
  reboot) without creating it, so the `mv` failed. Now `mkdir -p`s the output
  dir and ignores a failed `mv`. Writes 36 metrics.

Side findings (not caused by this work, not fixed):

- `fw4` emits pre-existing warnings: `@ipset[0] (Roblox)` declares `family any`
  while matching `ip`/`net`, and `@rule[26] (block Roblox)` references that
  unknown set.
- No Prometheus node exporter is installed or listening on `:9100`, so
  `dhcp-metrics.sh` writes to `/var/prometheus/dhcp.prom` for nobody. The
  Grafana router dashboard's `node_*` / `lan_client_*` panels are therefore
  dead until an exporter is installed (README says it was removed from the
  image).
