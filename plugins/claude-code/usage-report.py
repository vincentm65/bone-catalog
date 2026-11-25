#!/usr/bin/env python3
"""How fast Bone's Claude Code calls use the plan's 5-hour window, next to
interactive Claude Code, from the same token prices.

Reads ~/.bone/claude-code-usage.jsonl (one line per Bone CLI call, with the
plan's utilization as that call reported it) and the interactive transcripts
in ~/.claude/projects (Bone's own private -tmp-bone3-claude-code-* ones are
skipped). Between consecutive Bone samples in one 5-hour window it fits

    utilization points gained = a * Bone API-price $ + b * interactive $

so a/b says how much more (or less) of the window a dollar of Bone usage takes
than a dollar of interactive usage. Usage from elsewhere (claude.ai, other
machines) is noise in this fit. Utilization is reported in whole percent, so
it needs a few hours of mixed use before the numbers settle.

usage: usage-report.py [days=7]
"""
import glob, json, os, sys, time
from datetime import datetime

# $ per million tokens: input, output, cache read. Cache writes: 1h = 2x input,
# 5m = 1.25x input.
PRICES = {
    "claude-fable-5-2": (8.0, 40.0, 0.20),
    "claude-opus-5-5": (4.0, 20.0, 0.20),
    "claude-sonnet-5-5": (2.0, 10.0, 0.10),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
}


def price(model, inp, out, read, w1h, w5m):
    p = PRICES.get(model)
    if not p:
        p = next((v for k, v in PRICES.items() if model and model.split("[")[0].startswith(k)), PRICES["claude-opus-5-5"])
    i, o, r = p
    return (inp * i + out * o + read * r + w1h * 2 * i + w5m * 1.25 * i) / 1e6


def bone_calls(path, since):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="ignore"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("at", 0) < since:
            continue
        w1h = e.get("cache_write_1h")
        w5m = e.get("cache_write_5m")
        if w1h is None and w5m is None:
            w1h, w5m = e.get("cache_write", 0), 0
        e["usd"] = price(e.get("model"), e.get("input_tokens", 0), e.get("output_tokens", 0),
                         e.get("cache_read", 0), w1h or 0, w5m or 0)
        rows.append(e)
    rows.sort(key=lambda e: e["at"])
    return rows


def interactive_calls(root, since):
    seen, rows = set(), []
    for f in glob.glob(os.path.join(root, "*", "*.jsonl")):
        if "-tmp-bone3-claude-code-" in f or os.path.getmtime(f) < since:
            continue
        for line in open(f, errors="ignore"):
            if '"usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") or {}
            u = m.get("usage")
            if e.get("type") != "assistant" or not u or m.get("model") == "<synthetic>":
                continue
            key = (m.get("id"), e.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            try:
                at = datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00")).timestamp()
            except (KeyError, ValueError):
                continue
            if at < since:
                continue
            cc = u.get("cache_creation") or {}
            w1h, w5m = cc.get("ephemeral_1h_input_tokens"), cc.get("ephemeral_5m_input_tokens")
            if w1h is None and w5m is None:
                w1h, w5m = u.get("cache_creation_input_tokens", 0), 0
            rows.append((at, price(m.get("model"), u.get("input_tokens", 0), u.get("output_tokens", 0),
                                   u.get("cache_read_input_tokens", 0), w1h or 0, w5m or 0)))
    rows.sort()
    return rows


def main():
    days = float(sys.argv[1]) if len(sys.argv) > 1 else 7
    since = time.time() - days * 86400
    bone_dir = os.environ.get("BONE_CONFIG_DIR") or os.path.expanduser("~/.bone")
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    bone = bone_calls(os.path.join(bone_dir, "claude-code-usage.jsonl"), since)
    cli = interactive_calls(os.path.join(claude_dir, "projects"), since)
    if not bone:
        print("No Bone calls logged yet (claude-code-usage.jsonl).")
        return

    def cli_usd(t0, t1):
        return sum(c for at, c in cli if t0 < at <= t1)

    # Samples: each Bone call's reported 5-hour utilization, grouped by window.
    windows = {}
    for e in bone:
        w = (e.get("windows") or {}).get("five_hour") or {}
        if isinstance(w.get("utilization"), (int, float)) and w.get("resets_at"):
            windows.setdefault(w["resets_at"], []).append((e["at"], w["utilization"] * 100, e))

    print("5-hour windows (utilization as Bone's calls reported it)")
    print("%-16s %6s %6s %8s %10s %13s" % ("resets", "from%", "to%", "calls", "bone $", "interactive $"))
    intervals = []
    for resets, samples in sorted(windows.items()):
        t0, u0 = samples[0][0], samples[0][1]
        bone_sum = sum(s[2]["usd"] for s in samples[1:])
        print("%-16s %6.0f %6.0f %8d %10.2f %13.2f" % (time.strftime("%m-%d %H:%M", time.localtime(resets)),
              u0, samples[-1][1], len(samples), bone_sum, cli_usd(t0, samples[-1][0])))
        # Merge consecutive samples into buckets of at least 3 points gained or
        # 45 minutes, so whole-percent rounding matters less.
        start_t, start_u, acc = t0, u0, 0.0
        for at, u, e in samples[1:]:
            acc += e["usd"]
            if u - start_u >= 3 or at - start_t >= 2700:
                intervals.append((u - start_u, acc, cli_usd(start_t, at)))
                start_t, start_u, acc = at, u, 0.0

    # Least squares through the origin: d = a*x + b*y.
    sxx = sum(x * x for _, x, _ in intervals)
    syy = sum(y * y for _, _, y in intervals)
    sxy = sum(x * y for _, x, y in intervals)
    sdx = sum(d * x for d, x, _ in intervals)
    sdy = sum(d * y for d, _, y in intervals)
    det = sxx * syy - sxy * sxy
    print()
    print("Bone calls: %d (%.2f $ at API prices); interactive calls: %d (%.2f $)"
          % (len(bone), sum(e["usd"] for e in bone), len(cli), sum(c for _, c in cli)))
    print("intervals used for the fit: %d" % len(intervals))
    if len(intervals) < 4 or det <= 1e-12:
        if sxx > 0 and syy == 0:
            print("Only Bone usage in these intervals: %.2f points per $ of Bone usage" % (sdx / sxx))
        else:
            print("Not enough mixed data yet: use both for a few hours, then run this again.")
        return
    a = (sdx * syy - sdy * sxy) / det
    b = (sdy * sxx - sdx * sxy) / det
    print("5-hour points per $:  Bone %.2f   interactive %.2f" % (a, b))
    if b > 0:
        print("A dollar of Bone usage takes %.2fx the window a dollar of interactive usage does" % (a / b))


main()
