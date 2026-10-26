# Prompt Suggestions

Next-prompt predictions after a successful reply. The terminal shows one in
grey in the prompt. The desktop app shows it in a row just above the composer.
Either way this plugin makes one separate, tool-free model call, and the
prediction never enters the transcript or the actual draft until you accept it.

## Use

- **Tab** accepts the visible prediction into your draft; **Enter** then sends it.
  In the desktop app, **Accept** does the same thing.
- **Escape** dismisses a prediction or cancels one still being generated.
  In the desktop app, **Dismiss** does the same thing. Those controls are not
  keyboard targets, so arrows, typing, and the other editing keys stay in the
  composer. Tab and Escape keep their usual prompt actions.
- Typing a matching prefix shows the remaining text in grey (terminal) or after
  the typed prefix in the row (desktop). Diverging text, slash commands,
  selections, an unfocused prompt, and a cursor away from the end hide the
  prediction. Normal command completion is preserved. A background chat's
  composer does not show the row.
- While a prediction is still being requested and the composer is empty, the
  desktop row says so and **Dismiss** cancels it. The terminal has no extra
  row; Escape cancels the request there too.
- Starting a turn, switching chats, changing settings, or unloading the plugin
  clears the prediction and invalidates pending results.

Open `/config prompt-suggestions` (or select **Prompt suggestions** in `/config`):

| Setting | Default | Meaning |
| --- | --- | --- |
| Enabled | On | Generate predictions after successful replies. |
| Provider | Blank | A configured provider's name. Blank uses the default provider. |
| Model | Blank | A model ID accepted by that provider. Blank uses its default model. |

These persist in `settings.json` under `prompt-suggestions.enabled`,
`prompt-suggestions.provider`, and `prompt-suggestions.model`. Provider and model
apply only to predictions, not the main conversation. Credentials and endpoints
come from the existing provider configuration; a model ID is not a provider name.

For example, the relevant settings object could be:

```json
{
  "prompt-suggestions": {
    "enabled": true,
    "provider": "my-fast-provider",
    "model": "my-small-model"
  }
}
```

Use your actual configured provider and model IDs. Prefer a fast, cheap model.
Each prediction is an extra model call and may incur charges. The selected
provider receives the last eight nonempty user/assistant text messages, each
limited to 2,000 characters; no tool output, images, or reasoning is included.
The prediction is limited to 160 characters and one line; long display text is
clipped by the existing prompt renderer. No prediction is made for failed or
cancelled turns or background chats. An unclear next step may produce nothing.
A provider that is busy, rate limited, or unreachable simply produces no
prediction for that turn, with no message; a mistake you can act on (an unknown
provider name, a rejected model) is reported once, with the provider's own text
shortened to a single line. Disable predictions if you do not want the extra
calls.

## Installation and tests

Install **prompt-suggestions** from bone's `/catalog` page, or copy this folder
to `~/.bone/plugins/prompt-suggestions/`. If it has not loaded automatically,
run `/plugins load prompt-suggestions` or restart bone. Use
`/plugins unload prompt-suggestions` to remove it from the current UI.

From the catalog checkout, run the mocked regression tests without making
model requests:

```sh
luajit tests/prompt_suggestions_test.lua
```
