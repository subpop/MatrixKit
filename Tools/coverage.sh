#!/bin/bash
# Per-target line coverage for the library products.
#
#   Tools/coverage.sh [--min N]
#
# Runs the full suite with coverage, then reports line coverage per
# library target (MatrixKit, MatrixKitCrypto, MatrixKitSwiftData,
# MatrixRTC). Test support (Tests/Support), the test suites themselves,
# and the mx CLI are excluded — the gate measures shipped SDK surface only.
#
# --min N fails when any library target drops below N percent.
# --no-run reuses the last profdata/test binaries instead of re-running
# the suite (for iterating on the report itself).
# Keep this in step with .github/workflows/tests.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN=0
RUN=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --min) MIN="${2:-0}"; shift 2 ;;
        --no-run) RUN=0; shift ;;
        *) echo "unknown flag $1"; exit 2 ;;
    esac
done

if [[ "$RUN" == 1 ]]; then
    swift test --enable-code-coverage
fi

PROFDATA=$(find .build -name "*.profdata" | head -1)
if [[ -z "$PROFDATA" ]]; then echo "no profdata found"; exit 1; fi
# Xcode layout builds one test bundle per test target; merge them all so
# every library target's coverage is captured.
MAPFILE=$(mktemp)
find .build -path "*.xctest/Contents/MacOS/*" -not -path "*.dSYM*" -type f | sort > "$MAPFILE"
if [[ ! -s "$MAPFILE" ]]; then
    # SwiftPM-layout fallback: single test binary.
    find .build/debug -name "MatrixKitPackageTests" -path "*MacOS*" | head -1 > "$MAPFILE"
fi
if [[ ! -s "$MAPFILE" ]]; then echo "no test binary found"; exit 1; fi
MAIN=$(head -1 "$MAPFILE")
REST=()
while read -r BIN; do REST+=(-object "$BIN"); done < <(tail -n +2 "$MAPFILE")
rm -f "$MAPFILE"

export LLVM_PROFILE_FILE="$PROFDATA"
xcrun llvm-cov export "$MAIN" ${REST[@]+"${REST[@]}"} -instr-profile "$PROFDATA" \
    -ignore-filename-regex='\.build|/Tests/|/Checkouts/|/mx/' > /tmp/matrixkit-cov.json

python3 - /tmp/matrixkit-cov.json "$MIN" <<'EOF'
import json, sys
from collections import defaultdict

data = json.load(open(sys.argv[1]))
floor = float(sys.argv[2])
targets = ["Sources/MatrixKit/", "Sources/MatrixKitCrypto/",
           "Sources/MatrixKitSwiftData/",
           "Sources/MatrixRTC/"]
agg = {t: [0, 0] for t in targets}  # covered, total

for f in data["data"][0]["files"]:
    name = f["filename"]
    for t in targets:
        if t in name:
            lines = f["summary"]["lines"]
            agg[t][0] += lines["covered"]
            agg[t][1] += lines["count"]
            break

worst = 100.0
for t in targets:
    covered, total = agg[t]
    pct = 100.0 * covered / total if total else 100.0
    worst = min(worst, pct)
    short = t.replace("Sources/", "").rstrip("/")
    print(f"{short:20s} {pct:5.1f}% ({covered}/{total} lines)")
failed = worst < floor
print(f"gate: min {floor}% -> {'FAIL' if failed else 'PASS'}")
sys.exit(1 if failed else 0)
EOF
