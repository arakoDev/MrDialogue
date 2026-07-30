# Nodes

MrDialogue supports five node types. Every node is stored under a unique string ID in
`DialogueDefinition.nodes`.

| Type | Visible | Purpose |
| --- | :---: | --- |
| [`line`](#line) | Yes | Present text and optionally continue |
| [`choice`](#choice) | Yes | Present one or more filtered options |
| [`branch`](#branch) | No | Choose a path from a server condition |
| [`action`](#action) | No | Run a synchronous server handler |
| [`end`](#end) | No | Complete the session with an optional result |

## Line

```luau
introduction = {
	type = "line",
	text = "Welcome to the village.",
	speaker = "guide",
	emotion = "happy",
	next = "question",
}
```

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `type` | `"line"` | Yes | Node discriminator |
| `text` | `string` | Yes | Text sent to the client |
| `next` | `string?` | No | Next node ID; omitting it finishes after confirmation |
| `speaker` | `string \| false` | No | Speaker ID, or `false` for narration |
| `emotion` | `string?` | No | Emotion defined by the resolved speaker |

A line is complete only after the adapter calls `presentationCompleted`. The server
then decides whether the next input advances to another node or finishes the
conversation.

## Choice

```luau
destination = {
	type = "choice",
	text = "Where are you going?",
	options = {
		{
			id = "market",
			text = "The market.",
			next = "market",
		},
		{
			id = "castle",
			text = "The castle.",
			next = "castle",
			condition = {
				name = "hasInvitation",
			},
		},
	},
	fallback = "no_destinations",
}
```

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `type` | `"choice"` | Yes | Node discriminator |
| `text` | `string?` | No | Prompt shown before the options |
| `options` | `{ ChoiceOption }` | Yes | Non-empty dense array |
| `fallback` | `string?` | No | Target used when every option is filtered out |
| `speaker` | `string \| false` | No | Speaker for `text` |
| `emotion` | `string?` | No | Emotion for `text` |

If `text` is absent, options appear immediately. A promptless choice cannot set a
speaker or emotion.

Each option contains:

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `id` | `string` | Yes | Authoring identifier unique within this node |
| `text` | `string` | Yes | Text displayed to the player |
| `next` | `string` | Yes | Target node ID |
| `condition` | `ConditionSpec?` | No | Server condition controlling availability |

The client receives only option text and a temporary index. IDs, conditions, and
targets stay on the server.

In 1.0, option IDs are validation and authoring metadata; runtime selection uses the
temporary index. The bundled adapter prefixes displayed text with that index and
removes an existing leading numeric prefix to avoid duplication.

If no options remain and there is no `fallback`, the session is cancelled with
`reason = "no_available_options"`.

## Branch

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

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `type` | `"branch"` | Yes | Node discriminator |
| `condition` | `ConditionSpec` | Yes | Condition evaluated on the server |
| `onTrue` | `string` | Yes | Target when the condition returns `true` |
| `onFalse` | `string` | Yes | Target when the condition returns `false` |

Branches are silent and can be chained. A silent cycle is detected and cancels the
session with `reason = "resolution_error"`.

## Action

```luau
accept_quest = {
	type = "action",
	action = {
		name = "startQuest",
		arguments = { "find_the_map" },
	},
	next = "accepted",
}
```

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `type` | `"action"` | Yes | Node discriminator |
| `action` | `ActionSpec` | Yes | Server action to execute |
| `next` | `string?` | No | Target after success |

An action without `next` acts like an implicit end. A thrown, yielded, failed, or
invalid action result cancels the session with `reason = "action_error"`.

## End

```luau
accepted = {
	type = "end",
	result = "quest_accepted",
}
```

| Field | Type | Required | Description |
| --- | --- | :---: | --- |
| `type` | `"end"` | Yes | Node discriminator |
| `result` | `string?` | No | Application-defined completion result |

Results have no built-in meaning. Read them with `Session:GetOutcome()` or
`Session.Ended`. A custom adapter receives them in `OnEnd` when the session opened a
client presentation.
