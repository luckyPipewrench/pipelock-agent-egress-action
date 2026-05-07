#!/usr/bin/env bash
# Pipelock agent egress action entrypoint.
set -Eeuo pipefail

AGENT_USER="pipelock-agent"
AGENT_NAME="action-ephemeral"
RUN_SUFFIX="$$"
NETNS="pipelock-agent-$RUN_SUFFIX"
HOST_IF="plh$RUN_SUFFIX"
AGENT_IF="pla$RUN_SUFFIX"
IP_OCTET_2=$((20 + (RUN_SUFFIX % 200)))
IP_OCTET_3=$((30 + ((RUN_SUFFIX / 200) % 200)))
HOST_IP="10.$IP_OCTET_2.$IP_OCTET_3.1"
AGENT_IP="10.$IP_OCTET_2.$IP_OCTET_3.2"
PIPELOCK_PORT="8888"

SCRIPT_PATH=""
SCRIPT_ARGS_RAW=""
CONFIG=".pipelock/ci.yaml"
AGENT_IDENTITY="github-actions-agent"
PIPELOCK_VERSION=""
PIPELOCK_BIN=""
SIGNER_PRIVATE_KEY_PATH=""
SIGNER_PUBLIC_KEY=""
VERIFY_SIGNER_KEY=""
TRUSTED_VERIFICATION="false"
AUDIT_PACKET_DIR="pipelock-audit-packet"
WORKING_DIRECTORY="."
FAIL_ON_VERIFIER_ERROR="true"
DEBUG="false"

RUNTIME_ROOT=""
ACTION_WORK_ROOT=""
RUNTIME_BIN=""
RUNTIME_CONFIG=""
RUNTIME_KEYSTORE=""
EVIDENCE_DIR=""
POSTURE_PATH=""
VERIFIER_OUTPUT=""
EVIDENCE_EXPORT=""
KEYGEN_OUTPUT=""
PIPELOCK_PID=""
AGENT_EXIT_CODE=0
VERIFIER_VERDICT="error"
RECEIPT_COUNT=0
CREATED_AGENT_USER="false"
SUDOERS_DENY_FILE=""
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: run.sh \
  --script-path <script under working directory> \
  [--script-args <newline-delimited args>] \
  --config <pipelock config path> \
  --agent-identity <identity string> \
  --pipelock-version <reserved release version or empty> \
  --pipelock-bin <binary path or empty> \
  --signer-private-key-path <private key path or empty> \
  --signer-public-key <public key value/path or empty> \
  --audit-packet-dir <output dir> \
  --working-directory <directory> \
  --fail-on-verifier-error <true|false> \
  --debug <true|false>
EOF
}

note() {
  printf 'pipelock-agent-egress-action: %s\n' "$*" >&2
}

die() {
  printf 'pipelock-agent-egress-action: error: %s\n' "$*" >&2
  exit 1
}

debug() {
  if [[ "$DEBUG" == "true" ]]; then
    note "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

bool_input() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) die "$name must be true or false, got $value" ;;
  esac
}

yaml_quote() {
  python3 - "$1" <<'PY'
import sys

print("'" + sys.argv[1].replace("'", "''") + "'")
PY
}

json_string_array() {
  python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
}

