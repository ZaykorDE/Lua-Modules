---
-- @Liquipedia
-- wiki=commons
-- page=Module:MatchGroup/Util
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Array = require('Module:Array')
local FnUtil = require('Module:FnUtil')
local Json = require('Module:Json')
local Logic = require('Module:Logic')
local Lua = require('Module:Lua')
local MatchGroupWorkaround = require('Module:MatchGroup/Workaround')
local StringUtils = require('Module:StringUtils')
local Table = require('Module:Table')
local TypeUtil = require('Module:TypeUtil')
local Variables = require('Module:Variables')

local MatchGroupCoordinates = Lua.import('Module:MatchGroup/Coordinates', {requireDevIfEnabled = true})
local WikiSpecific = Lua.import('Module:Brkts/WikiSpecific', {requireDevIfEnabled = true})

local TBD_DISPLAY = '<abbr title="To Be Decided">TBD</abbr>'

local nilIfEmpty = StringUtils.nilIfEmpty

--[[
Non-display utility functions for brackets, matchlists, matches, opponents,
games, and etc in the new bracket framework.

Display related functions go in Module:MatchGroup/Display/Helper.
]]
local MatchGroupUtil = {types = {}}

MatchGroupUtil.types.ChildEdge = TypeUtil.struct({
	childMatchIndex = 'number',
	opponentIndex = 'number',
})
MatchGroupUtil.types.AdvanceBg = TypeUtil.literalUnion('up', 'stayup', 'stay', 'staydown', 'down')
MatchGroupUtil.types.AdvanceSpot = TypeUtil.struct({
	bg = MatchGroupUtil.types.AdvanceBg,
	matchId = 'string?',
	type = TypeUtil.literalUnion('advance', 'custom', 'qualify'),
})
MatchGroupUtil.types.BracketBracketData = TypeUtil.struct({
	advanceSpots = TypeUtil.array(MatchGroupUtil.types.AdvanceSpot),
	bracketResetMatchId = 'string?',
	header = 'string?',
	childEdges = TypeUtil.array(MatchGroupUtil.types.ChildEdge),
	childMatchIds = TypeUtil.array('string'),
	qualLose = 'boolean?',
	qualLoseLiteral = 'string?',
	qualSkip = 'number?',
	qualWin = 'boolean?',
	qualWinLiteral = 'string?',
	skipRound = 'number?',
	thirdPlaceMatchId = 'string?',
	title = 'string?',
	type = TypeUtil.literal('bracket'),
	parentMatchId = 'string?',
})
MatchGroupUtil.types.MatchCoordinates = TypeUtil.struct({
	depth = 'number',
	depthCount = 'number',
	matchIndexInRound = 'number',
	rootIndex = 'number',
	roundCount = 'number',
	roundIndex = 'number',
	sectionCount = 'number',
	sectionIndex = 'number',
	semanticDepth = 'number',
	semanticRoundIndex = 'number',
})
MatchGroupUtil.types.MatchlistBracketData = TypeUtil.struct({
	header = 'string?',
	title = 'string?',
	type = TypeUtil.literal('matchlist'),
})
MatchGroupUtil.types.BracketData = TypeUtil.union(
	MatchGroupUtil.types.MatchlistBracketData,
	MatchGroupUtil.types.BracketBracketData
)

MatchGroupUtil.types.Player = TypeUtil.struct({
	displayName = 'string?',
	flag = 'string?',
	pageName = 'string?',
})

MatchGroupUtil.types.Opponent = TypeUtil.struct({
	advanceBg = 'string?',
	advances = 'boolean?',
	icon = 'string?',
	name = 'string?',
	placement = 'number?',
	placement2 = 'number?',
	players = TypeUtil.array(MatchGroupUtil.types.Player),
	score = 'number?',
	score2 = 'number?',
	status = 'string?',
	status2 = 'string?',
	template = 'string?',
	type = 'string',
})

MatchGroupUtil.types.GameOpponent = TypeUtil.struct({
	name = 'string?',
	players = TypeUtil.optional(TypeUtil.array(MatchGroupUtil.types.Player)),
	template = 'string?',
	type = 'string',
})

