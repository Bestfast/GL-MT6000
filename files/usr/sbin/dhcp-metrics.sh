#!/bin/sh
OUT=/var/prometheus/dhcp.prom
# /var is a symlink to /tmp (tmpfs), so the collector directory is gone after a
# reboot until the node exporter recreates it. Create it ourselves so the mv
# below does not fail when the exporter is not (yet) running.
mkdir -p "$(dirname "$OUT")" 2>/dev/null
TMP=$(mktemp /tmp/dhcp.prom.XXXXXX) || exit 0

cat /tmp/dhcp.leases 2>/dev/null | awk '$4 != "*" && $4 != "" { print "lan_client_info{ip=\"" $3 "\",name=\"" $4 "\"} 1"; print "lan_client_mac{mac=\"" toupper($2) "\",name=\"" $4 "\"} 1" }' > "$TMP"
awk '$1 ~ /^10\./ && $2 != "" { print "lan_client_info{ip=\"" $1 "\",name=\"" $2 "\"} 1" }' /etc/hosts >> "$TMP" 2>/dev/null

sort -u "$TMP" > "$TMP.sorted"
if [ -s "$TMP.sorted" ]; then
  mv "$TMP.sorted" "$OUT" 2>/dev/null || true
fi
rm -f "$TMP" "$TMP.sorted"
exit 0