cleanup() {
  set +e
  if [[ -n "$PIPELOCK_PID" ]]; then
    if sudo kill -0 "$PIPELOCK_PID" >/dev/null 2>&1; then
      sudo kill "$PIPELOCK_PID" >/dev/null 2>&1
      for _ in $(seq 1 25); do
        sudo kill -0 "$PIPELOCK_PID" >/dev/null 2>&1 || break
        sleep 0.2
      done
      if sudo kill -0 "$PIPELOCK_PID" >/dev/null 2>&1; then
        sudo kill -KILL "$PIPELOCK_PID" >/dev/null 2>&1
      fi
    fi
    wait "$PIPELOCK_PID" >/dev/null 2>&1
  fi
  sudo ip netns del "$NETNS" >/dev/null 2>&1
  sudo ip link del "$HOST_IF" >/dev/null 2>&1
  if [[ -n "$RUNTIME_ROOT" ]]; then
    sudo rm -rf "$RUNTIME_ROOT" >/dev/null 2>&1
  fi
  if [[ -n "$ACTION_WORK_ROOT" ]]; then
    rm -rf "$ACTION_WORK_ROOT" >/dev/null 2>&1
  fi
  if [[ -n "$SUDOERS_DENY_FILE" ]]; then
    sudo rm -f "$SUDOERS_DENY_FILE" >/dev/null 2>&1
  fi
  if [[ "$CREATED_AGENT_USER" == "true" ]]; then
    sudo userdel -r "$AGENT_USER" >/dev/null 2>&1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script-path) SCRIPT_PATH="$2"; shift 2 ;;
    --script-args) SCRIPT_ARGS_RAW="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --agent-identity) AGENT_IDENTITY="$2"; shift 2 ;;
    --pipelock-version) PIPELOCK_VERSION="$2"; shift 2 ;;
    --pipelock-bin) PIPELOCK_BIN="$2"; shift 2 ;;
    --signer-private-key-path) SIGNER_PRIVATE_KEY_PATH="$2"; shift 2 ;;
    --signer-public-key) SIGNER_PUBLIC_KEY="$2"; shift 2 ;;
    --audit-packet-dir) AUDIT_PACKET_DIR="$2"; shift 2 ;;
    --working-directory) WORKING_DIRECTORY="$2"; shift 2 ;;
    --fail-on-verifier-error) FAIL_ON_VERIFIER_ERROR="$2"; shift 2 ;;
    --debug) DEBUG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown flag: $1" ;;
  esac
done

[[ -n "$SCRIPT_PATH" ]] || die "--script-path is required"
bool_input "--fail-on-verifier-error" "$FAIL_ON_VERIFIER_ERROR"
bool_input "--debug" "$DEBUG"

require_cmd sudo
require_cmd ip
require_cmd iptables
require_cmd ip6tables
require_cmd setpriv
require_cmd unshare
require_cmd curl
require_cmd python3
require_cmd realpath
require_cmd getent
require_cmd visudo
require_cmd grep
require_cmd install
require_cmd mount
require_cmd umount
sudo -n true >/dev/null 2>&1 || die "passwordless sudo is required on supported Linux runners"
[[ "$(uname -s)" == "Linux" ]] || die "only Linux runners are supported"

if [[ -n "$SIGNER_PUBLIC_KEY" && -z "$SIGNER_PRIVATE_KEY_PATH" ]]; then
  die "signer-public-key requires signer-private-key-path; omit signer-public-key for ephemeral self-consistent verification"
fi

