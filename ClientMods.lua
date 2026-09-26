--[[
ClientMods.lua
Detects the optional 1.12 client mods (SuperWoW, nampower, UnitXP_SP3, ClassicAPI,
VanillaHelpers). Informational only: nothing changes behaviour unless a module asks
BigWigsClientMods for a capability. Every check is nil-safe. Type /bwmods to print.
]]
BigWigsClientMods = BigWigsClientMods or {}
local M = BigWigsClientMods

function M:Detect()
	-- SetAutoloot is a SuperWoW function; existing modules already use it as a fallback check
	self.superwow = (SUPERWOW_VERSION or SUPERWOW_STRING or SetAutoloot) and true or false
	self.superwowVersion = SUPERWOW_VERSION

	self.nampower = false
	self.nampowerVersion = nil
	if type(GetNampowerVersion) == "function" then
		local ok, major, minor, patch = pcall(GetNampowerVersion)
		if ok and major then
			self.nampower = true
			self.nampowerVersion = major .. "." .. (minor or 0) .. "." .. (patch or 0)
		end
	end

	-- the mod's own recommended existence check
	self.unitxp = false
	if type(UnitXP) == "function" then
		local ok = pcall(UnitXP, "nop", "nop")
		self.unitxp = ok and true or false
	end

	self.classicapi = CLASSIC_API_VERSION and true or false
	self.classicapiVersion = CLASSIC_API_VERSION

	self.vanillahelpers = (type(ReadFile) == "function" and type(SetUnitBlip) == "function") and true or false

	-- WeirdUtils (weirdperformance.dll etc.). weirdperformance changes the Lua GC and speeds up
	-- string.find; it has no Lua API of its own that BigWigs needs, so this is informational.
	self.weirdutils = (type(GetWeirdUtilsVersion) == "function") and true or false
	-- WotLK-style structured combat log (DPSLog, bundled in WeirdUtils)
	self.combatlog = (type(CombatLogGetCurrentEventInfo) == "function") and true or false
end

-- true if the client can deliver structured unit cast events (no text parsing needed)
function M:HasCastEvents()
	return self.superwow
end

-- true if nampower's structured damage/aura events exist (needs nampower 2.14+ like MageTools)
function M:HasStructuredEvents()
	if not self.nampower or not GetNampowerVersion then
		return false
	end
	local major, minor = GetNampowerVersion()
	return major and (major > 2 or (major == 2 and minor >= 14)) and true or false
end

function M:Summary()
	local function yn(v, extra)
		if v then
			return "|cff00ff00yes|r" .. (extra and (" (" .. extra .. ")") or "")
		end
		return "|cffff0000no|r"
	end
	return "BigWigs client mods: SuperWoW " .. yn(self.superwow, self.superwowVersion and tostring(self.superwowVersion))
		.. ", nampower " .. yn(self.nampower, self.nampowerVersion)
		.. ", UnitXP_SP3 " .. yn(self.unitxp)
		.. ", ClassicAPI " .. yn(self.classicapi, self.classicapiVersion and tostring(self.classicapiVersion))
		.. ", VanillaHelpers " .. yn(self.vanillahelpers)
		.. ", WeirdUtils " .. yn(self.weirdutils)
		.. ", CombatLog events " .. yn(self.combatlog)
end

SLASH_BWMODS1 = "/bwmods"
SlashCmdList["BWMODS"] = function()
	M:Detect()
	DEFAULT_CHAT_FRAME:AddMessage(M:Summary())
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() M:Detect() end)
M:Detect()
