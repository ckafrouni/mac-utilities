#!/usr/bin/env bash
# Starts a new utility: scripts/new-utility.sh <Name> [SF Symbol] [hex color]
# Creates Utilities/<Name> (a menu bar app with one item, and an icon of the symbol on the
# color), ready for scripts/run.sh <Name>.
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:?usage: scripts/new-utility.sh <Name> [SF Symbol]}"
symbol="${2:-wrench.and.screwdriver}"
color="${3:-3478F6}"
[[ "$name" =~ ^[A-Z][A-Za-z0-9]*$ ]] || { echo "Name it in UpperCamelCase, like Calipers" >&2; exit 1; }
dir="Utilities/$name"
[[ ! -e "$dir" ]] || { echo "$dir already exists" >&2; exit 1; }
id="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$dir/Sources"
sed -e "s/Calipers/$name/g" -e "s/com\.ckafrouni\.calipers/com.ckafrouni.$id/" Utilities/Calipers/Info.plist > "$dir/Info.plist"
cat > "$dir/Sources/main.swift" <<SWIFT
import AppKit
import UtilityKit

// $name: what it does, in a line.

MainActor.assumeIsolated {
  UtilityApp.run(symbol: "$symbol") {
    [UtilityApp.item("Hello") { UtilityApp.alert("Hello from $name") }]
  }
}
SWIFT
cat > "$dir/README.md" <<MD
# $name

What it does, and how to use it.
MD
swift scripts/make-icon.swift "$name" "$symbol" "$color" >/dev/null
echo "Created $dir. Run it with: scripts/run.sh $name"
