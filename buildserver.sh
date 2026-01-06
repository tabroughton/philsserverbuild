#!/usr/bin/env bash
set -euo pipefail

##################################################
# build script for phils server
#
# - debian os
# - cockpit for server management
# - portainer for containers
# - hardening, firewalld and fail2ban
# - this script can be run multiple times
# - see output at end of script for further info
##################################################

# ---------------- USER SETTINGS ----------------
TIMEZONE="Europe/London"
LAN_CIDR="192.168.4.0/24"

ADMIN_USER="philadmin"

PORTAINER_HTTPS_PORT="9443"
COCKPIT_PORT="9090"

PORTAINER_VOL="portainer_data"

AUTO_REBOOT="true"
AUTO_REBOOT_TIME="03:30"

HARDEN_SSH="true"

DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="3"
# ------------------------------------------------

# ---------------- Helpers ----------------
log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\n\033[1;33m==>\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*"; exit 1; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run with sudo"; }

detect_debian() {
  source /etc/os-release || die "Cannot detect OS"
  [[ "$ID" == "debian" ]] || die "Debian only"
}

apt_install_if_missing() {
  local pkgs=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p"); done
  [[ ${#pkgs[@]} -eq 0 ]] || apt-get install -y "${pkgs[@]}"
}

detect_lan_iface() {
  ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

fw_add_port_home_once() {
  local portproto="$1"
  firewall-cmd --permanent --zone=home --query-port="$portproto" >/dev/null 2>&1 \
    || firewall-cmd --permanent --zone=home --add-port="$portproto" >/dev/null
}

fw_add_source_home_once() {
  local cidr="$1"
  firewall-cmd --permanent --zone=home --query-source="$cidr" >/dev/null 2>&1 \
    || firewall-cmd --permanent --zone=home --add-source="$cidr" >/dev/null
}
# ------------------------------------------------

require_root
detect_debian

LAN_IFACE="$(detect_lan_iface)"
[[ -n "$LAN_IFACE" ]] || die "Could not detect LAN interface"

# ---------------- Base system ----------------
log "Setting timezone"
timedatectl set-timezone "$TIMEZONE" || true

log "Updating base packages"
apt-get update -y
apt_install_if_missing ca-certificates curl gnupg lsb-release apt-transport-https

# ---------------- Firewall: firewalld ----------------
log "Replacing UFW with firewalld"

if dpkg -s ufw >/dev/null 2>&1; then
  systemctl stop ufw >/dev/null 2>&1 || true
  systemctl disable ufw >/dev/null 2>&1 || true
  ufw --force disable >/dev/null 2>&1 || true
  apt-get purge -y ufw >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
fi

apt_install_if_missing firewalld
systemctl enable --now firewalld

# ---------------- Docker ----------------
log "Installing Docker"

install -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF

apt-get update -y
apt_install_if_missing docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Ensure firewalld starts before Docker
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-firewalld.conf <<EOF
[Unit]
Requires=firewalld.service
After=firewalld.service
EOF
systemctl daemon-reload

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "$DOCKER_LOG_MAX_SIZE",
    "max-file": "$DOCKER_LOG_MAX_FILE"
  }
}
EOF

systemctl enable --now docker
systemctl restart docker

# ---------------- Cockpit ----------------
log "Installing Cockpit"
apt_install_if_missing cockpit
systemctl enable --now cockpit.socket

# ---------------- Fail2ban ----------------
log "Installing Fail2ban"
apt_install_if_missing fail2ban
systemctl enable --now fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl restart fail2ban

# ---------------- SSH hardening ----------------
if [[ "$HARDEN_SSH" == "true" ]]; then
  log "Hardening SSH"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
fi

# ---------------- Portainer ----------------
log "Deploying Portainer"
docker volume create "$PORTAINER_VOL" >/dev/null 2>&1 || true
docker rm -f portainer >/dev/null 2>&1 || true

docker run -d \
  --name portainer \
  --restart=always \
  -p "$PORTAINER_HTTPS_PORT:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PORTAINER_VOL:/data" \
  portainer/portainer-ce:latest

# ---------------- firewalld rules ----------------
log "Configuring firewalld zones"

firewall-cmd --permanent --set-default-zone=public >/dev/null

fw_add_source_home_once "$LAN_CIDR"

fw_add_port_home_once "22/tcp"
fw_add_port_home_once "${COCKPIT_PORT}/tcp"
fw_add_port_home_once "${PORTAINER_HTTPS_PORT}/tcp"

# Persist DOCKER-USER policy via /etc/firewalld/direct.xml
log "Persisting Docker LAN-only policy in /etc/firewalld/direct.xml"

install -d /etc/firewalld

cat > /etc/firewalld/direct.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<direct>
  <!-- Script-owned rules (LAN-only by default). Manual rules: use priority >= 30. -->

  <!-- Allow established/related -->
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="10">-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN</rule>

  <!-- Allow traffic originating from docker bridges (egress / bridge traffic) -->
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="11">-i docker0 -j RETURN</rule>
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="11">-i br+ -j RETURN</rule>

  <!-- Allow LAN to reach published container ports (forwarded to docker bridges) -->
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="12">-i ${LAN_IFACE} -s ${LAN_CIDR} -o docker0 -j RETURN</rule>
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="12">-i ${LAN_IFACE} -s ${LAN_CIDR} -o br+ -j RETURN</rule>

  <!-- Drop non-LAN attempting to reach containers via published ports -->
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="19">-i ${LAN_IFACE} -o docker0 -j DROP</rule>
  <rule ipv="ipv4" table="filter" chain="DOCKER-USER" priority="19">-i ${LAN_IFACE} -o br+ -j DROP</rule>
</direct>
EOF

# Reload firewalld to apply direct.xml + permanent changes
firewall-cmd --reload >/dev/null

# ---------------- README ----------------
log "Writing firewall README"
install -d /opt
cat > /opt/README-firewall.md <<EOF
# Docker + firewalld quick guide

## A) LAN-only container (default)
In Portainer:
- Publish port
- Host IP: <SERVER_LAN_IP> (e.g. ${LAN_CIDR%/*}.*)
- Host Port / Container Port: as needed

Result:
- LAN access only
- No firewall changes needed

---

## B) LAN + Public container

### 1) Portainer
- Host IP: 0.0.0.0
- Publish port normally

### 2) Host firewall (manual public exception)
Add rules with priority >= 30 so scripts won't overwrite them.

Example (TCP 8080):
sudo firewall-cmd --direct --add-rule ipv4 filter DOCKER-USER 30 -i ${LAN_IFACE} -o docker0 -p tcp --dport 8080 -j RETURN
sudo firewall-cmd --direct --add-rule ipv4 filter DOCKER-USER 30 -i ${LAN_IFACE} -o br+    -p tcp --dport 8080 -j RETURN

To make it persistent, add the same <rule> lines to /etc/firewalld/direct.xml (priority >= 30), then:
sudo firewall-cmd --reload

### 3) Router
Forward the same port to this host.
EOF

# ---------------- Done ----------------
IP="$(hostname -I | awk '{print $1}')"

log "Bootstrap complete"
echo "------------------------------------------------------------"
echo "Cockpit:   https://$IP:$COCKPIT_PORT"
echo "Portainer: https://$IP:$PORTAINER_HTTPS_PORT"
echo "Firewall notes: /opt/README-firewall.md"
echo "------------------------------------------------------------"
