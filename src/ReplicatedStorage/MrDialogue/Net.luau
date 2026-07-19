--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RUNTIME_NAME = "MrDialogueRuntime"
local REMOTE_NAME = "DialogueRemote"

local Net = {}

export type SpeakerPayload = {
	name: string,
	icon: string?,
}

export type PresentationPayload = {
	turn: string,
	kind: "line",
	speaker: SpeakerPayload?,
	text: string,
}

export type StartMessage = {
	type: "start",
	sessionId: string,
	dialogueId: string,
	presentation: PresentationPayload,
}

export type PresentMessage = PresentationPayload & {
	type: "present",
	sessionId: string,
}

export type ServerMessage = StartMessage | PresentMessage

local cachedRemote: RemoteEvent? = nil

local function getExistingRuntime(): Folder?
	local existing = ReplicatedStorage:FindFirstChild(RUNTIME_NAME)
	if not existing then
		return nil
	end

	if not existing:IsA("Folder") then
		error(`ReplicatedStorage.{RUNTIME_NAME} must be a Folder`, 3)
	end

	return existing
end

local function getExistingRemote(runtime: Folder): RemoteEvent?
	local remote = cachedRemote
	if remote and remote.Parent == runtime and remote.Name == REMOTE_NAME then
		return remote
	end

	local existing = runtime:FindFirstChild(REMOTE_NAME)
	if not existing then
		return nil
	end

	if not existing:IsA("RemoteEvent") then
		error(`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} must be a RemoteEvent`, 3)
	end

	cachedRemote = existing
	return existing
end

function Net._initializeServer(): RemoteEvent
	if not RunService:IsServer() then
		error("MrDialogue networking can only be initialized on the server", 2)
	end

	local existingRuntime = getExistingRuntime()
	local runtime: Folder
	if existingRuntime then
		runtime = existingRuntime
	else
		runtime = Instance.new("Folder")
		runtime.Name = RUNTIME_NAME
		runtime.Parent = ReplicatedStorage
	end

	local existing = getExistingRemote(runtime)
	if existing then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = runtime
	cachedRemote = remote

	return remote
end

function Net._getClientRemote(): RemoteEvent
	if not RunService:IsClient() then
		error("MrDialogue client networking can only be used on the client", 2)
	end

	local existingRuntime = getExistingRuntime()
	local runtime: Folder
	if existingRuntime then
		runtime = existingRuntime
	else
		local instance = ReplicatedStorage:WaitForChild(RUNTIME_NAME)
		if not instance:IsA("Folder") then
			error(`ReplicatedStorage.{RUNTIME_NAME} must be a Folder`, 2)
		end
		runtime = instance
	end

	local existing = getExistingRemote(runtime)
	if existing then
		return existing
	end

	local remote = runtime:WaitForChild(REMOTE_NAME)
	if not remote:IsA("RemoteEvent") then
		error(`ReplicatedStorage.{RUNTIME_NAME}.{REMOTE_NAME} must be a RemoteEvent`, 2)
	end

	cachedRemote = remote
	return remote
end

function Net._sendToClient(player: Player, message: ServerMessage)
	Net._initializeServer():FireClient(player, message)
end

function Net._connectClient(handler: (message: ServerMessage) -> ()): RBXScriptConnection
	return Net._getClientRemote().OnClientEvent:Connect(handler)
end

return table.freeze(Net)
