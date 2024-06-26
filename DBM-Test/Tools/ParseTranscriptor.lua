local filter = require "Transcriptor-Filter"

local unpack = unpack or table.unpack -- Lua 5.1 compat

local function usage()
	print("Usage: lua ParseTranscriptor.lua --transcriptor <path to SavedVariables/Transcriptor.lua> [--entry \"[YYYY-MM-DD]@[HH:MM:SS]\" --start <log offset> --end <log offset> --player <player who logged this>]")
	os.exit(1)
end

local function parseArgs(...)
	local args = {}
	local currentKey
	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		if arg:match("^%-%-") then
			if currentKey then
				args[currentKey] = true
			end
			currentKey = arg:match("^%-%-(.*)")
		elseif currentKey then
			args[currentKey] = arg
			currentKey = nil
		else
			usage()
		end
	end
	return args
end

local args = parseArgs(...)

if not args.transcriptor then
	usage()
end

local playerName = args.player

local function loadTranscriptorDB(fileName)
	local env = {}
	if _VERSION == "Lua 5.1" then
		print("Lua 5.1 can choke on huge Transcriptor logs, try using a newer version of Lua if you get errors about the constant limit")
		local f, err = loadfile(fileName)
		if not f then error(err) end
		setfenv(f, env)
		f()
	else
		---@diagnostic disable-next-line: redundant-parameter
		local f, err = loadfile(fileName, nil, env)
		if not f then error(err) end
		f()
	end
	return env.TranscriptDB
end

local transcriptorDB = loadTranscriptorDB(args.transcriptor)
local logName = nil
local log = nil

