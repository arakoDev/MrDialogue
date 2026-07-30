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
	endedEvent: BindableEvent,
	active: boolean,
	clientId: string,
	sessionId: string,
	phase: SessionPhase,
	expectedTurn: string?,
	offeredOptions: { Types.ChoiceOption }?,
	pendingNodeId: string?,
	pendingEndResult: string?,
	clientStarted: boolean,
	outcome: Types.SessionOutcome?,
	timeoutSeconds: number,
	timeoutThread: thread?,
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

type MessageRate = {
	windowStartedAt: number,
	count: number,
	warned: boolean,
}

local IMPLICIT_END_NODE: Types.EndNode = {
	type = "end",
}

local states: { [Session]: SessionState } = setmetatable({}, { __mode = "k" }) :: any
local activeSessions: { [Player]: Session } = {}
local clientReadyPlayers: { [Player]: string } = {}
local messageRates: { [Player]: MessageRate } = {}

local function safeToString(value: any): string
	local result = table.pack(pcall(tostring, value))
	if result[1] and type(result[2]) == "string" then
		return result[2] :: string
	end
	return "<unprintable value>"
end

local function resolveSpeaker(
	definition: Types.DialogueDefinition,
	node: Types.LineNode | Types.ChoiceNode
): Net.SpeakerPayload?
	local speakerId = if node.speaker == nil then definition.defaultSpeaker else node.speaker
	if type(speakerId) ~= "string" then
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

local function prepareChoiceOffer(
	self: Session,
	state: SessionState,
	node: Types.ChoiceNode
): PreparedNode?
	local options: { Net.ChoiceOptionPayload } = {}
	local offeredOptions: { Types.ChoiceOption } = {}
	local context = makeContext(self, state)

	for _, option in ipairs(node.options) do
		local available = option.condition == nil or Conditions._evaluate(option.condition, context)
		if not state.active then
			return nil
		end
		if available then
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

local function sendSessionMessage(self: Session, message: Net.ServerMessage): boolean
	local sendResult = table.pack(pcall(Net._sendToClient, self.Player, message))
	if sendResult[1] then
		return true
	end

	warn(
		`[MrDialogue][SERVER_NETWORK_SEND_FAILED] Could not send "{message.type}" for dialogue "{self.DialogueId}": {safeToString(
			sendResult[2]
		)}`
	)
	local outcome: Types.SessionOutcome = table.freeze({
		status = "cancelled",
		reason = "network_error",
	}) :: any
	Session._end(self, outcome, false)
	return false
end

local function sendPreparedNode(self: Session, state: SessionState, prepared: PreparedNode): boolean
	local presentation = prepared.presentation
	local choices = prepared.choices
	local sent = false

	if presentation then
		sent = sendSessionMessage(self, {
			version = Net.PROTOCOL_VERSION,
			type = "present",
			clientId = state.clientId,
			sessionId = state.sessionId,
			turn = presentation.turn,
			kind = presentation.kind,
			speaker = presentation.speaker,
			text = presentation.text,
		})
	elseif choices then
		sent = sendSessionMessage(self, {
			version = Net.PROTOCOL_VERSION,
			type = "choices",
			clientId = state.clientId,
			sessionId = state.sessionId,
			turn = choices.turn,
			options = choices.options,
		})
	end

	if not sent then
		return false
	end
	applyPreparedNode(state, prepared)
	return true
end

local function sendReady(
	self: Session,
	state: SessionState,
	phase: "READY_TO_ADVANCE" | "READY_TO_FINISH",
	interaction: "advance" | "finish",
	pendingNodeId: string?,
	pendingEndResult: string?
): boolean
	local turn = HttpService:GenerateGUID(false)
	if
		not sendSessionMessage(self, {
			version = Net.PROTOCOL_VERSION,
			type = "ready",
			clientId = state.clientId,
			sessionId = state.sessionId,
			turn = turn,
			interaction = interaction,
		})
	then
		return false
	end

	state.phase = phase
	state.expectedTurn = turn
	state.offeredOptions = nil
	state.pendingNodeId = pendingNodeId
	state.pendingEndResult = pendingEndResult
	return true
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
		version = Net.PROTOCOL_VERSION,
		type = "end",
		clientId = state.clientId,
		sessionId = state.sessionId,
		status = outcome.status,
		result = outcome.result,
		reason = outcome.reason,
	})
end

local function endSession(self: Session, _state: SessionState, result: string?)
	local outcome: Types.SessionOutcome = table.freeze({
		status = "completed",
		result = result,
	}) :: any

	Session._end(self, outcome, true)
