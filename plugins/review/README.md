# review

Immediately submit `/review [branch] [low|medium|high]`, without a panel or an
expanded prompt to edit. The visible and saved user message keeps the literal
command and arguments; the core plugin silently injects the review instructions,
scope, diff stats, bounded diffs, and small untracked files into the system
prompt for that turn only.

```sh
python3 install.py review
# To replace an installed version:
python3 install.py review --force
```

Run these commands from the catalog checkout, or install/update `review` from
Bone's `/catalog` page. Load both plugin halves with `/plugin load review`
(or restart Bone after installation). Git must be available on PATH.

- `/review` reviews repository-wide **unstaged and untracked** changes, even
  when the session starts in a subdirectory. Paths and file reads are resolved
  from the repository root; `diff.relative` does not narrow the scope.
  Staged-only changes and ignored files are excluded, including in repositories
  without a first commit.
- `/review <branch>` reviews committed changes from the merge base of that
  branch and `HEAD` to `HEAD`. Local uncommitted changes are excluded. Branches,
  tags, and commit IDs are accepted; `all` is not a special action.
- Effort defaults to **medium** and can be used alone (`/review low`) or after
  a revision (`/review main high`). Effort names are reserved, lowercase words:
  - **low**: near-certain, merge-blocking defects; at most **5** findings.
  - **medium**: findings worth flagging in a real PR; at most **10** findings.
  - **high**: anything worth commenting on in a careful review, still no style
    nits; at most **20** findings.

The legacy verification-first rules require checking surrounding code, callers,
and invariants with tools before reporting a defect. Style, speculative issues,
missing tests/docs, and unrelated pre-existing problems are out of scope. The
report has exactly **Review report** (per-file stats/issues table),
**Assessment**, and **Top issues**, with severity, exact location/code, concrete
problem, and minimal fix. A clean review says “No significant issues found.”
and “None.” rather than inventing findings.

The hidden review prompt is bounded to 80,000 characters, with a 12,000-character
overview, 8,000-character per-file diff limit, and at most 30 inlined diffs.
Whole files/diffs and overview lines are atomic: nothing is truncated mid-hunk.
Oversized/overflow diffs are listed for tool inspection. Untracked text files
up to 4,000 bytes are inlined when space allows; larger files are listed for
reading, and binary/unreadable files are marked as skipped. If even metadata
cannot fit, an omission count directs the model to Git for the rest.

Git discovery is cancellable; an empty scope, invalid revision, or failed Git
command stops the turn with an explanatory error. Queued commands collect their
scope when the turn starts. The core API accepts shell strings, so every argv
element is shell-quoted and diff paths use `--literal-pathspecs` and `--`.
External diff helpers and text conversions are disabled. Branch mode resolves
the merge base once and uses that same scope for all diff commands.

Uses existing `turn_start`, `system`, and `turn_end` core hooks and `bone.system`,
plus Lua file reads for untracked content; the TUI uses `bone.prompt` and
`bone.action`. No protocol extensions are needed.

Run real-Git standalone checks from the catalog checkout (no model credentials required):

```sh
luajit tests/review_test.lua
python3 check.py
python3 gen-index.py --check
```
