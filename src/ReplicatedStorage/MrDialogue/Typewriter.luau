--!strict

local RunService = game:GetService("RunService")

local DEFAULT_CHARS_PER_SECOND = 30
local DEFAULT_PUNCTUATION_PAUSE = 0.15

local PUNCTUATION: { [string]: boolean } = {
	[","] = true,
	["."] = true,
	["!"] = true,
	["?"] = true,
	[";"] = true,
	[":"] = true,
}

table.freeze(PUNCTUATION)

local Typewriter = {}
Typewriter.__index = Typewriter

export type CompletionOutcome = "natural" | "skipped" | "cancelled"

export type TypewriterConfig = {
	charsPerSecond: number?,
	punctuationPause: number?,
}

export type Typewriter = {
	Completed: RBXScriptSignal,
	GraphemeRevealed: RBXScriptSignal,
	Play: (self: Typewriter, text: string, config: TypewriterConfig?) -> number,
	Skip: (self: Typewriter) -> (),
	Cancel: (self: Typewriter) -> (),
	IsPlaying: (self: Typewriter) -> boolean,
	Destroy: (self: Typewriter) -> (),
}

type Run = {
	id: number,
	completed: boolean,
	connection: RBXScriptConnection?,
	graphemes: { string },
	visibleGraphemes: number,
	elapsed: number,
	nextDelay: number,
	charsPerSecond: number,
	punctuationPause: number,
}

type TypewriterState = {
	label: TextLabel,
	completedEvent: BindableEvent,
	graphemeRevealedEvent: BindableEvent,
	nextRunId: number,
	currentRun: Run?,
	destroyed: boolean,
}

local states: { [Typewriter]: TypewriterState } = setmetatable({}, { __mode = "k" }) :: any

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function readConfig(config: TypewriterConfig?): (number, number)
	if config ~= nil and type(config) ~= "table" then
		error("TYPEWRITER_INVALID_CONFIG: config must be a table", 3)
	end

	local charsPerSecond = if config then config.charsPerSecond else nil
	local punctuationPause = if config then config.punctuationPause else nil

	if charsPerSecond == nil then
		charsPerSecond = DEFAULT_CHARS_PER_SECOND
	elseif
		type(charsPerSecond) ~= "number"
		or not isFinite(charsPerSecond)
		or charsPerSecond <= 0
	then
		error("TYPEWRITER_INVALID_CONFIG: charsPerSecond must be a positive finite number", 3)
	end

	if punctuationPause == nil then
		punctuationPause = DEFAULT_PUNCTUATION_PAUSE
	elseif
		type(punctuationPause) ~= "number"
		or not isFinite(punctuationPause)
		or punctuationPause < 0
	then
		error("TYPEWRITER_INVALID_CONFIG: punctuationPause must be a non-negative finite number", 3)
	end

	return charsPerSecond :: number, punctuationPause :: number
end

local function getGraphemes(text: string): { string }
	local graphemes = {}
	for first, last in utf8.graphemes(text) do
		table.insert(graphemes, string.sub(text, first, last))
	end
	return graphemes
end

local function isCurrentRun(state: TypewriterState, run: Run): boolean
	return not state.destroyed and state.currentRun == run and not run.completed
end

local function finishRun(
	state: TypewriterState,
	run: Run,
	outcome: CompletionOutcome,
	revealAll: boolean
)
	if run.completed then
		return
	end

	run.completed = true
	if run.connection then
		run.connection:Disconnect()
		run.connection = nil
	end

	if state.currentRun == run then
		if revealAll then
			state.label.MaxVisibleGraphemes = -1
		end
		state.currentRun = nil
	end

	state.completedEvent:Fire(run.id, outcome)
end

