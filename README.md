# pipelock-agent-egress-action

GitHub Action for running agent-driven CI jobs through [Pipelock](https://pipelab.org), with verifiable egress evidence.

**Status:** Initial implementation in progress. No stable release yet.

## Planned scope

This action will run configured CI commands through Pipelock-controlled egress on supported Linux runners.

The first release is expected to provide:

- Pipelock-mediated HTTP, HTTPS, WebSocket, and MCP egress
- signed receipts for allowed and blocked actions
- standalone receipt verification
- local audit packet output in Markdown and JSON
- documented enforcement boundaries and unsupported paths

## Documentation

Release documentation will be published with the first stable version. See [pipelab.org](https://pipelab.org) for Pipelock.

## License

Apache 2.0.
