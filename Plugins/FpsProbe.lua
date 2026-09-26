--[[
FpsProbe.lua  -  /bwperf
Small self-contained probe to collect evidence for BigWigs FPS reports.
Samples once per second: framerate, Lua memory (gcinfo) and BigWigs queue sizes.
  /bwperf start    begin sampling
  /bwperf stop     stop and print the report (paste it into the bug report)
  /bwperf auto     toggle: sample automatically from combat start to combat end
Lua memory only ever rises until the (stop-the-world) garbage collector runs, so
"garbage KB/s" is the rate at which addons allocate, and "GC runs" counts the drops.
]]
local probe = CreateFrame("Frame", "BigWigsFpsProbe")
local running, auto = false, false
local elapsed, s

local function count(t)
	local n = 0
	if t then
		for _ in pairs(t) do
			n = n + 1
		end
	end
	return n
end

local function lib(name)
	local ok, l = pcall(AceLibrary, name)
	if ok then
		return l
	end
end

local function Reset()
	local mem = gcinfo()
	s = { n = 0, fpsSum = 0, fpsMin = 100000, startMem = mem, lastMem = mem, garbage = 0, gcRuns = 0,
		maxDrop = 0, maxSched = 0, maxBars = 0, startTime = GetTime(), zone = GetRealZoneText() or "?" }
	elapsed = 0
end

local function Sample()
	local fps = GetFramerate()
	local mem = gcinfo()
	s.n = s.n + 1
	s.fpsSum = s.fpsSum + fps
	if fps < s.fpsMin then
		s.fpsMin = fps
	end
	local d = mem - s.lastMem
	if d >= 0 then
		s.garbage = s.garbage + d
	else
		s.gcRuns = s.gcRuns + 1
		if -d > s.maxDrop then
			s.maxDrop = -d
		end
	end
	s.lastMem = mem
	local ace = lib("AceEvent-2.0")
	if ace then
		local n = count(ace.delayRegistry)
		if n > s.maxSched then
			s.maxSched = n
		end
	end
	local cb = lib("CandyBar-2.2")
	if cb and cb.var then
		local n = count(cb.var.handlers)
		if n > s.maxBars then
			s.maxBars = n
		end
	end
end

local function Report()
	if not s or s.n == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("BigWigs perf: no samples.")
		return
	end
	local dur = GetTime() - s.startTime
	local function say(m)
		DEFAULT_CHAT_FRAME:AddMessage("BigWigs perf: " .. m)
	end
	say(string.format("%s, %.0fs, raid %d", s.zone, dur, GetNumRaidMembers()))
	say(string.format("FPS avg %.1f / min %.1f", s.fpsSum / s.n, s.fpsMin))
	say(string.format("Lua memory %d -> %d KB, allocation ~%.0f KB/s, GC runs %d (largest %d KB)",
		s.startMem, s.lastMem, s.garbage / dur, s.gcRuns, s.maxDrop))
	say(string.format("peak scheduled events %d, peak bars %d", s.maxSched, s.maxBars))
	if BigWigsClientMods then
		say(BigWigsClientMods:Summary())
	end
end

local function Start()
	Reset()
	running = true
	probe:Show()
	DEFAULT_CHAT_FRAME:AddMessage("BigWigs perf: sampling started (/bwperf stop to report).")
end

local function Stop()
	if running then
		running = false
		Sample()
		Report()
	end
	probe:Hide()
end

probe:SetScript("OnUpdate", function()
	if not running then
		return
	end
	elapsed = elapsed + arg1
	if elapsed >= 1 then
		elapsed = 0
		Sample()
	end
end)

probe:RegisterEvent("PLAYER_REGEN_DISABLED")
probe:RegisterEvent("PLAYER_REGEN_ENABLED")
probe:SetScript("OnEvent", function()
	if not auto then
		return
	end
	if event == "PLAYER_REGEN_DISABLED" and not running then
		Start()
	elseif event == "PLAYER_REGEN_ENABLED" and running then
		Stop()
	end
end)

SLASH_BWPERF1 = "/bwperf"
SlashCmdList["BWPERF"] = function(msg)
	msg = string.lower(msg or "")
	if msg == "start" then
		Start()
	elseif msg == "stop" then
		Stop()
	elseif msg == "auto" then
		auto = not auto
		DEFAULT_CHAT_FRAME:AddMessage("BigWigs perf: auto " .. (auto and "ON (samples each combat)" or "OFF"))
	else
		DEFAULT_CHAT_FRAME:AddMessage("/bwperf start | stop | auto")
	end
end
