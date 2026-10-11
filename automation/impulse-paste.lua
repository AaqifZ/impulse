-- Impulse emoji picker: paste after Impulse copies an emoji.
-- Impulse opens hammerspoon://impulse-paste; Hammerspoon holds Accessibility permission and presses Command-V.
-- Only Impulse may ask, and the request takes no parameters, so nothing else can trigger a paste.
local M = {}

function M.setup()
    hs.urlevent.bind("impulse-paste", function(_, params, senderPID)
        local sender = senderPID and senderPID > 0 and hs.application.applicationForPID(senderPID)
        if not sender or sender:bundleID() ~= "io.github.aaqifz.impulse" or next(params) ~= nil then
            return
        end
        hs.eventtap.keyStroke({"cmd"}, "v", 0)
    end)
    return M
end

return M