local function startHeartbeat(state: TypewriterState, run: Run)
	run.connection = RunService.Heartbeat:Connect(function(deltaTime)
		if not isCurrentRun(state, run) then
			return
		end

		run.elapsed += deltaTime
		while run.elapsed >= run.nextDelay do
			if not isCurrentRun(state, run) then
				return
			end

			run.elapsed -= run.nextDelay
			run.visibleGraphemes += 1
			state.label.MaxVisibleGraphemes = run.visibleGraphemes

			if not isCurrentRun(state, run) then
				return
			end
			state.graphemeRevealedEvent:Fire(run.id, run.visibleGraphemes)

			if not isCurrentRun(state, run) then
				return
			end
			if run.visibleGraphemes >= #run.graphemes then
				finishRun(state, run, "natural", true)
				return
			end

			local grapheme = run.graphemes[run.visibleGraphemes]
			run.nextDelay = 1 / run.charsPerSecond
			if PUNCTUATION[grapheme] then
				run.nextDelay += run.punctuationPause
			end
		end
	end)
end

function Typewriter.new(label: Instance): Typewriter
	if not label:IsA("TextLabel") then
		error("Typewriter.new requires a TextLabel", 2)
	end

	local textLabel = label :: TextLabel
	local completedEvent = Instance.new("BindableEvent")
	local graphemeRevealedEvent = Instance.new("BindableEvent")

	local self = setmetatable({
		Completed = completedEvent.Event,
		GraphemeRevealed = graphemeRevealedEvent.Event,
	}, Typewriter) :: any

	states[self] = {
		label = textLabel,
		completedEvent = completedEvent,
		graphemeRevealedEvent = graphemeRevealedEvent,
		nextRunId = 0,
		currentRun = nil,
		destroyed = false,
	}

	return table.freeze(self) :: Typewriter
end

function Typewriter.Play(self: Typewriter, text: string, config: TypewriterConfig?): number
	local state = states[self]
	if not state or state.destroyed then
		error("TYPEWRITER_DESTROYED: Typewriter has been destroyed", 2)
	end
	if type(text) ~= "string" then
		error("TYPEWRITER_INVALID_TEXT: text must be a string", 2)
	end

	local charsPerSecond, punctuationPause = readConfig(config)
	state.nextRunId += 1

	local run: Run = {
		id = state.nextRunId,
		completed = false,
		connection = nil,
		graphemes = {},
		visibleGraphemes = 0,
		elapsed = 0,
		nextDelay = 1 / charsPerSecond,
		charsPerSecond = charsPerSecond,
		punctuationPause = punctuationPause,
	}
	local previousRun = state.currentRun
	state.currentRun = run

	if previousRun then
		finishRun(state, previousRun, "cancelled", false)
	end
	if not isCurrentRun(state, run) then
		return run.id
	end

	state.label.Text = text
	run.graphemes = getGraphemes(state.label.ContentText)
	state.label.MaxVisibleGraphemes = 0

	if #run.graphemes == 0 then
		task.defer(function()
			if isCurrentRun(state, run) then
				finishRun(state, run, "natural", true)
			end
		end)
	else
		startHeartbeat(state, run)
	end

	return run.id
end

function Typewriter.Skip(self: Typewriter)
	local state = states[self]
	if not state or state.destroyed then
		return
	end

	local run = state.currentRun
	if run then
		finishRun(state, run, "skipped", true)
	end
end

function Typewriter.Cancel(self: Typewriter)
	local state = states[self]
	if not state or state.destroyed then
		return
	end

	local run = state.currentRun
	if run then
		finishRun(state, run, "cancelled", false)
	end
end

function Typewriter.IsPlaying(self: Typewriter): boolean
	local state = states[self]
	return state ~= nil and not state.destroyed and state.currentRun ~= nil
end

function Typewriter.Destroy(self: Typewriter)
	local state = states[self]
	if not state or state.destroyed then
		return
	end

	state.destroyed = true
	local run = state.currentRun
	if run then
		finishRun(state, run, "cancelled", false)
	end

	local completedEvent = state.completedEvent
	local graphemeRevealedEvent = state.graphemeRevealedEvent
	task.defer(function()
		completedEvent:Destroy()
		graphemeRevealedEvent:Destroy()
	end)
end

return table.freeze(Typewriter)
