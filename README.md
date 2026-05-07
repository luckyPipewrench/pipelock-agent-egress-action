# Pipelock Agent Egress Action

Verifiable Egress Control is the missing CI primitive for AI agents. Run the agent script, control what leaves the runner, verify the receipts, produce an Audit Packet a third party can inspect. Pipelock is staking that category as an open-source agent firewall with mediator-signed action receipts from outside the agent trust boundary.

## What this action is for

Run an agent script in CI. Control supported egress. Verify receipts. Produce an Audit Packet.

That is the whole promise.

Agents are starting to run inside pull requests, issue triage jobs, release workflows, docs bots, and security automation. Those jobs touch source code, secrets, package registries, cloud APIs, MCP tools, and the public internet. A normal CI log can tell you what the agent said it did. A Pipelock Audit Packet is meant to prove what the network boundary saw.

## What an Audit Packet is

An Audit Packet is the evidence bundle from one agent run. It includes the receipt chain, verifier output, policy hash, allowed and blocked totals, scanner config snapshot, posture metadata, and a Markdown summary humans can read. The receipts are signed by Pipelock at the network boundary, not by the agent process. The packet does not ask you to trust the agent's transcript. It gives you control-point evidence from outside the agent trust boundary.

Trusted evidence requires signer-key pinning. The verifier can run without a pinned key and confirm a receipt is internally consistent, but that proves self-consistency, not provenance. Pin the signer key from a known source (your Pipelock deployment or a published trust anchor) when you need the evidence to count.

## V0 enforcement boundary

The action enforces egress for **the script executed inside the Pipelock action boundary**. It does not contain sibling steps in your workflow, later workflow steps, or other actions in the caller workflow. It is not a job-wide network firewall.

**Enforced for the action script on supported Linux runners:**

- HTTP and HTTPS traffic routed through Pipelock at the network egress level
- WebSocket destinations contained at the network egress level
- Frame-level WebSocket scanning when the script explicitly uses Pipelock's `/ws?url=...` proxy path
- Direct network, DNS, and raw TCP from the action script blocked inside the namespace
- Non-root execution as `pipelock-agent` with sudo denied and capabilities dropped
- Signed receipt verification and local Audit Packet generation

**Fail-closed in v0 unless explicitly enabled by a later container enforcement mode:**

- Nested Docker workloads launched from the action script
- GitHub service containers
- Sibling container actions in the caller workflow
- MCP transports

**Out of scope for v0:**

- macOS and Windows runners
- SSH egress (planned for a later release)
- Browsers without explicit proxy configuration
- Steps in the caller workflow that run outside the Pipelock action boundary
- MCP stdio and MCP HTTP/SSE. MCP stdio does not traverse a network proxy; MCP HTTP/SSE needs explicit Pipelock MCP listener wiring and is planned for v0.2.

If a path is not under the Pipelock control point, this action says so. No magic. No fake containment story.

## Action interface

```yaml
- uses: luckyPipewrench/pipelock-agent-egress-action@v0
  with:
    script-path: "./ci/agent-review.sh"
    pipelock-bin: "/usr/local/bin/pipelock"
    config: ".pipelock/ci.yaml"
    agent-identity: "ci-agent"
    signer-private-key-path: "${{ runner.temp }}/pipelock-signing/id_ed25519"
    signer-public-key: "${{ secrets.PIPELOCK_RECEIPT_PUBLIC_KEY }}"
    audit-packet-dir: "pipelock-audit-packet"
```

Optional `script-args` is newline-delimited. Each line is passed as one argv element; it is not evaluated as shell.

This pre-release action does not download `latest` Pipelock binaries. Install a pinned Pipelock binary in an earlier workflow step and pass `pipelock-bin`, or make `pipelock` available on `PATH`.

Trusted receipt verification requires both `signer-private-key-path` and `signer-public-key`. Omit both inputs to use an ephemeral signer; the verifier verdict will be `self_consistent_only`, not trusted provenance.

Current implementation note: the action records the `config` path in the Audit Packet posture, but it materializes an action-owned runtime config to force the listener, proxy, and receipt-signing settings required for this boundary. Safe caller-policy config merging is the next implementation step.

Self-hosted runner note: the action creates or reuses a local `pipelock-agent` account and writes a short-lived sudoers deny file during the run. Hosted runners are discarded after the job; self-hosted operators should reserve that account for this action.

Outputs:

- `audit-packet-path`
- `receipt-count`
- `verifier-verdict`

Required workflow permission:

```yaml
permissions:
  contents: read
```

## Development status

This repo is pre-release. The first useful milestone is not a polished Marketplace listing. It is a working Linux runner path that launches an agent script, enforces supported egress through Pipelock, verifies the generated receipt chain, and writes a local Audit Packet.

Track development in this repo and in Pipelock:

- https://github.com/luckyPipewrench/pipelock-agent-egress-action
- https://github.com/luckyPipewrench/pipelock
- https://pipelab.org/learn/action-receipt-spec/

## License

Apache 2.0.
