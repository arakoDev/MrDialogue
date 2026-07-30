# Your first dialogue

This guide builds a complete NPC conversation with a prompt, two choices, and a
result. It assumes MrDialogue is installed under `ReplicatedStorage.Packages` and the
[client runtime is started](installation.md#start-the-client).

## Prepare an NPC

Add a `ProximityPrompt` to an NPC model or one of its parts. Then add a server
`Script` under the prompt:

```text
Workspace
└── Guide
    └── HumanoidRootPart
        └── ProximityPrompt
            └── Dialogue.server.luau
```

## Define the graph

```luau title="Dialogue.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Server)

local prompt = script.Parent
local npc = prompt:FindFirstAncestorOfClass("Model")

local dialogue = MrDialogue.new({
	format = 1,
	id = "guide_directions",
	entry = "greeting",

	speakers = {
		guide = {
			name = "Guide",
		},
	},
	defaultSpeaker = "guide",

	nodes = {
		greeting = {
			type = "line",
			text = "Lost? I can point you in the right direction.",
			next = "choose_destination",
		},

		choose_destination = {
			type = "choice",
			text = "Where would you like to go?",
			options = {
				{
					id = "market",
					text = "The market.",
					next = "market_directions",
				},
				{
					id = "leave",
					text = "Nowhere, thanks.",
					next = "goodbye",
				},
			},
		},

		market_directions = {
			type = "line",
			text = "Cross the bridge and turn left at the fountain.",
			next = "done",
		},

		goodbye = {
			type = "line",
			text = "Safe travels.",
			next = "done",
		},

		done = {
			type = "end",
			result = "conversation_finished",
		},
	},
})
```

`entry` points to the first node. Each node ID is a key in `nodes`, and transitions
such as `next` refer to those keys.

## Start it for the player

Connect the prompt after the definition:

```luau
prompt.Triggered:Connect(function(player)
	local session, startError = dialogue:Start(player, {
		npc = npc,
	})

	if not session then
		warn(`Could not start "{dialogue.Id}" for {player.Name}: {startError}`)
		return
	end
end)
```

Passing `npc` makes the instance available to conditions and actions through
`context.npc`. The bundled adapter does not move the camera or inspect this instance.

!!! note "One active session per player"

    A player cannot start a second dialogue until the current session completes or
    is cancelled. Handle the returned error instead of assuming that every trigger
    starts a session.

## What happens at runtime?

1. The server validates that the player is connected and their client is ready.
2. The server creates a session and sends the first presentation.
3. The client reveals the line with the bundled typewriter.
4. The server offers the choices after the presentation is acknowledged.
5. The selected option is validated on the server.
6. The server follows the selected `next` target.
7. Reaching `done` stores a completed outcome on the session.

You now have a working graph. Continue with [Dialogue graphs](../guides/dialogue-graphs.md)
to understand how visible and silent nodes interact.
