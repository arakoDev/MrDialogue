--!strict

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Net = require(script.Parent.Net)
local Types = require(script.Parent.Types)

local Session = {}
Session.__index = Session

export type Session = Types.Session

type SessionPhase =
	"WAITING_PRESENTATION"
	| "READY_TO_ADVANCE"
	| "READY_TO_FINISH"
	| "WAITING_CHOICE"
	| "FINISHED"

type SessionState = {
	definition: Types.DialogueDefinition,
	currentNodeId: string,
	npc: Instance?,
	data: { [string]: any },
	active: boolean,
	sessionId: string,
	phase: SessionPhase,
	expectedTurn: string?,
	offeredOptions: { Types.ChoiceOption }?,
}

type PreparedNode = {
	phase: "WAITING_PRESENTATION" | "WAITING_CHOICE",
	expectedTurn: string,
	presentation: Net.PresentationPayload?,
	choices: Net.ChoicesPayload?,
	offeredOptions: { Types.ChoiceOption }?,
}

local states: { [Session]: SessionState } = setmetatable({}, { __mode = "k" }) :: any
local activeSessions: { [Player]: Session } = {}

local function resolveSpeaker(
	definition: Types.DialogueDefinition,
	node: Types.LineNode | Types.ChoiceNode
): Net.SpeakerPayload?
	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if speakerId == nil or speakerId == false then
		return nil
	end
	if type(speakerId) ~= "string" then
		error("presentation speaker must be a string or false", 3)
	end

	local speakers = definition.speakers
	local speaker = if speakers then speakers[speakerId] else nil
	if not speaker then
		error(`presentation references unknown speaker "{speakerId}"`, 3)
	end

	local icon: string? = nil
	if node.emotion ~= nil then
		local emotions = speaker.emotions
		icon = if emotions then emotions[node.emotion] else nil
		if not icon then
			error(
				`presentation references unknown emotion "{node.emotion}" for speaker "{speakerId}"`,
				3
			)
		end
	else
		icon = speaker.icon
	end

	return {
		name = speaker.name,
		icon = icon or speaker.icon or definition.defaultIcon,
	}
end

local function prepareChoiceOffer(node: Types.ChoiceNode): PreparedNode
	local turn = HttpService:GenerateGUID(false)

	local options: { Net.ChoiceOptionPayload } = {}
	local offeredOptions: { Types.ChoiceOption } = {}

	for index, option in ipairs(node.options) do
		options[index] = {
			text = option.text,
		}

		offeredOptions[index] = option
	end

	return {
		phase = "WAITING_CHOICE",
		expectedTurn = turn,
		presentation = nil,
		choices = {
			turn = turn,
			options = options,
		},
		offeredOptions = offeredOptions,
	}
end

local function prepareNode(definition: Types.DialogueDefinition, nodeId: string): PreparedNode
	local node = definition.nodes[nodeId]
	if node.type == "line" then
		local turn = HttpService:GenerateGUID(false)
		return {
			phase = "WAITING_PRESENTATION",
			expectedTurn = turn,
			presentation = {
				turn = turn,
				kind = "line",
				speaker = resolveSpeaker(definition, node),
				text = node.text,
			},
			choices = nil,
			offeredOptions = nil,
		}
	elseif node.type == "choice" then
		if node.text == nil then
			return prepareChoiceOffer(node)
		end

		local turn = HttpService:GenerateGUID(false)
		return {
			phase = "WAITING_PRESENTATION",
			expectedTurn = turn,
			presentation = {
				turn = turn,
				kind = "choice_prompt",
				speaker = resolveSpeaker(definition, node),
				text = node.text,
			},
			choices = nil,
			offeredOptions = nil,
		}
	end

	error(
		`Dialogue:Start node "{nodeId}" must be a line or choice until node traversal is implemented`,
		4
	)
end

