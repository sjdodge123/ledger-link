# Ledger Link

A World of Warcraft: Forever addon that exports your character, guild roster and
boss pulls as strings you
paste into your community's [Raid Ledger](https://sjdodge123.github.io/Raid-Ledger/)
site. Raid Ledger is self-hosted ([GitHub](https://github.com/sjdodge123/Raid-Ledger)),
so each guild or community runs its own. Addons can't make network
calls, so Ledger Link works like WeakAuras / Details exports: it builds the
data, compresses it, and shows it in a box you copy from.

```
/rl                  open the Ledger Link panel (or click the minimap button)
/rl help             list the commands
/rl minimap on|off   show or hide the minimap button
/rl export char      gear, talents and raid/dungeon lockouts
/rl export guild     guild roster (up to 2000 members; big guilds come in pages)
/rl export raid      recorded boss pulls (the last 50)
/rl export all       character + guild + raid in one box: copy once, paste once
/rl raid             how many pulls are recorded
/rl raid clear       forget recorded pulls
/rl guildnotes on|off  include PUBLIC notes in the guild export (default off)
/rl autoexport on|off  save an Export all on logout for the Raid Ledger Companion (default on)
/rl ruleset normal|pvp|rp|rppvp|hardcore     tell the export your ruleset (Hardcore and RP-PvP realms are detected automatically)
/rl region us|eu|kr|tw|cn   override the region; only used when the game doesn't report one (beta), where it is otherwise guessed from the game language. Raid Ledger has no China region: cn exports won't import
/rl status           last export times + recorded pull count
/rl probe            all beta checks in one copyable report (for bug reports)
/rl dev on|off       developer diagnostic snapshot for the Raid Ledger Companion (default off); /rl dev shows its state
```

**Raid Ledger Companion (outbox).** Every export also keeps a copy in
SavedVariables, so the Raid Ledger Companion app can upload it after you log out
or `/reload` (the game writes `WTF/Account/<ACCOUNT>/SavedVariables/LedgerLink.lua`
then). One entry per character, latest wins, at most 10 characters:
`LedgerLinkDB.outbox[<player GUID>] = { exportedAt, section, text, at, source }`,
where `text` is exactly the copy-box text (a paged export: every page, one per
line). On logout the addon also stores a fresh Export all by itself
(`source = "logout"`). By the time the game sends PLAYER_LOGOUT it has already
dropped your guild, gear and talents, so the addon keeps the last guild roster,
gear and talents it read while you played (in memory, this session only:
refreshed on entering/leaving the world, `GUILD_ROSTER_UPDATE` at most every
10 s, `PLAYER_GUILD_UPDATE`, `PLAYER_EQUIPMENT_CHANGED` and talent changes) and
the logout export uses them when the live read is empty. The guild page keeps
the `snapshotAt` of when the roster was read. Leaving the guild drops the cached
roster; an empty gear or talent read never replaces a cached one. If the roster
never loaded this session it stores the character alone, unless you clicked
Export earlier in the session. `/rl probe` shows what is cached (`logout
cache:` line). Turn this off with `/rl autoexport off` or the panel checkbox.
Pasting works exactly as before.

**Dev snapshot (`/rl dev`, developers only).** Off by default; nothing is written
until you type `/rl dev on`. While it is on, every logout or `/reload` stores one
diagnostic JSON string per character in
`LedgerLinkDB.dev.snapshots[<player GUID>]` (at most 10 characters, oldest
dropped): client version/build/locale/region, class, level, faction and whether
you are in a guild, each `Enum.GameRule` flag via `C_GameRules.IsGameRuleActive`, the result of each `/rl probe` API
call, which watched APIs exist, and the probe's section lines (Raid Ledger
ROK-2072, dev-bridge/v1 `ledgerlink-snapshot`). It is capped at 48 KiB and cut
(marked `truncated`) rather than growing. The snapshot never holds a name,
realm, guild name or GUID: name-bearing calls are recorded as "present" only and
any GUID-shaped text is replaced with `<guid>`; only the table key is the GUID,
as in the outbox. `/rl dev off` turns it off and deletes every saved snapshot;
`/rl dev` (or `/rl dev status`) says whether it is on and how many characters
are saved. The Raid Ledger Companion reads it from SavedVariables and keeps the
latest plus 7 days of history on your own PC only (never uploaded to Raid
Ledger), so a developer can query it over the Companion's local dev bridge
instead of asking you to paste `/rl probe`.

**Guild export.** Officer notes are never read or exported, whatever your rank
(`canViewOfficerNote` is always `false`). Public notes are left out unless you
turn them on with `/rl guildnotes on`. A guild of more than 250 members is split
into pages of 250 (`!RL1!guild-1of3!...`, at most 8 pages = 2000 members). The
export window shows **Page 1/3** with **< Prev / Next >**: copy every page and
paste them all into the one Raid Ledger import box, in any order, separated by
a newline or space. A guild of more than 2000 members keeps you, then online
members, then the most recently seen, and says how many were left out.

The guild export also carries the guild's in-game **Message of the Day**
(`motd`, at most 255 UTF-16 units) and **Guild Information** (`infoText`, at
most 499), exactly as the game holds them (colour codes and newlines kept), so
Raid Ledger can tell officers when they changed in game (ROK-2137). An empty
box is sent as `""`. A box the addon could not read is left out, which Raid
Ledger reads as "no opinion" and keeps what it had. Both are read with
`C_GuildInfo.GetMOTD()` / `C_GuildInfo.GetInfoText()` (falling back to the
pre-12.0 `GetGuildRosterMOTD()` / `GetGuildInfoText()`), kept with the cached
roster for the logout export, and sent on page 1 of a paged roster.

**Raid export.** While the addon is loaded it records every boss pull
(`ENCOUNTER_START` / `ENCOUNTER_END`): encounter, difficulty, kill or wipe,
start/end time (unix seconds) and the group roster at the pull (up to 40
GUIDs + names). The newest **50** pulls are kept in `LedgerLinkDB.raid.pulls`
(SavedVariables); older ones drop off. Every raid export resends the whole
buffer (Raid Ledger dedupes pulls it already has). If the string would be too
large for Raid Ledger, it keeps the newest pulls that fit and the chat says how
many were left out (ROK-2123). There is no damage or DPS data: the
combat log (`COMBAT_LOG_EVENT_UNFILTERED`) is closed to addons on Forever, so
Details!/DBM-style log parsing is impossible in-game.

**Export all.** The panel's **Export to Raid Ledger** button (or `/rl export all`) shows
the character string, every guild page and the raid string in one box, one per
line, to paste into Raid Ledger in one go (Raid Ledger ROK-1737, CONTRACT.md
§5.1). Each string keeps its normal format. No guild or no recorded pulls?
That section is left out and the chat says so. The raid string gets whatever
room the character and guild strings leave under Raid Ledger's 256 KB limit
(the oldest pulls go first); if even that is not enough, the paste is refused
with a hint to export the guild on its own.

**Panel.** `/rl` or the minimap button opens a small window with one
**Export to Raid Ledger** button (the Export all paste; the per-section exports
stay as optional `/rl export char|guild|raid`), ruleset buttons, the public-guild-notes checkbox, the recorded
pull count (with Clear), a Beta probe button, and, only when the game doesn't
report a region (the beta), region buttons. Every control does exactly what the
matching slash command does. Drag the minimap button around the minimap edge;
its position is saved. The addon list shows the Ledger Link icon
(`## IconTexture`, `Textures/Icon.tga`).

`/ledgerlink` works everywhere `/rl` does (handy if another addon already owns
`/rl`, which many use as a `/reload` shortcut).

## Beta install

1. Copy the `LedgerLink/` folder into
   `World of Warcraft/_classic_beta_/Interface/AddOns/`
   (you should end up with `AddOns/LedgerLink/LedgerLink.toc`).
2. In game, `/reload` (or log in), and make sure **Ledger Link** is ticked in
   the AddOns list on the character screen.
3. `/rl ruleset normal` (or `pvp`, `rp`, `rppvp`, `hardcore`) once per character. On the
   beta the region is guessed from the game language (the client reports a test
   region); `/rl region us` (or `eu`, `kr`, `tw`) corrects a wrong guess.
4. `/rl export char`, then **click the text** (that selects all of it) and
   Ctrl+C.
5. On your community's Raid Ledger site: your character -> **Import string** -> paste.

## Beta test checklist (operator)

Run these in game on the beta and paste the results back (into the Linear
story or a GitHub issue). `/console scriptErrors 1` first so Lua errors show.

1. `/rl probe`, Ctrl+C, paste the whole report back. It runs every check from
   "Beta unknowns" below (read-only; the officer note is never included), so no
   `/dump` lines need typing.
2. **Char:** `/rl ruleset normal`, `/rl export char`, copy, paste into Raid
   Ledger's import preview. Paste back: the preview (or error text).
3. **Guild roster APIs:** open the Guild window, then `/rl probe` again (the
   roster lines fill in once the roster has loaded).
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
9. **Mailer discovery (S5, for a second addon):** with Auctionator and
   Disenchantry installed and an Auctionator scan done, stand at a mailbox,
   open it, click the **Send Mail** tab, then `/rl probe`. Paste back the whole
   report. Nothing is mailed. Use the gamepad to open the mailbox (so the
   game's controller UI and its button hints are showing): the `S6` lines
   look for what drives it. Before `/rl probe`, also press Triangle on any
   bag item and open its menu (then close it): the `S7` lines name that menu.
10. **AH deposits (S8):** at the auction house, with the AH window open,
    `/rl probe` and paste back the report. Nothing is posted.

## Reporting a bug

Open an issue with:

- what you typed and what happened;
- the export string (char: your name, gear, talents and lockouts; guild: the
  roster's names, ranks, levels, classes, online state and - only if you ran
  `/rl guildnotes on` - public notes, plus the guild's Message of the Day and
  Guild Information; raid: boss pulls and who was in the group. Never officer
  notes, never account data), or
- the Lua error text: `/console scriptErrors 1`, reproduce, then copy the error
  popup;
- the client build: `/dump GetBuildInfo()`.

## The string format

```
!RL1!<section>!<standard base64, padded>( zlib( JSON ) )
!RL1!guild-<n>of<m>!...   one page of a paged guild export (m <= 8)
```

Every page of one guild export repeats the same envelope (`exportedAt`, `who`)
and the same `name` / `rawRealm` / `snapshotAt`; only `members` is split, and
`motd` / `infoText` ride on page 1. The
server sorts pages by number and refuses a set from different exports, a
missing page or a member listed twice. The whole paste must stay under the
server's 256 KB limit; the addon refuses anything bigger.

The JSON is the Raid Ledger contract `ledgerlink/v1`, which **Raid Ledger owns**
(`packages/contract/ledgerlink/v1/` there, generated from `AddonExportSchema`).
This repo pins a copy in `contract/v1/` (`SOURCE` = the Raid Ledger commit);
refresh it with `tools/sync-contract.sh <raid-ledger-checkout> [ref]`, never by
hand, and never change the format here (see `AGENTS.md`). The same script also
pins `contract/dev-bridge/v1/` (Raid Ledger `packages/contract/companion/dev-bridge/v1/`),
whose `$defs/ledgerlink-snapshot` is the `/rl dev` snapshot. Every object is strict:
an unknown key rejects the whole string, so the addon never emits extra fields.
Since the 2026-10-10 contract (Raid Ledger ROK-1742, `contract/v1` at
`3b4418ff`) the `char` section also carries `who.gender`, **every** talent
node (rank 0 included) with `name`, `spellId`, `maxRanks`, raw `posX`/`posY` and
the `tree`/`row`/`col` hint from `TalentGrid.lua` (CONTRACT.md §3), and
`data.quests`: completed quest ids ascending (capped at 10 000, then
`completedTruncated: true` and a chat note) and up to 35 quest-log quests with up
to 10 objectives each (`text`, `done`, `have`, `need`). A level-8 character's
`char` string grows from about 0.7 KB to 2.6 KB.

**Mailworthy guild contributions (Raid Ledger ROK-2148).** When the
[Mailworthy](https://github.com/sjdodge123/mailworthy) addon is installed
(`## OptionalDeps: Mailworthy`, load order only), the `char` section carries
`data.mailworthy` (CONTRACT.md §3.1): the guild template (profession masters),
Mailworthy users in the guild and the guild-rule items each character mailed,
from `MailworthyAPI.v1.GetGuildExport(<guild name>)`. The guild name is the one
cached while playing, so the logout export still has it. `Mailworthy.lua`
rebuilds the block from the keys the contract knows, with its caps (names ≤ 48
characters, dropped and never shortened; rules ≤ 8; peers ≤ 1000, newest first;
givers ≤ 200; days ≤ 35, newest), so a newer Mailworthy can't break the string.
No Mailworthy, no guild, a nil result or an error leaves the key out. A full
block adds about 40 KB to the `char` string.

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
gate. `spec/dev_snapshot_spec.lua` validates a normal and a worst-case `/rl dev`
snapshot against `contract/dev-bridge/v1/schema.json` `$defs/ledgerlink-snapshot`
(`node tools/validate-contract.mjs --dev-bridge ledgerlink-snapshot <file>`). As an optional local cross-check, `tools/verify-with-raid-ledger.sh` decodes the strings
`tools/gen_strings.lua` generates (char, guild single + 3-page + 8-page +
over-cap, raid) with Raid Ledger's actual server decoder
(`RAID_LEDGER_DIR=<checkout>`; Export all strings need a checkout with
ROK-1737, otherwise they are skipped; `TSX=<path to tsx>` if the checkout has
no `node_modules`), and checks that a paged guild paste decodes
identically with its pages reversed. It also decodes the anonymised real
strings in `spec/fixtures/beta/`, which `spec/contract_spec.lua` validates too.

**Export clock window** (Raid Ledger ROK-1756): the server refuses an
`exportedAt` (or guild `snapshotAt`) more than a day ahead of or a year behind
its clock. `spec/support/import.lua` mirrors it with an explicit clock:
`contract_spec` pins Raid Ledger's golden fixtures to 2026-09-21 + 1 h (as Raid
Ledger's `pin-export-clock.ts` does) and checks the beta strings against the real
clock. `tools/verify-with-raid-ledger.sh` runs Raid Ledger's real decoder with the
real clock, so the generated test strings (stamped 2026-09-21) stop passing it
after 2027-09-21; move the stub's `serverTime` forward then.

**Real strings from testers** become fixtures only after
`luajit tools/anonymise.lua <real.txt> spec/fixtures/beta/<name>.txt`: it
replaces player names, GUIDs (server id kept), guild names, public notes and
raid roster names consistently across pages, re-encodes, and fails if any
original survives. Keep the original paste out of the repo.

## Beta unknowns (check in game)

Every one of these is wrapped defensively (missing function -> skipped field or
a clear "please report this" message), but none is confirmed on Forever yet:

| API / behaviour | What to check | If wrong |
|---|---|---|
| `## Interface: 16001` | **confirmed** on beta build 1.60.1.70205 (2026-10-05) | addon shows "out of date" |
| `C_EncodingUtil.CompressString(s, Enum.CompressionMethod.Zlib, Enum.CompressionLevel.OptimizeForSize)` | export works at all | "C_EncodingUtil is missing" / "Compression failed" |
| `C_EncodingUtil.EncodeBase64` alphabet + padding | string pastes cleanly | URL-safe / unpadded output is normalised to standard padded either way |
| `UnitRace("player")` on new Forever races | "High Order Skyborne", token `"Skyborne"`, id 95 (probe 2026-10-05); the contract takes any race string ≤ 32 chars, so it exports | - |
| `GetCurrentRegion()` returns 1-5 | **no on the beta**: it returned `90` on build 70205 and **`110` on build 70291** (2026-10-09), so any value outside 1-5 is treated alike; `GetCurrentRegionName()` is `""` and the `portal` CVar is `"test"` (2026-10-05). Expected 1-4 on live: confirm with `/rl probe` on launch day | outside 1-5 the player's `/rl region` pick is sent, else a region guessed from `GetLocale()` (enUS/esMX/ptBR → us; enGB/deDE/frFR/esES/itIT/ruRU/ptPT → eu; koKR → kr; zhTW → tw; zhCN → cn; unknown → us), shown as "guessed" |
| `UnitGUID("player")` is `Player-<n>-<8 hex>` | **confirmed** on the beta (2026-10-05) | export refuses with "Unexpected player GUID format" |
| `GetUnitName("player", true)` returns "First Surname" | **confirmed** (probe, 2026-10-05); `UnitName`/`UnitFullName` return (first, surname), not a realm | `fullName` falls back to `UnitFullName` |
| `GetRealmName()` on a realmless client | beta returns `"Classic Beta PvP"` (probe, 2026-10-05) | stored raw only; the server ignores it |
| No ruleset API exists | `C_GameRules` exists on the beta. **Hardcore is auto-detected**: when the player hasn't picked a ruleset and `C_GameRules.IsHardcoreActive()` returns `true`, the export sends `hardcore` (shown as "hardcore (detected)"); the player's own pick always wins. `IsHardcoreActive()` was `false` on a PvP and a PvE realm; **`true` on a Hardcore character is unverified**: run `/rl probe` there. Normal/PvP/RP: `GetCurrentGameModeRecordID()` was 14 ("Classic Beta PvP") and 15 ("Classic Beta PvE 2"), other `C_GameRules` values equal; whether it tracks the ruleset needs an RP realm and a second PvP/PvE realm, and re-checking on live. **RP-PvP is auto-detected from the realm name**: no in-game API marks it (the realm list's `isRP`/`isPvP` are glue-screen only; `GameModeDisplayInfo` has no name), but live realms are named like "CAMWOW US2 Realm 9 RP PvP", so when the player hasn't picked a ruleset and `GetRealmName()` contains "RP PvP" / "RP-PvP" / "RPPvP" as a word (any case) the export sends `rppvp` (shown as "RP-PvP (detected)"; Hardcore wins when both apply; the beta's "Classic Beta PvP" does not match). **Unverified on a live RP-PvP realm**: run `/rl probe` there and check the `settings:` line says `export sends: RP-PvP (detected)`; a realm renamed without the words needs `/rl ruleset rppvp` | set it with `/rl ruleset` or the panel (`rppvp` / "RP-PvP" for RP-PvP realms); otherwise `null` (Raid Ledger may fill it from the realm) |
| `GetInventoryItemID` / `GetInventoryItemLink` / `C_Item.GetDetailedItemLevelInfo` | gear count + item levels in the import preview | slot skipped / `ilvl` omitted |
| `C_ClassTalents.GetActiveConfigID`, `C_Traits.GetConfigInfo/GetTreeNodes/GetNodeInfo/GenerateImportString` | talent node count in the import preview | `talents.nodes` empty |
| `GetNumSavedInstances` / `GetSavedInstanceInfo` (14th return `instanceId`) | lockouts in the import preview | lockout rows without an instance id are skipped |
| `## IconTexture` + uncompressed 32-bit TGA textures | Ledger Link shows its icon in the AddOns list (not the red "?"); the minimap button shows the round icon | default "?" icon / blank minimap button |
| `UICheckButtonTemplate`, `Interface\\ChatFrame\\ChatFrameBackground` (window fill), minimap textures (`MiniMap-TrackingBorder`, `UI-Minimap-Background`, `UI-Minimap-ZoomButton-Highlight`), `GetCursorPosition` | the panel checkbox and the minimap button look right and drag | cosmetic only |
| `BackdropTemplate`, `UIPanelScrollFrameTemplate`, `UIPanelButtonTemplate`, `UIPanelCloseButton` | the export window looks right | falls back to a plain frame (no border) |
| Very long strings in an `EditBox` | Ctrl+A / Ctrl+C on the biggest guild page | lower `Guild.MEMBERS_PER_PAGE` (250) |
| Requesting the roster from an addon (`C_GuildInfo.GuildRoster()`) | **not the cause** of the beta popup (alpha5 still showed it); the addon no longer requests the roster anyway: the client has it after login | the export waits for the roster the Guild window loads (`GUILD_ROSTER_UPDATE`) |
| `GetNumGuildMembers()` counts offline members | returns two values, `32, 24` (total, online) with the Guild window open (probe, 2026-10-05); checklist step 5 | offline members missing unless the Guild window shows them |
| `GetGuildRosterInfo(i)` return order (name 1, rank 2, rankIndex 3, level 4, note 7, online 9, class token 11, GUID 17) | **confirmed**, 17 returns (probe, 2026-10-05) | rows "unreadable and skipped"; the officer note (slot 8) is never read either way |
| Roster names are `"First Surname-<realm>"` | **no realm suffix** on the beta: `"First Surname"` (probe, 2026-10-05) | exported raw; Raid Ledger strips the suffix |
| Logout state: at `PLAYER_LOGOUT` `GetGuildInfo("player")` is nil, the roster is empty and `GetInventoryItemLink`/`C_ClassTalents` return nothing | **confirmed** from the operator's SavedVariables (every 2026-11-07 logout export: no guild page, `gear: []`, empty talents); the logout export now uses the play-time cache. Check: log out, then the Companion's outbox entry (`source = "logout"`) has a `!RL1!guild` page and non-empty gear | no guild page / empty gear at logout (as before) |
| `PLAYER_GUILD_UPDATE` + `IsInGuild()` on leaving a guild; `PLAYER_LEAVING_WORLD` before `PLAYER_LOGOUT` | leave a guild, log out: the logout export has no guild page. A no-guild `PLAYER_GUILD_UPDATE` after `PLAYER_LEAVING_WORLD` (teardown) is ignored; membership is checked again on `PLAYER_ENTERING_WORLD` | a left guild's roster is sent once more at logout (if leaving isn't seen); the cache dropped at logout (if the order differs) |
| `TRAIT_CONFIG_UPDATED`, `PLAYER_TALENT_UPDATE` (registered under pcall) | change a talent, log out at once: the logout export has the new talents | talents as of the last world entry / loading screen |
| `GetGuildRosterLastOnline(i)` (years, months, days) | returns nothing for an online member, as expected (probe, 2026-10-05); offline members still to check in the preview | `lastOnlineDays` omitted |
| `C_GuildInfo.GetMOTD()` / `C_GuildInfo.GetInfoText()` (guild export `motd` / `infoText`, ROK-2137) | Blizzard's own Forever Guild window calls both (UI source, builds 70009 and 70205); the pre-12.0 globals `GetGuildRosterMOTD` / `GetGuildInfoText` exist only as aliases when the `loadDeprecationFallbacks` CVar is on. The API docs mark both `HasRestrictions`. **Unverified in game from addon code**: `/rl probe` lists all four under presence and the `logout cache:` line says what was read (`motd 77 bytes` / `motd unread`). Also check both are loaded whenever the roster is (a read before the guild data arrives could return `""`) | the key is left out (missing API, an error, a non-string or a secret value); Raid Ledger keeps what it stored |
| `GetGuildInfo("player")` 4th return (realm) | **confirmed**: `"ClassicBetaPvP2"`, which differs from `GetRealmName()` (probe, 2026-10-05) | `rawRealm` falls back to `GetRealmName()` |
| `ENCOUNTER_START` / `ENCOUNTER_END` fire with IDs on Forever (E5) | `/rl raid` after a boss | no pulls recorded |
| `UnitGUID("raidN")` / `GetUnitName` readable during an encounter (secret values, E5) | roster count in the raid preview | roster re-read at `ENCOUNTER_END`; empty roster if both are secret |
| `GetInstanceInfo()` 8th return = instance id | **confirmed** (Kalimdor = 1, 11 returns) (probe, 2026-10-05) | `instanceId` omitted |
| `GetServerTime()` is unix seconds | **confirmed** (probe, 2026-10-05) | a millisecond value is divided down |
| "LedgerLink has been blocked from an action only available to the Blizzard UI" | **found and fixed** (beta 2026-10-05, playing with a gamepad): the blocked function was `SetPreferredGamepadInteractTarget()`. The export window called `editBox:SetFocus()` while the game was still handling the `/rl` command, and the gamepad UI reacted inside that addon-started call chain; any click afterwards crashed the client. The addon no longer moves focus: the player clicks the text. Still recorded via `ADDON_ACTION_FORBIDDEN` / `ADDON_ACTION_BLOCKED` (chat line + `/rl probe`) | **confirmed fixed** on v0.1.0-alpha6 with a gamepad (2026-10-05): no popup, no crash |
| Raid Ledger S3 request (2026-10-09): `UnitSex`, `C_Traits.GetEntryInfo` / `GetDefinitionInfo` + `C_Spell.GetSpellName` (talent names), node `posX`/`posY`, `C_QuestLog.GetAllCompletedQuestIDs` / `GetNumQuestLogEntries` / `GetInfo` / `GetQuestObjectives` | **confirmed** on the beta (Warrior, Druid, Paladin; build 70291) and **exported since Phase 2** (`who.gender`, full talent nodes, `data.quests`); `/rl probe` still lists them as `S3 …` lines | each piece is left out when its API is missing |
| Dungeon run + Forever "legacy talents" / "legacy challenges" (2026-10-09) | the `S4 …` lines of `/rl probe`, run **inside a dungeon** and again **after turning in its quests**: group (party GUID/name readability only, never values), map + dungeon-guide entry, difficulty, recorded pulls, every quest-log quest with level / suggested group / tag, dungeon quest flags, lockouts, every talent node with its computed tree/row/col, a scan for globals named legacy/forever/challenge (names only, never called), `C_Traits` systems 1-300 with a config, achievement categories (legacy/challenge ones in detail), item level / XP / professions | discovery only; nothing is exported |
| Mailer discovery (2026-10-13, for a second addon) | first report (v1.3.1): Auctionator 340 loaded, `API.v1` includes `GetAuctionAgeByItemLink`, `IsAuctionDataExactByItemLink`, `GetDisenchantPriceByItemLink`; Disenchantry 1.1.1's `DisenchantryDB` holds settings only (no prices); `GetAddOnMetadata(name, "SavedVariables")` returns nil; `GetContainerItemInfo` fields and the sell price confirmed; the AH is the modern `C_AuctionHouse` (commodities); `ATTACHMENTS_MAX_SEND` 12; `GetSendMailPrice()` 30 with nothing attached; `Settings.RegisterCanvasLayoutCategory` present, `InterfaceOptions_AddCategory` missing; bag item buttons are unnamed (`ContainerFrame1Item1` missing). `ah=` was nil on every item (no Auctionator scan yet). The `S5 item` lines now also show `ahAge`, `ahExact` and `commodity`: rerun after an Auctionator scan | discovery only; nothing is mailed, bound, auto-completed or exported, and no player name is printed |
| Forever's built-in gamepad UI ("smart navigation") | first report (v1.3.1, build 70338, 2026-10-13): the mail frames carry `FocusGamepad` / `InitializeGamepad` / `LockInFocus`, a `gamepadFooter` table, a `…FooterinputLegend` frame and a `smartNavigationFocusKey`; `C_Navigation`, `InputPromptMixin`, `InputPromptLegends` and `PromptedBindingFooterMixin` exist; no pad key has a normal binding (`GetBindingAction("PAD1")` = ""); `C_Console` is missing (`ConsoleGetAllCommands` exists). The `S6 …` lines now dump the footer tables and legend frames, every gamepad-related mixin, the `C_` navigation namespaces, `InputPromptLegends` and gamepad/cursor/smartnav CVars: run at a mailbox opened with the gamepad | discovery only; nothing found is called |
| Gamepad "More" menu on a bag slot (Triangle; 2026-10-13, for a second addon's "Lock slot" entry) | the `S7 …` lines of `/rl probe`: context-action labels (`CONTEXT_ACTION_…`), context/menu mixins, the `Menu` / `MenuUtil` API (`Menu.ModifyMenu`), and every menu opened since login (method, owner frame, tag, entry texts). **Press Triangle on a bag item and open its menu before running the probe** | discovery only; the recorder is a post-hook that reads the menu and never changes it |
| Auction house deposits (2026-10-13, for a second addon) | the `S8 …` lines of `/rl probe`, run **with the auction house open**: for each tradeable bag stack (commodity or item), the deposit for 12h / 24h / 48h, whole stack and one unit (`C_AuctionHouse.CalculateItemDeposit` / `CalculateCommodityDeposit`) next to its vendor price | calculations only; nothing is posted |
| Professions (2026-10-22, Raid Ledger ROK-1907 `char.professions`) | the `S9 …` lines of `/rl probe`, run on a character that has at least one profession: `GetProfessions()` slots and `GetProfessionInfo(index)` (name, skill, max, skillLine), `C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)`, and every `C_SkillInfo.GetSkillLineInfo` line (professions marked by SkillLine ID). One `S9 verdict: YES via <source>: Mining 75/150, …` line per source that worked, or `S9 verdict: NO` | discovery only; nothing is exported until Raid Ledger adds the field to the contract. Never expands a skill header |
| `MailworthyAPI.v1.GetGuildExport(guildName)` (the Mailworthy addon, v0.31.0+; not a WoW API) | with Mailworthy installed and a guild template published, `/rl export char` and Raid Ledger's import preview: the guild hub's Guild contributions widget fills in after the import. Also at logout (the Companion outbox entry) | called under `pcall`; any problem leaves `data.mailworthy` out and the rest of the export is unchanged |
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

**Release gate (ROK-2148):** a Raid Ledger server without ROK-2148 rejects a
`char` string carrying `data.mailworthy` with 422 `INVALID_PAYLOAD`. Don't tag a
release that emits it until sjdodge123/Raid-Ledger#2028 is merged **and** deployed to
prod; confirm with the operator first.
