-- Adapters/DandersFrames.lua
--
-- The adapter's only job now is frame discovery: report which DandersFrames
-- unit frames are currently visible and which unit each is showing. All aura
-- and cooldown logic lives in the core.

local SI = SwiftmendIndicator

local DFAdapter = {}
DFAdapter.name = "DandersFrames"

function DFAdapter:IsActive()
    return DandersFrames ~= nil and DandersFrames.unitFrameMap ~= nil
end

function DFAdapter:GetActiveFrames()
    local list, seen = {}, {}
    if not self:IsActive() then return list end

    -- unitFrameMap holds both party and raid frame sets at once, with only one
    -- set visible at a time, and maps several tokens ("player" and "raid1") to
    -- the same frame. Filter to visible frames and dedupe by frame object.
    for unit, frame in pairs(DandersFrames.unitFrameMap) do
        if frame:IsVisible() and not seen[frame] then
            seen[frame] = true
            table.insert(list, { frame = frame, unit = unit })
        end
    end

    return list
end

SI.RegisterAdapter(DFAdapter)
