# Profiling Swifty Notes

The scroll-perf work in May 2026 (commits 8b93646 → 4e7f497) lived
or died on whether we could read `sysprof` captures meaningfully.
This doc records the toolchain so the next perf episode can skip
the discovery phase.

`SCROLL_PERF_PLAN.md` covers the specific scroll-perf hypothesis +
the option tree we worked through. This file is the tooling
companion — what to install, what to run, how to read the output.

## Why sysprof, not macOS Time Profiler

`sysprof` is the right tool when the question is "where is GTK
spending render time on Linux":

- GTK4 emits per-widget marks (`gtk_widget_snapshot`,
  `gsk_renderer_render`, `layout pass`) — sysprof picks them up and
  shows you which widget classes dominate.
- The GL/Vulkan path is direct (no compat shim like the macOS GTK
  build), so what you see is the real render cost.
- Issue reporters live on Linux. Measure where the users feel it.

Use macOS Time Profiler only for cross-checks. The Swift symbols
are clearer there but the GTK internals are masked behind the
compatibility layer.

## Setup

```bash
# Ubuntu / Debian (24.04, 26.04)
sudo apt install sysprof linux-tools-common linux-tools-generic

# Fedora (40+)
sudo dnf install sysprof perf
```

Build the app for profiling. Release-equivalent with debug symbols
so Swift names demangle:

```bash
swift build -c release -Xswiftc -g
# binary lands at .build/release/swiftynotes
```

## Recording a capture

GUI flow (easiest):

```bash
sysprof
# New Recording → Command line: .build/release/swiftynotes
# Click Record, reproduce the scenario for ~10 s, click Stop, Save.
```

CLI flow (useful in CI / scripts):

```bash
sysprof-cli --command-arg .build/release/swiftynotes \
            --output /tmp/run.syscap
# stop with Ctrl-C when the scenario completes
```

The output `.syscap` file is what you analyze. It's a binary
capnproto-like format — needs `sysprof-cat` to read.

## Analyzing a capture — the critical workflow

This is the part the older perf doc didn't cover. Open in the
sysprof GUI is fine for one-off inspection, but for actual
optimization work you want the callgraph as text so `grep` and
`awk` can answer "did this commit move the needle":

```bash
sysprof-cat /path/to/capture.syscap > /tmp/cap.txt
wc -l /tmp/cap.txt   # ~600k lines for a 10-s recording is normal
```

Key things to extract from the dump:

### 1. Process total samples

```bash
awk '/symbol: "swiftynotes"/{found=1} found && /total:/{print; exit}' /tmp/cap.txt
```

This is the denominator. Everything else is interpreted relative
to it.

### 2. Top GTK render symbols

```bash
# All snapshot_child totals, sorted descending — the top number
# is the root render walk
awk '/symbol: "gtk_widget_snapshot_child"/{getline; getline t; print t}' \
    /tmp/cap.txt | sort -t: -k2 -rn | head -10
```

The headline metric for scroll-render perf is the ratio of the top
`gtk_widget_snapshot_child` total to swiftynotes-process total.
During the May 2026 work this dropped from 128 % (pre-B.1) to 9 %
(post-B.3) — a 14× shrink that matched the qualitative "feels
smooth now" feedback.

### 3. Other useful queries

```bash
# Signal dispatch cost (intrinsic GTK overhead; usually un-actionable)
awk '/symbol: "g_signal_emit"/{getline; getline t; print t}' \
    /tmp/cap.txt | sort -t: -k2 -rn | head -5

# Swift hot paths — look for demangled names
grep -E 'symbol: "[^"]*\.(tick|render|previewPositions|setActiveHeading)' \
     /tmp/cap.txt | sort -u | head -20

# Pango layout cost (regresses if you over-use markup)
grep 'symbol: "pango_layout_' /tmp/cap.txt | sort | uniq -c | sort -rn | head -5
```

### 4. Interpreting symbols

- `gtk_widget_snapshot_child` recursion total ≈ "how much of frame
  time is spent walking the widget tree". Reduce widget count to
  reduce this.
- `g_signal_emit` total is mostly GTK event-loop overhead and is
  hard to move from Swift code. Treat as a floor.
- `gsk_render_node_draw_full` recursion depth — if it goes very
  deep, nested `Box` containers are the cause.
- `gdk_memory_convert` showing up means a per-frame texture
  decode/conversion path is live. Cache the decoded texture.

If Swift symbols dominate the callgraph rather than GTK internals,
the optimization target is in user code (e.g. an unthrottled
scroll-spy or a per-tick widget tree rebuild). The May 2026 work
fixed several of these: commits 4fd4ed9, 892bb96, 50d1a6b.

## Companion: GTK Inspector for widget-tree size

```bash
GTK_DEBUG=interactive .build/release/swiftynotes
```

In the inspector → **Objects** → drill into the open note's
`MarkdownPreview`. Count widgets. Long notes pre-optimization had
80 +; post-Phase-B.3 the Markdown Showcase note sits at 47. The
sysprof render-walk cost tracks that count almost linearly, so
widget count is a cheap leading indicator before re-profiling.

The `debugTopLevelWidgetCount` / `debugWidgetTreeCount` APIs on
`MarkdownPreview` expose the same numbers programmatically and are
already used by the widget tests
(`Tests/SwiftyNotesWidgetTests/MarkdownPreviewWidgetTests.swift`),
so guarding a perf-sensitive structure with `#expect(treeCount ==
N)` is a sustainable regression check.

## FPS overlay — qualitative sanity check

```bash
GSK_DEBUG=fps .build/release/swiftynotes
```

GTK paints a FPS counter in the corner. Useful for a quick before
/ after vibe check before committing to a sysprof re-recording.

## Where the captures lived during the May 2026 work

`~/Downloads/System Capture from <date> <time>.syscap`. Several
captures across the optimization series — file names embed the
timestamp so the chronological order is obvious. The dumps were
written to `/tmp/sn_capN.txt` per capture and discarded after
analysis (they're 50-100 MB each, not worth committing).