local function applyPreparedNode(state: SessionState, prepared: PreparedNode)
	state.phase = prepared.phase
	state.expectedTurn = prepared.expectedTurn
	state.offeredOptions = prepared.offeredOptions
end

function Session.new(
	player: Player,
	dialogueId: string,
	definition: Types.DialogueDefinition,
	options: Types.SessionOptions?
): (Session?, string?)
	if not RunService:IsServer() then
		error("Dialogue:Start can only be called on the server", 3)
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Dialogue:Start requires a Player", 3)
	end

	if options ~= nil and type(options) ~= "table" then
		error("Dialogue:Start options must be a table", 3)
	end

	if options and options.npc ~= nil and typeof(options.npc) ~= "Instance" then
		error("Dialogue:Start options.npc must be an Instance", 3)
	end

	if options and options.data ~= nil and type(options.data) ~= "table" then
		error("Dialogue:Start options.data must be a table", 3)
	end

	if player.Parent ~= Players then
		return nil, "player is not connected"
	end

	local existingSession = activeSessions[player]
	if existingSession and existingSession:IsActive() then
		return nil, "player already has an active dialogue session"
	end

	local data = if options and options.data then table.clone(options.data) else {}
	local sessionId = HttpService:GenerateGUID(false)
	local prepared = prepareNode(definition, definition.entry)
	local self = setmetatable({
		Player = player,
		DialogueId = dialogueId,
	}, Session) :: any

	states[self] = {
		definition = definition,
		currentNodeId = definition.entry,
		npc = if options then options.npc else nil,
		data = data,
		active = true,
		sessionId = sessionId,
		phase = prepared.phase,
		expectedTurn = prepared.expectedTurn,
		offeredOptions = prepared.offeredOptions,
	}
	activeSessions[player] = self

	local startMessage: Net.StartMessage = {
		type = "start",
		sessionId = sessionId,
		dialogueId = dialogueId,
		presentation = prepared.presentation,
		choices = prepared.choices,
	}

	local sent, sendError = pcall(function()
		Net._sendToClient(player, startMessage)
	end)

	if not sent then
		states[self] = nil
		if activeSessions[player] == self then
			activeSessions[player] = nil
		end
		error(sendError, 3)
	end

	return table.freeze(self) :: Session, nil
end

function Session.IsActive(self: Session): boolean
	local state = states[self]
	return state ~= nil and state.active
end

local function sendPreparedNode(self: Session, state: SessionState, prepared: PreparedNode)
	local presentation = prepared.presentation
	if presentation then
		local message: Net.PresentMessage = {
			type = "present",
			sessionId = state.sessionId,
			turn = presentation.turn,
			kind = presentation.kind,
			speaker = presentation.speaker,
			text = presentation.text,
		}
		Net._sendToClient(self.Player, message)
		applyPreparedNode(state, prepared)
		return
	end

	local choices = prepared.choices
	if not choices then
		error("prepared dialogue node has no client payload", 2)
	end

	local message: Net.ChoicesMessage = {
		type = "choices",
		sessionId = state.sessionId,
		turn = choices.turn,
		options = choices.options,
	}
	Net._sendToClient(self.Player, message)
	applyPreparedNode(state, prepared)
end

local function sendReady(
	self: Session,
	state: SessionState,
	phase: "READY_TO_ADVANCE" | "READY_TO_FINISH",
	interaction: "advance" | "finish"
)
	local turn = HttpService:GenerateGUID(false)
	local message: Net.ReadyMessage = {
		type = "ready",
		sessionId = state.sessionId,
		turn = turn,
		interaction = interaction,
	}

	Net._sendToClient(self.Player, message)
	state.phase = phase
	state.expectedTurn = turn
	state.offeredOptions = nil
end

local function endSession(self: Session, state: SessionState, result: string?)
	local message: Net.EndMessage = {
		type = "end",
		sessionId = state.sessionId,
		result = result,
	}
	local sent, sendError = pcall(function()
		Net._sendToClient(self.Player, message)
	end)

	Session._end(self)
	if not sent then
		error(sendError, 0)
	end
