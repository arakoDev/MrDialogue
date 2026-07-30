--!strict

local Types = require(script.Parent.Types)
local Actions = require(script.Parent.Actions)
local Conditions = require(script.Parent.Conditions)
local Net = require(script.Parent.Net)
local SessionClass = require(script.Parent.Session)

local Dialogue = {}
Dialogue.__index = Dialogue

export type Dialogue = Types.Dialogue

type Requirement = {
	kind: "condition" | "action",
	name: string,
	path: string,
}

type DialogueInternal = Dialogue & {
	_definition: Types.DialogueDefinition,
	_requirements: { Requirement },
}

local NODE_TYPES: { [string]: boolean } = {
	line = true,
	choice = true,
	branch = true,
	action = true,
	["end"] = true,
}

table.freeze(NODE_TYPES)

local function fail(message: string): never
	error(`MrDialogue.new: {message}`, 0)
end

local function validateMaximumBytes(value: string, maximumBytes: number, path: string)
	if utf8.len(value) == nil then
		fail(`{path} must contain valid UTF-8`)
	end
	if #value > maximumBytes then
		fail(`{path} must not exceed {maximumBytes} bytes`)
	end
end

local function validateArray(value: any, path: string, maximumEntries: number?): number
	if type(value) ~= "table" then
		fail(`{path} must be an array`)
	end

	local count = 0
	local highestIndex = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			fail(`{path} must be an array`)
		end

		count += 1
		highestIndex = math.max(highestIndex, key)
	end

	if count ~= highestIndex then
		fail(`{path} must be a dense array without missing entries`)
	end
	if maximumEntries and count > maximumEntries then
		fail(`{path} must not contain more than {maximumEntries} entries`)
	end

	return count
end

