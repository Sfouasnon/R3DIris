#!/bin/bash
# setup_loopback.sh — alias N loopback IPs for the sim array (macOS).
# Usage: sudo ./setup_loopback.sh [count] [base-last-octet]
#   sudo ./setup_loopback.sh 12        → 127.0.0.101 … 127.0.0.112
#   sudo ./setup_loopback.sh 40        → 127.0.0.101 … 127.0.0.140
# macOS only routes 127.0.0.1 by default; every other 127.x address needs an
# explicit lo0 alias. Aliases do not survive reboot (re-run as needed).

set -euo pipefail
COUNT="${1:-12}"
BASE="${2:-101}"

if [ "$(id -u)" -ne 0 ]; then
  echo "needs sudo: sudo $0 $COUNT $BASE" >&2
  exit 1
fi

for ((i = 0; i < COUNT; i++)); do
  ip="127.0.0.$((BASE + i))"
  ifconfig lo0 alias "$ip" up
  echo "alias $ip"
done
echo "done — $COUNT loopback aliases. Remove with: sudo ./teardown_loopback.sh $COUNT $BASE"
