#!/usr/bin/env python3
"""Builds the website's editor demo data from the MarketingAssetsTests renders.

usage:
  SHOTNIX_MARKETING_DIR=/tmp/shotnix-marketing swift test --filter MarketingAssetsTests
  scripts/website-editor-demo.py /tmp/shotnix-marketing > ../shotnix-web/src/app/content/editor-demo.ts

Timing comes from shotnix-editor-demo.json. Geometry is measured on the probe renders:
the canvas painted pure green, the playhead at 0 s and 10 s, and the time label at 5 s.
Needs ffmpeg.
"""
import json
import subprocess
import sys
from pathlib import Path

WINDOW_WIDTH = 1512  # points; the renders are 2x
directory = Path(sys.argv[1])


def load(name):
    png = directory / f"{name}.png"
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(png)], capture_output=True, text=True, check=True)
    width, height = (int(v) for v in probe.stdout.strip().split(","))
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(png), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    return width, height, raw


W, H, frame = load("shotnix-editor-frame")
S = W / WINDOW_WIDTH  # pixels per point


def pixel(buf, x, y):
    i = (y * W + x) * 3
    return buf[i], buf[i + 1], buf[i + 2]


def near(c, target, tolerance):
    return all(abs(a - b) <= tolerance for a, b in zip(c, target))


def pt(v):
    return round(v / S, 2)


manifest = json.loads((directory / "shotnix-editor-demo.json").read_text())

# The canvas: pure green, left of the inspector.
_, _, canvas = load("probe-canvas")
xs, ys = [], []
for y in range(0, int(H * 0.75), 2):
    for x in range(0, int(W * 0.78), 2):
        if near(pixel(canvas, x, y), (0, 255, 0), 60):
            xs.append(x)
            ys.append(y)
preview = (min(xs), min(ys), max(xs) + 2, max(ys) + 2)


def playhead_x(name):
    _, _, buf = load(name)
    counts, tops = {}, {}
    for y in range(preview[3], H):
        for x in range(W):
            if near(pixel(buf, x, y), (255, 79, 110), 30):
                counts[x] = counts.get(x, 0) + 1
                tops.setdefault(x, y)
    columns = [x for x, n in counts.items() if n > (H - preview[3]) * 0.5]
    return sum(columns) / len(columns), min(tops[x] for x in columns)


x0, top = playhead_x("probe-playhead-0")
x10, _ = playhead_x("probe-playhead-10")
origin = pt(x0)
per_second = round((x10 - x0) / 10 / S, 3)


def time_x(seconds):
    return (origin + seconds * per_second) * S


