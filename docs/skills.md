# Skills catalog feature

`tools/skill.lua` installs the read-only `skill` tool and a `before_turn` index;
`commands/skill.lua` provides display-only `/skill` listing/errors and submits
`/skill NAME` as the next model prompt. The shared resolver puts the directory
header (including capped `references` and `scripts` entries) into every full
skill read, so the tool and command have identical content. The catalog item
bundles `lib/skill.lua` and the command; the command is intentionally not a
separate catalog item. Installing it copies Lua source; reading skills never
runs their scripts.

Skills are `SKILL.md` files under project `.agents/skills` directories or the
configured global `skills` directory. The nearest project directory wins over
later ancestors and global skills. Walking stops at the first `.git` marker
(file or directory), `HOME`, filesystem root, or 50 levels, including the boundary
directory. Names start with an ASCII letter/digit, followed by letters/digits,
`.`, `_`, or `-` (128 bytes maximum); the directory name must equal frontmatter
`name`. Plain scalars cannot contain inline comments or colon-space; quote those
values instead. Quoted strings do not support escapes.

Frontmatter is a deliberately small YAML subset: `---` delimiters on exact
lines, and one-line `name` and `description` values (unquoted, or fully quoted
with matching single/double quotes). Quoted escapes and internal quote
characters are rejected. `|` and `>` block scalars, duplicate/unknown keys,
and other YAML features are rejected. CRLF, blank lines, and comment lines are
accepted. Descriptions are limited to 512 bytes and cannot contain control
characters.

`SKILL.md` is limited to 64 KiB; referenced files are limited to 256 KiB;
indexes contain at most 100 skills and 16 KiB; discovery examines at most 1,000
entries; diagnostics are capped at 10 messages of 512 bytes each; and each
discovery has an 8 MiB aggregate read budget. Directory enumeration is delegated to the
native `ctx.fs.read_dir` API, whose underlying native enumeration is not made
bounded by Lua. Invalid nearest candidates shadow later copies of the same name;
missing `SKILL.md` files do not.

Every discovered/read file is checked with GNU `realpath
--canonicalize-existing --zero`; GNU realpath is therefore a runtime dependency.
Guard failure or approval denial fails closed and is reported in explicit read
errors or listing diagnostics. Relative file paths reject absolute paths,
backslashes, NULs, and `.`/`..` components. The trusted-local-filesystem threat
model does not claim to prevent a concurrent rename or symlink swap after the
check. Files are never executed. Optional header directories are guarded too;
if unavailable or outside the skill directory, their listing is omitted.

`ctx.exec` uses Bone's existing approval policy: it may prompt for `realpath`,
and denial/unavailability skips the affected skill rather than reading unsafely.
Each turn rescans metadata and runs guards, so large collections can add latency
or encounter the host hook timeout. There is no cache or promise of zero overhead.
Native whole-file reads are size-checked before/after, not race-proof bounded reads.

## Validation

From the catalog root (Lua 5.4, GNU coreutils, Python 3 and tmux required):

```sh
lua5.4 tests/skill_test.lua
lua5.4 tests/skill_filesystem_test.lua
python3 tests/skills_pty_smoke.py ../bone/target/release/bone
```

Build that Bone binary first with `cargo build --release` in the Bone workspace.
The PTY test uses only temporary configuration and a localhost mock provider;
it checks display-only commands, prompt/index content, project precedence,
reference tool reads, traversal rejection, resizing, and clean shutdown.
