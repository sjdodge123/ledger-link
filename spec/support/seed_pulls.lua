-- Synthetic stored pulls (LedgerLinkDB.raid.pulls rows, oldest first) for the
-- pull-history size specs (Raid Ledger ROK-2123). Every pull has a full
-- 40-player roster of distinct, made-up GUIDs and long names: the worst case
-- for zlib, since nothing repeats across pulls. No real player data.
return function(count, firstEncounterId)
    local pulls = {}
    for i = 1, count do
        local roster, names = {}, {}
        for j = 1, 40 do
            local id = i * 40 + j
            roster[j] = string.format("Player-%04d-%08X", 4000 + (id * 7919) % 999, (id * 2654435761) % 0xFFFFFFFF)
            names[j] = string.format("Testplayer%05d Fakerealmname%03d", (id * 31) % 99991, (id * 17) % 997)
        end
        pulls[i] = {
            encounterId = (firstEncounterId or 1000) + i, name = "Boss " .. i, difficultyId = 9, groupSize = 40,
            instanceId = 409, startAt = 1780000000 + i * 600, endAt = 1780000000 + i * 600 + 300,
            success = i % 3 ~= 0, roster = roster, rosterNames = names,
        }
    end
    return pulls
end