# The current-time text: its row is where the frame at 0 s and 5 s differ below the preview;
# the text itself is the bright run on that row (the total after the slash is dimmer).
_, _, later = load("probe-time-5")
changed = [(x, y) for y in range(preview[3] + 4, top) for x in range(0, W // 2) if sum(abs(a - b) for a, b in zip(pixel(frame, x, y), pixel(later, x, y))) > 40]
row_top, row_bottom = min(y for _, y in changed), max(y for _, y in changed)
bright = [x for y in range(row_top, row_bottom + 1) for x in range(0, W // 3) if sum(pixel(frame, x, y)) > 560 and sum(pixel(later, x, y)) > 560 or (x, y) in set(changed)]
bright = sorted(bright)
# The play button's white icon sits left of the text: keep the run that contains the changed digit.
digit = min(x for x, _ in changed)
runs, run = [], [bright[0]]
for x in bright[1:]:
    if x - run[-1] > 8 * S:
        runs.append(run)
        run = [x]
    else:
        run.append(x)
runs.append(run)
text = next(r for r in runs if r[0] <= digit <= r[-1])
label = (text[0], row_top, text[-1], row_bottom)
button_color = (0x2D, 0x2D, 0x30)
button = [(x, y) for y in range(label[1] - int(16 * S), label[3] + int(16 * S)) for x in range(0, label[0] - int(4 * S)) if near(pixel(frame, x, y), button_color, 2)]
button_box = (min(x for x, _ in button), min(y for _, y in button), max(x for x, _ in button), max(y for _, y in button))


RULER = 24  # points, the timeline's ruler above the lanes


def band(x, match, start=None):
    start = top + int(RULER * S) if start is None else start
    rows = [y for y in range(start, H) if match(pixel(frame, int(x), y))]
    if not rows:
        return None
    start = previous = rows[0]
    for y in rows[1:]:
        if y > previous + 2:
            break
        previous = y
    return start, previous


BACKGROUND = pixel(frame, int(time_x(manifest["duration"]) - 4 * S), top + int(40 * S))
# Columns just inside each block's left edge, clear of its label.
caption_band = band(time_x(manifest["captions"][0]["start"]) + 5 * S, lambda c: not near(c, BACKGROUND, 10))
zoom_band = band(time_x(manifest["zooms"][0]["start"]) + 12 * S, lambda c: near(c, (0x54, 0x4D, 0xBB), 45))
# The clip track: from the first thumbnail row below the zoom lane to its orange edge.
clip_x = int(time_x(0.3))
clip_top = next(y for y in range(zoom_band[1] + int(8 * S), H) if not near(pixel(frame, clip_x, y), BACKGROUND, 6))
clip_bottom = max(y for y in range(clip_top, H) if near(pixel(frame, clip_x, y), (0xF0, 0x94, 0x33), 30))
clip_band = (clip_top, clip_bottom)
cut_x = time_x(manifest["cuts"][0]) if manifest["cuts"] else None
cut_band = band(cut_x, lambda c: c[0] > 200 and c[1] > 150 and c[2] < 110) if cut_x else None
cut_width = 0
if cut_band:
    y = (cut_band[0] + cut_band[1]) // 2
    yellow = [x for x in range(int(cut_x - 60 * S), int(cut_x + 60 * S)) if pixel(frame, x, y)[0] > 200 and pixel(frame, x, y)[2] < 110]
    cut_width = pt(max(yellow) - min(yellow))


def r(v):
    return round(v, 3)


out = []
out.append("// Generated by scripts/website-editor-demo.py (Shotnix repo) from the MarketingAssetsTests renders:")
out.append("// the demo's timing in seconds of the exported video, and where things sit in the editor frame")
out.append(f"// (points of a {WINDOW_WIDTH}×{round(H / S)} window). Regenerate after changing the editor's layout.")
out.append("")
out.append("export const editorDemo = {")
out.append(f"  duration: {r(manifest['duration'])},")
out.append(f"  fps: {manifest['fps']},")
out.append("  clips: [" + ", ".join(f"{{ start: {r(c['start'])}, end: {r(c['end'])} }}" for c in manifest["clips"]) + "],")
out.append("  cuts: [" + ", ".join(str(r(c)) for c in manifest["cuts"]) + "],")
out.append("  zooms: [")
for z in manifest["zooms"]:
    out.append(f"    {{ start: {r(z['start'])}, end: {r(z['end'])}, scale: {z['scale']}, followsCursor: {str(z['followsCursor']).lower()} }},")
out.append("  ],")
out.append("  captions: [")
for c in manifest["captions"]:
    out.append(f"    {{ start: {r(c['start'])}, end: {r(c['end'])}, text: {json.dumps(c['text'], ensure_ascii=False)} }},")
out.append("  ],")
out.append("  keystrokes: [" + ", ".join(f"{{ start: {r(k['start'])}, end: {r(k['end'])}, keys: {json.dumps(k['keys'], ensure_ascii=False)} }}" for k in manifest["keystrokes"]) + "],")
out.append("} as const;")
out.append("")
out.append("export const editorFrame = {")
out.append(f"  width: {WINDOW_WIDTH},")
out.append(f"  height: {round(H / S)},")
out.append("  /** The canvas inside the preview (16:9). */")
out.append(f"  preview: {{ x: {pt(preview[0])}, y: {pt(preview[1])}, width: {pt(preview[2] - preview[0])}, height: {pt(preview[3] - preview[1])} }},")
out.append("  /** Playhead: x = originX + seconds × pointsPerSecond, from the ruler to the bottom. */")
out.append(f"  timeline: {{ originX: {origin}, pointsPerSecond: {per_second}, top: {pt(top)}, bottom: {round(H / S)} }},")
out.append(f"  playButton: {{ x: {pt(button_box[0])}, y: {pt(button_box[1])}, width: {pt(button_box[2] - button_box[0] + 1)}, height: {pt(button_box[3] - button_box[1] + 1)} }},")
out.append(f"  timeLabel: {{ x: {pt(label[0]) - 2.5}, y: {round(pt((label[1] + label[3]) / 2) - 11, 2)}, width: {round(pt(label[2] - label[0]) + 5, 2)}, height: 22 }},")
out.append("  lanes: {")
out.append(f"    captions: {{ top: {pt(caption_band[0])}, bottom: {pt(caption_band[1] + 1)} }},")
out.append(f"    zooms: {{ top: {pt(zoom_band[0])}, bottom: {pt(zoom_band[1] + 1)} }},")
out.append(f"    clips: {{ top: {pt(clip_band[0])}, bottom: {pt(clip_band[1] + 1)} }},")
if cut_band:
    out.append(f"    cut: {{ top: {pt(cut_band[0])}, bottom: {pt(cut_band[1] + 1)}, width: {cut_width} }},")
out.append("  },")
out.append("  /** The Style inspector's background picker (layout constants). */")
out.append("  inspector: { x: 1197, y: 128, width: 294, height: 222 },")
out.append("} as const;")
print("\n".join(out))
