# Installation

MrDialogue runs on both the server and client. Install the package in a container
replicated to both environments, then start its client runtime from a `LocalScript`.

## Wally

Add MrDialogue to the `[dependencies]` section of your `wally.toml`:

```toml
[dependencies]
MrDialogue = "arakodev/mrdialogue@1.0.0"
```

Install the dependency:

```sh
wally install
```

Sync the generated `Packages` directory into `ReplicatedStorage` with Rojo. A typical
project mapping looks like this:

```json
{
  "name": "MyExperience",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Packages": {
        "$path": "Packages"
      }
    }
  }
}
```

!!! tip "Keep the package shared"

    Do not install MrDialogue as a server-only dependency. The server API owns
    dialogue state, while the client API owns presentation and player input.

## Start the server

Create a `Script` under `ServerScriptService` so the versioned dialogue remote is
available before clients start:

```luau title="ServerScriptService/DialogueServer.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage.Packages.MrDialogue.Server)
```

Requiring the server module once initializes networking. Dialogue scripts can require
the same module again; Roblox returns the cached module.

## Start the client

Create a `LocalScript` under `StarterPlayerScripts`:

```luau title="StarterPlayerScripts/DialogueClient.client.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Client)

MrDialogue.Start()
```

`MrDialogue.Start()` creates the bundled interface and tells the server that this
player is ready for dialogues. Calling it again returns the same client runtime.

!!! warning "Start the client before starting a session"

    `Dialogue:Start()` returns `"player dialogue client is not ready"` until the
    player's client runtime has connected. Starting the runtime from
    `StarterPlayerScripts` normally makes it ready before the player can trigger an
    NPC prompt. Client startup raises a clear timeout error if the server module was
    not initialized within 10 seconds.

## Verify the installation

Run the experience and inspect `ReplicatedStorage`:

```text
ReplicatedStorage
├── Packages
│   └── MrDialogue
└── MrDialogueRuntime
    └── DialogueRemoteV1
```

`MrDialogueRuntime` is created by the server automatically. Do not create or send
messages through its remote manually. MrDialogue rejects duplicate server package
copies instead of allowing independent session registries to share this remote.

## Next step

[Create your first dialogue](first-dialogue.md) and trigger it with a
`ProximityPrompt`.
