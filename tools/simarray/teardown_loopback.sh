#!/bin/bash
# teardown_loopback.sh — remove the sim array's loopback aliases (macOS).
# Usage: sudo ./teardown_loopback.sh [count] [base-last-octet]

set -euo pipefail
COUNT="${1:-12}"
BASE="${2:-101}"

if [ "$(id -u)" -ne 0 ]; then
  echo "needs sudo: sudo $0 $COUNT $BASE" >&2
  exit 1
fi

for ((i = 0; i < COUNT; i++)); do
  ip="127.0.0.$((BASE + i))"
  ifconfig lo0 -alias "$ip" 2>/dev/null && echo "removed $ip" || true
done
echo "done"
