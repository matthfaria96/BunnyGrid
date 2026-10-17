"""Turns a REA observe/capture JSON into <name>.png (+ step PNGs) and a readable <name>.tree.txt."""
import base64, json, sys, os

def tree(nodes):
    out = []
    for n in nodes:
        depth = len(n["path"])
        bits = [(n.get("role") or "?").replace("AX", "")]
        if n.get("subrole"): bits.append(f"[{n['subrole'].replace('AX','')}]")
        if n.get("title"): bits.append(f'"{n["title"]}"')
        if n.get("value") not in (None, ""): bits.append(f"= {str(n['value'])[:80]!r}")
        if n.get("description"): bits.append(f"desc={n['description']!r}")
        if n.get("frame"):
            f = n["frame"]; bits.append(f"@{int(f.get('x',0))},{int(f.get('y',0))} {int(f.get('width',0))}x{int(f.get('height',0))}")
        if n.get("actions"): bits.append("{" + ",".join(a.replace("AX", "") for a in n["actions"]) + "}")
        out.append("  " * depth + " ".join(bits) + f"   #{n['path']}")
    return "\n".join(out)

src, name = sys.argv[1], sys.argv[2]
outdir = os.path.dirname(src)
d = json.load(open(src))["data"]["normalized_result"]
captures = [("", d["initial"])] + [(f"-step{i+1}", s.get("after") or s) for i, s in enumerate(d.get("steps") or [])]
for suffix, cap in captures:
    if not isinstance(cap, dict): continue
    shot = cap.get("screenshot")
    if shot and shot.get("base64"):
        open(os.path.join(outdir, f"{name}{suffix}.png"), "wb").write(base64.b64decode(shot["base64"]))
    if cap.get("nodes"):
        open(os.path.join(outdir, f"{name}{suffix}.tree.txt"), "w").write(tree(cap["nodes"]))
    print(name + suffix, len(cap.get("nodes") or []), "nodes", "truncated" if cap.get("truncated") else "")
