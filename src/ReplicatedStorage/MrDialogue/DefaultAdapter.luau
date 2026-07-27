--!strict

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ClientRuntimeClass = require(script.Parent.ClientRuntime)
local Net = require(script.Parent.Net)
local TypewriterClass = require(script.Parent.Typewriter)

local DefaultAdapter = {}
DefaultAdapter.__index = DefaultAdapter

export type Config = {
	gui: ScreenGui?,
	charsPerSecond: number?,
	punctuationPause: number?,
	freezeCharacter: boolean?,
}

export type DefaultAdapter = ClientRuntimeClass.Adapter & {
	Destroy: (self: DefaultAdapter) -> boolean,
}

type OptionBinding = {
	button: GuiButton,
	connection: RBXScriptConnection,
}

type ContinueMode = "DISABLED" | "TYPING" | "ADVANCE" | "FINISH"

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
	continueConnection: RBXScriptConnection?,
	inputConnection: RBXScriptConnection?,
	preferredInputConnection: RBXScriptConnection?,
	npcDialogueTween: Tween?,
	optionsTween: Tween?,
	npcDialoguePosition: UDim2,
	optionsPosition: UDim2,
	freezeCharacter: boolean,
	frozenHumanoid: Humanoid?,
	originalWalkSpeed: number?,
	originalJumpHeight: number?,
	continueMode: ContinueMode,
	continueAction: (() -> ())?,
	currentRunId: number?,
	presentationCompleted: (() -> ())?,
	optionBindings: { OptionBinding },
	choiceGeneration: number,
	choiceLocked: boolean,
	choose: ((index: number) -> ())?,
	destroyed: boolean,
}

local states: { [DefaultAdapter]: DefaultAdapterState } = setmetatable({}, { __mode = "k" }) :: any

local NUMBER_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

local APPEAR_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local DISAPPEAR_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

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

local function restoreCharacterMovement(state: DefaultAdapterState)
	local humanoid = state.frozenHumanoid
	local originalWalkSpeed = state.originalWalkSpeed
	local originalJumpHeight = state.originalJumpHeight

	state.frozenHumanoid = nil
	state.originalWalkSpeed = nil
	state.originalJumpHeight = nil

	if humanoid and humanoid.Parent then
		if originalWalkSpeed then
			humanoid.WalkSpeed = originalWalkSpeed
		end
		if originalJumpHeight then
			humanoid.JumpHeight = originalJumpHeight
		end
	end
end

local function freezeCharacterMovement(state: DefaultAdapterState)
	restoreCharacterMovement(state)
	if not state.freezeCharacter then
		return
	end

	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid then
		return
	end

	state.frozenHumanoid = humanoid
	state.originalWalkSpeed = humanoid.WalkSpeed
	state.originalJumpHeight = humanoid.JumpHeight
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0
end

local function cancelNpcDialogueTween(state: DefaultAdapterState)
	local tween = state.npcDialogueTween
	state.npcDialogueTween = nil
	if tween then
		tween:Cancel()
	end
end

local function resetNpcDialogueTween(state: DefaultAdapterState)
	cancelNpcDialogueTween(state)
	state.npcDialogueFrame.Position = state.npcDialoguePosition
end

local function getNpcDialogueHiddenPosition(state: DefaultAdapterState): UDim2
	local originalPosition = state.npcDialoguePosition
	return UDim2.new(
		originalPosition.X.Scale,
		originalPosition.X.Offset,
		2,
		originalPosition.Y.Offset
	)
end

local function playNpcDialogueTween(state: DefaultAdapterState)
	resetNpcDialogueTween(state)
	local originalPosition = state.npcDialoguePosition
	state.npcDialogueFrame.Position = getNpcDialogueHiddenPosition(state)
	state.npcDialogueFrame.Visible = true

	local tween = TweenService:Create(
		state.npcDialogueFrame,
		APPEAR_TWEEN_INFO,
		{ Position = originalPosition }
	)
	state.npcDialogueTween = tween
	tween:Play()
end

local function playNpcDialogueExitTween(state: DefaultAdapterState, completed: () -> ())
	cancelNpcDialogueTween(state)
	if not state.gui.Enabled or not state.npcDialogueFrame.Visible then
		state.npcDialogueFrame.Position = state.npcDialoguePosition
		state.npcDialogueFrame.Visible = false
		completed()
		return
	end

	local tween = TweenService:Create(
		state.npcDialogueFrame,
		DISAPPEAR_TWEEN_INFO,
		{ Position = getNpcDialogueHiddenPosition(state) }
	)
	state.npcDialogueTween = tween
	tween.Completed:Once(function(playbackState)
		if state.npcDialogueTween ~= tween or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		state.npcDialogueTween = nil
		state.npcDialogueFrame.Visible = false
		state.npcDialogueFrame.Position = state.npcDialoguePosition
		completed()
	end)
	tween:Play()
