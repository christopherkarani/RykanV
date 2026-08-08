<p align="center">
  <img src="docs/images/ryk-banner.svg" alt="ryk，为编码代理提供护栏" width="100%">
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.ur-pk.md">اردو</a>
</p>

<p align="center">
  <a href="https://rykanv.com/">网站</a> ·
  <a href="https://discord.gg/uZn9MDUYKx">Discord</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a>
</p>

# ryk

为编码代理提供清晰的安全护栏。

ryk 是一个运行在本机的控制层，面向工程师已经在使用的编码代理。通过 `ryk <agent>` 启动 Pi、Hermes、OpenCode、Codex 或 Claude。代理仍然使用原本的终端和工具流程，ryk 会根据策略评估命令、文件、环境和密钥、网络请求、MCP 操作以及其他效果。

每个动作都会得到 `allow`、`ask`、`deny` 或 `observe` 决策。会话会留下本地审计记录，可以使用 `ryk dashboard` 或 `ryk replay` 查看。

## 安装

```sh
curl -fsSL https://rykanv.com/install | sh
```

让 `ryk` 出现在 `PATH` 后，使用 `ryk <agent>` 启动代理。

## 启动代理

```sh
ryk pi
ryk hermes
ryk opencode
ryk codex
ryk claude
```

OpenClaw 和 Grok 也有对应的入口：

```sh
ryk openclaw
ryk grok
```

需要时检查本机状态：

```sh
ryk doctor
```

主要集成包括 Pi、Hermes、OpenCode、Codex 和 Claude。Onboarding 也会检测 Cursor，用于发现主机环境。

## 策略如何工作

本地策略覆盖命令、文件、环境、网络和 MCP 工具。模式决定策略的响应方式：

| 模式 | 行为 |
| --- | --- |
| `observe` | 记录决策，但不阻止受支持的动作 |
| `ask` | 在交互式主机中询问风险动作 |
| `strict` | 除非有规则允许，否则拒绝未知或风险动作 |
| `ci` | 不进行交互询问，执行严格模式 |

显式拒绝优先级最高。安全 pack 用于分类命令和效果，不会越过拒绝规则授予权限。

```sh
ryk policy check --preset ask
ryk packs
ryk test "git status"
ryk explain "rm -rf /"
```

完整格式请阅读[策略文档](docs/policy.md)。

## 安全 pack

shell engine 内置 86 个 pack。核心 pack 默认启用，也可以按项目添加额外 pack：

```sh
ryk packs
ryk packs show core.git
ryk packs enable containers.docker database.postgresql
ryk packs disable containers.docker
```

在 Git workspace 中，项目选择会写入 `.ryk.toml`。脚本和诊断可以使用 `ryk packs --json`。

## 架构

启动别名、主机适配器、shell evaluator 和策略引擎共用一条本地决策路径。

<p align="center">
  <img src="docs/images/ryk-architecture.svg" alt="ryk 架构图" width="100%">
</p>

1. 启动边界创建会话并应用代理默认设置。
2. 主机适配器把 shell 和工具事件发送到 evaluator。
3. evaluator 组合策略规则、安全 pack 和当前模式。
4. 动作被允许、询问、观察或拒绝。
5. 会话证据供本地 dashboard 和 replay 使用。

## Dashboard

```sh
ryk dashboard
```

在浏览器打开 [http://127.0.0.1:7742](http://127.0.0.1:7742)。自动化场景可以使用：

```sh
ryk dashboard --once
```

## 参与贡献

ryk 使用 Zig 0.16.0。修改代码后运行这些检查：

```sh
./scripts/zig version
./scripts/compile-fast.sh check
./scripts/zig build
./scripts/zig build test-shell-engine
```

提交 pull request 前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。安全问题请按照 [`SECURITY.md`](SECURITY.md) 报告。

## 社区

- [网站](https://rykanv.com/)
- [Discord](https://discord.gg/uZn9MDUYKx)
- [GitHub Issues](https://github.com/christopherkarani/ryk/issues)

如果 ryk 对你的代理工作有帮助，请给[仓库加星](https://github.com/christopherkarani/ryk)，让更多工程师找到它。

## 许可证

Apache 2.0。见 [`LICENSE`](LICENSE)。
