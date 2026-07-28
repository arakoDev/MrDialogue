--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RUNTIME_NAME = "MrDialogueRuntime"
local REMOTE_NAME = "DialogueRemote"

local Net = {}

export type SpeakerPayload = {
	name: string,
	icon: string?,
}

export type PresentationPayload = {
	turn: string,
	kind: "line" | "choice_prompt",
	speaker: SpeakerPayload?,
	text: string,
}

export type ChoiceOptionPayload = {
	text: string,
}

export type ChoicesPayload = {
	turn: string,
	options: { ChoiceOptionPayload },
}

export type StartMessage = {
	type: "start",
	sessionId: string,
	dialogueId: string,
	freezeCharacter: boolean?,
	presentation: PresentationPayload?,
	choices: ChoicesPayload?,
}

export type PresentMessage = {
	type: "present",
	sessionId: string,
	turn: string,
	kind: "line" | "choice_prompt",
	speaker: SpeakerPayload?,
	text: string,
}

export type ChoicesMessage = {
	type: "choices",
	sessionId: string,
	turn: string,
	options: { ChoiceOptionPayload },
}

export type ReadyMessage = {
	type: "ready",
	sessionId: string,
	turn: string,
	interaction: "advance" | "finish",
}

export type EndMessage = {
	type: "end",
	sessionId: string,
	status: "completed" | "cancelled",
	result: string?,
	reason: string?,
}

export type ServerMessage =
	StartMessage
	| PresentMessage
	| ChoicesMessage
	| ReadyMessage
	| EndMessage

export type PresentationCompletedMessage = {
	type: "presentation_completed",
	sessionId: string,
	turn: string,
}

export type ChooseMessage = {
	type: "choose",
	sessionId: string,
	turn: string,
	index: number,
}

export type AdvanceMessage = {
	type: "advance",
	sessionId: string,
	turn: string,
}

export type CancelMessage = {
	type: "cancel",
	sessionId: string,
}

export type ClientReadyMessage = {
	type: "client_ready",
}

export type ClientStoppedMessage = {
	type: "client_stopped",
}

export type ClientMessage =
	PresentationCompletedMessage
	| ChooseMessage
	| AdvanceMessage
	| CancelMessage
	| ClientReadyMessage
	| ClientStoppedMessage

local remote: RemoteEvent? = nil

local function getRuntimeFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(RUNTIME_NAME)
	if existing then
		if not existing:IsA("Folder") then
			error(`ReplicatedStorage.{RUNTIME_NAME} must be a Folder`, 2)
		end
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = RUNTIME_NAME
	folder.Parent = ReplicatedStorage

	return folder
end

-- Installed copies share one RemoteEvent.
function Net._initializeServer(): RemoteEvent
	local cached = remote
	if cached then
		return cached
	end

	local runtime = getRuntimeFolder()
	local existing = runtime:FindFirstChild(REMOTE_NAME)
	if existing then
		if not existing:IsA("RemoteEvent") then
			error(`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} must be a RemoteEvent`, 2)
		end
		remote = existing
		return existing
	end

	local created = Instance.new("RemoteEvent")
	created.Name = REMOTE_NAME
	created.Parent = runtime
	remote = created

	return created
end

function Net._getClientRemote(): RemoteEvent
	local cached = remote
	if cached then
		return cached
	end

	local runtime = ReplicatedStorage:WaitForChild(RUNTIME_NAME)
	if not runtime:IsA("Folder") then
		error(`ReplicatedStorage.{RUNTIME_NAME} must be a Folder`, 2)
	end

	local found = runtime:WaitForChild(REMOTE_NAME)
	if not found:IsA("RemoteEvent") then
		error(`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} must be a RemoteEvent`, 2)
	end
	remote = found

	return found
end

function Net._sendToClient(player: Player, message: ServerMessage)
	Net._initializeServer():FireClient(player, message)
end

function Net._sendToServer(message: ClientMessage)
	Net._getClientRemote():FireServer(message)
end

function Net._connectServer(handler: (player: Player, message: any) -> ()): RBXScriptConnection
	return Net._initializeServer().OnServerEvent:Connect(handler)
end

function Net._connectClient(handler: (message: ServerMessage) -> ()): RBXScriptConnection
	return Net._getClientRemote().OnClientEvent:Connect(handler)
end

return table.freeze(Net)
