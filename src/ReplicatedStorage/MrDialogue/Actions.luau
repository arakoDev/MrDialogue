--!strict

local Types = require(script.Parent.Types)

local Actions = {}

export type ExecutionResult = {
	success: boolean,
	code: string?,
	details: any?,
}

local handlers: { [string]: Types.ActionHandler } = {}

function Actions.Register(name: any, handler: any)
	if type(name) ~= "string" or name == "" then
		error("MrDialogue.RegisterAction requires a non-empty name", 3)
	end
	if type(handler) ~= "function" then
		error("MrDialogue.RegisterAction requires a function", 3)
	end
	if handlers[name] ~= nil then
		error(`MrDialogue.RegisterAction action "{name}" is already registered`, 3)
	end

	handlers[name] = handler
end

function Actions._isRegistered(name: string): boolean
	return handlers[name] ~= nil
end

function Actions._execute(spec: Types.ActionSpec, context: Types.DialogueContext): ExecutionResult
	local handler = handlers[spec.name]
	if not handler then
		return {
			success = false,
			code = "ACTION_NOT_REGISTERED",
			details = `no handler is registered for action "{spec.name}"`,
		}
	end

	local arguments = spec.arguments or {}
	local thread = coroutine.create(handler)
	local returned = table.pack(coroutine.resume(thread, context, table.unpack(arguments)))

	if not returned[1] then
		return {
			success = false,
			code = "ACTION_THROWN",
			details = returned[2],
		}
	end

	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)

		return {
			success = false,
			code = "ACTION_YIELDED",
			details = "action handlers must not yield",
		}
	end

	if returned.n == 1 or returned[2] == true then
		return {
			success = true,
		}
	end

	if returned[2] == false then
		return {
			success = false,
			code = "ACTION_FAILED",
			details = returned[3],
		}
	end

	return {
		success = false,
		code = "ACTION_INVALID_RESULT",
		details = "actions must return nothing, true, or false with optional details",
	}
end

return table.freeze(Actions)
