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

-- A panel that slides in from off-screen and back out again.
type Slide = {
	frame: GuiObject,
	shown: UDim2,
	hidden: UDim2,
	tween: Tween?,
}

type GuiReferences = {
	gui: ScreenGui,
	dialogueFrame: GuiObject,
	continueButton: GuiButton,
	npcIcon: ImageLabel,
	dialogueScroller: ScrollingFrame,
	dialogueLabel: TextLabel,
	npcName: TextLabel,
	optionsPanel: GuiObject,
	optionsContainer: ScrollingFrame,
	optionTemplate: GuiButton,
}

type DefaultAdapterState = GuiReferences & {
	typewriter: TypewriterClass.Typewriter,
	typewriterConfig: TypewriterClass.TypewriterConfig,
	connections: { RBXScriptConnection },
	dialogueSlide: Slide,
	optionsSlide: Slide,
	defaultFreezeCharacter: boolean,
	freezeCharacter: boolean,
	frozenHumanoid: Humanoid?,
	originalWalkSpeed: number?,
	originalJumpHeight: number?,
	continueMode: ContinueMode,
	continueAction: (() -> ())?,
	currentRunId: number?,
	presentationCompleted: (() -> ())?,
	optionBindings: { OptionBinding },
	choiceLocked: boolean,
	choose: ((index: number) -> ())?,
	destroyed: boolean,
}

local states: { [DefaultAdapter]: DefaultAdapterState } = setmetatable({}, { __mode = "k" }) :: any

local NUMBER_KEYS: { [Enum.KeyCode]: number } = table.freeze({
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
})

local APPEAR_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local DISAPPEAR_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local function resolveGui(explicitGui: ScreenGui?): ScreenGui
	local player = Players.LocalPlayer
	if not player then
		error("MrDialogue.DefaultAdapter requires a LocalPlayer", 3)
	end

	local playerGui = player:WaitForChild("PlayerGui")
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

	-- Nothing in StarterGui, so fall back to the copy packaged with the library.
	local assets = script.Parent:FindFirstChild("Assets")
	local template = if assets then assets:FindFirstChild("DialogueGui") else nil
	if not template or not template:IsA("ScreenGui") then
		error("MrDialogue.Assets.DialogueGui is missing", 3)
	end

	local gui = template:Clone()
	gui.Parent = playerGui
	return gui
end

local function expectChild(
	parent: Instance?,
	name: string,
	className: string,
	issues: { string }
): Instance?
	if not parent then
		return nil -- Its own absence was already reported; don't pile on.
	end

	local child = parent:FindFirstChild(name)
	if not child then
		table.insert(issues, `{parent:GetFullName()}.{name} is missing; expected a {className}`)
		return nil
	end
	if not child:IsA(className) then
		table.insert(issues, `{child:GetFullName()} must be a {className}, not a {child.ClassName}`)
		return nil
	end

	return child
end

-- Reports everything wrong with the GUI at once: fixing a template one error per run is miserable.
local function validateGui(gui: ScreenGui): GuiReferences
	local issues = {}
	local dialogueFrame = expectChild(gui, "DialogueFrame", "GuiObject", issues)
	local continueButton = expectChild(dialogueFrame, "ContinueButton", "GuiButton", issues)
	local npcIcon = expectChild(dialogueFrame, "NpcIcon", "ImageLabel", issues)
	local npcName = expectChild(dialogueFrame, "NpcName", "TextLabel", issues)
	local dialogueScroller = expectChild(dialogueFrame, "DialogueLabel", "ScrollingFrame", issues)
	local dialogueLabel = expectChild(dialogueScroller, "TextLabel", "TextLabel", issues)
	local optionsPanel = expectChild(gui, "OptionsFrame", "GuiObject", issues)
	local optionsContainer = expectChild(optionsPanel, "OptionsFrame", "ScrollingFrame", issues)
	local optionTemplate = expectChild(optionsContainer, "OptionTemplate", "GuiButton", issues)

	-- A TextButton carries its own text; an ImageButton needs a label to put it in.
	if optionTemplate and optionTemplate:IsA("ImageButton") then
		expectChild(optionTemplate, "TextLabel", "TextLabel", issues)
	end

	if #issues > 0 then
		error(`Invalid DialogueGui:\n- {table.concat(issues, "\n- ")}`, 3)
	end

	return {
		gui = gui,
		dialogueFrame = dialogueFrame :: GuiObject,
		continueButton = continueButton :: GuiButton,
		npcIcon = npcIcon :: ImageLabel,
		dialogueScroller = dialogueScroller :: ScrollingFrame,
		dialogueLabel = dialogueLabel :: TextLabel,
		npcName = npcName :: TextLabel,
		optionsPanel = optionsPanel :: GuiObject,
		optionsContainer = optionsContainer :: ScrollingFrame,
		optionTemplate = optionTemplate :: GuiButton,
	}
