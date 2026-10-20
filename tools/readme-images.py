#!/usr/bin/env python3
"""Renders the README images from the real code into docs/images/.

  statusline.svg  the status line script's own output, ANSI colors as SVG
  band.svg        the desktop mod's ring SVGs and texts, laid out above a prompt box
  menubar.png     the menu bar app's --preview of every ring state

Run from anywhere: python3 tools/readme-images.py (needs jq, swiftc, tsc, node).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from html import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "images")

FONT_MONO = "SF Mono, Menlo, Consolas, monospace"
FONT_UI = "-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def statusline_svg(tmp):
    now = int(time.time())
    data = {"rate_limits": {
        "five_hour": {"used_percentage": 62, "resets_at": now + 7800},
        "seven_day": {"used_percentage": 18, "resets_at": now + 356400},
    }}
    env = dict(os.environ, CLAUDE_LIMITS_NOW=str(now), CLAUDE_LIMITS_FILE=f"{tmp}/limits.json",
               CLAUDE_LIMITS_CACHE=f"{tmp}/cache")
    env.pop("NO_COLOR", None)
    line = run(["bash", f"{ROOT}/statusline/statusline-limits.sh"], input=json.dumps(data), env=env).rstrip("\n")

    colors = {"0": "#d4d4d4", "32": "#5fd068", "33": "#e5c07b", "31": "#ef6b73", "90": "#7f848e"}
    color, spans = colors["0"], []
    for part in re.split(r"(\x1b\[\d+m)", line):
        m = re.fullmatch(r"\x1b\[(\d+)m", part)
        if m:
            color = colors.get(m.group(1), colors["0"])
        elif part:
            spans.append(f'<tspan fill="{color}">{escape(part)}</tspan>')

    width = 560
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="92" viewBox="0 0 {width} 92">
  <rect width="{width}" height="92" rx="10" fill="#1e1e1e"/>
  <line x1="16" y1="34" x2="{width - 16}" y2="34" stroke="#3a3a3a"/>
  <text x="18" y="25" font-family="{FONT_MONO}" font-size="13" fill="#d4d4d4">❯</text>
  <text x="18" y="60" font-family="{FONT_MONO}" font-size="13" xml:space="preserve">{"".join(spans)}</text>
  <text x="18" y="80" font-family="{FONT_MONO}" font-size="11" fill="#7f848e">⏵⏵ auto mode on</text>
</svg>
'''


def band_svg(tmp):
    js = f"{tmp}/js"
    run(["tsc", "--outDir", js, "--module", "esnext", "--moduleResolution", "bundler", "--target", "es2023", "--skipLibCheck",
         f"{ROOT}/mod/limit-rings/hooks/limits.ts"])
    with open(f"{js}/package.json", "w") as f:
        f.write('{"type":"module"}')
    script = """
      import * as L from './limits.js'
      const now = Date.now(), h = 3600000
      const five = { percentUsed: 62, resetsAt: now + 3 * h }
      const week = { percentUsed: 18, resetsAt: now + 99 * h }
      console.log(JSON.stringify({
        rings: [L.ringSvg(five, now), L.ringSvg(week, now)],
        texts: [L.windowText(five, L.FIVE_HOUR_MS, now), L.windowText(week, L.SEVEN_DAY_MS, now)],
      }))
    """
    with open(f"{js}/band.mjs", "w") as f:
        f.write(script)
    out = json.loads(run(["node", f"{js}/band.mjs"]))

    def item(x, ring, title, text):
        inner = re.sub(r"^<svg[^>]*>|</svg>$", "", ring)
        parts = [f'<tspan fill="#e8e6dc">{escape(title)}</tspan>',
                 f'<tspan fill="#9a988f"> · {escape(text["detail"])}</tspan>']
        if "warning" in text:
            parts.append(f'<tspan fill="#e5a14a"> · {escape(text["warning"])}</tspan>')
        return (f'<g transform="translate({x} 14)">{inner}</g>'
                f'<text x="{x + 26}" y="28" font-family="{FONT_UI}" font-size="12.5">{"".join(parts)}</text>')

    width = 640
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="104" viewBox="0 0 {width} 104">
  <rect width="{width}" height="104" rx="12" fill="#262624"/>
  {item(20, out["rings"][0], "5 часов", out["texts"][0])}
  {item(360, out["rings"][1], "Неделя", out["texts"][1])}
  <rect x="12" y="46" width="{width - 24}" height="46" rx="12" fill="none" stroke="#4a4944"/>
  <text x="30" y="74" font-family="{FONT_UI}" font-size="13" fill="#8a8880">⏎ to send, ⌘⏎ to queue for later</text>
</svg>
'''


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, svg in (("statusline.svg", statusline_svg(tmp)), ("band.svg", band_svg(tmp))):
            with open(os.path.join(OUT, name), "w") as f:
                f.write(svg)
        run(["bash", f"{ROOT}/menubar/build.sh"])
        run([f"{ROOT}/build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits", "--preview", os.path.join(OUT, "menubar.png")])
    print("\n".join(sorted(os.listdir(OUT))))


if __name__ == "__main__":
    sys.exit(main())
