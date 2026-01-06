#!/usr/bin/env bash
set -euo pipefail

# container-vols.sh
#
# Usage:
#   sudo ./container-vols.sh create <container-name> <dir1> [dir2 ...]
#   sudo ./container-vols.sh add    <container-name> <dir1> [dir2 ...]
#   sudo ./container-vols.sh remove <container-name> <dir1> [dir2 ...]
#   sudo ./container-vols.sh delete <container-name>
#
# Defaults:
#   BASE_DIR=/opt/containers
#
# Notes:
# - Directory execute bit is required for traversal/access.
# - Script is idempotent for create/add (won't fail if user/dirs already exist).
# - remove/delete prompt for confirmation.

BASE_DIR="${BASE_DIR:-/opt/containers}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run with sudo"
}

sanitize_name() {
  # lower, allow a-z0-9_.-, replace others with -
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//'
}

user_for_container() {
  local cname="$1"
  echo "container_${cname}"
}

ensure_user() {
  local user="$1"
  if id "$user" >/dev/null 2>&1; then
    info "User exists: $user"
  else
    info "Creating user: $user"
    # system user, no home, no login
    useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
  fi
}

ensure_base_dir() {
  install -d -m 0755 "$BASE_DIR"
}

container_root() {
  local cname="$1"
  echo "${BASE_DIR}/${cname}"
}

ensure_dirs() {
  local root="$1" user="$2"; shift 2
  local d path
  for d in "$@"; do
    [[ -n "$d" ]] || continue
    # prevent traversal / absolute paths
    [[ "$d" != /* ]] || die "Dir names must be relative (got absolute: $d)"
    [[ "$d" != *".."* ]] || die "Dir names must not contain '..' (got: $d)"

    path="${root}/${d}"

    if [[ -d "$path" ]]; then
      info "Dir exists: $path"
    else
      info "Creating dir: $path"
      install -d "$path"
    fi

    # Ownership: user:user (primary group is typically same as user for system user? If not, still ok)
    chown -R "$user:$user" "$path"

    # Permissions:
    # - Directories need x for traversal. 750 = user rwx, group rx, other none
    chmod 0750 "$path"

    # Ensure new files/dirs inherit group = user group
    chmod g+s "$path" || true
  done
}

remove_dirs() {
  local root="$1"; shift
  local d path missing=0
  for d in "$@"; do
    [[ -n "$d" ]] || continue
    path="${root}/${d}"
    if [[ -e "$path" ]]; then
      info "Removing: $path"
      rm -rf --one-file-system "$path"
    else
      echo "WARN: Not found: $path" >&2
      missing=1
    fi
  done
  return $missing
}

delete_everything() {
  local root="$1" user="$2"
  if [[ -d "$root" ]]; then
    info "Removing container root: $root"
    rm -rf --one-file-system "$root"
  else
    info "Container root not present: $root"
  fi

  if id "$user" >/dev/null 2>&1; then
    info "Deleting user: $user"
    userdel "$user" || true
  else
    info "User not present: $user"
  fi
}

main() {
  require_root
  [[ $# -ge 2 ]] || die "Usage: $0 <create|add|remove|delete> <container-name> [dir ...]"

  local cmd="$1"; shift
  local raw_name="$1"; shift
  local cname; cname="$(sanitize_name "$raw_name")"
  [[ -n "$cname" ]] || die "Invalid container name: $raw_name"

  local user; user="$(user_for_container "$cname")"
  local root; root="$(container_root "$cname")"

  ensure_base_dir

  case "$cmd" in
    create|add)
      [[ $# -ge 1 ]] || die "Usage: $0 $cmd <container-name> <dir1> [dir2 ...]"
      ensure_user "$user"
      # Create root
      if [[ -d "$root" ]]; then
        info "Container root exists: $root"
      else
        info "Creating container root: $root"
        install -d "$root"
      fi
      chown "$user:$user" "$root"
      chmod 0750 "$root"
      chmod g+s "$root" || true

      ensure_dirs "$root" "$user" "$@"
      info "Done."
      ;;
    remove)
      [[ $# -ge 1 ]] || die "Usage: $0 remove <container-name> <dir1> [dir2 ...]"
      [[ -d "$root" ]] || die "Container root does not exist: $root"
      if confirm "Remove the listed directories under '$root'?"; then
        remove_dirs "$root" "$@"
        info "Done."
      else
        info "Cancelled."
      fi
      ;;
    delete)
      [[ $# -eq 0 ]] || die "Usage: $0 delete <container-name>"
      if confirm "DELETE user '$user' and ALL data under '$root'?"; then
        delete_everything "$root" "$user"
        info "Done."
      else
        info "Cancelled."
      fi
      ;;
    *)
      die "Unknown command: $cmd (use create|add|remove|delete)"
      ;;
  esac
}

main "$@"
