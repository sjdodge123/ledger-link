# Ledger Link

A World of Warcraft: Forever addon that exports your character, guild roster and
boss pulls as strings you
paste into [Raid Ledger](https://raid.gamernight.net). Addons can't make network
calls, so Ledger Link works like WeakAuras / Details exports: it builds the
data, compresses it, and shows it in a box you copy from.

```
/rl export char      gear, talents and raid/dungeon lockouts
/rl export guild     guild roster (up to 2000 members; big guilds come in pages)
/rl export raid      recorded boss pulls (the last 50)
/rl raid             how many pulls are recorded
/rl raid clear       forget recorded pulls
/rl guildnotes on|off  include PUBLIC notes in the guild export (default off)
/rl ruleset normal|pvp|rp|hardcore           tell the export your ruleset
/rl status           last export times + recorded pull count
```

**Guild export.** Officer notes are never read or exported, whatever your rank
(`canViewOfficerNote` is always `false`). Public notes are left out unless you
turn them on with `/rl guildnotes on`. A guild of more than 250 members is split
into pages of 250 (`!RL1!guild-1of3!...`, at most 8 pages = 2000 members). The
export window shows **Page 1/3** with **< Prev / Next >**: copy every page and
paste them all into the one Raid Ledger import box, in any order, separated by
a newline or space. A guild of more than 2000 members keeps you, then online
members, then the most recently seen, and says how many were left out.

**Raid export.** While the addon is loaded it records every boss pull
(`ENCOUNTER_START` / `ENCOUNTER_END`): encounter, difficulty, kill or wipe,
start/end time (unix seconds) and the group roster at the pull (up to 40
GUIDs + names). The newest **50** pulls are kept in `LedgerLinkDB.raid.pulls`
(SavedVariables); older ones drop off. There is no damage or DPS data: the
combat log (`COMBAT_LOG_EVENT_UNFILTERED`) is closed to addons on Forever, so
Details!/DBM-style log parsing is impossible in-game.

`/ledgerlink` works everywhere `/rl` does (handy if another addon already owns
`/rl`, which many use as a `/reload` shortcut).

## Beta install

1. Copy the `LedgerLink/` folder into
   `World of Warcraft/_classic_beta_/Interface/AddOns/`
   (you should end up with `AddOns/LedgerLink/LedgerLink.toc`).
2. In game, `/reload` (or log in), and make sure **Ledger Link** is ticked in
   the AddOns list on the character screen.
3. `/rl ruleset normal` (or `pvp`, `rp`, `hardcore`) once per character.
4. `/rl export char`, then Ctrl+C (the text is pre-selected; **Select all**
   re-selects it).
5. In Raid Ledger: your character -> **Import string** -> paste.

## Beta test checklist (operator)

Run these in game on the beta and paste the results back (into the Linear
story or a GitHub issue). `/console scriptErrors 1` first so Lua errors show.

1. `/dump GetBuildInfo()` and `/dump GetCurrentRegion()` - paste both.
2. **Char:** `/rl ruleset normal`, `/rl export char`, copy, paste into Raid
   Ledger's import preview. Paste back: the preview (or error text).
3. **Guild roster APIs:** `/dump GetNumGuildMembers()` and
   `/dump GetGuildRosterInfo(1)` (all returns; blank out the officer note
   before pasting) and `/dump C_GuildInfo and C_GuildInfo.GuildRoster`.
4. **Guild export:** open the Guild window once, then `/rl export guild`.
   Paste back: the chat lines it printed (skipped / duplicate / left-out
   counts, page count), whether **Page x/y** + Prev/Next work, and how long
   Ctrl+A / Ctrl+C takes on the biggest page (E7). Then paste ALL pages into
   one Raid Ledger import box (try reversed order too) and paste back the
   preview's member count.
5. Repeat 4 with the Guild window's **Show offline members** ticked and
   unticked - paste back both member counts.
6. **Raid:** pull a boss (dungeon boss is fine). `/rl raid` should say 1 pull.
   `/rl export raid`, paste into Raid Ledger, paste back the preview. Note
   whether the roster count matches your group.
7. `/reload`, then `/rl raid` - is the pull still there? (SavedVariables bug.)
8. Any Lua error popup text, verbatim.

## Reporting a bug

Open an issue with:

- what you typed and what happened;
- the export string (char: your name, gear, talents and lockouts; guild: the
  roster's names, ranks, levels, classes, online state and - only if you ran
  `/rl guildnotes on` - public notes; raid: boss pulls and who was in the
  group. Never officer notes, never account data), or
- the Lua error text: `/console scriptErrors 1`, reproduce, then copy the error
  popup;
- the client build: `/dump GetBuildInfo()`.

## The string format

```
!RL1!<section>!<standard base64, padded>( zlib( JSON ) )
!RL1!guild-<n>of<m>!...   one page of a paged guild export (m <= 8)
```

Every page of one guild export repeats the same envelope (`exportedAt`, `who`)
and the same `name` / `rawRealm` / `snapshotAt`; only `members` is split. The
server sorts pages by number and refuses a set from different exports, a
missing page or a member listed twice. The whole paste must stay under the
server's 256 KB limit; the addon refuses anything bigger.

The JSON is the Raid Ledger contract `ledgerlink/v1`, which **Raid Ledger owns**
(`packages/contract/ledgerlink/v1/` there, generated from `AddonExportSchema`).
This repo pins a copy in `contract/v1/` (`SOURCE` = the Raid Ledger commit);
refresh it with `tools/sync-contract.sh <raid-ledger-checkout> [ref]`, never by
hand, and never change the format here (see `AGENTS.md`). Every object is strict:
an unknown key rejects the whole string, so the addon never emits extra fields.
JSON is produced by the addon's own encoder (`Json.lua`) so empty lists encode
as `[]` and an unknown ruleset as `null`; `C_EncodingUtil` does the zlib
compression and base64.

## Development

Needs LuaJIT (Lua 5.1 semantics, same as the client), busted, luacheck,
libdeflate and dkjson:

```sh
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" --local install busted
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" --local install luacheck
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" --local install libdeflate
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" --local install dkjson
npm ci   # ajv, for the contract schema check
eval "$(luarocks --lua-version=5.1 path)"
luacheck .
busted --lua=luajit
```

`spec/support/wow_stub.lua` stubs every WoW API the addon calls;
`C_EncodingUtil` is backed by LibDeflate + pure-Lua base64, so test strings are
real strings. `spec/contract_spec.lua` validates every page of every export
case (`spec/support/export_cases.lua`) against `contract/v1/schema.json`, and
decodes `contract/v1/fixtures/` once Raid Ledger publishes them; that is the CI
gate. As an optional local cross-check, `tools/verify-with-raid-ledger.sh` decodes the strings
`tools/gen_strings.lua` generates (char, guild single + 3-page + 8-page +
over-cap, raid) with Raid Ledger's actual server decoder
(`RAID_LEDGER_DIR=<checkout>`), and checks that a paged guild paste decodes
identically with its pages reversed.

## Beta unknowns (check in game)

Every one of these is wrapped defensively (missing function -> skipped field or
a clear "please report this" message), but none is confirmed on Forever yet:

| API / behaviour | What to check | If wrong |
|---|---|---|
| `## Interface: 16001` | `/dump select(4, GetBuildInfo())` | addon shows "out of date" |
| `C_EncodingUtil.CompressString(s, Enum.CompressionMethod.Zlib, Enum.CompressionLevel.OptimizeForSize)` | export works at all | "C_EncodingUtil is missing" / "Compression failed" |
| `C_EncodingUtil.EncodeBase64` alphabet + padding | string pastes cleanly | URL-safe / unpadded output is normalised to standard padded either way |
| `GetCurrentRegion()` returns 1-5 | `/dump GetCurrentRegion()` | export refuses with "Couldn't read your region" |
| `UnitGUID("player")` is `Player-<n>-<8 hex>` | `/dump UnitGUID("player")` | export refuses with "Unexpected player GUID format" |
| `GetUnitName("player", true)` returns "First Surname" | `/dump GetUnitName("player", true)` | `fullName` falls back to `UnitFullName` |
| `GetRealmName()` on a realmless client | `/dump GetRealmName()` | stored raw only; the server ignores it |
| No ruleset API exists | - | set it with `/rl ruleset`; otherwise `null` |
| `GetInventoryItemID` / `GetInventoryItemLink` / `C_Item.GetDetailedItemLevelInfo` | gear count + item levels in the import preview | slot skipped / `ilvl` omitted |
| `C_ClassTalents.GetActiveConfigID`, `C_Traits.GetConfigInfo/GetTreeNodes/GetNodeInfo/GenerateImportString` | talent node count in the import preview | `talents.nodes` empty |
| `GetNumSavedInstances` / `GetSavedInstanceInfo` (14th return `instanceId`) | lockouts in the import preview | lockout rows without an instance id are skipped |
| `BackdropTemplate`, `UIPanelScrollFrameTemplate`, `UIPanelButtonTemplate`, `UIPanelCloseButton` | the export window looks right | falls back to a plain frame (no border) |
| Very long strings in an `EditBox` | Ctrl+A / Ctrl+C on the biggest guild page | lower `Guild.MEMBERS_PER_PAGE` (250) |
| `C_GuildInfo.GuildRoster()` (or legacy `GuildRoster()`) + `GUILD_ROSTER_UPDATE` | `/rl export guild` right after login | "Loading the guild roster..." and no window: run it again |
| `GetNumGuildMembers()` counts offline members | checklist step 5 | offline members missing unless the Guild window shows them |
| `GetGuildRosterInfo(i)` return order (name 1, rank 2, rankIndex 3, level 4, note 7, online 9, class token 11, GUID 17) | `/dump GetGuildRosterInfo(1)` | rows "unreadable and skipped"; the officer note (slot 8) is never read either way |
| Roster names are `"First Surname-<realm>"` | same dump | exported raw; Raid Ledger strips the suffix |
| `GetGuildRosterLastOnline(i)` (years, months, days) | offline members' "last online" in the preview | `lastOnlineDays` omitted |
| `GetGuildInfo("player")` 4th return (realm) | guild preview | `rawRealm` falls back to `GetRealmName()` |
| `ENCOUNTER_START` / `ENCOUNTER_END` fire with IDs on Forever (E5) | `/rl raid` after a boss | no pulls recorded |
| `UnitGUID("raidN")` / `GetUnitName` readable during an encounter (secret values, E5) | roster count in the raid preview | roster re-read at `ENCOUNTER_END`; empty roster if both are secret |
| `GetInstanceInfo()` 8th return = instance id | raid preview | `instanceId` omitted |
| `GetServerTime()` is unix seconds | pull times in the preview | a millisecond value is divided down |
| SavedVariables reload bug (beta) | `/rl status` / `/rl raid` after a relog | status history and recorded pulls are empty; only this session's pulls export |

## Releases

Pushing a `v*` tag runs `.github/workflows/release.yml` (BigWigsMods packager):
it builds `LedgerLink-<tag>.zip` and attaches it to a GitHub Release; tags
containing `alpha`/`beta` are pre-releases. CI also builds the zip on every push
without uploading and runs `tools/check-package-layout.sh`, which fails unless
the zip holds only `LedgerLink/LedgerLink.toc`, the files it loads, LICENSE and the generated CHANGELOG.md.
The version in the .toc and `ns.VERSION` is `@project-version@`, which the
packager replaces with the tag (the layout check fails if any keyword is left).
CurseForge uploads are on (project 1728299, `CF_API_KEY` secret). Wago stays off
until the `WAGO_API_TOKEN` secret and a `## X-Wago-ID` .toc line exist.
Listing artwork and copy live in `media/` (not packaged).