local function deepCopy(value: any, copies: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end

	local existing = copies[value]
	if existing then
		return existing
	end

	local copy = {}
	copies[value] = copy
	for key, nested in pairs(value) do
		copy[key] = deepCopy(nested, copies)
	end

	return table.freeze(copy)
end

local function validateSpec(kind: "condition" | "action", spec: any, path: string): Requirement
	if type(spec) ~= "table" then
		fail(`{path} must be a table`)
	end
	if type(spec.name) ~= "string" or spec.name == "" then
		fail(`{path}.name must be a non-empty string`)
	end
	validateMaximumBytes(spec.name, Net.Limits.maxIdBytes, `{path}.name`)
	if spec.arguments ~= nil then
		validateArray(spec.arguments, `{path}.arguments`, Net.Limits.maxArguments)
	end

	return table.freeze({ kind = kind, name = spec.name, path = path }) :: any
end

local function validateTarget(definition: any, targetId: any, path: string)
	if type(targetId) ~= "string" or targetId == "" then
		fail(`{path} must be a node ID`)
	end
	validateMaximumBytes(targetId, Net.Limits.maxIdBytes, path)
	if definition.nodes[targetId] == nil then
		fail(`{path} points at "{targetId}", which does not exist`)
	end
end

local function validateSpeakers(definition: any)
	local speakers: { [any]: unknown }? = nil
	local speakersValue = definition.speakers

	if speakersValue ~= nil then
		if type(speakersValue) ~= "table" then
			fail("definition.speakers must be a table")
		end

		speakers = speakersValue :: { [any]: unknown }
	end

	for speakerId, speakerValue in pairs(speakers or {}) do
		if type(speakerId) ~= "string" or speakerId == "" then
			fail("definition.speakers keys must be non-empty strings")
		end
		validateMaximumBytes(speakerId, Net.Limits.maxIdBytes, "definition.speakers key")

		local path = `speaker "{tostring(speakerId)}"`

		if type(speakerValue) ~= "table" then
			fail(`{path} must be a table with a non-empty name`)
		end

		local speaker = speakerValue :: { [string]: unknown }

		local name = speaker.name
		if type(name) ~= "string" or name == "" then
			fail(`{path} must be a table with a non-empty name`)
		end
		validateMaximumBytes(name :: string, Net.Limits.maxSpeakerNameBytes, `{path} name`)

		local icon = speaker.icon
		if icon ~= nil and type(icon) ~= "string" then
			fail(`{path} icon must be a string`)
		end
		if icon ~= nil then
			validateMaximumBytes(icon :: string, Net.Limits.maxIconBytes, `{path} icon`)
		end

		local emotionsValue = speaker.emotions
		if emotionsValue ~= nil then
			if type(emotionsValue) ~= "table" then
				fail(`{path} emotions must be a table`)
			end

			local emotions = emotionsValue :: { [any]: unknown }

			for emotion, emotionIcon in pairs(emotions) do
				if type(emotion) ~= "string" or emotion == "" then
					fail(`{path} emotion keys must be non-empty strings`)
				end
				validateMaximumBytes(emotion, Net.Limits.maxIdBytes, `{path} emotion key`)
				if type(emotionIcon) ~= "string" then
					fail(`{path} emotion "{tostring(emotion)}" must map to an icon string`)
				end
				validateMaximumBytes(
					emotionIcon :: string,
					Net.Limits.maxIconBytes,
					`{path} emotion "{tostring(emotion)}"`
				)
			end
		end
	end

	local defaultSpeaker = definition.defaultSpeaker
	if defaultSpeaker ~= nil then
		if type(defaultSpeaker) ~= "string" or defaultSpeaker == "" then
			fail("definition.defaultSpeaker must be a non-empty speaker key")
		end
		validateMaximumBytes(defaultSpeaker, Net.Limits.maxIdBytes, "definition.defaultSpeaker")
		if speakers == nil or speakers[defaultSpeaker] == nil then
			fail(`definition.defaultSpeaker references unknown speaker "{defaultSpeaker}"`)
		end
	end
end

local function validatePresentation(nodeId: string, node: any, definition: any)
	if node.emotion ~= nil and (type(node.emotion) ~= "string" or node.emotion == "") then
		fail(`node "{nodeId}" emotion must be a non-empty emotion key`)
	end
	if node.emotion ~= nil then
		validateMaximumBytes(node.emotion, Net.Limits.maxIdBytes, `node "{nodeId}" emotion`)
	end

	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if speakerId == nil or speakerId == false then
		if node.emotion ~= nil then
			fail(`node "{nodeId}" cannot use an emotion without a speaker`)
		end
		return
	end

	if type(speakerId) ~= "string" then
		fail(`node "{nodeId}" speaker must be a speaker key or false`)
	end
	validateMaximumBytes(speakerId, Net.Limits.maxIdBytes, `node "{nodeId}" speaker`)

	local speakers = definition.speakers
	local speaker = if speakers then speakers[speakerId] else nil
	if speaker == nil then
		fail(`node "{nodeId}" references unknown speaker "{speakerId}"`)
	end

	if node.emotion == nil then
		return
	end

	local emotions = speaker.emotions
	if type(emotions) ~= "table" or emotions[node.emotion] == nil then
		fail(`node "{nodeId}" references unknown emotion "{tostring(node.emotion)}"`)
	end
end

local function validateLine(nodeId: string, node: any, definition: any)
	if type(node.text) ~= "string" then
		fail(`line node "{nodeId}" text must be a string`)
	end
	validateMaximumBytes(node.text, Net.Limits.maxTextBytes, `line node "{nodeId}" text`)

	validatePresentation(nodeId, node, definition)

	if node.next ~= nil then
		validateTarget(definition, node.next, `line node "{nodeId}" next`)
	end
end

local function validateChoice(
	nodeId: string,
	node: any,
	definition: any,
	requirements: { Requirement }
)
	if node.text ~= nil then
		if type(node.text) ~= "string" then
			fail(`choice node "{nodeId}" text must be a string`)
		end
		validateMaximumBytes(node.text, Net.Limits.maxTextBytes, `choice node "{nodeId}" text`)
		validatePresentation(nodeId, node, definition)
	elseif node.speaker ~= nil or node.emotion ~= nil then
		fail(`promptless choice node "{nodeId}" cannot set a speaker or emotion`)
	end

	if
		validateArray(node.options, `choice node "{nodeId}" options`, Net.Limits.maxChoices) == 0
	then
		fail(`choice node "{nodeId}" must contain at least one option`)
	end

	local usedIds = {}
	for index, option in ipairs(node.options) do
		local path = `choice node "{nodeId}" option {index}`
		if type(option) ~= "table" then
			fail(`{path} must be a table`)
		end
		if type(option.id) ~= "string" or option.id == "" then
			fail(`{path} must have a non-empty id`)
		end
		validateMaximumBytes(option.id, Net.Limits.maxIdBytes, `{path} id`)
		if usedIds[option.id] then
			fail(`{path} reuses the id "{option.id}"`)
		end
		usedIds[option.id] = true

		if type(option.text) ~= "string" then
			fail(`{path} text must be a string`)
		end
		validateMaximumBytes(option.text, Net.Limits.maxTextBytes, `{path} text`)
		validateTarget(definition, option.next, `{path} next`)

		if option.condition ~= nil then
			table.insert(
				requirements,
				validateSpec("condition", option.condition, `{path} condition`)
			)
		end
	end

	if node.fallback ~= nil then
		validateTarget(definition, node.fallback, `choice node "{nodeId}" fallback`)
	end
end

local function validateBranch(
	nodeId: string,
	node: any,
	definition: any,
	requirements: { Requirement }
)
	table.insert(
		requirements,
		validateSpec("condition", node.condition, `branch node "{nodeId}" condition`)
	)
	validateTarget(definition, node.onTrue, `branch node "{nodeId}" onTrue`)
	validateTarget(definition, node.onFalse, `branch node "{nodeId}" onFalse`)
end

local function validateAction(
	nodeId: string,
	node: any,
	definition: any,
	requirements: { Requirement }
)
	table.insert(requirements, validateSpec("action", node.action, `action node "{nodeId}" action`))

	if node.next ~= nil then
		validateTarget(definition, node.next, `action node "{nodeId}" next`)
	end
end

function Dialogue.new(definition: any): Dialogue
	if type(definition) ~= "table" then
		fail("definition must be a table")
	end
	if definition.format ~= 1 then
		fail("definition.format must be 1")
	end
	if type(definition.id) ~= "string" or definition.id == "" then
		fail("definition.id must be a non-empty string")
	end
	validateMaximumBytes(definition.id, Net.Limits.maxIdBytes, "definition.id")
	if type(definition.nodes) ~= "table" then
		fail("definition.nodes must be a table")
	end
	if definition.defaultIcon ~= nil and type(definition.defaultIcon) ~= "string" then
		fail("definition.defaultIcon must be a string")
	end
	if definition.defaultIcon ~= nil then
		validateMaximumBytes(
			definition.defaultIcon,
			Net.Limits.maxIconBytes,
			"definition.defaultIcon"
		)
	end
	if definition.freezeCharacter ~= nil and type(definition.freezeCharacter) ~= "boolean" then
		fail("definition.freezeCharacter must be a boolean")
	end
	if
		definition.endDialogueOnDeath ~= nil
		and type(definition.endDialogueOnDeath) ~= "boolean"
	then
		fail("definition.endDialogueOnDeath must be a boolean")
	end

	validateSpeakers(definition)

	local requirements: { Requirement } = {}
	local nodeCount = 0
	for nodeId, node in pairs(definition.nodes) do
		nodeCount += 1
		if nodeCount > Net.Limits.maxNodes then
			fail(`definition.nodes must not contain more than {Net.Limits.maxNodes} nodes`)
		end
		if type(nodeId) ~= "string" or nodeId == "" then
			fail("node IDs must be non-empty strings")
		end
		validateMaximumBytes(nodeId, Net.Limits.maxIdBytes, "node ID")
		if type(node) ~= "table" or not NODE_TYPES[node.type] then
			fail(`node "{nodeId}" must be a line, choice, branch, action, or end node`)
		end

		if node.type == "line" then
			validateLine(nodeId, node, definition)
		elseif node.type == "choice" then
			validateChoice(nodeId, node, definition, requirements)
		elseif node.type == "branch" then
			validateBranch(nodeId, node, definition, requirements)
		elseif node.type == "action" then
			validateAction(nodeId, node, definition, requirements)
		elseif node.type == "end" then
			if node.result ~= nil and type(node.result) ~= "string" then
				fail(`end node "{nodeId}" result must be a string`)
			end
			if node.result ~= nil then
				validateMaximumBytes(
					node.result,
					Net.Limits.maxResultBytes,
					`end node "{nodeId}" result`
				)
			end
		end
	end

	validateTarget(definition, definition.entry, "definition.entry")

	local self: DialogueInternal = setmetatable({
		Id = definition.id,
		_definition = deepCopy(definition, {}),
		_requirements = table.freeze(requirements),
	}, Dialogue) :: any

	return table.freeze(self)
end

function Dialogue.Start(
	self: DialogueInternal,
	player: Player,
	options: Types.SessionOptions?
): (SessionClass.Session?, string?)
	SessionClass._validateStartArguments(player, options)

	for _, requirement in ipairs(self._requirements) do
		local registered = if requirement.kind == "condition"
			then Conditions._isRegistered(requirement.name)
			else Actions._isRegistered(requirement.name)

		if not registered then
			return nil, `{requirement.path} "{requirement.name}" is not registered`
		end
	end

	return SessionClass.new(player, self.Id, self._definition, options)
end

return table.freeze(Dialogue)
