#!/usr/bin/env bash
# Measured audit of the UI's source against the scale: type sizes (11, 12, 13, 15 only), paddings and spacing (4, 8,
# 12, 16, 24 only), and icon sizes (16, 20, 24 only). Prints each off-scale use as file:line and a count per kind.
# Advisory: it lists what to review; the surfaces' renders are the proof.
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, glob
ok_font = {11, 12, 13, 15}
ok_space = {0, 4, 8, 12, 16, 24}
ok_icon = {16, 20, 24}
counts = {"font": 0, "space": 0, "icon": 0}
rows = []
for f in sorted(glob.glob("Sources/SemanticSpotlight/*.swift")):
    if f.endswith(("Tests.swift", "TestHooks.swift")): continue
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        code = line.strip()
        if code.startswith("//"): continue
        for m in re.finditer(r"\.font\(\.system\(size: (\d+(?:\.\d+)?)", code):
            v = float(m.group(1))
            if v not in ok_font: counts["font"] += 1; rows.append(f"{f}:{n}: font {v:g}")
        for m in re.finditer(r"\.padding\((?:\.[a-z]+, )?(-?\d+(?:\.\d+)?)\)", code):
            v = abs(float(m.group(1)))
            if v not in ok_space: counts["space"] += 1; rows.append(f"{f}:{n}: padding {v:g}")
        for m in re.finditer(r"(?:spacing: |height: |width: )(\d+(?:\.\d+)?)\b", code):
            v = float(m.group(1))
            if v in (2, 6, 10, 14, 18, 20, 22, 28, 32, 36, 44, 48, 96) and "frame" not in code and "Spacer" not in code:
                counts["space"] += 1; rows.append(f"{f}:{n}: spacing/size {v:g}")
        for m in re.finditer(r"Image\(systemName:[^)]*\)\s*\.font\(\.system\(size: (\d+)", code):
            v = int(m.group(1))
            if v not in ok_icon and v not in ok_font: counts["icon"] += 1; rows.append(f"{f}:{n}: icon {v}")
for r in rows: print(r)
print(f"off-scale: font {counts['font']}, spacing/padding {counts['space']}, icon {counts['icon']}")
PY
