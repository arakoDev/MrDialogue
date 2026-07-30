# Sessions

A `Session` is one run of one dialogue for one player. The server owns it from
`Dialogue:Start()` until completion or cancellation.

<span class="mrd-badge mrd-badge--server">Server</span>

## Start a session

```luau
local session, startError = dialogue:Start(player, {
	npc = workspace.Guide,
	timeoutSeconds = 120,
	data = {
		questId = "find_the_map",
	},
})

if not session then
	warn(startError)
	return
end
```

Only one active session is allowed per player.

`Dialogue:Start()` can return an error when:

- A referenced condition or action is not registered.
- The player is no longer connected.
- The player's client runtime is not ready.
- The player already has an active session.

Invalid argument types raise an error because they indicate a programming mistake.
Expected runtime conflicts are returned as `(nil, message)`.

`timeoutSeconds` controls the inactivity timeout for this run. It resets after every
accepted client response, defaults to 120 seconds, and cannot exceed 3600 seconds.

## Inspect a session

```luau
print(session.Player)
print(session.DialogueId)
print(session:IsActive())
```

`Player` and `DialogueId` are read-only public properties.

## Read the outcome

```luau
local outcome = session:GetOutcome()
if outcome then
	if outcome.status == "completed" then
		print("Result:", outcome.result)
	else
		print("Cancelled:", outcome.reason)
	end
end
```

While the session is active, `GetOutcome()` returns `nil`.

For event-driven server code, connect `Ended`:

```luau
session.Ended:Connect(function(outcome)
	if outcome.status == "completed" then
		print("Result:", outcome.result)
	else
		warn("Cancelled:", outcome.reason)
	end
end)
```

Immediately terminal graphs may finish before `Dialogue:Start()` returns, so also
check `GetOutcome()` once after connecting.

For a session that opened the client interface, the final client outcome is queued
before `Ended` fires. An `Ended` listener can therefore start the player's next
dialogue without racing the previous client session.

Completed outcomes have this shape:

```luau
{
	status = "completed",
	result = "quest_accepted", -- optional
}
```

Cancelled outcomes have this shape:

```luau
{
	status = "cancelled",
	reason = "death",
}
```

## Cancel from the server

```luau
session:Cancel()
```

The default reason is `"manual"`. Application-specific reasons must be namespaced:

```luau
session:Cancel("quest:expired")
session:Cancel("npc:despawned")
```

A valid namespaced reason has the form `namespace:value`. Calling `Cancel()` on an
inactive session returns `false`.

## Built-in cancellation reasons

| Reason | Cause |
| --- | --- |
| `manual` | `Session:Cancel()` without a reason |
| `client_cancelled` | The client cancels or stops its runtime |
| `client_error` | The client runtime or adapter rejected a callback or payload |
| `client_restarted` | A newly started client replaced a stale active runtime |
| `death` | The player's humanoid dies |
| `player_left` | The player leaves the server |
| `timeout` | The client did not respond within the session inactivity timeout |
| `rate_limited` | The client exceeded the dialogue message rate limit |
| `network_error` | A client presentation or interaction update could not be sent |
| `no_available_options` | A choice has no valid option or fallback |
| `resolution_error` | Silent nodes form a cycle |
| `action_error` | An action throws, yields, fails, or returns an invalid result |

## Character death

By default, a session is cancelled when the player's current humanoid dies. Disable
this per definition:

```luau
local dialogue = MrDialogue.new({
	format = 1,
	id = "respawn_tutorial",
	entry = "start",
	endDialogueOnDeath = false,
	nodes = {
		start = {
			type = "end",
		},
	},
})
```

`endDialogueOnDeath` controls the server session. `freezeCharacter` separately
controls the bundled client adapter's movement behavior.
