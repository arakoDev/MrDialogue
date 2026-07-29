# Troubleshooting

Start with the message returned by `Dialogue:Start` or the warning emitted with
the `[MrDialogue]` prefix.

## The dialogue does not start

### `player dialogue client is not ready`

Initialize MrDialogue once from a `LocalScript` under `StarterPlayerScripts`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MrDialogue = require(ReplicatedStorage.Packages.MrDialogue)

MrDialogue.Start()
```

Do not start a server dialogue immediately when `PlayerAdded` fires. The client
needs time to load and announce readiness. A player interaction such as a
`ProximityPrompt` naturally happens after initialization.

### `player already has an active dialogue session`

Only one dialogue may be active for a player. Keep the returned `Session`,
finish or cancel it, and then start the next dialogue.

### A handler `is not registered`

Every condition and action referenced by the graph must be registered before
`Dialogue:Start`. Registration may happen before or after `MrDialogue.new`.

## The default UI is missing or invalid

If no custom GUI is provided, the package must contain:

```text
MrDialogue
└── Assets
    └── DialogueGui
```

Wally and Rojo must map the package as a shared package so the client receives
the included asset.

For a custom GUI, match the required hierarchy and classes exactly. See
[Use a custom ScreenGui](guides/client-interface.md#use-a-custom-screengui).

## Choices disappear

Choice conditions are evaluated when the options are offered and again when the
client selects one. If all options fail:

- the graph follows `fallback`, when present;
- otherwise the session is cancelled with `no_available_options`.

Check Output for `CONDITION_THROWN`, `CONDITION_YIELDED`, or
`CONDITION_INVALID_RESULT`. Conditions fail closed.

## The session ends with `action_error`

Action handlers must finish synchronously and return no values, `true`, or
`false, details`. The following all cancel the session:

- throwing an error;
- yielding with `task.wait`, an event wait, or an async API;
- returning a value other than the accepted results;
- returning `false`.

Start long-running work elsewhere and keep the dialogue action synchronous.

## The character still moves—or stays frozen

`definition.freezeCharacter` overrides the default adapter setting for that
dialogue. When omitted, `DefaultAdapter` uses its configured value, which
defaults to `true`.

If you provide a custom adapter, movement handling is your responsibility.

## A custom adapter stops responding

Call each action callback only for the screen state that received it:

- call `presentationCompleted` after revealing the current text;
- call `advance` or `finish` from the current continue control;
- call `choose(index)` with a current, one-based option index.

Old callbacks intentionally become no-ops after the runtime moves to another
state.

## Definition validation throws

Verify these common constraints:

- `format` is `1`;
- `id`, node IDs, and option IDs are non-empty strings;
- every transition targets an existing node;
- node and choice arrays are dense;
- referenced speakers and emotions exist;
- a choice has at least one option;
- all fields use the types in [Types](api/types.md).

Definitions are validated early so graph mistakes fail during setup rather than
halfway through a player's conversation.
