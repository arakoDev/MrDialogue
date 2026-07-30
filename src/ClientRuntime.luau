--!strict

local HttpService = game:GetService("HttpService")

local Net = require(script.Parent.Net)

local ClientRuntime = {}
ClientRuntime.__index = ClientRuntime

export type PresentationActions = {
	presentationCompleted: () -> (),
}

export type AdvanceActions = {
	advance: () -> (),
}

export type FinishActions = {
	finish: () -> (),
}

export type ChoiceActions = {
	choose: (index: number) -> (),
}

export type ShowInfo = {
	dialogueId: string,
	freezeCharacter: boolean?,
}

export type SpeakerInfo = {
	name: string,
	icon: string?,
}

export type PresentationInfo = {
	kind: "line" | "choice_prompt",
	speaker: SpeakerInfo?,
	text: string,
}

export type ChoiceInfo = {
	text: string,
}

export type EndOutcome = {
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
	authoritative: boolean,
}

export type Adapter = {
	OnShow: (self: Adapter, info: ShowInfo) -> (),
	OnPresentation: (
		self: Adapter,
		presentation: PresentationInfo,
		actions: PresentationActions
	) -> (),
	OnAdvanceReady: (self: Adapter, actions: AdvanceActions) -> (),
	OnFinishReady: (self: Adapter, actions: FinishActions) -> (),
	OnChoices: (self: Adapter, options: { ChoiceInfo }, actions: ChoiceActions) -> (),
	OnEnd: (self: Adapter, outcome: EndOutcome) -> (),
}

export type ClientRuntime = {
	IsActive: (self: ClientRuntime) -> boolean,
}

type ClientPhase =
	"IDLE"
	| "WAITING_PRESENTATION"
	| "WAITING_SERVER"
	| "READY_TO_ADVANCE"
	| "READY_TO_FINISH"
	| "WAITING_CHOICE"

type ClientRuntimeState = {
	adapter: Adapter,
	clientId: string,
	connection: RBXScriptConnection?,
	phase: ClientPhase,
	sessionId: string?,
	turn: string?,
	cancelSent: boolean,
	stopped: boolean,
}

type NormalizedPresentation = PresentationInfo & {
	turn: string,
}

type NormalizedChoices = {
	turn: string,
	options: { ChoiceInfo },
}

local states: { [ClientRuntime]: ClientRuntimeState } = setmetatable({}, { __mode = "k" }) :: any

local ADAPTER_METHODS = {
	"OnShow",
	"OnPresentation",
	"OnAdvanceReady",
	"OnFinishReady",
	"OnChoices",
	"OnEnd",
}

local function validateAdapter(adapter: any)
	if type(adapter) ~= "table" then
		error("MrDialogue.Start config.adapter must be an Adapter", 4)
	end

	for _, methodName in ipairs(ADAPTER_METHODS) do
		if type(adapter[methodName]) ~= "function" then
			error(`MrDialogue.Start config.adapter must implement {methodName}`, 4)
		end
	end
end

local function isBoundedString(value: any, maximumBytes: number, allowEmpty: boolean): boolean
	return type(value) == "string"
		and (allowEmpty or value ~= "")
		and #value <= maximumBytes
		and utf8.len(value) ~= nil
end

local function normalizeSpeaker(value: any): (boolean, SpeakerInfo?)
	if value == nil then
		return true, nil
	end
	if type(value) ~= "table" then
		return false, nil
	end

	local name = value.name
	local icon = value.icon
	if not isBoundedString(name, Net.Limits.maxSpeakerNameBytes, true) then
		return false, nil
	end
	if icon ~= nil and not isBoundedString(icon, Net.Limits.maxIconBytes, true) then
		return false, nil
	end

	return true, {
		name = name,
		icon = icon,
	}
end