for k, v in pairs(transcriptorDB) do
	if not args.entry or k:sub(1, #args.entry) == args.entry then
		if log then
			print("Multiple logs found in file, use --entry to select one")
			os.exit(1)
		end
		log = v
		logName = k
	end
end

if not log or not logName then
	print("Could not find specified log")
	os.exit(1)
end

local firstLog = args.start
local lastLog = args["end"]

if not firstLog or not lastLog then
	local encounterStarts = {}
	local encounterEnds = {}
	local bossKills = {}
	for i, v in ipairs(log.total) do
		if v:find("%[ENCOUNTER_START%]") then
			encounterStarts[#encounterStarts + 1] = i
		elseif v:find("%[ENCOUNTER_END%]") then
			encounterEnds[#encounterEnds + 1] = i
		elseif v:find("%[BOSS_KILL%]") then
			bossKills[#bossKills + 1] = i
		end
	end
	if #encounterStarts ~= 1 or #encounterEnds ~= 1 then
		print("Log doesn't contain exactly one ENCOUNTER_START/END")
		print("ENCOUNTER_START at: " .. table.concat(encounterStarts, ", "))
		print("ENCOUNTER_END at: " .. table.concat(encounterEnds, ", "))
		print("Use --start and --end to select offsets explicitly")
		os.exit(1)
	end
	firstLog = encounterStarts[1]
	lastLog = encounterEnds[1]
	-- BOSS_KILL often triggers after ENCOUNTER_END, we want to include both to test that we don't trigger end multiple times
	local lastBossKill = bossKills[#bossKills]
	if lastBossKill and lastBossKill < lastLog + 50 then
		lastLog = math.max(lastLog, lastBossKill)
	end
end

local function guessType(str)
	if str == "nil" then
		return nil
	end
	if str == "true" then
		return true
	end
	if str == "false" then
		return false
	end
	if tostring(tonumber(str)) == str then
		return tonumber(str)
	end
	return str
end

local function guessTypes(...)
	if select("#", ...) == 1 then
		return guessType(...)
	else
		return guessType(...), guessTypes(select(2, ...))
	end
end

local hexMetatable = {
	__tostring = function(self)
		return "0x" .. ("%x"):format(self.value)
	end
}
local function hex(num)
	return setmetatable({value = num}, hexMetatable)
end

local function literal(lit)
	if type(lit) == "string" then
		return ("%q"):format(lit)
	else
		return tostring(lit)
	end
end

local function literals(...)
	if select("#", ...) == 1 then
		return literal(...)
	else
		return literal(...), literals(select(2, ...))
	end
end

local function literalsTable(...)
	local tbl = {...}
	for i = 1, select("#", ...) do
		tbl[i] = literal(select(i, ...))
	end
	return tbl
end

local function getInstanceInfo(info)
	return ("{name = %s, instanceType = %s, difficultyID = %s, difficultyName = %s, maxPlayers = %s, dynamicDifficulty = %s, isDynamic = %s, instanceID = %s, instanceGroupSize = %s, lfgDungeonID = %s}"):format(
		literals(info.name, info.instanceType, info.difficultyID, info.difficultyName, info.maxPlayers, info.dynamicDifficulty, info.isDynamic, info.instanceID, info.instanceGroupSize, info.lfgDungeonID)
	)
end

local function transcribeUnitSpellEvent(event, params)
	if params:match("^PLAYER_SPELL") then
		return
	end
	local unit, guid, spellId = params:match("%[%[([^:]+):([^:]+):([^%]]+)%]%]")
	return literalsTable(event, unit, guid, tonumber(spellId))
end

-- Rough attempt at flag reconstruction, not 100% correct, we could be a bit more smart here about REACTION by tracking a GUID across multiple events
-- Or using sourceFlags from a previous event to build destFlags if source flags are logged
local function reconstructFlags(name, isPlayer, isPet, isNpc)
	local flags = 0
	if isPlayer then
		if name == playerName then
			flags = flags + 0x1 -- AFFILIATION_MINE
		else
			flags = flags + 0x2 -- AFFILIATION_PARTY -- don't distinguish party vs raid
		end
		flags = flags + 0x0010  -- REACTION_FRIENDLY
		flags = flags + 0x0100  -- CONTROL_PLAYER
		flags = flags + 0x0400  -- TYPE_PLAYER
	elseif isPet then
		flags = flags + 0x0002  -- AFFILIATION_PARTY
		flags = flags + 0x0010  -- REACTION_FRIENDLY -- all pets are friendly for now
		flags = flags + 0x0100  -- CONTROL_PLAYER
		flags = flags + 0x1000  -- TYPE_PET
	elseif isNpc then
		flags = flags + 0x0008  -- AFFILIATION_OUTSIDER
		flags = flags + 0x0040  -- REACTION_HOSTILE -- all NPCs are hostile for now
		flags = flags + 0x0200  -- CONTROL_NPC
		flags = flags + 0x0800  -- TYPE_NPC
	end
	return flags
end

local flagWarningShown

local function transcribeCleu(rawParams)
	local params = {}
	local i = 1 -- to handle nil
	for param in rawParams:gmatch("([^#]*)") do
		params[i] = guessType(param)
		i = i + 1
	end
	local event, sourceFlags, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraArg1, extraArg2
	if params[1]:match("%[CONDENSED%]") then
		local _
		event, sourceGUID, sourceName, _, spellId, spellName = unpack(params, 1, i - 1)
		destGUID = ""
	else
		if type(params[2]) == "number" then
			event, sourceFlags, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraArg1, extraArg2 = unpack(params, 1, i - 1)
			-- clear special flags to make flags look more uniform across events
			-- deliberately doing this in a bit ugly way to not pull in a dependency on bit.* for Lua 5.1
			-- TODO: target/focus could be used to reconstruct targets
			if sourceFlags >= 0x80000000 then -- NONE
				sourceFlags = sourceFlags - 0x80000000
			end
			if sourceFlags >= 0x80000 then -- MAINASSIST
				sourceFlags = sourceFlags - 0x80000
			end
			if sourceFlags >= 0x40000 then -- MAINTANK
				sourceFlags = sourceFlags - 0x80000
			end
			if sourceFlags >= 0x20000 then -- FOCUS
				sourceFlags = sourceFlags - 0x20000
			end
			if sourceFlags >= 0x10000 then -- TARGET
				sourceFlags = sourceFlags - 0x10000
			end
		else
			if not flagWarningShown and params[1] == "SPELL_CAST_START" then -- not all entries are logged with flags
				print("-- Note: log doesn't contain flags, /getspells logflags to log flags in Transcriptor. Results for mods relying heavily on flags may be inaccurate.")
				flagWarningShown = true
			end
			event, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraArg1, extraArg2 = unpack(params, 1, i - 1)
		end
	end
	if spellId and filter.ignoredSpellIds[spellId] then
		return
	end
	local sourceCid = sourceGUID and tonumber(sourceGUID:match("Creature%-0%-%d*%-%d*%-%d*%-(%d+)") or tonumber(sourceGUID:match("GameObject%-0%-%d*%-%d*%-%d*%-(%d+)")))
	local destCid = destGUID and tonumber(destGUID:match("Creature%-0%-%d*%-%d*%-%d*%-(%d+)") or destGUID:match("GameObject%-0%-%d*%-%d*%-%d*%-(%d+)"))
	if sourceCid and filter.ignoredCreatureIds[sourceCid] or destCid and filter.ignoredCreatureIds[destCid] then
		return
	end
	local destIsPlayer = destGUID and destGUID:match("^Player%-")
	local srcIsPlayer = sourceGUID and sourceGUID:match("^Player%-")
	local destIsPet = destGUID and destGUID:match("^Pet%-")
	local srcIsPet = sourceGUID and sourceGUID:match("^Pet%-")
	local destIsPlayerOrPet = destIsPlayer or destIsPet
	local srcIsPlayerOrPet = srcIsPlayer or srcIsPet
	local destIsNpc = destGUID and (destGUID:match("^Creature-") or destGUID:match("^Vehicle-"))
	local srcIsNpc = sourceGUID and (sourceGUID:match("^Creature-") or sourceGUID:match("^Vehicle-"))
	if event == "SPELL_DAMAGE[CONDENSED]" then event = "SPELL_DAMAGE" end
	if event == "SPELL_PERIODIC_DAMAGE[CONDENSED]" then event = "SPELL_PERIODIC_DAMAGE" end
	if event == "SPELL_SUMMON" and srcIsPlayerOrPet then
		return
	end
	-- FIXME: use sourceFlags if available to filter healing and attacks of friendly totems
	if (event:match("_ENERGIZE$") or event:match("_HEAL$")) and destIsPlayerOrPet then
		return
	end
	if (event:match("^SPELL_CAST") or event == "SPELL_EXTRA_ATTACKS") and srcIsPlayerOrPet then
		return
	end
	if (event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" or event == "SPELL_PERIODIC_MISSED" or event == "SPELL_MISSED" or event == "DAMAGE_SHIELD" or event == "SWING_DAMAGE" or event == "DAMAGE_SHIELD_MISSED") and srcIsPlayerOrPet then
		return
	end
	if event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_APPLIED_DOSE" or event == "SPELL_AURA_REMOVED" or event == "SPELL_AURA_REMOVED_DOSE" or event == "SPELL_AURA_REFRESH" then
		if extraArg1 == "BUFF" and destIsPlayerOrPet or extraArg1 == "DEBUFF" and destIsNpc then
			return
		end
	end
	sourceFlags = sourceFlags or reconstructFlags(sourceName, srcIsPlayer, srcIsPet, srcIsNpc)
	local destFlags = reconstructFlags(destName, destIsPlayer, destIsPet, destIsNpc)
	return literalsTable(
		"COMBAT_LOG_EVENT_UNFILTERED", event,				-- skipping timestamp and hideCaster
		sourceGUID, sourceName, hex(sourceFlags), hex(0),	-- 0x0 == sourceRaidFlags, not logged
		destGUID, destName, hex(destFlags), hex(0),			-- 0x0 == destRaidFlags, not logged
		spellId, spellName, hex(0),							-- 0x0 == spellSchool, not logged
		extraArg1, extraArg2
	)
end

local function transcribeEvent(event, params)
	if event:match("^DBM_") or event:match("^NAME_PLATE_UNIT_") then
		return
	end
	if event:match("^UNIT_SPELL") then
		return transcribeUnitSpellEvent(event, params)
	end
	if event == "UNIT_TARGET" or event == "PLAYER_TARGET_CHANGED" then
		-- TODO: use this to reconstruct targets, e.g. for IsTanking
		return
	end
	if event == "CLEU" then
		return transcribeCleu(params)
	end
	-- Generic event
	local result = {literal(event)}
	for param in params:gmatch("([^#]*)") do
		result[#result + 1] = literal(guessType(param))
	end
	return result
end

local function getMetadataFromLog()
	local player
	local instanceInfo = {}
	for i = firstLog, lastLog do
		local line = log.total[i]
		if not instanceInfo.name and line:match("GetInstanceInfo%(%) =") then
			instanceInfo.name, instanceInfo.instanceType,
			instanceInfo.difficultyID, instanceInfo.difficultyName,
			instanceInfo.maxPlayers, instanceInfo.dynamicDifficulty,
			instanceInfo.isDynamic, instanceInfo.instanceID,
			instanceInfo.instanceGroupSize, instanceInfo.lfgDungeonID = guessTypes(line:match(
				"%[DBM_Debug%] GetInstanceInfo%(%) = ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^,]+), ([^#]+)"
			))
		end
		if not player then
			player = line:match("%[UNIT_SPELLCAST_SUCCEEDED%] PLAYER_SPELL{([^}]+)} %-.*%- %[%[player:Cast%-")
		end
		if player and instanceInfo.name then
			break
		end
	end
	return player, instanceInfo, logName:match("Version: 1%.") and "SeasonOfDiscovery" or ""
end

local function getLog()
	local result = {}
	local timeOffset
	for i = firstLog, lastLog do
		local line = log.total[i]
		local time, event, params = line:match("^<([%d.]+) [^>]+> %[([^%]]*)%] (.*)")
		time = tonumber(time)
		if not tonumber(time) or not event or not params then
			error("unparseable line" .. line)
		end
		timeOffset = timeOffset or time
		time = time - timeOffset
		local testEvent = transcribeEvent(event, params)
		if testEvent then
			result[#result + 1] = ("{%.2f, %s},"):format(time, table.concat(testEvent, ", "))
		end
	end
	return table.concat(result, "\n\t\t")
end

local template = [[
DBM.Test:DefineTest{
	name = %s,
	gameVersion = %s,
	addon = %s,
	mod = %s,
	instanceInfo = %s,
	playerName = %s,
	log = {
		%s
	}
}
]]

local deducedPlayer, instanceInfo, gameVersion = getMetadataFromLog()
if playerName and deducedPlayer ~= playerName then
	print("-- Warning: log seems to be created by player " .. deducedPlayer .. ", you provided player " .. playerName .. " on CLI, this mismatch can mess with flags and targets")
end
playerName = playerName or deducedPlayer

local function generateTest()
	local str = template:format(
		literal(""), literal(gameVersion), literal(""), literal(""),
		getInstanceInfo(instanceInfo),
		literal(playerName),
		getLog()
	)
	return str
end

print(generateTest())
