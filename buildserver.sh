#!/usr/bin/env bash
set -euo pipefail

##################################################
# build script for phils server			 #
# 						 #
# - debian os					 #
# - cockpit for server management		 #
# - portainer for				 #
# - hardening, firewalld and fail2ban		 #
# - this script can be run multiple times	 #
# - see output at end of script for further info #
##################################################

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run with sudo"; exit 1; }
}

require_root

echo "Detecting IPv4 addresses..."

mapfile -t IPS < <(
  ip -o -4 addr show scope global | awk '{print $2, $4}'
)

[[ ${#IPS[@]} -gt 0 ]] || { echo "No IPv4 addresses found"; exit 1; }

echo
echo "Select the LAN IP to base the configuration on:"
i=1
for entry in "${IPS[@]}"; do
  iface="${entry%% *}"
  cidr="${entry##* }"
  ip="${cidr%%/*}"
  echo "  [$i] $iface  →  $ip/$cidr"
  ((i++))
done

echo
read -rp "Enter number: " choice
(( choice >= 1 && choice <= ${#IPS[@]} )) || { echo "Invalid choice"; exit 1; }

SELECTED="${IPS[$((choice-1))]}"
LAN_IFACE="${SELECTED%% *}"
LAN_CIDR_FULL="${SELECTED##* }"
LAN_IP="${LAN_CIDR_FULL%%/*}"
LAN_PREFIX="${LAN_CIDR_FULL##*/}"

echo
echo "Selected:"
echo "  Interface : $LAN_IFACE"
echo "  IP        : $LAN_IP"
echo "  CIDR      : $LAN_IP/$LAN_PREFIX"

# ------------------------------------------------------------
# Infer subnet (network address)
# ------------------------------------------------------------
LAN_SUBNET="$(ipcalc -n "$LAN_CIDR_FULL" | awk -F= '/NETWORK/ {print $2}')/$LAN_PREFIX"

echo "  Subnet    : $LAN_SUBNET"
echo

read -rp "Proceed with updating system to this LAN? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# ------------------------------------------------------------
# firewalld: update home zone source
# ------------------------------------------------------------
echo
echo "Updating firewalld home zone..."

# Remove old home sources
mapfile -t OLD_SOURCES < <(
  firewall-cmd --permanent --zone=home --list-sources
)

for src in "${OLD_SOURCES[@]}"; do
  [[ -n "$src" ]] && firewall-cmd --permanent --zone=home --remove-source="$src"
done

firewall-cmd --permanent --zone=home --add-source="$LAN_SUBNET"

# ------------------------------------------------------------
# firewalld: update DOCKER-USER rules
# ------------------------------------------------------------
echo
echo "Updating DOCKER-USER rules..."

mapfile -t RULES < <(
  firewall-cmd --permanent --direct --get-all-rules | grep 'DOCKER-USER' || true
)

for rule in "${RULES[@]}"; do
  firewall-cmd --permanent --direct --remove-rule $rule || true
done

# Re-add baseline rules with new iface/CIDR
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 \
  -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 1 \
  -i docker0 -j RETURN
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 1 \
  -i br+ -j RETURN

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 2 \
  -i "$LAN_IFACE" -s "$LAN_SUBNET" -o docker0 -j RETURN
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 2 \
  -i "$LAN_IFACE" -s "$LAN_SUBNET" -o br+ -j RETURN

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 10 \
  -i "$LAN_IFACE" -o docker0 -j DROP
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 10 \
  -i "$LAN_IFACE" -o br+ -j DROP

# ------------------------------------------------------------
# Update Docker containers bound to old LAN IPs
# ------------------------------------------------------------
echo
echo "Scanning containers for old LAN IP bindings..."

mapfile -t CONTAINERS < <(docker ps -q)

for c in "${CONTAINERS[@]}"; do
  mapfile -t BINDS < <(
    docker inspect "$c" \
      --format '{{range .HostConfig.PortBindings}}{{range .}}{{.HostIp}}{{end}}{{end}}'
  )

  for ip in "${BINDS[@]}"; do
    [[ "$ip" == "0.0.0.0" || -z "$ip" ]] && continue
    [[ "$ip" == "$LAN_IP" ]] && continue

    echo
    echo "Container $c is bound to old IP $ip"
    echo "You must recreate this container to bind to $LAN_IP"
    echo "Skipping automatic change (Docker limitation)."
  done
done

# ------------------------------------------------------------
# Apply firewall changes
# ------------------------------------------------------------
firewall-cmd --reload

echo
echo "✔ LAN network update complete"
echo
echo "Summary:"
echo "  Interface : $LAN_IFACE"
echo "  IP        : $LAN_IP"
echo "  Subnet    : $LAN_SUBNET"
echo
echo "NOTE:"
echo "- Containers bound to old IPs must be recreated"
echo "- Containers bound to 0.0.0.0 are unaffected"
