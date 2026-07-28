--!strict

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

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
	clientStarted: boolean,
	outcome: Types.SessionOutcome?,
	characterAddedConnection: RBXScriptConnection?,
	characterChildAddedConnection: RBXScriptConnection?,
	humanoidDiedConnection: RBXScriptConnection?,
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

-- Stands in for the end of an action node that has no next.
local IMPLICIT_END_NODE: Types.EndNode = {
	type = "end",
}

local states: { [Session]: SessionState } = setmetatable({}, { __mode = "k" }) :: any
local activeSessions: { [Player]: Session } = {}
local clientReadyPlayers: { [Player]: boolean } = {}

local function resolveSpeaker(
	definition: Types.DialogueDefinition,
	node: Types.LineNode | Types.ChoiceNode
): Net.SpeakerPayload?
	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if type(speakerId) ~= "string" then
		-- false explicitly selects narration.
		return nil
	end

	local speakers = definition.speakers
	local speaker = if speakers then speakers[speakerId] else nil
	if not speaker then
		return nil
	end

	local emotions = speaker.emotions
	local emotionIcon = if node.emotion and emotions then emotions[node.emotion] else nil
	local icon = emotionIcon or speaker.icon or definition.defaultIcon

	return {
		name = speaker.name,
		icon = if icon ~= "" then icon else nil,
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

local function preparePresentation(
	definition: Types.DialogueDefinition,
	node: Types.LineNode | Types.ChoiceNode,
	kind: "line" | "choice_prompt",
	text: string
): PreparedNode
	local turn = HttpService:GenerateGUID(false)
	return {
		phase = "WAITING_PRESENTATION",
		expectedTurn = turn,
		presentation = {
			turn = turn,
			kind = kind,
			speaker = resolveSpeaker(definition, node),
			text = text,
		},
	}
end

local function prepareVisibleNode(
	definition: Types.DialogueDefinition,
	nodeId: string
): PreparedNode
	local node = definition.nodes[nodeId]
	if node.type == "line" then
		return preparePresentation(definition, node, "line", node.text)
	elseif node.type == "choice" and node.text ~= nil then
		return preparePresentation(definition, node, "choice_prompt", node.text)
	end

	error(`node "{nodeId}" has nothing to present`, 2)
end

-- Filter as late as possible so conditions use current game state.
local function prepareChoiceOffer(
	self: Session,
	state: SessionState,
	node: Types.ChoiceNode
): PreparedNode?
	local options: { Net.ChoiceOptionPayload } = {}
	local offeredOptions: { Types.ChoiceOption } = {}
	local context = makeContext(self, state)

	for _, option in ipairs(node.options) do
		if option.condition == nil or Conditions._evaluate(option.condition, context) then
			table.insert(options, { text = option.text })
			table.insert(offeredOptions, option)
		end
	end

	if #offeredOptions == 0 then
		return nil
	end

	local turn = HttpService:GenerateGUID(false)
	return {
		phase = "WAITING_CHOICE",
		expectedTurn = turn,
		choices = {
			turn = turn,
			options = options,
		},
		offeredOptions = offeredOptions,
	}
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
	local choices = prepared.choices

	if presentation then
		Net._sendToClient(self.Player, {
			type = "present",
			sessionId = state.sessionId,
			turn = presentation.turn,
			kind = presentation.kind,
			speaker = presentation.speaker,
			text = presentation.text,
		})
	elseif choices then
		Net._sendToClient(self.Player, {
			type = "choices",
			sessionId = state.sessionId,
			turn = choices.turn,
			options = choices.options,
		})
	end

	applyPreparedNode(state, prepared)
end

-- Hold the next node until the player acknowledges the current line.
local function sendReady(
	self: Session,
	state: SessionState,
	phase: "READY_TO_ADVANCE" | "READY_TO_FINISH",
	interaction: "advance" | "finish",
	pendingNodeId: string?,
	pendingEndResult: string?
)
	local turn = HttpService:GenerateGUID(false)
	Net._sendToClient(self.Player, {
		type = "ready",
		sessionId = state.sessionId,
		turn = turn,
		interaction = interaction,
	})

	state.phase = phase
	state.expectedTurn = turn
	state.offeredOptions = nil
	state.pendingNodeId = pendingNodeId
	state.pendingEndResult = pendingEndResult
end

local function beginResolving(state: SessionState)
	state.phase = "RESOLVING"
	state.expectedTurn = nil
	state.offeredOptions = nil
	state.pendingNodeId = nil
	state.pendingEndResult = nil
end

local function sendOutcome(self: Session, state: SessionState, outcome: Types.SessionOutcome)
	if not state.clientStarted or self.Player.Parent ~= Players then
		return
	end

	Net._sendToClient(self.Player, {
		type = "end",
		sessionId = state.sessionId,
		status = outcome.status,
		result = outcome.result,
		reason = outcome.reason,
	})
end

local function endSession(self: Session, state: SessionState, result: string?)
	local outcome: Types.SessionOutcome = table.freeze({
		status = "completed",
		result = result,
	}) :: any

	if Session._end(self, outcome) then
		sendOutcome(self, state, outcome)
	end
end

local function cancelSession(
	self: Session,
	state: SessionState,
	reason: string,
	notifyClient: boolean
): boolean
	local outcome: Types.SessionOutcome = table.freeze({
		status = "cancelled",
		reason = reason,
	}) :: any

	if not Session._end(self, outcome) then
		return false
	end
	if notifyClient then
		sendOutcome(self, state, outcome)
	end

	return true
end

local function disconnectCharacterDeathMonitoring(state: SessionState)
	local characterChildAddedConnection = state.characterChildAddedConnection
	if characterChildAddedConnection then
		characterChildAddedConnection:Disconnect()
		state.characterChildAddedConnection = nil
	end

	local humanoidDiedConnection = state.humanoidDiedConnection
	if humanoidDiedConnection then
		humanoidDiedConnection:Disconnect()
		state.humanoidDiedConnection = nil
	end
end

local function disconnectDeathMonitoring(state: SessionState)
	disconnectCharacterDeathMonitoring(state)

	local characterAddedConnection = state.characterAddedConnection
	if characterAddedConnection then
		characterAddedConnection:Disconnect()
		state.characterAddedConnection = nil
	end
end

local function monitorCharacterDeath(self: Session, state: SessionState, character: Model)
	disconnectCharacterDeathMonitoring(state)

	local function monitorHumanoid(humanoid: Humanoid)
		local existingConnection = state.humanoidDiedConnection
		if existingConnection then
			existingConnection:Disconnect()
		end

		state.humanoidDiedConnection = humanoid.Died:Connect(function()
			if state.active and self.Player.Character == character then
				cancelSession(self, state, "death", true)
			end
		end)

		-- The humanoid may already be dead when monitoring begins.
		if humanoid.Health <= 0 and state.active and self.Player.Character == character then
			cancelSession(self, state, "death", true)
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		monitorHumanoid(humanoid)
		return
	end

	state.characterChildAddedConnection = character.ChildAdded:Connect(function(child)
		if state.active and self.Player.Character == character and child:IsA("Humanoid") then
			local childAddedConnection = state.characterChildAddedConnection
			if childAddedConnection then
				childAddedConnection:Disconnect()
				state.characterChildAddedConnection = nil
			end
			monitorHumanoid(child)
		end
	end)
end

local function beginDeathMonitoring(self: Session, state: SessionState)
	if state.definition.endDialogueOnDeath == false then
		return
	end

	state.characterAddedConnection = self.Player.CharacterAdded:Connect(function(character)
		if state.active then
			monitorCharacterDeath(self, state, character)
		end
	end)

	local character = self.Player.Character
	if character then
		monitorCharacterDeath(self, state, character)
	end
end

local function cancelWithoutOptions(self: Session, state: SessionState, nodeId: string)
	warn(
		`[MrDialogue][CHOICE_NO_AVAILABLE_OPTIONS] Choice node "{nodeId}" in dialogue "{self.DialogueId}" filtered to zero options and has no fallback`
	)
	cancelSession(self, state, "no_available_options", true)
end

-- Walk silent nodes until there is something to show. Look-ahead stops before running actions.
local function resolveNode(
	self: Session,
	state: SessionState,
	initialNodeId: string,
	executeActions: boolean
): ResolvedNode?
	local nodeId = initialNodeId
	local visited: { [string]: boolean } = {}

	while true do
		if visited[nodeId] then
			warn(
				`[MrDialogue][RESOLUTION_CYCLE] Dialogue "{self.DialogueId}" looped back to node "{nodeId}" without presenting anything`
			)
			cancelSession(self, state, "resolution_error", true)
			return nil
		end
		visited[nodeId] = true

		local node = state.definition.nodes[nodeId]
		if node.type == "branch" then
			local passed = Conditions._evaluate(node.condition, makeContext(self, state))
			nodeId = if passed then node.onTrue else node.onFalse
		elseif node.type == "choice" and node.text == nil then
			local prepared = prepareChoiceOffer(self, state, node)
			if prepared then
				return { nodeId = nodeId, node = node, prepared = prepared }
			end
			if node.fallback == nil then
				cancelWithoutOptions(self, state, nodeId)
				return nil
			end
			nodeId = node.fallback
		elseif node.type == "action" then
			if not executeActions then
				return { nodeId = nodeId, node = node, prepared = nil }
			end

			state.currentNodeId = nodeId
			local result = Actions._execute(node.action, makeContext(self, state))
			if not state.active then
				return nil
			end
			if not result.success then
				warn(
					`[MrDialogue][{result.code}] Action "{node.action.name}" failed: {tostring(
						result.details
					)}`
				)
				cancelSession(self, state, "action_error", true)
				return nil
			end

			if node.next == nil then
				return { nodeId = nodeId, node = IMPLICIT_END_NODE, prepared = nil }
			end
			nodeId = node.next
		else
			return { nodeId = nodeId, node = node, prepared = nil }
		end
	end
end

-- Starts and accepted choices show the next visible node immediately.
local function moveToNode(self: Session, state: SessionState, nodeId: string)
	local resolved = resolveNode(self, state, nodeId, true)
	if not resolved then
		return
	end

	state.currentNodeId = resolved.nodeId
	if resolved.node.type == "end" then
		endSession(self, state, resolved.node.result)
		return
	end

	sendPreparedNode(
		self,
		state,
		resolved.prepared or prepareVisibleNode(state.definition, resolved.nodeId)
	)
end

-- After a line, wait for another click before showing the next visible node.
local function prepareFollowingInteraction(self: Session, state: SessionState, nodeId: string)
	local resolved = resolveNode(self, state, nodeId, false)
	if not resolved then
		return
	end

	if resolved.node.type == "end" then
		sendReady(self, state, "READY_TO_FINISH", "finish", resolved.nodeId, resolved.node.result)
	elseif resolved.prepared then
		sendPreparedNode(self, state, resolved.prepared)
		state.currentNodeId = resolved.nodeId
	else
		sendReady(self, state, "READY_TO_ADVANCE", "advance", resolved.nodeId, nil)
	end
end

local function offerChoices(
	self: Session,
	state: SessionState,
	nodeId: string,
	node: Types.ChoiceNode
)
	local prepared = prepareChoiceOffer(self, state, node)
	if prepared then
		sendPreparedNode(self, state, prepared)
		state.currentNodeId = nodeId
	elseif node.fallback then
		prepareFollowingInteraction(self, state, node.fallback)
	else
		cancelWithoutOptions(self, state, nodeId)
	end
end

function Session.new(
	player: Player,
	dialogueId: string,
	definition: Types.DialogueDefinition,
	options: Types.SessionOptions?
): (Session?, string?)
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
	if not clientReadyPlayers[player] then
		return nil, "player dialogue client is not ready"
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
		clientStarted = false,
	}
	states[self] = state
	activeSessions[player] = self

	local initial = resolveNode(self, state, definition.entry, true)
	if not initial then
		return table.freeze(self) :: Session, nil
	end

	state.currentNodeId = initial.nodeId
	if initial.node.type == "end" then
		endSession(self, state, initial.node.result)
		return table.freeze(self) :: Session, nil
	end

	local prepared = initial.prepared or prepareVisibleNode(definition, initial.nodeId)
	applyPreparedNode(state, prepared)
	Net._sendToClient(player, {
		type = "start",
		sessionId = sessionId,
		dialogueId = dialogueId,
		freezeCharacter = definition.freezeCharacter,
		presentation = prepared.presentation,
		choices = prepared.choices,
	})
	state.clientStarted = true
	beginDeathMonitoring(self, state)

	return table.freeze(self) :: Session, nil
