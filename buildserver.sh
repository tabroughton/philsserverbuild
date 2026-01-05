#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Secure headless Docker host bootstrap (Debian 13.x stable)
# Installs/configures:
# - Docker Engine + Compose plugin
# - Portainer CE + Dockge (web UIs)
# - Cockpit + Cockpit Firewall UI (UFW management)
# - UFW firewall (LAN-only management)
# - Avahi mDNS (.local hostname)
# - Unattended upgrades (security updates) + optional reboot window
# - Fail2ban (SSH protection)
# - SSH hardening (safe: disables password login only if philadmin has SSH keys)
# ============================================================

# ---- YOUR SETTINGS ----
TIMEZONE="Europe/London"
LAN_CIDR="192.168.4.0/24"

# Hostname for LAN access via mDNS -> <HOSTNAME>.local
# NOTE: This does NOT edit /etc/hosts. You said you manage that manually.
HOSTNAME="philshomeserver"

# Existing admin sudo user (must exist)
ADMIN_USER="philadmin"

# Web UIs (restricted to LAN by firewall)
PORTAINER_HTTPS_PORT="9443"
DOCKGE_PORT="5001"
COCKPIT_PORT="9090"

# Where Dockge looks for stacks
STACKS_DIR="/opt/stacks"
DOCKGE_DIR="/opt/dockge"
PORTAINER_VOL="portainer_data"

# Automatic updates / reboot
AUTO_REBOOT="true"
AUTO_REBOOT_TIME="03:30"

# SSH hardening
# PasswordAuthentication will ONLY be disabled if an SSH key exists for ADMIN_USER.
HARDEN_SSH="true"

# Docker log rotation (prevents disk fill)
DOCKER_LOG_MAX_SIZE="10m"
DOCKER_LOG_MAX_FILE="3"


# ---- Helpers ----
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\n\033[1;33m==>\033[0m $*"; }
die() { echo -e "\n\033[1;31mERROR:\033[0m $*"; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run as root (use: sudo bash $0)"
  fi
}

detect_debian() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    die "Cannot detect OS (missing /etc/os-release)"
  fi
  [[ "${ID:-}" == "debian" ]] || die "This script is intended for Debian. Detected: ${ID:-unknown}"
  [[ -n "${VERSION_CODENAME:-}" ]] || die "VERSION_CODENAME not found in /etc/os-release"
}

ensure_admin_user_exists() {
  if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    die "Admin user '${ADMIN_USER}' does not exist. Create it first or change ADMIN_USER in the script."
  fi
  if ! id -nG "${ADMIN_USER}" | tr ' ' '\n' | grep -qx "sudo"; then
    warn "User '${ADMIN_USER}' is not in sudo group. Continuing, but sudo is expected."
  fi
}

has_admin_ssh_key() {
  local home_dir
  home_dir="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  [[ -n "$home_dir" && -f "${home_dir}/.ssh/authorized_keys" && -s "${home_dir}/.ssh/authorized_keys" ]]
}

apt_install_if_missing() {
  # Installs packages only if they are not already installed.
  # Usage: apt_install_if_missing pkg1 pkg2 ...
  local to_install=()
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      continue
    fi
    to_install+=("$pkg")
  done
  if (( ${#to_install[@]} > 0 )); then
    apt-get install -y "${to_install[@]}"
  fi
}

# ---- Start ----
require_root
detect_debian
ensure_admin_user_exists

log "Detected OS: ${PRETTY_NAME:-Debian} (codename: ${VERSION_CODENAME})"
log "Admin user: ${ADMIN_USER}"

log "Setting timezone to ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}" >/dev/null 2>&1 || true

log "Setting hostname to ${HOSTNAME} (will NOT edit /etc/hosts)"
hostnamectl set-hostname "${HOSTNAME}"

log "Updating apt and installing base packages"
apt-get update -y
apt_install_if_missing ca-certificates curl gnupg lsb-release apt-transport-https ufw

log "Installing Avahi for mDNS (.local) hostname discovery"
apt_install_if_missing avahi-daemon
systemctl enable --now avahi-daemon

# ---- Docker install (official repo) ----
log "Installing Docker Engine using Docker's official repo (idempotent)"
install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF

apt-get update -y
apt_install_if_missing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Enabling Docker"
systemctl enable --now docker

log "Keeping Docker CLI access limited (use sudo docker ...). Not adding users to docker group."

# Docker daemon hardening: log rotation
log "Configuring Docker log rotation"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  }
}
JSON
systemctl restart docker

# ---- Cockpit ----
log "Installing Cockpit (host web admin)"
apt_install_if_missing cockpit
systemctl enable --now cockpit.socket

# ---- Unattended upgrades ----
log "Installing and enabling unattended upgrades (automatic security updates)"
apt_install_if_missing unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

UA_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "${UA_CONF}" && "${AUTO_REBOOT}" == "true" ]]; then
  if grep -q 'Unattended-Upgrade::Automatic-Reboot' "${UA_CONF}"; then
    sed -i 's#//\s*Unattended-Upgrade::Automatic-Reboot\s*".*";#Unattended-Upgrade::Automatic-Reboot "true";#' "${UA_CONF}" || true
  else
    echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "${UA_CONF}"
  fi

  if grep -q 'Unattended-Upgrade::Automatic-Reboot-Time' "${UA_CONF}"; then
    sed -i "s#//\s*Unattended-Upgrade::Automatic-Reboot-Time\s*\".*\";#Unattended-Upgrade::Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\";#" "${UA_CONF}" || true
  else
    echo "Unattended-Upgrade::Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\";" >> "${UA_CONF}"
  fi
