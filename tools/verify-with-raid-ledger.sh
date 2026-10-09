#!/usr/bin/env bash
# Cross-check: decode addon-generated char / guild (incl. multi-page) / raid
# strings, plus the anonymised real beta strings in spec/fixtures/beta, with
# Raid Ledger's real server decoder (decodeImportString). A paged
# guild paste must decode to the same roster + sha256 in reversed page order. Nothing is written into the Raid
# Ledger checkout; the decode script lives in a temp dir.
#
#   RAID_LEDGER_DIR=/path/to/Raid-Ledger-checkout tools/verify-with-raid-ledger.sh
#
# "Export all" strings (all-*.txt) need a Raid Ledger with ROK-1737
# (decodeImportPaste); with an older checkout they are skipped, not failed.
# TSX overrides the TypeScript runner (default: npx --no-install tsx in api/).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RL="${RAID_LEDGER_DIR:-$HOME/Documents/Projects/Raid-Ledger--rok-1724}"
DECODER="$RL/api/src/plugins/wow-common/addon-import/addon-import.decoder.ts"
[ -f "$DECODER" ] || { echo "decoder not found: $DECODER (set RAID_LEDGER_DIR)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v luarocks >/dev/null; then eval "$(luarocks --lua-version=5.1 path)"; fi
(cd "$REPO" && luajit tools/gen_strings.lua "$TMP")
# Anonymised real strings from the beta (tools/anonymise.lua) must decode too.
for f in "$REPO"/spec/fixtures/beta/*.txt; do [ -e "$f" ] && cp "$f" "$TMP/beta-$(basename "$f")"; done

MIXED=false
grep -q "export function decodeImportPaste" "$DECODER" && MIXED=true
echo "Raid Ledger decoder: $DECODER (mixed paste: $MIXED)"

cat > "$TMP/decode.ts" <<TS
import { readFileSync, readdirSync } from 'node:fs';
import * as decoder from '$DECODER';
const { decodeImportString } = decoder;
const decodeImportPaste = (decoder as any).decodeImportPaste;
let failed = 0;
const seen = new Map<string, { sha256: string; guids: string }>();
for (const file of readdirSync('$TMP').filter((f) => f.endsWith('.txt')).sort()) {
  if (/(^|-)all-/.test(file)) { // Export all pastes, incl. beta-all-* fixtures
    if (!decodeImportPaste) { console.log('SKIP', file, '(needs Raid Ledger with ROK-1737)'); continue; }
    try {
      const r = decodeImportPaste(readFileSync('$TMP/' + file, 'utf8'));
      const parts = r.order.map((s: string) => s + ':' + r.sections[s].pages);
      const guids = new Set(r.order.map((s: string) => r.sections[s].payload.who.guid));
      if (guids.size !== 1) throw new Error('sections from different exporters');
      console.log('OK  ', file, JSON.stringify({ sections: parts.join(' '), tokens: r.tokens, inputBytes: r.inputBytes }));
    } catch (err) {
      failed++;
      const e = err as { code?: string; message?: string };
      console.log('FAIL', file, e.code ?? '', e.message ?? String(err));
    }
    continue;
  }
  try {
    const { payload, pages, sha256, inputBytes } = decodeImportString(readFileSync('$TMP/' + file, 'utf8'));
    const p = payload as any;
    const summary: Record<string, unknown> = { section: payload.section, pages, inputBytes,
      ruleset: payload.who.ruleset, guildName: payload.who.guildName ?? null, region: payload.client.region };
    if (p.section === 'char') Object.assign(summary, { gear: p.data.gear.length,
      talentNodes: p.data.talents.nodes.length, lockouts: p.data.lockouts.length });
    if (p.section === 'guild') {
      const guids = p.data.members.map((m: { guid: string }) => m.guid);
      const notes = p.data.members.filter((m: { note?: string }) => m.note !== undefined).length;
      Object.assign(summary, { members: guids.length, uniqueGuids: new Set(guids).size, notes,
        canViewOfficerNote: p.data.canViewOfficerNote,
        exporterListed: guids.includes(payload.who.guid) });
      const key = file.replace(/-reversed\.txt\$/, '.txt');
      const prev = seen.get(key);
      const cur = { sha256, guids: guids.join(',') };
      if (prev) {
        const same = prev.sha256 === cur.sha256 && prev.guids === cur.guids;
        summary.reversedMatches = same;
        if (!same) throw new Error('reversed page order decoded differently');
      } else seen.set(key, cur);
    }
    if (p.section === 'raid') Object.assign(summary, { pulls: p.data.pulls.length,
      maxRoster: Math.max(...p.data.pulls.map((x: { roster: string[] }) => x.roster.length)),
      firstStartAt: p.data.pulls[0]?.startAt });
    if (JSON.stringify(payload).includes('officerNote')) throw new Error('officerNote present');
    console.log('OK  ', file, JSON.stringify(summary));
  } catch (err) {
    failed++;
    const e = err as { code?: string; message?: string };
    console.log('FAIL', file, e.code ?? '', e.message ?? String(err));
  }
}
if (failed) { console.log(failed + ' string(s) failed to decode'); process.exit(1); }
console.log('all strings decoded with zero errors');
TS

cd "$RL/api" && ${TSX:-npx --no-install tsx} "$TMP/decode.ts"
