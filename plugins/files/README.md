# Files

A file explorer, a file viewer and a text editor, in one sidebar docked at the
right of the chat — in the terminal and the desktop app alike. `/files` opens it:
the conversation's folder as a tree you expand in place, a search, and a list of what
changed. Three tabs (Files, Search, Changed) sit above the content. Opening a
text or code file puts you straight in the editor; a picture, a PDF or a binary
file opens in the preview. No windows: it all happens in the panel, which takes
half the window (the `width` setting says otherwise).

**In the desktop app** the panel draws its own look (`files.look`): breadcrumbs of
the folder (press one to go there), a tree with drawn chevrons and file-type icons,
and Git's letters and this session's edits as small marks at the right. An open file
takes the room on the left, with line numbers, the current line lit, syntax colors
and a caret you can place with a click; the tree narrows to a column on the right,
showing the open file, and the panel widens by a tenth. `esc` in the file gives the
keys to the tree (the file stays open), `tab` gives them back, and `esc` in the tree
closes the file. The search groups its results under their file and marks the term.
**In a terminal** the panel draws its own lines (`files.tlook`), in the
colorscheme's colors: breadcrumbs, the file beside the tree when the terminal is wide
enough (90 columns and more; one of them when it is not), tabs and the file bar,
syntax colors, the caret's line, a selection drawn as one, find's matches, the
bracket pair, Git's change bars in color, and quick open, a name to give and the
menus as cards over the panel. The mouse places the caret, drags a selection, takes a word
with a double press, presses rows, tabs and crumbs, opens a row's menu with the right
button, and closes a card with a press beside it; the wheel scrolls. Every color is a group linked to one of the scheme's (`FilesTSelect`,
`FilesTLine`, `FilesTMatch`, `FilesTAdded`…), so a scheme or `bone.hl.set` restyles
it. The `tui_look` setting set to `elements` draws it with the shared elements
instead — which a TUI library can restyle — one pane at a time,
and `esc` from the file goes back to the tree; the file stays open in its tab
(`tab` or `ctrl+tab` brings it back). Quick open, the filter, find, a name to give a
file and the open files are rows of their own there, and the change marks ride
beside the line numbers: `+` added, `~` changed, `_` lines taken out above.

**Getting around.** `ctrl+p` (or `p` in the tree, or the header's *Go to file*)
finds any file under the folder by a few letters of its path, in order: a match in
the name, at the start of a word or in one run ranks higher, the files you opened
last come first (they are kept across restarts), and `name:42` opens it at line 42.
The list comes from ripgrep, so what `.gitignore` keeps out stays out. The tree's own
filter (`f`, the field under it) shows the files and folders anywhere under the
folder whose names hold the letters, under the folders that hold them (quick open's
list; the folders read so far while it is read); what `.gitignore` keeps out is still listed, dimmed. In the desktop
app the folder the top row sits in stays pinned over the list while you scroll.

**After a reload.** The panel keeps what it holds as it changes (`bone.state`): the
folder, the folders open in it, the tabs with their carets, and the text of a tab with
unsaved work. When the plugin reloads (its files changed, `/plugins`) in the same bone
process, the panel opens again as it was, unsaved text and all; a file that moved
meanwhile says so. A new start of bone begins fresh.

**Tabs.** Each file you open is a tab, and keeps its own unsaved work, caret and undo:
`ctrl+tab` and `ctrl+shift+tab` go through them, `ctrl+w` closes one (twice when it
holds unsaved work), a middle click too. Twenty at most; the oldest one with nothing
unsaved makes room.

**The editor.** Shift and the arrows (or a drag) select; `ctrl+shift+arrows` and
`ctrl+arrows` go by words (a drag past the top or the bottom keeps selecting as the
view follows), `home` goes to the line's first character and then its
start, a double click selects a word, `ctrl+a` all of it. Copy, cut and paste go
through the system clipboard (`wl-copy`, `xclip` or `xsel`): `ctrl+c` `ctrl+x`
`ctrl+v`. The desktop app hands a focused panel its copy and cut as those keys from
bone's build of 6 November 2026 on; in an older one `ctrl+c` and `ctrl+x` never reach
the panel, and `ctrl+insert`, `shift+delete` and the right-click menu do the same
anywhere.
**Neovim, Vim or your own (in a terminal).** With the `editor` setting on `nvim`,
`vim` or `custom`, a text file opens in that program instead, in the term plugin's
terminal panel beside the tree, at the line asked for, with your own config. The
desktop app always uses its own editor. A second file goes to the same Neovim or Vim (`:hide e`, so
unsaved work stays in its buffer). `ctrl+]` gives the keys back to the prompt; a click
on the tree opens the next file there. When the program ends its panel closes, the tree
and Git's marks are read again, and the keys come back to the tree. `E` (or *Open in the
built-in editor* on the right-click menu) still opens the built-in one; it is also used
when the program is not on the PATH or there is no terminal to run it in.