MatchGroupUtil.types.ResultType = TypeUtil.literalUnion('default', 'draw', 'np')
MatchGroupUtil.types.Walkover = TypeUtil.literalUnion('L', 'FF', 'DQ')
MatchGroupUtil.types.Game = TypeUtil.struct({
	comment = 'string?',
	header = 'string?',
	length = 'number?',
	map = 'string?',
	mode = 'string?',
	participants = 'table',
	resultType = TypeUtil.optional(MatchGroupUtil.types.ResultType),
	scores = TypeUtil.array('number'),
	subgroup = 'number?',
	type = 'string?',
	vod = 'string?',
	walkover = TypeUtil.optional(MatchGroupUtil.types.Walkover),
	winner = 'number?',
})

MatchGroupUtil.types.Match = TypeUtil.struct({
	bracketData = MatchGroupUtil.types.BracketData,
	comment = 'string?',
	date = 'string',
	dateIsExact = 'boolean',
	finished = 'boolean',
	games = TypeUtil.array(MatchGroupUtil.types.Game),
	links = 'table',
	matchId = 'string?',
	mode = 'string',
	opponents = TypeUtil.array(MatchGroupUtil.types.Opponent),
	resultType = 'string?',
	stream = 'table',
	type = 'string?',
	vod = 'string?',
	walkover = 'string?',
	winner = 'number?',
})

MatchGroupUtil.types.Team = TypeUtil.struct({
	bracketName = 'string',
	displayName = 'string',
	pageName = 'string?',
	shortName = 'string',
})

MatchGroupUtil.types.Matchlist = TypeUtil.struct({
	matches = TypeUtil.array(MatchGroupUtil.types.Match),
	matchesById = TypeUtil.table('string', MatchGroupUtil.types.Match),
	type = TypeUtil.literal('matchlist'),
})

MatchGroupUtil.types.Bracket = TypeUtil.struct({
	bracketDatasById = TypeUtil.table('string', MatchGroupUtil.types.BracketData),
	coordinatesByMatchId = TypeUtil.table('string', MatchGroupUtil.types.MatchCoordinates),
	matches = TypeUtil.array(MatchGroupUtil.types.Match),
	matchesById = TypeUtil.table('string', MatchGroupUtil.types.Match),
	rootMatchIds = TypeUtil.array('string'),
	rounds = TypeUtil.array(TypeUtil.array('string')),
	sections = TypeUtil.array(TypeUtil.array('string')),
	type = TypeUtil.literal('bracket'),
})

MatchGroupUtil.types.MatchGroup = TypeUtil.union(
	MatchGroupUtil.types.Matchlist,
	MatchGroupUtil.types.Bracket
)

--[[
Fetches all matches in a matchlist or bracket. Tries to read from page
variables before fetching from LPDB. Returns a list of records
ordered lexicographically by matchId.
]]
MatchGroupUtil.fetchMatchRecords = FnUtil.memoize(function(bracketId)
	local varData = Variables.varDefault('match2bracket_' .. bracketId)
	if varData then
		return Json.parse(varData)
	else
		local matchRecords = mw.ext.LiquipediaDB.lpdb(
			'match2',
			{
				conditions = '([[namespace::0]] or [[namespace::>0]]) AND [[match2bracketid::' .. bracketId .. ']]',
				order = 'match2id ASC',
				limit = 5000,
			}
		)
		for _, matchRecord in ipairs(matchRecords) do
			MatchGroupWorkaround.applyPlayerBugWorkaround(matchRecord)
		end
		return matchRecords
	end
end)

function MatchGroupUtil.fetchMatchGroup(matchGroupId, type)
	local matchRecords = MatchGroupUtil.fetchMatchRecords(matchGroupId)
	type = type
		or matchRecords[1] and matchRecords[1].match2bracketdata.type
		or 'matchlist'

	return type == 'bracket'
		and MatchGroupUtil.fetchBracket(matchGroupId)
		or MatchGroupUtil.fetchMatchlist(matchGroupId)
end

