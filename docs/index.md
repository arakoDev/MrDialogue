---
hide:
  - navigation
  - toc
---

<div class="mrd-intro" markdown>

# MrDialogue

A dialogue package for Roblox.

[Get started](getting-started/installation.md){ .md-button .md-button--primary }
[API reference](api/server.md){ .md-button .mrd-button--secondary }

</div>

MrDialogue defines conversations as graphs composed of line, choice, branch, action,
and end nodes. Dialogue state, conditions, and actions run on the server. The package
includes a client interface and supports custom adapters.

## Installation

Install MrDialogue with Wally or get the model from the Roblox Creator Store:

[Install with Wally](/getting-started/installation/#__tabbed_1_1){ .md-button .md-button--primary }
[Get it from Creator Store](/getting-started/installation/#__tabbed_1_2){ .md-button .mrd-button--secondary }

## Example

MrDialogue runs on both the client and server. Start the client runtime once, then
start server-owned dialogue definitions in response to player interactions.

### Client

Create a `LocalScript` under `StarterPlayerScripts`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Client)

MrDialogue.Start()
```

### Server

Create a server `Script` under a `ProximityPrompt`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Server)

local dialogue = MrDialogue.new({
	format = 1,
	id = "directions",
	entry = "greeting",
	nodes = {
		greeting = {
			type = "line",
			text = "Do you need directions?",
			next = "answer",
		},
		answer = {
			type = "choice",
			options = {
				{ id = "yes", text = "Yes.", next = "directions" },
				{ id = "no", text = "No, thanks.", next = "done" },
			},
		},
		directions = {
			type = "line",
			text = "Follow the road north.",
			next = "done",
		},
		done = {
			type = "end",
		},
	},
})

script.Parent.Triggered:Connect(function(player)
	local session, startError = dialogue:Start(player)
	if not session then
		warn(`Could not start dialogue: {startError}`)
	end
end)
```

## Documentation

- [Install MrDialogue](getting-started/installation.md)
- [Create a dialogue](getting-started/first-dialogue.md)
- [Dialogue graphs](guides/dialogue-graphs.md)
- [Server API](api/server.md)
- [Client API](api/client.md)
