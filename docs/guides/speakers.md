# Speakers and emotions

Speakers attach display names and image asset IDs to line text and choice prompts.
They are part of the dialogue definition and are resolved by the server.

## Define speakers

```luau
local dialogue = MrDialogue.new({
	format = 1,
	id = "blacksmith",
	entry = "hello",

	speakers = {
		blacksmith = {
			name = "Mara",
			icon = "rbxassetid://123456789",
			emotions = {
				happy = "rbxassetid://234567891",
				concerned = "rbxassetid://345678912",
			},
		},
		player = {
			name = "You",
		},
	},

	defaultSpeaker = "blacksmith",
	defaultIcon = "rbxassetid://456789123",

	nodes = {
		hello = {
			type = "line",
			text = "The forge is finally hot.",
			emotion = "happy",
			next = "reply",
		},
		reply = {
			type = "line",
			text = "Can you repair my sword?",
			speaker = "player",
			next = "done",
		},
		done = {
			type = "end",
		},
	},
})
```

`defaultSpeaker` applies when a line or choice prompt omits `speaker`.

## Icon resolution

MrDialogue chooses an icon in this order:

1. The image mapped by the node's `emotion`.
2. The speaker's `icon`.
3. `DialogueDefinition.defaultIcon`.
4. No icon.

An empty icon string explicitly resolves to no image.

## Narration

Set `speaker = false` to override `defaultSpeaker` for a narration line:

```luau
storm = {
	type = "line",
	text = "Thunder rolls over the valley.",
	speaker = false,
	next = "warning",
}
```

Narration contains no speaker payload. It cannot have an emotion.

## Validation rules

- Speaker IDs and emotion IDs must be non-empty strings.
- `defaultSpeaker` must refer to a defined speaker.
- A node's string `speaker` must refer to a defined speaker.
- A node's `emotion` must exist on its resolved speaker.
- `speaker` and `emotion` are valid only on lines and choice nodes with prompt text.

!!! note "Dynamic names"

    Speaker definitions are static data. For a dynamic player name, either build the
    definition with the name before calling `MrDialogue.new()` or render it inside a
    custom adapter based on your own application data.
