--!strict

local Players = game:GetService("Players")

local ClientRuntimeClass = require(script.Parent.ClientRuntime)
local Net = require(script.Parent.Net)
local TypewriterClass = require(script.Parent.Typewriter)

local DefaultAdapter = {}
DefaultAdapter.__index = DefaultAdapter

export type Config = {
	gui: ScreenGui?,
	charsPerSecond: number?,
	punctuationPause: number?,
}

export type DefaultAdapter = ClientRuntimeClass.Adapter

type OptionBinding = {
	button: GuiButton,
	connection: RBXScriptConnection,
}

type GuiReferences = {
	gui: ScreenGui,
	npcDialogueFrame: GuiObject,
	continueButton: GuiButton,
	npcIcon: ImageLabel,
	dialogueLabel: TextLabel,
	npcName: TextLabel,
	optionsFrame: GuiObject,
	optionTemplate: GuiButton,
}

type DefaultAdapterState = GuiReferences & {
	typewriter: TypewriterClass.Typewriter,
	typewriterConfig: TypewriterClass.TypewriterConfig,
	typewriterConnection: RBXScriptConnection?,
	currentRunId: number?,
	presentationCompleted: (() -> ())?,
	optionBindings: { OptionBinding },
	choiceGeneration: number,
	choiceLocked: boolean,
}

local states: { [DefaultAdapter]: DefaultAdapterState } = setmetatable({}, { __mode = "k" }) :: any

local function getPlayerGui(): PlayerGui
	local player = Players.LocalPlayer
	if not player then
		error("MrDialogue.DefaultAdapter requires a LocalPlayer", 3)
	end

	local playerGui = player:WaitForChild("PlayerGui")
	if not playerGui:IsA("PlayerGui") then
		error("LocalPlayer.PlayerGui must be a PlayerGui", 3)
	end

	return playerGui
end

local function resolveGui(explicitGui: ScreenGui?): ScreenGui
	local playerGui = getPlayerGui()
	if explicitGui then
		if explicitGui.Parent == nil then
			explicitGui.Parent = playerGui
		end
		return explicitGui
	end

	local existing = playerGui:FindFirstChild("DialogueGui")
	if existing then
		if not existing:IsA("ScreenGui") then
			error("PlayerGui.DialogueGui must be a ScreenGui", 3)
		end
		return existing
	end

	local assets = script.Parent:FindFirstChild("Assets")
	if not assets or not assets:IsA("Folder") then
		error("MrDialogue is missing its Assets folder", 3)
	end

	local template = assets:FindFirstChild("DialogueGui")
	if not template or not template:IsA("ScreenGui") then
		error("MrDialogue.Assets.DialogueGui must be a ScreenGui", 3)
	end

	local gui = template:Clone()
	gui.Parent = playerGui
	return gui
end

local function expectChild(
	parent: Instance?,
	name: string,
	className: string,
	path: string,
	issues: { string }
): Instance?
	if not parent then
		table.insert(issues, `{path} is missing; expected {className}`)
		return nil
	end

	local child = parent:FindFirstChild(name)
	if not child then
		table.insert(issues, `{path} is missing; expected {className}`)
		return nil
	end
	if not child:IsA(className) then
		table.insert(issues, `{path} must be a {className}, got {child.ClassName}`)
		return nil
	end

	return child
end