end

local function newSlide(frame: GuiObject, hidden: UDim2): Slide
	return {
		frame = frame,
		shown = frame.Position,
		hidden = hidden,
		tween = nil,
	}
end

local function stopSlide(slide: Slide)
	local tween = slide.tween
	slide.tween = nil
	if tween then
		tween:Cancel()
	end
end

local function resetSlide(slide: Slide)
	stopSlide(slide)
	slide.frame.Position = slide.shown
end

local function slideIn(slide: Slide)
	stopSlide(slide)
	slide.frame.Position = slide.hidden
	slide.frame.Visible = true

	local tween = TweenService:Create(slide.frame, APPEAR_TWEEN_INFO, { Position = slide.shown })
	slide.tween = tween
	tween:Play()
end

local function slideOut(slide: Slide, completed: () -> ())
	stopSlide(slide)
	if not slide.frame.Visible then
		slide.frame.Position = slide.shown
		completed()
		return
	end

	local tween =
		TweenService:Create(slide.frame, DISAPPEAR_TWEEN_INFO, { Position = slide.hidden })
	slide.tween = tween
	tween.Completed:Once(function(playbackState)
		-- A new slide may have started while this one was playing; it owns the frame now.
		if slide.tween ~= tween or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		slide.tween = nil
		slide.frame.Visible = false
		slide.frame.Position = slide.shown
		completed()
	end)
	tween:Play()
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

local function clearDialogueSelection(state: DefaultAdapterState)
	local selectedObject = GuiService.SelectedObject
	if selectedObject and selectedObject:IsDescendantOf(state.gui) then
		GuiService.SelectedObject = nil
	end
end

--[[
	Keeps the gamepad cursor on whatever is actually actionable. Mouse and touch players get no
	selection at all, since a highlighted button they never asked for looks like a bug.
]]
local function updateDialogueSelection(state: DefaultAdapterState)
	if not state.gui.Enabled or UserInputService.PreferredInput ~= Enum.PreferredInput.Gamepad then
		clearDialogueSelection(state)
		return
	end

	if state.optionsPanel.Visible and not state.choiceLocked then
		local selectedObject = GuiService.SelectedObject
		for _, binding in ipairs(state.optionBindings) do
			if selectedObject == binding.button then
				return
			end
		end

		local firstBinding = state.optionBindings[1]
		if firstBinding then
			GuiService.SelectedObject = firstBinding.button
			return
		end
	end

	if state.continueMode == "DISABLED" then
		clearDialogueSelection(state)
	else
		GuiService.SelectedObject = state.continueButton
	end
end

local function setContinueMode(state: DefaultAdapterState, mode: ContinueMode, action: (() -> ())?)
	state.continueMode = mode
	state.continueAction = action
	setContinueEnabled(state, mode ~= "DISABLED")
	updateDialogueSelection(state)
end

local function activateContinue(state: DefaultAdapterState)
	if
		state.continueMode == "DISABLED" or (state.optionsPanel.Visible and not state.choiceLocked)
	then
		return
	end

	local mode = state.continueMode
	local action = state.continueAction
	setContinueMode(state, "DISABLED", nil)

	-- While text is still typing the click only completes it. Advancing is a second, separate click.
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

	local icon = speaker.icon
	if icon then
		state.npcIcon.Image = icon
		state.npcIcon.Visible = true
	end
