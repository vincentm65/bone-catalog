# Usage dashboard

`/usage` and `/stats` open the same plugin-owned dashboard in terminal and desktop.
Requires Bone 2.4.6 (host API 4 and the `ui.page` standard library).

- `1`–`5` or `d/w/m/y/a`: today, seven days, four weeks, yearly, all time.
- Left/right or `h/l`: previous/next view.
- `t`: edit an inclusive custom date range; Tab switches fields, Enter applies.
- `r`: refresh; up/down or PageUp/PageDown scroll; `q`/Esc closes.

Queries use the daemon's local-time usage history. Date ranges must be valid,
ordered, and no longer than 100 years. Disable the `usage` plugin in `/config`
to remove both commands. Customize `usage_view.lua` for presentation and
`usage_data.lua` for aggregation. The harness only records usage and renders
ordinary plugin page nodes; there is no native `/stats` fallback.
