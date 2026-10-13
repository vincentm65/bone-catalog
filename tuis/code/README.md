# Code

Dressed as Visual Studio Code: explorer, tabs, bottom panel and status bar.

* Title bar with a command center, an activity bar, an Explorer side bar
  (open chats, the files this chat touched as a decorated tree, and an
  outline of its turns), editor tabs and breadcrumbs.
* The conversation reads like the Copilot Chat view: avatars, "Ran
  terminal command" / "Read file" tool lines, highlighted code blocks.
* A bottom panel (alt+j) with PROBLEMS, OUTPUT and TERMINAL tabs.
* The blue status bar: git branch, problems, the prompt's Ln/Col, model.
* ctrl+p / ctrl+o: a Quick Open picker for sessions.

Self-contained: it does not load bone.ui.setup().

Install from `/catalog`, then switch with `/tui use code`.
