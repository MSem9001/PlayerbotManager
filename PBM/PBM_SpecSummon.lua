-- ============================================================
--  PBM_SpecSummon.lua  |  Spec-targeted RndBot summon buttons
--
--  Extends the "Add RndBot" column on the Playerbots tab with a
--  row of small per-spec icon buttons next to each class. Clicking
--  one summons a random bot of that class, then - once it actually
--  shows up in your party/raid roster - the addon automatically:
--    1) sets its talent spec       ("talents spec <spec>")
--    2) applies a matching role    ("co +tank/heal/dps,?")
--    3) auto-gears it              ("autogear")
--
--  New arrivals are detected by diffing a snapshot of your
--  party/raid roster (names + classes) on every
--  PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE against the previous
--  snapshot, rather than matching localized "X has joined..." chat
--  text (party and raid joins turned out to use different wording).
--  Correlation with the newly-joined bot is done via a per-class
--  FIFO queue: each click pushes the chosen spec onto
--  PBM.State.pendingSpecSummons[classCmd]; the next roster addition
--  of that class consumes the oldest pending entry. Entries older
--  than 90s are dropped rather than mis-applied to an unrelated bot
--  join (e.g. one you added by name, or another summon that failed).
--
--  Only PvE specs are exposed as quick buttons. Role assignments
--  (tank/heal/dps) below reflect standard WotLK 3.3.5 conventions
--  (e.g. Paladin Protection = tank, Priest Shadow = dps). Death
--  Knight "Blood" and "Double Aura Blood" are both mapped to tank
--  since Blood is the WotLK tank spec - edit PBM.SpecData below if
--  you'd rather map any of these differently.
-- ============================================================
PBM       = PBM       or {}
PBM.State = PBM.State or {}
PBM.State.pendingSpecSummons = PBM.State.pendingSpecSummons or {}
PBM.State.specSummonPicking  = PBM.State.specSummonPicking  or {}  -- [botName] = jobEntry, while waiting for "Picking X"
PBM.State.lastRosterSnapshot = PBM.State.lastRosterSnapshot or nil -- [name] = classToken, refreshed on every roster change

-- -- UnitClass token -> CLASS_DEFS.cmd (see PBM_Tab_Playerbots.lua) --
local CLASS_TOKEN_TO_CMD = {
    DEATHKNIGHT = "dk",
    DRUID       = "druid",
    HUNTER      = "hunter",
    MAGE        = "mage",
    PALADIN     = "paladin",
    PRIEST      = "priest",
    ROGUE       = "rogue",
    SHAMAN      = "shaman",
    WARLOCK     = "warlock",
    WARRIOR     = "warrior",
}

