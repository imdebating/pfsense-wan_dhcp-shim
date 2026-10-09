## 1. Findings that change the implementation

Your latest output establishes:

| Item | Actual installation |
|---|---|
| pfSense version | `2.9.0-RELEASE`, not `2.8.1` |
| Operating system | FreeBSD `16.0-CURRENT` |
| Active DHCP configuration | `/var/etc/dhclient_wan.conf` |
| Configured event script | `/usr/local/sbin/pfSense-dhclient-script` |
| WAN handler | `/etc/rc.newwanip` |
| Link handler | `/etc/rc.linkup` |
| Timeout utility | `/bin/timeout` |
| Lock utility | `/usr/bin/lockf` |
| Existing DHCP hooks | None reported |
| Previous observer installation | None reported |
| Current monitor | `1.1.1.1` |

The revised installer is pinned to this native DHCP script checksum:

```text
67a689b0855d1ea4f3d4b8e30ae163edb745e0db8c03a672f0542989ff5409cc
```

It refuses another pfSense version or a changed native script. The observer likewise stops collecting when either changes; native DHCP processing continues.

### Why the process sections were empty

My previous explanation of `comm` was insufficient. FreeBSD documents `ucomm` as the process accounting name that can be depended upon. The updated filtering uses that field, and the read-only collector also prints an unfiltered process table so a failed filter cannot masquerade as “no processes running.” [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1&format=html)

The corrected command is:

```sh
/bin/ps -axww -o pid=,ucomm=,args= |
    /usr/bin/awk '$2 == "dhclient" || $2 == "dpinger"'
```

### What the DHCP-server route means

Your lookup shows:

```text
192.168.2.1
  → default route
  → 142.124.36.154
  → ix0
```

There is no dedicated host route to `192.168.2.1` in the supplied routing table. That alone does not establish an error or justify adding one. The existing packet evidence already showed renewal requests addressed to the hub at Ethernet level.

The updated observers record both event-derived server routes and live gateway routes. They do not modify either.

## 2. Complete updated code

Use the final archive named `bell-admz-v2-complete-source.zip`. It contains the final, unabridged versions of:

| File | Updated purpose |
|---|---|
| `bell-admz-observe.sh` | Passive DHCP-event collector |
| `bell-admz-install.sh` | Version/checksum-guarded observer installation |
| `bell-admz-uninstall.sh` | Verified hook removal and rollback |
| `bell-admz-readonly.sh` | Corrected read-only collection, including current native source |
| `bell-admz-README.txt` | Complete operational instructions and limitations |
| `bell-admz-SHA256.txt` | Checksums for the four scripts |

Use the files inside that final archive rather than any earlier individual script attachment: the final archive includes the last corrections for reboot handling and retention of interrupted observations.

### Changes applied across the code

- Replaced the `2.8.1` version requirement with the observed `2.9.0-RELEASE`.
- Replaced `/usr/bin/timeout` with the observed `/bin/timeout`.
- Removed Linux-style executable selection with `ps -C`.
- Replaced executable-name filtering on `comm` with `ucomm`.
- Added an unfiltered process-name/start-time listing.
- Removed the misleading previous-network equality test.
- Added separate numbered directories for enter and exit observations.
- Added sequence number, timestamp, boot identity, event phase, and native status.
- Added an `INCOMPLETE` marker that remains when collection is interrupted.
- Retained up to 200 numbered runtime events.
- Added runtime-directory recreation after reboot.
- Added nonblocking observation locking.
- Added serialized installation/uninstallation.
- Preserved path-separated backups so identically named native files do not overwrite each other.
- Preserved native `exit_status` by isolating observation in a subshell.
- Kept all native scripts, generated DHCP configuration, DNS configuration, routes, and service settings unchanged.

No unified diff is needed because the native DHCP script is not patched. The installer creates the two external hooks only if neither already exists and both sourced-hook references are present in the checksum-pinned native script.

## 3. Preflight and installation

Extract the archive on your workstation, and copy the four scripts into:

```text
/root/bell-admz-src/
```

Run from the local console, iLO, or another verified independent recovery connection.

### Syntax checks on pfSense

```sh
/bin/sh -n /root/bell-admz-src/bell-admz-observe.sh
/bin/sh -n /root/bell-admz-src/bell-admz-install.sh
/bin/sh -n /root/bell-admz-src/bell-admz-uninstall.sh
/bin/sh -n /root/bell-admz-src/bell-admz-readonly.sh
```

### Installation preflight

```sh
/bin/sh /root/bell-admz-src/bell-admz-install.sh \
    --dry-run /root/bell-admz-src 1.1.1.1
```

Here, `1.1.1.1` is the configured monitor from your logs, not a DHCP gateway or server override.

Preflight:

- Checks the version and native checksum.
- Checks both native sourced-hook references.
- Refuses existing hooks.
- Checks required utilities.
- Exercises `timeout`, nonblocking `lockf`, and the process output format.
- Installs no hooks.

