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
			if
				state.sessionId ~= sessionId
				or state.phase ~= "WAITING_PRESENTATION"
				or state.turn ~= turn
			then
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

	local presentationInfo: PresentationInfo = {
		kind = presentation.kind,
		speaker = presentation.speaker,
		text = presentation.text,
	}

	state.adapter:OnPresentation(presentationInfo, actions)
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
				state.sessionId ~= sessionId
				or state.phase ~= "WAITING_CHOICE"
				or state.turn ~= turn
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

local function showReady(state: ClientRuntimeState, message: Net.ReadyMessage)
	local sessionId = state.sessionId
	if not sessionId or state.phase ~= "WAITING_SERVER" then
		return
	end

	local turn = message.turn
	state.turn = turn

	if message.interaction == "advance" then
		state.phase = "READY_TO_ADVANCE"

		local actions: AdvanceActions = {
			advance = function()
				if not isCurrent(state, sessionId, "READY_TO_ADVANCE", turn) then
					return
				end

				state.phase = "WAITING_SERVER"
				state.turn = nil

				Net._sendToServer({
					type = "advance",
					sessionId = sessionId,
					turn = turn,
				})
			end,
		}

		state.adapter:OnAdvanceReady(actions)
	else
		state.phase = "READY_TO_FINISH"

		local actions: FinishActions = {
			finish = function()
				if not isCurrent(state, sessionId, "READY_TO_FINISH", turn) then
					return
				end

				state.phase = "WAITING_SERVER"
				state.turn = nil

				Net._sendToServer({
					type = "advance",
					sessionId = sessionId,
					turn = turn,
				})
			end,
		}

		state.adapter:OnFinishReady(actions)
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
	if message.freezeCharacter ~= nil and type(message.freezeCharacter) ~= "boolean" then
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
	local outcome: EndOutcome
	if message.status == "cancelled" then
		local reason = message.reason
		if type(reason) ~= "string" or reason == "" then
			return
		end
		outcome = {
			status = "cancelled",
			reason = reason,
			authoritative = true,
		}
	else
		outcome = {
			status = "completed",
			result = message.result,
			authoritative = true,
		}
	end

	state.phase = "IDLE"
	state.sessionId = nil
	state.turn = nil
	state.cancelSent = false

	state.adapter:OnEnd(outcome)
end

local function handleMessage(state: ClientRuntimeState, message: Net.ServerMessage)
	if message.type == "start" then
		handleStart(state, message)
		return
	end

	if state.sessionId == nil or message.sessionId ~= state.sessionId then
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

		showPresentation(state, {
			turn = message.turn,
			kind = message.kind,
			speaker = message.speaker,
			text = message.text,
		})
	elseif message.type == "choices" then
		if state.phase ~= "WAITING_SERVER" then
			return
		end

		showChoices(state, {
			turn = message.turn,
			options = message.options,
		})
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
		connection = nil,
		phase = "IDLE",
		sessionId = nil,
		turn = nil,
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

function ClientRuntime._cancelActiveSession(self: ClientRuntime): boolean
	local state = states[self]
	if not state or state.stopped or state.sessionId == nil or state.cancelSent then
		return false
	end

	local sessionId = state.sessionId
	local previousPhase: ClientPhase = state.phase
	local previousTurn: string? = state.turn
	state.phase = "WAITING_SERVER"
	state.turn = nil
	state.cancelSent = true

	local sent, sendError = pcall(function()
		Net._sendToServer({
			type = "cancel",
			sessionId = sessionId,
		})
	end)
	if not sent then
		if state.sessionId == sessionId and not state.stopped then
			state.phase = previousPhase
			state.turn = previousTurn
			state.cancelSent = false
		end
		error(sendError, 2)
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
		local sent, sendError = pcall(function()
			Net._sendToServer({
				type = "cancel",
				sessionId = sessionId,
			})
		end)
		if not sent then
			warn(`[MrDialogue][CLIENT_CANCEL_SEND_FAILED] {tostring(sendError)}`)
		end
	end

	if sessionId then
		local outcome: EndOutcome = {
			status = "cancelled",
			reason = "client_shutdown",
			authoritative = false,
		}
		local cleaned, cleanupError = pcall(function()
			state.adapter:OnEnd(outcome)
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
