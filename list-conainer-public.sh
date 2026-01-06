#!/usr/bin/env bash
set -euo pipefail

# Lists Docker public port exceptions managed by public-fwrules-*.service

CONF_DIR="/etc/docker-public"
UNIT_DIR="/etc/systemd/system"

[[ -d "$CONF_DIR" ]] || { echo "No public Docker rules found."; exit 0; }

printf "\nPublic Docker port exceptions:\n"
printf "--------------------------------------------------\n"

found=0

for spec in "$CONF_DIR"/*.ports; do
  [[ -e "$spec" ]] || continue
  found=1

  name="$(basename "$spec" .ports)"
  unit="public-fwrules-${name}.service"
  unitfile="${UNIT_DIR}/${unit}"

  echo
  echo "Container reference : $name"
  echo "Ports               : $(tr '\n' ' ' < "$spec")"

  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    echo "Service enabled     : yes"
  else
    echo "Service enabled     : no"
  fi

  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    echo "Service active      : yes"
  else
    echo "Service active      : no"
  fi

  if [[ -f "$unitfile" ]]; then
    echo "Service file        : $unitfile"
  else
    echo "Service file        : (missing)"
  fi
done

[[ $found -eq 1 ]] || echo "No public Docker rules found."

echo
printf "--------------------------------------------------\n"
echo "Tip:"
echo "  - Use make-docker-public.sh <name> <port/proto>..."
echo "  - Use remove-docker-public.sh <name>"
echo
