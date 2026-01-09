#!/usr/bin/env bash
set -euo pipefail

# update-backups-device.sh
#
# Usage:
#   sudo ./update-backups-device.sh <device>
# Example:
#   sudo ./update-backups-device.sh /dev/sdc1
#
# What it does:
# - Reads UUID from <device>
# - Updates the UUID for the /backups entry in /etc/fstab (in-place, with backup)
# - Reloads systemd units, mounts /backups
# - Ensures /backups/<container_name> exists for each container directory in /opt/containers/<container_name>
#   and sets ownership to container_<container_name>:backups with permissions 2700

BASE_DIR="${BASE_DIR:-/opt/containers}"
BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
BACKUPS_GROUP="${BACKUPS_GROUP:-backups}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run with sudo"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_group() {
  local group="$1"
  if getent group "$group" >/dev/null 2>&1; then
    info "Group exists: $group"
  else
    info "Creating group: $group"
    groupadd "$group"
  fi
}

sanitize_name() {
  # Keep in sync with container-vols.sh: lower, allow a-z0-9_.-, replace others with -
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

user_for_container() {
  local cname="$1"
  echo "container_${cname}"
}

ensure_backups_dir_for_container() {
  local cname="$1" user="$2"
  local bdir="${BACKUPS_DIR}/${cname}"

  if [[ -d "$bdir" ]]; then
    info "Backups dir exists: $bdir"
  else
    info "Creating backups dir: $bdir"
    install -d "$bdir"
  fi

  # Ownership: <container_user>:backups
  chown "$user:$BACKUPS_GROUP" "$bdir"

  # Secure default; setgid so group sticks on new files/dirs
  chmod 2700 "$bdir"
}

ensure_backups_dirs_for_all_containers() {
  [[ -d "$BASE_DIR" ]] || die "Container base dir not found: $BASE_DIR"
  ensure_group "$BACKUPS_GROUP"

  local d raw cname user
  shopt -s nullglob
  for d in "$BASE_DIR"/*; do
    [[ -d "$d" ]] || continue
    raw="$(basename "$d")"
    cname="$(sanitize_name "$raw")"
    [[ -n "$cname" ]] || continue

    user="$(user_for_container "$cname")"
    if id "$user" >/dev/null 2>&1; then
      ensure_backups_dir_for_container "$cname" "$user"
    else
      echo "WARN: Skipping '$cname' (user not found: $user)" >&2
    fi
  done
  shopt -u nullglob
}

update_fstab_uuid_for_backups() {
  local uuid="$1"

  [[ -d "$BACKUPS_DIR" ]] || die "Backups mountpoint does not exist: $BACKUPS_DIR"

  info "Backing up /etc/fstab"
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"

  info "Updating UUID for $BACKUPS_DIR in /etc/fstab"
  sed -i -E \
    "s|^UUID=[^[:space:]]+([[:space:]]+${BACKUPS_DIR//\//\\/}[[:space:]]+)|UUID=${uuid}\1|" \
    /etc/fstab

  if ! grep -qE "^UUID=${uuid}[[:space:]]+${BACKUPS_DIR//\//\\/}([[:space:]]+|$)" /etc/fstab; then
    die "Backups entry not found or not updated in /etc/fstab. Check manually!"
  fi
}

mount_backups() {
  info "Reloading systemd units (fstab -> mount units)"
  systemctl daemon-reload

  info "Mounting $BACKUPS_DIR"
  umount "$BACKUPS_DIR" 2>/dev/null || true
  mount "$BACKUPS_DIR"

  info "Mounted:"
  findmnt "$BACKUPS_DIR"
}

main() {
  require_root
  require_cmd blkid
  require_cmd sed
  require_cmd mount
  require_cmd findmnt
  require_cmd systemctl

  [[ $# -eq 1 ]] || die "Usage: $0 <device>  e.g. /dev/sdc1"
  local dev="$1"

  [[ -b "$dev" ]] || die "$dev is not a block device"

  local uuid
  uuid="$(blkid -s UUID -o value "$dev" || true)"
  [[ -n "$uuid" ]] || die "Could not read UUID from $dev"

  info "Device: $dev"
  info "UUID:   $uuid"

  update_fstab_uuid_for_backups "$uuid"
  mount_backups

  info "Ensuring per-container backup directories under $BACKUPS_DIR"
  ensure_backups_dirs_for_all_containers

  info "Done."
}

main "$@"
