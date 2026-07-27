--!strict

local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	error("MrDialogue client API can only be required on the client", 2)
end

local ClientRuntimeClass = require(script.Parent.ClientRuntime)
local DefaultAdapterClass = require(script.Parent.DefaultAdapter)
local TypewriterClass = require(script.Parent.Typewriter)

export type Adapter = ClientRuntimeClass.Adapter
export type ClientRuntime = ClientRuntimeClass.ClientRuntime
export type EndOutcome = ClientRuntimeClass.EndOutcome
export type ShowInfo = ClientRuntimeClass.ShowInfo
export type DefaultAdapter = DefaultAdapterClass.DefaultAdapter
export type DefaultAdapterConfig = DefaultAdapterClass.Config
export type Typewriter = TypewriterClass.Typewriter
export type TypewriterConfig = TypewriterClass.TypewriterConfig
export type TypewriterCompletionOutcome = TypewriterClass.CompletionOutcome

export type StartConfig = {
	adapter: Adapter?,
}

local Client = {}
local runtime: ClientRuntime? = nil
local ownedDefaultAdapter: DefaultAdapter? = nil

Client.DefaultAdapter = DefaultAdapterClass
Client.Typewriter = TypewriterClass

function Client.Start(config: StartConfig?): ClientRuntime
	if config ~= nil and type(config) ~= "table" then
		error("MrDialogue.Client.Start requires a configuration table", 2)
	end

	if runtime then
		return runtime
	end

	local adapter: Adapter
	local defaultAdapter: DefaultAdapter? = nil
	if config and config.adapter ~= nil then
		adapter = config.adapter
	else
		local createdAdapter = DefaultAdapterClass.new()
		defaultAdapter = createdAdapter
		adapter = createdAdapter
	end

	local newRuntime = ClientRuntimeClass.new(adapter)
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

return table.freeze(Client)
