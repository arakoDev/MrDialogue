--!strict

local Types = require(script.Parent.Types)
local Actions = require(script.Parent.Actions)
local Conditions = require(script.Parent.Conditions)
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

type DialogueInternal = Dialogue & { _definition: Types.DialogueDefinition }

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

local function validateConditionSpec(spec: any, path: string)
	if type(spec) ~= "table" then
		error(`MrDialogue.new: {path} must be a condition table`, 4)
	end
	if type(spec.name) ~= "string" or spec.name == "" then
		error(`MrDialogue.new: {path}.name must be a non-empty string`, 4)
	end

	local arguments = spec.arguments
	if arguments == nil then
		return
	end
	if type(arguments) ~= "table" then
		error(`MrDialogue.new: {path}.arguments must be an array`, 4)
	end

	local argumentCount = 0
	for index in pairs(arguments) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
			error(`MrDialogue.new: {path}.arguments must be a dense array`, 4)
		end
		argumentCount += 1
	end
	for index = 1, argumentCount do
		if arguments[index] == nil then
			error(`MrDialogue.new: {path}.arguments must be a dense array`, 4)
		end
	end
end

local function validateActionSpec(spec: any, path: string)
	if type(spec) ~= "table" then
		error(`MrDialogue.new: {path} must be an action table`, 4)
	end
	if type(spec.name) ~= "string" or spec.name == "" then
		error(`MrDialogue.new: {path}.name must be a non-empty string`, 4)
	end

	local arguments = spec.arguments
	if arguments == nil then
		return
	end
	if type(arguments) ~= "table" then
		error(`MrDialogue.new: {path}.arguments must be an array`, 4)
	end

	local argumentCount = 0
	for index in pairs(arguments) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
			error(`MrDialogue.new: {path}.arguments must be a dense array`, 4)
		end
		argumentCount += 1
	end
	for index = 1, argumentCount do
		if arguments[index] == nil then
			error(`MrDialogue.new: {path}.arguments must be a dense array`, 4)
		end
	end
end

local function validatePresentation(nodeKind: string, nodeId: string, node: any, definition: any)
	if
		node.speaker ~= nil
		and node.speaker ~= false
		and (type(node.speaker) ~= "string" or node.speaker == "")
	then
		error(
			`MrDialogue.new: {nodeKind} node "{nodeId}" speaker must be a non-empty string or false`,
			4
		)
	end

	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if speakerId == nil or speakerId == false then
		if node.emotion ~= nil then
			error(
				`MrDialogue.new: {nodeKind} node "{nodeId}" cannot use an emotion without a speaker`,
				4
			)
		end
		return
	end

	if type(speakerId) ~= "string" or speakerId == "" then
		error(
			`MrDialogue.new: {nodeKind} node "{nodeId}" speaker must be a non-empty string or false`,
			4
		)
	end

	local speakers = definition.speakers
	local speaker = if type(speakers) == "table" then speakers[speakerId] else nil
	if type(speaker) ~= "table" then
		error(
			`MrDialogue.new: {nodeKind} node "{nodeId}" references unknown speaker "{speakerId}"`,
			4
		)
	end

	if type(speaker.name) ~= "string" or speaker.name == "" then
		error(`MrDialogue.new: speaker "{speakerId}" must have a non-empty name`, 4)
	end

	if node.emotion ~= nil then
		if type(node.emotion) ~= "string" or node.emotion == "" then
			error(
				`MrDialogue.new: {nodeKind} node "{nodeId}" emotion must be a non-empty string`,
				4
			)
		end

		local emotions = speaker.emotions
		local emotionIcon = if type(emotions) == "table" then emotions[node.emotion] else nil
		if type(emotionIcon) ~= "string" then
			error(
				`MrDialogue.new: {nodeKind} node "{nodeId}" references unknown emotion "{node.emotion}"`,
				4
			)
		end
	elseif speaker.icon ~= nil then
		if type(speaker.icon) ~= "string" then
			error(`MrDialogue.new: speaker "{speakerId}" icon must be a string`, 4)
		end
	elseif definition.defaultIcon ~= nil and type(definition.defaultIcon) ~= "string" then
		error("MrDialogue.new: definition.defaultIcon must be a string", 4)
	end
end

local function validateLine(nodeId: string, node: any, definition: any)
	if type(node.text) ~= "string" then
		error(`MrDialogue.new: line node "{nodeId}" text must be a string`, 4)
	end

	validatePresentation("line", nodeId, node, definition)

	if node.next ~= nil then
		if type(node.next) ~= "string" or node.next == "" then
			error(`MrDialogue.new: line node "{nodeId}" next must be a non-empty string`, 4)
		end

		local target = definition.nodes[node.next]
		if type(target) ~= "table" then
			error(`MrDialogue.new: line node "{nodeId}" target "{node.next}" does not exist`, 4)
		end
		if
			target.type ~= "line"
			and target.type ~= "choice"
			and target.type ~= "branch"
			and target.type ~= "action"
			and target.type ~= "end"
		then
			error(
				`MrDialogue.new: line node "{nodeId}" target must be a line, choice, branch, action, or end`,
				4
			)
		end
	end
end

