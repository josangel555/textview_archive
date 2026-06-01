#!/usr/bin/env python3
"""Convert macOS `sample` Call-graph output into folded stacks + a self-contained
interactive SVG flame graph. Dependency-free (stdlib only).

Usage: sample_flamegraph.py <sample.txt> <out.svg> [title]
Also writes <out.svg>.folded (collapsed stacks: a;b;c <self-samples>) — the
universal format, usable with any flame-graph viewer if the SVG isn't enough.

`sample` tree format (verified 2026-06-01):
    + 2517 start  (in dyld) + 7184  [0x...]
    +   2517 MarkdownViewer_main  (in MarkdownViewer) + 796  ...
    +     2495 -[NSApplication run]  (in AppKit) + 368 ...
    +     ! 2495 ...
Depth is the count of leading tree/indent chars before the sample count; each
nesting level adds 2 columns. Self-samples = node.count - sum(direct children).
"""
import sys, re, html

def parse(path):
    text = open(path, errors="replace").read().splitlines()
    try:
        start = next(i for i, l in enumerate(text) if l.startswith("Call graph"))
    except StopIteration:
        sys.exit("no 'Call graph' section in sample output")
    pat = re.compile(r"^([ +!:|]*?)(\d+)\s+(.*?)\s+\(in ([^)]+)\)")
    nodes = []  # (indent, count, label)
    for l in text[start + 1:]:
        if not l.strip():
            break
        m = pat.match(l)
        if not m:
            continue
        indent = len(m.group(1)); count = int(m.group(2))
        sym = m.group(3).strip(); lib = m.group(4)
        nodes.append((indent, count, f"{sym} [{lib}]"))
    if not nodes:
        sys.exit("parsed 0 frames")
    # indent -> contiguous level
    order = sorted({n[0] for n in nodes})
    level_of = {v: i for i, v in enumerate(order)}
    lvl = [level_of[n[0]] for n in nodes]
    # self = count - sum(direct children counts)
    folded = {}
    pathstack = []
    for i, (indent, count, label) in enumerate(nodes):
        L = lvl[i]
        pathstack = pathstack[:L]; pathstack.append(label)
        child = 0
        for j in range(i + 1, len(nodes)):
            if lvl[j] <= L: break
            if lvl[j] == L + 1: child += nodes[j][1]
        self_ct = count - child
        if self_ct > 0:
            key = ";".join(pathstack)
            folded[key] = folded.get(key, 0) + self_ct
    return folded

def build_tree(folded):
    root = {"name": "root", "value": 0, "children": {}}
    for stack, v in folded.items():
        node = root; root["value"] += v
        for frame in stack.split(";"):
            node = node["children"].setdefault(frame, {"name": frame, "value": 0, "children": {}})
            node["value"] += v
    return root

PALETTE = ["#e8704a", "#e6a23c", "#d9c44a", "#7cb342", "#42a5b3", "#5c7ae6", "#9c6ade", "#d65aa8"]

def svg(root, out, title):
    total = root["value"] or 1
    W, ROW = 1200, 17.0
    rects = []; maxd = [0]
    def walk(node, depth, x0, width):
        maxd[0] = max(maxd[0], depth)
        if depth > 0:
            name = node["name"]; pct = 100.0 * node["value"] / total
            color = PALETTE[(hash(name) % len(PALETTE))]
            label = name if len(name) * 6.5 < width else (name[:max(0, int(width / 6.5) - 1)] + "…" if width > 30 else "")
            rects.append((x0, depth, width, color, html.escape(label),
                          html.escape(f"{name}  —  {node['value']} samples ({pct:.1f}%)")))
        kids = sorted(node["children"].values(), key=lambda c: -c["value"])
        cx = x0
        for k in kids:
            w = W * k["value"] / total
            walk(k, depth + 1, cx, w); cx += w
    walk(root, 0, 0, W)
    H = int((maxd[0] + 2) * ROW)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="monospace" font-size="11">',
             f'<rect width="{W}" height="{H}" fill="#fbfbf6"/>',
             f'<text x="6" y="13" font-size="13" font-weight="bold">{html.escape(title)} — {total} samples</text>']
    for x0, depth, w, color, label, tip in rects:
        y = H - (depth + 1) * ROW
        ww = max(0.6, w - 0.6)
        parts.append(f'<g><title>{tip}</title>'
                     f'<rect x="{x0:.1f}" y="{y:.1f}" width="{ww:.1f}" height="{ROW-0.6:.1f}" fill="{color}" stroke="#fff" stroke-width="0.3"/>'
                     + (f'<text x="{x0+2:.1f}" y="{y+ROW-4:.1f}">{label}</text>' if label else "") + '</g>')
    parts.append("</svg>")
    open(out, "w").write("\n".join(parts))

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: sample_flamegraph.py <sample.txt> <out.svg> [title]")
    folded = parse(sys.argv[1])
    title = sys.argv[3] if len(sys.argv) > 3 else "flame graph"
    with open(sys.argv[2] + ".folded", "w") as f:
        for k, v in sorted(folded.items(), key=lambda kv: -kv[1]):
            f.write(f"{k} {v}\n")
    svg(build_tree(folded), sys.argv[2], title)
    print(f"wrote {sys.argv[2]} ({len(folded)} unique stacks, {sum(folded.values())} self-samples)")
