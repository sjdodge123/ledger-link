# LedgerLink agent rules

## The wire format belongs to Raid Ledger (STRICT)

LedgerLink's export strings are a wire format that Raid Ledger owns, at
`packages/contract/ledgerlink/vN/` in the Raid Ledger repo (`CONTRACT.md`,
`schema.json`, `fixtures/`, `CHANGELOG.md`). This repo pins a copy in
`contract/vN/` (`contract/vN/SOURCE` records the Raid Ledger commit), refreshed
only by `tools/sync-contract.sh`. The same script pins the `/rl dev` snapshot's
contract, `packages/contract/companion/dev-bridge/v1/` → `contract/dev-bridge/v1/`,
from the same Raid Ledger commit; the same rules apply to it.

- **Never change the wire format here**: no new, renamed or removed keys, types,
  envelope fields, encoding or compression changes. Raid Ledger rejects a whole
  string on any unknown key.
- **Never hand-edit `contract/`.** Re-sync it with `tools/sync-contract.sh`.
- If the addon needs a format change, **stop and tell the operator**, so a Raid
  Ledger story can change `ledgerlink/vN/` first. Then re-sync and update the addon.
- Real beta strings become fixtures only after anonymisation (no real player
  names, GUIDs or guild names).

## Working rules

- Branches and PRs only; never push to `main`, never force-push.
- Never invent WoW API functions. Wrap anything unverified in the beta
  (pcall / nil checks) and list it under "Beta unknowns" in README.md.
- Before every push: `eval "$(luarocks --lua-version=5.1 path)"`, then
  `busted --lua=luajit` and `luacheck .`.
- Before opening a PR: `git fetch origin main && codex review --base origin/main`.
  Fix each finding or say in the PR description why it was left. Run it again
  on the final diff if the fixes were substantial.
