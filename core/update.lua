-- In-app updater: check jsDelivr for a newer release, hand off to setup.lua.
--
-- Everything here stands on the same delivery facts as setup.lua (and the
-- "Доставка файлов" section of CLAUDE.md):
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

-- jsDelivr's data API lists published versions newest-first. It is the source of
-- truth for "what is the latest tag" — unlike the @latest file redirect, which
-- the CDN caches for hours. That stale @latest, combined with a plain string
-- "differs?" check, is exactly what once let an OLD tag pose as the latest and
-- downgraded an install.
update.DATA_URL = "https://data.jsdelivr.com/v1/packages/gh/" .. update.REPO

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

-- Compare two "X.Y.Z" versions numerically. Returns 1 if a > b, -1 if a < b,
-- 0 if equal. A leading "v" is ignored, missing parts count as 0 ("2.5" ==
-- "2.5.0"), and anything without digits sorts oldest. This is what stops the
-- updater ever offering a version that is not strictly newer than the running
-- one — the guard the string "differs?" check was missing.
function update.compare(a, b)
    local function parts(v)
        local out = {}
        for n in tostring(v):gsub("^v", ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y and 1 or -1 end
    end
    return 0
end

-- wget one URL to a path. Returns true on success. Isolated so the two callers
-- fetch the same way setup.lua does (-f overwrite, -q quiet).
local function fetch(url, target)
    local shell = require("shell")
    return shell.execute("wget -f -q " .. url .. " " .. target) and true or false
end

local function readProbe()
    local file = io.open(update.PROBE, "r")
    if not file then return nil end
    local body = file:read("*a")
    file:close()
    require("filesystem").remove(update.PROBE)
    return body
end

-- The newest published version. Primary source is the data API (its versions[]
-- is sorted newest-first, so the first "version" in the body is the latest);
-- the @latest file is a fallback. Either way the result is only ever compared,
-- never trusted to be newer, so a stale fallback can lose an update but can no
-- longer force a downgrade.
local function fetchLatest()
    local filesystem = require("filesystem")

    filesystem.remove(update.PROBE)
    if fetch(update.DATA_URL, update.PROBE) then
        local body = readProbe()
        local version = body and body:match('"version"%s*:%s*"([^"]+)"')
        if version then return version end
    end

    filesystem.remove(update.PROBE)
    if fetch(jsdelivr("latest", "version.lua"), update.PROBE) then
        return update.parseVersion(readProbe())
    end

    return nil
end

-- Look up the latest published version. Returns a table
--   {current = "2.5.2", latest = "2.5.3", newer = true}
-- or nil plus a reason. `newer` is a real SemVer comparison: it is true ONLY
-- when the published version is strictly newer than the running one, so the UI
-- never offers a same-or-older "update".
function update.check()
    local component = require("component")
    if not component.isAvailable("internet") then
        return nil, "no Internet Card"
    end

    local latest = fetchLatest()
    if not latest then return nil, "could not reach cdn.jsdelivr.net" end

    local current = update.current()
    return {current = current, latest = latest, newer = update.compare(latest, current) > 0}
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
