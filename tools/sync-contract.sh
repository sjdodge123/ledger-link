#!/usr/bin/env bash
# Refreshes contract/v1/ from Raid Ledger's packages/contract/ledgerlink/v1/.
# Copies committed content only (git archive), and records the source commit in
# contract/v1/SOURCE. Never hand-edit contract/; re-run this instead.
# Usage: tools/sync-contract.sh <raid-ledger-checkout> [git-ref, default HEAD]
set -euo pipefail

rl="${1:?usage: $0 <raid-ledger-checkout> [git-ref]}"
ref="${2:-HEAD}"
src="packages/contract/ledgerlink/v1"
dest="$(cd "$(dirname "$0")/.." && pwd)/contract/v1"

sha=$(git -C "$rl" rev-parse --verify "$ref^{commit}")
if ! git -C "$rl" cat-file -e "$sha:$src" 2>/dev/null; then
  echo "error: $src does not exist at $ref ($sha) in $rl" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$rl" archive "$sha" "$src" | tar -x -C "$tmp"

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$tmp/$src" "$dest"
printf '%s\n' "$sha" > "$dest/SOURCE"
echo "contract/v1 synced from $sha ($ref)"
