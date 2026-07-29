# Types

MrDialogue exports its public types from the same module as its runtime API.
The server and client receive different APIs, so use type imports in code that
runs in the matching context.

## Dialogue definition

```luau
export type DialogueDefinition = {
	format: number,
	id: string,
	entry: string,
	nodes: { [string]: DialogueNode },
	speakers: { [string]: SpeakerDefinition }?,
	defaultSpeaker: string?,
	defaultIcon: string?,
	freezeCharacter: boolean?,
	endDialogueOnDeath: boolean?,
}
```

`format` currently accepts only `1`.

## Nodes

```luau
export type LineNode = {
	type: "line",
	text: string,
	next: string?,
	speaker: (string | false)?,
	emotion: string?,
}

export type ChoiceOption = {
	id: string,
	text: string,
	next: string,
	condition: ConditionSpec?,
}

export type ChoiceNode = {
	type: "choice",
	text: string?,
	options: { ChoiceOption },
	fallback: string?,
	speaker: (string | false)?,
	emotion: string?,
}

export type BranchNode = {
	type: "branch",
	condition: ConditionSpec,
	onTrue: string,
	onFalse: string,
}

export type ActionNode = {
	type: "action",
	action: ActionSpec,
	next: string?,
}

export type EndNode = {
	type: "end",
	result: string?,
}

export type DialogueNode =
	LineNode
	| ChoiceNode
	| BranchNode
	| ActionNode
	| EndNode
```

See [Nodes](../guides/nodes.md) for runtime behavior and examples.

## Speakers

```luau
export type SpeakerDefinition = {
	name: string,
	icon: string?,
	emotions: { [string]: string }?,
}
```

Speaker keys are local to one dialogue definition. `name` is the displayed
label, while icons are Roblox content strings such as `rbxassetid://123`.

## Conditions and actions

```luau
export type ConditionSpec = {
	name: string,
	arguments: { any }?,
}

export type ActionSpec = {
	name: string,
	arguments: { any }?,
}

export type DialogueContext = {
	player: Player,
	dialogueId: string,
	session: Session,
	npc: Instance?,
	data: { [string]: any },
}

export type ConditionHandler =
	(context: DialogueContext, ...any) -> boolean

export type ActionHandler =
	(context: DialogueContext, ...any) -> ...any
```

Arguments from a spec are unpacked after `context`.

## Sessions

```luau
export type SessionOptions = {
	npc: Instance?,
	data: { [string]: any }?,
}

export type SessionOutcome = {
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
}

export type Session = {
	Player: Player,
	DialogueId: string,
	IsActive: (self: Session) -> boolean,
	GetOutcome: (self: Session) -> SessionOutcome?,
	Cancel: (self: Session, reason: string?) -> boolean,
}
```

MrDialogue shallow-clones the `data` table when a session starts. The session's
conditions and actions share that clone.

## Client adapter

```luau
export type ShowInfo = {
	dialogueId: string,
	freezeCharacter: boolean?,
}

export type PresentationInfo = {
	kind: "line" | "choice_prompt",
	speaker: {
		name: string,
		icon: string?,
	}?,
	text: string,
}

export type EndOutcome = {
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
	authoritative: boolean,
}

export type Adapter = {
	OnShow: (self: Adapter, info: ShowInfo) -> (),
	OnPresentation: (
		self: Adapter,
		presentation: PresentationInfo,
		actions: { presentationCompleted: () -> () }
	) -> (),
	OnAdvanceReady: (
		self: Adapter,
		actions: { advance: () -> () }
	) -> (),
	OnFinishReady: (
		self: Adapter,
		actions: { finish: () -> () }
	) -> (),
	OnChoices: (
		self: Adapter,
		options: { { text: string } },
		actions: { choose: (index: number) -> () }
	) -> (),
	OnEnd: (self: Adapter, outcome: EndOutcome) -> (),
}
```

Adapter action callbacks are scoped to the state that created them. Calling a
stale callback does nothing.

## Client configuration

```luau
export type StartConfig = {
	adapter: Adapter?,
}

export type DefaultAdapterConfig = {
	gui: ScreenGui?,
	charsPerSecond: number?,
	punctuationPause: number?,
	freezeCharacter: boolean?,
}

export type TypewriterConfig = {
	charsPerSecond: number?,
	punctuationPause: number?,
}

export type TypewriterCompletionOutcome =
	"natural" | "skipped" | "cancelled"
```

[:octicons-code-16: Server type source](https://github.com/arakoDev/MrDialogue/blob/main/src/Types.luau)
[:octicons-code-16: Client type source](https://github.com/arakoDev/MrDialogue/blob/main/src/ClientRuntime.luau)
