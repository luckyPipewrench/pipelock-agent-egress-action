#!/usr/bin/env bash
# Pipelock Audit Packet writer.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: audit-packet.sh \
  --receipt-chain <evidence jsonl path> \
  --verifier-output <path> \
  --posture <path> \
  --output-dir <dir>
EOF
}

RECEIPT_CHAIN=""
VERIFIER_OUTPUT=""
POSTURE=""
OUTPUT_DIR="pipelock-audit-packet"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --receipt-chain) RECEIPT_CHAIN="$2"; shift 2 ;;
    --verifier-output) VERIFIER_OUTPUT="$2"; shift 2 ;;
    --posture) POSTURE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "unknown flag: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$VERIFIER_OUTPUT" ]] || { usage >&2; echo "--verifier-output is required" >&2; exit 64; }
[[ -n "$POSTURE" ]] || { usage >&2; echo "--posture is required" >&2; exit 64; }
[[ -f "$VERIFIER_OUTPUT" ]] || { echo "verifier output not found: $VERIFIER_OUTPUT" >&2; exit 1; }
[[ -f "$POSTURE" ]] || { echo "posture file not found: $POSTURE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
if [[ -n "$RECEIPT_CHAIN" && -f "$RECEIPT_CHAIN" ]]; then
  cp "$RECEIPT_CHAIN" "$OUTPUT_DIR/evidence.jsonl"
else
  : >"$OUTPUT_DIR/evidence.jsonl"
fi
cp "$VERIFIER_OUTPUT" "$OUTPUT_DIR/verifier.txt"

python3 - "$OUTPUT_DIR" "$POSTURE" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys
from datetime import datetime, timezone

out_dir = pathlib.Path(sys.argv[1])
posture_path = pathlib.Path(sys.argv[2])
evidence_path = out_dir / "evidence.jsonl"
verifier_path = out_dir / "verifier.txt"
packet_path = out_dir / "packet.json"
summary_path = out_dir / "summary.md"

posture = json.loads(posture_path.read_text(encoding="utf-8"))
verifier_text = verifier_path.read_text(encoding="utf-8")
verdict = posture.get("verifier_verdict", "error")

totals = {
    "allow": 0,
    "block": 0,
    "warn": 0,
    "ask": 0,
    "strip": 0,
    "forward": 0,
    "redirect": 0,
    "other": 0,
}
receipt_count = 0
policy_hashes: set[str] = set()
transports: dict[str, int] = {}

with evidence_path.open("r", encoding="utf-8") as fh:
    for line in fh:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            totals["other"] += 1
            continue
        if entry.get("type") != "action_receipt":
            continue
        receipt_count += 1
        detail = entry.get("detail") or {}
        action_record = detail.get("action_record") or {}
        verdict_name = str(action_record.get("verdict") or "other")
        totals[verdict_name if verdict_name in totals else "other"] += 1
        policy_hash = action_record.get("policy_hash")
        if policy_hash:
            policy_hashes.add(str(policy_hash))
        transport = str(action_record.get("transport") or "unknown")
        transports[transport] = transports.get(transport, 0) + 1

packet = {
    "schema_version": "pipelock.audit_packet.v0",
    "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "receipt_count": receipt_count,
    "verifier": {
        "verdict": verdict,
        "trusted": bool(posture.get("trusted_verification")),
        "output_file": "verifier.txt",
    },
    "totals": totals,
    "policy_hashes": sorted(policy_hashes),
    "transports": transports,
    "posture": posture,
    "artifacts": {
        "packet": "packet.json",
        "summary": "summary.md",
        "evidence": "evidence.jsonl",
        "verifier": "verifier.txt",
    },
}

packet_path.write_text(json.dumps(packet, indent=2, sort_keys=True) + "\n", encoding="utf-8")

summary_lines = [
    "# Pipelock Audit Packet",
    "",
    f"- Verifier verdict: `{verdict}`",
    f"- Trusted verification: `{str(bool(posture.get('trusted_verification'))).lower()}`",
    f"- Receipt count: `{receipt_count}`",
    f"- Script: `{posture.get('script_basename', '<unknown>')}`",
    f"- Script args: `{posture.get('script_arg_count', 0)}`",
    f"- Enforcement mode: `{posture.get('enforcement_mode', '<unknown>')}`",
    "",
    "## Totals",
    "",
]
for key in sorted(totals):
    summary_lines.append(f"- {key}: `{totals[key]}`")
summary_lines.extend([
    "",
    "## Artifacts",
    "",
    "- `packet.json`",
    "- `summary.md`",
    "- `evidence.jsonl`",
    "- `verifier.txt`",
    "",
])
if verdict == "self_consistent_only":
    summary_lines.extend([
        "## Warning",
        "",
        "Trusted evidence requires signer-key pinning. This packet only proves internal receipt-chain consistency.",
        "",
    ])

summary_path.write_text("\n".join(summary_lines), encoding="utf-8")
PY
