#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ORCA_BIN="$ROOT/zig-out/bin/orca"

if [ ! -x "$ORCA_BIN" ]; then
  echo "missing ryk binary at $ORCA_BIN; run zig build first" >&2
  exit 1
fi

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
missing = []
for md in [root / "README.md", *sorted((root / "docs").glob("*.md"))]:
    text = md.read_text()
    for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", text):
        target = match.group(1)
        if "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        target = target.split("#", 1)[0]
        if not target:
            continue
        path = (md.parent / target).resolve()
        try:
            path.relative_to(root.resolve())
        except ValueError:
            continue
        if not path.exists():
            missing.append(f"{md.relative_to(root)} -> {target}")
if missing:
    print("missing markdown targets:", file=sys.stderr)
    for item in missing:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

find "$ROOT/examples/policies" "$ROOT/policies" -name '*.yaml' -print | while IFS= read -r policy; do
  "$ORCA_BIN" policy check "$policy" >/dev/null
done
"$ORCA_BIN" policy check "$ROOT/examples/leaky-agent-demo/policy.yaml" >/dev/null
"$ORCA_BIN" mcp manifest check "$ROOT/examples/mcp/demo-manifest.yaml" >/dev/null

"$ROOT/examples/leaky-agent-demo/run-demo.sh" >/tmp/orca-doc-demo.out

grep -R "generatedSyntheticDemoValue" "$ROOT/README.md" "$ROOT/docs" "$ROOT/examples" >/dev/null 2>&1 && {
  echo "found forbidden demo fallback value in docs/examples" >&2
  exit 1
}

grep -R "perfect sandboxing" "$ROOT/README.md" "$ROOT/docs" >/dev/null
grep -R "transparent network enforcement" "$ROOT/README.md" "$ROOT/docs" >/dev/null
grep -R "transparent filesystem" "$ROOT/README.md" "$ROOT/docs" >/dev/null

echo "documentation validation passed"
