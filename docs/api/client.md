# Client API

<span class="mrd-badge mrd-badge--client">Client</span>

On the client, requiring the same package returns the client API.

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue)
```

## Lifecycle

### `MrDialogue.Start`

```luau
MrDialogue.Start(config: { adapter: Adapter? }?): ClientRuntime
```

Initializes the client and tells the server it is ready. Calling it again
returns the existing runtime.

Without an adapter, MrDialogue creates and owns a `DefaultAdapter`.

```luau
local runtime = MrDialogue.Start()
```

With a custom adapter:

```luau
local runtime = MrDialogue.Start({
	adapter = MyDialogueAdapter.new(),
})
```

### `MrDialogue.CancelActiveSession`

```luau
MrDialogue.CancelActiveSession(): boolean
```

Requests cancellation of the active session. Returns `true` when a request was
sent; returns `false` when the client is not started, has no active session, or
already sent a cancellation request.

The server records this cancellation as `client_cancelled`.

### `MrDialogue.Stop`

```luau
MrDialogue.Stop(): boolean
```

Disconnects the client runtime and destroys the owned default adapter. Returns
`false` if the client was not started.

If a session was active, the adapter receives a local, non-authoritative
cancelled outcome while the server receives a cancellation request.

## ClientRuntime

### `ClientRuntime:IsActive`

```luau
ClientRuntime:IsActive(): boolean
```

Returns whether this runtime currently has an active dialogue.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Client.luau)

## DefaultAdapter

The built-in adapter renders the packaged GUI, reveals text with a typewriter
effect, supports mouse, touch, keyboard, and gamepad selection, and optionally
freezes the local character.

### `MrDialogue.DefaultAdapter.new`

```luau
MrDialogue.DefaultAdapter.new(config: DefaultAdapterConfig?): DefaultAdapter
```

| Config field | Type | Default |
| --- | --- | --- |
| `gui` | `ScreenGui?` | Clone `MrDialogue.Assets.DialogueGui` |
| `charsPerSecond` | `number?` | `30` |
| `punctuationPause` | `number?` | `0.15` |
| `freezeCharacter` | `boolean?` | `true` |

```luau
local adapter = MrDialogue.DefaultAdapter.new({
	charsPerSecond = 42,
	punctuationPause = 0.1,
	freezeCharacter = false,
})

MrDialogue.Start({ adapter = adapter })
```

When you supply an adapter yourself, you also own its lifetime.

### `DefaultAdapter:Destroy`

```luau
DefaultAdapter:Destroy(): boolean
```

Releases connections, restores character movement, and hides the GUI. Returns
`false` if already destroyed.

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/DefaultAdapter.luau)

## Typewriter

`MrDialogue.Typewriter` is the UTF-8 and RichText-safe text reveal utility used
by the default adapter.

### Constructor and events

```luau
local typewriter = MrDialogue.Typewriter.new(label: TextLabel)

typewriter.Completed:Connect(function(runId, outcome)
	print(runId, outcome)
end)

typewriter.GraphemeRevealed:Connect(function(runId, visibleGraphemes)
	print(runId, visibleGraphemes)
end)
```

### Methods

```luau
typewriter:Play(text: string, config: TypewriterConfig?): number
typewriter:Skip(): ()
typewriter:Cancel(): ()
typewriter:IsPlaying(): boolean
typewriter:Destroy(): ()
```

`Play` returns a run ID. Starting a new run cancels the previous run. `Skip`
reveals all text and fires `Completed` with `skipped`; `Cancel` fires
`Completed` with `cancelled` without revealing the remainder.

```luau
typewriter:Play("Welcome, traveler!", {
	charsPerSecond = 36,
	punctuationPause = 0.2,
})
```

[:octicons-code-16: Source](https://github.com/arakoDev/MrDialogue/blob/main/src/Typewriter.luau)

## Adapter callbacks

The complete custom adapter contract and callback timing are covered in
[Client interface](../guides/client-interface.md#implement-a-custom-adapter).
