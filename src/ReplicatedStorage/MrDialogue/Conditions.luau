--!strict

local Types = require(script.Parent.Types)

local Conditions = {}

local handlers: { [string]: Types.ConditionHandler } = {}

local function report(code: string, name: string, detail: any)
	warn(`[MrDialogue][{code}] Condition "{name}" failed closed: {tostring(detail)}`)
end

function Conditions.Register(name: any, handler: any)
	if type(name) ~= "string" or name == "" then
		error("MrDialogue.RegisterCondition requires a non-empty name", 3)
	end
	if type(handler) ~= "function" then
		error("MrDialogue.RegisterCondition requires a function", 3)
	end
	if handlers[name] ~= nil then
		error(`MrDialogue.RegisterCondition condition "{name}" is already registered`, 3)
	end

	handlers[name] = handler
end

function Conditions._isRegistered(name: string): boolean
	return handlers[name] ~= nil
end

-- Conditions are synchronous and fail closed if they throw, yield, or return the wrong type.
function Conditions._evaluate(spec: Types.ConditionSpec, context: Types.DialogueContext): boolean
	local handler = handlers[spec.name]
	if not handler then
		report("CONDITION_NOT_REGISTERED", spec.name, "no handler is registered")
		return false
	end

	local arguments = spec.arguments or {}
	local thread = coroutine.create(handler)
	local resumed = table.pack(coroutine.resume(thread, context, table.unpack(arguments)))
	if not resumed[1] then
		report("CONDITION_THROWN", spec.name, resumed[2])
		return false
	end

	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		report("CONDITION_YIELDED", spec.name, "handlers must not yield")
		return false
	end

	local result = resumed[2]
	if type(result) ~= "boolean" then
		report("CONDITION_INVALID_RESULT", spec.name, "handlers must return a boolean")
		return false
	end

	return result
end

return table.freeze(Conditions)
