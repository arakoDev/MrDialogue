--!strict

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Net = require(script.Parent.Net)
local Types = require(script.Parent.Types)

local Session = {}
Session.__index = Session

export type Session = Types.Session

type SessionState = {
	definition: Types.DialogueDefinition,
	currentNodeId: string,
	npc: Instance?,
	data: { [string]: any },
	active: boolean,
	sessionId: string,
}

local states: { [Session]: SessionState } = setmetatable({}, { __mode = "k" }) :: any
local activeSessions: { [Player]: Session } = {}

function Session.new(
	player: Player,
	dialogueId: string,
	definition: Types.DialogueDefinition,
	options: Types.SessionOptions?
): (Session?, string?)
	if not RunService:IsServer() then
		error("Dialogue:Start can only be called on the server", 3)
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Dialogue:Start requires a Player", 3)
	end

	if options ~= nil and type(options) ~= "table" then
		error("Dialogue:Start options must be a table", 3)
	end

	if options and options.npc ~= nil and typeof(options.npc) ~= "Instance" then
		error("Dialogue:Start options.npc must be an Instance", 3)
	end

	if options and options.data ~= nil and type(options.data) ~= "table" then
		error("Dialogue:Start options.data must be a table", 3)
	end

	if player.Parent ~= Players then
		return nil, "player is not connected"
	end

	local existingSession = activeSessions[player]
	if existingSession and existingSession:IsActive() then
		return nil, "player already has an active dialogue session"
	end

	local self = setmetatable({
		Player = player,
		DialogueId = dialogueId,
	}, Session) :: any
	local data = if options and options.data then table.clone(options.data) else {}
	local sessionId = HttpService:GenerateGUID(false)

	states[self] = {
		definition = definition,
		currentNodeId = definition.entry,
		npc = if options then options.npc else nil,
		data = data,
		active = true,
		sessionId = sessionId,
	}
	activeSessions[player] = self

	local startMessage: Net.StartMessage = {
		type = "start",
		sessionId = sessionId,
		dialogueId = dialogueId,
	}
	
	local sent, sendError = pcall(function()
		Net._sendToClient(player, startMessage)
	end)

	if not sent then
		states[self] = nil
		if activeSessions[player] == self then
			activeSessions[player] = nil
		end
		error(sendError, 3)
	end

	return table.freeze(self) :: Session, nil
end

function Session.IsActive(self: Session): boolean
	local state = states[self]
	return state ~= nil and state.active
end

function Session._getActiveSession(player: Player): Session?
	local session = activeSessions[player]

	if session and session:IsActive() then
		return session
	end

	return nil
end

function Session._getDefinition(self: Session): Types.DialogueDefinition
	return states[self].definition
end

function Session._getCurrentNodeId(self: Session): string
	return states[self].currentNodeId
end

function Session._setCurrentNodeId(self: Session, nodeId: string)
	states[self].currentNodeId = nodeId
end

function Session._getNpc(self: Session): Instance?
	return states[self].npc
end

function Session._getData(self: Session): { [string]: any }
	return states[self].data
end

function Session._getSessionId(self: Session): string
	return states[self].sessionId
end

function Session._end(self: Session): boolean
	local state = states[self]

	if not state or not state.active then
		return false
	end

	state.active = false

	if activeSessions[self.Player] == self then
		activeSessions[self.Player] = nil
	end

	return true
end

return table.freeze(Session)
