-- In-app updater: check jsDelivr for a newer release, hand off to setup.lua.
--
-- Everything here stands on the same delivery facts as setup.lua (and the
-- "Доставка файлов" section of DETAILS.md):
--
--   * raw.githubusercontent.com is not reachable from many OpenComputers
--     servers — its TLS handshake is dropped — so the check uses cdn.jsdelivr.net
--     only. There is no mirror probing here; if jsDelivr is down the user still
--     has the terminal installer.
--
--   * The CHECK reads the moving @latest ref, which jsDelivr resolves to the
--     newest git tag. The APPLY pins to that resolved TAG (@vX.Y.Z), never a
--     moving ref: jsDelivr caches a branch/moving ref per file for hours, so
--     @latest/@main can serve files from different commits and leave a mix that
--     only fails in-game. A tag is immutable.
--
--   * The actual install is delegated to setup.lua, which is downloaded fresh
--     from that tag and then run. This module deliberately does NOT keep its own
--     copy of the file manifest, mirror list, or version check — setup.lua is
--     the single source of truth, and it already preserves settings and verifies
--     that the expected version really landed.
--
-- None of this is desktop-testable — it needs the Internet Card and the OpenOS
-- shell — so component/shell are required lazily, inside the functions that use
-- them. The module itself loads fine under plain Lua, which keeps it out of the
-- way of the test suite's load-time smoke check.

local update = {}

update.REPO = "happyCat-dev/ARGUS"
update.PROBE = "/tmp/argus-version"
update.SETUP_PATH = "/home/setup.lua"

local function jsdelivr(ref, file)
    return "https://cdn.jsdelivr.net/gh/" .. update.REPO .. "@" .. ref .. "/" .. file
end

-- The version this install reports. version.lua is a script re-read from disk,
-- so this is always the running build.
function update.current()
    local ok, version = pcall(require, "version")
    return ok and tostring(version) or "?"
end

-- Pull "X.Y.Z" out of a version.lua body (return "X.Y.Z").
function update.parseVersion(body)
    if type(body) ~= "string" then return nil end
    return body:match('"([^"]+)"')
end

-- Normalise a version or tag to the tag form setup.lua installs from: "2.5.0"
-- and "v2.5.0" both become "v2.5.0". A commit SHA (no leading digit-dot) is left
-- alone, since it is already an immutable ref.
function update.tagFor(version)
    version = tostring(version)
    if version:match("^%d") then return "v" .. version end
    return version
end

-- wget one URL to a path. Returns true on success. Isolated so the two callers
-- fetch the same way setup.lua does (-f overwrite, -q quiet).
local function fetch(url, target)
    local shell = require("shell")
    return shell.execute("wget -f -q " .. url .. " " .. target) and true or false
end

-- Look up the latest published version. Returns a table
--   {current = "2.4.0", latest = "2.5.0", available = true}
-- or nil plus a reason. "available" means the latest differs from the running
-- build — an explicit newer/older comparison is left out on purpose, because a
-- pinned reinstall of the same-or-different tag is exactly what the user wants
-- either way (recover a bad install, or move forward).
function update.check()
    local component = require("component")
    if not component.isAvailable("internet") then
        return nil, "no Internet Card"
    end
    local filesystem = require("filesystem")

    filesystem.remove(update.PROBE)
    if not fetch(jsdelivr("latest", "version.lua"), update.PROBE) then
        return nil, "could not reach cdn.jsdelivr.net"
    end

    local file = io.open(update.PROBE, "r")
    if not file then return nil, "download produced no file" end
    local body = file:read("*a")
    file:close()
    filesystem.remove(update.PROBE)

    local latest = update.parseVersion(body)
    if not latest then return nil, "unrecognised version file" end

    local current = update.current()
    return {current = current, latest = latest, available = latest ~= current}
end

-- Download the pinned setup.lua for `version`. Returns true, tag on success, or
-- false, reason. The caller then quits the app and runs setup.lua at that tag —
-- setup owns the rest (settings backup, the file list, the landed-version check).
-- Only the download happens here, so a failed fetch never leaves the caller
-- quitting into a half-updated tree.
function update.apply(version)
    local component = require("component")
    if not component.isAvailable("internet") then
        return false, "no Internet Card"
    end

    local tag = update.tagFor(version)
    if not fetch(jsdelivr(tag, "setup.lua"), update.SETUP_PATH) then
        return false, "could not download setup.lua from " .. tag
    end
    return true, tag
end

return update
