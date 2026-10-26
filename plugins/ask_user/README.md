# Ask User

Lets the model ask you one or more questions: pick one option, pick several,
or type an answer. The same questions work in the terminal and the desktop
app.

In the terminal, questions are asked in the input field, like the first bone.
While one is open the field becomes the question: it grows to hold the
question, its options, an input row and the keys, drawn in your prompt's own
style (background, border, padding and prefix). Typing and editing work as
usual in the input row. Your draft in the prompt is kept and comes back when
the question is answered.

In the desktop app, a question opens as a modal window over the chat. Click
an option to choose it, or to toggle it when several can be picked. Click
Cancel to dismiss it, or Answer to send what enter would send. A text field
is always there for your own answer; click it to type, with the usual editing
keys. The composer's draft is left alone.

- `↑`/`↓` move, `enter` chooses, `1`-`9` pick (or toggle) directly.
- Multi-select: `space` toggles, `enter` confirms (the highlighted option if
  none is checked).
- Typed text is the answer for text questions, and your own answer for
  choice questions: typing your own is always an option. In multi-select
  it goes along with the checked options. On the desktop, enter still
  prefers that typed text; clicking an option chooses that option (or
  toggles it) even if the field already has text.
- While the desktop text field itself has the keyboard, digits and space
  type into it. Up and down still move, enter sends, and esc cancels.
  Before you click the field, `1`-`9` and space behave as in the terminal
  when the answer is empty.
- `esc` cancels; `ctrl+c` interrupts the turn as usual.
- Enter, esc and `1`-`9` are ignored for a moment after a question appears,
  so the key that opened it does not answer it. Arrows, space and typing
  are not held back.

Answers reach the model as `{ value, label, index }`, `{ values, labels }`
(with `custom = true` when you typed one) or `{ value, custom = true }`;
clients that answer with a plain string still work.

A question belongs to the chat that asked it. It is shown only while that
chat is on screen, and put away (the choice and any typed answer kept) while
you look at another chat.

Questions asked before the UI was listening (it started late, or the plugin
reloaded) are picked up with `ask/list` on newer cores.

The desktop app also has a built-in question card, which only understands
plain string options. This plugin does not register a second handler for the
same question: while it is loaded, that card is hidden for these questions
so it cannot answer them, and it is restored when the plugin unloads. Other
questions, such as an approval, still use the built-in card.

Install with `python3 install.py ask_user` from the repository root.
