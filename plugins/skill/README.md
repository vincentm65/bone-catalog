# Skills

Skills: instructions for particular kinds of work (cutting a release,
writing a migration) that the model loads only when a task calls for them.
The core has no notion of skills; this plugin adds it.

```sh
python3 install.py skill
```

Skills live in `~/.bone/skills/<name>/SKILL.md` (the config dir's `skills`
folder): no setup, and asking bone to write one is enough. The folders are read
again each turn, so a skill written, changed or removed while bone runs counts
at once.

```lua
-- ~/.bone/core.lua, only to change that:
bone.config.skill_dirs = { "~/.bone/skills", "~/work/skills" }   -- the first folder wins a name
-- or register them yourself (these win over a folder's):
bone.skill.register { name = "style", description = "Our code style", content = "Use tabs. ..." }
bone.skill.register { name = "deploy", path = "~/work/deploy",            -- a folder with SKILL.md, or a .md file
                      enabled = function(ctx) return ctx.cwd:find("/work/") ~= nil end }
```

`SKILL.md` files start with front matter (`name`, `description`). While a
session has at least one skill (`enabled(ctx)` decides per session), the
system prompt gets a short "Skills" list (a `system` hook with priority 1000,
so your own `system` hooks run after it) and a `skill` tool returns a skill's
full text plus the paths of the other files in its folder. With no skills,
nothing changes. The tool is there when bone starts with a skill or a skills
folder; skills that come after a start without either are read from their files
until the next start. `bone.config.skills = { prompt = false }` or
`{ tool = false }` turns either part off. Also `bone.skill.load_dir(dir)` (adds
a folder), `unregister(name)` and `list()`.

In the TUI and the GUI, `/skill` (or `/skills`) opens a picker: one line per
skill, typing filters, enter writes "Use the name skill: " into the prompt for
you to finish. `/skill name task` skips the picker (names complete; an unknown
name opens the picker and keeps the task). Either frontend gets the list
through `bone.rpc.call("skills.list")` (`{ skills, dirs }`). In the chat a
call reads `skill  name`, and a summary line "Loaded the name skill" (on a bone
whose tool views can name summary lines), or "Loaded 3 skills" for several (on
a bone whose summary lines read a view's `many` phrase; an older one names each);
the skill's text shows when the call is opened.