end

local function cancelSession(
	self: Session,
	_state: SessionState,
	reason: string,
	notifyClient: boolean
): boolean
	local outcome: Types.SessionOutcome = table.freeze({
		status = "cancelled",
		reason = reason,
	}) :: any

	return Session._end(self, outcome, notifyClient)
end

local function clearSessionTimeout(state: SessionState)
	local timeoutThread = state.timeoutThread
	state.timeoutThread = nil
	if timeoutThread then
		task.cancel(timeoutThread)
	end
end

local function armSessionTimeout(self: Session, state: SessionState)
	clearSessionTimeout(state)
	if not state.active then
		return
	end

	local timeoutThread: thread?
	timeoutThread = task.delay(state.timeoutSeconds, function()
		if not state.active or state.timeoutThread ~= timeoutThread then
			return
		end

		state.timeoutThread = nil
		warn(
			`[MrDialogue][SESSION_TIMEOUT] Dialogue "{self.DialogueId}" timed out for {self.Player.Name}`
		)
		cancelSession(self, state, "timeout", true)
	end)
	state.timeoutThread = timeoutThread
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

local function resolveNode(
	self: Session,
	state: SessionState,
	initialNodeId: string,
	executeActions: boolean
): ResolvedNode?
	local nodeId = initialNodeId
	local visited: { [string]: boolean } = {}
	local steps = 0

	while true do
		steps += 1
		if steps > Net.Limits.maxSilentSteps then
			warn(
				`[MrDialogue][RESOLUTION_LIMIT] Dialogue "{self.DialogueId}" exceeded {Net.Limits.maxSilentSteps} silent resolution steps`
			)
			cancelSession(self, state, "resolution_error", true)
			return nil
		end

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
			if not state.active then
				return nil
			end
			nodeId = if passed then node.onTrue else node.onFalse
		elseif node.type == "choice" and node.text == nil then
			local prepared = prepareChoiceOffer(self, state, node)
			if not state.active then
				return nil
			end
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
					`[MrDialogue][{result.code}] Action "{node.action.name}" failed: {safeToString(
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

local function prepareFollowingInteraction(self: Session, state: SessionState, nodeId: string)
	local resolved = resolveNode(self, state, nodeId, false)
	if not resolved then
		return
	end

	if resolved.node.type == "end" then
		sendReady(self, state, "READY_TO_FINISH", "finish", nodeId, nil)
	elseif resolved.prepared then
		if sendPreparedNode(self, state, resolved.prepared) then
			state.currentNodeId = resolved.nodeId
		end
	else
		sendReady(self, state, "READY_TO_ADVANCE", "advance", nodeId, nil)
	end
end

local function offerChoices(
	self: Session,
	state: SessionState,
	nodeId: string,
	node: Types.ChoiceNode
)
	local prepared = prepareChoiceOffer(self, state, node)
	if not state.active then
		return
	end
	if prepared then
		if sendPreparedNode(self, state, prepared) then
			state.currentNodeId = nodeId
		end
	elseif node.fallback then
		prepareFollowingInteraction(self, state, node.fallback)
	else
		cancelWithoutOptions(self, state, nodeId)
	end
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Session._validateStartArguments(player: any, options: any)
	if typeof(player) ~= "Instance" then
		error("Dialogue:Start requires a Player", 3)
	end

	local playerInstance = player :: Instance
	if not playerInstance:IsA("Player") then
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

	local timeoutSeconds = if options then options.timeoutSeconds else nil
	if
		timeoutSeconds ~= nil
		and (
			type(timeoutSeconds) ~= "number"
			or not isFinite(timeoutSeconds)
			or timeoutSeconds <= 0
			or timeoutSeconds > Net.Limits.maxSessionTimeoutSeconds
		)
	then
		error(
			`Dialogue:Start options.timeoutSeconds must be a positive number no greater than {Net.Limits.maxSessionTimeoutSeconds}`,
			3
		)
	end
end

function Session.new(
	player: Player,
	dialogueId: string,
	definition: Types.DialogueDefinition,
	options: Types.SessionOptions?
): (Session?, string?)
	Session._validateStartArguments(player, options)
	if player.Parent ~= Players then
		return nil, "player is not connected"
	end
	local clientId = clientReadyPlayers[player]
	if not clientId then
		return nil, "player dialogue client is not ready"
	end

	local existingSession = activeSessions[player]
	if existingSession and existingSession:IsActive() then
		return nil, "player already has an active dialogue session"
	end

	local sessionId = HttpService:GenerateGUID(false)
	local endedEvent = Instance.new("BindableEvent")
	local self = setmetatable({
		Player = player,
		DialogueId = dialogueId,
		Ended = endedEvent.Event,
	}, Session) :: any
	local state: SessionState = {
		definition = definition,
		currentNodeId = definition.entry,
		npc = if options then options.npc else nil,
		data = if options and options.data then table.clone(options.data) else {},
		endedEvent = endedEvent,
		active = true,
		clientId = clientId,
		sessionId = sessionId,
		phase = "RESOLVING",
		clientStarted = false,
		timeoutSeconds = if options and options.timeoutSeconds
			then options.timeoutSeconds
			else Net.Limits.sessionTimeoutSeconds,
		timeoutThread = nil,
	}
	states[self] = state
	activeSessions[player] = self

	local initial = resolveNode(self, state, definition.entry, true)
	if not initial or not state.active then
		return table.freeze(self) :: Session, nil
	end

	state.currentNodeId = initial.nodeId
	if initial.node.type == "end" then
		endSession(self, state, initial.node.result)
		return table.freeze(self) :: Session, nil
	end

	local prepared = initial.prepared or prepareVisibleNode(definition, initial.nodeId)
	applyPreparedNode(state, prepared)
	local startMessage: Net.StartMessage = {
		version = Net.PROTOCOL_VERSION,
		type = "start",
		clientId = clientId,
		sessionId = sessionId,
		dialogueId = dialogueId,
		freezeCharacter = definition.freezeCharacter,
		presentation = prepared.presentation,
		choices = prepared.choices,
	}
	local sendResult = table.pack(pcall(Net._sendToClient, player, startMessage))
	if not sendResult[1] then
		warn(
			`[MrDialogue][SERVER_NETWORK_SEND_FAILED] Could not start dialogue "{dialogueId}" for {player.Name}: {safeToString(
				sendResult[2]
			)}`
		)
		cancelSession(self, state, "network_error", false)
		return table.freeze(self) :: Session, nil
	end
	state.clientStarted = true
	beginDeathMonitoring(self, state)
	armSessionTimeout(self, state)

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
		or #cancelReason > Net.Limits.maxReasonBytes
		or (cancelReason ~= "manual" and string.match(cancelReason, "^[%w_%-]+:[%w_.%-]+$") == nil)
	then
		error(
			`Session:Cancel reason must be "manual" or a namespaced string no longer than {Net.Limits.maxReasonBytes} bytes`,
			2
		)
	end

	local state = states[self]
	if not state or not state.active then
		return false
	end

	return cancelSession(self, state, cancelReason, true)
end

local function isExpectedTurn(state: SessionState, turn: any): boolean
	return state.expectedTurn ~= nil and state.expectedTurn == turn
end

local function handlePresentationCompleted(
	self: Session,
	state: SessionState,
	message: any
): boolean
	if state.phase ~= "WAITING_PRESENTATION" or not isExpectedTurn(state, message.turn) then
		return false
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

	return true
end

local function handleAdvance(self: Session, state: SessionState, message: any): boolean
	if
		(state.phase ~= "READY_TO_ADVANCE" and state.phase ~= "READY_TO_FINISH")
		or not isExpectedTurn(state, message.turn)
	then
		return false
	end

	local finishing = state.phase == "READY_TO_FINISH"
	local pendingNodeId = state.pendingNodeId
	local pendingEndResult = state.pendingEndResult
	beginResolving(state)

	if finishing then
		if pendingNodeId then
			moveToNode(self, state, pendingNodeId)
		else
			endSession(self, state, pendingEndResult)
		end
	elseif pendingNodeId then
		moveToNode(self, state, pendingNodeId)
	end

	return true
end

local function handleChoose(self: Session, state: SessionState, message: any): boolean
	if state.phase ~= "WAITING_CHOICE" or not isExpectedTurn(state, message.turn) then
		return false
	end

	local offeredOptions = state.offeredOptions
	local index = message.index
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
		return false
	end

	local option = if offeredOptions then offeredOptions[index] else nil
	if not option then
		return false
	end

	local nodeId = state.currentNodeId
	beginResolving(state)

	local stillAvailable = option.condition == nil
		or Conditions._evaluate(option.condition, makeContext(self, state))
	if not state.active then
		return true
	end

	if not stillAvailable then
		local node = state.definition.nodes[nodeId]
		if node.type == "choice" then
			offerChoices(self, state, nodeId, node)
		end
		return true
	end

	moveToNode(self, state, option.next)
	return true
end

local function isBoundedString(value: any, maximumBytes: number): boolean
	return type(value) == "string"
		and value ~= ""
		and #value <= maximumBytes
		and utf8.len(value) ~= nil
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local existingRate = messageRates[player]
	local rate: MessageRate
	if
		not existingRate
		or now - existingRate.windowStartedAt >= Net.Limits.messageWindowSeconds
	then
		rate = {
			windowStartedAt = now,
			count = 0,
			warned = false,
		}
		messageRates[player] = rate
	else
		rate = existingRate
	end

	rate.count += 1
	if rate.count <= Net.Limits.maxMessagesPerWindow then
		return false
	end

	if not rate.warned then
		rate.warned = true
		warn(
			`[MrDialogue][CLIENT_RATE_LIMITED] Ignoring excessive dialogue messages from {player.Name}`
		)
	end

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if self and state and state.active then
		cancelSession(self, state, "rate_limited", true)
	end

	return true
end

local function handleClientMessage(player: Player, message: any)
	if isRateLimited(player) then
		return
	end
	if type(message) ~= "table" then
		return
	end
	if
		message.version ~= Net.PROTOCOL_VERSION
		or not isBoundedString(message.type, Net.Limits.maxIdBytes)
		or not isBoundedString(message.clientId, Net.Limits.maxIdBytes)
	then
		return
	end

	if message.type == "client_ready" then
		local clientId = message.clientId
		if clientReadyPlayers[player] == clientId then
			return
		end

		-- End the stale runtime before listeners can start another session.
		clientReadyPlayers[player] = clientId
		local existingSession = activeSessions[player]
		local existingState = if existingSession then states[existingSession] else nil
		if existingSession and existingState and existingState.active then
			cancelSession(existingSession, existingState, "client_restarted", true)
		end
		return
	elseif message.type == "client_stopped" then
		if clientReadyPlayers[player] ~= message.clientId then
			return
		end

		clientReadyPlayers[player] = nil
		local stoppedSession = activeSessions[player]
		local stoppedState = if stoppedSession then states[stoppedSession] else nil
		if
			stoppedSession
			and stoppedState
			and stoppedState.active
			and stoppedState.clientId == message.clientId
		then
			cancelSession(stoppedSession, stoppedState, "client_cancelled", true)
		end
		return
	end

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if
		not self
		or not state
		or not state.active
		or message.clientId ~= state.clientId
		or not isBoundedString(message.sessionId, Net.Limits.maxIdBytes)
		or message.sessionId ~= state.sessionId
	then
		return
	end

	local accepted = false
	if message.type == "cancel" then
		accepted = true
		cancelSession(self, state, "client_cancelled", true)
	elseif message.type == "client_error" then
		accepted = true
		cancelSession(self, state, "client_error", true)
	elseif message.type == "presentation_completed" then
		if isBoundedString(message.turn, Net.Limits.maxIdBytes) then
			accepted = handlePresentationCompleted(self, state, message)
		end
	elseif message.type == "advance" then
		if isBoundedString(message.turn, Net.Limits.maxIdBytes) then
			accepted = handleAdvance(self, state, message)
		end
	elseif message.type == "choose" then
		if isBoundedString(message.turn, Net.Limits.maxIdBytes) then
			accepted = handleChoose(self, state, message)
		end
	end

	if accepted and state.active then
		armSessionTimeout(self, state)
	end
end

function Session._end(self: Session, outcome: Types.SessionOutcome, notifyClient: boolean): boolean
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
	clearSessionTimeout(state)
	disconnectDeathMonitoring(state)

	if activeSessions[self.Player] == self then
		activeSessions[self.Player] = nil
	end

	if notifyClient then
		local sendResult = table.pack(pcall(sendOutcome, self, state, outcome))
		if not sendResult[1] then
			warn(
				`[MrDialogue][SERVER_NETWORK_SEND_FAILED] Could not send the final outcome for dialogue "{self.DialogueId}": {safeToString(
					sendResult[2]
				)}`
			)
		end
	end

	state.endedEvent:Fire(outcome)
	return true
end

Net._connectServer(handleClientMessage)

Players.PlayerRemoving:Connect(function(player)
	clientReadyPlayers[player] = nil
	messageRates[player] = nil

	local self = activeSessions[player]
	local state = if self then states[self] else nil
	if self and state and state.active then
		cancelSession(self, state, "player_left", false)
	end
end)

return table.freeze(Session)
