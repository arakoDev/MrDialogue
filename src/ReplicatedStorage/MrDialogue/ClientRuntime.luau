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

--[[
	The seam between the runtime and whatever draws the dialogue. Each callback is handed the only
	actions that make sense at that moment, and each of those is single-use: an adapter cannot
	advance twice, choose after choosing, or reply to a step the server has moved past.
]]
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

-- Mirrors the server's turn rule locally so a late callback from a stale UI element is ignored
-- before it ever reaches the wire. The server checks it again regardless.
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

--[[
	Advancing and finishing are the same intent on the wire: the server knows from its own state
	whether the next click continues the conversation or closes it. The client only reports the
	click, which keeps it from ending a Session the server is not finished with.
]]
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
	-- A start carries exactly one opening payload: a line to read or options to pick from.
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

	-- Once a cancel is on its way, the only message still worth acting on is the ending itself.
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

	return table.freeze(self) :: ClientRuntime
end

function ClientRuntime.IsActive(self: ClientRuntime): boolean
	local state = states[self]
	return state ~= nil and not state.stopped and state.sessionId ~= nil
end

-- Locks input straight away but leaves the outcome to the server, which still sends the ending.
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

	if sessionId then
		-- Local teardown cannot wait for the server's answer, so this ending is flagged as the
		-- guess it is; the server still closes the Session on its own terms.
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
