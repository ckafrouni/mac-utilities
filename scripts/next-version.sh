#!/usr/bin/env bash
# Prints the next release of a utility as GitHub outputs (version=, tag=, previous_tag=).
#   scripts/next-version.sh <Name> <patch|minor|major> [exact version]
# Tags are <id>-vX.Y.Z, <id> the lowercased name; a utility's first release is 0.1.0.
set -euo pipefail
name="${1:?usage: scripts/next-version.sh <Name> <bump> [version]}"
bump="${2:-patch}"
exact="${3:-}"
id="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
previous="$(git tag -l "$id-v*" | sed "s/^$id-v//" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"

if [[ -n "$exact" ]]; then
  version="$exact"
elif [[ -z "$previous" ]]; then
  version=0.1.0
else
  IFS=. read -r major minor patch <<<"$previous"
  case "$bump" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    patch) version="$major.$minor.$((patch + 1))" ;;
    *) echo "Unknown bump $bump" >&2; exit 1 ;;
  esac
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a version: $version" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$id-v$version" >/dev/null; then
  echo "$id-v$version is already released" >&2
  exit 1
fi
echo "version=$version"
echo "tag=$id-v$version"
echo "previous_tag=${previous:+$id-v$previous}"
