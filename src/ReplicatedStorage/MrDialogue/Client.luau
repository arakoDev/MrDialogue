--!strict

local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	error("MrDialogue client API can only be required on the client", 2)
end

local ClientRuntimeClass = require(script.Parent.ClientRuntime)

export type Adapter = ClientRuntimeClass.Adapter
export type ClientRuntime = ClientRuntimeClass.ClientRuntime

export type StartConfig = {
	adapter: Adapter,
}

local Client = {}
local runtime: ClientRuntime? = nil

function Client.Start(config: StartConfig): ClientRuntime
	if type(config) ~= "table" then
		error("MrDialogue.Client.Start requires a configuration table", 2)
	end

	if runtime then
		return runtime
	end

	local newRuntime = ClientRuntimeClass.new(config.adapter)
	runtime = newRuntime
	return newRuntime
end

return table.freeze(Client)
