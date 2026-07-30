--!nocheck

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local MrDialogue = require(ReplicatedStorage.MrDialogue.Server)

assert(MrDialogue.Version == "1.0.0", "unexpected package version")
assert(MrDialogue.ProtocolVersion == 1, "unexpected protocol version")

local dialogue = MrDialogue.new({
	format = 1,
	id = "smoke_test",
	entry = "start",
	nodes = {
		start = {
			type = "line",
			text = "Hello.",
			next = "done",
		},
		done = {
			type = "end",
			result = "ok",
		},
	},
})

assert(dialogue.Id == "smoke_test", "unexpected dialogue ID")

local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
local session
local startError

for _ = 1, 100 do
	session, startError = dialogue:Start(player)
	if session then
		break
	end
	if startError ~= "player dialogue client is not ready" then
		error(startError or "dialogue failed to start")
	end
	task.wait(0.05)
end

assert(session, startError or "client did not become ready")
local outcome = session:GetOutcome() or session.Ended:Wait()

assert(outcome.status == "completed", "dialogue did not complete")
assert(outcome.result == "ok", "unexpected dialogue result")
print("MrDialogue server smoke test passed")