end

function Session.IsActive(self: Session): boolean
	local state = states[self]
	return state ~= nil and state.active
end

function Session.GetOutcome(self: Session): Types.SessionOutcome?
	local state = states[self]
	return if state then state.outcome else nil
end

function Session.Cancel(self: Session, reason: any): boolean
	local cancelReason = if reason == nil then "manual" else reason
	if
		type(cancelReason) ~= "string"
		or (cancelReason ~= "manual" and string.match(cancelReason, "^[%w_%-]+:[%w_.%-]+$") == nil)
	then
		error('Session:Cancel reason must be "manual" or a namespaced string', 2)
	end

	local state = states[self]
	if not state or not state.active then
		return false
	end

	return cancelSession(self, state, cancelReason, true)
end

-- Each server message accepts one reply with the matching turn token.
local function isExpectedTurn(state: SessionState, turn: any): boolean
	return state.expectedTurn ~= nil and state.expectedTurn == turn
end

local function handlePresentationCompleted(self: Session, state: SessionState, message: any)
	if state.phase ~= "WAITING_PRESENTATION" or not isExpectedTurn(state, message.turn) then
		return
	end

	local nodeId = state.currentNodeId
	local node = state.definition.nodes[nodeId]
	beginResolving(state)

	if node.type == "line" then
		if node.next == nil then
			sendReady(self, state, "READY_TO_FINISH", "finish", nil, nil)
		else
			prepareFollowingInteraction(self, state, node.next)
		end
	elseif node.type == "choice" then
		offerChoices(self, state, nodeId, node)
	end
