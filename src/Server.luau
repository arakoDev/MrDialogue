--!strict

local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	error("MrDialogue.Server can only be required on the server", 2)
end

local Net = require(script.Parent.Net)
local Types = require(script.Parent.Types)
local Actions = require(script.Parent.Actions)
local Conditions = require(script.Parent.Conditions)
local DialogueClass = require(script.Parent.Dialogue)

Net._initializeServer()

export type Session = Types.Session
export type SessionOptions = Types.SessionOptions
export type SessionOutcome = Types.SessionOutcome
export type DialogueContext = Types.DialogueContext
export type ConditionHandler = Types.ConditionHandler
export type ActionHandler = Types.ActionHandler
export type ConditionSpec = Types.ConditionSpec
export type ActionSpec = Types.ActionSpec
export type SpeakerDefinition = Types.SpeakerDefinition
export type LineNode = Types.LineNode
export type ChoiceOption = Types.ChoiceOption
export type ChoiceNode = Types.ChoiceNode
export type BranchNode = Types.BranchNode
export type ActionNode = Types.ActionNode
export type EndNode = Types.EndNode
export type DialogueNode = Types.DialogueNode
export type DialogueDefinition = Types.DialogueDefinition
export type Dialogue = DialogueClass.Dialogue
export type Limits = Net.Limits

export type ServerApi = {
	Version: string,
	ProtocolVersion: number,
	Limits: Limits,
	RegisterAction: (name: string, handler: Types.ActionHandler) -> (),
	RegisterCondition: (name: string, handler: Types.ConditionHandler) -> (),
	new: (definition: Types.DialogueDefinition) -> DialogueClass.Dialogue,
}

local Server: ServerApi = {
	Version = Net.PACKAGE_VERSION,
	ProtocolVersion = Net.PROTOCOL_VERSION,
	Limits = Net.Limits,
} :: any

function Server.RegisterAction(name: string, handler: Types.ActionHandler)
	Actions.Register(name, handler)
end

function Server.RegisterCondition(name: string, handler: Types.ConditionHandler)
	Conditions.Register(name, handler)
end

function Server.new(definition: Types.DialogueDefinition): DialogueClass.Dialogue
	return DialogueClass.new(definition)
end

return table.freeze(Server)
