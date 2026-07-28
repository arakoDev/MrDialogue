--!strict

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

export type PresentationInfo = {
	kind: "line" | "choice_prompt",
	speaker: Net.SpeakerPayload?,
	text: string,
}

export type EndOutcome = {
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
	authoritative: boolean,
}

-- Action callbacks only work for the state that created them.
export type Adapter = {
	OnShow: (self: Adapter, info: ShowInfo) -> (),
	OnPresentation: (
		self: Adapter,
		presentation: PresentationInfo,
		actions: PresentationActions
	) -> (),
	OnAdvanceReady: (self: Adapter, actions: AdvanceActions) -> (),
	OnFinishReady: (self: Adapter, actions: FinishActions) -> (),
	OnChoices: (
		self: Adapter,
		options: { Net.ChoiceOptionPayload },
		actions: ChoiceActions
	) -> (),
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
	connection: RBXScriptConnection?,
	phase: ClientPhase,
	sessionId: string?,
	turn: string?,
	cancelSent: boolean,
	stopped: boolean,
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
		error("MrDialogue.Client.Start requires an adapter", 4)
	end

	for _, methodName in ipairs(ADAPTER_METHODS) do
		if type(adapter[methodName]) ~= "function" then
			error(`MrDialogue.Client.Start adapter must implement {methodName}`, 4)
		end
	end
end

-- Ignore callbacks left over from an earlier UI state.
local function isCurrent(
	state: ClientRuntimeState,
	sessionId: string,
	phase: ClientPhase,
	turn: string
): boolean
	return state.sessionId == sessionId and state.phase == phase and state.turn == turn
end

local function showPresentation(state: ClientRuntimeState, presentation: Net.PresentationPayload)
	local sessionId = state.sessionId
	if not sessionId then
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
			Net._sendToServer({
				type = "presentation_completed",
				sessionId = sessionId,
				turn = turn,
			})
		end,
	}

	state.adapter:OnPresentation({
		kind = presentation.kind,
		speaker = presentation.speaker,
		text = presentation.text,
	}, actions)
end

local function showChoices(state: ClientRuntimeState, choices: Net.ChoicesPayload)
	local sessionId = state.sessionId
	if not sessionId then
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
			Net._sendToServer({
				type = "choose",
				sessionId = sessionId,
				turn = turn,
				index = index,
			})
		end,
	}

	state.adapter:OnChoices(choices.options, actions)
end

-- The server decides whether this click advances or finishes.
local function showReady(state: ClientRuntimeState, message: Net.ReadyMessage)
	local sessionId = state.sessionId
	if not sessionId or state.phase ~= "WAITING_SERVER" then
		return
	end

	local turn = message.turn
	local phase: ClientPhase = if message.interaction == "advance"
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
		Net._sendToServer({
			type = "advance",
			sessionId = sessionId,
			turn = turn,
		})
	end

	if phase == "READY_TO_ADVANCE" then
		state.adapter:OnAdvanceReady({ advance = send })
	else
		state.adapter:OnFinishReady({ finish = send })
	end
end

local function handleStart(state: ClientRuntimeState, message: Net.StartMessage)
	if state.stopped or state.sessionId ~= nil then
		return
	end

	local presentation = message.presentation
	local choices = message.choices
	if (presentation == nil) == (choices == nil) then
		return
	end

	state.sessionId = message.sessionId
	state.cancelSent = false
	state.adapter:OnShow({
		dialogueId = message.dialogueId,
		freezeCharacter = message.freezeCharacter,
	})

	if presentation then
		showPresentation(state, presentation)
	elseif choices then
		showChoices(state, choices)
	end
end

local function handleEnd(state: ClientRuntimeState, message: Net.EndMessage)
	state.phase = "IDLE"
	state.sessionId = nil
	state.turn = nil
	state.cancelSent = false

	state.adapter:OnEnd({
		status = message.status,
		result = message.result,
		reason = message.reason,
		authoritative = true,
	})
end

local function handleMessage(state: ClientRuntimeState, message: Net.ServerMessage)
	if message.type == "start" then
		handleStart(state, message)
		return
	end

	if state.sessionId == nil or message.sessionId ~= state.sessionId then
		return
	end

	-- After cancelling, only the final outcome matters.
	if state.cancelSent then
		if message.type == "end" then
			handleEnd(state, message)
		end
		return
	end

	if message.type == "present" then
		if state.phase == "WAITING_SERVER" then
			showPresentation(state, {
				turn = message.turn,
				kind = message.kind,
				speaker = message.speaker,
				text = message.text,
			})
		end
	elseif message.type == "choices" then
		if state.phase == "WAITING_SERVER" then
			showChoices(state, {
				turn = message.turn,
				options = message.options,
			})
		end
	elseif message.type == "ready" then
		showReady(state, message)
	elseif message.type == "end" then
		handleEnd(state, message)
	end
end

function ClientRuntime.new(adapter: any): ClientRuntime
	validateAdapter(adapter)

	local self = setmetatable({}, ClientRuntime) :: any
	local state: ClientRuntimeState = {
		adapter = adapter,
		phase = "IDLE",
		cancelSent = false,
		stopped = false,
	}
	states[self] = state

	state.connection = Net._connectClient(function(message: Net.ServerMessage)
		if not state.stopped then
			handleMessage(state, message)
		end
	end)
	Net._sendToServer({
		type = "client_ready",
	})

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
	Net._sendToServer({
		type = "cancel",
		sessionId = sessionId,
	})

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
		Net._sendToServer({
			type = "cancel",
			sessionId = sessionId,
		})
	end
	Net._sendToServer({
		type = "client_stopped",
	})

	if sessionId then
		-- Stop cannot wait for a server response, so this outcome is explicitly local.
		local cleaned, cleanupError = pcall(function()
			state.adapter:OnEnd({
				status = "cancelled",
				reason = "client_shutdown",
				authoritative = false,
			})
		end)
		if not cleaned then
			warn(`[MrDialogue][ADAPTER_END_FAILED] {tostring(cleanupError)}`)
		end
	end

	if connection then
		connection:Disconnect()
	end

	return true
end

return table.freeze(ClientRuntime)