Enter keeps the line's indentation, one step more after a line that opens a block,
and puts a closing bracket on a line of its own; a closing bracket typed on a line of
only indentation steps it back. The indentation is the file's own (a tab, two or four
spaces). `tab` and `shift+tab` indent the selected lines. The bracket at the caret and
its partner are marked. `ctrl+f` finds in the file (lower case matches any case),
`enter` the next, `shift+enter` the one before; `ctrl+l` goes to a line (`line:col`
too). At the edge of the line numbers a bar marks what changed since the last commit
— added, changed, or (a small wedge) lines taken out — from `git show HEAD:file`, kept
up to date as you type; a file Git does not track yet is all added. In the desktop
app long lines wrap (the file bar's *Wrap*, or `alt+z`): prose files wrap unless
you say otherwise, code does not, and a click or a drag lands on the row it is over.
In a terminal a selection is its lines in the accent color, with `⟨` `⟩` where it
starts and stops.

**With the agent.** When the agent writes the file you have open and you have not
changed it, the editor takes the new text and lights the lines that changed; with
unsaved work of yours it does not touch it and says the file moved. *Follow* (the
header's button, or `F`) opens each file the agent writes as it writes it. `ctrl+k`
names the file in the message you are writing — `src/app.lua`, or with lines selected
`src/app.lua:12-40` — for the agent to read.

**Files.** `a` makes a file in the selected folder (a name with slashes makes the
folders on the way), `A` a folder, `R` (or `f2`) renames, `D` duplicates ("name
copy.ext"), `delete` moves to the desktop's Trash (`gio trash`, else trash-cli); where there
is no Trash (a system folder such as `/tmp`) it asks whether to delete for good —
only `y` (or the red button) does, any other key leaves it — `y`
copies the path and `Y` the full one. In the desktop app a right click on a row, or in
the editor, opens a menu of the same.

**Pictures and PDFs.** A picture can be zoomed (`+` `−`, `0` fits it, `1` is its own
pixels, ctrl and the wheel, a double click) and, once larger than the pane, dragged
around; one that can be see-through sits on a checkerboard. A PDF's pages zoom the
same way (`w` the column's width), wider than the column too — then a drag, or shift
and the wheel, moves them sideways — and the page field over them (`g`) goes to a
page. Its pages are drawn twenty at a time, the next twenty as the list nears its end.

**HTML pages.** An `.html` file opens as it reads — the editor's *Preview*, beside
*Edit* and *Changes* — drawn by the plugin in a column the width of a page:
headings, paragraphs with their bold, italics, code, strike-through and highlights,
lists (nested and numbered), quotes, code blocks, tables (a header row, stripes, the
caption), rules, and pictures — beside the page, absolute, or `data:` URLs; one on
the web is named, not fetched. Links work: `#somewhere` goes there on the page, a
file beside it opens in the panel, a web or mail link goes to the browser or the mail
program. Small pictures (an icon, a badge) sit in the line; a
code block is colored by its `language-…` class, with a *Copy* button; a table's
columns of numbers line up on the right (or as its `align` says); `<kbd>` is a key,
a figure's caption sits under it, and `<video>`, `<audio>` and `<iframe>` are cards
that open what they hold (a clip beside the page, in the panel). A page of three
headings or more has *Contents*, to go to one. Pictures on the web are not fetched
until you press *Show them*, for that page. *Split* shows the text and the page side
by side, the page following as you type (Markdown too). It is the page's content,
not its CSS or its scripts: **Open in browser** in the file bar shows it as a
browser does. `e` or enter edits it, `alt+m` goes back to
the page, and it is drawn again as you type. A terminal shows it as Markdown.

**Files named in the chat.** In the desktop app each reply of the agent's ends with
the files it names, as chips — `app.lua :4-6`, `util.py`, a folder — and pressing one
opens it in the panel (the panel too, when it is closed) at its line, the lines it
names lit. A path counts when it is there: in the chat's folder, else in the one the
panel shows, written `path`, `path:42`, `path:12-40`, `path#L42` or as a Markdown
link. In a terminal the paths a reply names are drawn as links
(`FilesTLink`, the scheme's path color underlined) and a press on one does the
same. `/files links` (or `L` in the tree) lists the files the last reply named, to
open one, in either. So that the agent writes them that way, the core half adds a
line to its system prompt. The `link_files` setting turns these off.

**GIFs, videos and 3D models.** A GIF plays in the panel, at its own frame times,
with the picture's zoom and checkerboard (`space` stops and starts it): the plugin
reads the GIF itself, in Lua, and keeps its frames as PNGs in its cache, so nothing
has to be installed for it. A video shows its poster, a row of twelve pictures along
it (press one to play from there) and what it is — codec, size, length, frame rate,
whether it has sound — and plays a silent preview in the panel, twelve frames a
second, made twenty seconds at a time; **Open in player** (or `o`) hands it to mpv
(else Celluloid or VLC, else the desktop's own app) to watch with sound. A 3D model
(STL, OBJ, PLY, glTF or GLB, read in Lua) is drawn lit, and turns as you drag it (or
with the arrow keys); the wheel zooms, `w` shows its wires, a double click or `0`
puts it back. A model of more triangles than the panel draws is thinned by merging
the corners that lie close together, so its surface stays whole.

**ffmpeg, for videos.** A video needs ffmpeg (an APNG uses it too, when it is
there). When it is missing, the video says so and offers three things: **Install**
runs the system's package manager in a terminal (`sudo pacman -S --needed ffmpeg`,
`brew install ffmpeg`, `winget install --id Gyan.FFmpeg -e`, apt, dnf, zypper, apk
and others), **Download it for the panel** fetches a build into the plugin's own
folder (`~/.cache/bone/files/ffmpeg/bin`), and **Open in player** plays it outside.
The download says first how big it is and where it comes from, and is checked before
it is used: on macOS against a SHA-256 pinned here (evermeet.cx's ffmpeg 9.0.2), on
Linux (BtbN's builds) and Windows (Gyan's) against the SHA-256 GitHub publishes for
the file. The plugin's own copy is used before the one on the PATH.
`BONE_FILES_NO_FFMPEG=1` makes the panel act as if there were none, to see the offer.

The syntax colors are the plugin's own groups (`FilesKeyword`, `FilesString`,
`FilesNumber`, `FilesComment`, `FilesType`, `FilesHeading`, `FilesCode`,
`FilesQuote`), linked under the colorscheme's, so a scheme or `bone.hl.set` can
restyle them.

## What it does

| File | What the preview shows |
|---|---|
| Markdown · HTML | the document rendered, or a page's text without its markup |
| PDF | in the desktop app, its pages drawn (Ghostscript); its text, read by the plugin itself, behind the Pages · Text switch and in a terminal |
| Pictures | the picture itself, in the pane — or, in a terminal, what it is: `PNG · 1920×1200` |
| Anything else | its text, as it is |

**A picture, in the panel.** The preview reads the file's first few kilobytes and
takes its size from the header (PNG, JPEG and WebP), so the desktop app draws it in
the sidebar — as large as the panel allows, never larger than the file's own pixels,
centred, never taller than most of the pane. A terminal cannot draw it and says what
it is instead: `□ photo.png  PNG · 1920×1200`. Press the picture, or `o`, for the
desktop's own viewer, which shows it large.

**A PDF, in the panel.** The desktop app draws its pages as pictures, twenty at a
time, one under another, each as wide as the column allows (up to 760 pixels)
— `gs` does the drawing, as a bone job, into `~/.cache/bone/files-pdf/`, a folder
per file named by its SHA-256, so a file is drawn once and a changed file again;
the forty folders used last are kept. The Pages · Text switch over it (or `t`)
shows the text the plugin reads out of the file instead. Without Ghostscript the
text is what you get, as in a terminal.

**How deep the tree goes.** Only the folders you open are read, and each one is read
once — `r` reads them again. No folder is too deep to reach. 1500 rows is as far as
the list goes, and an expansion that runs into that says so instead of doing nothing.
A folder's children are indented under it; its chevron (`▸`, `▾` while open) leads
its name, and a file's name starts two cells in, so every name at a depth begins in
the same column. A file's size sits at the other end of its row (`4.1 KB`), asked of the file
when its folder is read, and it is the same word the preview carries.

**What the agent changed.** The core half keeps every `edit_file` and `write_file`
the session makes. The tree badges those files (`edited`, or `edited ×3`) and the
Changed tab names them newest first, with the tool and the time — pressing one moves
the sidebar there, expanding the folders above it. The preview carries the same badge.
The marks live in the plugin's state, so they survive a reload.

**What Git thinks.** `git status --porcelain` runs in the folder, from the
repository's own root so its paths match, and its markers ride along in the tree and
the Changed tab: `M` changed, `?` not tracked, `A` added, `D` deleted — the files
themselves, and where they sit in this folder, which the Git sidebar cannot show you.
The patch itself stays `/diff`'s job.

**Searching the folder.** Press `s` or `/` and type; the hits become the list — the
line that matched, with `path:line` at its end — and `enter` opens the file at that
line. ripgrep
does the work when it is installed (`--hidden`, no `.git`, `--smart-case`, 400 hits
at most), `grep -rn -i` when it is not. A term in lower case matches either case —
`button` finds `Button` too — and a term with a capital in it is matched exactly.
Typing starts a search a quarter of a second after the last letter, so a whole word
costs one.

**When the file moved under you.** After every tool call the sidebar asks the core
what the shown file hashes to now; when it is not what it was when it was read, the
preview says *changed on disk since this was read* and `v` reads it again. A preview
is kept once read: choosing it again costs nothing.

The editor holds the file's lines with a caret in them. Opening another file keeps this one's unsaved work in its tab. In a terminal each line is a row you can press to put the caret there,
two hundred shown at a time. A line longer than the panel is drawn in part, around the
caret, with `…` at the ends where text was dropped. `home` is the line's real
beginning, indentation and all, and `pageup` `pagedown` move the caret a page (fifty
lines) so the lines shown follow it instead of the pane scrolling away from it.
`ctrl+g` stands the changes in place of the text — the
buffer against the file as it was opened, marked with line numbers, unchanged
stretches folded; `ctrl+p` shows the Markdown it renders to instead. In the desktop
app the Edit · Changes · Preview switch over the file does the same.

**It will not write over someone else's work.** `ctrl+s` first asks the core what the
file hashes to. If it is not the file the editor read, the agent or another editor got
there first: the save is refused, the panel says so, and you choose — `ctrl+o` writes
your version over theirs, `ctrl+r` reads theirs instead.

## The keys

| Pane | Its keys |
|---|---|
| Everywhere | `ctrl+p` go to a file · `ctrl+tab` `ctrl+shift+tab` the open files · `ctrl+w` close the one shown · `ctrl+k` add it to the message |
| Files | `↑` `↓` through the tabs and the tree (past the end, scroll) · `enter` open or close a folder, or open a file (text in the editor) · `e` edit (in a terminal, in the `editor` setting's program) · `E` the built-in editor · `o` open with the desktop's app · `v` the preview, read fresh |
| Files | `p` go to a file · `f` filter · `a` new file · `A` new folder · `R` `f2` rename · `D` duplicate · `delete` to the Trash · `y` `Y` copy the path · `F` follow the agent |
| Files (desktop) | `→` opens a folder or steps into it, `←` closes it or steps out to the one above · `home` `end` `pageup` `pagedown` · `tab` the open file · `esc` closes the open file (twice if unsaved) · `ctrl+s` saves it |
| Files | `s` or `/` search · `c` the Changed tab · `r` read the folder, the marks and Git again · `backspace` `←` close the deepest open folder, or go to the folder above · `ctrl+h` hidden · `q` close the sidebar · `esc` hand the keyboard to the prompt — the panel's top row then carries a dim `keys: prompt` badge, and a click, `tab` or `focus_next` give them back |
| Search | typing edits the term · `backspace` a letter (and leaves it when empty) · `↑` `↓` the hits · `enter` opens a hit at its line · `esc` back |
| Changed | `↑` `↓` · `enter` goes to that file · `r` read it all again · `esc` or `←` back |
| Preview | `+` `−` `0` `1` zoom, fit, actual size · `g` a PDF's page · `w` its width · `t` a PDF's pages or its text (desktop) · `e` edit · `o` open outside · `v` (or `r`) read it again · `esc` or `←` back. 600 lines shown, the rest named |
| Editor | `ctrl+s` save (after checking the file on disk) · `ctrl+o` save over a file someone else changed · `ctrl+r` read it as it is on disk now · `ctrl+z` undo · `ctrl+y` (or `ctrl+shift+z`) redo · `ctrl+g` the changes · `ctrl+shift+v` or `alt+m` read it as Markdown |
| Editor | `shift`+arrows, `home` `end` `pageup` `pagedown` select · `ctrl+←` `ctrl+→` by word · `ctrl+home` `ctrl+end` the ends · `ctrl+a` all · `ctrl+d` the word · `ctrl+c` `ctrl+x` `ctrl+v` (desktop: `ctrl+insert` `shift+delete` `ctrl+v`) · `ctrl+f` find · `f3` `shift+f3` again · `ctrl+l` go to line · `ctrl+backspace` a word back |
| Editor | `enter` newline (indented) · `backspace` (a step of indentation at a time) `delete` · `tab` `shift+tab` indent · `esc` closes find, then the selection, then goes back to the folder with the file still open in its tab |

A click selects, opens and gives the panel the keyboard; the panel's last row lists
that pane's keys.

## The commands

| Command | What it does |
|---|---|
| `/files [path]` | open the sidebar (at `path`, or in the conversation's folder); again with no path, it closes |
| `/files search <term>` | open the sidebar with the folder searched |
| `/editor <path> [line]` | open the sidebar on that file, at a line if you give one |
| `/explorer` · `/edit` | the same as `/files` · the same as `/editor` |

**`tab` finishes a path.** On these commands the first word is completed from the
folder it points into: `~` is the home folder too, hidden names are offered, a folder
keeps its `/` so the next `tab` goes deeper, and at most 30 names are offered. Only
the first word is completed — `/files`' second word is a search term (`tab` there
offers `search`) and `/editor`'s is a line number. A name matches in its own case.

## The settings

| Setting | Default | What it changes |
|---|---|---|
| `width` | 50 | the sidebar's share of the window, in percent (20–80); the editor takes a little more |
| `preview_limit` | 256 | how much of a file the preview reads (KB); the rest is not shown |
| `mark_changes` | on | the badges, and the Changed tab |
| `show_git` | on | Git's markers in the tree and the Changed tab |
| `autorefresh` | on | asking the core, after each tool call, what changed |
| `follow_agent` | off | open each file the agent writes as it writes it (`F` switches it for now) |
| `editor` | built-in | the text editor in a terminal: `built-in`, `nvim`, `vim`, or `custom` (the desktop app keeps its own) |
| `editor_command` | — | the `custom` editor's line, `{file}` and `{line}` filled in (e.g. `hx {file}:{line}`, `micro +{line} {file}`) |

They are on the Files page of `/config`; the plugin reads them at load.

## What the core half does

`core.lua` registers what a frontend cannot do — `files.pdftext` (a PDF's text),
`files.open` (`xdg-open`), `files.hash` (a file's SHA-256 and size: how the panel
tells one read of a file from the next), `files.touched` (this session's writes,
newest first) — and hooks `tool_call`, `tool_result` and `turn_end` to build that
list: paths made absolute while a call starts, failed calls dropped, the last twelve
sessions kept. `/health` checks `xdg-open`.

`ui.lua` is the whole UI — one view of elements, drawn as lines by the terminal and
as widgets by the desktop app. It reacts to `tool/finished` (the marks, and the files
it shows) and `turn/finished` (that, plus a fresh `git status`), re-sizes on
`resize`, and puts its panel back after a runtime reload when it was open. A search,
a `git status` and a PDF read run as bone jobs; the editor writes through
`bone.fs.write`, which renames a temporary file over the file, so a save is never
half-written.

## The PDF reader

`files.pdf` reads a PDF as it is, in Lua: the objects (a page tree, the fonts), the
streams (inflated in the plugin, with a DEFLATE decoder of its own) and the text
operators in them — the text of the first twenty pages, with the pages' own fonts (a
simple font's codes, or a `ToUnicode` map). What it cannot read: a scanned page (a
picture of a page, with no text in it) — the preview says so — and a font whose codes
are mapped nowhere.

## What it needs

- `xdg-open` for opening a file with the desktop's app
- ripgrep for searching the folder (`grep` is used when it is missing)
- `find` for the size at the end of a file's row (`find -printf`; without it the
  rows simply say nothing about size)
- Git, for the markers and the editor's change bars
- `wl-copy`/`wl-paste` (or `xclip`, `xsel`) for the clipboard
- `gio` (or trash-cli) for moving to the Trash
- Ghostscript (`gs`), for a PDF's pages in the desktop app (its text is shown without it)
- ffmpeg and ffprobe, for videos (offered when missing: installed, or fetched for the panel)
- mpv, Celluloid or VLC to open a video with sound (else the desktop's own app)
- Neovim or Vim, for the `editor` setting in a terminal, and the term plugin for it
  to run in

**Where it runs.** Linux is where it is used and tried. macOS takes its own tools —
`open`, `pbcopy`, the Trash through `trash` or the Finder, BSD `stat` and `shasum` —
but has not been tried here; the reload that puts the panel back as it was reads
`/proc`, so on macOS a reload opens the panel fresh. Windows runs a plugin's jobs in
PowerShell, and most of this plugin's jobs are shell lines: only the ffmpeg fetch is
written for Windows so far.

The PDF, the editor's diff (`files.diff`) and the sizes of pictures
(`files.image`) are read by the plugin itself.
