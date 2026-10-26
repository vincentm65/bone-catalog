# Shell

Run a shell command directly from the prompt, without asking the model:

```text
!pwd
!git status --short
!printf 'hello\n'
```

The leading `!` must be the first character. Everything after it is passed
unchanged to Bone's local shell job API (`bash -c` on Unix, PowerShell on
Windows). Commands run asynchronously in the current session's working
directory; a new chat without a session uses the frontend's working directory.
Output and exit status appear in that chat, even if you switch chats while
the command runs. Stdout and stderr are combined as their chunks arrive;
only the first 64 KiB is displayed. Terminal control sequences are stripped.

- `/shell-cancel` cancels all running shell commands started in the current chat.
- `!!text` sends `!text` to the model instead of running a command.
- Ordinary messages and slash commands behave as before.
- A bare `!` displays usage and is not sent to the model.
- Image attachments are not supported with shell commands and are discarded
  when the submit is intercepted.

Commands execute immediately with your user's permissions: there is no model
or approval step. Each command uses a separate shell, so `!cd path` does not
change the session directory for later commands. Use `!cd path && command`
for a single command in another directory. Interactive programs should use
`/term command` instead; shell commands do not have a terminal or interactive
stdin.

These are TUI-local items, not core tool calls. Neither the command nor its
output enters the model's conversation or saved transcript. Reopening a
session drops the items. Reloading/unloading the plugin or quitting Bone
cancels its running jobs.

## Installation

Install with `/catalog`, or copy this directory to `~/.bone/plugins/shell/`
and run `/plugins load shell` (or restart Bone). Read this page in Bone with
`/help shell`.

## Tests

From the catalog checkout:

```sh
luajit tests/shell_test.lua
BONE_BIN=/path/to/bone python3 tests/shell_tmux_test.py
```

The live test uses tmux and an isolated config with a local HTTP endpoint;
it asserts that no model requests are made.