MatchGroupUtil.fetchMatchlist = FnUtil.memoize(function(matchlistId)
	local matchRecords = MatchGroupUtil.fetchMatchRecords(matchlistId)
	return MatchGroupUtil.makeMatchlistFromRecords(matchRecords)
end)

MatchGroupUtil.fetchBracket = FnUtil.memoize(function(bracketId)
	local matchRecords = MatchGroupUtil.fetchMatchRecords(bracketId)
	return MatchGroupUtil.makeBracketFromRecords(matchRecords)
end)

--[[
Creates a match group structure from its match records. Returns a value of type
MatchGroupUtil.types.MatchGroup.
]]
function MatchGroupUtil.makeMatchGroup(matchRecords)
	local type = matchRecords[1] and matchRecords[1].match2bracketdata.type or 'matchlist'
	if type == 'bracket' then
		return MatchGroupUtil.makeBracketFromRecords(matchRecords)
	else
		return MatchGroupUtil.makeMatchlistFromRecords(matchRecords)
	end
end

function MatchGroupUtil.makeMatchlistFromRecords(matchRecords)
	matchRecords = MatchGroupUtil.coerceMatchRecordsToType(matchRecords, 'matchlist')
	local matches = Array.map(matchRecords, WikiSpecific.matchFromRecord)

	return {
		matches = matches,
		matchesById = Table.map(matches, function(_, match) return match.matchId, match end),
		type = 'matchlist',
	}
end

function MatchGroupUtil.makeBracketFromRecords(matchRecords)
	matchRecords = MatchGroupUtil.coerceMatchRecordsToType(matchRecords, 'bracket')
	local matches = Array.map(matchRecords, WikiSpecific.matchFromRecord)

	local matchesById = Table.map(matches, function(_, match) return match.matchId, match end)
	local bracketDatasById = Table.mapValues(matchesById, function(match) return match.bracketData end)

	local firstCoordinates = matches[1] and matches[1].bracketData.coordinates
	if not firstCoordinates then
		MatchGroupUtil.backfillParentMatchIds(bracketDatasById)
	end

	local bracket = {
		bracketDatasById = bracketDatasById,
		coordinatesByMatchId = Table.mapValues(matchesById, function(match) return match.bracketData.coordinates end),
		matches = matches,
		matchesById = matchesById,
		rootMatchIds = MatchGroupUtil.computeRootMatchIds(bracketDatasById),
		type = 'bracket',
	}

	if firstCoordinates then
		Table.mergeInto(bracket, {
			rounds = MatchGroupCoordinates.getRoundsFromCoordinates(bracket),
			sections = MatchGroupCoordinates.getSectionsFromCoordinates(bracket),
		})
	else
		MatchGroupUtil.backfillCoordinates(bracket)
	end

	MatchGroupUtil.populateAdvanceSpots(bracket)

	return bracket
end

--[[
Converts bracket match records to/from matchlist match records. The two types
of match records are basically identical, so all this does is rename header
fields.
]]
function MatchGroupUtil.coerceMatchRecordsToType(matchRecords, type)
	return Array.map(matchRecords, function(matchRecord, index)
		if matchRecord.match2bracketdata.type ~= type then
			local bracketData = matchRecord.match2bracketdata

			local header
			if index == 1 and type == 'bracket' then
				header = bracketData.header or bracketData.title or 'Matches'
			end

			return Table.merge(matchRecord, {
				match2bracketdata = Table.merge(bracketData, {
					type = type,
					header = header,
				}),
			})
		else
			return matchRecord
		end
	end)
end

--[[
Returns an array of all the IDs of root matches. The matches are sorted in
display order.
]]
function MatchGroupUtil.computeRootMatchIds(bracketDatasById)
	-- Matches without parent matches
	local rootMatchIds = {}
	for matchId, bracketData in pairs(bracketDatasById) do
		if not bracketData.parentMatchId
			and not StringUtils.endsWith(matchId, 'RxMBR') then
			table.insert(rootMatchIds, matchId)
		end
	end

	Array.sortInPlaceBy(rootMatchIds, function(matchId)
		local coordinates = bracketDatasById[matchId].coordinates
		return coordinates and {coordinates.rootIndex} or {-1, matchId}
	end)

	return rootMatchIds
