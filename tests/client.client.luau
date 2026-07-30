--!nocheck

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.MrDialogue.Client)

assert(MrDialogue.Version == "1.0.0", "unexpected package version")
assert(MrDialogue.ProtocolVersion == 1, "unexpected protocol version")

local adapter = {}

function adapter:OnShow(info: any)
	assert(info.dialogueId == "smoke_test", "unexpected dialogue")
end

function adapter:OnPresentation(_presentation: any, actions: any)
	actions.presentationCompleted()
end

function adapter:OnAdvanceReady(_actions: any)
	error("unexpected advance")
end

function adapter:OnFinishReady(actions: any)
	actions.finish()
end

function adapter:OnChoices(_options: any, _actions: any)
	error("unexpected choices")
end

function adapter:OnEnd(outcome: any)
	assert(outcome.authoritative, "expected an authoritative outcome")
	assert(outcome.status == "completed", "dialogue did not complete")
	print("MrDialogue client smoke test passed")
end

MrDialogue.Start({
	adapter = adapter,
})
