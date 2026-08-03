import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
    if (!line.trim()) continue;
    let msg;
    try {
        msg = JSON.parse(line);
    } catch {
        continue;
    }
    const { method, id } = msg;
    if (method === "initialize") {
        process.stdout.write(
            JSON.stringify({
                jsonrpc: "2.0",
                id,
                result: {
                    protocolVersion: msg.params?.protocolVersion ?? "2025-03-26",
                    capabilities: { tools: { listChanged: false } },
                    serverInfo: { name: "simple-mcp", version: "0.0.1" },
                },
            }) + "\n",
        );
    } else if (method === "tools/list") {
        process.stdout.write(
            JSON.stringify({
                jsonrpc: "2.0",
                id,
                result: {
                    tools: [
                        {
                            name: "ping",
                            description: "ping",
                            inputSchema: { type: "object", properties: {} },
                        },
                    ],
                },
            }) + "\n",
        );
    }
}