end

local function handlePresentationCompleted(self: Session, state: SessionState, message: any)
	if
		state.phase ~= "WAITING_PRESENTATION"
		or type(message.turn) ~= "string"
		or message.turn ~= state.expectedTurn
	then
		return
	end

	local node = state.definition.nodes[state.currentNodeId]
	if node.type == "line" then
		if node.next ~= nil then
			sendReady(self, state, "READY_TO_ADVANCE", "advance")
		else
			sendReady(self, state, "READY_TO_FINISH", "finish")
		end
		return
	end

	if node.type == "choice" and node.text ~= nil then
		local prepared = prepareChoiceOffer(node)
		sendPreparedNode(self, state, prepared)
	end
end

local function moveToNode(self: Session, state: SessionState, nodeId: string)
	local node = state.definition.nodes[nodeId]
	if node.type == "end" then
		state.currentNodeId = nodeId
		endSession(self, state, node.result)
		return
	end

	local prepared = prepareNode(state.definition, nodeId)
	sendPreparedNode(self, state, prepared)
	state.currentNodeId = nodeId
end

local function handleAdvance(self: Session, state: SessionState, message: any)
	if
		(state.phase ~= "READY_TO_ADVANCE" and state.phase ~= "READY_TO_FINISH")
		or type(message.turn) ~= "string"
		or message.turn ~= state.expectedTurn
	then
		return
	end

	if state.phase == "READY_TO_FINISH" then
		endSession(self, state, nil)
		return
	end

	local node = state.definition.nodes[state.currentNodeId]
	if node.type ~= "line" or node.next == nil then
		return
	end

	moveToNode(self, state, node.next)
end

local function handleChoose(self: Session, state: SessionState, message: any)
	if
		state.phase ~= "WAITING_CHOICE"
		or type(message.turn) ~= "string"
		or message.turn ~= state.expectedTurn
		or type(message.index) ~= "number"
		or message.index % 1 ~= 0
	then
		return
	end

	local offeredOptions = state.offeredOptions
	local option = if offeredOptions then offeredOptions[message.index] else nil
	if not option then
		return
	end

	moveToNode(self, state, option.next)
end

local function handleClientMessage(player: Player, message: any)
	if type(message) ~= "table" then
		return
	end

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if
		not self
		or not state
		or not state.active
		or type(message.sessionId) ~= "string"
		or message.sessionId ~= state.sessionId
	then
		return
	end

	if message.type == "presentation_completed" then
		handlePresentationCompleted(self, state, message)
	elseif message.type == "advance" then
		handleAdvance(self, state, message)
	elseif message.type == "choose" then
		handleChoose(self, state, message)
	end
end

function Session._getActiveSession(player: Player): Session?
	local session = activeSessions[player]

	if session and session:IsActive() then
		return session
	end

	return nil
end

function Session._getDefinition(self: Session): Types.DialogueDefinition
	return states[self].definition
end

function Session._getCurrentNodeId(self: Session): string
	return states[self].currentNodeId
end

function Session._setCurrentNodeId(self: Session, nodeId: string)
	states[self].currentNodeId = nodeId
end

function Session._getNpc(self: Session): Instance?
	return states[self].npc
end

function Session._getData(self: Session): { [string]: any }
	return states[self].data
end

function Session._getSessionId(self: Session): string
	return states[self].sessionId
end

function Session._end(self: Session): boolean
	local state = states[self]

	if not state or not state.active then
		return false
	end

	state.active = false
	state.phase = "FINISHED"
	state.expectedTurn = nil
	state.offeredOptions = nil

	if activeSessions[self.Player] == self then
		activeSessions[self.Player] = nil
	end

	return true
end

if RunService:IsServer() then
	Net._connectServer(handleClientMessage)
end

return table.freeze(Session)