-- -- PvE spec quick-buttons per class ----------------------------
-- role drives the "co +<role>,?" strategy applied after summon.
local ICN = "Interface\\Icons\\"
PBM.SpecData = {
    dk = {
        { spec="blood pve",             label="Blood",             role="tank", icon=ICN.."Spell_DeathKnight_BloodPresence"  },
        { spec="frost pve",             label="Frost",             role="dps",  icon=ICN.."Spell_DeathKnight_FrostPresence"  },
        { spec="unholy pve",            label="Unholy",            role="dps",  icon=ICN.."Spell_DeathKnight_UnholyPresence" },
        { spec="double aura blood pve", label="Double Aura Blood", role="tank", icon=ICN.."Spell_DeathKnight_BloodPresence"  },
    },
    druid = {
        { spec="balance pve", label="Balance",     role="dps",  icon=ICN.."Spell_Nature_StarFall"     },
        { spec="bear pve",    label="Bear",        role="tank", icon=ICN.."Ability_Racial_BearForm"   },
        { spec="resto pve",   label="Restoration", role="heal", icon=ICN.."Spell_Nature_HealingTouch" },
        { spec="cat pve",     label="Cat",         role="dps",  icon=ICN.."Ability_Druid_CatForm"     },
    },
    hunter = {
        { spec="bm pve",   label="Beast Mastery", role="dps", icon=ICN.."Ability_Hunter_BeastTaming" },
        { spec="mm pve",   label="Marksmanship",  role="dps", icon=ICN.."Ability_Marksmanship"       },
        { spec="surv pve", label="Survival",      role="dps", icon=ICN.."Ability_Hunter_SwiftStrike" },
    },
    mage = {
        { spec="arcane pve",    label="Arcane",    role="dps", icon=ICN.."Spell_Holy_MagicalSentry"    },
        { spec="fire pve",      label="Fire",      role="dps", icon=ICN.."Spell_Fire_FireBolt02"       },
        { spec="frost pve",     label="Frost",     role="dps", icon=ICN.."Spell_Frost_FrostBolt02"     },
        { spec="frostfire pve", label="Frostfire", role="dps", icon=ICN.."Ability_Mage_FrostFireBolt"  },
    },
    paladin = {
        { spec="holy pve", label="Holy",        role="heal", icon=ICN.."Spell_Holy_HolyBolt"                },
        { spec="prot pve", label="Protection",  role="tank", icon=ICN.."Ability_Paladin_ShieldoftheTemplar" },
        { spec="ret pve",  label="Retribution", role="dps",  icon=ICN.."Spell_Holy_AuraofLight"             },
    },
    priest = {
        { spec="disc pve",   label="Discipline", role="heal", icon=ICN.."Spell_Holy_WordFortitude"    },
        { spec="holy pve",   label="Holy",       role="heal", icon=ICN.."Spell_Holy_GuardianSpirit"   },
        { spec="shadow pve", label="Shadow",     role="dps",  icon=ICN.."Spell_Shadow_ShadowWordPain" },
    },
    rogue = {
        { spec="as pve",       label="Assassination", role="dps", icon=ICN.."Ability_Rogue_Eviscerate" },
        { spec="combat pve",   label="Combat",        role="dps", icon=ICN.."Ability_BackStab"         },
        { spec="subtlety pve", label="Subtlety",      role="dps", icon=ICN.."Ability_Stealth"          },
    },
    shaman = {
        { spec="ele pve",   label="Elemental",   role="dps",  icon=ICN.."Spell_Nature_Lightning"       },
        { spec="enh pve",   label="Enhancement", role="dps",  icon=ICN.."Spell_Nature_LightningShield" },
        { spec="resto pve", label="Restoration", role="heal", icon=ICN.."Spell_Nature_MagicImmunity"   },
    },
    warlock = {
        { spec="affli pve",  label="Affliction",  role="dps", icon=ICN.."Spell_Shadow_DeathCoil"     },
        { spec="demo pve",   label="Demonology",  role="dps", icon=ICN.."Spell_Shadow_Metamorphosis" },
        { spec="destro pve", label="Destruction", role="dps", icon=ICN.."Spell_Shadow_RainOfFire"    },
    },
    warrior = {
        { spec="arms pve", label="Arms",       role="dps",  icon=ICN.."Ability_Warrior_Sunder"          },
        { spec="fury pve", label="Fury",       role="dps",  icon=ICN.."Ability_Warrior_InnerRage"       },
        { spec="prot pve", label="Protection", role="tank", icon=ICN.."Ability_Warrior_DefensiveStance" },
    },
}

