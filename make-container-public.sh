#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo make-docker-public.sh <container-name> <port/proto> [<port/proto> ...]
# Example:
#   sudo make-docker-public.sh valheim 2456/udp 2457/udp 2458/udp

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run with sudo"
[[ $# -ge 2 ]] || die "Usage: $0 <container-name> <port/proto> [more...]"

RAW_NAME="$1"; shift

# sanitize name for filenames/systemd units
SAFE_NAME="$(echo "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$SAFE_NAME" ]] || die "Invalid container name"

LAN_IFACE="$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[[ -n "${LAN_IFACE:-}" ]] || die "Could not detect LAN interface"

RULESCRIPT="/usr/local/sbin/public-fwrules-${SAFE_NAME}.sh"
UNIT="/etc/systemd/system/public-fwrules-${SAFE_NAME}.service"
SPEC="/etc/docker-public/${SAFE_NAME}.ports"

mkdir -p /etc/docker-public

# Validate and normalize ports
PORTS=()
for pp in "$@"; do
  if [[ ! "$pp" =~ ^([0-9]{1,5})/(tcp|udp)$ ]]; then
    die "Bad port/proto: '$pp' (expected like 2456/udp)"
  fi
  port="${BASH_REMATCH[1]}"
  proto="${BASH_REMATCH[2]}"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: $port"
  PORTS+=("${port}/${proto}")
done

# Write spec file (used for removal)
printf "%s\n" "${PORTS[@]}" > "$SPEC"

# Write rules script
cat > "$RULESCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LAN_IFACE="${LAN_IFACE}"
# Reference name only:
CONTAINER_NAME="${RAW_NAME}"

# Ports to allow public access to:
PORTS=(
$(printf "  %q\n" "${PORTS[@]}")
)

# Ensure DOCKER-USER exists and is in path
iptables -w -t filter -L DOCKER-USER >/dev/null 2>&1 || iptables -w -t filter -N DOCKER-USER
iptables -w -t filter -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -w -t filter -I FORWARD 1 -j DOCKER-USER

add_rule() {
  local out_if="\$1" proto="\$2" dport="\$3"
  # Insert near the top so it sits above the DROP rules added by docker-lan-only
  iptables -w -t filter -C DOCKER-USER -i "\$LAN_IFACE" -o "\$out_if" -p "\$proto" --dport "\$dport" -j RETURN >/dev/null 2>&1 \
    || iptables -w -t filter -I DOCKER-USER 1 -i "\$LAN_IFACE" -o "\$out_if" -p "\$proto" --dport "\$dport" -j RETURN
}

for pp in "\${PORTS[@]}"; do
  port="\${pp%/*}"
  proto="\${pp#*/}"
  add_rule docker0 "\$proto" "\$port"
  add_rule br+    "\$proto" "\$port"
done
EOF

chmod 0755 "$RULESCRIPT"

# Write systemd unit
cat > "$UNIT" <<EOF
[Unit]
Description=Public Docker port exceptions for ${RAW_NAME}
Requires=docker.service docker-lan-only.service
After=docker.service docker-lan-only.service

[Service]
Type=oneshot
ExecStart=${RULESCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "public-fwrules-${SAFE_NAME}.service"
systemctl restart "public-fwrules-${SAFE_NAME}.service"

echo "Created:"
echo "  $RULESCRIPT"
echo "  $UNIT"
echo "Enabled/started: public-fwrules-${SAFE_NAME}.service"
echo "Ports made public (iptables DOCKER-USER RETURN rules): ${PORTS[*]}"
