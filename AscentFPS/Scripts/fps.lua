-- AscentFPS logic (state lives in AFPS.S).
--
-- How it works (all verified in the running game):
--  * The pawn's Blueprint tick is moved to the last tick group (TG_PostUpdateWork), i.e. after the game
--    has updated its isometric camera. There we overwrite the camera cache POV with an eye-level view.
--  * The game moves the pawn relative to its camera actor (CoopCamera). We yaw that actor to our view,
--    so the game's own WASD / gamepad movement, dodge etc. follow the first-person camera natively.
--  * The game aims at the world point under the mouse cursor. We read the cursor offset from the screen
--    centre as mouse-look and warp it back to the centre, so the aim point is always under the crosshair.
local A = AFPS
local S = A.S
local valid, addr, log = A.valid, A.addr, A.log

local CFG = A.dir .. "AscentFPS.cfg"
local DEFAULTS = {
    sens = 0.15, fov = 90.0, eye = 8.0, crosshair = 1,
    weapon = 1, wsize = 60, wfwd = 44, wright = 16, wdown = 18,   -- weapon view model: scale %, offsets in cm
    laser = 1,                                                    -- the weapon's laser sight (moved to the muzzle)
    recoil = 100,                                                 -- weapon kick per shot in %, 0 = off
    roofs = 1,                                                    -- keep ceilings / roofs that the game fades away indoors
    radar = 0,                                                    -- floor plan under the game's radar dots
    bob = 100,                                                    -- walking head bob in %, 0 = off
    bloom = 4,                                                    -- bloom intensity in %, below 0 = leave to the game
}
local CFG_ORDER = { "sens", "fov", "eye", "crosshair", "weapon", "wsize", "wfwd", "wright", "wdown", "bloom", "bob", "radar", "roofs", "recoil", "laser" }
S.cfg = S.cfg or {}
for k, v in pairs(DEFAULTS) do if S.cfg[k] == nil then S.cfg[k] = v end end
if S.on == nil then S.on = true end
S.yaw = S.yaw or 0.0
S.pitch = S.pitch or 0.0
S.tickN = S.tickN or 0

local MAX_PITCH = 85.0
local CROUCH_EYE_MIN = 45.0
local AIM_PLANE_MARGIN = 10.0
local TG_POST_UPDATE_WORK = 5
local VIS_COLLAPSED, VIS_HIT_TEST_INVISIBLE = 1, 3

local function clamp(v, lo, hi) if v < lo then return lo end; if v > hi then return hi end; return v end
local function wrap(a) while a > 180 do a = a - 360 end; while a < -180 do a = a + 360 end; return a end

local function loadCfg()
    local f = io.open(CFG, "r"); if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([%-%d%.]+)")
        if k and DEFAULTS[k] ~= nil then S.cfg[k] = tonumber(v) or S.cfg[k] end
    end
    f:close()
end
local function saveCfg()
    local f = io.open(CFG, "w"); if not f then return end
    for _, k in ipairs(CFG_ORDER) do f:write(string.format("%s=%.4f\n", k, S.cfg[k])) end
    f:close()
end
if not S.cfgLoaded then loadCfg(); S.cfgLoaded = true end

-- ---------------------------------------------------------------- own body / weapon
-- Actor-level hiding: nothing has to be enumerated (walking component arrays from Lua crashed this
-- game, and FindAllOf over every mesh costs seconds).
local function carriedWeapon(pawn)
    local w = nil
    pcall(function() w = pawn.PlayerWeaponHandlerComponent.CarriedWeapon end)
    if valid(w) then return w end
    return nil
end

-- The weapon view model: the carried weapon actor stays attached to the (hidden) hand, but every frame
-- it is put in front of the camera. Its hand-relative transform is remembered and given back.
local VM_YAW = -90.0        -- weapon meshes point along +Y

local function releaseWeapon()
    local k = S.vmW; S.vmW = nil
    if k and valid(k.obj) then pcall(function()
        k.obj:SetActorScale3D(k.scale)
        k.obj:K2_SetActorRelativeLocation(k.loc, false, {}, true)
        k.obj:K2_SetActorRelativeRotation(k.rot, false, {}, true)
    end) end
end

-- Recoil. A shot is seen as a drop of the weapon's "remaining shots in clip" attribute (the game has no
-- hookable per-shot event). How hard a weapon kicks comes from its own stats: slow, heavy shots kick
-- more (time between shots), and weapons whose spread does not grow when firing - steady beams - do
-- not kick at all. S.recoil is the current kick (0..), it decays every frame.
local function recoilStrength(w, as)
    local va, ha, tbs = 0.0, 0.0, 0.2
    pcall(function() va = as.VerticalSpreadAccumulationPerShot.CurrentValue; ha = as.HorizontalSpreadAccumulationPerShot.CurrentValue end)
    pcall(function() tbs = w:GetCurrentTimeBetweenShots() end)
    if (va or 0) <= 0 and (ha or 0) <= 0 then return 0.0 end
    return clamp(math.sqrt(math.min(tbs or 0.2, 1.0)), 0.25, 1.0)
end

local function recoilStep(pawn, dt)
    local kick = S.recoil or 0.0
    if S.cfg.recoil > 0 then
        local w = carriedWeapon(pawn)
        local as = w and w.WeaponAttributeSet or nil
        if valid(as) then
            local a = addr(w)
            local ammo = as.RemainingShotsInClip.CurrentValue
            if S.rcW ~= a then S.rcW = a; S.rcStr = recoilStrength(w, as)
            elseif S.rcAmmo and ammo < S.rcAmmo - 0.5 then kick = math.min(kick + S.rcStr * S.cfg.recoil / 100.0, 1.8) end
            S.rcAmmo = ammo
        else S.rcW = nil end
    end
    kick = kick * math.exp(-dt * 13.0)
    if kick < 0.002 then kick = 0.0 end
    S.recoil = kick
    return kick
end

-- Every frame: the game hides the weapon actor together with the hidden pawn and shows it again when
-- you fire, so its visibility has to be enforced continuously in both directions.
local function pinWeapon(pawn, ex, ey, ez)
    local w = carriedWeapon(pawn)
    if w == nil or S.cfg.weapon == 0 then
        if S.vmW then releaseWeapon() end
        if w ~= nil and w.bHidden ~= true then w:SetActorHiddenInGame(true) end
        return
    end
    if w.bHidden == true then w:SetActorHiddenInGame(false) end
    local a = addr(w)
    if S.vmW == nil or S.vmW.a ~= a then
        releaseWeapon()
        local root = w.RootComponent
        if not valid(root) then return end
        local l, r, sc = root.RelativeLocation, root.RelativeRotation, w:GetActorScale3D()
        S.vmW = { obj = w, a = a, loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll },
                  scale = { X = sc.X, Y = sc.Y, Z = sc.Z } }
    end
    local k = S.vmW
    if k.size ~= S.cfg.wsize then
        k.size = S.cfg.wsize
        local m = k.size / 100.0
        w:SetActorScale3D({ X = k.scale.X * m, Y = k.scale.Y * m, Z = k.scale.Z * m })
    end
    local kick = S.recoil or 0.0                                   -- muzzle up, weapon back
    local fwd, right, up = S.cfg.wfwd - kick * 4.0, S.cfg.wright, -S.cfg.wdown + kick * 1.0
    local y, p = math.rad(S.yaw), math.rad(S.pitch)
    local cy, sy, cp, sp = math.cos(y), math.sin(y), math.cos(p), math.sin(p)
    w:K2_SetActorLocationAndRotation({
        X = ex + cp * cy * fwd - sy * right - sp * cy * up,
        Y = ey + cp * sy * fwd + cy * right - sp * sy * up,
        Z = ez + sp * fwd + cp * up,
    }, { Pitch = S.pitch + kick * 7.0, Yaw = S.yaw + VM_YAW, Roll = 0.0 }, false, {}, true)
end

