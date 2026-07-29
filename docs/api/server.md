# Server API

<span class="mrd-badge mrd-badge--server">Server</span>

Require MrDialogue from a server `Script` to create dialogues, register handlers,
and start sessions.

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue)
```

## MrDialogue

### `MrDialogue.new`

```luau
MrDialogue.new(definition: DialogueDefinition): Dialogue
```

Validates a dialogue definition and returns an immutable `Dialogue`.

The definition is deep-copied before it is stored. Mutating the original table
after this call does not alter the dialogue.

**Throws when:** the definition is malformed, a transition points to a missing
node, a speaker or emotion is unknown, or a field has the wrong type.

Handlers referenced by conditions and actions do not need to be registered until
the dialogue is started.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Dialogue.luau)

### `MrDialogue.RegisterCondition`

```luau
MrDialogue.RegisterCondition(
    name: string,
    handler: (context: DialogueContext, ...any) -> boolean
): ()
```

Registers a global condition handler. Names must be non-empty and unique.
Handlers must return a boolean without yielding. A handler that throws, yields,
or returns another type fails closed and produces a warning.

```luau
MrDialogue.RegisterCondition("hasCoins", function(context, amount)
	return context.data.coins >= amount
end)
```

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Conditions.luau)

### `MrDialogue.RegisterAction`

```luau
MrDialogue.RegisterAction(
    name: string,
    handler: (context: DialogueContext, ...any) -> ...any
): ()
```

Registers a global action handler. Names must be non-empty and unique. Actions
are synchronous and may return:

| Return | Meaning |
| --- | --- |
| no values | Success |
| `true` | Success |
| `false, details?` | Failure |

Throwing, yielding, returning an invalid value, or explicitly failing cancels
the session with reason `action_error`.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Actions.luau)

## Dialogue

Created by `MrDialogue.new`.

### `Dialogue.Id`

```luau
Dialogue.Id: string
```

<span class="mrd-badge mrd-badge--readonly">Read only</span>

The ID from `definition.id`.

### `Dialogue:Start`

```luau
Dialogue:Start(
    player: Player,
    options: SessionOptions?
): (Session?, string?)
```

Starts an independent session for `player`.

```luau
local session, startError = dialogue:Start(player, {
	npc = workspace.Guide,
	data = {
		questId = "find_the_map",
	},
})

if not session then
	warn(startError)
end
```

When the request is valid but cannot start, it returns `nil` and a message:

| Message | Cause |
| --- | --- |
| `player is not connected` | The player has left `Players`. |
| `player dialogue client is not ready` | `MrDialogue.Start()` has not initialized on that client yet. |
| `player already has an active dialogue session` | A player can have only one active session. |
| `... is not registered` | A referenced condition or action handler is missing. |

Invalid argument types throw instead of returning an error message.

!!! note

    A graph that resolves immediately to an `end` node still returns a
    `Session`, but it is already inactive.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Dialogue.luau)

## Session

A session represents one player's run through a dialogue.

### Properties

```luau
Session.Player: Player
Session.DialogueId: string
```

<span class="mrd-badge mrd-badge--readonly">Read only</span>

### `Session:IsActive`

```luau
Session:IsActive(): boolean
```

Returns `true` while the dialogue is accepting progress from the client.

### `Session:GetOutcome`

```luau
Session:GetOutcome(): SessionOutcome?
```

Returns `nil` while active, then the final completed or cancelled outcome.

```luau
local outcome = session:GetOutcome()
if outcome and outcome.status == "completed" then
	print(outcome.result)
end
```

### `Session:Cancel`

```luau
Session:Cancel(reason: string?): boolean
```

Cancels an active session. Returns `true` if this call ended the session and
`false` if it had already ended.

The default reason is `manual`. Custom reasons must be namespaced, for example
`quest:abandoned` or `npc:despawned`.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Session.luau)
