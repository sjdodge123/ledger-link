#!/usr/bin/env bash
# Cross-check: decode addon-generated `char` strings with Raid Ledger's real
# server decoder (decodeImportString). Nothing is written into the Raid
# Ledger checkout; the decode script lives in a temp dir.
#
#   RAID_LEDGER_DIR=/path/to/Raid-Ledger-checkout tools/verify-with-raid-ledger.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RL="${RAID_LEDGER_DIR:-$HOME/Documents/Projects/Raid-Ledger--rok-1724}"
DECODER="$RL/api/src/plugins/wow-common/addon-import/addon-import.decoder.ts"
[ -f "$DECODER" ] || { echo "decoder not found: $DECODER (set RAID_LEDGER_DIR)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v luarocks >/dev/null; then eval "$(luarocks --lua-version=5.1 path)"; fi
(cd "$REPO" && luajit tools/gen_char_strings.lua "$TMP")

cat > "$TMP/decode.ts" <<TS
import { readFileSync, readdirSync } from 'node:fs';
import { decodeImportString } from '$DECODER';
let failed = 0;
for (const file of readdirSync('$TMP').filter((f) => f.endsWith('.txt')).sort()) {
  try {
    const { payload, pages, inputBytes } = decodeImportString(readFileSync('$TMP/' + file, 'utf8'));
    const d = payload.section === 'char' ? payload.data : null;
    console.log('OK  ', file, JSON.stringify({ section: payload.section, pages, inputBytes,
      ruleset: payload.who.ruleset, guildName: payload.who.guildName ?? null, region: payload.client.region,
      gear: d?.gear.length, talentNodes: d?.talents.nodes.length, lockouts: d?.lockouts.length }));
  } catch (err) {
    failed++;
    const e = err as { code?: string; message?: string };
    console.log('FAIL', file, e.code ?? '', e.message ?? String(err));
  }
}
if (failed) { console.log(failed + ' string(s) failed to decode'); process.exit(1); }
console.log('all strings decoded with zero errors');
TS

cd "$RL/api" && npx --no-install tsx "$TMP/decode.ts"
