# System prompt

Editable main and delegated agent policy for Bone 2.4.6 and later.
Use `/config` → System prompt to change the prompt and tool guidance, or edit
`system_prompt_profile.lua` to change defaults. Existing `general.system_prompt`
text is preserved as the initial main prompt. The delegated entry point opts in
through `agent.lua`.

Disable this plugin to remove its policy. The harness still supplies runtime
environment facts and the delegated task/output contract.