local function normalizePresentation(value: any): NormalizedPresentation?
	if type(value) ~= "table" then
		return nil
	end

	local turn = value.turn
	local kind = value.kind
	local text = value.text
	if not isBoundedString(turn, Net.Limits.maxIdBytes, false) then
		return nil
	end
	if kind ~= "line" and kind ~= "choice_prompt" then
		return nil
	end
	if not isBoundedString(text, Net.Limits.maxTextBytes, true) then
		return nil
	end

	local speakerIsValid, speaker = normalizeSpeaker(value.speaker)
	if not speakerIsValid then
		return nil
	end

	return {
		turn = turn,
		kind = kind,
		speaker = speaker,
		text = text,
	}
end

local function normalizeChoiceOptions(value: any): { ChoiceInfo }?
	if type(value) ~= "table" then
		return nil
	end

	local count = 0
	for index in pairs(value) do
		if
			type(index) ~= "number"
			or index % 1 ~= 0
			or index < 1
			or index > Net.Limits.maxChoices
		then
			return nil
		end
		count += 1
	end
	if count < 1 or count > Net.Limits.maxChoices then
		return nil
	end

	local normalized = {}
	for index = 1, count do
		local option = value[index]
		if
			type(option) ~= "table"
			or not isBoundedString(option.text, Net.Limits.maxTextBytes, true)
		then
			return nil
		end
		table.insert(normalized, {
			text = option.text,
		})
	end

	return normalized
end

local function normalizeChoices(value: any): NormalizedChoices?
	if type(value) ~= "table" then
		return nil
	end

	local turn = value.turn
	if not isBoundedString(turn, Net.Limits.maxIdBytes, false) then
		return nil
	end

	local options = normalizeChoiceOptions(value.options)
	if not options then
		return nil
	end

	return {
		turn = turn,
		options = options,
	}
end

local function normalizeOptionalString(value: any, maximumBytes: number): (boolean, string?)
	if value == nil then
		return true, nil
	end
	if not isBoundedString(value, maximumBytes, true) then
		return false, nil
	end
	return true, value
end

local function safeToString(value: any): string
	local result = table.pack(pcall(tostring, value))
	if result[1] and type(result[2]) == "string" then
		return result[2] :: string
	end
	return "<unprintable value>"
end

local function reportAdapterFailure(methodName: string, code: string, detail: any)
	warn(`[MrDialogue][{code}] Adapter.{methodName} failed: {safeToString(detail)}`)
end

-- Adapter callbacks must not yield.
local function invokeAdapter(
	state: ClientRuntimeState,
	methodName: string,
	...: any
): (boolean, string?, any?)
	local arguments = table.pack(...)
	local thread = coroutine.create(function()
		local method = (state.adapter :: any)[methodName]
		method(state.adapter, table.unpack(arguments, 1, arguments.n))
	end)
	local resumed = table.pack(coroutine.resume(thread))

	if not resumed[1] then
		return false, "CLIENT_ADAPTER_CALLBACK_THROWN", resumed[2]
	end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, "CLIENT_ADAPTER_CALLBACK_YIELDED", "adapter callbacks must not yield"
	end

	return true, nil, nil
end

local function sendToServer(state: ClientRuntimeState, message: any): boolean
	message.clientId = state.clientId

	local sendResult = table.pack(pcall(Net._sendToServer, message))
	local sent = sendResult[1] == true

	if not sent then
		warn(`[MrDialogue][CLIENT_NETWORK_SEND_FAILED] {safeToString(sendResult[2])}`)
	end

	return sent
end

local function clearActiveState(state: ClientRuntimeState)
	state.phase = "IDLE"
	state.sessionId = nil
	state.turn = nil
	state.cancelSent = false
end

local function notifyLocalEnd(state: ClientRuntimeState, reason: string)
	local succeeded, code, detail = invokeAdapter(state, "OnEnd", {
		status = "cancelled",
		reason = reason,
		authoritative = false,
	})
	if not succeeded then
		reportAdapterFailure("OnEnd", code :: string, detail)
	end
end

local function endActiveLocally(
	state: ClientRuntimeState,
	reason: string,
	reportClientError: boolean
)
	local sessionId = state.sessionId
	if not sessionId then
		return
	end

	clearActiveState(state)

	if reportClientError then
		sendToServer(state, {
			version = Net.PROTOCOL_VERSION,
			type = "client_error",
			sessionId = sessionId,
		})
	end

	notifyLocalEnd(state, reason)
