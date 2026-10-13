# Prompt suggestions

Grey next-prompt predictions in bone's input field. After a successful reply,
this plugin makes one separate, tool-free model call. Predictions never enter
the transcript or the actual draft until you accept them.

## Use

- **Tab** accepts the visible prediction into your draft; **Enter** then sends it.
- **Escape** dismisses a prediction or cancels one still being generated.
- Typing a matching prefix shows the remaining text in grey. Diverging text,
  slash commands, selections, an unfocused prompt, and a cursor away from the
  end hide the prediction. Normal command completion is preserved.
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
Provider errors appear as notifications; disable predictions if needed.

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
