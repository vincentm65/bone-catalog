# ask_user

Lets the model ask you one or more questions: pick one option, pick several,
or type an answer.

Questions are asked in the input field, like the first bone. While one is
open the field becomes the question: it grows to hold the question, its
options, an input row and the keys, drawn in your prompt's own style
(background, border, padding and prefix). Typing and editing work as usual
in the input row. Your draft in the prompt is kept and comes back when the
question is answered.

- `↑`/`↓` move, `enter` chooses, `1`-`9` pick (or toggle) directly.
- Multi-select: `space` toggles, `enter` confirms (the highlighted option if
  none is checked).
- Typed text is the answer for text questions, and your own answer for
  choice questions that allow one.
- `esc` cancels; `ctrl+c` interrupts the turn as usual.

Answers reach the model as `{ value, label, index }`, `{ values, labels }`
or `{ value, custom = true }`; clients that answer with a plain string still
work.

Install with `python3 install.py ask_user` from the repository root.
