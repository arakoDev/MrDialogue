# Client interface

The client runtime translates authoritative server messages into calls on an
interface adapter. Start with the bundled adapter, configure it, or implement the
adapter contract yourself.

<span class="mrd-badge mrd-badge--client">Client</span>

## Bundled interface

The simplest client bootstrap creates and owns a `DefaultAdapter`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Client)

local runtime = MrDialogue.Start()
```

The bundled interface:

- Reveals text by grapheme, preserving UTF-8 and RichText.
- Adds a pause after common punctuation.
- Supports mouse, keyboard, touch buttons, and gamepad selection.
- Lets number keys `1` through `9` select visible choices.
- Freezes character movement by default and restores its previous values.
- Animates the dialogue and choice panels.

Movement freezing sets the local Humanoid's `WalkSpeed`, `JumpHeight`, and
`JumpPower` to zero. It does not anchor the character or override custom physics
controllers. During cleanup, the adapter restores only properties that still contain
the zero it applied, preserving newer non-zero values written by another system.
The lock follows character respawns and Humanoid replacement while the dialogue
remains active.

## Configure the default adapter

Create it explicitly and pass it to `Start`:

```luau
local adapter = MrDialogue.DefaultAdapter.new({
	charsPerSecond = 45,
	punctuationPause = 0.1,
	freezeCharacter = false,
})

local runtime = MrDialogue.Start({
	adapter = adapter,
})
```

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `gui` | `ScreenGui?` | Existing named GUI, otherwise bundled clone | Existing interface to use |
| `charsPerSecond` | `number?` | `30` | Positive reveal speed |
| `punctuationPause` | `number?` | `0.15` | Additional non-negative pause |
| `freezeCharacter` | `boolean?` | `true` | Adapter fallback for movement freezing |

When `DialogueDefinition.freezeCharacter` is present, it overrides the adapter
fallback for that session.

!!! warning "Ownership of supplied adapters"

    `MrDialogue.Stop()` destroys only the default adapter that `Start()` created
    internally. If you supply an adapter, you own it and should call `Destroy()` when
    it is no longer needed.

## Use a custom `ScreenGui`

The default adapter accepts an existing GUI, but its descendants must follow this
contract:

```text
DialogueGui (ScreenGui)
├── DialogueFrame (GuiObject)
│   ├── ContinueButton (GuiButton)
│   ├── NpcIcon (ImageLabel)
│   ├── NpcName (TextLabel)
│   └── DialogueLabel (ScrollingFrame)
│       └── TextLabel (TextLabel)
└── OptionsFrame (GuiObject)
    └── OptionsFrame (ScrollingFrame)
        └── OptionTemplate (GuiButton)
```

If `OptionTemplate` is an `ImageButton`, it must contain a `TextLabel`. The adapter
clones the template for every available option.

When `gui` is omitted, the adapter first reuses `PlayerGui.DialogueGui` if present.
It clones `MrDialogue.Assets.DialogueGui` only when that name does not already exist.

```luau
local gui = game.Players.LocalPlayer.PlayerGui:WaitForChild("DialogueGui")

local adapter = MrDialogue.DefaultAdapter.new({
	gui = gui,
})

MrDialogue.Start({ adapter = adapter })
```

## Implement a custom adapter

A custom adapter implements six methods:

```luau
local adapter = {}

function adapter:OnShow(info)
	-- Open the interface.
end

function adapter:OnPresentation(presentation, actions)
	-- Render presentation.text, then acknowledge it.
	actions.presentationCompleted()
end

function adapter:OnAdvanceReady(actions)
	-- Bind the next user input to actions.advance().
end

function adapter:OnFinishReady(actions)
	-- Bind the final user input to actions.finish().
end

function adapter:OnChoices(options, actions)
	-- Render options and call actions.choose(index).
end

function adapter:OnEnd(outcome)
	-- Close the interface and clear local state.
end

MrDialogue.Start({ adapter = adapter })
```

Do not retain an action callback after the corresponding UI state is replaced. The
runtime ignores stale callbacks, but the adapter should still disconnect obsolete
buttons and animations.

All six adapter methods must finish synchronously without yielding. If `OnShow`,
`OnPresentation`, `OnAdvanceReady`, `OnFinishReady`, or `OnChoices` throws or yields,
the runtime reports `client_error`, clears its local session, and invokes one
non-authoritative `OnEnd`. The server then cancels the authoritative session with the
same reason. A failure inside `OnEnd` itself is logged and contained without invoking
cleanup recursively.

## Presentation data

`OnPresentation` receives:

```luau
{
	kind = "line" | "choice_prompt",
	speaker = {
		name = "Guide",
		icon = "rbxassetid://123",
	}?,
	text = "Where are you going?",
}
```

`OnChoices` receives an array containing only:

```luau
{
	{ text = "The market." },
	{ text = "The castle." },
}
```

The client never receives option IDs, targets, or conditions.

## Cancel or stop

```luau
MrDialogue.CancelActiveSession()
```

Requests authoritative cancellation and leaves the runtime available for another
session.

```luau
MrDialogue.Stop()
```

Stops the runtime, disconnects networking, and cancels any active session. If an
active custom adapter receives `OnEnd` during shutdown, the outcome has
`authoritative = false` because the client cannot wait for the server reply.

Starting after `Stop()` creates a fresh runtime.
