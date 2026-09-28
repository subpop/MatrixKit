#!/usr/bin/env python3
"""Generate the harness spec-endpoint registry from the official Matrix spec.

Reads the per-endpoint OpenAPI files
(`data/api/client-server/*.yaml`) at the pinned release in SPEC_VERSION
and rewrites the GENERATED block in Tests/Support/SpecEndpoint.swift.

The parser is line-based and stdlib-only on purpose: the spec files use
a rigid layout (`paths:` -> `  /path:` -> `    method:`), and avoiding
PyYAML keeps the tool runnable on a bare checkout.

Usage:
  python3 Tools/spec-registry/gen_spec_registry.py [--check] [--local DIR]

  --check   exit 1 when the committed Swift file differs from generated
  --local   read *.yaml from a local matrix-spec checkout instead of network
"""

import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC_VERSION = (ROOT / "Tools/spec-registry/SPEC_VERSION").read_text().strip()
SWIFT_FILE = ROOT / "Tests/Support/SpecEndpoint.swift"
OVERRIDES = ROOT / "Tools/spec-registry/overrides.json"
BASE_URL = f"https://raw.githubusercontent.com/matrix-org/matrix-spec/{SPEC_VERSION}/data/api/client-server"

METHODS = {"get", "post", "put", "delete", "patch", "head", "options"}

PATH_RE = re.compile(r'^  "?(/?[^":]*?)"?:\s*$')
METHOD_RE = re.compile(r"^    ([a-z]+):\s*$")
BASE_PATH_RE = re.compile(r"basePath:\s*\n\s+default:\s*(\S+)")


def parse_file(text: str, name: str):
    """Return (base_path, [(method, path, requires_auth)])."""
    base = "/_matrix/client/v3"
    m = BASE_PATH_RE.search(text)
    if m:
        base = m.group(1)
    rows = []
    in_paths = False
    current_path = None
    current_method = None
    op_has_auth = False
    op_auth_optional = False

    def flush():
        nonlocal op_has_auth, op_auth_optional
        if current_path is not None and current_method is not None:
            rows.append(
                (
                    current_method.upper(),
                    base + current_path,
                    op_has_auth and not op_auth_optional,
                )
            )
        op_has_auth = False
        op_auth_optional = False

    for line in text.splitlines():
        if re.match(r"^[a-zA-Z]", line):
            if current_path is not None:
                flush()
                current_path = None
                current_method = None
            in_paths = line.startswith("paths:")
            continue
        if not in_paths:
            continue
        pm = PATH_RE.match(line)
        if pm and pm.group(1).startswith("/"):
            flush()
            current_path = pm.group(1).strip()
            current_method = None
            continue
        mm = METHOD_RE.match(line)
        if mm and current_path is not None and mm.group(1) in METHODS:
            flush()
            current_method = mm.group(1)
            continue
        # Any dedent back to a 2-space or 4-space key ends the operation scan.
        if re.match(r"^  \S", line):
            flush()
            current_path = None
            current_method = None
            continue
        if current_method is not None and re.match(r"^      security:", line):
            # Next deeper lines name the schemes; accessToken* means auth.
            # A bare `- {}` entry means anonymous is also allowed
            # (e.g. GET /versions), i.e. auth is optional.
            op_has_auth = None  # pending: inspect following lines
            continue
        if op_has_auth is None:
            deeper = re.match(r"^        (-\s*)?(\S+)", line)
            if deeper:
                if "accessToken" in deeper.group(2):
                    op_has_auth = True
                if deeper.group(2) == "{}":
                    op_auth_optional = True
                continue
            else:
                # Left the security block without an accessToken scheme.
                op_has_auth = False
        if (
            current_method is not None
            and re.match(r"^    \S", line)
            and not METHOD_RE.match(line)
        ):
            flush()
            current_method = None
    flush()
    # De-duplicate (some files repeat an operation across version blocks).
    seen = set()
    out = []
    for method, path, auth in rows:
        key = (method, path)
        if key in seen:
            continue
        seen.add(key)
        # An endpoint is authenticated when any definition requires it.
        out.append([method, path, auth or False, name])
    merged = {}
    for method, path, auth, name in out:
        key = (method, path)
        if key in merged:
            merged[key][2] = merged[key][2] or auth
        else:
            merged[key] = [method, path, auth, name]
    return sorted(merged.values())


def load_overrides():
    import json

    if not OVERRIDES.exists():
        return {"drop": [], "add": []}
    return json.loads(OVERRIDES.read_text())


def fetch(name: str, local: Path | None) -> str:
    if local is not None:
        return (local / name).read_text()
    with urllib.request.urlopen(f"{BASE_URL}/{name}", timeout=30) as r:
        return r.read().decode("utf-8")


def main() -> int:
    check = "--check" in sys.argv
    local = None
    if "--local" in sys.argv:
        local = Path(sys.argv[sys.argv.index("--local") + 1])
    if local is None:
        import json

        with urllib.request.urlopen(
            f"https://api.github.com/repos/matrix-org/matrix-spec/contents/data/api/client-server?ref={SPEC_VERSION}",
            timeout=30,
        ) as r:
            names = sorted(
                e["name"] for e in json.loads(r.read()) if e["name"].endswith(".yaml")
            )
    else:
        names = sorted(p.name for p in local.glob("*.yaml"))
    rows = []
    for name in names:
        rows.extend(parse_file(fetch(name, local), name))
    ov = load_overrides()
    drop = {(d["method"], d["pathTemplate"]) for d in ov.get("drop", [])}
    rows = [r for r in rows if (r[0], r[1]) not in drop]
    for a in ov.get("add", []):
        rows.append(
            [
                a["method"],
                a["pathTemplate"],
                a["requiresAuth"],
                a.get("sourceFile", "overrides.json"),
            ]
        )
    rows.sort()
    lines = [
        "    // BEGIN GENERATED — do not edit by hand.",
        "    // Regenerate with: python3 Tools/spec-registry/gen_spec_registry.py",
        "    public static let endpoints: [SpecEndpoint] = [",
    ]
    for method, path, auth, name in rows:
        lines.append(
            f'        SpecEndpoint(method: "{method}", pathTemplate: "{path}", '
            f'requiresAuth: {"true" if auth else "false"}, sourceFile: "{name}"),'
        )
    lines.append("    ];")
    lines.append("    // END GENERATED")
    block = "\n".join(lines)
    text = SWIFT_FILE.read_text()
    text = re.sub(
        r'public static let specVersion = "[^"]*"',
        f'public static let specVersion = "{SPEC_VERSION}"',
        text,
    )
    new_text, n = re.subn(
        r"    // BEGIN GENERATED.*?    // END GENERATED", block, text, flags=re.S
    )
    assert n == 1, "generated block markers not found"
    if check:
        if text != new_text:
            print("SpecRegistry is stale: regenerate with gen_spec_registry.py")
            return 1
        print(f"SpecRegistry current ({len(rows)} endpoints, spec {SPEC_VERSION})")
        return 0
    SWIFT_FILE.write_text(new_text)
    print(f"Wrote {len(rows)} endpoints (spec {SPEC_VERSION}) to {SWIFT_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
