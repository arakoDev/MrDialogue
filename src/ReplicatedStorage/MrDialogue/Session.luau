--!strict

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Actions = require(script.Parent.Actions)
local Conditions = require(script.Parent.Conditions)
local Net = require(script.Parent.Net)
local Types = require(script.Parent.Types)

local Session = {}
Session.__index = Session

export type Session = Types.Session

type SessionPhase =
	"RESOLVING"
	| "WAITING_PRESENTATION"
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
	pendingNodeId: string?,
	pendingEndResult: string?,
	lifecycleGeneration: number,
	clientStarted: boolean,
}

type PreparedNode = {
	phase: "WAITING_PRESENTATION" | "WAITING_CHOICE",
	expectedTurn: string,
	presentation: Net.PresentationPayload?,
	choices: Net.ChoicesPayload?,
	offeredOptions: { Types.ChoiceOption }?,
}

type ResolvedNode = {
	nodeId: string,
	node: Types.DialogueNode,
	prepared: PreparedNode?,
}

local MAX_SILENT_HOPS = 32
local IMPLICIT_END_NODE: Types.EndNode = {
	type = "end",
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

local function makeContext(self: Session, state: SessionState): Types.DialogueContext
	return {
		player = self.Player,
		dialogueId = self.DialogueId,
		session = self,
		npc = state.npc,
		data = state.data,
	}
end

local function prepareChoiceOffer(
	self: Session,
	state: SessionState,
	node: Types.ChoiceNode
): PreparedNode
	local turn = HttpService:GenerateGUID(false)
	local options: { Net.ChoiceOptionPayload } = {}
	local offeredOptions: { Types.ChoiceOption } = {}
	local context = makeContext(self, state)

	for _, option in ipairs(node.options) do
		if option.condition == nil or Conditions._evaluate(option.condition, context) then
			table.insert(options, {
				text = option.text,
			})
			table.insert(offeredOptions, option)
		end
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

local function prepareVisibleNode(
	definition: Types.DialogueDefinition,
	nodeId: string
): PreparedNode
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
	elseif node.type == "choice" and node.text ~= nil then
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

	error(`node "{nodeId}" is not a visible dialogue presentation`, 3)
end

local function applyPreparedNode(state: SessionState, prepared: PreparedNode)
	state.phase = prepared.phase
	state.expectedTurn = prepared.expectedTurn
	state.offeredOptions = prepared.offeredOptions
	state.pendingNodeId = nil
	state.pendingEndResult = nil
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
	interaction: "advance" | "finish",
	pendingNodeId: string?,
	pendingEndResult: string?
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
	state.pendingNodeId = pendingNodeId
	state.pendingEndResult = pendingEndResult
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

local function beginResolving(state: SessionState)
	state.phase = "RESOLVING"
	state.expectedTurn = nil
	state.offeredOptions = nil
	state.pendingNodeId = nil
	state.pendingEndResult = nil
end

local function failAction(
	self: Session,
	state: SessionState,
	actionName: string,
	result: Actions.ExecutionResult
)
	local code = result.code or "ACTION_FAILED"
	warn(`[MrDialogue][{code}] Action "{actionName}" failed: {tostring(result.details)}`)

	local sent = true
	local sendError: any = nil
	if state.clientStarted then
		local message: Net.EndMessage = {
			type = "end",
			sessionId = state.sessionId,
			result = nil,
		}
		sent, sendError = pcall(function()
			Net._sendToClient(self.Player, message)
		end)
	end

	Session._end(self)
	if not sent then
		warn(
			`[MrDialogue][END_SEND_FAILED] Failed to end action Session for "{actionName}": {tostring(
				sendError
			)}`
		)
	end

	error(`action "{actionName}" failed with {code}`, 3)
end

local function resolveNode(
	self: Session,
	state: SessionState,
	initialNodeId: string,
	executeActions: boolean
): ResolvedNode?
	local nodeId = initialNodeId
	local visited: { [string]: boolean } = {}
	local silentHops = 0

	while true do
		if visited[nodeId] then
			error(`dialogue resolution entered a silent cycle at node "{nodeId}"`, 2)
		end
		visited[nodeId] = true

		local node = state.definition.nodes[nodeId]
		if node.type == "branch" then
			if silentHops >= MAX_SILENT_HOPS then
				error(`dialogue resolution exceeded {MAX_SILENT_HOPS} silent nodes`, 2)
			end
			silentHops += 1

			local passed = Conditions._evaluate(node.condition, makeContext(self, state))
			nodeId = if passed then node.onTrue else node.onFalse
		elseif node.type == "choice" and node.text == nil then
			local prepared = prepareChoiceOffer(self, state, node)
			local offeredOptions = prepared.offeredOptions
			if offeredOptions and #offeredOptions > 0 then
				return {
					nodeId = nodeId,
					node = node,
					prepared = prepared,
				}
			end

			if node.fallback == nil then
				error(`choice node "{nodeId}" has no available options or fallback`, 2)
			end
			if silentHops >= MAX_SILENT_HOPS then
				error(`dialogue resolution exceeded {MAX_SILENT_HOPS} silent nodes`, 2)
			end
			silentHops += 1
			nodeId = node.fallback
		elseif node.type == "action" then
			if not executeActions then
				return {
					nodeId = nodeId,
					node = node,
					prepared = nil,
				}
			end
			if silentHops >= MAX_SILENT_HOPS then
				error(`dialogue resolution exceeded {MAX_SILENT_HOPS} silent nodes`, 2)
			end
			silentHops += 1

			state.currentNodeId = nodeId
			local generation = state.lifecycleGeneration
			local result = Actions._execute(node.action, makeContext(self, state))

			if
				not state.active
				or state.lifecycleGeneration ~= generation
				or state.phase ~= "RESOLVING"
				or state.currentNodeId ~= nodeId
			then
				return nil
			end

			if not result.success then
				failAction(self, state, node.action.name, result)
			end

			if node.next == nil then
				return {
					nodeId = nodeId,
					node = IMPLICIT_END_NODE,
					prepared = nil,
				}
			end
			nodeId = node.next
		else
			return {
				nodeId = nodeId,
				node = node,
				prepared = nil,
			}
		end
	end
end

local function moveToNode(self: Session, state: SessionState, nodeId: string)
	local resolved = resolveNode(self, state, nodeId, true)
	if not resolved then
		return
	end
	if resolved.node.type == "end" then
		state.currentNodeId = resolved.nodeId
		endSession(self, state, resolved.node.result)
		return
	end

	local prepared = resolved.prepared or prepareVisibleNode(state.definition, resolved.nodeId)
	sendPreparedNode(self, state, prepared)
	state.currentNodeId = resolved.nodeId
end

local function prepareFollowingInteraction(self: Session, state: SessionState, nodeId: string)
	local resolved = resolveNode(self, state, nodeId, false)
	if not resolved then
		return
	end
	if resolved.node.type == "end" then
		sendReady(self, state, "READY_TO_FINISH", "finish", resolved.nodeId, resolved.node.result)
		return
	end

	if resolved.prepared then
		sendPreparedNode(self, state, resolved.prepared)
		state.currentNodeId = resolved.nodeId
		return
	end

	sendReady(self, state, "READY_TO_ADVANCE", "advance", resolved.nodeId, nil)
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

	local sessionId = HttpService:GenerateGUID(false)
	local self = setmetatable({
		Player = player,
		DialogueId = dialogueId,
	}, Session) :: any
	local state: SessionState = {
		definition = definition,
		currentNodeId = definition.entry,
		npc = if options then options.npc else nil,
		data = if options and options.data then table.clone(options.data) else {},
		active = true,
		sessionId = sessionId,
		phase = "RESOLVING",
		expectedTurn = nil,
		offeredOptions = nil,
		pendingNodeId = nil,
		pendingEndResult = nil,
		lifecycleGeneration = 0,
		clientStarted = false,
	}
	states[self] = state
	activeSessions[player] = self

	local resolvedOk, resolved = pcall(resolveNode, self, state, definition.entry, true)
	if not resolvedOk then
		states[self] = nil
		if activeSessions[player] == self then
			activeSessions[player] = nil
		end
		error(resolved, 3)
	end

	local initial = resolved :: ResolvedNode?
	if not initial then
		return table.freeze(self) :: Session, nil
	end
	if initial.node.type == "end" then
		state.currentNodeId = initial.nodeId
		Session._end(self)
		return table.freeze(self) :: Session, nil
	end

	local prepared = initial.prepared or prepareVisibleNode(definition, initial.nodeId)
	state.currentNodeId = initial.nodeId
	applyPreparedNode(state, prepared)
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
	state.clientStarted = true

	return table.freeze(self) :: Session, nil
end

function Session.IsActive(self: Session): boolean
	local state = states[self]
	return state ~= nil and state.active
end

local function handlePresentationCompleted(self: Session, state: SessionState, message: any)
	if
		state.phase ~= "WAITING_PRESENTATION"
		or type(message.turn) ~= "string"
		or message.turn ~= state.expectedTurn
	then
		return
	end

	beginResolving(state)

	local node = state.definition.nodes[state.currentNodeId]
	if node.type == "line" then
		if node.next == nil then
			sendReady(self, state, "READY_TO_FINISH", "finish", nil, nil)
		else
			prepareFollowingInteraction(self, state, node.next)
		end
		return
	end

	if node.type == "choice" and node.text ~= nil then
		local prepared = prepareChoiceOffer(self, state, node)
		local offeredOptions = prepared.offeredOptions
		if offeredOptions and #offeredOptions > 0 then
			sendPreparedNode(self, state, prepared)
		elseif node.fallback then
			prepareFollowingInteraction(self, state, node.fallback)
		else
			error(`choice node "{state.currentNodeId}" has no available options or fallback`, 2)
		end
	end
end

local function handleAdvance(self: Session, state: SessionState, message: any)
	if
		(state.phase ~= "READY_TO_ADVANCE" and state.phase ~= "READY_TO_FINISH")
		or type(message.turn) ~= "string"
		or message.turn ~= state.expectedTurn
	then
		return
	end

	local finishing = state.phase == "READY_TO_FINISH"
	local pendingNodeId = state.pendingNodeId
	local pendingEndResult = state.pendingEndResult
	beginResolving(state)

	if finishing then
		if pendingNodeId then
			state.currentNodeId = pendingNodeId
		end
		endSession(self, state, pendingEndResult)
		return
	end

	if not pendingNodeId then
		return
	end

	moveToNode(self, state, pendingNodeId)
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

	beginResolving(state)

	if
		option.condition and not Conditions._evaluate(option.condition, makeContext(self, state))
	then
		local node = state.definition.nodes[state.currentNodeId]
		if node.type ~= "choice" then
			return
		end

		local prepared = prepareChoiceOffer(self, state, node)
		local refreshedOptions = prepared.offeredOptions
		if refreshedOptions and #refreshedOptions > 0 then
			sendPreparedNode(self, state, prepared)
		elseif node.fallback then
			prepareFollowingInteraction(self, state, node.fallback)
		else
			error(`choice node "{state.currentNodeId}" has no available options or fallback`, 2)
		end
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
	state.lifecycleGeneration += 1
	state.phase = "FINISHED"
	state.expectedTurn = nil
	state.offeredOptions = nil
	state.pendingNodeId = nil
	state.pendingEndResult = nil

	if activeSessions[self.Player] == self then
		activeSessions[self.Player] = nil
	end
	return true
end

if RunService:IsServer() then
	Net._connectServer(handleClientMessage)
end

return table.freeze(Session)