end

local function clearChoiceSelection(state: DefaultAdapterState)
	local selectedObject = GuiService.SelectedObject
	for _, binding in ipairs(state.optionBindings) do
		if selectedObject == binding.button then
			GuiService.SelectedObject = nil
			return
		end
	end
end

local function lockOptions(state: DefaultAdapterState)
	clearChoiceSelection(state)
	state.choiceLocked = true
	state.choose = nil

	for _, binding in ipairs(state.optionBindings) do
		binding.button.Active = false
		binding.button.AutoButtonColor = false
		binding.button.Selectable = false
	end
end

local function releaseOptions(state: DefaultAdapterState)
	for _, binding in ipairs(state.optionBindings) do
		binding.connection:Disconnect()
		binding.button:Destroy()
	end
	table.clear(state.optionBindings)
end

-- Buttons are locked immediately but only destroyed once they are off-screen, so the slide-out has
-- something left to animate.
local function clearOptions(state: DefaultAdapterState, animate: boolean?)
	lockOptions(state)

	if animate and state.optionsPanel.Visible then
		slideOut(state.optionsSlide, function()
			releaseOptions(state)
			updateDialogueSelection(state)
		end)
	else
		resetSlide(state.optionsSlide)
		releaseOptions(state)
		state.optionsPanel.Visible = false
	end
end

-- Options are numbered so the 1-9 shortcuts match what the player is reading.
local function setOptionText(button: GuiButton, index: number, text: string)
	local content = string.gsub(text, "^%s*%d+%.%s*", "", 1)
	local numbered = `{index}. {content}`

	if button:IsA("TextButton") then
		button.Text = numbered
		return
	end

	local label = button:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		label.Text = numbered
	end
end

local function activateChoice(state: DefaultAdapterState, index: number)
	local binding = state.optionBindings[index]
	local choose = state.choose
	if state.choiceLocked or not binding or not choose then
		return
	end

	lockOptions(state)
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

	local references = validateGui(resolveGui(explicitGui))
	local freezeCharacter = if config and config.freezeCharacter ~= nil
		then config.freezeCharacter
		else true

	-- The dialogue box drops off the bottom of the screen; the options panel slides off the side.
	local dialoguePosition = references.dialogueFrame.Position
	local optionsPosition = references.optionsPanel.Position

	local self = setmetatable({}, DefaultAdapter) :: any
	local state: DefaultAdapterState = {
		gui = references.gui,
		dialogueFrame = references.dialogueFrame,
		continueButton = references.continueButton,
		npcIcon = references.npcIcon,
		dialogueScroller = references.dialogueScroller,
		dialogueLabel = references.dialogueLabel,
		npcName = references.npcName,
		optionsPanel = references.optionsPanel,
		optionsContainer = references.optionsContainer,
		optionTemplate = references.optionTemplate,
		typewriter = TypewriterClass.new(references.dialogueLabel),
		typewriterConfig = {
			charsPerSecond = if config then config.charsPerSecond else nil,
			punctuationPause = if config then config.punctuationPause else nil,
		},
		connections = {},
		dialogueSlide = newSlide(
			references.dialogueFrame,
			UDim2.new(
				dialoguePosition.X.Scale,
				dialoguePosition.X.Offset,
				2,
				dialoguePosition.Y.Offset
			)
		),
		optionsSlide = newSlide(
			references.optionsPanel,
			UDim2.new(
				2,
				optionsPosition.X.Offset,
				optionsPosition.Y.Scale,
				optionsPosition.Y.Offset
			)
		),
		defaultFreezeCharacter = freezeCharacter,
		freezeCharacter = freezeCharacter,
		continueMode = "DISABLED" :: ContinueMode,
		optionBindings = {},
		choiceLocked = true,
		destroyed = false,
	}
	states[self] = state

	state.gui.Enabled = false
	state.optionsPanel.Visible = false
	state.optionsContainer.Visible = true
	state.optionTemplate.Visible = false
	state.optionTemplate.Active = false
	state.optionTemplate.Selectable = false
	state.optionTemplate.AutoButtonColor = false
	clearDialogueSelection(state)
	setContinueMode(state, "DISABLED", nil)

	table.insert(
		state.connections,
		state.typewriter.Completed:Connect(function(runId, outcome)
			local presentationCompleted = state.presentationCompleted
			if
				state.currentRunId ~= runId
				or outcome == "cancelled"
				or not presentationCompleted
			then
				return
			end

			state.currentRunId = nil
			state.presentationCompleted = nil
			setContinueMode(state, "DISABLED", nil)
			presentationCompleted()
		end)
	)

	table.insert(
		state.connections,
		state.continueButton.Activated:Connect(function(input)
			-- Space also jumps, so let it through unless the character is standing still anyway.
			if input.KeyCode == Enum.KeyCode.Space and not state.freezeCharacter then
				return
			end
			activateContinue(state)
		end)
	)

	table.insert(
		state.connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
			if
				gameProcessedEvent
				or not state.gui.Enabled
				or UserInputService:GetFocusedTextBox() ~= nil
			then
				return
			end

			local keyCode = input.KeyCode
			if state.optionsPanel.Visible and not state.choiceLocked then
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
	)

	table.insert(
		state.connections,
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			updateDialogueSelection(state)
		end)
	)

	return table.freeze(self) :: DefaultAdapter
