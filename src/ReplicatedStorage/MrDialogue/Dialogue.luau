--!strict

local Types = require(script.Parent.Types)
local SessionClass = require(script.Parent.Session)

local Dialogue = {}
Dialogue.__index = Dialogue

local SUPPORTED_NODE_TYPES: { [string]: boolean } = {
	line = true,
	choice = true,
	branch = true,
	action = true,
	["end"] = true,
}

table.freeze(SUPPORTED_NODE_TYPES)

export type Dialogue = {
	Id: string,
	Start: (
		self: Dialogue,
		player: Player,
		options: Types.SessionOptions?
	) -> (SessionClass.Session?, string?),
}

type DialogueInternal = Dialogue & {
	_definition: Types.DialogueDefinition,
}

local function assertNonEmptyString(value: any, field: string)
	if type(value) ~= "string" or value == "" then
		error(`MrDialogue.new: {field} must be a non-empty string`, 4)
	end
end

local function deepCopy(value: any, copies: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end

	local existingCopy = copies[value]
	if existingCopy then
		return existingCopy
	end

	local copy = {}
	copies[value] = copy

	for key, nestedValue in pairs(value) do
		copy[key] = deepCopy(nestedValue, copies)
	end

	return table.freeze(copy)
end

local function validateLine(nodeId: string, node: any, definition: any)
	if type(node.text) ~= "string" then
		error(`MrDialogue.new: line node "{nodeId}" text must be a string`, 4)
	end

	if
		node.speaker ~= nil
		and node.speaker ~= false
		and (type(node.speaker) ~= "string" or node.speaker == "")
	then
		error(`MrDialogue.new: line node "{nodeId}" speaker must be a non-empty string or false`, 4)
	end

	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if speakerId == nil or speakerId == false then
		if node.emotion ~= nil then
			error(`MrDialogue.new: line node "{nodeId}" cannot use an emotion without a speaker`, 4)
		end
		return
	end

	if type(speakerId) ~= "string" or speakerId == "" then
		error(`MrDialogue.new: line node "{nodeId}" speaker must be a non-empty string or false`, 4)
	end

	local speakers = definition.speakers
	local speaker = if type(speakers) == "table" then speakers[speakerId] else nil
	if type(speaker) ~= "table" then
		error(`MrDialogue.new: line node "{nodeId}" references unknown speaker "{speakerId}"`, 4)
	end

	if type(speaker.name) ~= "string" or speaker.name == "" then
		error(`MrDialogue.new: speaker "{speakerId}" must have a non-empty name`, 4)
	end

	if node.emotion ~= nil then
		if type(node.emotion) ~= "string" or node.emotion == "" then
			error(`MrDialogue.new: line node "{nodeId}" emotion must be a non-empty string`, 4)
		end

		local emotions = speaker.emotions
		local emotionIcon = if type(emotions) == "table" then emotions[node.emotion] else nil
		if type(emotionIcon) ~= "string" or emotionIcon == "" then
			error(
				`MrDialogue.new: line node "{nodeId}" references unknown emotion "{node.emotion}"`,
				4
			)
		end
	elseif speaker.icon ~= nil then
		if type(speaker.icon) ~= "string" or speaker.icon == "" then
			error(`MrDialogue.new: speaker "{speakerId}" icon must be a non-empty string`, 4)
		end
	elseif
		definition.defaultIcon ~= nil
		and (type(definition.defaultIcon) ~= "string" or definition.defaultIcon == "")
	then
		error("MrDialogue.new: definition.defaultIcon must be a non-empty string", 4)
	end
end

function Dialogue.new(definition: any): Dialogue
	if type(definition) ~= "table" then
		error("MrDialogue.new: definition must be a table", 3)
	end

	if definition.format ~= 1 then
		error("MrDialogue.new: definition.format must be 1", 3)
	end

	assertNonEmptyString(definition.id, "definition.id")
	assertNonEmptyString(definition.entry, "definition.entry")

	if type(definition.nodes) ~= "table" then
		error("MrDialogue.new: definition.nodes must be a table", 3)
	end

	for nodeId, node in pairs(definition.nodes) do
		if type(nodeId) ~= "string" or nodeId == "" then
			error("MrDialogue.new: node IDs must be non-empty strings", 3)
		end

		if type(node) ~= "table" then
			error(`MrDialogue.new: node "{nodeId}" must be a table`, 3)
		end

		if type(node.type) ~= "string" or not SUPPORTED_NODE_TYPES[node.type] then
			error(`MrDialogue.new: node "{nodeId}" has an unsupported type`, 3)
		end

		if node.type == "line" then
			validateLine(nodeId, node, definition)
		end
	end

	if type(definition.nodes[definition.entry]) ~= "table" then
		error(`MrDialogue.new: entry node "{definition.entry}" does not exist`, 3)
	end

	local copiedDefinition = deepCopy(definition, {}) :: Types.DialogueDefinition
	local self: DialogueInternal = setmetatable({
		Id = copiedDefinition.id,
		_definition = copiedDefinition,
	}, Dialogue) :: any

	return table.freeze(self)
end

function Dialogue.Start(
	self: DialogueInternal,
	player: Player,
	options: Types.SessionOptions?
): (SessionClass.Session?, string?)
	return SessionClass.new(player, self.Id, self._definition, options)
end

return table.freeze(Dialogue)