fi

systemctl enable --now unattended-upgrades || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || true

# ---- Fail2ban ----
log "Installing and enabling Fail2ban (SSH brute-force protection)"
apt_install_if_missing fail2ban
systemctl enable --now fail2ban

cat > /etc/fail2ban/jail.d/sshd.local <<'CONF'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
CONF
systemctl restart fail2ban

# ---- SSH hardening (safe) ----
if [[ "${HARDEN_SSH}" == "true" ]]; then
  log "Hardening SSH (no root login; password auth disabled ONLY if ${ADMIN_USER} has SSH keys)"
  SSHD_CFG="/etc/ssh/sshd_config"

  # Always: no root login
  if grep -qE '^\s*PermitRootLogin' "${SSHD_CFG}"; then
    sed -i 's/^\s*PermitRootLogin\s\+.*/PermitRootLogin no/' "${SSHD_CFG}"
  else
    echo "PermitRootLogin no" >> "${SSHD_CFG}"
  fi

  if has_admin_ssh_key; then
    if grep -qE '^\s*PasswordAuthentication' "${SSHD_CFG}"; then
      sed -i 's/^\s*PasswordAuthentication\s\+.*/PasswordAuthentication no/' "${SSHD_CFG}"
    else
      echo "PasswordAuthentication no" >> "${SSHD_CFG}"
    fi

    if grep -qE '^\s*KbdInteractiveAuthentication' "${SSHD_CFG}"; then
      sed -i 's/^\s*KbdInteractiveAuthentication\s\+.*/KbdInteractiveAuthentication no/' "${SSHD_CFG}"
    else
      echo "KbdInteractiveAuthentication no" >> "${SSHD_CFG}"
    fi
  else
    warn "No SSH key found for ${ADMIN_USER} (~${ADMIN_USER}/.ssh/authorized_keys)."
    warn "Leaving SSH password login ENABLED to avoid locking you out."
    warn "Add an SSH key for ${ADMIN_USER}, then set PasswordAuthentication no if desired."
  fi

  systemctl restart ssh || systemctl restart sshd || true
fi

# ---- Deploy Portainer CE ----
log "Deploying Portainer CE (idempotent)"
docker volume create "${PORTAINER_VOL}" >/dev/null 2>&1 || true

docker rm -f portainer >/dev/null 2>&1 || true
docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 \
  -p 9000:9000 \
  -p "${PORTAINER_HTTPS_PORT}:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_VOL}":/data \
  portainer/portainer-ce:latest

# ---- Deploy Dockge ----
log "Deploying Dockge (idempotent)"
mkdir -p "${STACKS_DIR}"
mkdir -p "${DOCKGE_DIR}"

cat > "${DOCKGE_DIR}/compose.yml" <<YAML
services:
  dockge:
    image: louislam/dockge:1
    restart: unless-stopped
    ports:
      - "${DOCKGE_PORT}:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - ${STACKS_DIR}:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
YAML

docker compose -f "${DOCKGE_DIR}/compose.yml" up -d

# ---- Firewall (UFW) ----
log "Configuring UFW firewall (LAN-only management access)"
# Safe to re-run: we reset and re-apply the baseline rules.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH only from LAN
ufw allow from "${LAN_CIDR}" to any port 22 proto tcp

# Management UIs only from LAN
ufw allow from "${LAN_CIDR}" to any port "${COCKPIT_PORT}" proto tcp
ufw allow from "${LAN_CIDR}" to any port "${PORTAINER_HTTPS_PORT}" proto tcp
ufw allow from "${LAN_CIDR}" to any port "${DOCKGE_PORT}" proto tcp

# (Optional) If you want Portainer HTTP on LAN (not recommended), uncomment:
# ufw allow from "${LAN_CIDR}" to any port 9000 proto tcp

ufw --force enable

log "Firewall status:"
ufw status verbose || true

# ---- Final notes ----
IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

log "All done."
echo "------------------------------------------------------------"
echo "Hostname / mDNS:"
echo "  Server name on LAN: ${HOSTNAME}.local"
echo
echo "LAN-only management (from ${LAN_CIDR}):"
echo "  Cockpit:   https://${HOSTNAME}.local:${COCKPIT_PORT}  (or https://${IP_HINT:-SERVER_IP}:${COCKPIT_PORT})"
echo "  Portainer: https://${HOSTNAME}.local:${PORTAINER_HTTPS_PORT}"
echo "  Dockge:    http://${HOSTNAME}.local:${DOCKGE_PORT}"
echo
echo "Notes:"
echo " - Docker control == root-equivalent; keep Docker CLI to admin via sudo."
echo " - Put Compose stacks in: ${STACKS_DIR} (Dockge watches this)."
echo " - Add public ports later with: sudo ufw allow <port>/<proto>"
echo "------------------------------------------------------------"