local function hideBody(pawn, hide)
    if hide then
        if pawn.bHidden ~= true then pawn:SetActorHiddenInGame(true) end
    else
        if pawn.bHidden == true then pawn:SetActorHiddenInGame(false) end
        local w = carriedWeapon(pawn)          -- back in the visible character's hands
        if w ~= nil and w.bHidden == true then w:SetActorHiddenInGame(false) end
    end
end

-- ---------------------------------------------------------------- laser sight
-- Guns draw a laser while firing: a Niagara beam (/Game/FX/debug_beam) whose user parameters
-- "User.start_pos" / "User.end_pos" are written every tick by the weapon's VFX component Blueprint. The
-- start is the character's chest (GetFireStartPoint), i.e. a red line growing out of the middle of the
-- screen. We set the start to the muzzle of the view model instead - or hide the beam when the option is
-- off. This has to happen after the Blueprint's own update and before Niagara ticks, so it is done in a
-- post-hook on that Blueprint's ReceiveTick (float parameter only), not in our late pawn tick.
local LASER_TICK = "/Game/Blueprints/Weapons/WeaponGunBaseVFXComponent_BP.WeaponGunBaseVFXComponent_BP_C:ReceiveTick"

function A.laserTick(Context)
    if not (S.active and valid(S.pawn)) then return end
    local vc = Context:get()                      -- fires for every gun in the level; ours is filtered by address
    if not valid(vc) or addr(vc) ~= S.laserVC then return end
    local nc = vc.LaserSightNiagaraComponent
    if not valid(nc) or nc.bVisible ~= true then return end
    if S.cfg.laser == 0 then nc:SetVisibility(false, false); return end
    local w = carriedWeapon(S.pawn)
    local fp = w and w.FirePoint or nil
    if not valid(fp) then return end
    local l = fp:K2_GetComponentLocation()
    nc:SetNiagaraVariableVec3("User.start_pos", { X = l.X, Y = l.Y, Z = l.Z })
end

local function trackLaser(pawn)
    if not S.laserHook and S.wall - (S.laserHookT or -10) > 5.0 then       -- fails until a gun class is loaded; retried
        S.laserHookT = S.wall
        local ok = pcall(function()
            RegisterHook(LASER_TICK, function(Context) pcall(function() if A.laserTick then A.laserTick(Context) end end) end)
        end)
        if ok then S.laserHook = true; log("laser hook ok") end
    end
    if S.wall - (S.laserVCT or -1) > 0.25 then          -- which VFX component is ours right now
        S.laserVCT = S.wall
        local w = carriedWeapon(pawn)
        local vc = w and w.WeaponVFXComp or nil
        S.laserVC = valid(vc) and addr(vc) or nil
    end
end

-- ---------------------------------------------------------------- floating health bars
-- The game places its floating bars with a projection that has no "behind the camera" case (the
-- top-down camera never needed one), so bars of things behind you show up mirrored on screen.
-- Bars register themselves through their Blueprint Construct event; we move the ones behind the view away.
local BAR_CONSTRUCT = "/Game/Blueprints/UI/TheAscentHPBarWidget_Normal.TheAscentHPBarWidget_Normal_C:Construct"