local function validateGui(gui: ScreenGui): GuiReferences
	local issues = {}
	local npcDialogueFrame =
		expectChild(gui, "NpcDialogueFrame", "GuiObject", "DialogueGui.NpcDialogueFrame", issues)
	local continueButton = expectChild(
		npcDialogueFrame,
		"ContinueButton",
		"GuiButton",
		"DialogueGui.NpcDialogueFrame.ContinueButton",
		issues
	)
	local npcIcon = expectChild(
		npcDialogueFrame,
		"NpcIcon",
		"ImageLabel",
		"DialogueGui.NpcDialogueFrame.NpcIcon",
		issues
	)
	local dialogueLabel = expectChild(
		npcDialogueFrame,
		"DialogueLabel",
		"TextLabel",
		"DialogueGui.NpcDialogueFrame.DialogueLabel",
		issues
	)
	local npcName = expectChild(
		npcDialogueFrame,
		"NpcName",
		"TextLabel",
		"DialogueGui.NpcDialogueFrame.NpcName",
		issues
	)
	local optionsFrame =
		expectChild(gui, "OptionsFrame", "GuiObject", "DialogueGui.OptionsFrame", issues)
	local optionTemplate = expectChild(
		optionsFrame,
		"OptionTemplate",
		"GuiButton",
		"DialogueGui.OptionsFrame.OptionTemplate",
		issues
	)

	if optionTemplate and optionTemplate:IsA("ImageButton") then
		expectChild(
			optionTemplate,
			"TextLabel",
			"TextLabel",
			"DialogueGui.OptionsFrame.OptionTemplate.TextLabel",
			issues
		)
	end

	if #issues > 0 then
		error(`Invalid DialogueGui:\n- {table.concat(issues, "\n- ")}`, 3)
	end

	return {
		gui = gui,
		npcDialogueFrame = npcDialogueFrame :: GuiObject,
		continueButton = continueButton :: GuiButton,
		npcIcon = npcIcon :: ImageLabel,
		dialogueLabel = dialogueLabel :: TextLabel,
		npcName = npcName :: TextLabel,
		optionsFrame = optionsFrame :: GuiObject,
		optionTemplate = optionTemplate :: GuiButton,
	}
end

local function setContinueEnabled(state: DefaultAdapterState, enabled: boolean)
	state.continueButton.Active = enabled
	state.continueButton.AutoButtonColor = enabled
	state.continueButton.Selectable = enabled
end

local function clearSpeaker(state: DefaultAdapterState)
	state.npcName.Text = ""
	state.npcName.Visible = false
	state.npcIcon.Image = ""
	state.npcIcon.Visible = false
end

local function applySpeaker(state: DefaultAdapterState, speaker: Net.SpeakerPayload?)
	clearSpeaker(state)
	if not speaker then
		return
	end

	state.npcName.Text = speaker.name
	state.npcName.Visible = true
	if speaker.icon then
		state.npcIcon.Image = speaker.icon
		state.npcIcon.Visible = true
	end
end

local function clearOptions(state: DefaultAdapterState)
	state.choiceGeneration += 1
	state.choiceLocked = true
	for _, binding in ipairs(state.optionBindings) do
		binding.connection:Disconnect()
		binding.button:Destroy()
	end
	table.clear(state.optionBindings)
	state.optionsFrame.Visible = false
end

local function setOptionText(button: GuiButton, text: string)
	if button:IsA("TextButton") then
		button.Text = text
		return
	end

	local label = button:FindFirstChild("TextLabel")
	if not label or not label:IsA("TextLabel") then
		error("OptionTemplate ImageButton requires a TextLabel child", 2)
	end
	label.Text = text
end

local function lockChoiceButtons(state: DefaultAdapterState)
	state.choiceLocked = true
	for _, binding in ipairs(state.optionBindings) do
		binding.button.Active = false
		binding.button.AutoButtonColor = false
		binding.button.Selectable = false
	end
end

local function resetPresentation(state: DefaultAdapterState)
	state.currentRunId = nil
	state.presentationCompleted = nil
	state.typewriter:Cancel()
end