end

function DefaultAdapter.OnShow(self: DefaultAdapter, info: ClientRuntimeClass.ShowInfo)
	local state = states[self]
	state.freezeCharacter = if info.freezeCharacter ~= nil
		then info.freezeCharacter
		else state.defaultFreezeCharacter

	resetPresentation(state)
	clearOptions(state)
	clearSpeaker(state)
	clearDialogueSelection(state)
	state.dialogueScroller.CanvasPosition = Vector2.zero
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1

	freezeCharacterMovement(state)
	state.gui.Enabled = true
	slideIn(state.dialogueSlide)
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
	state.dialogueScroller.CanvasPosition = Vector2.zero

	state.currentRunId = state.typewriter:Play(presentation.text, state.typewriterConfig)
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
	state.choiceLocked = false
	state.choose = actions.choose
	state.optionsContainer.CanvasPosition = Vector2.zero

	for index, option in ipairs(options) do
		local button = state.optionTemplate:Clone()
		button.Name = `Option{index}`
		button.LayoutOrder = index
		button.SelectionOrder = index
		button.Visible = true
		button.Active = true
		button.AutoButtonColor = true
		button.Selectable = true
		setOptionText(button, index, option.text)
		button.Parent = state.optionsContainer

		table.insert(state.optionBindings, {
			button = button,
			connection = button.Activated:Connect(function()
				activateChoice(state, index)
			end),
		})
	end

	-- Wrap the gamepad selection around the list so it never dead-ends.
	local optionCount = #state.optionBindings
	for index, binding in ipairs(state.optionBindings) do
		local previousIndex = if index == 1 then optionCount else index - 1
		local nextIndex = if index == optionCount then 1 else index + 1
		binding.button.NextSelectionUp = state.optionBindings[previousIndex].button
		binding.button.NextSelectionDown = state.optionBindings[nextIndex].button
	end

	slideIn(state.optionsSlide)
	updateDialogueSelection(state)
end

function DefaultAdapter.OnEnd(self: DefaultAdapter, _outcome: ClientRuntimeClass.EndOutcome)
	local state = states[self]
	restoreCharacterMovement(state)
	resetPresentation(state)
	clearOptions(state, true)
	clearDialogueSelection(state)

	slideOut(state.dialogueSlide, function()
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
	resetSlide(state.dialogueSlide)
	clearDialogueSelection(state)
	clearSpeaker(state)
	state.dialogueLabel.Text = ""
	state.dialogueLabel.MaxVisibleGraphemes = -1
	state.gui.Enabled = false

	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)
	state.typewriter:Destroy()

	return true
end

return table.freeze(DefaultAdapter)
