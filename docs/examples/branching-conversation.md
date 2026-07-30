# Branching conversation

This example combines speakers, a conditional choice, a branch, an action, and a
session result.

## Register game handlers

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue.Server)

local playerState = {}

MrDialogue.RegisterCondition("hasCoins", function(context, amount)
	local state = playerState[context.player]
	return state ~= nil and state.coins >= amount
end)

MrDialogue.RegisterCondition("alreadyBoughtMap", function(context)
	local state = playerState[context.player]
	return state ~= nil and state.hasMap
end)

MrDialogue.RegisterAction("buyMap", function(context, price)
	local state = playerState[context.player]
	if not state or state.coins < price then
		return false, "not enough coins"
	end

	state.coins -= price
	state.hasMap = true
	return true
end)
```

Production games should connect these handlers to their authoritative profile or
inventory system. The table above keeps the example focused on dialogue flow.

## Define the merchant

```luau
local merchantDialogue = MrDialogue.new({
	format = 1,
	id = "merchant_map",
	entry = "check_purchase",

	speakers = {
		merchant = {
			name = "Map Merchant",
			icon = "rbxassetid://123456789",
			emotions = {
				happy = "rbxassetid://234567891",
			},
		},
	},
	defaultSpeaker = "merchant",
	freezeCharacter = true,

	nodes = {
		check_purchase = {
			type = "branch",
			condition = {
				name = "alreadyBoughtMap",
			},
			onTrue = "already_owned",
			onFalse = "offer",
		},

		already_owned = {
			type = "line",
			text = "Take good care of that map.",
			next = "leave",
		},

		offer = {
			type = "choice",
			text = "A map of the valley costs 25 coins.",
			options = {
				{
					id = "buy",
					text = "Buy the map.",
					next = "purchase",
					condition = {
						name = "hasCoins",
						arguments = { 25 },
					},
				},
				{
					id = "ask",
					text = "What is on the map?",
					next = "explain",
				},
				{
					id = "leave",
					text = "Maybe later.",
					next = "leave",
				},
			},
		},

		explain = {
			type = "line",
			text = "Every road, ruin, and shortcut I could find.",
			next = "offer",
		},

		purchase = {
			type = "action",
			action = {
				name = "buyMap",
				arguments = { 25 },
			},
			next = "purchased",
		},

		purchased = {
			type = "line",
			text = "A fine purchase. May it keep you on the path.",
			emotion = "happy",
			next = "bought",
		},

		bought = {
			type = "end",
			result = "map_bought",
		},

		leave = {
			type = "end",
			result = "left",
		},
	},
})
```

The `buy` option is absent when the player has fewer than 25 coins. The `ask` path
loops back only after presenting a visible line, so it is not a silent resolution
cycle.

## Start and inspect

```luau
script.Parent.Triggered:Connect(function(player)
	playerState[player] = playerState[player] or {
		coins = 50,
		hasMap = false,
	}

	local session, startError = merchantDialogue:Start(player, {
		npc = script.Parent:FindFirstAncestorOfClass("Model"),
	})

	if not session then
		warn(startError)
		return
	end

	local handled = false
	local function handleOutcome(outcome)
		if handled then
			return
		end
		handled = true
		if outcome and outcome.status == "completed" then
			print(player.Name, outcome.result)
		end
	end

	local connection = session.Ended:Connect(handleOutcome)
	local immediateOutcome = session:GetOutcome()
	if immediateOutcome then
		connection:Disconnect()
		handleOutcome(immediateOutcome)
	end
end)
```

Connecting before reading `GetOutcome()` handles both normal and immediately terminal
sessions without polling or missing a race.
