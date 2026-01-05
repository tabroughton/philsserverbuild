#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Secure headless Docker host bootstrap (Debian 13.x stable)
#
# Assumes:
# - Existing admin sudo user: philadmin
# - Script is run via sudo
# - Server is accessed via IP address ONLY
# - /etc/hosts is managed manually (script does NOT touch it)
#
# Installs/configures:
# - Docker Engine + Compose plugin
# - Portainer CE + Dockge (web UIs)
# - Cockpit (host monitoring/admin)
# - UFW firewall (LAN-only management)
# - Unattended security updates (+ optional reboot)
# - Fail2ban (SSH protection)
# - SSH hardening (safe, key-aware)
#
# Explicitly NOT included:
# - Avahi / mDNS
# - Hostname discovery
# ============================================================

# ---- YOUR SETTINGS ----
TIMEZONE="Europe/London"
LAN_CIDR="192.168.4.0/24"

ADMIN_USER="philadmin"

PORTAINER_HTTPS_PORT="9443"
DOCKGE_PORT="5001"
COCKPIT_PORT="9090"

STACKS_DIR="/opt/stacks"
DOCKGE_DIR="/opt/dockge"
PORTAINER_VOL="portainer_data"

AUTO_REBOOT="true"
AUTO_REBOOT_TIME="03:30"

HARDEN_SSH="true"

DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="3"

# ---- Helpers ----
log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\n\033[1;33m==>\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*"; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run with sudo"
}

detect_debian() {
  source /etc/os-release || die "Cannot detect OS"
  [[ "$ID" == "debian" ]] || die "This script supports Debian only"
  [[ -n "${VERSION_CODENAME:-}" ]] || die "VERSION_CODENAME missing"
}

ensure_admin_user_exists() {
  id "$ADMIN_USER" >/dev/null 2>&1 || die "Admin user $ADMIN_USER does not exist"
  id -nG "$ADMIN_USER" | grep -qw sudo || warn "$ADMIN_USER is not in sudo group"
}

has_admin_ssh_key() {
  local home
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  [[ -s "$home/.ssh/authorized_keys" ]]
}

apt_install_if_missing() {
  local pkgs=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  [[ ${#pkgs[@]} -eq 0 ]] || apt-get install -y "${pkgs[@]}"
}

# ---- Start ----
require_root
detect_debian
ensure_admin_user_exists

log "Setting timezone"
timedatectl set-timezone "$TIMEZONE" || true

log "Updating base packages"
apt-get update -y
apt_install_if_missing ca-certificates curl gnupg lsb-release apt-transport-https ufw

# ---- Docker ----
log "Installing Docker (official repo)"
install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF

apt-get update -y
apt_install_if_missing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

log "Configuring Docker log rotation"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "$DOCKER_LOG_MAX_SIZE",
    "max-file": "$DOCKER_LOG_MAX_FILE"
  }
}
JSON
systemctl restart docker

# ---- Cockpit ----
log "Installing Cockpit"
apt_install_if_missing cockpit
systemctl enable --now cockpit.socket

# ---- Unattended upgrades ----
log "Configuring unattended security upgrades"
apt_install_if_missing unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

UA_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ "$AUTO_REBOOT" == "true" ]]; then
  grep -q Automatic-Reboot "$UA_CONF" || echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "$UA_CONF"
  grep -q Automatic-Reboot-Time "$UA_CONF" || echo "Unattended-Upgrade::Automatic-Reboot-Time \"$AUTO_REBOOT_TIME\";" >> "$UA_CONF"
fi

systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer

# ---- Fail2ban ----
log "Installing Fail2ban"
apt_install_if_missing fail2ban
systemctl enable --now fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<CONF
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
CONF
systemctl restart fail2ban

# ---- SSH hardening ----
if [[ "$HARDEN_SSH" == "true" ]]; then
  log "Hardening SSH"
  SSHD_CFG="/etc/ssh/sshd_config"

  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CFG" || true

  if has_admin_ssh_key; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CFG" || true
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CFG" || true
  else
    warn "No SSH key for $ADMIN_USER — leaving password auth enabled"
  fi

  systemctl restart ssh || systemctl restart sshd || true
fi

# ---- Portainer ----
log "Deploying Portainer"
docker volume create "$PORTAINER_VOL" >/dev/null 2>&1 || true
docker rm -f portainer >/dev/null 2>&1 || true

docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 \
  -p 9000:9000 \
  -p "$PORTAINER_HTTPS_PORT:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PORTAINER_VOL:/data" \
  portainer/portainer-ce:latest

# ---- Dockge ----
log "Deploying Dockge"
mkdir -p "$STACKS_DIR" "$DOCKGE_DIR"

cat > "$DOCKGE_DIR/compose.yml" <<YAML
services:
  dockge:
    image: louislam/dockge:1
    restart: unless-stopped
    ports:
      - "$DOCKGE_PORT:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - $STACKS_DIR:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
YAML

docker compose -f "$DOCKGE_DIR/compose.yml" up -d

# ---- Firewall ----
log "Configuring UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow from "$LAN_CIDR" to any port 22 proto tcp
ufw allow from "$LAN_CIDR" to any port "$COCKPIT_PORT" proto tcp
ufw allow from "$LAN_CIDR" to any port "$PORTAINER_HTTPS_PORT" proto tcp
ufw allow from "$LAN_CIDR" to any port "$DOCKGE_PORT" proto tcp

ufw --force enable
ufw status verbose || true

# ---- Done ----
IP="$(hostname -I | awk '{print $1}')"

log "Bootstrap complete"
echo "------------------------------------------------------------"
echo "Access via IP address:"
echo "  Cockpit:   https://$IP:$COCKPIT_PORT"
echo "  Portainer: https://$IP:$PORTAINER_HTTPS_PORT"
echo "  Dockge:    http://$IP:$DOCKGE_PORT"
echo
echo "Notes:"
echo " - Docker CLI access via: sudo docker / sudo docker compose"
echo " - Compose stacks live in: $STACKS_DIR"
echo " - Add public services later with: sudo ufw allow <port>/<proto>"
echo "------------------------------------------------------------"
