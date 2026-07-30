--!strict

local RunService = game:GetService("RunService")
local Types = require(script.Types)

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
export type Dialogue = Types.Dialogue

if RunService:IsClient() then
	return require(script.Client) :: any
end

return require(script.Server) :: any