WORKDIR_REAL="$(realpath -e "$WORKING_DIRECTORY")"
if [[ "$SCRIPT_PATH" = /* ]]; then
  SCRIPT_REAL="$(realpath -e "$SCRIPT_PATH")"
else
  SCRIPT_REAL="$(realpath -e "$WORKDIR_REAL/$SCRIPT_PATH")"
fi
case "$SCRIPT_REAL" in
  "$WORKDIR_REAL"/*) ;;
  *) die "script-path escapes working-directory: $SCRIPT_PATH" ;;
esac
[[ -f "$SCRIPT_REAL" ]] || die "script-path is not a file: $SCRIPT_REAL"
[[ -r "$SCRIPT_REAL" ]] || die "script-path is not readable: $SCRIPT_REAL"

SCRIPT_ARGV=()
if [[ -n "$SCRIPT_ARGS_RAW" ]]; then
  while IFS= read -r arg; do
    SCRIPT_ARGV+=("$arg")
  done <<<"$SCRIPT_ARGS_RAW"
fi
SCRIPT_BASENAME="$(basename "$SCRIPT_REAL")"
note "script: $SCRIPT_BASENAME (${#SCRIPT_ARGV[@]} args)"
if [[ "$DEBUG" == "true" ]]; then
  debug "validated script path: $SCRIPT_REAL"
  debug "script args: ${SCRIPT_ARGV[*]:-<none>}"
fi

resolve_pipelock_bin() {
  local candidate=""
  if [[ -n "$PIPELOCK_BIN" ]]; then
    candidate="$(realpath -e "$PIPELOCK_BIN")"
  elif command -v pipelock >/dev/null 2>&1; then
    candidate="$(command -v pipelock)"
  else
    if [[ -n "$PIPELOCK_VERSION" ]]; then
      die "pinned release install is not wired yet; provide --pipelock-bin or put pipelock on PATH"
    fi
    die "pipelock-bin is required unless pipelock is already on PATH; this action does not download latest releases"
  fi
  [[ -x "$candidate" ]] || die "pipelock binary is not executable: $candidate"
  printf '%s\n' "$candidate"
}

HOST_PIPELOCK_BIN="$(resolve_pipelock_bin)"
"$HOST_PIPELOCK_BIN" --version >/dev/null 2>&1 || die "pipelock binary failed --version: $HOST_PIPELOCK_BIN"

RUNTIME_ROOT="${RUNNER_TEMP:-/tmp}/pipelock-agent-egress-${GITHUB_RUN_ID:-local}-$$"
ACTION_WORK_ROOT="${RUNNER_TEMP:-/tmp}/pipelock-agent-egress-work-${GITHUB_RUN_ID:-local}-$$"
RUNTIME_BIN="$RUNTIME_ROOT/bin/pipelock"
RUNTIME_CONFIG="$RUNTIME_ROOT/config/action.yaml"
RUNTIME_KEYSTORE="$RUNTIME_ROOT/keys"
EVIDENCE_DIR="$RUNTIME_ROOT/evidence"
POSTURE_PATH="$ACTION_WORK_ROOT/posture.json"
VERIFIER_OUTPUT="$ACTION_WORK_ROOT/verifier.txt"
EVIDENCE_EXPORT="$ACTION_WORK_ROOT/export/evidence.jsonl"
KEYGEN_OUTPUT="$ACTION_WORK_ROOT/keygen.txt"
PIPELOCK_LOG="$ACTION_WORK_ROOT/logs/pipelock.log"

trap cleanup EXIT

mkdir -p "$ACTION_WORK_ROOT"/{export,logs}
chmod 0700 "$ACTION_WORK_ROOT" "$ACTION_WORK_ROOT"/{export,logs}
sudo mkdir -p "$RUNTIME_ROOT"/{bin,config,keys,evidence}
sudo chmod 0700 "$RUNTIME_ROOT" "$RUNTIME_ROOT"/{keys,evidence}
sudo install -m 0555 -o root -g root "$HOST_PIPELOCK_BIN" "$RUNTIME_BIN"

ensure_agent_user() {
  if id "$AGENT_USER" >/dev/null 2>&1; then
    CREATED_AGENT_USER="false"
  else
    sudo useradd --system --create-home --shell /bin/bash "$AGENT_USER"
    CREATED_AGENT_USER="true"
  fi

  local groups
  groups="$(id -nG "$AGENT_USER")"
  for forbidden in sudo wheel docker kvm; do
    case " $groups " in
      *" $forbidden "*) die "$AGENT_USER must not belong to privileged group $forbidden" ;;
    esac
  done

  SUDOERS_DENY_FILE="/etc/sudoers.d/pipelock-agent-egress-action-$$"
  printf '%s ALL=(ALL:ALL) !ALL\n' "$AGENT_USER" | sudo tee "$SUDOERS_DENY_FILE" >/dev/null
  sudo chmod 0440 "$SUDOERS_DENY_FILE"
  sudo visudo -cf "$SUDOERS_DENY_FILE" >/dev/null
}

ensure_agent_user
AGENT_UID="$(id -u "$AGENT_USER")"
AGENT_GID="$(id -g "$AGENT_USER")"
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"

if [[ -n "$SIGNER_PRIVATE_KEY_PATH" ]]; then
  SIGNER_PRIVATE_KEY_PATH="$(realpath -e "$SIGNER_PRIVATE_KEY_PATH")"
  sudo test -r "$SIGNER_PRIVATE_KEY_PATH" || die "signer private key is not readable by root: $SIGNER_PRIVATE_KEY_PATH"
  if [[ -n "$SIGNER_PUBLIC_KEY" ]]; then
    VERIFY_SIGNER_KEY="$SIGNER_PUBLIC_KEY"
    TRUSTED_VERIFICATION="true"
  fi
else
  if ! sudo "$RUNTIME_BIN" keygen "$AGENT_NAME" --keystore "$RUNTIME_KEYSTORE" --force >"$KEYGEN_OUTPUT" 2>&1; then
    sed -n '1,80p' "$KEYGEN_OUTPUT" >&2 || true
    die "pipelock keygen failed; expected CLI: pipelock keygen <agent-name> --keystore <dir> --force"
  fi
  SIGNER_PRIVATE_KEY_PATH="$RUNTIME_KEYSTORE/agents/$AGENT_NAME/id_ed25519"
  EPHEMERAL_PUBLIC_KEY_PATH="$RUNTIME_KEYSTORE/agents/$AGENT_NAME/id_ed25519.pub"
  sudo chmod 0600 "$SIGNER_PRIVATE_KEY_PATH"
  sudo chmod 0644 "$EPHEMERAL_PUBLIC_KEY_PATH"
  if [[ -n "$SIGNER_PUBLIC_KEY" ]]; then
    VERIFY_SIGNER_KEY="$SIGNER_PUBLIC_KEY"
    TRUSTED_VERIFICATION="true"
  else
    VERIFY_SIGNER_KEY="$EPHEMERAL_PUBLIC_KEY_PATH"
    TRUSTED_VERIFICATION="false"
  fi
fi

write_runtime_config() {
  local listen_addr="$HOST_IP:$PIPELOCK_PORT"
  {
    printf 'version: 1\n'
    printf 'mode: balanced\n'
    printf 'default_agent_identity: %s\n' "$(yaml_quote "$AGENT_IDENTITY")"
    printf 'bind_default_agent_identity: true\n'
    printf 'fetch_proxy:\n'
    printf '  listen: %s\n' "$(yaml_quote "$listen_addr")"
    printf '  timeout_seconds: 30\n'
    printf '  max_response_mb: 10\n'
    printf 'forward_proxy:\n'
    printf '  enabled: true\n'
    printf 'websocket_proxy:\n'
    printf '  enabled: true\n'
    printf 'flight_recorder:\n'
    printf '  enabled: true\n'
    printf '  dir: %s\n' "$(yaml_quote "$EVIDENCE_DIR")"
    printf '  redact: true\n'
    printf '  sign_checkpoints: true\n'
    printf '  signing_key_path: %s\n' "$(yaml_quote "$SIGNER_PRIVATE_KEY_PATH")"
  } | sudo tee "$RUNTIME_CONFIG" >/dev/null
  sudo chmod 0600 "$RUNTIME_CONFIG"
}

write_runtime_config

setup_network_boundary() {
  sudo ip netns del "$NETNS" >/dev/null 2>&1 || true
  sudo ip link del "$HOST_IF" >/dev/null 2>&1 || true

  sudo ip netns add "$NETNS"
  sudo ip link add "$HOST_IF" type veth peer name "$AGENT_IF"
  sudo ip link set "$AGENT_IF" netns "$NETNS"
  sudo ip addr add "$HOST_IP/30" dev "$HOST_IF"
  sudo ip link set "$HOST_IF" up
  sudo ip -n "$NETNS" addr add "$AGENT_IP/30" dev "$AGENT_IF"
  sudo ip -n "$NETNS" link set lo up
  sudo ip -n "$NETNS" link set "$AGENT_IF" up
  sudo ip -n "$NETNS" route add default via "$HOST_IP"

  sudo ip netns exec "$NETNS" iptables -P OUTPUT DROP
  sudo ip netns exec "$NETNS" iptables -F OUTPUT
  sudo ip netns exec "$NETNS" iptables -A OUTPUT -o lo -j ACCEPT
  sudo ip netns exec "$NETNS" iptables -A OUTPUT -p tcp -d "$HOST_IP" --dport "$PIPELOCK_PORT" -j ACCEPT
  sudo ip netns exec "$NETNS" iptables -A OUTPUT -j REJECT
  sudo ip netns exec "$NETNS" ip6tables -P OUTPUT DROP
  sudo ip netns exec "$NETNS" ip6tables -F OUTPUT
  sudo ip netns exec "$NETNS" ip6tables -A OUTPUT -j REJECT
}

setup_network_boundary

sudo "$RUNTIME_BIN" run --config "$RUNTIME_CONFIG" >"$PIPELOCK_LOG" 2>&1 &
PIPELOCK_PID="$!"

for _ in $(seq 1 80); do
  if curl -fsS --max-time 1 "http://$HOST_IP:$PIPELOCK_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if ! curl -fsS --max-time 2 "http://$HOST_IP:$PIPELOCK_PORT/health" >/dev/null 2>&1; then
  sed -n '1,120p' "$PIPELOCK_LOG" >&2 || true
  die "pipelock listener did not become healthy on $HOST_IP:$PIPELOCK_PORT"
fi

run_agent_probe() {
  sudo -E ip netns exec "$NETNS" setpriv \
    --reuid "$AGENT_UID" \
    --regid "$AGENT_GID" \
    --clear-groups \
    --no-new-privs \
    --bounding-set=-all \
    --inh-caps=-all \
    --ambient-caps=-all \
    -- "$@"
}

if run_agent_probe sudo -n true >/dev/null 2>&1; then
  die "$AGENT_USER can invoke sudo; containment would be bypassable"
fi
if run_agent_probe cat "$SIGNER_PRIVATE_KEY_PATH" >/dev/null 2>&1; then
  die "$AGENT_USER can read the signing private key"
fi
if run_agent_probe sh -c 'echo malicious >> "$1"/write-probe' sh "$EVIDENCE_DIR" >/dev/null 2>&1; then
  die "$AGENT_USER can write to the evidence directory"
fi
if command -v getpcaps >/dev/null 2>&1; then
  if ! run_agent_probe sh -c 'getpcaps $$' >"$ACTION_WORK_ROOT/export/capabilities.txt" 2>&1; then
    die "capability probe failed"
  fi
  if grep -Eq 'cap_[a-z0-9_]+' "$ACTION_WORK_ROOT/export/capabilities.txt"; then
    sed -n '1,20p' "$ACTION_WORK_ROOT/export/capabilities.txt" >&2 || true
    die "$AGENT_USER retained Linux capabilities after setpriv"
  fi
fi

PROXY_URL="http://$HOST_IP:$PIPELOCK_PORT"
CA_BUNDLE="${PIPELOCK_CA_BUNDLE:-}"
if [[ -z "$CA_BUNDLE" && -f "$HOME/.pipelock/ca.pem" ]]; then
  CA_BUNDLE="$HOME/.pipelock/ca.pem"
fi

note "launching script inside $NETNS as $AGENT_USER"
set +e
sudo -E ip netns exec "$NETNS" unshare --mount --propagation private bash -c '
set -euo pipefail
workdir="$1"; shift
agent_uid="$1"; shift
agent_gid="$1"; shift
agent_home="$1"; shift
proxy_url="$1"; shift
ca_bundle="$1"; shift
docker_sock_created="false"
cleanup_docker_sock() {
  set +e
  umount /var/run/docker.sock >/dev/null 2>&1
  if [[ "$docker_sock_created" == "true" ]]; then
    rm -f /var/run/docker.sock
  fi
}
trap cleanup_docker_sock EXIT
if [[ ! -e /var/run/docker.sock ]]; then
  install -m 000 /dev/null /var/run/docker.sock
  docker_sock_created="true"
fi
mount --bind /dev/null /var/run/docker.sock
cd "$workdir"
export HOME="$agent_home"
export HTTP_PROXY="$proxy_url"
export HTTPS_PROXY="$proxy_url"
export http_proxy="$proxy_url"
export https_proxy="$proxy_url"
unset NO_PROXY
unset no_proxy
if [[ -n "$ca_bundle" ]]; then
  export NODE_EXTRA_CA_CERTS="$ca_bundle"
  export REQUESTS_CA_BUNDLE="$ca_bundle"
  export SSL_CERT_FILE="$ca_bundle"
  export CURL_CA_BUNDLE="$ca_bundle"
  export GIT_SSL_CAINFO="$ca_bundle"
  export PIP_CERT="$ca_bundle"
  export NPM_CONFIG_CAFILE="$ca_bundle"
  export YARN_CA_FILE="$ca_bundle"
  export PNPM_CONFIG_CAFILE="$ca_bundle"
  export AWS_CA_BUNDLE="$ca_bundle"
  export SSL_CERT_DIR="$(dirname "$ca_bundle")"
  export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH="$ca_bundle"
  export NODE_OPTIONS="${NODE_OPTIONS:-} --use-openssl-ca"
fi
setpriv \
  --reuid "$agent_uid" \
  --regid "$agent_gid" \
  --clear-groups \
  --no-new-privs \
  --bounding-set=-all \
  --inh-caps=-all \
  --ambient-caps=-all \
  -- bash "$@"
' bash "$WORKDIR_REAL" "$AGENT_UID" "$AGENT_GID" "$AGENT_HOME" "$PROXY_URL" "$CA_BUNDLE" "$SCRIPT_REAL" "${SCRIPT_ARGV[@]}"
AGENT_EXIT_CODE=$?
set -e

if [[ "$AGENT_EXIT_CODE" -ne 0 ]]; then
  note "script exited with code $AGENT_EXIT_CODE; continuing to verify receipts"
fi

if ! sudo test -d "$EVIDENCE_DIR"; then
  VERIFIER_VERDICT="error"
  printf 'no evidence directory found: %s\n' "$EVIDENCE_DIR" >"$VERIFIER_OUTPUT"
else
  sudo sh -c 'cat "$1"/evidence-proxy-*.jsonl > "$2" 2>/dev/null' sh "$EVIDENCE_DIR" "$EVIDENCE_EXPORT" || true
  sudo chown "$(id -u):$(id -g)" "$EVIDENCE_EXPORT" >/dev/null 2>&1 || true
  sudo chmod 0600 "$EVIDENCE_EXPORT" >/dev/null 2>&1 || true
  if [[ ! -s "$EVIDENCE_EXPORT" ]]; then
    VERIFIER_VERDICT="error"
    printf 'no_signed_receipts_emitted; signing_key_path not configured or pipelock not invoked\n' >"$VERIFIER_OUTPUT"
  else
    set +e
    # `verify-receipt --chain` expects the raw evidence directory. EVIDENCE_EXPORT
    # is the flattened copy carried in the Audit Packet.
    if [[ -n "$VERIFY_SIGNER_KEY" ]]; then
      sudo "$RUNTIME_BIN" verify-receipt --chain "$EVIDENCE_DIR" --key "$VERIFY_SIGNER_KEY" >"$VERIFIER_OUTPUT" 2>&1
      verify_status=$?
      if [[ "$verify_status" -eq 0 && "$TRUSTED_VERIFICATION" == "true" ]]; then
        VERIFIER_VERDICT="valid"
      elif [[ "$verify_status" -eq 0 ]]; then
        VERIFIER_VERDICT="self_consistent_only"
      else
        VERIFIER_VERDICT="invalid"
      fi
    else
      sudo "$RUNTIME_BIN" verify-receipt --chain "$EVIDENCE_DIR" >"$VERIFIER_OUTPUT" 2>&1
      verify_status=$?
      [[ "$verify_status" -eq 0 ]] && VERIFIER_VERDICT="self_consistent_only" || VERIFIER_VERDICT="invalid"
    fi
    if [[ "$VERIFIER_VERDICT" == "self_consistent_only" ]]; then
      printf '\nWARNING: trusted evidence requires signer-public-key pinning; ephemeral signer proves chain self-consistency only.\n' >>"$VERIFIER_OUTPUT"
    fi
    set -e
  fi
fi

if [[ -s "$EVIDENCE_EXPORT" ]]; then
  RECEIPT_COUNT="$(python3 - "$EVIDENCE_EXPORT" <<'PY'
import json
import sys

count = 0
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") == "action_receipt":
            count += 1
print(count)
PY
)"
fi

SCRIPT_ARGS_JSON="$(json_string_array "${SCRIPT_ARGV[@]}")"
POSTURE_GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
POSTURE_SCRIPT_ARGS_JSON="$SCRIPT_ARGS_JSON" \
POSTURE_GENERATED_AT="$POSTURE_GENERATED_AT" \
POSTURE_NETNS="$NETNS" \
POSTURE_AGENT_USER="$AGENT_USER" \
POSTURE_AGENT_UID="$AGENT_UID" \
POSTURE_HOST_IP="$HOST_IP" \
POSTURE_AGENT_IP="$AGENT_IP" \
POSTURE_PROXY_URL="$PROXY_URL" \
POSTURE_SCRIPT_BASENAME="$SCRIPT_BASENAME" \
POSTURE_SCRIPT_PATH="$SCRIPT_REAL" \
POSTURE_AGENT_EXIT_CODE="$AGENT_EXIT_CODE" \
POSTURE_VERIFIER_VERDICT="$VERIFIER_VERDICT" \
POSTURE_TRUSTED_VERIFICATION="$TRUSTED_VERIFICATION" \
POSTURE_RECEIPT_COUNT="$RECEIPT_COUNT" \
POSTURE_USER_CONFIG_PATH="$CONFIG" \
POSTURE_RUNTIME_CONFIG_PATH="$RUNTIME_CONFIG" \
python3 - "$POSTURE_PATH" <<'PY'
import json
import os
import sys

posture = {
    "generated_at": os.environ["POSTURE_GENERATED_AT"],
    "runner_os": os.environ.get("RUNNER_OS", "Linux"),
    "runner_arch": os.environ.get("RUNNER_ARCH", ""),
    "enforcement_mode": "linux_netns_iptables_setpriv",
    "network_namespace": os.environ["POSTURE_NETNS"],
    "agent_user": os.environ["POSTURE_AGENT_USER"],
    "agent_uid": int(os.environ["POSTURE_AGENT_UID"]),
    "host_ip": os.environ["POSTURE_HOST_IP"],
    "agent_ip": os.environ["POSTURE_AGENT_IP"],
    "proxy_url": os.environ["POSTURE_PROXY_URL"],
    "script_basename": os.environ["POSTURE_SCRIPT_BASENAME"],
    "script_path": os.environ["POSTURE_SCRIPT_PATH"],
    "script_args": json.loads(os.environ["POSTURE_SCRIPT_ARGS_JSON"]),
    "script_arg_count": len(json.loads(os.environ["POSTURE_SCRIPT_ARGS_JSON"])),
    "agent_exit_code": int(os.environ["POSTURE_AGENT_EXIT_CODE"]),
    "verifier_verdict": os.environ["POSTURE_VERIFIER_VERDICT"],
    "trusted_verification": os.environ["POSTURE_TRUSTED_VERIFICATION"] == "true",
    "receipt_count": int(os.environ["POSTURE_RECEIPT_COUNT"]),
    "user_config_path": os.environ["POSTURE_USER_CONFIG_PATH"],
    "runtime_config_path": os.environ["POSTURE_RUNTIME_CONFIG_PATH"],
    "websocket_frame_scanning": "explicit_ws_proxy_path_required",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(posture, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

"$ACTION_DIR/src/audit-packet.sh" \
  --receipt-chain "$EVIDENCE_EXPORT" \
  --verifier-output "$VERIFIER_OUTPUT" \
  --posture "$POSTURE_PATH" \
  --output-dir "$AUDIT_PACKET_DIR"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'audit_packet_path=%s\n' "$AUDIT_PACKET_DIR"
    printf 'receipt_count=%s\n' "$RECEIPT_COUNT"
    printf 'verifier_verdict=%s\n' "$VERIFIER_VERDICT"
  } >>"$GITHUB_OUTPUT"
fi

if [[ "$FAIL_ON_VERIFIER_ERROR" == "true" && "$VERIFIER_VERDICT" != "valid" ]]; then
  note "verifier verdict is $VERIFIER_VERDICT; failing because fail-on-verifier-error=true"
  exit 1
fi

exit "$AGENT_EXIT_CODE"
