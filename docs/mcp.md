# MCP

ryk supports stdio MCP proxying for servers launched through ryk.

## Inspect

```sh
./zig-out/bin/ryk mcp inspect --name demo --command python3 -- fixtures/mcp/fake_server.py
./zig-out/bin/ryk mcp inspect --name demo --policy policies/presets/mcp-dev.yaml --command python3 -- fixtures/mcp/fake_server.py
```

`inspect` initializes the server, sends `notifications/initialized`, calls `tools/list`, and reports risk findings. For each tool it also prints **inferred effect hits** from the built-in catalog (and user effect packs when present), e.g. `effects: comms.message [high catalog…]` or `effects: (none)`.

When `--policy <path>` is provided, it evaluates each listed tool through the loaded Core policy (including `effects:` when configured) and prints the policy decision and matched rule. Example line:

```text
  send_email    risk: high  default: ask  effects: comms.message [high catalog…]  policy: deny rule: effects.deny[comms.message]
```

Effect output never includes raw argument values. For interactive classification without starting a server, use `ryk tools classify <name>`.

## Proxy

```sh
python3 fixtures/mcp/fake_client.py | ./zig-out/bin/ryk mcp proxy --name demo --policy policies/presets/mcp-dev.yaml --command python3 -- fixtures/mcp/fake_server.py
```

The proxy reads client JSON-RPC from stdin and writes protocol responses to stdout. Server stderr and ryk human logs are logs, not protocol. Running `ryk mcp proxy` without a client input stream waits for JSON-RPC on stdin.

## Manifest Support

```sh
./zig-out/bin/ryk mcp manifest check examples/mcp/demo-manifest.yaml
./zig-out/bin/ryk mcp proxy --name demo --manifest examples/mcp/demo-manifest.yaml --command python3 -- fixtures/mcp/fake_server.py
```

Manifest defaults only apply when the launched command and manifest binding match.

## Mediated Methods

ryk policy-gates:

- `tools/call`
- `resources/read`
- `prompts/get`
- sampling requests, default-denied unless policy permits them

ryk also observes and audits `tools/list`, `resources/list`, and `prompts/list` metadata so later calls can be evaluated with the discovered risk context.

## Protocol Warning

Stdio MCP stdout must contain only newline-delimited JSON-RPC protocol messages. Human logs belong on stderr.

## Remote/HTTP Status

Remote HTTP MCP, OAuth, and hosted gateway support are not v1.1 defaults. Use stdio proxying unless docs for a future phase say otherwise.

## Limitations

ryk mediates MCP traffic that passes through `ryk mcp proxy`. It does not protect an MCP server launched directly by another client.
