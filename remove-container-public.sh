#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo remove-docker-public.sh <container-name>
# Example:
#   sudo remove-docker-public.sh valheim

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run with sudo"
[[ $# -eq 1 ]] || die "Usage: $0 <container-name>"

RAW_NAME="$1"
SAFE_NAME="$(echo "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$SAFE_NAME" ]] || die "Invalid container name"

LAN_IFACE="$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[[ -n "${LAN_IFACE:-}" ]] || die "Could not detect LAN interface"

RULESCRIPT="/usr/local/sbin/public-fwrules-${SAFE_NAME}.sh"
UNIT="public-fwrules-${SAFE_NAME}.service"
UNITFILE="/etc/systemd/system/public-fwrules-${SAFE_NAME}.service"
SPEC="/etc/docker-public/${SAFE_NAME}.ports"

# Stop/disable service if present
if systemctl list-unit-files | grep -q "^${UNIT}"; then
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
fi

# Remove iptables rules using spec file if present
if [[ -f "$SPEC" ]]; then
  while IFS= read -r pp; do
    [[ -z "$pp" ]] && continue
    if [[ "$pp" =~ ^([0-9]{1,5})/(tcp|udp)$ ]]; then
      port="${BASH_REMATCH[1]}"
      proto="${BASH_REMATCH[2]}"

      # Delete matching rules repeatedly until none remain (handles duplicates safely)
      for out_if in docker0 br+; do
        while iptables -w -t filter -C DOCKER-USER -i "$LAN_IFACE" -o "$out_if" -p "$proto" --dport "$port" -j RETURN >/dev/null 2>&1; do
          iptables -w -t filter -D DOCKER-USER -i "$LAN_IFACE" -o "$out_if" -p "$proto" --dport "$port" -j RETURN || break
        done
      done
    fi
  done < "$SPEC"
fi

# Remove files
rm -f "$UNITFILE" "$RULESCRIPT" "$SPEC" || true
systemctl daemon-reload

echo "Removed public exceptions for: $RAW_NAME"
echo "Removed:"
echo "  $RULESCRIPT"
echo "  $UNITFILE"
echo "  $SPEC"