local function validateChoice(nodeId: string, node: any, definition: any)
	if node.text ~= nil then
		if type(node.text) ~= "string" then
			error(`MrDialogue.new: choice node "{nodeId}" text must be a string`, 4)
		end
		validatePresentation("choice", nodeId, node, definition)
	elseif node.speaker ~= nil or node.emotion ~= nil then
		error(`MrDialogue.new: promptless choice node "{nodeId}" cannot set speaker or emotion`, 4)
	end

	if type(node.options) ~= "table" then
		error(`MrDialogue.new: choice node "{nodeId}" options must be an array`, 4)
	end

	local optionCount = 0
	for index in pairs(node.options) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
			error(`MrDialogue.new: choice node "{nodeId}" options must be a dense array`, 4)
		end
		optionCount += 1
	end

	if optionCount == 0 then
		error(`MrDialogue.new: choice node "{nodeId}" must contain at least one option`, 4)
	end

	local optionIds = {}
	for index = 1, optionCount do
		local option = node.options[index]
		if type(option) ~= "table" then
			error(`MrDialogue.new: choice node "{nodeId}" options must be a dense array`, 4)
		end

		if type(option.id) ~= "string" or option.id == "" then
			error(`MrDialogue.new: choice node "{nodeId}" option {index} must have an ID`, 4)
		end
		if optionIds[option.id] then
			error(`MrDialogue.new: choice node "{nodeId}" has duplicate option ID "{option.id}"`, 4)
		end
		optionIds[option.id] = true

		if type(option.text) ~= "string" then
			error(`MrDialogue.new: choice node "{nodeId}" option {index} text must be a string`, 4)
		end

		if type(option.next) ~= "string" or option.next == "" then
			error(`MrDialogue.new: choice node "{nodeId}" option {index} must have a target`, 4)
		end

		if option.condition ~= nil then
			validateConditionSpec(
				option.condition,
				`choice node "{nodeId}" option {index} condition`
			)
		end

		local target = definition.nodes[option.next]
		if type(target) ~= "table" then
			error(
				`MrDialogue.new: choice node "{nodeId}" option {index} target "{option.next}" does not exist`,
				4
			)
		end
		if
			target.type ~= "line"
			and target.type ~= "choice"
			and target.type ~= "branch"
			and target.type ~= "action"
			and target.type ~= "end"
		then
			error(
				`MrDialogue.new: choice node "{nodeId}" option {index} target must be a line, choice, branch, action, or end`,
				4
			)
		end
	end

	if node.fallback ~= nil then
		if type(node.fallback) ~= "string" or node.fallback == "" then
			error(`MrDialogue.new: choice node "{nodeId}" fallback must be a non-empty string`, 4)
		end

		local fallback = definition.nodes[node.fallback]
		if type(fallback) ~= "table" then
			error(
				`MrDialogue.new: choice node "{nodeId}" fallback target "{node.fallback}" does not exist`,
				4
			)
		end
		if
			fallback.type ~= "line"
			and fallback.type ~= "choice"
			and fallback.type ~= "branch"
			and fallback.type ~= "action"
			and fallback.type ~= "end"
		then
			error(
				`MrDialogue.new: choice node "{nodeId}" fallback must target a line, choice, branch, action, or end`,
				4
			)
		end
	end
end

local function validateBranch(nodeId: string, node: any, definition: any)
	validateConditionSpec(node.condition, `branch node "{nodeId}" condition`)

	for _, field in ipairs({ "onTrue", "onFalse" }) do
		local targetId = node[field]
		if type(targetId) ~= "string" or targetId == "" then
			error(`MrDialogue.new: branch node "{nodeId}" {field} must be a non-empty string`, 4)
		end

		local target = definition.nodes[targetId]
		if type(target) ~= "table" then
			error(
				`MrDialogue.new: branch node "{nodeId}" {field} target "{targetId}" does not exist`,
				4
			)
		end
		if
			target.type ~= "line"
			and target.type ~= "choice"
			and target.type ~= "branch"
			and target.type ~= "action"
			and target.type ~= "end"
		then
			error(
				`MrDialogue.new: branch node "{nodeId}" {field} must target a line, choice, branch, action, or end`,
				4
			)
		end
	end
end

local function validateAction(nodeId: string, node: any, definition: any)
	validateActionSpec(node.action, `action node "{nodeId}" action`)
	if node.next == nil then
		return
	end
	if type(node.next) ~= "string" or node.next == "" then
		error(`MrDialogue.new: action node "{nodeId}" next must be a non-empty string`, 4)
	end
	if type(definition.nodes[node.next]) ~= "table" then
		error(`MrDialogue.new: action node "{nodeId}" target "{node.next}" does not exist`, 4)
	end
end

local function validateEnd(nodeId: string, node: any)
	if node.result ~= nil and type(node.result) ~= "string" then
		error(`MrDialogue.new: end node "{nodeId}" result must be a string`, 4)
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

	if definition.freezeCharacter ~= nil and type(definition.freezeCharacter) ~= "boolean" then
		error("MrDialogue.new: definition.freezeCharacter must be a boolean", 3)
	end

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
		elseif node.type == "choice" then
			validateChoice(nodeId, node, definition)
		elseif node.type == "branch" then
			validateBranch(nodeId, node, definition)
		elseif node.type == "action" then
			validateAction(nodeId, node, definition)
		elseif node.type == "end" then
			validateEnd(nodeId, node)
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
	for nodeId, node in pairs(self._definition.nodes) do
		if node.type == "branch" and not Conditions._isRegistered(node.condition.name) then
			return nil,
				`condition "{node.condition.name}" used by branch node "{nodeId}" is not registered`
		elseif node.type == "choice" then
			for index, option in ipairs(node.options) do
				local condition = option.condition
				if condition and not Conditions._isRegistered(condition.name) then
					return nil,
						`condition "{condition.name}" used by choice node "{nodeId}" option {index} is not registered`
				end
			end
		elseif node.type == "action" and not Actions._isRegistered(node.action.name) then
			return nil,
				`action "{node.action.name}" used by action node "{nodeId}" is not registered`
		end
	end

	return SessionClass.new(player, self.Id, self._definition, options)
end

return table.freeze(Dialogue)
