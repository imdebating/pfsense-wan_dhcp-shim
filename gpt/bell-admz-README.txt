Bell ADMZ diagnostic observer v2
================================

Complete sources: bell-admz-observe.sh, bell-admz-install.sh,
bell-admz-uninstall.sh, bell-admz-readonly.sh.
No active DHCP suppression exists in this package.

TARGET
pfSense 2.9.0-RELEASE / supplied FreeBSD 16.0-CURRENT installation.
Native script: /usr/local/sbin/pfSense-dhclient-script
Expected SHA256:
67a689b0855d1ea4f3d4b8e30ae163edb745e0db8c03a672f0542989ff5409cc
Verified executable paths include /bin/timeout and /usr/bin/lockf.
Monitor 1.1.1.1 is explicitly supplied by the operator, not inferred from DHCP.

WHAT CHANGED
* Version pin updated from 2.8.1 to 2.9.0-RELEASE.
* timeout uses /bin/timeout.
* Process selection uses FreeBSD ucomm; the read-only collector also prints
  an unfiltered process table. No ps -C executable selector is used.
* Runtime event directories preserve enter and exit observations separately.
* Each event has a sequence, timestamp, boot identity, and INCOMPLETE marker.
* Up to 200 numbered runtime events are retained. Values over 2048 characters
  are truncated in the event metadata. At most eight old and eight new router
  entries are queried. No resulting comparison authorizes suppression.
* The previous misleading network baseline/equality test is removed.
* New runtime directories are recreated after reboot. Historical observations
  are not trusted or used as a healthy-state baseline.
* Native-script hash and version drift stop collection, not DHCP processing.
* Existing hooks are refused, not overwritten or automatically chained.
* Native script and generated DHCP/Unbound configurations are untouched.

INSTALL
Copy all four source files to /root/bell-admz-src on pfSense.
Run from local console/iLO or a verified independent recovery connection:

/bin/sh -n /root/bell-admz-src/bell-admz-observe.sh
/bin/sh -n /root/bell-admz-src/bell-admz-install.sh
/bin/sh -n /root/bell-admz-src/bell-admz-uninstall.sh
/bin/sh -n /root/bell-admz-src/bell-admz-readonly.sh

/bin/sh /root/bell-admz-src/bell-admz-install.sh --dry-run /root/bell-admz-src 1.1.1.1

Preflight creates/retains administrative and preflight lock files, but no hooks
or native changes. It exercises timeout, lockf, and ps output fields.
The install creates path-preserving root backups and a checksum manifest.
The source hook references must exist or installation refuses.
A hash identifies the observed native file, not proof that its complete current
source has been reviewed. Collect and provide current source for further work.

/bin/sh /root/bell-admz-src/bell-admz-install.sh --install /root/bell-admz-src 1.1.1.1 --console-confirmed

No release, renew, interface apply, restart, or reboot is performed.
An interrupted install stays disabled. Use the uninstall script for published
managed hooks; early partial directories with no hooks can be reviewed manually.
Run administrative operations serially; locks coordinate only these scripts,
not arbitrary edits by other root sessions.

VERIFY
Wait for natural DHCP events.

/usr/bin/tail -F /var/log/system.log
/usr/bin/find /var/run/bell-admz-v2/events -name event.txt -print
/bin/ps -axww -o pid=,ucomm=,lstart=,etime=

Each complete event directory includes address, route, process, and metadata
files. A directory with INCOMPLETE is not a complete observation. Do not equate
missing event files or empty comparisons with unchanged network state.
Observer execution can time out or be skipped because of lock contention.

Manual observation without fabricated lease data, executed in /bin/sh:

/bin/sh -c 'interface=ix0; reason=MANUAL_DIAGNOSTIC; export interface reason; exec /bin/timeout -k 1 2 /bin/sh /usr/local/etc/bell-admz-v2/bell-admz-observe.sh --run diagnostic unavailable'

The native hook runs the observer in a subshell. No native shell variables,
functions, options, traps, or exit_status are changed. It sources no state files.
No eval is used. The observer never invokes the native DHCP script.

DISABLE AND UNINSTALL
/usr/bin/touch /usr/local/etc/bell-admz-v2/disabled
/bin/sh /usr/local/etc/bell-admz-v2/bell-admz-uninstall.sh --check
/bin/sh /usr/local/etc/bell-admz-v2/bell-admz-uninstall.sh --uninstall

Uninstall leaves backups, runtime evidence, lock files, and a disabled install
folder. Reinstallation refuses retained installation/runtime directories until
they have been reviewed and archived manually. Uninstall never restores an old
native file, because this package never patches one. Changed hooks require manual
review; uninstall does not delete another customization. No reboot required.

UPGRADES
Disable/uninstall before upgrading. Do not automatically reapply hooks.
An unexpected version or native SHA256 stops observation and leaves native
DHCP logic untouched. Review the new files, update the explicit pin only after
review, and repeat preflight. This is not upgrade persistence for an active shim.

CAUTIONS
The observer is synchronous: the native script waits for it. timeout requests
termination after two seconds and SIGKILL after one additional second if needed.
Failure logging has its own one-second timeout plus one-second kill grace.
These are intended bounds, not hard real-time guarantees. A failed observation
can therefore add several seconds of delay. Disable if timing is unacceptable.
Snapshots are separate live queries, not an atomic kernel snapshot.
Monitor correspondence is operator-verified, not automatically verified.
The route to 192.168.2.1 in the supplied diagnostic follows the default route;
this alone does not prove an error or establish a static route as a fix.
Existing raw capture evidence already shows unanswered unicast and broadcast
renewal attempts and successful fresh acquisition after 600-second leases.
A retained expired lease is not implemented or endorsed by these observers.
The collector prints complete scripts and DHCP configurations: review for any
confidential custom content before sharing. Runtime evidence is root-only.

TEST STATUS
All four files passed /bin/sh -n in the assistant's execution environment.
This was a POSIX shell syntax check, not execution on pfSense/FreeBSD.
No installer, hook, or observer has been executed on tardis by the assistant.

EXIT STATUSES
Observer/collector/administrative commands use:
0 completed or native-only decline; 64 usage; 65 mismatch/unsafe state;
66 missing source; 69 utility/preflight failure; 73 creation failure;
74 file operation failure; 77 not root; 130/143 interrupted observer.
Timeout and lockf statuses are preserved by administrative launchers.
Native hook exits successfully as a hook and preserves native exit_status.