end

local function invokeActiveAdapter(state: ClientRuntimeState, methodName: string, ...: any): boolean
	local succeeded, code, detail = invokeAdapter(state, methodName, ...)
	if succeeded then
		return true
	end

	reportAdapterFailure(methodName, code :: string, detail)
	endActiveLocally(state, "client_error", true)
	return false
end

local function failProtocol(state: ClientRuntimeState, detail: string)
	warn(`[MrDialogue][CLIENT_PROTOCOL_ERROR] {detail}`)
	endActiveLocally(state, "client_error", true)
end

local function isCurrent(
	state: ClientRuntimeState,
	sessionId: string,
	phase: ClientPhase,
	turn: string
): boolean
	return not state.stopped
		and not state.cancelSent
		and state.sessionId == sessionId
		and state.phase == phase
		and state.turn == turn
end

local function showPresentation(state: ClientRuntimeState, presentation: NormalizedPresentation)
	local sessionId = state.sessionId
	if not sessionId or state.stopped or state.cancelSent then
		return
	end

	local turn = presentation.turn
	state.phase = "WAITING_PRESENTATION"
	state.turn = turn

	local actions: PresentationActions = {
		presentationCompleted = function()
			if not isCurrent(state, sessionId, "WAITING_PRESENTATION", turn) then
				return
			end

			state.phase = "WAITING_SERVER"
			state.turn = nil
			if
				not sendToServer(state, {
					version = Net.PROTOCOL_VERSION,
					type = "presentation_completed",
					sessionId = sessionId,
					turn = turn,
				})
			then
				endActiveLocally(state, "client_error", false)
			end
		end,
	}

	invokeActiveAdapter(state, "OnPresentation", {
		kind = presentation.kind,
		speaker = presentation.speaker,
		text = presentation.text,
	}, actions)
end

local function showChoices(state: ClientRuntimeState, choices: NormalizedChoices)
	local sessionId = state.sessionId
	if not sessionId or state.stopped or state.cancelSent then
		return
	end

	local turn = choices.turn
	local optionCount = #choices.options
	state.phase = "WAITING_CHOICE"
	state.turn = turn

	local actions: ChoiceActions = {
		choose = function(index: number)
			if
				not isCurrent(state, sessionId, "WAITING_CHOICE", turn)
				or type(index) ~= "number"
				or index % 1 ~= 0
				or index < 1
				or index > optionCount
			then
				return
			end

			state.phase = "WAITING_SERVER"
			state.turn = nil
			if
				not sendToServer(state, {
					version = Net.PROTOCOL_VERSION,
					type = "choose",
					sessionId = sessionId,
					turn = turn,
					index = index,
				})
			then
				endActiveLocally(state, "client_error", false)
			end
		end,
	}

	invokeActiveAdapter(state, "OnChoices", choices.options, actions)
end

local function showReady(state: ClientRuntimeState, turn: string, interaction: "advance" | "finish")
	local sessionId = state.sessionId
	if not sessionId or state.phase ~= "WAITING_SERVER" then
		return
	end

	local phase: ClientPhase = if interaction == "advance"
		then "READY_TO_ADVANCE"
		else "READY_TO_FINISH"
	state.phase = phase
	state.turn = turn

	local function send()
		if not isCurrent(state, sessionId, phase, turn) then
			return
		end

		state.phase = "WAITING_SERVER"
		state.turn = nil
		if
			not sendToServer(state, {
				version = Net.PROTOCOL_VERSION,
				type = "advance",
				sessionId = sessionId,
				turn = turn,
			})
		then
			endActiveLocally(state, "client_error", false)
		end
	end

	if phase == "READY_TO_ADVANCE" then
		invokeActiveAdapter(state, "OnAdvanceReady", { advance = send })
	else
		invokeActiveAdapter(state, "OnFinishReady", { finish = send })
	end
end

