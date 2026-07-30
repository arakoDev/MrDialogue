# Conditions and actions

Conditions read game state and choose which path is available. Actions apply game
state changes. Both are named handlers registered on the server.

<span class="mrd-badge mrd-badge--server">Server</span>

## Register a condition

```luau
MrDialogue.RegisterCondition("minimumLevel", function(context, requiredLevel)
	local profile = Profiles[context.player]
	return profile ~= nil and profile.Data.Level >= requiredLevel
end)
```

Reference it from a branch:

```luau
check_level = {
	type = "branch",
	condition = {
		name = "minimumLevel",
		arguments = { 10 },
	},
	onTrue = "qualified",
	onFalse = "too_low",
}
```

Or filter one choice:

```luau
{
	id = "restricted",
	text = "Enter the restricted area.",
	next = "enter",
	condition = {
		name = "minimumLevel",
		arguments = { 10 },
	},
}
```

Condition handlers must:

- Return a boolean.
- Finish synchronously without yielding.
- Treat all client-related state as untrusted.

If a condition throws, yields, or returns another type, MrDialogue warns and treats
the result as `false`. This is called failing closed.

## Register an action

```luau
MrDialogue.RegisterAction("startQuest", function(context, questId)
	local profile = Profiles[context.player]
	if not profile then
		return false, "profile is unavailable"
	end

	profile.Data.ActiveQuests[questId] = true
	return true
end)
```

Reference it from an action node:

```luau
start_quest = {
	type = "action",
	action = {
		name = "startQuest",
		arguments = { "find_the_map" },
	},
	next = "accepted",
}
```

An action reports success by returning nothing or `true`. It reports failure by
returning `false` and optional details:

```luau
return false, "quest is already active"
```

Action handlers must not yield. A failed handler cancels the session and logs a
specific warning code.

## Dialogue context

Every handler receives a `DialogueContext` first:

```luau
export type DialogueContext = {
	player: Player,
	dialogueId: string,
	session: Session,
	npc: Instance?,
	data: { [string]: any },
}
```

### `player`

The player whose session is being resolved.

### `dialogueId`

The ID supplied in the definition.

### `session`

The active session. Either kind of handler may call `context.session:Cancel()` when
appropriate. Resolution stops immediately after cancellation; later graph actions are
not executed.

### `npc`

The instance passed through `Dialogue:Start(player, { npc = instance })`.

### `data`

Session-local state created from `SessionOptions.data`. Use it to share temporary
values between handlers:

```luau
local session = dialogue:Start(player, {
	data = {
		offerId = "daily_sword",
	},
})
```

```luau
MrDialogue.RegisterCondition("isOffer", function(context, offerId)
	return context.data.offerId == offerId
end)
```

The input data table is shallow-cloned when the session starts.

## Registration order

Definitions may be created before handlers are registered. All referenced handlers
must be registered before `Dialogue:Start()`:

```luau
local dialogue = MrDialogue.new(definition)

MrDialogue.RegisterCondition("hasKey", hasKey)
MrDialogue.RegisterAction("consumeKey", consumeKey)

local session, startError = dialogue:Start(player)
```

Starting before registration returns an error instead of opening a partial session.
Names cannot be registered twice.

Handler names must be valid UTF-8 and are limited to 128 bytes. Each `arguments`
array is limited to 100 entries.

## Warning codes

| Code | Meaning |
| --- | --- |
| `CONDITION_NOT_REGISTERED` | A condition is unavailable during execution |
| `CONDITION_THROWN` | A condition raised an error |
| `CONDITION_YIELDED` | A condition attempted to yield |
| `CONDITION_INVALID_RESULT` | A condition did not return a boolean |
| `ACTION_NOT_REGISTERED` | An action is unavailable during execution |
| `ACTION_THROWN` | An action raised an error |
| `ACTION_YIELDED` | An action attempted to yield |
| `ACTION_FAILED` | An action returned `false` |
| `ACTION_INVALID_RESULT` | An action returned an unsupported value |
