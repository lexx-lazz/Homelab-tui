#!/usr/bin/env python3
"""pihole-tui - a btop-style live dashboard for Pi-hole v6.

Reads through `docker exec <container> pihole api <endpoint>`, which is the
Pi-hole CLI's own authenticated client. No app password, no session handling,
no secret on disk.

Keys:  q quit   r refresh now   p pause
"""

import json
import math
import os
import re
import select
import socket
import subprocess
import sys
import termios
import time
import tty
from concurrent.futures import ThreadPoolExecutor

from rich.align import Align
from rich.console import Console, Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

CONTAINER = os.environ.get("PIHOLE_CONTAINER", "pihole")
WEB_URL = ""            # worked out at startup by detect_web_url()
FAST_EVERY = 2.0        # summary + history
SLOW_EVERY = 10.0       # top lists, upstreams, blocking state

# btop-ish ramp, cool -> hot
RAMP = ["#00d7af", "#00d7ff", "#5fafff", "#afafff", "#ffafd7", "#ff8787", "#ff5f5f"]
C_BLOCKED = "#ff5f5f"
C_ALLOWED = "#00d7af"
C_CACHED = "#5fafff"
C_DIM = "grey42"
C_EDGE = "grey30"


# ---------------------------------------------------------------- data

def api(endpoint, timeout=8):
    """One API call. Returns parsed JSON, or None on any failure."""
    try:
        p = subprocess.run(
            ["docker", "exec", CONTAINER, "pihole", "api", endpoint],
            capture_output=True, text=True, timeout=timeout,
        )
        if p.returncode != 0:
            return None
        return json.loads(p.stdout)
    except Exception:
        return None


def detect_web_url():
    """Work out the admin URL for whatever host this is actually running on.

    Nothing about the address is baked in: the published port comes from
    docker, the address from whichever local interface routes outward.
    PIHOLE_WEB_URL overrides the lot.
    """
    override = os.environ.get("PIHOLE_WEB_URL")
    if override:
        return override

    port = 80
    try:
        p = subprocess.run(["docker", "port", CONTAINER, "80/tcp"],
                           capture_output=True, text=True, timeout=5)
        m = re.search(r":(\d+)\s*$", p.stdout.strip().splitlines()[0])
        if m:
            port = int(m.group(1))
    except Exception:
        pass

    host = "localhost"
    try:
        # connecting a UDP socket sends nothing; it just picks the route
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 1))          # TEST-NET-1, deliberately unroutable
        host = s.getsockname()[0]
        s.close()
    except Exception:
        pass

    suffix = "" if port == 80 else f":{port}"
    return f"http://{host}{suffix}/admin"


def api_many(endpoints):
    """Fetch concurrently - each docker exec costs ~160ms, so serial hurts."""
    with ThreadPoolExecutor(max_workers=len(endpoints)) as pool:
        return dict(zip(endpoints, pool.map(api, endpoints)))


class Store:
    def __init__(self):
        self.summary = None
        self.history = []
        self.top_blocked = []
        self.clients = []
        self.upstreams = []
        self.blocking = None
        self.err = None
        self.last_fast = 0.0
        self.last_slow = 0.0

    def fast(self):
        d = api_many(["stats/summary", "history"])
        s, h = d["stats/summary"], d["history"]
        if s is None and h is None:
            self.err = "cannot reach the pihole container"
            return
        self.err = None
        if s:
            self.summary = s
        if h:
            self.history = h.get("history", [])
        self.last_fast = time.time()

    def slow(self):
        eps = [
            "stats/top_domains?blocked=true&count=9",
            "stats/top_clients?count=9",
            "stats/upstreams",
            "dns/blocking",
        ]
        d = api_many(eps)
        if d[eps[0]]:
            self.top_blocked = d[eps[0]].get("domains", [])
        if d[eps[1]]:
            self.clients = d[eps[1]].get("clients", [])
        if d[eps[2]]:
            self.upstreams = d[eps[2]].get("upstreams", [])
        if d[eps[3]]:
            self.blocking = d[eps[3]]
        self.last_slow = time.time()


# ---------------------------------------------------------------- drawing

BLOCKS = " ▁▂▃▄▅▆▇█"