local function rejectStart(
	state: ClientRuntimeState,
	sessionId: string,
	code: string,
	detail: string
)
	warn(`[MrDialogue][{code}] {detail}`)
	sendToServer(state, {
		version = Net.PROTOCOL_VERSION,
		type = "client_error",
		sessionId = sessionId,
	})
end

local function handleStart(state: ClientRuntimeState, message: any)
	local sessionId = message.sessionId
	if not isBoundedString(sessionId, Net.Limits.maxIdBytes, false) then
		warn("[MrDialogue][CLIENT_PROTOCOL_ERROR] Ignored start with an invalid session ID")
		return
	end

	local activeSessionId = state.sessionId
	if activeSessionId ~= nil then
		if sessionId ~= activeSessionId then
			rejectStart(
				state,
				sessionId,
				"CLIENT_SESSION_CONFLICT",
				"rejected a second session while another was active"
			)
		end
		return
	end
	if state.stopped then
		return
	end

	local dialogueId = message.dialogueId
	local freezeCharacter = message.freezeCharacter
	local presentationValue = message.presentation
	local choicesValue = message.choices
	if
		not isBoundedString(dialogueId, Net.Limits.maxIdBytes, false)
		or (freezeCharacter ~= nil and type(freezeCharacter) ~= "boolean")
		or (presentationValue == nil) == (choicesValue == nil)
	then
		rejectStart(state, sessionId, "CLIENT_PROTOCOL_ERROR", "rejected a malformed start message")
		return
	end

	local presentation = if presentationValue ~= nil
		then normalizePresentation(presentationValue)
		else nil
	local choices = if choicesValue ~= nil then normalizeChoices(choicesValue) else nil
	if
		(presentationValue ~= nil and presentation == nil)
		or (choicesValue ~= nil and choices == nil)
	then
		rejectStart(
			state,
			sessionId,
			"CLIENT_PROTOCOL_ERROR",
			"rejected a start message with an invalid payload"
		)
		return
	end

	state.sessionId = sessionId
	state.cancelSent = false
	if
		not invokeActiveAdapter(state, "OnShow", {
			dialogueId = dialogueId,
			freezeCharacter = freezeCharacter,
		})
	then
		return
	end

	if state.sessionId ~= sessionId or state.cancelSent or state.stopped then
		return
	end

	if presentation then
		showPresentation(state, presentation)
	elseif choices then
		showChoices(state, choices)
	end
end

local function handleEnd(state: ClientRuntimeState, message: any)
	local status = message.status
	if status ~= "completed" and status ~= "cancelled" then
		failProtocol(state, "received an end message with an invalid status")
		return
	end

	local resultIsValid, result = normalizeOptionalString(message.result, Net.Limits.maxResultBytes)
	local reasonIsValid, reason = normalizeOptionalString(message.reason, Net.Limits.maxReasonBytes)
	if not resultIsValid or not reasonIsValid then
		failProtocol(state, "received an end message with an invalid outcome")
		return
	end

	clearActiveState(state)
	local succeeded, code, detail = invokeAdapter(state, "OnEnd", {
		status = status,
		result = result,
		reason = reason,
		authoritative = true,
	})
	if not succeeded then
		reportAdapterFailure("OnEnd", code :: string, detail)
	end
end

