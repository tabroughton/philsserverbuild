#!/usr/bin/env bash
set -euo pipefail

##################################################
# build script for phils server
#
# - Debian
# - Cockpit
# - Portainer
# - fail2ban + basic SSH hardening
# - firewalld for host ports (LAN-only)
# - Docker published ports LAN-only by default
#   (enforced via DOCKER-USER using systemd after docker starts)
#
# Safe to re-run.
##################################################

# ---------------- USER SETTINGS ----------------
TIMEZONE="Europe/London"
LAN_CIDR="192.168.4.0/24"

ADMIN_USER="philadmin"

PORTAINER_HTTPS_PORT="9443"
COCKPIT_PORT="9090"

PORTAINER_VOL="portainer_data"

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
  ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
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
log "Installing Docker (official repo)"

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
apt_install_if_missing docker-ce docker-ce-cli containerd.io docker-compose-plugin iptables

# Ensure firewalld starts before Docker
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-firewalld.conf <<EOF
[Unit]
Requires=firewalld.service
After=firewalld.service
EOF
systemctl daemon-reload

log "Configuring Docker log rotation"
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

# ---------------- firewalld rules (host ports) ----------------
log "Configuring firewalld zones (runtime → permanent)"

# Runtime only (compatible across firewalld builds)
firewall-cmd --set-default-zone=public || true
firewall-cmd --zone=home --add-source="$LAN_CIDR" || true

firewall-cmd --zone=home --add-port=22/tcp || true
firewall-cmd --zone=home --add-port="${COCKPIT_PORT}/tcp" || true
firewall-cmd --zone=home --add-port="${PORTAINER_HTTPS_PORT}/tcp" || true

# Persist runtime config
firewall-cmd --runtime-to-permanent || true
firewall-cmd --reload || true

# ---------------- Docker LAN-only policy (persist + boot-safe) ----------------
log "Installing Docker LAN-only policy service (runs after Docker starts)"

install -d /usr/local/sbin
cat > /usr/local/sbin/docker-lan-only.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

LAN_IFACE="${LAN_IFACE}"
LAN_CIDR="${LAN_CIDR}"

# Ensure chain exists
iptables -w -t filter -L DOCKER-USER >/dev/null 2>&1 || iptables -w -t filter -N DOCKER-USER

# Ensure FORWARD jumps to DOCKER-USER near the top
iptables -w -t filter -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -w -t filter -I FORWARD 1 -j DOCKER-USER

# Helper: add rule if missing (inserts or appends as specified)
add_insert() { iptables -w -t filter -C DOCKER-USER "\$@" >/dev/null 2>&1 || iptables -w -t filter -I DOCKER-USER "\$@"; }
add_append() { iptables -w -t filter -C DOCKER-USER "\$@" >/dev/null 2>&1 || iptables -w -t filter -A DOCKER-USER "\$@"; }

# Script-owned rules: keep order stable
add_insert 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
add_insert 2 -i docker0 -j RETURN
add_insert 3 -i br+ -j RETURN
add_insert 4 -i "\$LAN_IFACE" -s "\$LAN_CIDR" -o docker0 -j RETURN
add_insert 5 -i "\$LAN_IFACE" -s "\$LAN_CIDR" -o br+ -j RETURN

# Drops go at the end so manual "public exceptions" can be inserted above them
add_append -i "\$LAN_IFACE" -o docker0 -j DROP
add_append -i "\$LAN_IFACE" -o br+ -j DROP
EOF
chmod +x /usr/local/sbin/docker-lan-only.sh

cat > /etc/systemd/system/docker-lan-only.service <<'EOF'
[Unit]
Description=Apply LAN-only policy for Docker published ports
Requires=firewalld.service docker.service
After=firewalld.service docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-lan-only.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now docker-lan-only.service
systemctl restart docker-lan-only.service

# ---------------- README ----------------
log "Writing firewall README"
install -d /opt
cat > /opt/README-firewall.md <<EOF
# Docker + firewalld quick guide

## A) LAN-only container (default)
In Portainer:
- Publish a port and set **Host IP** to the server's LAN IP (e.g. 192.168.x.y)
- Deploy

No firewall changes needed.

## B) LAN + Public container
1) Portainer: Host IP = 0.0.0.0
2) Add a public exception ABOVE the DROP rules:

Example (TCP 8080):
sudo iptables -w -t filter -I DOCKER-USER 1 -i ${LAN_IFACE} -o docker0 -p tcp --dport 8080 -j RETURN
sudo iptables -w -t filter -I DOCKER-USER 1 -i ${LAN_IFACE} -o br+    -p tcp --dport 8080 -j RETURN

3) Router: port-forward to this host

(If you want these public exceptions to persist across reboot, add them in a small
systemd oneshot similar to docker-lan-only.service, or tell me and I’ll generate it.)
EOF

# ---------------- Done ----------------
IP="$(hostname -I | awk '{print $1}')"

log "Bootstrap complete"
echo "------------------------------------------------------------"
echo "Cockpit:   https://$IP:$COCKPIT_PORT   (LAN-only)"
echo "Portainer: https://$IP:$PORTAINER_HTTPS_PORT   (LAN-only)"
echo "Firewall notes: /opt/README-firewall.md"
echo "LAN interface detected: $LAN_IFACE"
echo "LAN CIDR configured: $LAN_CIDR"
echo "------------------------------------------------------------"