-- -- PvP spec quick-buttons per class ------------------------------
-- Mirrors PBM.SpecData above, but every "spec" string is a distinct
-- "<x> pvp" talent build (PBM_TalentData.lua carries a separate point
-- allocation for each) rather than the PvE one. A few PvE-only builds
-- have no PvP counterpart in the talent data and are intentionally
-- left out here: Death Knight "Double Aura Blood", Mage "Frostfire",
-- and Druid "Bear" (no dedicated PvP bear-tank build).
PBM.SpecDataPvP = {
    dk = {
        { spec="blood pvp",  label="Blood",  role="tank", icon=ICN.."Spell_DeathKnight_BloodPresence"  },
        { spec="frost pvp",  label="Frost",  role="dps",  icon=ICN.."Spell_DeathKnight_FrostPresence"  },
        { spec="unholy pvp", label="Unholy", role="dps",  icon=ICN.."Spell_DeathKnight_UnholyPresence" },
    },
    druid = {
        { spec="balance pvp", label="Balance",     role="dps",  icon=ICN.."Spell_Nature_StarFall"     },
        { spec="resto pvp",   label="Restoration", role="heal", icon=ICN.."Spell_Nature_HealingTouch" },
        { spec="cat pvp",     label="Cat",         role="dps",  icon=ICN.."Ability_Druid_CatForm"     },
    },
    hunter = {
        { spec="bm pvp",   label="Beast Mastery", role="dps", icon=ICN.."Ability_Hunter_BeastTaming" },
        { spec="mm pvp",   label="Marksmanship",  role="dps", icon=ICN.."Ability_Marksmanship"       },
        { spec="surv pvp", label="Survival",      role="dps", icon=ICN.."Ability_Hunter_SwiftStrike" },
    },
    mage = {
        { spec="arcane pvp", label="Arcane", role="dps", icon=ICN.."Spell_Holy_MagicalSentry" },
        { spec="fire pvp",   label="Fire",   role="dps", icon=ICN.."Spell_Fire_FireBolt02"    },
        { spec="frost pvp",  label="Frost",  role="dps", icon=ICN.."Spell_Frost_FrostBolt02"  },
    },
    paladin = {
        { spec="holy pvp", label="Holy",        role="heal", icon=ICN.."Spell_Holy_HolyBolt"                },
        { spec="prot pvp", label="Protection",  role="tank", icon=ICN.."Ability_Paladin_ShieldoftheTemplar" },
        { spec="ret pvp",  label="Retribution", role="dps",  icon=ICN.."Spell_Holy_AuraofLight"             },
    },
    priest = {
        { spec="disc pvp",   label="Discipline", role="heal", icon=ICN.."Spell_Holy_WordFortitude"    },
        { spec="holy pvp",   label="Holy",       role="heal", icon=ICN.."Spell_Holy_GuardianSpirit"   },
        { spec="shadow pvp", label="Shadow",     role="dps",  icon=ICN.."Spell_Shadow_ShadowWordPain" },
    },
    rogue = {
        { spec="as pvp",       label="Assassination", role="dps", icon=ICN.."Ability_Rogue_Eviscerate" },
        { spec="combat pvp",   label="Combat",        role="dps", icon=ICN.."Ability_BackStab"         },
        { spec="subtlety pvp", label="Subtlety",      role="dps", icon=ICN.."Ability_Stealth"          },
    },
    shaman = {
        { spec="ele pvp",   label="Elemental",   role="dps",  icon=ICN.."Spell_Nature_Lightning"       },
        { spec="enh pvp",   label="Enhancement", role="dps",  icon=ICN.."Spell_Nature_LightningShield" },
        { spec="resto pvp", label="Restoration", role="heal", icon=ICN.."Spell_Nature_MagicImmunity"   },
    },
    warlock = {
        { spec="affli pvp",  label="Affliction",  role="dps", icon=ICN.."Spell_Shadow_DeathCoil"     },
        { spec="demo pvp",   label="Demonology",  role="dps", icon=ICN.."Spell_Shadow_Metamorphosis" },
        { spec="destro pvp", label="Destruction", role="dps", icon=ICN.."Spell_Shadow_RainOfFire"    },
    },
    warrior = {
        { spec="arms pvp", label="Arms",       role="dps",  icon=ICN.."Ability_Warrior_Sunder"          },
        { spec="fury pvp", label="Fury",       role="dps",  icon=ICN.."Ability_Warrior_InnerRage"       },
        { spec="prot pvp", label="Protection", role="tank", icon=ICN.."Ability_Warrior_DefensiveStance" },
    },
}

-- -- tiny local timer helper (mirrors PBM_Core.lua's CoreTimerAfter) --
local function SpecAfter(delay, func)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, func)
    else
        local elapsed = 0
        local f = CreateFrame("Frame")
        f:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= delay then
                self:SetScript("OnUpdate", nil)
                func()
            end
        end)
    end
end

