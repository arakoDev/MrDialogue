--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RUNTIME_NAME = "MrDialogueRuntime"
local REMOTE_NAME = "DialogueRemoteV1"
local PROTOCOL_ATTRIBUTE = "MrDialogueProtocolVersion"
local PACKAGE_ATTRIBUTE = "MrDialoguePackageVersion"
local OWNER_ATTRIBUTE = "MrDialogueServerOwner"

local Net = {}

Net.PROTOCOL_VERSION = 1
Net.PACKAGE_VERSION = "1.0.0"
Net.Limits = table.freeze({
	maxIdBytes = 128,
	maxTextBytes = 16 * 1024,
	maxSpeakerNameBytes = 256,
	maxIconBytes = 1024,
	maxResultBytes = 1024,
	maxReasonBytes = 256,
	maxChoices = 100,
	maxNodes = 10_000,
	maxArguments = 100,
	maxSilentSteps = 10_000,
	maxMessagesPerWindow = 120,
	messageWindowSeconds = 10,
	clientRemoteTimeoutSeconds = 10,
	sessionTimeoutSeconds = 120,
	maxSessionTimeoutSeconds = 3600,
	typewriterMaxGraphemes = 16_384,
	typewriterMaxRevealsPerHeartbeat = 512,
})

export type Limits = typeof(Net.Limits)

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
	version: number,
	type: "start",
	clientId: string,
	sessionId: string,
	dialogueId: string,
	freezeCharacter: boolean?,
	presentation: PresentationPayload?,
	choices: ChoicesPayload?,
}

export type PresentMessage = {
	version: number,
	type: "present",
	clientId: string,
	sessionId: string,
	turn: string,
	kind: "line" | "choice_prompt",
	speaker: SpeakerPayload?,
	text: string,
}

export type ChoicesMessage = {
	version: number,
	type: "choices",
	clientId: string,
	sessionId: string,
	turn: string,
	options: { ChoiceOptionPayload },
}

export type ReadyMessage = {
	version: number,
	type: "ready",
	clientId: string,
	sessionId: string,
	turn: string,
	interaction: "advance" | "finish",
}

export type EndMessage = {
	version: number,
	type: "end",
	clientId: string,
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
	version: number,
	type: "presentation_completed",
	clientId: string,
	sessionId: string,
	turn: string,
}

export type ChooseMessage = {
	version: number,
	type: "choose",
	clientId: string,
	sessionId: string,
	turn: string,
	index: number,
}

export type AdvanceMessage = {
	version: number,
	type: "advance",
	clientId: string,
	sessionId: string,
	turn: string,
}

export type CancelMessage = {
	version: number,
	type: "cancel",
	clientId: string,
	sessionId: string,
}

export type ClientErrorMessage = {
	version: number,
	type: "client_error",
	clientId: string,
	sessionId: string,
}

export type ClientReadyMessage = {
	version: number,
	type: "client_ready",
	clientId: string,
}

export type ClientStoppedMessage = {
	version: number,
	type: "client_stopped",
	clientId: string,
}

export type ClientMessage =
	PresentationCompletedMessage
	| ChooseMessage
	| AdvanceMessage
	| CancelMessage
	| ClientErrorMessage
	| ClientReadyMessage
	| ClientStoppedMessage

local remote: RemoteEvent? = nil
local serverOwnerId = HttpService:GenerateGUID(false)

local function validateProtocol(instance: RemoteEvent)
	local protocolVersion = instance:GetAttribute(PROTOCOL_ATTRIBUTE)
	if protocolVersion ~= Net.PROTOCOL_VERSION then
		error(
			`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} uses protocol {tostring(protocolVersion)}; MrDialogue {Net.PACKAGE_VERSION} requires protocol {Net.PROTOCOL_VERSION}`,
			3
		)
	end
end

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

-- Reject competing server copies before they share a remote.
function Net._initializeServer(): RemoteEvent
	if not RunService:IsServer() then
		error("MrDialogue server networking can only be initialized on the server", 2)
	end

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

		validateProtocol(existing)
		local existingOwner = existing:GetAttribute(OWNER_ATTRIBUTE)
		if existingOwner ~= serverOwnerId then
			error(
				`MrDialogue {Net.PACKAGE_VERSION} detected another server package copy using protocol {Net.PROTOCOL_VERSION}; require exactly one installed copy`,
				2
			)
		end

		remote = existing
		return existing
	end

	local created = Instance.new("RemoteEvent")
	created.Name = REMOTE_NAME
	created:SetAttribute(PROTOCOL_ATTRIBUTE, Net.PROTOCOL_VERSION)
	created:SetAttribute(PACKAGE_ATTRIBUTE, Net.PACKAGE_VERSION)
	created:SetAttribute(OWNER_ATTRIBUTE, serverOwnerId)
	created.Parent = runtime
	remote = created

	return created
end

function Net._getClientRemote(): RemoteEvent
	if not RunService:IsClient() then
		error("MrDialogue client networking can only be initialized on the client", 2)
	end

	local cached = remote
	if cached then
		return cached
	end

	local timeout = Net.Limits.clientRemoteTimeoutSeconds
	local runtime = ReplicatedStorage:WaitForChild(RUNTIME_NAME, timeout)
	if not runtime then
		error(
			`MrDialogue timed out after {timeout} seconds waiting for ReplicatedStorage.{RUNTIME_NAME}; require MrDialogue from a server Script before starting the client`,
			2
		)
	end
	if not runtime:IsA("Folder") then
		error(`ReplicatedStorage.{RUNTIME_NAME} must be a Folder`, 2)
	end

	local found = runtime:WaitForChild(REMOTE_NAME, timeout)
	if not found then
		error(
			`MrDialogue timed out after {timeout} seconds waiting for ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME}; verify the server package version`,
			2
		)
	end
	if not found:IsA("RemoteEvent") then
		error(`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} must be a RemoteEvent`, 2)
	end
	validateProtocol(found)
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
