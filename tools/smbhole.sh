#!/bin/bash
#
# smbhole.sh — instantly toggle a silent "blackhole" on SMB traffic using macOS pf.
#
# Mechanism (same as the reliable manual version):
#   - load a ruleset that silently drops both directions to the SMB server, then
#   - toggle with `pfctl -e` (enforce = blackhole ON) / `pfctl -d` (disable pf =
#     instant restore). Rules stay loaded, so toggling is just enable/disable.
#
# "block drop" (NOT "block return") = silent drop = the worst-case poll() hang,
# i.e. the "Finder completely unresponsive" case (a RST would fast-fail instead).
#
# Usage:
#   sudo ./smbhole.sh [ip]        # interactive: SPACE=toggle, s=status, q=quit(+restore)
#   sudo ./smbhole.sh on  [ip]    # one-shot ON
#   sudo ./smbhole.sh off         # one-shot OFF (restore)
#   sudo ./smbhole.sh toggle [ip]
#   sudo ./smbhole.sh status
#
# NOTE: `pfctl -f` replaces the active ruleset for the duration of the test.
# Fine on a dev/test machine (macOS ships with pf disabled). `off`/`q` restores
# /etc/pf.conf and disables pf.

set -uo pipefail

PORT="${SMBHOLE_PORT:-445}"

die() { echo "error: $*" >&2; exit 1; }
[[ "$(uname)" == "Darwin" ]] || die "macOS only"
if [[ $EUID -ne 0 ]]; then exec sudo -- "$0" "$@"; fi

detect_ip() {
    netstat -an -p tcp 2>/dev/null \
        | awk -v p=".$PORT " '$0 ~ p && /ESTABLISHED/ {print $5}' \
        | sed "s/\.$PORT\$//" | sort -u | head -n1
}

# Load the blackhole ruleset (idempotent). Does NOT enforce until `pfctl -e`.
load_rules() {
    local ip="$1"
    [[ -n "$ip" ]] || die "no target IP (mount the share first, or pass an IP)"
    printf 'block drop quick proto tcp from any to %s port %s\nblock drop quick proto tcp from %s port %s to any\n' \
        "$ip" "$PORT" "$ip" "$PORT" | pfctl -f - 2>/dev/null \
        || die "failed to load pf rules"
}

hole_on() {
    local ip="$1"
    load_rules "$ip"
    pfctl -e 2>/dev/null
    echo "🕳  BLACKHOLE ON  → $ip:$PORT (silent drop)"
}

hole_off() {
    pfctl -d 2>/dev/null
    echo "✅ BLACKHOLE OFF → pf disabled, traffic restored"
}

is_on() { pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; }

status() {
    if is_on; then echo "state: ON"; pfctl -sr 2>/dev/null | sed 's/^/  /'
    else echo "state: OFF"; fi
}

restore() {
    pfctl -f /etc/pf.conf 2>/dev/null || true
    pfctl -d 2>/dev/null || true
    echo "🧹 restored /etc/pf.conf, pf disabled"
}

cmd="${1:-interactive}"
case "$cmd" in
    on)      hole_on "${2:-$(detect_ip)}";;
    off)     hole_off;;
    toggle)  if is_on; then hole_off; else hole_on "${2:-$(detect_ip)}"; fi;;
    status)  status;;
    cleanup|restore) restore;;
    interactive)
        ip="${2:-$(detect_ip)}"
        if [[ -z "$ip" ]]; then
            echo "⚠️  couldn't auto-detect an SMB peer (nothing mounted?)."
            read -rp "enter target IP: " ip
        fi
        [[ -n "$ip" ]] || die "no target IP"
        trap 'echo; restore; exit 0' INT TERM
        load_rules "$ip"          # preload once; toggling is just -e/-d
        pfctl -d 2>/dev/null       # known OFF start
        echo "target: $ip:$PORT"
        echo "controls: [space]=toggle  [s]=status  [q]=quit(+restore)"
        echo "✅ OFF"
        while true; do
            sudo -nv 2>/dev/null || true
            IFS= read -rsn1 key || break
            case "$key" in
                ' '|'') if is_on; then hole_off; else hole_on "$ip"; fi;;
                s|S)    status;;
                q|Q)    restore; exit 0;;
            esac
        done
        ;;
    *) exec "$0" interactive "$cmd";;
esac
