--!strict

local Types = require(script.Parent.Types)

local Dialogue = {}
Dialogue.__index = Dialogue

local SUPPORTED_NODE_TYPES = table.freeze({
	line = true,
	choice = true,
	branch = true,
	action = true,
	["end"] = true,
})

export type Dialogue = {
	Id: string,
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

return table.freeze(Dialogue)