local function handleMessage(state: ClientRuntimeState, message: any)
	if type(message) ~= "table" then
		warn("[MrDialogue][CLIENT_PROTOCOL_ERROR] Ignored a non-table server message")
		return
	end
	if message.clientId ~= state.clientId then
		return
	end
	if message.version ~= Net.PROTOCOL_VERSION then
		if message.sessionId == state.sessionId and state.sessionId ~= nil then
			failProtocol(state, "received a message with an incompatible protocol version")
		end
		return
	end

	if message.type == "start" then
		handleStart(state, message)
		return
	end

	local sessionId = state.sessionId
	if sessionId == nil or message.sessionId ~= sessionId then
		return
	end

	if state.cancelSent then
		if message.type == "end" then
			handleEnd(state, message)
		end
		return
	end

	if message.type == "present" then
		if state.phase ~= "WAITING_SERVER" then
			return
		end

		local presentation = normalizePresentation(message)
		if presentation then
			showPresentation(state, presentation)
		else
			failProtocol(state, "received an invalid presentation")
		end
	elseif message.type == "choices" then
		if state.phase ~= "WAITING_SERVER" then
			return
		end

		local choices = normalizeChoices(message)
		if choices then
			showChoices(state, choices)
		else
			failProtocol(state, "received an invalid choice offer")
		end
	elseif message.type == "ready" then
		if state.phase ~= "WAITING_SERVER" then
			return
		end

		local turn = message.turn
		local interaction = message.interaction
		if
			not isBoundedString(turn, Net.Limits.maxIdBytes, false)
			or (interaction ~= "advance" and interaction ~= "finish")
		then
			failProtocol(state, "received an invalid ready message")
			return
		end
		showReady(state, turn, interaction)
	elseif message.type == "end" then
		handleEnd(state, message)
	else
		failProtocol(state, "received an unknown message type for the active session")
	end
end

function ClientRuntime.new(adapter: any): ClientRuntime
	validateAdapter(adapter)

	local self = setmetatable({}, ClientRuntime) :: any
	local state: ClientRuntimeState = {
		adapter = adapter,
		clientId = HttpService:GenerateGUID(false),
		phase = "IDLE",
		cancelSent = false,
		stopped = false,
	}
	states[self] = state

	state.connection = Net._connectClient(function(message: any)
		if state.stopped then
			return
		end

		local handleResult = table.pack(pcall(handleMessage, state, message))
		local handled = handleResult[1]
		if not handled then
			warn(`[MrDialogue][CLIENT_RUNTIME_ERROR] {safeToString(handleResult[2])}`)
			endActiveLocally(state, "client_error", true)
		end
	end)

	if not sendToServer(state, {
		version = Net.PROTOCOL_VERSION,
		type = "client_ready",
	}) then
		local connection = state.connection
		state.connection = nil
		state.stopped = true
		if connection then
			connection:Disconnect()
		end
		error("[MrDialogue][CLIENT_READY_FAILED] Could not notify the server", 2)
	end

	return table.freeze(self) :: ClientRuntime
end

function ClientRuntime.IsActive(self: ClientRuntime): boolean
	local state = states[self]
	return state ~= nil and not state.stopped and state.sessionId ~= nil
end

function ClientRuntime._cancelActiveSession(self: ClientRuntime): boolean
	local state = states[self]
	if not state or state.stopped or state.cancelSent then
		return false
	end

	local sessionId = state.sessionId
	if not sessionId then
		return false
	end

	state.phase = "WAITING_SERVER"
	state.turn = nil
	state.cancelSent = true
	if
		not sendToServer(state, {
			version = Net.PROTOCOL_VERSION,
			type = "cancel",
			sessionId = sessionId,
		})
	then
		clearActiveState(state)
		notifyLocalEnd(state, "client_error")
		return false
	end

	return true
end

function ClientRuntime._stop(self: ClientRuntime): boolean
	local state = states[self]
	if not state or state.stopped then
		return false
	end

	local sessionId = state.sessionId
	local shouldSendCancel = sessionId ~= nil and not state.cancelSent
	local connection = state.connection
	state.stopped = true
	state.connection = nil
	state.phase = "IDLE"
	state.sessionId = nil
	state.turn = nil
	state.cancelSent = true

	if shouldSendCancel and sessionId then
		sendToServer(state, {
			version = Net.PROTOCOL_VERSION,
			type = "cancel",
			sessionId = sessionId,
		})
	end
	sendToServer(state, {
		version = Net.PROTOCOL_VERSION,
		type = "client_stopped",
	})

	if sessionId then
		local succeeded, code, detail = invokeAdapter(state, "OnEnd", {
			status = "cancelled",
			reason = "client_shutdown",
			authoritative = false,
		})
		if not succeeded then
			reportAdapterFailure("OnEnd", code :: string, detail)
		end
	end

	if connection then
		connection:Disconnect()
	end

	return true
end

return table.freeze(ClientRuntime)
