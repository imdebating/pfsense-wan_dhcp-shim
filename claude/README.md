# Bell Advanced DMZ DHCP shim for pfSense (tardis, ix0)

## Problem

Every 10 minutes the WAN (ix0) is torn down and rebuilt even though the effective WAN state never changes. Each cycle causes about 10 seconds of disruption: `rc.newwanip`, a dpinger restart, a filter reload, two gif0 (HE IPv6) flaps, and DNS interruptions.

## Root cause (measured, not assumed)

Packet capture (12:49 to 14:06 EDT, 9 cycles) and logs show:

- The Giga Hub's Advanced DMZ handoff always issues a fixed **600 s lease** with no option 58/59 (renewal and rebinding times). It ignores the LAN DHCP lease setting.
- dhclient sends its first RENEW at +300 s (the "renewal in 300 seconds" log line is its default of half the lease), then REBIND, about 131 requests in total. **The Hub never answers any of them.** It only answers DISCOVER and the REQUEST that follows an OFFER.
- The lease therefore hits EXPIRE at +600 s every time. In `pfSense-dhclient-script`, EXPIRE deletes the address and routes. The following BOUND arrives with `old_ip_address` empty, takes the `add_new_address` path, sets `changes="yes"`, and calls `pfSctl -c "interface newip ix0"`, which runs `rc.newwanip`.
- All 9 OFFERs and 8 ACKs carried identical values: IP, mask, router, server ID, DNS. The DISCOVER to ACK exchange takes about 0.3 s.
- The native script already skips `rc.newwanip` for an unchanged RENEW or REBIND. It cannot skip it for EXPIRE followed by BOUND.
- Not the cause: TR-069 (six-hourly, does not align) and any renewal-timing option (the Hub ignores renewals regardless of timing).

## Approach

Use the script's supported extension point, `/etc/dhclient-enter-hooks`. It is sourced before `case $reason`, and `exit` from it ends the script. No pfSense file is modified, so there is no patch to reapply.

The shim defers the destructive EXPIRE instead of guessing, because the new lease is unknown at EXPIRE time:

1. **EXPIRE:** snapshot the state and verify the live IP, mask, gateway, routes to the gateway and dpinger monitor, `/tmp/ix0_router`, and `/var/db/ix0_ip`. If everything matches the last recorded lease, skip the native EXPIRE and start a bounded watchdog (default 15 s).
2. **PREINIT:** skip while a deferral is pending.
3. **BOUND:** compare the new lease (IP, mask, routers, DHCP server ID, DNS, domain) to the snapshot and the live routes.
   - Identical: skip the native script. There is no `rc.newwanip`, no dpinger restart, no filter reload, and no gif0 flap.
   - Different or uncertain: replay the native EXPIRE with the saved `old_*` values, then run the native BOUND unchanged.
4. **Any other event, or watchdog timeout:** replay the native teardown and continue natively.

dhclient keeps doing its DHCP exchange with the Hub every cycle, so the Hub is still kept informed.

## Safety properties

- Applies to ix0 only. Nothing is hard-coded: the IP, mask, gateway, server, and monitor are read live, and the monitor comes from the dpinger process.
- Fail-open: no previous record (first install or reboot), malformed data, lock timeout, 20 s hook timeout, unapproved or changed native script hash, classless or static routes, an alias address, or any mismatch all lead to the normal pfSense path.
- No `eval`, no Bash-only syntax. It runs as POSIX `/bin/sh` using only base utilities, with a lock, atomic state writes, and a log at `/var/log/bell-admz.log`.
- Starts in **dry-run** (decisions logged, behaviour unchanged). Enforcement is an explicit `mode enforce`.
- The native script's sha256 is pinned (`approve`). After a pfSense upgrade changes it, the shim goes inert and logs loudly until the compat check passes and you re-approve.
- Instant bypass with `bell-admz-shim.sh disable`, with no reboot. Full removal with `uninstall.sh`.
- Does not touch Unbound, BIND, pfBlockerNG, dpinger, firewall rules, generated config, or WAN addressing, and does not make the WAN static.

## Files

| File | Purpose |
| --- | --- |
| `bell-admz-shim.sh` | Decision logic, installed to `/usr/local/libexec/` |
| `bell-admz-compat.sh` | Read-only check of the native script anchors and base tools |
| `install.sh` | Compat check, backup with checksums, atomic install in dry-run mode |
| `uninstall.sh` | Disable, flush, remove hook and shim (`--purge` also removes config and logs) |
| `bell-admz-verify.sh` | Snapshot of WAN, routes, services, IPsec, BGP, WireGuard, gif0 |
| `bell-admz-monitor.sh` | Watch one lease cycle, optional pcap |

## Usage

```sh
sh install.sh -n                        # dry-run of the installer
sh install.sh --i-have-console          # install (dry-run mode)
sh bell-admz-monitor.sh 1300            # watch two cycles
bell-admz-shim.sh mode enforce          # only after clean DRYRUN lines
bell-admz-shim.sh disable               # instant bypass
sh uninstall.sh                         # remove
```

Expected dry-run lines from the second cycle onward: `DRYRUN EXPIRE: would defer teardown` then `DRYRUN BOUND: would SKIP`. Never test on a production WAN without iLO or VGA console access.

## Limitations

- The stale address stays on ix0 for up to the deferral window (about 2 s in practice) while DHCP re-acquires. If Bell truly changes or drops the address, recovery follows normal pfSense logic after that delay.
- The shim does not remove the Hub's own sub-second lease expiry, and it does not fix the Hub ignoring renewals.
- IPv4 on ix0 only. Classless routes, static routes, and alias addresses take the normal path.
- Open risk: the kernel may send ICMP port-unreachable to the Hub while the address is still configured during OFFER and ACK. Check with `bell-admz-monitor.sh -p` on the first enforced cycle.
- Verified against pfSense CE 2.9.0 (native script sha256 `67a689b0...5409cc`). Re-run the compat check after any upgrade.