end

--[[
Populate bracketData.parentMatchId if it is missing. This can happen if the
bracket template is missing data.
]]
function MatchGroupUtil.backfillParentMatchIds(bracketDatasById)
	local parentMatchIds = MatchGroupCoordinates.computeParentMatchIds(bracketDatasById)

	for matchId, bracketData in pairs(bracketDatasById) do
		bracketData.parentMatchId = parentMatchIds[matchId]
	end
end

--[[
Populate bracketData.coordinates if it is missing. This can happen if the
bracket template has not been recently purged.
]]
function MatchGroupUtil.backfillCoordinates(matchGroup)
	local bracketCoordinates = MatchGroupCoordinates.computeCoordinates(matchGroup)

	Table.mergeInto(matchGroup, bracketCoordinates)
	for matchId, bracketData in pairs(matchGroup.bracketDatasById) do
		bracketData.coordinates = bracketCoordinates.coordinatesByMatchId[matchId]
	end
end

--[[
Returns a match struct for use in a bracket display or match summary popup. The
bracket display and match summary popup expects that the finals match also
include results from the bracket reset match.
]]
function MatchGroupUtil.fetchMatchForBracketDisplay(bracketId, matchId)
	local bracket = MatchGroupUtil.fetchMatchGroup(bracketId)
	local match = bracket.matchesById[matchId]

	local bracketResetMatch = match
		and match.bracketData.bracketResetMatchId
		and bracket.matchesById[match.bracketData.bracketResetMatchId]
	if bracketResetMatch then
		return MatchGroupUtil.mergeBracketResetMatch(match, bracketResetMatch)
	else
		return match
	end
end