It may create retained administrative/preflight lock files under `/var/run/`. Those are not WAN configuration changes. FreeBSD documents `lockf -t 0` as immediate acquisition or failure, and `-k` as retaining the lock file. [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=lockf)

### Install passive observation

```sh
/bin/sh /root/bell-admz-src/bell-admz-install.sh \
    --install /root/bell-admz-src 1.1.1.1 --console-confirmed
```

Installation does not release or renew the lease, apply WAN settings, restart a service, or reboot.

The earlier successful DHCP observations were collected without my observer hooks installed. Your output therefore rules out those hooks as the cause of the already recorded disruption.

## 4. Event collection and verification

### Follow decisions

```sh
/usr/bin/tail -F /var/log/system.log
```

Look for the tag:

```text
bell-admz-v2
```

Each observation logs `STARTED` and, if completed, `COMPLETED`.

### Locate retained event metadata

```sh
/usr/bin/find /var/run/bell-admz-v2/events \
    -name event.txt -print
```

Each numbered event directory contains:

- DHCP-variable presence indicators, values, and raw comparisons.
- Event phase, reason, and native status.
- `ix0` and `gif0` state.
- Default, server, gateway, and monitor route lookups.
- Native WAN cache values.
- Process start times.
- DHCP-client and dpinger arguments.

A remaining `INCOMPLETE` file means collection did not finish. Missing or incomplete observations must not be interpreted as an unchanged WAN.

### Manual diagnostic observation

This explicitly invokes `/bin/sh`, so it can be launched from pfSense’s surrounding console shell:

```sh
/bin/sh -c '
    interface=ix0
    reason=MANUAL_DIAGNOSTIC
    export interface reason

    exec /bin/timeout -k 1 2 \
        /bin/sh /usr/local/etc/bell-admz-v2/bell-admz-observe.sh \
        --run diagnostic unavailable
'
```

It does not invent old/new DHCP data. Those fields will be unavailable outside an actual DHCP event.

### Collect the current native source

```sh
/bin/sh /root/bell-admz-src/bell-admz-readonly.sh
```

This version prints the current native scripts and complete existing DHCP configuration. Review any custom confidential content before sharing the output.

That source is still needed before an active design can be reviewed. A checksum identifies the installed file; it does not establish that the previously pasted source is byte-for-byte the current 2.9.0 implementation.

## 5. Disable, uninstall, and upgrades

### Disable collection immediately

```sh
/usr/bin/touch /usr/local/etc/bell-admz-v2/disabled
```

Native DHCP processing remains enabled throughout.

### Verify rollback eligibility

```sh
/bin/sh /usr/local/etc/bell-admz-v2/bell-admz-uninstall.sh --check
```

### Remove observer hooks

```sh
/bin/sh /usr/local/etc/bell-admz-v2/bell-admz-uninstall.sh --uninstall
```

Uninstall:

- Disables collection first.
- Verifies each existing hook against the installed expected contents.
- Refuses to remove a changed/customized hook.
- Removes only the managed hooks.
- Leaves backups, evidence, and the disabled installation directory.
- Does not restore an older native script, since installation never changed one.
- Requires no reboot or DHCP restart.

Before a pfSense upgrade, uninstall the hooks. Do not automatically reapply them afterward. Review the new native source and checksum first.

## 6. Remaining limitations and confidence

These observers are synchronous: the native script waits for them. The observation timeout requests termination after two seconds and permits one additional second before forced termination. Failure logging has its own bounded call. These are intended execution bounds, not hard real-time guarantees. [man.freebsd](https://man.freebsd.org/cgi/man.cgi?query=timeout)

Therefore:

- A stalled observation can still add several seconds.
- Lock contention can skip an observation.
- Individual route queries are not an atomic kernel snapshot.
- The monitor is operator-supplied, not automatically reconciled against configuration.
- Static/classless-route values are recorded, not interpreted into a suppression decision.
- Nothing here makes an expired lease valid or eliminates the ten-minute interruption.

All four final scripts passed `/bin/sh -n` in my execution environment. The final archive was also checked against the final source files. Those are syntax and packaging checks—not execution on FreeBSD or on `tardis`.

| Assessment | Updated confidence |
|---|---:|
| Target version and supplied native checksum are correctly reflected | 99% |
| Commands use the supplied paths and FreeBSD-compatible options | 97% |
| Corrected read-only collector will obtain useful evidence | 95% |
| Passive hook installation/collection will operate correctly on `tardis` after successful preflight | 85% |
| The supplied code implements no active expiry suppression | 100% |
| A safe outage-prevention shim has been validated | Not established |

The next decisive evidence is the complete current native script plus retained `EXPIRE`, `PREINIT`, and `BOUND` enter/exit observations—not another guessed route or an IP-only suppression test.