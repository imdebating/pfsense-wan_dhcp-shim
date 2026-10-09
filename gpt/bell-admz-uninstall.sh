#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077
BASE=/usr/local/etc/bell-admz-v2
case "${1-}" in --check|--uninstall) ;; *) printf '%s\n' 'Usage: bell-admz-uninstall.sh --check|--uninstall' >&2; exit 64 ;; esac
mode=$1
[ "$(/usr/bin/id -u)" = 0 ] || exit 77
if [ "${BELL_ADMZ_ADMIN_LOCKED-}" != yes ]; then
    BELL_ADMZ_ADMIN_LOCKED=yes; export BELL_ADMZ_ADMIN_LOCKED
    exec /bin/timeout -k 1 15 /usr/bin/lockf -k -t 0 \
        /var/run/bell-admz-v2-admin.lock /bin/sh "$0" "$@"
fi
[ -d "$BASE" ] && [ ! -L "$BASE" ] || exit 65
[ "$(/usr/bin/stat -f '%u:%Lp' "$BASE")" = 0:700 ] || exit 65
identifier=
IFS= read -r identifier < "$BASE/installation-id" || :
[ "$identifier" = bell-admz-observer-v2 ] || exit 65
if [ "$mode" = --uninstall ]; then
    : > "$BASE/disabled" || exit 73
fi
verify()
{
    actual=$1; expected=$2
    if [ ! -e "$actual" ] && [ ! -L "$actual" ]; then
        printf 'Already absent: %s\n' "$actual"; return 0
    fi
    [ -f "$actual" ] && [ ! -L "$actual" ] && [ -f "$expected" ] &&
        /usr/bin/cmp -s "$actual" "$expected" || {
            printf 'Changed/nonregular hook: %s. Manual review required; nothing removed.\n' "$actual" >&2
            return 1
        }
    printf 'Verified managed hook: %s\n' "$actual"
}
verify /etc/dhclient-enter-hooks "$BASE/enter-hook.expected" || exit 65
verify /etc/dhclient-exit-hooks "$BASE/exit-hook.expected" || exit 65
[ "$mode" = --uninstall ] || { printf '%s\n' 'Uninstall preflight passed.'; exit 0; }
/bin/rm -f /etc/dhclient-enter-hooks /etc/dhclient-exit-hooks || exit 74
printf '%s\n' 'Hooks removed; native DHCP and configuration files unchanged.' \
    'Disabled installation directory, event evidence, backups, and lock files retained.' \
    'No reboot or DHCP restart required. Allow an already-running observer to finish.'
exit 0
