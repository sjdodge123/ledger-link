# Ledger Link

A World of Warcraft: Forever addon that exports your character as a string you
paste into [Raid Ledger](https://raid.gamernight.net). Addons can't make network
calls, so Ledger Link works like WeakAuras / Details exports: it builds the
data, compresses it, and shows it in a box you copy from.

```
/rl export char      gear, talents and raid/dungeon lockouts (works now)
/rl export guild     guild roster            (not yet supported)
/rl export raid      recorded boss pulls     (not yet supported)
/rl ruleset normal|pvp|rp|hardcore           tell the export your ruleset
/rl status           last export times
```

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

## Reporting a bug

Open an issue with:

- what you typed and what happened;
- the export string (it holds your character name, gear, talents and lockouts
  and nothing else - no officer notes, no account data), or
- the Lua error text: `/console scriptErrors 1`, reproduce, then copy the error
  popup;
- the client build: `/dump GetBuildInfo()`.

## The string format

```
!RL1!<section>!<standard base64, padded>( zlib( JSON ) )
```

The JSON is the Raid Ledger contract `AddonExportSchema`
(`packages/contract/src/wow-addon-export.schema.ts`). Every object is strict:
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
eval "$(luarocks --lua-version=5.1 path)"
luacheck .
busted --lua=luajit
```

`spec/support/wow_stub.lua` stubs every WoW API the addon calls;
`C_EncodingUtil` is backed by LibDeflate + pure-Lua base64, so test strings are
real strings. `tools/verify-with-raid-ledger.sh` decodes generated strings with
Raid Ledger's actual server decoder (`RAID_LEDGER_DIR=<checkout>`).

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
| Very long strings in an `EditBox` (guild exports, lane 2) | Ctrl+A / Ctrl+C on a large export | paging (`!RL1!guild-1of3!...`) |
| SavedVariables reload bug (beta) | `/rl status` after a relog | status history is empty; exports still work |