local function trackBars()
    if not S.barHook then
        local ok, e = pcall(function()
            RegisterHook(BAR_CONSTRUCT, function(Context)
                pcall(function()
                    local b = Context:get()
                    if S.bars and valid(b) then S.bars[#S.bars + 1] = { w = b, faded = false } end
                end)
            end)
        end)
        S.barHook = true
        log("health-bar hook ok=" .. tostring(ok) .. " " .. tostring(ok and "" or e))
    end
    if S.bars then return end       -- same world (respawn): the list is still good
    S.bars = {}
    local list = FindAllOf("TheAscentHPBarWidget_Normal_C")     -- once: the bars that already exist
    if list then for _, b in pairs(list) do if valid(b) then S.bars[#S.bars + 1] = { w = b, faded = false } end end end
end

local function updateBars(ex, ey, ez, restore)
    local bars = S.bars
    if not bars then return end
    local y, p = math.rad(S.yaw), math.rad(S.pitch)
    local fx, fy, fz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
    for i = #bars, 1, -1 do
        local e = bars[i]
        if not valid(e.w) then table.remove(bars, i)
        else
            local fade = false
            if not restore then
                local actor = e.w:GetOwningActor()
                if valid(actor) then
                    local l = actor:K2_GetActorLocation()
                    fade = ((l.X - ex) * fx + (l.Y - ey) * fy + (l.Z - ez) * fz) < 30.0
                end
            end
            -- pushed off screen with a render translation: the game rewrites opacity and visibility every frame
            if fade ~= e.faded then e.faded = fade; e.w:SetRenderTranslation({ X = fade and 100000.0 or 0.0, Y = 0.0 }) end
        end
    end
end
-- ---------------------------------------------------------------- floating status texts
-- Hints such as "ACCESS DENIED" (StatusText_C) are drawn at a world point through the widget's own
-- projection (GetScreenLocation of its ActorLocation). For the top-down camera that point is the door /
-- chest / the player; from the eyes it is below the view or inside the camera. Worded hints near the
-- player, and anything spawned on the player itself, are carried along in front of the view instead
-- (their ActorLocation is rewritten every frame); damage numbers on enemies stay in the world.
--
-- Only parameterless Blueprint events may be hooked. SimpleStatusText_C:Start (the pooled damage numbers)
-- takes an FText: UE4SS 3.0.1 cannot pass that to Lua ("[push_textproperty] Operation::GetParam is not
-- supported") and the game crashed inside the hook a few calls later. It is deliberately not hooked.
local TEXT_HOOKS = {
    "/Game/GUI/StatusText/StatusText.StatusText_C:Construct",
}

local function onStatusText(Context)
    if not (S.active and S.texts and valid(S.pawn)) then return end
    local w = Context:get()
    if not valid(w) then return end
    local l, pl = w.ActorLocation, S.pawn:K2_GetActorLocation()
    local dx, dy = l.X - pl.X, l.Y - pl.Y
    local d2 = dx * dx + dy * dy
    local txt = ""; pcall(function() txt = w.TextElement:ToString() end)
    local worded = txt:find("[^%d%s%+%-%.,%%xX]") ~= nil      -- not just a number
    local pin = d2 < 150 * 150 or (worded and d2 < 1000 * 1000)
    S.textN = (S.textN or 0) + 1
    if S.textN <= 40 then log(string.format("status text type=%s dist=%.0f worded=%s pin=%s", tostring(w.StatusTextType), math.sqrt(d2), tostring(worded), tostring(pin))) end
    if pin then S.texts[#S.texts + 1] = { w = w, t0 = S.wall, dur = (w.DisplayTime or 1.0) + 2.0 } end
end

local function trackTexts()
    if S.textHook2 then return end
    S.textHook2 = true
    for _, path in ipairs(TEXT_HOOKS) do
        local ok, e = pcall(function() RegisterHook(path, function(Context) pcall(onStatusText, Context) end) end)
        log("status-text hook " .. path:match("[^.]*$") .. " ok=" .. tostring(ok) .. " " .. tostring(ok and "" or e))
    end
end
local function updateTexts(ex, ey, ez)
    local texts = S.texts
    if not texts or #texts == 0 then return end
    local y, p = math.rad(S.yaw), math.rad(S.pitch)
    local cy, sy, cp, sp = math.cos(y), math.sin(y), math.cos(p), math.sin(p)
    for i = #texts, 1, -1 do
        local e = texts[i]
        if S.wall - e.t0 > e.dur or not valid(e.w) then table.remove(texts, i)
        else
            local up = -45.0 - (i - 1) * 22.0          -- below the crosshair, stacked
            local l = e.w.ActorLocation
            l.X = ex + cp * cy * 400.0 - sp * cy * up
            l.Y = ey + cp * sy * 400.0 - sp * sy * up
            l.Z = ez + sp * 400.0 + cp * up
        end
    end
end

-- ---------------------------------------------------------------- interaction prompts
-- "[F] OPEN", lift / station / vendor prompts and the hold-to-interact bar live in the floating widget
-- canvas. Native code puts them at the interactable's projected position (meant for the top-down camera)
-- and makes them fully transparent whenever that position is off screen - which from the eyes is most of
-- the time, although the interaction still works.
--  * while the game shows the widget, a render translation moves it from its slot to under the crosshair
--    (the slot position is one frame old: a slight drift in fast turns);
--  * while the game has it transparent, our own text line shows the same key and label there instead
--    (forcing the opacity does not work, the game writes it after us).
local PROMPTS = {
    { prop = "interactionPrompt", y = 0.62, text = "Text", needItem = true },
    { prop = "TimedInteractionUI", y = 0.70, text = "Name" },
}

local function buildOwnPrompt()
    local function cls(p) local c = StaticFindObject(p); if not valid(c) then error("no class " .. p) end; return c end
    local gi = S.gs:GetGameInstance(S.pawn)
    if not valid(gi) then error("no game instance") end
    S.xn = (S.xn or 0) + 1
    local w = StaticConstructObject(cls("/Script/UMG.UserWidget"), gi, FName("AFPS_Prompt_" .. S.xn))
    local tree = StaticConstructObject(cls("/Script/UMG.WidgetTree"), w, FName("AFPS_Tree"))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree, FName("AFPS_Canvas"))
    tree.RootWidget = canvas
    local o = { w = w, lines = {}, shown = {}, text = {} }
    for i, d in ipairs(PROMPTS) do
        local tb = StaticConstructObject(cls("/Script/UMG.TextBlock"), canvas, FName("AFPS_P" .. i))
        tb.Font.Size = 15
        tb.ShadowOffset.X = 1.5; tb.ShadowOffset.Y = 1.5
        tb.ShadowColorAndOpacity.R = 0; tb.ShadowColorAndOpacity.G = 0; tb.ShadowColorAndOpacity.B = 0; tb.ShadowColorAndOpacity.A = 0.9
        local slot = canvas:AddChildToCanvas(tb)
        local ld = slot.LayoutData
        ld.Anchors.Minimum.X = 0.5; ld.Anchors.Minimum.Y = d.y; ld.Anchors.Maximum.X = 0.5; ld.Anchors.Maximum.Y = d.y
        ld.Alignment.X = 0.5; ld.Alignment.Y = 0.0
        ld.Offsets.Left = 0; ld.Offsets.Top = 0; ld.Offsets.Right = 100; ld.Offsets.Bottom = 30
        slot.bAutoSize = true
        tb:SetVisibility(VIS_COLLAPSED)
        o.lines[i] = tb; o.shown[i] = false
    end
    w:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    w:AddToViewport(-60)
    return o
end

local function ownPromptLine(i, text)       -- text == nil hides the line
    local o = S.ownPrompt
    if text ~= nil and not (o and valid(o.w)) then
        if (S.ownPromptFails or 0) >= 3 then return end
        local ok, r = pcall(buildOwnPrompt)
        if ok and r then S.ownPrompt = r; o = r else S.ownPromptFails = (S.ownPromptFails or 0) + 1; log("own prompt: " .. tostring(r)); return end
    end
    if not (o and valid(o.w) and valid(o.lines[i])) then return end
    if text ~= nil and o.text[i] ~= text then o.text[i] = text; o.lines[i]:SetText(FText(text)) end
    local show = text ~= nil
    if o.shown[i] ~= show then o.shown[i] = show; o.lines[i]:SetVisibility(show and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end
end

-- "[F]  ACTIVATE" from the game's own widget (key display + label)
local function promptLabel(w, d)
    local key, label = "", ""
    pcall(function() key = w.WB_KeyDisplay.Action_Key:GetText():ToString() end)
    pcall(function() label = w[d.text]:GetText():ToString() end)
    if label == "" then return nil end
    if key ~= "" then return "[" .. key .. "]  " .. label end
    return label
end

local function updatePrompts(pawn, restore)
    S.prompts = S.prompts or {}
    local slow = false
    if not restore and S.wall - (S.promptT or -1) > 0.2 then          -- widgets, canvas size and labels: 5 Hz
        S.promptT = S.wall; slow = true
        local ic = pawn.InteractionComponent
        if valid(ic) then for i, d in ipairs(PROMPTS) do
            local w = ic[d.prop]
            if not valid(w) then S.prompts[i] = nil
            elseif not S.prompts[i] or addr(S.prompts[i].w) ~= addr(w) then S.prompts[i] = { w = w, moved = false } end
        end end
        local scale = S.lib:GetViewportScale(S.pc)
        if type(scale) == "number" and scale > 0 and S.cx then S.canvasW, S.canvasH = S.cx * 2 / scale, S.cy * 2 / scale end
    end
    for i, d in ipairs(PROMPTS) do
        local e = S.prompts[i]
        local own = nil
        if e and valid(e.w) then
            local live = not restore and S.canvasW ~= nil and not S.ui and e.w:GetVisibility() ~= VIS_COLLAPSED
            if live and d.needItem and not valid(e.w.HighlightedItem) then live = false end
            local slot = live and e.w.Slot or nil
            if live and valid(slot) then
                local pos, size = slot:GetPosition(), e.w:GetDesiredSize()
                e.w:SetRenderTranslation({ X = S.canvasW / 2 - size.X / 2 - pos.X, Y = S.canvasH * d.y - pos.Y })
                e.moved = true
                if e.w.RenderOpacity < 0.5 then          -- the game is hiding it: off screen for the top-down maths
                    if slow or e.label == nil then e.label = promptLabel(e.w, d) or false end
                    own = e.label or nil
                end
            else
                e.label = nil
                if e.moved then e.moved = false; e.w:SetRenderTranslation({ X = 0.0, Y = 0.0 }) end
            end
        end
        if own ~= nil or (S.ownPrompt and S.ownPrompt.shown[i]) then ownPromptLine(i, own) end
    end
end
-- ---------------------------------------------------------------- crosshair (a tiny UMG widget built at runtime)
local function buildCrosshair()
    local function cls(p) local c = StaticFindObject(p); if not valid(c) then error("no class " .. p) end; return c end
    local gi = S.gs:GetGameInstance(S.pawn)
    if not valid(gi) then error("no game instance") end
    S.xn = (S.xn or 0) + 1
    local w = StaticConstructObject(cls("/Script/UMG.UserWidget"), gi, FName("AFPS_Crosshair_" .. S.xn))
    local tree = StaticConstructObject(cls("/Script/UMG.WidgetTree"), w, FName("AFPS_Tree"))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree, FName("AFPS_Canvas"))
    tree.RootWidget = canvas
    local function bar(name, x, y, sx, sy)
        local img = StaticConstructObject(cls("/Script/UMG.Image"), canvas, FName(name))
        local ld = canvas:AddChildToCanvas(img).LayoutData   -- written before the Slate widget exists
        ld.Anchors.Minimum.X = 0.5; ld.Anchors.Minimum.Y = 0.5; ld.Anchors.Maximum.X = 0.5; ld.Anchors.Maximum.Y = 0.5
        ld.Alignment.X = 0.5; ld.Alignment.Y = 0.5
        ld.Offsets.Left = x; ld.Offsets.Top = y; ld.Offsets.Right = sx; ld.Offsets.Bottom = sy
        img.ColorAndOpacity.R = 1; img.ColorAndOpacity.G = 1; img.ColorAndOpacity.B = 1; img.ColorAndOpacity.A = 0.85
    end
    bar("AFPS_Dot", 0, 0, 3, 3)
    bar("AFPS_L", -11, 0, 10, 2); bar("AFPS_R", 11, 0, 10, 2); bar("AFPS_U", 0, -11, 2, 10); bar("AFPS_D", 0, 11, 2, 10)
    w:SetVisibility(VIS_COLLAPSED)
    w:AddToViewport(-100)      -- under the game's own UI: the pause menu (pawn tick stopped) blurs it away
    return w
end

local function showCrosshair(show)
    show = show and S.cfg.crosshair ~= 0
    if show and not valid(S.xhair) then
        S.xhairShown = false
        if (S.xhairFails or 0) < 3 then
            local ok, w = pcall(buildCrosshair)
            if ok and valid(w) then S.xhair = w else S.xhairFails = (S.xhairFails or 0) + 1; log("crosshair: " .. tostring(w)) end
        end
    end
    if valid(S.xhair) and S.xhairShown ~= show then
        S.xhairShown = show
        S.xhair:SetVisibility(show and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
    end
end

-- ---------------------------------------------------------------- keys (polled on the game thread)
local function keyDown(pc, name)
    S.keys = S.keys or {}
    local k = S.keys[name]
    if k == nil then k = { KeyName = FName(name) }; S.keys[name] = k end
    return pc:IsInputKeyDown(k) == true
end

-- true once per press; with `repeatable`, again while the key is held
local function keyPressed(pc, name, repeatable)
    S.keyState = S.keyState or {}
    local st = S.keyState[name]
    if st == nil then st = { down = true, next = 0 }; S.keyState[name] = st end   -- ignore a key already held
    local down = keyDown(pc, name)
    local fire = false
    if down and not st.down then fire = true; st.next = S.wall + 0.35
    elseif down and repeatable and S.wall >= st.next then fire = true; st.next = S.wall + 0.06 end
    st.down = down
    return fire
end

-- ---------------------------------------------------------------- language
-- The menu follows the game's language. Asking the engine for the culture string crashed the game
-- (string-returning calls are not safe in this UE4SS build), so the language is read off the game's own
-- HUD instead: if its texts contain Cyrillic letters the game runs in Russian, otherwise English is used.
local TEXTS = {
    ru = {
        settings = "НАСТРОЙКИ", on = "ВКЛ", off = "ВЫКЛ", gameDefault = "КАК В ИГРЕ", cm = "см", enter = "ENTER",
        hint = "ВВЕРХ / ВНИЗ: ВЫБОР     ВЛЕВО / ВПРАВО: ИЗМЕНИТЬ     F6: ЗАКРЫТЬ",
        tabView = "ОБЗОР", tabWeapon = "ОРУЖИЕ", tabUi = "ИНТЕРФЕЙС",
        sens = "Чувствительность мыши", fov = "Угол обзора", eye = "Высота глаз", bob = "Покачивание при ходьбе",
        bloom = "Свечение эффектов", roofs = "Потолки в помещениях",
        weapon = "Оружие в кадре", wsize = "Размер", wfwd = "Дальше от глаз", wright = "Правее", wdown = "Ниже",
        recoil = "Отдача", laser = "Лазерный целеуказатель",
        crosshair = "Прицел", radar = "Геометрия на радаре", reset = "Сбросить все настройки",
    },
    en = {
        settings = "SETTINGS", on = "ON", off = "OFF", gameDefault = "GAME DEFAULT", cm = "cm", enter = "ENTER",
        hint = "UP / DOWN: SELECT     LEFT / RIGHT: CHANGE     F6: CLOSE",
        tabView = "VIEW", tabWeapon = "WEAPON", tabUi = "INTERFACE",
        sens = "Mouse sensitivity", fov = "Field of view", eye = "Eye height", bob = "Head bob when walking",
        bloom = "Effect glow (bloom)", roofs = "Ceilings indoors",
        weapon = "Weapon in view", wsize = "Size", wfwd = "Distance from eyes", wright = "To the right", wdown = "Lower",
        recoil = "Recoil", laser = "Laser sight",
        crosshair = "Crosshair", radar = "Geometry on the radar", reset = "Reset all settings",
    },
}

local function gameLanguage(pc, pawn)
    local function cyrillic(tb)
        if not valid(tb) then return false end
        local txt = ""
        pcall(function() txt = tb:GetText():ToString() end)
        return txt:find("[\208-\211]") ~= nil
    end
    local found = false
    pcall(function() local mm = pc.Minimap; if valid(mm) and cyrillic(mm.AreaName) then found = true end end)
    if not found then pcall(function()
        local ic = pawn.InteractionComponent
        local pr = valid(ic) and ic.interactionPrompt or nil
        if valid(pr) and cyrillic(pr.Text) then found = true end
    end) end
    if not found then pcall(function()
        local hud = pc.PlayerHUDReference
        if valid(hud) and (cyrillic(hud.Level) or cyrillic(hud.XP)) then found = true end
    end) end
    if found then S.langSeenRu = true end
    return S.langSeenRu and "ru" or "en"
end

-- ---------------------------------------------------------------- settings menu (F6)
-- A panel in the game's own look (dark sheet, red header and accents), three category tabs.
-- Keyboard only: Lua cannot bind UMG click delegates here. Row 0 is the tab bar.
local MENU = {
    { title = "tabView", items = {
        { key = "sens", step = 0.01, min = 0.02, max = 1.0, fmt = "%.2f" },
        { key = "fov", step = 5, min = 60, max = 120, fmt = "%.0f" },
        { key = "eye", step = 2, min = -40, max = 60, fmt = "%+.0f", unit = "cm" },
        { key = "bob", step = 25, min = 0, max = 200, fmt = "%.0f", unit = "%", zero = "off" },
        { key = "bloom", step = 1, min = -1, max = 60, fmt = "%.0f", unit = "%", negative = "gameDefault" },
        { key = "roofs", bool = true },
    } },
    { title = "tabWeapon", items = {
        { key = "weapon", bool = true },
        { key = "wsize", step = 5, min = 20, max = 120, fmt = "%.0f", unit = "%" },
        { key = "wfwd", step = 2, min = 16, max = 100, fmt = "%.0f", unit = "cm" },
        { key = "wright", step = 1, min = -40, max = 40, fmt = "%+.0f", unit = "cm" },
        { key = "wdown", step = 1, min = 0, max = 50, fmt = "%.0f", unit = "cm" },
        { key = "recoil", step = 25, min = 0, max = 200, fmt = "%.0f", unit = "%", zero = "off" },
        { key = "laser", bool = true },
    } },
    { title = "tabUi", items = {
        { key = "crosshair", bool = true },
        { key = "radar", bool = true },
        { action = "reset", key = "reset" },
    } },
}
local MENU_ROWS = 7
local MENU_W, MENU_H, ROW_H = 640, 372, 30
local MENU_TOP = -MENU_H / 2
local TAB_Y = MENU_TOP + 62
local ROW_Y0 = MENU_TOP + 112

local function menuValue(item, T)
    if item.action then return T.enter end
    local v = S.cfg[item.key]
    if item.bool then return (v ~= 0) and T.on or T.off end
    if item.negative and v < 0 then return T[item.negative] end
    if item.zero and v == 0 then return T[item.zero] end
    local s = string.format(item.fmt, v)
    if item.unit == "cm" then s = s .. " " .. T.cm elseif item.unit == "%" then s = s .. "%" end
    return "<  " .. s .. "  >"
end

local function menuRefresh()
    local m = S.menu
    if not (m and valid(m.w)) then return end
    local T = TEXTS[m.lang]
    local tab = MENU[S.menuTab]
    local function set(tb, cache, i, txt)
        if cache[i] ~= txt and valid(tb) then cache[i] = txt; tb:SetText(FText(txt)) end
    end
    for i = 1, MENU_ROWS do
        local item = tab.items[i]
        local show = item ~= nil
        if m.rowShown[i] ~= show then
            m.rowShown[i] = show
            local vis = show and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED
            if valid(m.labels[i]) then m.labels[i]:SetVisibility(vis) end
            if valid(m.values[i]) then m.values[i]:SetVisibility(vis) end
        end
        if show then
            set(m.labels[i], m.labelText, i, T[item.key])
            local val = menuValue(item, T)
            if item.bool then val = "<  " .. val .. "  >" end
            set(m.values[i], m.valueText, i, val)
        end
    end
    if m.shownTab ~= S.menuTab and valid(m.tabBar) then
        m.shownTab = S.menuTab
        m.tabBar.Slot:SetPosition({ X = -MENU_W / 2 + MENU_W * (S.menuTab - 0.5) / #MENU, Y = TAB_Y + 17 })
    end
    local selKey = S.menuTab * 100 + S.menuSel
    if m.shownSel ~= selKey and valid(m.band) and valid(m.bandEdge) then
        m.shownSel = selKey
        local y = (S.menuSel == 0) and TAB_Y or (ROW_Y0 + (S.menuSel - 1) * ROW_H)
        m.band.Slot:SetPosition({ X = 0, Y = y })
        m.bandEdge.Slot:SetPosition({ X = -MENU_W / 2 + 14, Y = y })
    end
end

local function buildMenu(lang)
    local function cls(p) local c = StaticFindObject(p); if not valid(c) then error("no class " .. p) end; return c end
    local gi = S.gs:GetGameInstance(S.pawn)
    if not valid(gi) then error("no game instance") end
    local T = TEXTS[lang]
    S.xn = (S.xn or 0) + 1
    local w = StaticConstructObject(cls("/Script/UMG.UserWidget"), gi, FName("AFPS_Menu_" .. S.xn))
    local tree = StaticConstructObject(cls("/Script/UMG.WidgetTree"), w, FName("AFPS_Tree"))
    w.WidgetTree = tree
    local canvas = StaticConstructObject(cls("/Script/UMG.CanvasPanel"), tree, FName("AFPS_Canvas"))
    tree.RootWidget = canvas
    -- layout is written into the slot before the Slate widget exists (see crosshair)
    local function place(wd, x, y, sx, sy, alignX, auto)
        local slot = canvas:AddChildToCanvas(wd)
        local ld = slot.LayoutData
        ld.Anchors.Minimum.X = 0.5; ld.Anchors.Minimum.Y = 0.5; ld.Anchors.Maximum.X = 0.5; ld.Anchors.Maximum.Y = 0.5
        ld.Alignment.X = alignX; ld.Alignment.Y = 0.5
        ld.Offsets.Left = x; ld.Offsets.Top = y; ld.Offsets.Right = sx; ld.Offsets.Bottom = sy
        if auto then slot.bAutoSize = true end
    end
    local function box(name, x, y, sx, sy, r, g, b, a)
        local img = StaticConstructObject(cls("/Script/UMG.Image"), canvas, FName(name))
        img.ColorAndOpacity.R = r; img.ColorAndOpacity.G = g; img.ColorAndOpacity.B = b; img.ColorAndOpacity.A = a
        place(img, x, y, sx, sy, 0.5, false)
        return img
    end
    local function text(name, str, size, x, y, alignX, r, g, b)
        local tb = StaticConstructObject(cls("/Script/UMG.TextBlock"), canvas, FName(name))
        tb.Font.Size = size
        local c = tb.ColorAndOpacity.SpecifiedColor
        c.R = r or 1.0; c.G = g or 1.0; c.B = b or 1.0; c.A = 1.0
        place(tb, x, y, 100, 30, alignX, true)
        tb:SetText(FText(str))
        return tb
    end
    local RED_R, RED_G, RED_B = 0.80, 0.04, 0.07
    local m = { w = w, lang = lang, labels = {}, values = {}, labelText = {}, valueText = {}, rowShown = {} }
    box("AFPS_Edge", 0, 0, MENU_W + 2, MENU_H + 2, RED_R, RED_G, RED_B, 0.55)
    box("AFPS_Bg", 0, 0, MENU_W, MENU_H, 0.015, 0.012, 0.016, 0.93)
    box("AFPS_Head", 0, MENU_TOP + 18, MENU_W, 36, RED_R, RED_G, RED_B, 0.95)
    text("AFPS_Title", "ASCENT FPS", 15, -MENU_W / 2 + 20, MENU_TOP + 18, 0.0)
    text("AFPS_Sub", T.settings .. "   v" .. tostring(A.version), 10, MENU_W / 2 - 20, MENU_TOP + 18, 1.0)
    box("AFPS_TabLine", 0, TAB_Y + 19, MENU_W - 28, 1, RED_R, RED_G, RED_B, 0.45)
    m.band = box("AFPS_Band", 0, ROW_Y0, MENU_W - 28, ROW_H - 4, RED_R, RED_G, RED_B, 0.30)
    m.bandEdge = box("AFPS_BandEdge", -MENU_W / 2 + 14, ROW_Y0, 4, ROW_H - 4, 1.0, 0.10, 0.12, 1.0)
    m.tabBar = box("AFPS_TabBar", 0, TAB_Y + 17, MENU_W / #MENU - 40, 3, 1.0, 0.10, 0.12, 1.0)
    for i, tab in ipairs(MENU) do
        text("AFPS_Tab" .. i, T[tab.title], 12, -MENU_W / 2 + MENU_W * (i - 0.5) / #MENU, TAB_Y, 0.5)
    end
    for i = 1, MENU_ROWS do
        local y = ROW_Y0 + (i - 1) * ROW_H
        m.labels[i] = text("AFPS_L" .. i, "", 12, -MENU_W / 2 + 34, y, 0.0)
        m.values[i] = text("AFPS_V" .. i, "", 12, MENU_W / 2 - 34, y, 1.0, 1.0, 0.45, 0.45)
    end
    box("AFPS_FootLine", 0, MENU_TOP + MENU_H - 34, MENU_W - 28, 1, RED_R, RED_G, RED_B, 0.45)
    text("AFPS_Help", T.hint, 9, 0, MENU_TOP + MENU_H - 17, 0.5, 0.85, 0.85, 0.85)
    w:SetVisibility(VIS_COLLAPSED)
    w:AddToViewport(-50)       -- under the game's own menus, like the crosshair
    return m
end

local function showMenu(show)
    if show then
        local lang = gameLanguage(S.pc, S.pawn)
        local m = S.menu
        if m and valid(m.w) and m.lang ~= lang then m.w:RemoveFromViewport(); S.menu = nil; S.menuShown = false end
        if not (S.menu and valid(S.menu.w)) then
            S.menuShown = false
            if (S.menuFails or 0) < 3 then
                local ok, r = pcall(buildMenu, lang)
                if ok and r then S.menu = r else S.menuFails = (S.menuFails or 0) + 1; log("menu: " .. tostring(r)) end
            end
        end
    end
    if S.menu and valid(S.menu.w) then
        if show then menuRefresh() end
        if S.menuShown ~= show then
            S.menuShown = show
            S.menu.w:SetVisibility(show and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
        end
    end
end

local function menuInput(pc)
    S.menuTab = S.menuTab or 1
    S.menuSel = S.menuSel or 1
    local items = MENU[S.menuTab].items
    local n = #items
    if keyPressed(pc, "Up", true) then S.menuSel = (S.menuSel - 1) % (n + 1) end
    if keyPressed(pc, "Down", true) then S.menuSel = (S.menuSel + 1) % (n + 1) end
    local dir = 0
    if keyPressed(pc, "Left", true) then dir = -1 end
    if keyPressed(pc, "Right", true) then dir = 1 end
    local enter = keyPressed(pc, "Enter", false)
    if S.menuSel == 0 then                              -- the tab bar
        if dir ~= 0 then S.menuTab = (S.menuTab - 1 + dir) % #MENU + 1 end
        return
    end
    local item = items[S.menuSel]
    if item == nil then S.menuSel = 1; return end
    local changed = false
    if item.action == "reset" then
        if enter then for k, v in pairs(DEFAULTS) do S.cfg[k] = v end; changed = true end
    elseif item.bool then
        if dir ~= 0 or enter then S.cfg[item.key] = (S.cfg[item.key] ~= 0) and 0 or 1; changed = true end
    elseif dir ~= 0 then
        local v = clamp(S.cfg[item.key] + dir * item.step, item.min, item.max)
        v = math.floor(v / item.step + 0.5) * item.step
        if v ~= S.cfg[item.key] then S.cfg[item.key] = v; changed = true end
    end
    if changed then saveCfg(); S.look = nil; S.hideT = -1 end   -- re-apply crosshair / weapon visibility
end

-- ---------------------------------------------------------------- radar with geometry
-- The game's radar (WB_Minimap_C) shows dots on an empty disc - useless from the eyes, because you cannot
-- see the walls the dots are behind. We render a floor plan and give it to the radar as its background:
--  * a SceneCapture2D actor looks straight down from above the player, yawed like the view (the radar is
--    already rotated that way: its "up" is the camera's forward), with the near clipping plane just above
--    the head, so roofs and upper floors are cut away and the walls of the current level remain;
--  * the capture goes into a render target that becomes the brush of the radar's `Bg` border (the Slate
--    border keeps a pointer to that brush struct, so writing the resource in place is enough);
--  * the radar's scale was measured against its own dots: 0.0429 px per cm, i.e. the 256 x 272 px radar
--    covers 5967 x 6340 cm, with the player 9 px above the middle.
local RADAR_PX_W, RADAR_PX_H = 256, 272
local RADAR_PX_PER_CM = 0.0429
local RADAR_CENTRE_UP_PX = 9.0
local RADAR_HZ = 10
local RADAR_DISC_ALPHA = 0.5
local RADAR_CUT = 150.0       -- cm above the pawn centre where the plan is cut
local RADAR_HEIGHT = RADAR_PX_W / RADAR_PX_PER_CM / 2.0      -- FOV 90: the picture is 2 x height wide

local function buildRadar(pawn)
    local function cls(p) local c = StaticFindObject(p); if not valid(c) then error("no class " .. p) end; return c end
    local krl = cls("/Script/Engine.Default__KismetRenderingLibrary")
    local rt = krl:CreateRenderTarget2D(pawn, RADAR_PX_W * 2, RADAR_PX_H * 2, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
    if not valid(rt) then error("no render target") end
    local l = pawn:K2_GetActorLocation()
    local actor = pawn:GetWorld():SpawnActor(cls("/Script/Engine.SceneCapture2D"), { X = l.X, Y = l.Y, Z = l.Z + RADAR_HEIGHT }, { Pitch = -89.9, Yaw = 0, Roll = 0 })
    if not valid(actor) then error("no capture actor") end
    local comp = actor.CaptureComponent2D
    if not valid(comp) then error("no capture component") end
    comp.TextureTarget = rt
    comp.CaptureSource = 2              -- SCS_FinalColorLDR (the HDR sources come out transparent in UMG)
    comp.bCaptureEveryFrame = false; comp.bCaptureOnMovement = false
    comp.FOVAngle = 90.0
    comp.bOverride_CustomNearClippingPlane = true
    comp.CustomNearClippingPlane = RADAR_HEIGHT - RADAR_CUT
    -- a capture is a full scene render; the plan only needs what is near, and coarse
    comp.MaxViewDistanceOverride = RADAR_HEIGHT + 900.0
    comp.LODDistanceFactor = 4.0
    return { rt = rt, actor = actor, comp = comp, t = -1 }
end

-- the radar's background border; show=false gives it back its own (transparent) colour
local function radarBackground(show)
    local r = S.radar
    local bg, disc = nil, nil
    if valid(S.pc) then local mm = S.pc.Minimap; if valid(mm) then bg = mm.Bg; disc = mm.MinimapBorder end end
    if not valid(bg) then return false end
    local a = addr(bg)
    if S.radarBgAddr ~= a then          -- a new radar widget (new world): remember its own colours
        S.radarBgAddr = a; S.radarOn = false
        local c = bg.BrushColor
        S.radarBgColor = { R = c.R, G = c.G, B = c.B, A = c.A }
        S.radarDiscColor = nil
        if valid(disc) then local d = disc.BrushColor; S.radarDiscColor = { R = d.R, G = d.G, B = d.B, A = d.A } end
    end
    if show and r and valid(r.rt) then
        if not S.radarOn then
            S.radarOn = true
            bg.Background.ResourceObject = r.rt
            bg:SetBrushColor({ R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
            -- the radar's own dark disc lies on top of the plan; thin it out so the walls stay readable
            if valid(disc) and S.radarDiscColor then
                local d = S.radarDiscColor
                disc:SetBrushColor({ R = d.R, G = d.G, B = d.B, A = math.min(d.A, RADAR_DISC_ALPHA) })
            end
        end
    elseif S.radarOn then
        S.radarOn = false
        bg:SetBrushColor(S.radarBgColor)
        if valid(disc) and S.radarDiscColor then disc:SetBrushColor(S.radarDiscColor) end
    end
    return true
end

local function updateRadar(pawn, show)
    show = show and S.cfg.radar ~= 0
    local r = S.radar
    if show and not (r and valid(r.actor) and valid(r.comp) and valid(r.rt)) then
        r = nil; S.radar = nil
        if (S.radarFails or 0) < 3 then
            local ok, res = pcall(buildRadar, pawn)
            if ok and res then S.radar = res; r = res else S.radarFails = (S.radarFails or 0) + 1; log("radar: " .. tostring(res)) end
        end
    end
    if S.wall - (S.radarBgT or -1) > 0.5 or (show ~= S.radarWant) then      -- the widget is looked up twice a second
        S.radarBgT = S.wall; S.radarWant = show
        radarBackground(show and r ~= nil)
    end
    if not (show and r) or S.wall - r.t < 1.0 / RADAR_HZ then return end
    r.t = S.wall
    local l = pawn:K2_GetActorLocation()
    local ry = math.rad(S.yaw)
    local back = RADAR_CENTRE_UP_PX / RADAR_PX_PER_CM          -- the player sits a little above the middle of the radar
    r.actor:K2_SetActorLocationAndRotation({ X = l.X - math.cos(ry) * back, Y = l.Y - math.sin(ry) * back, Z = l.Z + RADAR_HEIGHT },
        { Pitch = -89.9, Yaw = S.yaw, Roll = 0.0 }, false, {}, true)
    r.comp:CaptureScene()
end
-- ---------------------------------------------------------------- ceilings
-- For the top-down camera the game fades roofs and ceilings away when you walk indoors: BP_GroupFade
-- actors have activation boxes, and overlapping one fades that actor's meshes out (leaving it fades them
-- back in). From the eyes the room just loses its ceiling. While first person is on, those actors get
-- their collision switched off, so nothing overlaps: the ones you are standing in fade back in at once,
-- the others never trigger. Levels stream in while you walk, so new ones are caught by a hook on their
-- overlap event. No references are kept (streamed-out actors would dangle): switching back re-scans.
local FADE_CLASS = "BP_GroupFade_C"
local FADE_OVERLAP = "/Game/Blueprints/Misc/BP_GroupFade.BP_GroupFade_C:ReceiveActorBeginOverlap"

local function hookGroupFades()
    if S.fadeHook then return end
    local ok = pcall(function()
        RegisterHook(FADE_OVERLAP, function(Context)
            pcall(function()
                if not (S.active and S.fadesOff) then return end
                local a = Context:get()
                if valid(a) then a:SetActorEnableCollision(false) end
            end)
        end)
    end)
    if ok then S.fadeHook = true; log("group-fade hook ok") end      -- fails until the class is loaded; retried
end

local function updateGroupFades(want)
    if want and not S.fadeHook and S.wall - (S.fadeHookT or -10) > 5.0 then S.fadeHookT = S.wall; hookGroupFades() end
    if want == (S.fadesOff == true) then return end
    S.fadesOff = want
    local n = 0
    local list = FindAllOf(FADE_CLASS)          -- one scan per switch (~80 ms)
    if list then for _, a in pairs(list) do if valid(a) then n = n + 1; a:SetActorEnableCollision(not want) end end end
    log("ceilings kept=" .. tostring(want) .. " (" .. n .. " fade groups)")
end

-- ---------------------------------------------------------------- head bob
-- Without it the eye glides: the camera sits on the capsule, not on the (hidden, un-animated) head.
-- The phase advances with the distance walked, so the rhythm follows the speed; the amount eases in and
-- out and is dropped during dashes. Returns the eye offset: up and to the right, in cm.
local BOB_STEP = 150.0      -- cm per step
local BOB_UP, BOB_SIDE = 2.2, 1.3

local function headBob(pawn, dt)
    local want = 0.0
    if S.cfg.bob > 0 then
        local v = pawn:GetVelocity()
        local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        if speed > 60 and speed < 900 and math.abs(v.Z) < 150 then      -- walking / running on the ground
            want = S.cfg.bob / 100.0
            S.bobPhase = ((S.bobPhase or 0) + math.min(speed, 650) * dt / BOB_STEP * math.pi) % (2 * math.pi)
        end
    end
    S.bobAmt = (S.bobAmt or 0) + (want - (S.bobAmt or 0)) * math.min(1.0, dt * 8.0)
    if S.bobAmt < 0.002 then return 0.0, 0.0 end
    local ph = S.bobPhase or 0
    return -math.abs(math.sin(ph)) * BOB_UP * S.bobAmt + BOB_UP * 0.5 * S.bobAmt, math.sin(ph) * BOB_SIDE * S.bobAmt
end

-- ---------------------------------------------------------------- per-pawn setup
-- Forget every object of the world that is going away, WITHOUT touching it: after a map load the old
-- widgets and actors are freed, and even IsValid() on such a pointer can crash the game.
function A.worldReset(reason)
    log("world reset (" .. tostring(reason) .. ")")
    S.pawn = nil; S.pawnAddr = nil; S.pc = nil; S.pcName = nil; S.cam = nil
    S.vtObj = nil; S.vtAddr = nil; S.vtYaw0 = nil; S.vtCoop = false
    S.xhair = nil; S.xhairShown = nil; S.xhairFails = 0
    S.menu = nil; S.menuShown = nil; S.menuFails = 0
    S.fadesOff = false; S.laserVC = nil
    S.radar = nil; S.radarFails = 0; S.radarBgAddr = nil; S.radarOn = false; S.radarBgT = -1
    S.bars = nil; S.texts = nil; S.vmW = nil; S.prompts = nil; S.promptT = -1; S.ownPrompt = nil; S.ownPromptFails = 0
    S.active = false; S.look = nil; S.lastMX = nil
end

local function setupPawn(pawn)
    S.pawn = pawn; S.pawnAddr = addr(pawn)
    S.pc = nil; pcall(function() S.pc = pawn.Controller end)
    S.pcName = A.fname(S.pc)
    S.cam = nil; if valid(S.pc) then pcall(function() S.cam = S.pc.PlayerCameraManager end) end
    if not valid(S.lib) then S.lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    if not valid(S.ksl) then S.ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not valid(S.gs) then S.gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    S.keys = nil; S.keyState = nil; S.eyeH = nil
    S.lastMX = nil; S.slowT = -1; S.hideT = -1; S.coopT = -1; S.active = false; S.look = nil; S.vtAddr = nil; S.vmW = nil; S.barT = -1
    pcall(function() pawn.PrimaryActorTick.TickGroup = TG_POST_UPDATE_WORK end)
    -- start out looking where the character faces
    pcall(function() S.yaw = pawn:K2_GetActorRotation().Yaw; S.pitch = 0.0 end)
    pcall(trackBars); pcall(trackTexts)
    S.texts = S.texts or {}
    log("pawn ready: " .. A.fname(pawn))
end

-- Anything that needs the mouse cursor or shows the game's own camera work.
local function uiOpen(pc)
    if pc.bIsInUI == true or pc.UIScreen == true or pc.bIsInJournal == true or pc.IsInShop == true or pc.IsInPhotoMode == true then return true end
    local r = {}; pc:HasMenusOpen(r)
    if r.Return == true then return true end
    if pc:CanInput() ~= true then return true end      -- cinematic mode, dialogue, journal
    -- Menus that set none of the flags above (the taxi / fast-travel list): the game remembers the widget
    -- that last took focus. A menu is open while that widget really holds the keyboard focus, or is itself
    -- a top-level widget still in the viewport. Its own IsVisible() is NOT enough: after a vendor dialogue
    -- a pooled dialogue-option widget stays "visible" forever and the cursor never came back.
    local focused = pc:GetLastFocusedWidget()
    if valid(focused) then
        if focused:HasUserFocus(pc) == true or focused:HasUserFocusedDescendants(pc) == true then return true end
        if focused:IsInViewport() == true and focused:IsVisible() == true then return true end
    end
    return false
end

local function restoreCameraActor()
    local vt = S.vtObj
    if valid(vt) and S.vtYaw0 ~= nil then
        pcall(function() local ar = vt:K2_GetActorRotation(); vt:K2_SetActorRotation({ Pitch = ar.Pitch, Yaw = S.vtYaw0, Roll = ar.Roll }, false) end)
    end
    S.vtYaw0 = nil
end

-- ---------------------------------------------------------------- tick (pawn BP tick, last tick group)
function A.tick(Context, Delta)
    S.tickN = S.tickN + 1; S.step = "start"
    local pawn = Context:get()
    if not valid(pawn) then return end
    if addr(pawn) ~= S.pawnAddr then
        local ctrl = nil; pcall(function() ctrl = pawn.Controller end)
        if not valid(ctrl) or not A.fname(ctrl):find("KallamariPlayerController", 1, true) then return end
        -- a different controller object (names are never reused) means a new world was loaded
        if S.pcName ~= nil and A.fname(ctrl) ~= S.pcName then A.worldReset("new controller") end
        setupPawn(pawn)
    end
    local pc, cam = S.pc, S.cam
    if not (valid(pc) and valid(cam)) then S.pawnAddr = nil; return end
    local dt = 0.016; pcall(function() dt = Delta:get() end)
    S.t = (S.t or 0) + dt
    S.wall = os.clock()

    -- F5 / F6 and the menu keys, polled here on the game thread (UE4SS key binds call back from another thread)
    S.step = "key"
    if keyPressed(pc, "F5", false) then A.toggle() end
    if keyPressed(pc, "F6", false) then S.menuOpen = not S.menuOpen end
    if S.menuOpen and not S.ui then S.step = "menu"; menuInput(pc) end
    showMenu(S.menuOpen == true and not S.ui)

    S.step = "viewtarget"
    -- the game's camera actor; anything else as view target (journal, cutscene) is left alone
    local vt = cam.ViewTarget.Target
    local va = valid(vt) and addr(vt) or nil
    if va ~= S.vtAddr then
        S.vtAddr = va; S.vtObj = vt; S.vtYaw0 = nil
        S.vtCoop = va ~= nil and vt:GetClass():GetFName():ToString():find("CoopCamera", 1, true) ~= nil
    end

    -- slow checks (10 Hz): UI state, viewport size, co-op guard
    S.step = "ui"
    if S.wall - (S.slowT or -1) > 0.1 then
        S.slowT = S.wall
        S.ui = uiOpen(pc)
        local sz = {}; pc:GetViewportSize(sz, {})
        if type(sz.SizeX) == "number" and sz.SizeX > 0 then S.cx, S.cy = sz.SizeX // 2, sz.SizeY // 2 end
    end
    if S.wall - (S.coopT or -1) > 2.0 and valid(S.ksl) and valid(S.gs) then
        S.coopT = S.wall
        -- single-player only: not hosting / joined (standalone net mode) and no second local player
        local coop = S.ksl:IsStandalone(pawn) ~= true or valid(S.gs:GetPlayerController(pawn, 1))
        if coop and not S.coop then log("more than one player: first-person is off (single-player only)") end
        S.coop = coop
    end

    S.step = "activate"
    local active = (S.on and S.vtCoop and not S.coop and valid(S.ksl) and valid(S.gs)) == true
    if active ~= S.active then
        S.active = active; S.look = nil
        if active then S.hideT = -1 else
            hideBody(pawn, false); releaseWeapon(); updateBars(0, 0, 0, true); updatePrompts(pawn, true); updateRadar(pawn, false); updateGroupFades(false); restoreCameraActor(); showCrosshair(false)
            pc.CurrentMouseCursor = 1
        end
        S.lastMX = nil
    end
    if not active then return end

    S.step = "hide"
    -- keep our own body hidden; the game un-hides it after some events
    if S.wall - (S.hideT or -1) > 0.25 then S.hideT = S.wall; hideBody(pawn, true) end

    S.step = "look"
    -- look: only while the game window is focused (GetMousePosition fails otherwise) and no UI is open
    local look = (not S.ui) and valid(S.lib) and S.cx ~= nil and pc:GetMousePosition({}, {}) == true
    if look ~= S.look then
        S.look = look; S.lastMX = nil; showCrosshair(look)
        if not look then pc.CurrentMouseCursor = 1 end       -- EMouseCursor::Default: hand the pointer back
    end
    if look then
        -- The game's arrow pointer is made invisible by its cursor type, NOT by clearing bShowMouseCursor:
        -- the game sets that flag again every frame at times (reading a note), and the show/hide flip-flop
        -- shifts the warped cursor by (-1,-1) px per frame - the view crept up and left on its own.
        if pc.CurrentMouseCursor ~= 0 then pc.CurrentMouseCursor = 0 end         -- EMouseCursor::None
        local m = S.lib:GetMousePositionOnPlatform()
        if S.lastMX ~= nil then
            S.yaw = wrap(S.yaw + (m.X - S.lastMX) * S.cfg.sens)
            S.pitch = clamp(S.pitch - (m.Y - S.lastMY) * S.cfg.sens, -MAX_PITCH, MAX_PITCH)
        end
        pc:SetMouseLocation(S.cx, S.cy)
        local r = S.lib:GetMousePositionOnPlatform()   -- the reference is re-read after the warp, never assumed
        S.lastMX, S.lastMY = r.X, r.Y
    end

    S.step = "basis"
    -- movement basis: yaw the game's camera actor so that its camera looks along our yaw
    local ar = vt:K2_GetActorRotation()
    if S.vtYaw0 == nil then S.vtYaw0 = ar.Yaw end
    local d = wrap(S.yaw - vt:GetCameraRotation().Yaw)
    if d > 0.01 or d < -0.01 then vt:K2_SetActorRotation({ Pitch = ar.Pitch, Yaw = wrap(ar.Yaw + d), Roll = ar.Roll }, false) end

    S.step = "view"
    -- the view itself
    local loc = pawn:K2_GetActorLocation()
    -- Eye height. The game's cursor aim only updates while the camera is above the character's current
    -- aim point (AimLowPoint normally, AimHighPoint while the right mouse button raises the weapon);
    -- otherwise the aim and the laser freeze at their last direction. Crouching (Ctrl) drops
    -- BaseEyeHeight to -24, below AimLowPoint (+35), and aiming high while crouched puts the aim point at
    -- +90. So the eye is kept above the active aim point (and at least 45 cm above the capsule centre when
    -- crouched); the height is eased, so crouching or raising the weapon over cover moves the view smoothly.
    local eyeOff = (pawn.BaseEyeHeight or 64.0) + S.cfg.eye
    if pawn.bIsCrouched == true and eyeOff < CROUCH_EYE_MIN then eyeOff = CROUCH_EYE_MIN end
    if S.wall - (S.aimPlaneT or -1) > 0.05 then                 -- 20 Hz
        S.aimPlaneT = S.wall
        S.aimPlane = nil
        local pt = (pawn:IsAimingHigh() == true) and pawn.AimHighPoint or pawn.AimLowPoint
        if valid(pt) then S.aimPlane = pt:K2_GetComponentLocation().Z - loc.Z end
    end
    if S.aimPlane and eyeOff < S.aimPlane + AIM_PLANE_MARGIN then eyeOff = S.aimPlane + AIM_PLANE_MARGIN end
    local halfH = 88.0
    local cap = pawn.CapsuleComponent
    if valid(cap) then halfH = cap:GetScaledCapsuleHalfHeight() end
    local eyeH = halfH + eyeOff                         -- above the feet
    if S.eyeH == nil or math.abs(S.eyeH - eyeH) > 150 then S.eyeH = eyeH end
    S.eyeH = S.eyeH + (eyeH - S.eyeH) * math.min(1.0, dt * 12.0)
    local ex, ey, ez = loc.X, loc.Y, loc.Z - halfH + S.eyeH
    local wx, wy, wz = ex, ey, ez                    -- the weapon follows only half of the bob, so it moves on screen
    local bobUp, bobSide = headBob(pawn, dt)
    if bobUp ~= 0.0 or bobSide ~= 0.0 then
        local ry = math.rad(S.yaw); local rx, ryy = -math.sin(ry), math.cos(ry)
        wx, wy, wz = ex + rx * bobSide * 0.5, ey + ryy * bobSide * 0.5, ez + bobUp * 0.5
        ex, ey, ez = ex + rx * bobSide, ey + ryy * bobSide, ez + bobUp
    end
    local pov = cam.CameraCachePrivate.POV
    S.step = "laser"
    trackLaser(pawn)
    S.step = "roofs"
    updateGroupFades(S.cfg.roofs ~= 0)
    S.step = "radar"
    updateRadar(pawn, true)
    S.step = "view"
    pov.Location.X = ex; pov.Location.Y = ey; pov.Location.Z = ez
    S.step = "recoil"
    local kick = recoilStep(pawn, dt)
    S.step = "view"
    pov.Rotation.Pitch = S.pitch + kick * 0.8; pov.Rotation.Yaw = S.yaw; pov.Rotation.Roll = 0.0
    pov.FOV = S.cfg.fov
    if S.cfg.bloom >= 0 then        -- effects sit right in front of the lens now; the top-down bloom whites the screen out
        local pp = pov.PostProcessSettings
        pp.bOverride_BloomIntensity = true; pp.BloomIntensity = S.cfg.bloom / 100.0
        pp.bOverride_LensFlareIntensity = true; pp.LensFlareIntensity = 0.0
        pov.PostProcessBlendWeight = 1.0
    end

    S.step = "weapon"
    pinWeapon(pawn, wx, wy, wz)
    S.step = "texts"
    updateTexts(ex, ey, ez)
    S.step = "prompts"
    updatePrompts(pawn, false)
    if S.wall - (S.barT or -1) > 0.05 then S.step = "bars"; S.barT = S.wall; updateBars(ex, ey, ez, false) end
    S.step = "done"
end


function A.toggle()
    S.on = not S.on
    log("first person = " .. tostring(S.on))
    return S.on
end

function A.command(p)
    local a1 = string.lower(tostring(p[1] or ""))
    local n = tonumber(p[2])
    if a1 == "reset" then for k, v in pairs(DEFAULTS) do S.cfg[k] = v end; saveCfg(); S.look = nil; return "reset"
    elseif a1 == "toggle" then return "first person=" .. tostring(A.toggle())
    elseif DEFAULTS[a1] ~= nil then
        if n then S.cfg[a1] = n; saveCfg(); S.look = nil end
        return a1 .. "=" .. tostring(S.cfg[a1])
    end
    local t = {}
    for _, k in ipairs(CFG_ORDER) do t[#t + 1] = k .. "=" .. tostring(S.cfg[k]) end
    return table.concat(t, " ") .. " | afps <name> <value>, afps reset, afps toggle (F5), menu: F6"
end