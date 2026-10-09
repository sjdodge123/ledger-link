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

## Talent tree shape (confirmed 2026-10-09, v1.1.2 probe)

One `C_Traits` tree per class (1117 for Warrior), 52 nodes, holding the three
vanilla-style sub-trees side by side. Distinct positions with node counts:

| Sub-tree | posX columns (nodes) | Nodes |
|---|---|---|
| 0 (left) | 1020 (5), 1620 (6), 2220 (5), 2820 (1) | 17 |
| 1 (middle, Fury: Death Wish, Flurry, Improved Intercept) | 5020 (3), 5620 (7), 6220 (5), 6820 (2) | 17 |
| 2 (right) | 9080 (5), 9680 (5), 10280 (6), 10880 (2) | 18 |

Rows: posY 2130 (8), 2730 (8), 3330 (9), 3930 (10), 4530 (9), 5130 (5), 5730 (3):
7 rows, 52 nodes in total.

**Mapping:** columns and rows are 600 apart; the gap between sub-trees is about
2200. So:

- `tree` = which column group (cluster posX values; a gap > 600 starts a new group),
  0-2 left to right, which matches the in-game tab order (Arms, Fury, Protection
  for Warrior);
- `col` = (posX - the group's first posX) / 600, 0-3;
- `row` = (posY - 2130) / 600, 0-6.

Caveat: the groups' first columns differ (1020, 5020, **9080**), so `col` must be
measured from each group's own first column, not one global origin. Only one
class (Warrior) has been probed; another class confirms the 600 spacing and
2130 origin hold everywhere.

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
- The talent mapping on a second class (spacing and row origin).