def stacked_graph(buckets, width, height):
    """Stacked column chart: blocked at the bottom, allowed above.

    One character cell carries one colour, so stacking beats braille here - a
    braille cell mixing two series would still have to pick a single colour.
    Partial blocks give sub-cell resolution at the top of each segment.
    """
    out = Text()
    if not buckets or width < 4 or height < 2:
        return out

    # squash 145 ten-minute buckets down to `width` columns
    cols = []
    n = len(buckets)
    for i in range(width):
        lo = int(i * n / width)
        hi = max(lo + 1, int((i + 1) * n / width))
        chunk = buckets[lo:hi]
        cols.append((sum(b.get("blocked", 0) for b in chunk),
                     sum(b.get("total", 0) for b in chunk)))

    peak = max((t for _, t in cols), default=0)
    if peak <= 0:
        return Text("\n".join(" " * width for _ in range(height)), style=C_EDGE)

    for row in range(height):
        top = height - row          # this row spans (top-1, top] in cell units
        for blocked, total in cols:
            b_cells = blocked / peak * height
            t_cells = total / peak * height
            if t_cells >= top:
                out.append("█", style=C_BLOCKED if b_cells >= top else C_ALLOWED)
            elif t_cells > top - 1:
                frac = t_cells - (top - 1)
                glyph = BLOCKS[max(1, min(8, round(frac * 8)))]
                out.append(glyph, style=C_BLOCKED if b_cells > top - 1 else C_ALLOWED)
            else:
                out.append(" ")
        if row != height - 1:
            out.append("\n")
    return out


def donut(fracs, width, height, inner=0.46):
    """Ring chart. fracs is [(fraction, colour), ...] summing to <= 1."""
    rows = []
    cx, cy = (width - 1) / 2, (height - 1) / 2
    for y in range(height):
        line = Text()
        for x in range(width):
            dx = (x - cx) / (width / 2)
            dy = (y - cy) / (height / 2)
            r = math.hypot(dx, dy)
            if r > 1.0 or r < inner:
                line.append(" ")
                continue
            ang = (90 - math.degrees(math.atan2(-dy, dx))) % 360   # cw from 12
            acc = 0.0
            placed = False
            for frac, colour in fracs:
                acc += frac * 360
                if ang <= acc:
                    line.append("█", style=colour)
                    placed = True
                    break
            if not placed:
                line.append("·", style=C_EDGE)
        rows.append(line)
    return rows


def donut_panel(summary, width, height):
    if not summary:
        return Align.center(Text("no data", style=C_DIM), vertical="middle")
    q = summary.get("queries", {})
    total = max(1, q.get("total", 0))
    blocked = q.get("blocked", 0)
    pct = q.get("percent_blocked", 0.0)

    w = max(13, min(25, width - 2))
    if w % 2 == 0:
        w -= 1
    h = max(7, min(13, height - 4))
    rows = donut([(blocked / total, C_BLOCKED), (1 - blocked / total, C_ALLOWED)], w, h)

    # punch the figure through the middle of the ring, keeping the ring
    # colour on the shoulders either side of the text
    mid = h // 2
    for text, r, style in ((f"{pct:.1f}%", mid, f"bold {C_BLOCKED}"),
                           ("blocked", mid + 1, C_DIM)):
        if not 0 <= r < h or len(text) >= w:
            continue
        start = (w - len(text)) // 2
        merged = Text()
        merged.append_text(rows[r][:start])
        merged.append(text, style=style)
        merged.append_text(rows[r][start + len(text):])
        rows[r] = merged

    # stacked, not side by side - one line wraps in a narrow panel and the
    # wrapped half looks like a stray label
    l1 = Text()
    l1.append("█ ", style=C_BLOCKED)
    l1.append(f"{blocked:,} blocked", style=C_DIM)
    l2 = Text()
    l2.append("█ ", style=C_ALLOWED)
    l2.append(f"{total - blocked:,} allowed", style=C_DIM)
    body = Text("\n").join(rows)
    return Align.center(
        Group(Align.center(body), Text(""), Align.center(l1), Align.center(l2)),
        vertical="middle")


