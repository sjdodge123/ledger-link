#!/usr/bin/env bash
# Refreshes the pinned Raid Ledger contracts from one Raid Ledger commit:
#   packages/contract/ledgerlink/v1/           -> contract/v1/
#   packages/contract/companion/dev-bridge/v1/ -> contract/dev-bridge/v1/
# Copies committed content only (git archive), and records the source commit in
# each folder's SOURCE. Never hand-edit contract/; re-run this instead.
# Usage: tools/sync-contract.sh <raid-ledger-checkout> [git-ref, default HEAD]
set -euo pipefail

rl="${1:?usage: $0 <raid-ledger-checkout> [git-ref]}"
ref="${2:-HEAD}"
root="$(cd "$(dirname "$0")/.." && pwd)"
sha=$(git -C "$rl" rev-parse --verify "$ref^{commit}")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sync <source folder in Raid Ledger> <destination under this repo>
sync() {
  local src="$1" dest="$root/$2"
  if ! git -C "$rl" cat-file -e "$sha:$src" 2>/dev/null; then
    echo "error: $src does not exist at $ref ($sha) in $rl" >&2
    exit 1
  fi
  git -C "$rl" archive "$sha" "$src" | tar -x -C "$tmp"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp/$src" "$dest"
  printf '%s\n' "$sha" > "$dest/SOURCE"
  echo "$2 synced from $sha ($ref)"
}

sync packages/contract/ledgerlink/v1 contract/v1
sync packages/contract/companion/dev-bridge/v1 contract/dev-bridge/v1
