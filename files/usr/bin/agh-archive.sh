#!/bin/sh
# Archive AdGuardHome's rotated query log to compressed cold storage.
# AdGuardHome keeps only querylog.json + querylog.json.1 and never compresses;
# this grabs each rotation before the next one overwrites it.
# Archives are grep-able but NOT searchable in the AdGuardHome web UI.

WORKDIR=/opt/adguardhome
SRC="$WORKDIR/data/querylog.json.1"
ARCHIVE="$WORKDIR/archive"
KEEP_DAYS=90

mkdir -p "$ARCHIVE"

archive_rotation() {
	[ -f "$SRC" ] || return 0

	# Name by the source file's own mtime, not today's date: if the log has not
	# rotated since the last run we simply rewrite the same archive instead of
	# creating a duplicate under a new name.
	STAMP=$(date -r "$SRC" +%Y%m%d)
	DEST="$ARCHIVE/querylog-$STAMP.json.gz"

	# Nothing new since the last run.
	[ -f "$DEST" ] && [ "$DEST" -nt "$SRC" ] && return 0

	if gzip -c "$SRC" > "$DEST.tmp"; then
		mv "$DEST.tmp" "$DEST"
		logger -t agh-archive "archived $(basename "$DEST") ($(wc -c < "$DEST") bytes)"
	else
		rm -f "$DEST.tmp"
		logger -t agh-archive "failed to archive $SRC"
		return 1
	fi
}

# Retention runs unconditionally: it must not be skipped on days when there is
# no new rotation to archive, or old files would never expire.
prune_old() {
	# busybox find has no -delete, so use -exec rm.
	find "$ARCHIVE" -name 'querylog-*.json.gz' -mtime "+$KEEP_DAYS" -exec rm -f {} \;
}

archive_rotation
rc=$?
prune_old
exit $rc
