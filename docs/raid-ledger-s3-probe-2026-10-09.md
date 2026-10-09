# Raid Ledger S3 request: Phase 1 probe results (2026-10-09)

Answers `planning-artifacts/LEDGERLINK-S3-REQUEST-2026-10-09.md` (Raid Ledger), Phase 1.
Source: `/rl probe` on LedgerLink v1.1.1, WoW: Forever beta build **1.60.1.70291**
(interface 16001), Alliance Night Elf **Warrior, level 8**, realm "Classic Beta PvP".
Read-only probes; nothing new is exported.

## Probe table

| # | API | Exists | Returns data | Sample |
|---|---|---|---|---|
| 1 | `UnitSex("player")` | yes | yes | `2` (male) |
| 2a | `C_ClassTalents.GetActiveConfigID()` → `C_Traits.GetConfigInfo(configId).treeIDs` | yes | yes | config `12937387`, **one** tree `1117` |
| 2b | `C_Traits.GetTreeNodes(1117)` | yes | yes | **52** nodes, 1 with a rank at level 8 |
| 2c | `C_Traits.GetNodeInfo(configId, nodeId)`: `posX`, `posY`, `entryIDs`, `activeRank` | yes | yes | node `105926`: posX `6820`, posY `4530`, entryIDs `{130656}`, activeRank `0` |
| 2d | `C_Traits.GetEntryInfo(configId, entryId).definitionID` | yes | yes | `130656` → `135457` |
| 2e | `C_Traits.GetDefinitionInfo(definitionId).spellID` | yes | yes | `135457` → `20504` |
| 2f | `C_Spell.GetSpellName(spellID)` | yes | yes | `20504` → "Improved Intercept"; `12328` → "Death Wish"; `12319` → "Flurry" |
| 3 | `C_QuestLog.GetAllCompletedQuestIDs()` | yes | yes | **40** ids at level 8 (first: 456, 457, 458, 459, 475). **Max-level count still to come.** |
| 4a | `C_QuestLog.GetNumQuestLogEntries()` | yes | yes | `15, 12` (entries incl. headers, quests) |
| 4b | `C_QuestLog.GetInfo(i)` | yes | yes | headers (`isHeader`, title "Teldrassil") and quests (`questID` 488, title "Zenn's Bidding") |
| 4c | `C_QuestLog.GetQuestObjectives(questID)` | yes | yes | `{ text = "2/3 Nightsaber Fang", finished = false, numFulfilled = 2, numRequired = 3, objectiveType = 1, type = "item" }`; types seen: `item`, `monster`, `log`; quest 98391 has **no** objectives (empty) |
| 5 | Anything that threw or returned nil | - | - | **none** |

## Talent tree shape

One `C_Traits` tree per class (1117 for Warrior), 52 nodes. Positions:
`posX` 1020–10880 with **12 distinct** values; `posY` 2130–5730 with **7 distinct**
values. The three sampled Fury talents (Improved Intercept, Death Wish, Flurry) are
in that same tree. Hypothesis: the vanilla-style 51-point layout, three sub-trees of 4
columns side by side (12 columns), 7 tiers (rows). **Not yet confirmed**: the next
probe lists the distinct posX/posY values and node counts per column so the
row/column/sub-tree mapping can be stated exactly.

## Sizes

- `char` token today: **970 bytes** (level 8, 10 gear items, 1 ranked node).
- 40 completed quest ids would add about **180 bytes encoded** (226 bytes of JSON):
  about 4.5 bytes per id encoded, 5.7 per id as JSON. Extrapolated, 2000 ids would be
  ~9 KB encoded / ~11 KB of JSON: far under `ADDON_IMPORT_MAX_BYTES` (262 144) and
  `ADDON_IMPORT_MAX_DECODED_BYTES` (1 048 576). The binding limit is the structural
  2000-items-per-array cap (CONTRACT §6); the max-level count decides whether it bites.

## Anonymised sample strings (for Raid Ledger fixtures)

In this repo, `spec/fixtures/beta/` (names, GUIDs, guild names and notes replaced by
`tools/anonymise.lua`; realms, items, quests and numbers kept):

- `char-warrior-l3-region90.txt`: char, level 3, build 70205
- `guild-39-members-1-page.txt`: guild, 39 members
- `all-char-guild208-v1.1.0.txt`: Export all (char + guild 208 members), build 70291

## Still open

- `GetAllCompletedQuestIDs()` count on a **max-level** character.
- Exact talent row/column/sub-tree mapping (distinct posX/posY values).
