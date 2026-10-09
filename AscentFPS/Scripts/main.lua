-- AscentFPS bootstrap: logging, the hooks and the console command.
-- All gameplay logic lives in fps.lua; its state is kept in AFPS.S.
-- Everything runs on the game thread, inside hooks.
local src = debug.getinfo(1, "S").source or ""
local MOD_DIR = src:match("^@?(.*[\\/])[Ss]cripts[\\/][^\\/]*$") or "Mods\\AscentFPS\\"

AFPS = AFPS or {}
local A = AFPS
A.dir = MOD_DIR
A.S = A.S or {}            -- all mod state
A.version = "1.23"

local LOG = MOD_DIR .. "AscentFPS.log"
function A.log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(os.date("%H:%M:%S ") .. tostring(msg) .. "\n"); f:close() end
end
function A.valid(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end
function A.addr(o) local a = nil; pcall(function() a = o:GetAddress() end); return a end
function A.fname(o)
    if not A.valid(o) then return "<invalid>" end
    local ok, r = pcall(function() return o:GetFullName() end)
    return ok and tostring(r) or "<err>"
end

function A.reload()
    local chunk, err = loadfile(MOD_DIR .. "Scripts\\fps.lua")
    if not chunk then A.log("reload: " .. tostring(err)); return "ERR " .. tostring(err) end
    local ok, e = pcall(chunk)
    if not ok then A.log("reload run: " .. tostring(e)); return "ERR " .. tostring(e) end
    return "loaded"
end

-- ---------------------------------------------------------------- hooks
-- Everything below runs on the game thread. Nothing here may use LoopAsync, ExecuteInGameThread or
-- RegisterKeyBind: their callbacks come from UE4SS's own threads, race with the hooks on the shared Lua
-- registry and brought the game down ("[Lua::Registry::get_function_ref] Ref was not function").
local TICK_FN = "/Game/Blueprints/KallamariPlayerCharacter.KallamariPlayerCharacter_C:ReceiveTick"
local hookedClass = nil

local function onTick(Context, Delta)
    local ok, err = pcall(function() if A.tick then A.tick(Context, Delta) end end)
    if not ok then
        A.S.errs = (A.S.errs or 0) + 1
        if A.S.errs <= 20 then A.log("tick ERR at step '" .. tostring(A.S.step) .. "': " .. tostring(err)) end
    end
end

local function hookPawn(pawn)
    if not A.valid(pawn) then return end
    local full = A.fname(pawn)
    if not full:find("KallamariPlayerCharacter", 1, true) or full:find("Default__", 1, true) then return end
    local cls = nil; pcall(function() cls = A.addr(pawn:GetClass()) end)
    if cls ~= nil and cls ~= hookedClass then
        local ok, e = pcall(function() RegisterHook(TICK_FN, onTick) end)
        A.log("tick hook ok=" .. tostring(ok) .. " " .. tostring(ok and "" or e))
        if ok then hookedClass = cls end
    end
end

-- The player character announces itself when it is spawned or possessed; that is when its Blueprint
-- class is certainly loaded and the tick hook can be installed.
-- (FindFirstOf/FindAllOf walk every object in the game, ~80 ms here, so nothing polls with them.)
pcall(function()
    NotifyOnNewObject("/Script/TheAscent.TheAscentPlayerCharacter", function(obj) pcall(hookPawn, obj) end)
end)
-- (RegisterLoadMapPreHook crashes this game at startup; stale references after a map load are dropped
-- in fps.lua when a pawn with a different controller shows up.)
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(Context, NewPawn)
        pcall(function() hookPawn(NewPawn:get()) end)
    end)
end)
pcall(function()
    RegisterConsoleCommandGlobalHandler("afps", function(FullCommand, Parameters, Ar)
        local out = "?"
        local ok, err = pcall(function() if A.command then out = A.command(Parameters) end end)
        if not ok then out = "error: " .. tostring(err) end
        pcall(function() if Ar then Ar:Log("[afps] " .. tostring(out)) end end)
        A.log("[afps] " .. tostring(out))
        return true
    end)
end)

A.log("=== AscentFPS " .. A.version .. " " .. A.reload() .. " ===")