-- -- Reusable small icon button (mirrors PBIconBtn in PBM_Tab_Playerbots.lua) --
function PBM.CreateSpecIconButton(parent, x, y, size, iconPath, tipTitle, tipBody, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    btn:SetFrameLevel(parent:GetFrameLevel() + 2)

    local bdr = btn:CreateTexture(nil, "BACKGROUND")
    bdr:SetAllPoints()
    bdr:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    bdr:SetBlendMode("ADD"); bdr:SetAlpha(0.5)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT",     btn, "TOPLEFT",     1, -1)
    tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    tex:SetTexture(iconPath)

    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tipTitle, 0.78, 0.61, 0.23)
        if tipBody then GameTooltip:AddLine(tipBody, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- -- Summon a random bot of cmdToken's class, queue the spec job --
function PBM.SummonSpecBot(cmdToken, job)
    local q = PBM.State.pendingSpecSummons[cmdToken]
    if not q then q = {}; PBM.State.pendingSpecSummons[cmdToken] = q end
    q[#q + 1] = {
        spec  = job.spec,
        role  = job.role,
        label = job.label,
        t     = GetTime(),
    }
    SendChatMessage(".playerbots bot addclass " .. cmdToken, "SAY")
    DEFAULT_CHAT_FRAME:AddMessage("|cffC69B3APBM:|r Summoning random " .. cmdToken ..
        " -> will auto-set |cffffcc00" .. job.label .. "|r on join.")
end

-- -- Gear/strategy tail end, run once the spec change is confirmed --
-- (maintenance step removed - server-side issue with that command)
local function FinishBotSetup(botName, jobEntry)
    if jobEntry.role then
        PBM.SendToBot("co +" .. jobEntry.role .. ",?", botName)
    end
    SpecAfter(2, function()
        PBM.SendToBot("autogear", botName)
        if PBM.FindTrackedRowIndexByName then
            local di = PBM.FindTrackedRowIndexByName(botName)
            if di and LichborneTrackerDB and LichborneTrackerDB.rows[di] then
                LichborneTrackerDB.rows[di].spec = jobEntry.label
                if PBM.RefreshOverviewRows then PBM.RefreshOverviewRows() end
                if PBM.RefreshRows then PBM.RefreshRows() end
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffC69B3APBM:|r |cff44ff44" .. botName ..
            "|r configured as |cffffcc00" .. jobEntry.label .. "|r.")
    end)
end

-- -- Apply the queued spec to a freshly-joined bot -----------------
-- A fresh RndBot doesn't have an existing dual-spec to switch away
-- from, so unlike the addon's roster "Set Talents" menu (which
-- targets already-established bots and primes with "talents switch
-- 1" first) we can just send "talents spec <spec>" directly. We
-- then wait for the bot's own "Picking ..." reply (same signal
-- PBM_Core.lua's menu-driven flow waits on) before moving on to
-- strategy/gear, instead of guessing a fixed delay. A 15s fallback
-- fires FinishBotSetup anyway in case the "Picking " reply never
-- arrives (e.g. spec name mismatch), so the bot doesn't end up
-- stuck half-configured.
local function ApplySpecToNewBot(botName, jobEntry)
    PBM.SendToBot("talents spec " .. jobEntry.spec, botName)
    PBM.State.specSummonPicking[botName] = jobEntry
    SpecAfter(15, function()
        if PBM.State.specSummonPicking[botName] == jobEntry then
            PBM.State.specSummonPicking[botName] = nil
            FinishBotSetup(botName, jobEntry)
        end
    end)
end

-- -- Join detection via roster diffing --------------------------------
-- Rather than matching localized/version-specific chat text (party
-- and raid joins turned out to use different wording, and there
-- could be more variants), snapshot the actual party/raid roster on
-- every PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE event and diff it
-- against the previous snapshot. Any name present now that wasn't
-- there before is a genuine new arrival - works identically whether
-- the group is a 2-4 person party or a full raid, and needs no
-- knowledge of what the client actually prints.
local function BuildRosterSnapshot()
    local snap = {}
    local me = UnitName("player")
    if me then
        local _, meClass = UnitClass("player")
        snap[me] = meClass
    end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local unit = "raid" .. i
            local n = UnitName(unit)
            if n then
                local _, c = UnitClass(unit)
                snap[n] = c
            end
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        for i = 1, GetNumPartyMembers() do
            local unit = "party" .. i
            local n = UnitName(unit)
            if n then
                local _, c = UnitClass(unit)
                snap[n] = c
            end
        end
    end
    return snap
end

-- -- Auto-track any bot that joins your group ---------------------
-- The Overview tracker is otherwise only populated by manually
-- targeting someone and clicking "+Add Target", or by running a
-- group/GS scan. That means a bot summoned via the spec buttons
-- above *or* the addon's original "Add RndBot" buttons never gets a
-- tracker row unless you happen to scan before it leaves your group
-- - so if it's removed first, "Remove Orphaned Bots" has no record
-- of it and can't flag it as orphaned. Give every new roster arrival
-- a tracker row immediately (mirrors AddTargetToTracker in
-- PBM_TrackerCore.lua), independent of the spec-queue logic below,
-- so this covers ALL bot joins, not just spec-summoned ones.
local function ResolveGroupUnitToken(name)
    if UnitName("player") == name then return "player" end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local unit = "raid" .. i
            if UnitName(unit) == name then return unit end
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        for i = 1, GetNumPartyMembers() do
            local unit = "party" .. i
            if UnitName(unit) == name then return unit end
        end
    end
    return nil
