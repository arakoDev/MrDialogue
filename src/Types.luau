--!strict

export type SessionOutcome = {
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
}

export type Session = {
	Player: Player,
	DialogueId: string,
	Ended: RBXScriptSignal,
	IsActive: (self: Session) -> boolean,
	GetOutcome: (self: Session) -> SessionOutcome?,
	Cancel: (self: Session, reason: string?) -> boolean,
}

export type SessionOptions = {
	npc: Instance?,
	data: { [string]: any }?,
	timeoutSeconds: number?,
}

export type DialogueContext = {
	player: Player,
	dialogueId: string,
	session: Session,
	npc: Instance?,
	data: { [string]: any },
}

export type ConditionHandler = (context: DialogueContext, ...any) -> boolean
export type ActionHandler = (context: DialogueContext, ...any) -> ...any

export type ConditionSpec = {
	name: string,
	arguments: { any }?,
}

export type ActionSpec = {
	name: string,
	arguments: { any }?,
}

export type SpeakerDefinition = {
	name: string,
	icon: string?,
	emotions: { [string]: string }?,
}

type PresentationFields = {
	speaker: (string | false)?,
	emotion: string?,
}

export type LineNode = PresentationFields & {
	type: "line",
	text: string,
	next: string?,
}

export type ChoiceOption = {
	id: string,
	text: string,
	next: string,
	condition: ConditionSpec?,
}

export type ChoiceNode = PresentationFields & {
	type: "choice",
	text: string?,
	options: { ChoiceOption },
	fallback: string?,
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

export type DialogueNode = LineNode | ChoiceNode | BranchNode | ActionNode | EndNode

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

export type Dialogue = {
	Id: string,
	Start: (self: Dialogue, player: Player, options: SessionOptions?) -> (Session?, string?),
}

return {}