def bar_table(rows, inner, label_key="domain"):
    """Ranked horizontal bars, gradient by rank like btop's meters.

    Columns are fixed, not ratios - a ratio column lets Rich ellipsize the bar
    itself, which turns a full meter into an indistinguishable "████…".
    """
    val_w = 7
    bar_w = max(8, int(inner * 0.32))
    label_w = max(8, inner - bar_w - val_w - 2)   # 2 = the two padding gaps

    t = Table.grid(padding=(0, 1))
    t.add_column(width=label_w, no_wrap=True, overflow="ellipsis")
    t.add_column(width=bar_w, no_wrap=True, overflow="crop")
    t.add_column(width=val_w, justify="right", no_wrap=True)
    if not rows:
        t.add_row(Text("no data", style=C_DIM), "", "")
        return t

    peak = max(r.get("count", 0) for r in rows) or 1
    for i, r in enumerate(rows):
        label = r.get(label_key) or r.get("ip") or "?"
        if label_key == "ip" and r.get("name"):
            label = r["name"]
        val = r.get("count", 0)
        filled = int(val / peak * bar_w)
        c = RAMP[min(len(RAMP) - 1, i * len(RAMP) // max(1, len(rows)))]
        bar = Text()
        bar.append("█" * filled, style=c)
        bar.append("─" * (bar_w - filled), style=C_EDGE)
        t.add_row(Text(str(label), style="white", overflow="ellipsis"), bar,
                  Text(f"{val:,}", style=c))
    return t


def header(store, paused):
    q = (store.summary or {}).get("queries", {})
    g = (store.summary or {}).get("gravity", {})
    blocking = (store.blocking or {}).get("blocking")

    line = Text()
    line.append("  pi-hole  ", style="bold white")
    if blocking == "enabled":
        line.append("● blocking", style=f"bold {C_ALLOWED}")
    elif blocking is None:
        line.append("● unknown", style=C_DIM)
    else:
        line.append(f"● {blocking}", style=f"bold {C_BLOCKED}")
    line.append("   ")
    for label, val, style in (
        ("queries", f"{q.get('total', 0):,}", C_CACHED),
        ("blocked", f"{q.get('blocked', 0):,}", C_BLOCKED),
        ("cached", f"{q.get('cached', 0):,}", C_ALLOWED),
        ("on blocklist", f"{g.get('domains_being_blocked', 0):,}", C_DIM),
    ):
        line.append(f"{label} ", style=C_DIM)
        line.append(f"{val}   ", style=style)
    if paused:
        line.append("[PAUSED]  ", style=f"bold {C_BLOCKED}")
    if store.err:
        line.append(store.err, style=f"bold {C_BLOCKED}")
    return line


def footer():
    t = Text()
    for key, desc in (("q", "quit"), ("r", "refresh"), ("p", "pause")):
        t.append(f"  {key}", style=f"bold {C_CACHED}")
        t.append(f" {desc}", style=C_DIM)
    t.append("     web ui ", style=C_DIM)
    t.append(WEB_URL, style=f"underline {C_ALLOWED}")
    t.append("  (open on your own machine)", style=C_EDGE)
    return t


def render(store, console, paused):
    W, H = console.size.width, console.size.height
    lay = Layout()
    lay.split_column(
        Layout(name="head", size=1),
        Layout(name="graph", ratio=3),
        Layout(name="mid", ratio=4),
        Layout(name="foot", size=1),
    )
    lay["mid"].split_row(Layout(name="blocked", ratio=3),
                         Layout(name="clients", ratio=3),
                         Layout(name="ring", ratio=2))

    lay["head"].update(header(store, paused))
    lay["foot"].update(footer())

    # mirror the layout's own arithmetic: 1 head + 1 foot fixed, the rest
    # split 3:4. A panel eats 2 rows of border and 2 columns of border+padding.
    avail = max(6, H - 2)
    gh = max(3, avail * 3 // 7 - 2)
    mid_h = max(5, avail * 4 // 7 - 2)
    col_w = max(18, W * 3 // 8)
    ring_w = max(18, W - 2 * col_w)

    lay["graph"].update(Panel(
        stacked_graph(store.history, max(10, W - 4), gh),
        title="[bold]queries — last 24h[/]  [dim]red blocked · green allowed[/]",
        title_align="left", border_style=C_EDGE, padding=(0, 1)))
    lay["blocked"].update(Panel(
        bar_table(store.top_blocked, col_w - 4, label_key="domain"),
        title="[bold]top blocked domains[/]", title_align="left",
        border_style=C_EDGE, padding=(0, 1)))
    lay["clients"].update(Panel(
        bar_table(store.clients, col_w - 4, label_key="ip"),
        title="[bold]top clients[/]", title_align="left",
        border_style=C_EDGE, padding=(0, 1)))
    lay["ring"].update(Panel(
        donut_panel(store.summary, ring_w - 4, mid_h),
        title="[bold]block rate[/]", title_align="left",
        border_style=C_EDGE, padding=(0, 1)))
    return lay


# ---------------------------------------------------------------- main

def main():
    global WEB_URL
    console = Console()
    store = Store()
    paused = False
    WEB_URL = detect_web_url()

    if api("stats/summary") is None:
        console.print(f"[bold red]Cannot query the '{CONTAINER}' container.[/]")
        console.print(f"[dim]Try:  docker exec {CONTAINER} pihole api stats/summary[/]")
        return 1

    isatty = sys.stdin.isatty()
    fd = sys.stdin.fileno() if isatty else None
    old = termios.tcgetattr(fd) if isatty else None
    if isatty:
        tty.setcbreak(fd)
    try:
        store.fast()
        store.slow()
        with Live(render(store, console, paused), console=console, screen=True,
                  auto_refresh=False) as live:
            while True:
                if isatty and select.select([sys.stdin], [], [], 0.12)[0]:
                    ch = sys.stdin.read(1).lower()
                    if ch == "q":
                        break
                    if ch == "p":
                        paused = not paused
                    if ch == "r":
                        store.fast()
                        store.slow()
                elif not isatty:
                    time.sleep(0.12)

                now = time.time()
                if not paused:
                    if now - store.last_fast >= FAST_EVERY:
                        store.fast()
                    if now - store.last_slow >= SLOW_EVERY:
                        store.slow()
                live.update(render(store, console, paused), refresh=True)
    except KeyboardInterrupt:
        pass
    finally:
        if isatty:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return 0


if __name__ == "__main__":
    sys.exit(main())
