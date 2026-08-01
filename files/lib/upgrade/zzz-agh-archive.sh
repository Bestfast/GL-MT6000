# Snapshot AdGuardHome's rotated query log into the archive directory just
# before sysupgrade builds its list of files to preserve.
#
# Why this exists: /etc/sysupgrade.conf deliberately does NOT keep
# data/querylog.json.1 (~140 MB). The keep list is tarred into /tmp, which is
# tmpfs = RAM, and this router has 1 GB with no swap. agh-archive.sh gzips
# that log into /opt/adguardhome/archive/ (~14 MB), which IS kept -- so the
# history survives, compressed, without staging 140 MB in RAM.
#
# Without this hook the archive would only be as fresh as the last 03:30 cron
# run, silently losing up to a day of queries on every flash.
#
# Hook mechanism: /sbin/sysupgrade sets $sysupgrade_init_conffiles, then runs
# `include /lib/upgrade` (which sources every *.sh here, alphabetically), then
# calls `run_hooks "$CONFFILES" $sysupgrade_init_conffiles`. run_hooks() in
# common.sh iterates the value as a word list, so prepending our function name
# makes it run before the file list is built. The zzz- prefix guarantees we
# are sourced after whatever set the variable.

agh_archive_before_backup() {
	# `sysupgrade -l` only prints the keep list. Don't spend a minute of CPU
	# gzipping 140 MB just because someone asked what would be preserved.
	[ "${CONF_BACKUP_LIST:-0}" = "1" ] && return 0

	[ -x /usr/bin/agh-archive.sh ] || return 0
	[ -d /opt/adguardhome/data ] || return 0

	echo "Archiving AdGuardHome query log before upgrade..." >&2
	# Never let a failed archive abort the upgrade. The script logs its own
	# errors via logger; worst case we flash with a slightly stale archive.
	/usr/bin/agh-archive.sh || \
		echo "agh-archive.sh failed; continuing with existing archive" >&2

	return 0
}

# Prepend, so the snapshot exists before the keep list is enumerated.
sysupgrade_init_conffiles="agh_archive_before_backup $sysupgrade_init_conffiles"
