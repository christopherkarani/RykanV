<p align="center">
  <img src="docs/images/ryk-banner.svg" alt="ryk، coding agents کے لیے guardrails" width="100%">
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.es.md">Español</a>
</p>

<p align="center">
  <a href="https://rykanv.com/">ویب سائٹ</a> ·
  <a href="https://discord.gg/uZn9MDUYKx">Discord</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

# ryk

coding agents کو واضح guardrails کے ساتھ چلائیں۔

ryk ایک local control layer ہے جو ان agents کے لیے ہے جنہیں engineers پہلے سے استعمال کرتے ہیں۔ `ryk <agent>` کے ذریعے Pi، Hermes، OpenCode، Codex یا Claude چلائیں۔ Agent اپنا عام terminal اور tools workflow برقرار رکھتا ہے، جبکہ ryk commands، files، environment اور secrets، network requests، MCP actions اور دوسرے effects کو policy کے مطابق evaluate کرتا ہے۔

ہر action کا فیصلہ `allow`، `ask`، `deny` یا `observe` ہوتا ہے۔ Sessions کا local audit record `ryk dashboard` یا `ryk replay` سے دیکھا جا سکتا ہے۔

## انسٹال کریں

```sh
curl -fsSL https://rykanv.com/install | sh
```

`ryk` کو اپنے `PATH` میں فعال کرنے کے بعد `ryk <agent>` کے ذریعے agent چلائیں۔

## Agent چلائیں

```sh
ryk pi
ryk hermes
ryk opencode
ryk codex
ryk claude
```

OpenClaw اور Grok کے لیے بھی launch paths موجود ہیں:

```sh
ryk openclaw
ryk grok
```

جب ضرورت ہو تو local posture دیکھیں:

```sh
ryk doctor
```

اہم integrations Pi، Hermes، OpenCode، Codex اور Claude کے لیے ہیں۔ Onboarding host discovery کے لیے Cursor کو بھی detect کرتا ہے۔

## Policy کیسے کام کرتی ہے

Local policy commands، files، environment، network اور MCP tools کو cover کرتی ہے۔ Mode فیصلہ کرنے کا طریقہ طے کرتا ہے:

| Mode | رویہ |
| --- | --- |
| `observe` | فیصلے record کرتا ہے، supported actions کو block نہیں کرتا |
| `ask` | interactive host پر risky actions کے لیے confirmation لیتا ہے |
| `strict` | unknown یا risky actions کو rule کی اجازت کے بغیر deny کرتا ہے |
| `ci` | prompts کے بغیر strict behavior چلاتا ہے |

Explicit deny کو ترجیح حاصل ہے۔ Safety packs commands اور effects کو classify کرتے ہیں، مگر deny rule کے اوپر permission نہیں دیتے۔

```sh
ryk policy check --preset ask
ryk packs
ryk test "git status"
ryk explain "rm -rf /"
```

مکمل format کے لیے [policy documentation](docs/policy.md) دیکھیں۔

## Safety packs

Shell engine میں 86 built-in packs شامل ہیں۔ Core packs default طور پر enabled ہیں، اور project کے مطابق اضافی packs فعال کیے جا سکتے ہیں:

```sh
ryk packs
ryk packs show core.git
ryk packs enable containers.docker database.postgresql
ryk packs disable containers.docker
```

Git workspace میں project selections `.ryk.toml` میں محفوظ ہوتی ہیں۔ Automation اور diagnostics کے لیے `ryk packs --json` استعمال کریں۔

## Architecture

Launch aliases، host adapters، shell evaluator اور policy engine ایک ہی local decision path استعمال کرتے ہیں۔

<p align="center">
  <img src="docs/images/ryk-architecture.svg" alt="ryk architecture" width="100%">
</p>

1. Launch boundary agent defaults کے ساتھ session شروع کرتی ہے۔
2. Host adapters shell اور tool events evaluator تک پہنچاتے ہیں۔
3. Evaluator policy rules، safety packs اور active mode کو ملاتا ہے۔
4. Action allow، ask، observe یا deny ہوتا ہے۔
5. Session evidence local dashboard اور replay کے لیے دستیاب رہتی ہے۔

## Dashboard

```sh
ryk dashboard
```

Browser میں [http://127.0.0.1:7742](http://127.0.0.1:7742) کھولیں۔ Automation کے لیے:

```sh
ryk dashboard --once
```

## Contributing

ryk Zig 0.16.0 سے build ہوتا ہے۔ Code change کے بعد focused checks چلائیں:

```sh
./scripts/zig version
./scripts/compile-fast.sh check
./scripts/zig build
./scripts/zig build test-shell-engine
```

Pull request سے پہلے [`CONTRIBUTING.md`](CONTRIBUTING.md) پڑھیں۔ Security issues کے لیے [`SECURITY.md`](SECURITY.md) دیکھیں۔

## Community

- [ویب سائٹ](https://rykanv.com/)
- [Discord](https://discord.gg/uZn9MDUYKx)
- [GitHub issues](https://github.com/christopherkarani/ryk/issues)

اگر ryk آپ کے agent workflow میں مفید ہے تو [repository کو star کریں](https://github.com/christopherkarani/ryk)، تاکہ دوسرے engineers بھی اسے تلاش کر سکیں۔

## License

Apache 2.0۔ [`LICENSE`](LICENSE) دیکھیں۔
