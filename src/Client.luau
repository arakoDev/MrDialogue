--!strict

local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	error("MrDialogue client API can only be required on the client", 2)
end

local Net = require(script.Parent.Net)
local ClientRuntimeClass = require(script.Parent.ClientRuntime)
local DefaultAdapterClass = require(script.Parent.DefaultAdapter)
local TypewriterClass = require(script.Parent.Typewriter)

export type Adapter = ClientRuntimeClass.Adapter
export type ClientRuntime = ClientRuntimeClass.ClientRuntime
export type PresentationActions = ClientRuntimeClass.PresentationActions
export type AdvanceActions = ClientRuntimeClass.AdvanceActions
export type FinishActions = ClientRuntimeClass.FinishActions
export type ChoiceActions = ClientRuntimeClass.ChoiceActions
export type EndOutcome = ClientRuntimeClass.EndOutcome
export type ShowInfo = ClientRuntimeClass.ShowInfo
export type SpeakerInfo = ClientRuntimeClass.SpeakerInfo
export type PresentationInfo = ClientRuntimeClass.PresentationInfo
export type ChoiceInfo = ClientRuntimeClass.ChoiceInfo
export type DefaultAdapter = DefaultAdapterClass.DefaultAdapter
export type DefaultAdapterConfig = DefaultAdapterClass.DefaultAdapterConfig
export type Typewriter = TypewriterClass.Typewriter
export type TypewriterConfig = TypewriterClass.TypewriterConfig
export type TypewriterCompletionOutcome = TypewriterClass.CompletionOutcome
export type Limits = Net.Limits

export type StartConfig = {
	adapter: Adapter?,
}

export type ClientApi = {
	Start: (config: StartConfig?) -> ClientRuntime,
	CancelActiveSession: () -> boolean,
	Stop: () -> boolean,
	Version: string,
	ProtocolVersion: number,
	Limits: Limits,
	DefaultAdapter: typeof(DefaultAdapterClass),
	Typewriter: typeof(TypewriterClass),
}

local Client = {}
local runtime: ClientRuntime? = nil
local ownedDefaultAdapter: DefaultAdapter? = nil

Client.Version = Net.PACKAGE_VERSION
Client.ProtocolVersion = Net.PROTOCOL_VERSION
Client.Limits = Net.Limits
Client.DefaultAdapter = DefaultAdapterClass
Client.Typewriter = TypewriterClass

function Client.Start(config: StartConfig?): ClientRuntime
	if config ~= nil and type(config) ~= "table" then
		error("MrDialogue.Start config must be a table", 2)
	end

	local existing = runtime
	if existing then
		return existing
	end

	local suppliedAdapter = if config then config.adapter else nil
	local defaultAdapter = if suppliedAdapter == nil then DefaultAdapterClass.new() else nil
	local started, result = pcall(ClientRuntimeClass.new, suppliedAdapter or defaultAdapter)
	if not started then
		if defaultAdapter then
			defaultAdapter:Destroy()
		end
		error(result, 2)
	end
	local newRuntime = result :: ClientRuntime

	runtime = newRuntime
	ownedDefaultAdapter = defaultAdapter
	return newRuntime
end

function Client.CancelActiveSession(): boolean
	if not runtime then
		return false
	end

	return ClientRuntimeClass._cancelActiveSession(runtime)
end

function Client.Stop(): boolean
	if not runtime then
		return false
	end

	local currentRuntime = runtime
	local currentDefaultAdapter = ownedDefaultAdapter
	runtime = nil
	ownedDefaultAdapter = nil

	local stopped = ClientRuntimeClass._stop(currentRuntime)
	if currentDefaultAdapter then
		currentDefaultAdapter:Destroy()
	end
	return stopped
end

return table.freeze(Client) :: ClientApi