--[[
Converts a match record to a structurally typed table with the appropriate data
types for field values. The match record is either a match created in the store
bracket codepath (WikiSpecific.processMatch), or a record fetched from LPDB
(MatchGroupUtil.fetchMatchRecords). The returned match struct is used in
various display components (Bracket, MatchSummary, etc)

This is the implementation used on wikis by default. Wikis may specify a
different conversion by setting WikiSpecific.matchFromRecord. Refer
to the starcraft2 wiki as an example.
]]
function MatchGroupUtil.matchFromRecord(record)
	local extradata = MatchGroupUtil.parseOrCopyExtradata(record.extradata)
	local opponents = Array.map(record.match2opponents, MatchGroupUtil.opponentFromRecord)
	local bracketData = MatchGroupUtil.bracketDataFromRecord(Json.parseIfString(record.match2bracketdata))
	if bracketData.type == 'bracket' then
		bracketData.childEdges = bracketData.childEdges
			or MatchGroupUtil.autoAssignChildEdges(#bracketData.childMatchIds, #opponents)
	end

	return {
		bracketData = bracketData,
		comment = nilIfEmpty(Table.extract(extradata, 'comment')),
		extradata = extradata,
		date = record.date,
		dateIsExact = Logic.readBool(record.dateexact),
		finished = Logic.readBool(record.finished),
		games = Array.map(record.match2games, MatchGroupUtil.gameFromRecord),
		links = Json.parseIfString(record.links) or {},
		matchId = record.match2id,
		mode = record.mode,
		opponents = opponents,
		resultType = nilIfEmpty(record.resulttype),
		stream = Json.parseIfString(record.stream) or {},
		type = nilIfEmpty(record.type) or 'literal',
		vod = nilIfEmpty(record.vod),
		walkover = nilIfEmpty(record.walkover),
		winner = tonumber(record.winner),
	}
end

function MatchGroupUtil.bracketDataFromRecord(data)
	if data.type == 'bracket' then
		local advanceSpots = data.advanceSpots or MatchGroupUtil.computeAdvanceSpots(data)
		return {
			advanceSpots = advanceSpots,
			bracketResetMatchId = nilIfEmpty(data.bracketreset),
			coordinates = data.coordinates and MatchGroupUtil.indexTableFromRecord(data.coordinates),
			header = nilIfEmpty(data.header),
			childEdges = data.childEdges and Array.map(data.childEdges, MatchGroupUtil.indexTableFromRecord),
			childMatchIds = data.childMatchIds or MatchGroupUtil.computeChildMatchIdsFromLegacy(data),
			qualLose = advanceSpots[2] and advanceSpots[2].type == 'qualify',
			qualLoseLiteral = nilIfEmpty(data.qualloseLiteral),
			qualSkip = tonumber(data.qualskip) or data.qualskip == 'true' and 1 or 0,
			qualWin = advanceSpots[1] and advanceSpots[1].type == 'qualify',
			qualWinLiteral = nilIfEmpty(data.qualwinLiteral),
			skipRound = tonumber(data.skipround) or data.skipround == 'true' and 1 or 0,
			thirdPlaceMatchId = nilIfEmpty(data.thirdplace),
			type = 'bracket',
			parentMatchId = nilIfEmpty(data.parentMatchId),
		}
	else
		return {
			header = nilIfEmpty(data.header),
			title = nilIfEmpty(data.title),
			type = 'matchlist',
		}
	end
end

function MatchGroupUtil.bracketDataToRecord(bracketData)
	local coordinates = bracketData.coordinates
	return {
		bracketreset = bracketData.bracketResetMatchId,
		coordinates = coordinates and MatchGroupUtil.indexTableToRecord(coordinates),
		header = bracketData.header,
		childEdges = bracketData.childEdges and Array.map(bracketData.childEdges, MatchGroupUtil.indexTableToRecord),
		childMatchIds = bracketData.childMatchIds,
		qualWinLiteral = bracketData.qualwinLiteral,
		quallose = bracketData.qualLose and 'true' or nil,
		qualloseLiteral = bracketData.qualLoseLiteral,
		qualskip = bracketData.qualSkip ~= 0 and bracketData.qualSkip or nil,
		qualwin = bracketData.qualWin and 'true' or nil,
		skipround = bracketData.skipRound ~= 0 and bracketData.skipRound or nil,
		thirdplace = bracketData.thirdPlaceMatchId,
		type = bracketData.type,
		parentMatchId = bracketData.parentMatchId,

		-- Deprecated
		bracketsection = coordinates
			and MatchGroupUtil.sectionIndexToString(coordinates.sectionIndex, coordinates.sectionCount),
		tolower = bracketData.childMatchIds[#bracketData.childMatchIds],
		toupper = bracketData.childMatchIds[#bracketData.childMatchIds - 1],
	}
end

function MatchGroupUtil.opponentFromRecord(record)
	local extradata = MatchGroupUtil.parseOrCopyExtradata(record.extradata)
	return {
		advanceBg = nilIfEmpty(Table.extract(extradata, 'bg')),
		advances = Logic.readBoolOrNil(Table.extract(extradata, 'advances')),
		extradata = extradata,
		icon = nilIfEmpty(record.icon),
		name = nilIfEmpty(record.name),
		placement = tonumber(record.placement),
		players = Array.map(record.match2players, MatchGroupUtil.playerFromRecord),
		score = tonumber(record.score),
		status = record.status,
		template = nilIfEmpty(record.template),
		type = nilIfEmpty(record.type) or 'literal',
	}
end

function MatchGroupUtil.createOpponent(args)
	return {
		extradata = args.extradata or {},
		icon = args.icon,
		name = args.name,
		placement = args.placement,
		players = args.players or {},
		score = args.score,
		status = args.status,
		template = args.template,
		type = args.type or 'literal',
	}
end

function MatchGroupUtil.playerFromRecord(record)
	local extradata = MatchGroupUtil.parseOrCopyExtradata(record.extradata)
	return {
		displayName = record.displayname,
		extradata = extradata,
		flag = nilIfEmpty(record.flag),
		pageName = record.name,
	}
end

function MatchGroupUtil.gameFromRecord(record)
	local extradata = MatchGroupUtil.parseOrCopyExtradata(record.extradata)
	return {
		comment = nilIfEmpty(Table.extract(extradata, 'comment')),
		extradata = extradata,
		header = nilIfEmpty(Table.extract(extradata, 'header')),
		length = record.length,
		map = nilIfEmpty(record.map),
		mode = nilIfEmpty(record.mode),
		participants = Json.parseIfString(record.participants) or {},
		resultType = nilIfEmpty(record.resulttype),
		scores = Json.parseIfString(record.scores) or {},
		subgroup = tonumber(record.subgroup),
		type = nilIfEmpty(record.type),
		vod = nilIfEmpty(record.vod),
		walkover = nilIfEmpty(record.walkover),
		winner = tonumber(record.winner),
	}
end

function MatchGroupUtil.computeChildMatchIdsFromLegacy(data)
	local childMatchIds = {}
	if nilIfEmpty(data.toupper) then
		table.insert(childMatchIds, data.toupper)
	end
	if nilIfEmpty(data.tolower) then
		table.insert(childMatchIds, data.tolower)
	end
	return childMatchIds
end

--[[
Auto compute child edges, which encode the connector lines between child
matches and this match.
]]
function MatchGroupUtil.autoAssignChildEdges(childMatchCount, opponentCount)
	local childEdges = {}
	if childMatchCount <= opponentCount then
		-- More opponents than child matches: connect child matches to opponents near the middle.
		local skip = math.ceil((opponentCount - childMatchCount) / 2)
		for childMatchIndex = 1, childMatchCount do
			table.insert(childEdges, {
				childMatchIndex = childMatchIndex,
				opponentIndex = childMatchIndex + skip,
			})
		end
	else
		-- More child matches than opponents: The excess child matches are all connected to the final opponent.
		for childMatchIndex = 1, childMatchCount do
			table.insert(childEdges, {
				childMatchIndex = childMatchIndex,
				opponentIndex = math.min(childMatchIndex, opponentCount),
			})
		end
	end
	return childEdges
end

--[[
Computes just the advance spots that can be determined from a match bracket
data. More are found in populateAdvanceSpots.
]]
function MatchGroupUtil.computeAdvanceSpots(data)
	local advanceSpots = {}

	if data.parentMatchId then
		advanceSpots[1] = {bg = 'up', type = 'advance', matchId = data.parentMatchId}
	end

	if nilIfEmpty(data.winnerto) then
		advanceSpots[1] = {bg = 'up', type = 'custom', matchId = data.winnerto}
	end
	if nilIfEmpty(data.loserto) then
		advanceSpots[2] = {bg = 'stayup', type = 'custom', matchId = data.loserto}
	end

	if Logic.readBool(data.qualwin) then
		advanceSpots[1] = Table.merge(advanceSpots[1], {bg = 'up', type = 'qualify'})
	end
	if Logic.readBool(data.quallose) then
		advanceSpots[2] = Table.merge(advanceSpots[2], {bg = 'stayup', type = 'qualify'})
	end

	return advanceSpots
end

function MatchGroupUtil.populateAdvanceSpots(bracket)
	if #bracket.matches == 0 then
		return
	end

	-- Loser of semifinals play in third place match
	local firstBracketData = bracket.bracketDatasById[bracket.rootMatchIds[1]]
	local thirdPlaceMatchId = firstBracketData.thirdPlaceMatchId
	if thirdPlaceMatchId and bracket.matchesById[thirdPlaceMatchId] then
		for _, childMatchId in ipairs(firstBracketData.childMatchIds) do
			local bracketData = bracket.bracketDatasById[childMatchId]
			bracketData.advanceSpots[2] = bracketData.advanceSpots[2]
				or {bg = 'stayup', type = 'advance', matchId = thirdPlaceMatchId}
		end
	end

	-- Custom advance spots set via pbg params
	for _, match in ipairs(bracket.matches) do
		local pbgs = Array.mapIndexes(function(ix)
			return Table.extract(match.extradata, 'pbg' .. ix)
		end)
		for i = 1, #pbgs do
			match.bracketData.advanceSpots[i] = Table.merge(
				match.bracketData.advanceSpots[i],
				{bg = pbgs[i], type = 'custom'}
			)
		end
	end
end

-- Merges a grand finals match with results of its bracket reset match.
function MatchGroupUtil.mergeBracketResetMatch(match, bracketResetMatch)
	local mergedMatch = Table.merge(match, {
		opponents = {},
		games = Table.copy(match.games),
	})

	for ix, opponent in ipairs(match.opponents) do
		local resetOpponent = bracketResetMatch.opponents[ix]
		mergedMatch.opponents[ix] = Table.merge(opponent, {
			score2 = resetOpponent.score,
			status2 = resetOpponent.status,
			placement2 = resetOpponent.placement,
		})
	end

	for _, game in ipairs(bracketResetMatch.games) do
		table.insert(mergedMatch.games, game)
	end

	return mergedMatch
end

--[[
Fetches information about a team via mw.ext.TeamTemplate.
]]
function MatchGroupUtil.fetchTeam(template)
	--exception for TBD opponents
	if string.lower(template) == 'tbd' then
		return {
			bracketName = TBD_DISPLAY,
			displayName = TBD_DISPLAY,
			pageName = 'TBD',
			shortName = TBD_DISPLAY,
		}
	end
	local rawTeam = mw.ext.TeamTemplate.raw(template)
	if not rawTeam then
		return nil
	end

	return {
		bracketName = rawTeam.bracketname,
		displayName = rawTeam.name,
		pageName = rawTeam.page,
		shortName = rawTeam.shortname,
	}
end

--[[
Parse extradata as a JSON string if read from page variables. Otherwise create
a copy if fetched from lpdb. The returned extradata table can then be mutated
without altering the source.
]]
function MatchGroupUtil.parseOrCopyExtradata(recordExtradata)
	return type(recordExtradata) == 'string' and Json.parse(recordExtradata)
		or type(recordExtradata) == 'table' and Table.copy(recordExtradata)
		or {}
end

-- Convert 0-based indexes to 1-based
function MatchGroupUtil.indexTableFromRecord(record)
	return Table.map(record, function(key, value)
		if key:match('Index') and type(value) == 'number' then
			return key, value + 1
		else
			return key, value
		end
	end)
end

-- Convert 1-based indexes to 0-based
function MatchGroupUtil.indexTableToRecord(coordinates)
	return Table.map(coordinates, function(key, value)
		if key:match('Index') and type(value) == 'number' then
			return key, value - 1
		else
			return key, value
		end
	end)
end

-- Deprecated
function MatchGroupUtil.sectionIndexToString(sectionIndex, sectionCount)
	if sectionIndex == 1 then
		return 'upper'
	elseif sectionIndex == sectionCount then
		return 'lower'
	else
		return 'mid'
	end
end

--[[
Splits a matchId like h5HXaqbSVP_R02-M002 into the bracket ID h5HXaqbSVP and
the base match ID R02-M002.
]]
function MatchGroupUtil.splitMatchId(matchId)
	return matchId:match('^(.-)_([%w-]+)$')
end

--[[
Converts R01-M003 to R1M3 (for match in bracket), and 0005 to M5 (for match in
matchlist)
]]
function MatchGroupUtil.matchIdToKey(matchId)
	-- Matchlist format
	if tonumber(matchId) then
		return 'M' .. tonumber(matchId)
	end

	-- Bracket format
	if matchId == 'RxMBR' or matchId == 'RxMTP' then
		return matchId
	end
	local round, matchInRound = matchId:match('^R(%d+)%-M(%d+)$')
	if round and matchInRound then
		return 'R' .. tonumber(round) .. 'M' .. tonumber(matchInRound)
	end
end

--[[
Converts R1M3 to R01-M003 (for match in bracket), and M5 or 5 to 0005 (for
match in matchlist)
]]
function MatchGroupUtil.matchIdFromKey(matchKey)
	-- Matchlist format
	if type(matchKey) == 'number' then
		return string.format('%04d', matchKey)
	end
	local matchIndex = matchKey:match('^M?(%d+)$')
	if matchIndex then
		return string.format('%04d', matchIndex)
	end

	-- Bracket format
	if matchKey == 'RxMBR' or matchKey == 'RxMTP' then
		return matchKey
	end
	local round, matchInRound = matchKey:match('^R(%d+)M(%d+)$')
	if round and matchInRound then
		return 'R' .. string.format('%02d', round) .. '-M' .. string.format('%03d', matchInRound)
	end
end

return MatchGroupUtil