end

local function handleAdvance(self: Session, state: SessionState, message: any)
	if
		(state.phase ~= "READY_TO_ADVANCE" and state.phase ~= "READY_TO_FINISH")
		or not isExpectedTurn(state, message.turn)
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
	elseif pendingNodeId then
		moveToNode(self, state, pendingNodeId)
	end
end

local function handleChoose(self: Session, state: SessionState, message: any)
	if state.phase ~= "WAITING_CHOICE" or not isExpectedTurn(state, message.turn) then
		return
	end

	-- Resolve the index against the exact filtered offer sent to this client.
	local offeredOptions = state.offeredOptions
	local index = message.index
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
		return
	end

	local option = if offeredOptions then offeredOptions[index] else nil
	if not option then
		return
	end

	local nodeId = state.currentNodeId
	beginResolving(state)

	if
		option.condition and not Conditions._evaluate(option.condition, makeContext(self, state))
	then
		-- The option changed while it was visible; send a fresh offer.
		local node = state.definition.nodes[nodeId]
		if node.type == "choice" then
			offerChoices(self, state, nodeId, node)
		end
		return
	end

	moveToNode(self, state, option.next)
end

local function handleClientMessage(player: Player, message: any)
	if type(message) ~= "table" then
		return
	end

	if message.type == "client_ready" then
		clientReadyPlayers[player] = true
		return
	elseif message.type == "client_stopped" then
		clientReadyPlayers[player] = nil
		local stoppedSession = activeSessions[player]
		local stoppedState = if stoppedSession then states[stoppedSession] else nil
		if stoppedSession and stoppedState and stoppedState.active then
			cancelSession(stoppedSession, stoppedState, "client_cancelled", true)
		end
		return
	end

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if not self or not state or not state.active or message.sessionId ~= state.sessionId then
		return
	end

	if message.type == "cancel" then
		cancelSession(self, state, "client_cancelled", true)
	elseif message.type == "presentation_completed" then
		handlePresentationCompleted(self, state, message)
	elseif message.type == "advance" then
		handleAdvance(self, state, message)
	elseif message.type == "choose" then
		handleChoose(self, state, message)
	end
end

-- All completion and cancellation paths meet here.
function Session._end(self: Session, outcome: Types.SessionOutcome): boolean
	local state = states[self]
	if not state or not state.active then
		return false
	end

	state.active = false
	state.phase = "FINISHED"
	state.expectedTurn = nil
	state.offeredOptions = nil
	state.pendingNodeId = nil
	state.pendingEndResult = nil
	state.outcome = outcome
	disconnectDeathMonitoring(state)

	if activeSessions[self.Player] == self then
		activeSessions[self.Player] = nil
	end

	return true
end

Net._connectServer(handleClientMessage)

Players.PlayerRemoving:Connect(function(player)
	clientReadyPlayers[player] = nil

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if self and state and state.active then
		cancelSession(self, state, "player_left", false)
	end
end)

return table.freeze(Session)
