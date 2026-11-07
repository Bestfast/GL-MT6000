#!/bin/sh
# Restart the CrowdSec firewall bouncer if it is running but enforcing nothing.
#
# Why this exists: on 2026-07-29 the LAPI on npm.lan was rebuilt. The bouncer
# logged "auth with api key failed ... connection refused", reconnected once the
# LAPI came back, and carried on pulling decisions -- but its nftables set
# management never recovered. For three days it pulled ~26k decisions and threw
# them away, logging:
#
#   unable to commit add decisions failed to get current state:
#   receiveAckAware: netlink receive: no such file or directory
#
# The sets sat empty and the router dropped nothing. A plain service restart
# fixes it instantly. Nothing in the bouncer detects the condition itself, and
# it recurs on every LAPI restart, so this checks for it.
#
# Signal used: the per-origin sets exist but hold no elements. A bouncer that
# has pulled at least once always has entries -- CAPI alone supplies ~26k.

TABLE="ip crowdsec"
STATE_DIR=/tmp/crowdsec-watchdog
MAX_RESTARTS_PER_DAY=6

/etc/init.d/crowdsec-firewall-bouncer enabled || exit 0
pgrep -f cs-firewall-bouncer >/dev/null 2>&1 || exit 0

# grep -q closes the pipe on first match, so nft stops emitting early and we
# never materialise all 26k elements.
has_elements() {
	for s in crowdsec-blacklists-CAPI crowdsec-blacklists-crowdsec crowdsec-blacklists; do
		if nft list set $TABLE "$s" 2>/dev/null | grep -q 'elements = '; then
			return 0
		fi
	done
	return 1
}

has_elements && exit 0

# Rate-limit restarts: if the bouncer is crash-looping or the LAPI is simply
# down, restarting every 15 minutes forever helps nobody and fills the log.
mkdir -p "$STATE_DIR"
today=$(date +%Y%m%d)
counter="$STATE_DIR/restarts.$today"
rm -f "$STATE_DIR"/restarts.* 2>/dev/null
[ -f "$counter" ] || echo 0 > "$counter"
count=$(cat "$counter")

if [ "$count" -ge "$MAX_RESTARTS_PER_DAY" ]; then
	logger -t crowdsec-watchdog "sets still empty but already restarted $count times today, giving up until tomorrow"
	exit 1
fi

echo $((count + 1)) > "$counter"
logger -t crowdsec-watchdog "bouncer running but nftables sets are empty, restarting (attempt $((count + 1)) today)"
/etc/init.d/crowdsec-firewall-bouncer restart

sleep 20
if has_elements; then
	logger -t crowdsec-watchdog "recovered, sets repopulated"
else
	logger -t crowdsec-watchdog "WARNING: sets still empty after restart, check LAPI reachability at $(uci -q get crowdsec.@bouncer[0].api_url)"
fi
