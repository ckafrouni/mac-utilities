#!/usr/bin/env bash
# Builds a utility for development and (re)starts it: scripts/run.sh <Name>
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:?usage: scripts/run.sh <Name>}"
scripts/build-app.sh "$name" --dev
pkill -x "$name" 2>/dev/null && sleep 0.5 || true
open "build/$name.app"