function DefaultAdapter.new(config: Config?): DefaultAdapter
	if config ~= nil and type(config) ~= "table" then
		error("MrDialogue.DefaultAdapter.new config must be a table", 2)
	end

	local explicitGui = if config then config.gui else nil
	if
		explicitGui ~= nil
		and (typeof(explicitGui) ~= "Instance" or not explicitGui:IsA("ScreenGui"))
	then
		error("MrDialogue.DefaultAdapter.new config.gui must be a ScreenGui", 2)
	end

	local references = validateGui(resolveGui(explicitGui))
	local typewriter = TypewriterClass.new(references.dialogueLabel)
	local self = setmetatable({}, DefaultAdapter) :: any
	local state: DefaultAdapterState = {
		gui = references.gui,
		npcDialogueFrame = references.npcDialogueFrame,
		continueButton = references.continueButton,
		npcIcon = references.npcIcon,
		dialogueLabel = references.dialogueLabel,
		npcName = references.npcName,
		optionsFrame = references.optionsFrame,
		optionTemplate = references.optionTemplate,
		typewriter = typewriter,
		typewriterConfig = {
			charsPerSecond = if config then config.charsPerSecond else nil,
			punctuationPause = if config then config.punctuationPause else nil,
		},
		typewriterConnection = nil,
		currentRunId = nil,
		presentationCompleted = nil,
		optionBindings = {},
		choiceGeneration = 0,
		choiceLocked = true,
	}
	states[self] = state

	state.gui.Enabled = false
	state.optionsFrame.Visible = false
	state.optionTemplate.Visible = false
	state.optionTemplate.Active = false
	state.optionTemplate.AutoButtonColor = false
	setContinueEnabled(state, false)
	state.typewriterConnection = typewriter.Completed:Connect(function(runId, outcome)
		if
			state.currentRunId ~= runId
			or outcome == "cancelled"
			or state.presentationCompleted == nil
		then
			return
		end

		local presentationCompleted = state.presentationCompleted
		state.currentRunId = nil
		state.presentationCompleted = nil
		setContinueEnabled(state, false)
		presentationCompleted()
	end)

	return table.freeze(self) :: DefaultAdapter
end

function DefaultAdapter.OnShow(self: DefaultAdapter, _info: { dialogueId: string })
	local state = states[self]
	resetPresentation(state)
	clearOptions(state)
	clearSpeaker(state)
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1
	state.npcDialogueFrame.Visible = true
	setContinueEnabled(state, false)
	state.gui.Enabled = true
end

function DefaultAdapter.OnPresentation(
	self: DefaultAdapter,
	presentation: ClientRuntimeClass.PresentationInfo,
	actions: ClientRuntimeClass.PresentationActions
)
	local state = states[self]
	resetPresentation(state)
	clearOptions(state)
	applySpeaker(state, presentation.speaker)
	state.npcDialogueFrame.Visible = true
	setContinueEnabled(state, false)

	local runId = state.typewriter:Play(presentation.text, state.typewriterConfig)
	state.currentRunId = runId
	state.presentationCompleted = actions.presentationCompleted
end

function DefaultAdapter.OnAdvanceReady(
	self: DefaultAdapter,
	_actions: ClientRuntimeClass.AdvanceActions
)
	setContinueEnabled(states[self], false)
end

function DefaultAdapter.OnFinishReady(
	self: DefaultAdapter,
	_actions: ClientRuntimeClass.FinishActions
)
	setContinueEnabled(states[self], false)
end

function DefaultAdapter.OnChoices(
	self: DefaultAdapter,
	options: { Net.ChoiceOptionPayload },
	actions: ClientRuntimeClass.ChoiceActions
)
	local state = states[self]
	resetPresentation(state)
	clearOptions(state)
	setContinueEnabled(state, false)
	state.choiceLocked = false
	local generation = state.choiceGeneration

	for index, option in ipairs(options) do
		local button = state.optionTemplate:Clone()
		button.Name = `Option{index}`
		button.LayoutOrder = index
		button.Visible = true
		button.Active = true
		button.AutoButtonColor = true
		button.Selectable = true
		setOptionText(button, option.text)
		button.Parent = state.optionsFrame

		local connection = button.Activated:Connect(function()
			if state.choiceLocked or state.choiceGeneration ~= generation then
				return
			end

			lockChoiceButtons(state)
			actions.choose(index)
		end)
		table.insert(state.optionBindings, {
			button = button,
			connection = connection,
		})
	end

	state.optionsFrame.Visible = true
end

function DefaultAdapter.OnEnd(
	self: DefaultAdapter,
	_outcome: {
		status: "completed",
		result: string?,
	}
)
	local state = states[self]
	resetPresentation(state)
	clearOptions(state)
	clearSpeaker(state)
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1
	setContinueEnabled(state, false)
	state.gui.Enabled = false
end

return table.freeze(DefaultAdapter)