end

local function cancelOptionsTween(state: DefaultAdapterState)
	local tween = state.optionsTween
	state.optionsTween = nil
	if tween then
		tween:Cancel()
	end
end

local function resetOptionsTween(state: DefaultAdapterState)
	cancelOptionsTween(state)
	state.optionsFrame.Position = state.optionsPosition
end

local function getOptionsHiddenPosition(state: DefaultAdapterState): UDim2
	local originalPosition = state.optionsPosition
	return UDim2.new(
		2,
		originalPosition.X.Offset,
		originalPosition.Y.Scale,
		originalPosition.Y.Offset
	)
end

local function playOptionsTween(state: DefaultAdapterState)
	resetOptionsTween(state)
	local originalPosition = state.optionsPosition
	state.optionsFrame.Position = getOptionsHiddenPosition(state)
	state.optionsFrame.Visible = true

	local tween =
		TweenService:Create(state.optionsFrame, APPEAR_TWEEN_INFO, { Position = originalPosition })
	state.optionsTween = tween
	tween:Play()
end

local function playOptionsExitTween(state: DefaultAdapterState, completed: () -> ())
	cancelOptionsTween(state)
	if not state.optionsFrame.Visible then
		state.optionsFrame.Position = state.optionsPosition
		completed()
		return
	end

	local tween = TweenService:Create(
		state.optionsFrame,
		DISAPPEAR_TWEEN_INFO,
		{ Position = getOptionsHiddenPosition(state) }
	)
	state.optionsTween = tween
	tween.Completed:Once(function(playbackState)
		if state.optionsTween ~= tween or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		state.optionsTween = nil
		state.optionsFrame.Visible = false
		state.optionsFrame.Position = state.optionsPosition
		completed()
	end)
	tween:Play()
end

local function clearDialogueSelection(state: DefaultAdapterState)
	local selectedObject = GuiService.SelectedObject
	if selectedObject and selectedObject:IsDescendantOf(state.gui) then
		GuiService.SelectedObject = nil
	end
end

local function updateDialogueSelection(state: DefaultAdapterState)
	if not state.gui.Enabled or UserInputService.PreferredInput ~= Enum.PreferredInput.Gamepad then
		clearDialogueSelection(state)
		return
	end

	if state.optionsFrame.Visible and not state.choiceLocked then
		local selectedObject = GuiService.SelectedObject
		for _, binding in ipairs(state.optionBindings) do
			if selectedObject == binding.button then
				return
			end
		end

		local firstBinding = state.optionBindings[1]
		if firstBinding then
			GuiService.SelectedObject = firstBinding.button
		end
		return
	end

	if
		(not state.optionsFrame.Visible or state.choiceLocked)
		and state.continueMode ~= "DISABLED"
	then
		GuiService.SelectedObject = state.continueButton
		return
	end

	clearDialogueSelection(state)
end

local function setContinueMode(state: DefaultAdapterState, mode: ContinueMode, action: (() -> ())?)
	state.continueMode = mode
	state.continueAction = action
	setContinueEnabled(state, mode ~= "DISABLED")
	updateDialogueSelection(state)
end

local function activateContinue(state: DefaultAdapterState)
	if
		not state.gui.Enabled
		or (state.optionsFrame.Visible and not state.choiceLocked)
		or state.continueMode == "DISABLED"
	then
		return
	end

	local mode = state.continueMode
	local action = state.continueAction
	setContinueMode(state, "DISABLED", nil)

	if mode == "TYPING" then
		state.typewriter:Skip()
	elseif action then
		action()
	end
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

local function clearChoiceSelection(state: DefaultAdapterState)
	local selectedObject = GuiService.SelectedObject
	if not selectedObject then
		return
	end

	for _, binding in ipairs(state.optionBindings) do
		if selectedObject == binding.button then
			GuiService.SelectedObject = nil
			return
		end
	end
end

local function destroyOptionBindings(state: DefaultAdapterState)
	for _, binding in ipairs(state.optionBindings) do
		binding.connection:Disconnect()
		binding.button:Destroy()
	end
	table.clear(state.optionBindings)
end

