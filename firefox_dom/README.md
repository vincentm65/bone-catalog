# Firefox DOM (`firefox_dom`)

This independent tool uses native host `dev.bone.firefox_dom`, owner-only socket `bone-firefox-dom.sock`, extension ID `firefox-dom@bone.local`, and package `bone-firefox-dom-0.1.0.zip`. It does not share protocol, state, sockets, or files with the existing Firefox/browser tools.

## Use

Call the tool with one required `action`: `tabs`, `outline`, `find`, `inspect`, `act`, `changes`, `navigate`, or `select_tab`. Start with a narrow `tabs` or `outline`/`find`, use only returned stable refs, then inspect or perform one action at a time and observe again. Compact results include bounded control identity, accessible names, placeholders, and redacted link targets so similar elements can be distinguished without guessing selectors. `inspect` expands children through the requested depth while sharing `max_nodes` across its returned node records. Text budgets trim text fields without hiding the corresponding nodes and report `omitted_text`. Editable state and typing are limited to writable text controls and contenteditable elements; native selects use the explicit `select` operation. `outline` defaults to viewport scope. For `act`, typing accepts `text` or `value`, scrolling accepts `x`/`y`, and scroll-into-view accepts `block`/`inline`. Navigation accepts a 1–30 second `timeout_ms`, returns the new document identity when the page is accessible, and accepts `outline: true` for a bounded main-frame viewport outline. Do not guess refs, selectors, or ambiguous matches.

## Setup

Setup requires a working Rust/Cargo installation and builds the bundled bridge with `cargo build --release --locked`. The command installs state under the Bone configuration directory (`<config_dir>/firefox_dom`), copies an owner-only bridge binary and launcher, creates an owner-only native-messaging manifest, copies the extension, and creates the package ZIP. It never uses sudo and never modifies a Firefox profile.

From the installed catalog command:

```text
/firefox_dom setup
/firefox_dom doctor
/firefox_dom remove
```

After setup, install the extension through Firefox's normal workflow. For a persistent install, open `about:addons`, choose the gear menu, select **Install Add-on From File**, and choose the reported `bone-firefox-dom-0.1.0.zip`. For a temporary install, open `about:debugging` → **This Firefox** → **Load Temporary Add-on**, and choose the reported copied `extension/manifest.json`. Firefox may require the temporary extension to be loaded again after restart. These are the exact supported loading paths; setup does not silently alter profiles.

`doctor` checks the native-host manifest, launcher, built binary, copied extension and manifest, package ZIP, and canonical socket (`<config_dir>/firefox_dom/bone-firefox-dom.sock`). It distinguishes an accepting socket from a stale socket file left after Firefox terminates the native host. `remove` removes only this tool's manifest, extension state, package, launcher, binary, socket, and empty state directory; it does not touch Firefox profiles or the existing browser tool. Symlinked unsafe targets are refused rather than followed.

## DOM reach and limitations

The extension can discover ordinary HTML/SVG elements, custom elements, open shadow roots, slots, ancestry, bounded text, geometry, focus and interaction state. It can search the live DOM and act on supported controls by ref: click, focus, type/set value, press, scroll, check/uncheck, submit, and native-select by exact label/value/index. Firefox-privileged pages, inaccessible frames, closed shadow roots, canvas/video/image pixels, and trusted physical input remain unavailable.

DOM inspection can expose personal or financial data. Passwords, hidden values, token/secret/session/authorization/credential-like fields, URL userinfo, script bodies, and style contents are redacted or omitted conservatively. Use narrow scopes and budgets.
