# MCP Example

Inspect the deterministic fake server:

```sh
../../zig-out/bin/ryk mcp inspect --name demo --command python3 -- ../../fixtures/mcp/fake_server.py
```

Proxy it with policy:

```sh
../../zig-out/bin/ryk mcp proxy --name demo --policy ../policies/mcp-stdio-demo.yaml --command python3 -- ../../fixtures/mcp/fake_server.py
```

The proxy is stdio-only. Server stdout must be protocol JSON-RPC; logs belong on stderr.