local function clearOptions(state: DefaultAdapterState, animate: boolean?)
	clearChoiceSelection(state)
	state.choiceGeneration += 1
	state.choiceLocked = true
	state.choose = nil
	for _, binding in ipairs(state.optionBindings) do
		binding.connection:Disconnect()
		binding.button.Active = false
		binding.button.AutoButtonColor = false
		binding.button.Selectable = false
	end

	if animate and state.optionsFrame.Visible then
		playOptionsExitTween(state, function()
			destroyOptionBindings(state)
			updateDialogueSelection(state)
		end)
	else
		resetOptionsTween(state)
		destroyOptionBindings(state)
		state.optionsFrame.Visible = false
	end
end

local function formatOptionText(index: number, text: string): string
	local expectedPrefix = `{index}.`
	if string.sub(text, 1, #expectedPrefix) == expectedPrefix then
		return text
	end

	local content = string.gsub(text, "^%s*%d+%.%s*", "", 1)
	return `{expectedPrefix} {content}`
end

local function setOptionText(button: GuiButton, index: number, text: string)
	local formattedText = formatOptionText(index, text)
	if button:IsA("TextButton") then
		button.Text = formattedText
		return
	end

	local label = button:FindFirstChild("TextLabel")
	if not label or not label:IsA("TextLabel") then
		error("OptionTemplate ImageButton requires a TextLabel child", 2)
	end
	label.Text = formattedText
end

local function lockChoiceButtons(state: DefaultAdapterState)
	clearChoiceSelection(state)
	state.choiceLocked = true
	state.choose = nil
	for _, binding in ipairs(state.optionBindings) do
		binding.button.Active = false
		binding.button.AutoButtonColor = false
		binding.button.Selectable = false
	end
end

local function activateChoice(state: DefaultAdapterState, index: number)
	if state.choiceLocked or not state.gui.Enabled then
		return
	end

	local binding = state.optionBindings[index]
	local choose = state.choose
	if not binding or not choose then
		return
	end

	lockChoiceButtons(state)
	choose(index)
end

local function resetPresentation(state: DefaultAdapterState)
	setContinueMode(state, "DISABLED", nil)
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
	if config and config.freezeCharacter ~= nil and type(config.freezeCharacter) ~= "boolean" then
		error("MrDialogue.DefaultAdapter.new config.freezeCharacter must be a boolean", 2)
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
		continueConnection = nil,
		inputConnection = nil,
		preferredInputConnection = nil,
		npcDialogueTween = nil,
		optionsTween = nil,
		npcDialoguePosition = references.npcDialogueFrame.Position,
		optionsPosition = references.optionsFrame.Position,
		freezeCharacter = if config and config.freezeCharacter ~= nil
			then config.freezeCharacter
			else true,
		frozenHumanoid = nil,
		originalWalkSpeed = nil,
		originalJumpHeight = nil,
		continueMode = "DISABLED" :: ContinueMode,
		continueAction = nil,
		currentRunId = nil,
		presentationCompleted = nil,
		optionBindings = {},
		choiceGeneration = 0,
		choiceLocked = true,
		choose = nil,
		destroyed = false,
	}
	states[self] = state

	state.gui.Enabled = false
	clearDialogueSelection(state)
	state.optionsFrame.Visible = false
	state.optionTemplate.Visible = false
	state.optionTemplate.Active = false
	state.optionTemplate.Selectable = false
	state.optionTemplate.AutoButtonColor = false
	setContinueMode(state, "DISABLED", nil)
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
		setContinueMode(state, "DISABLED", nil)
		presentationCompleted()
	end)
	state.continueConnection = state.continueButton.Activated:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Space and not state.freezeCharacter then
			return
		end
		activateContinue(state)
	end)
	state.inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		if
			gameProcessedEvent
			or not state.gui.Enabled
			or UserInputService:GetFocusedTextBox() ~= nil
		then
			return
		end

		local keyCode = input.KeyCode
		if state.optionsFrame.Visible and not state.choiceLocked then
			local optionIndex = NUMBER_KEYS[keyCode]
			if optionIndex then
				activateChoice(state, optionIndex)
			end
			return
		end

		if
			(keyCode == Enum.KeyCode.Space and state.freezeCharacter)
			or keyCode == Enum.KeyCode.Return
			or keyCode == Enum.KeyCode.KeypadEnter
		then
			activateContinue(state)
		end
	end)
	state.preferredInputConnection = UserInputService:GetPropertyChangedSignal("PreferredInput")
		:Connect(function()
			updateDialogueSelection(state)
		end)

	return table.freeze(self) :: DefaultAdapter
