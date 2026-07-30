<div align="center">

<img height="100" src="./assets/logo.svg" alt="MrDialogue Logo">

<h1>MrDialogue</h1>

<p>A dialogue package for Roblox.</p>

<p>
  <a href="https://wally.run/package/arakodev/mrdialogue" target="_blank" rel="noopener noreferrer"><img src="./assets/wally.svg" alt="Wally" height="24"></a>
  <a href="https://create.roblox.com/store/asset/105201219018918/MrDialogue-v100" target="_blank" rel="noopener noreferrer"><img src="./assets/creatorhub.svg" alt="Creator Store" height="24"></a>
</p>

<p>
  <a href="https://mrdialogue.arako.dev/" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/badge/docs-mrdialogue.arako.dev-blue?style=flat-square" alt="Documentation"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/version-1.0.0-blue?style=flat-square" alt="Package version">
</p>

</div>

## Introduction

MrDialogue lets Roblox experiences define conversations as data and run them for individual players from the server. Use the included dialogue UI or connect the runtime to your own interface.

## Features

- **Graph-Based:** Build branching conversations from line, choice, branch, action, and end nodes.
- **Server-Authoritative:** Conditions, actions, choices, and dialogue state are evaluated and controlled by the server.
- **Customizable:** Use the included UI or supply a custom client adapter.
- **Typed and Validated:** The package uses strict Luau types and validates dialogue definitions and client adapters.

## Usage Example

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

[**Read the full MrDialogue documentation →**](https://mrdialogue.arako.dev/)

## License

MrDialogue is available under the [MIT License](./LICENSE).
