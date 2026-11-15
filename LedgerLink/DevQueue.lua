-- Raid Ledger Companion probe queue (dev-bridge v1, `/rl dev`). This file ships
-- empty. While the operator uses the Companion's dev bridge, the Companion
-- overwrites it with `RaidLedgerProbeQueue = [==[<probe-queue JSON>]==]`;
-- DevProbes.lua reads that string as JSON (never as code), only in dev mode.
RaidLedgerProbeQueue = nil