end

local function TrackNewMemberInDB(name, classToken)
    if not name or name == "" then return end
    if not (PBM.CLASS_TOKEN_MAP and PBM.EnsureClass and PBM.GetAllClassRows and PBM.DefaultRow) then return end
    local cls = classToken and PBM.CLASS_TOKEN_MAP[classToken]
    if not cls then return end
    if not (LichborneTrackerDB and LichborneTrackerDB.rows) then return end

    PBM.EnsureClass(cls)
    local indices = PBM.GetAllClassRows(cls)
    for _, di in ipairs(indices) do
        local row = LichborneTrackerDB.rows[di]
        if row.name and row.name ~= "" and row.name:lower() == name:lower() then
            return -- already tracked
        end
    end
    local slot = nil
    for _, di in ipairs(indices) do
        local row = LichborneTrackerDB.rows[di]
        if not row.name or row.name == "" then slot = di; break end
    end
    if not slot then
        table.insert(LichborneTrackerDB.rows, PBM.DefaultRow(cls))
        slot = #LichborneTrackerDB.rows
    end
    local unit = ResolveGroupUnitToken(name)
    LichborneTrackerDB.rows[slot].name  = name
    LichborneTrackerDB.rows[slot].level = (unit and UnitLevel(unit)) or 0

    if PBM.State.overviewRowFrames and #PBM.State.overviewRowFrames > 0 and PBM.RefreshOverviewRows then
        PBM.RefreshOverviewRows()
    end
    if PBM.State.rowFrames and #PBM.State.rowFrames > 0 and PBM.RefreshRows then
        PBM.RefreshRows()
    end
end

local function HandleNewMember(name, classToken)
    local cmdToken = classToken and CLASS_TOKEN_TO_CMD[classToken]
    if not cmdToken then return end

    local q = PBM.State.pendingSpecSummons[cmdToken]
    if not q or #q == 0 then return end

    -- Drop stale entries (older than 90s - likely an unrelated join)
    while q[1] and (GetTime() - q[1].t) > 90 do
        table.remove(q, 1)
    end
    local jobEntry = table.remove(q, 1)
    if not jobEntry then return end

    ApplySpecToNewBot(name, jobEntry)
end

local _rosterFrame = CreateFrame("Frame")
_rosterFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
_rosterFrame:RegisterEvent("RAID_ROSTER_UPDATE")
_rosterFrame:RegisterEvent("PLAYER_LOGIN")
_rosterFrame:SetScript("OnEvent", function()
    local newSnap = BuildRosterSnapshot()
    local oldSnap = PBM.State.lastRosterSnapshot
    if oldSnap then
        for name, classToken in pairs(newSnap) do
            if not oldSnap[name] then
                TrackNewMemberInDB(name, classToken)
                HandleNewMember(name, classToken)
            end
        end
    end
    PBM.State.lastRosterSnapshot = newSnap
end)

-- -- Listen for talent-pick confirmations -----------------------------
-- (Runs alongside PBM_Core.lua's own whisper handling - both fire
--  independently off the same event, no interference; we use our
--  own PBM.State.specSummonPicking table rather than the shared
--  pickingPending one so we don't trigger the char-sheet menu's
--  own UI-refresh side effects.)
local _specPickFrame = CreateFrame("Frame")
_specPickFrame:RegisterEvent("CHAT_MSG_WHISPER")
_specPickFrame:SetScript("OnEvent", function(_, _, msg, sender)
    if not msg:find("^Picking ") then return end
    local jobEntry = PBM.State.specSummonPicking[sender]
    if not jobEntry then return end
    PBM.State.specSummonPicking[sender] = nil
    SpecAfter(1, function()
        FinishBotSetup(sender, jobEntry)
    end)
end)

-- -- Load diagnostic: confirms this file executed to the end ------
DEFAULT_CHAT_FRAME:AddMessage("|cffC69B3APBM:|r PBM_SpecSummon.lua loaded OK.")
