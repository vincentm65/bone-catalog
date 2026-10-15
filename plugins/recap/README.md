# Recap

Show a brief recap of the conversation

This is the Bone 3 port of the `recap` catalog package.

- core half: no
- TUI half: yes

Install with `python3 install.py recap` from the repository root.

## Settings

Open `/config` → Plugins → Recap to configure:

- **Automatic recap** (`recap.auto`): show a recap after an idle completed turn;
  disabled by default.
- **Idle delay (milliseconds)** (`recap.idle_ms`): wait 900000 ms (15 minutes)
  by default.

These replace the old General options `recap_auto` and `recap_idle_ms`.
If you previously customized those options, set them on the Recap page instead.
The `/recap` command still works regardless of the automatic recap setting.