end

function DefaultAdapter.OnShow(self: DefaultAdapter, _info: { dialogueId: string })
	local state = states[self]
	clearDialogueSelection(state)
	resetPresentation(state)
	clearOptions(state)
	clearSpeaker(state)
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1
	setContinueMode(state, "DISABLED", nil)
	freezeCharacterMovement(state)
	state.gui.Enabled = true
	playNpcDialogueTween(state)
end

function DefaultAdapter.OnPresentation(
	self: DefaultAdapter,
	presentation: ClientRuntimeClass.PresentationInfo,
	actions: ClientRuntimeClass.PresentationActions
)
	local state = states[self]
	resetPresentation(state)
	clearOptions(state, true)
	applySpeaker(state, presentation.speaker)
	state.npcDialogueFrame.Visible = true

	local runId = state.typewriter:Play(presentation.text, state.typewriterConfig)
	state.currentRunId = runId
	state.presentationCompleted = actions.presentationCompleted
	setContinueMode(state, "TYPING", nil)
end

function DefaultAdapter.OnAdvanceReady(
	self: DefaultAdapter,
	actions: ClientRuntimeClass.AdvanceActions
)
	setContinueMode(states[self], "ADVANCE", actions.advance)
end

function DefaultAdapter.OnFinishReady(
	self: DefaultAdapter,
	actions: ClientRuntimeClass.FinishActions
)
	setContinueMode(states[self], "FINISH", actions.finish)
end

function DefaultAdapter.OnChoices(
	self: DefaultAdapter,
	options: { Net.ChoiceOptionPayload },
	actions: ClientRuntimeClass.ChoiceActions
)
	local state = states[self]
	resetPresentation(state)
	clearOptions(state)
	setContinueMode(state, "DISABLED", nil)
	state.choiceLocked = false
	state.choose = actions.choose
	local generation = state.choiceGeneration

	for index, option in ipairs(options) do
		local button = state.optionTemplate:Clone()
		button.Name = `Option{index}`
		button.LayoutOrder = index
		button.Visible = true
		button.Active = true
		button.AutoButtonColor = true
		button.Selectable = true
		button.SelectionOrder = index
		setOptionText(button, index, option.text)
		button.Parent = state.optionsFrame

		local connection = button.Activated:Connect(function()
			if state.choiceGeneration ~= generation then
				return
			end
			activateChoice(state, index)
		end)
		table.insert(state.optionBindings, {
			button = button,
			connection = connection,
		})
	end

	local optionCount = #state.optionBindings
	for index, binding in ipairs(state.optionBindings) do
		local previousIndex = if index == 1 then optionCount else index - 1
		local nextIndex = if index == optionCount then 1 else index + 1
		binding.button.NextSelectionUp = state.optionBindings[previousIndex].button
		binding.button.NextSelectionDown = state.optionBindings[nextIndex].button
	end

	playOptionsTween(state)
	updateDialogueSelection(state)
end

function DefaultAdapter.OnEnd(self: DefaultAdapter, _outcome: ClientRuntimeClass.EndOutcome)
	local state = states[self]
	restoreCharacterMovement(state)
	resetPresentation(state)
	clearOptions(state, true)
	clearDialogueSelection(state)
	playNpcDialogueExitTween(state, function()
		clearSpeaker(state)
		state.dialogueLabel.Text = ""
		state.dialogueLabel.MaxVisibleGraphemes = -1
		state.gui.Enabled = false
	end)
end

function DefaultAdapter.Destroy(self: DefaultAdapter): boolean
	local state = states[self]
	if not state or state.destroyed then
		return false
	end

	state.destroyed = true
	restoreCharacterMovement(state)
	resetPresentation(state)
	clearOptions(state)
	resetNpcDialogueTween(state)
	clearDialogueSelection(state)
	clearSpeaker(state)
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1
	state.gui.Enabled = false

	if state.typewriterConnection then
		state.typewriterConnection:Disconnect()
		state.typewriterConnection = nil
	end
	if state.continueConnection then
		state.continueConnection:Disconnect()
		state.continueConnection = nil
	end
	if state.inputConnection then
		state.inputConnection:Disconnect()
		state.inputConnection = nil
	end
	if state.preferredInputConnection then
		state.preferredInputConnection:Disconnect()
		state.preferredInputConnection = nil
	end
	state.typewriter:Destroy()

	return true
end

return table.freeze(DefaultAdapter)
