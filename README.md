<div align="center">

<img src="assets/logo.webp" alt="BashClaw" width="600" />

**Bash is all you need.**

Pure-shell AI agent runtime. No Node.js, no Python, no compiled binaries.

<p>
  <img src="https://img.shields.io/badge/bash-3.2%2B_(2006)-4EAA25?logo=gnubash&logoColor=white" alt="Bash 3.2+" />
  <img src="https://img.shields.io/badge/deps-jq%20%2B%20curl-blue" alt="Dependencies" />
  <img src="https://img.shields.io/badge/tests-all%20pass-brightgreen" alt="Tests" />
  <img src="https://img.shields.io/badge/RAM-%3C%2010MB-purple" alt="Memory" />
  <a href="https://opensource.org/licenses/MIT">
    <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT" />
  </a>
</p>

<p>
  <a href="#install">Install</a> &middot;
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#web-dashboard">Dashboard</a> &middot;
  <a href="#providers">Providers</a> &middot;
  <a href="#engines">Engines</a> &middot;
  <a href="#channels">Channels</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="README_CN.md">&#x4E2D;&#x6587;</a>
</p>
</div>

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/shareAI-lab/bashclaw/main/install.sh | bash
```

Or clone directly:

```sh
git clone https://github.com/shareAI-lab/bashclaw.git
cd bashclaw && ./bashclaw doctor
```

## Quick Start

### 1. Start the Gateway

```sh
bashclaw gateway
```

Open `http://localhost:18789` in your browser. If no API key is configured, a first-run setup overlay guides you through it.

### 2. Choose an Engine

<table>
<tr><th>Claude Code CLI (Recommended)</th><th>Builtin (Direct API)</th></tr>
<tr>
<td>

Reuses your Claude subscription -- no API keys, no per-token cost.

```sh
bashclaw config set \
  '.agents.defaults.engine' '"claude"'
```

Requires: [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated.

</td>
<td>

Calls LLM APIs directly via curl. Supports 18 providers.

```sh
export ANTHROPIC_API_KEY="sk-ant-..."
# or set via web dashboard
```

</td>
</tr>
</table>

### 3. Connect Channels (Optional)

Add always-on messaging through Telegram, Discord, Slack, or Feishu. Channels auto-start with the gateway:

```sh
# Example: Telegram
bashclaw config set '.channels.telegram.botToken' '"BOT_TOKEN"'
bashclaw config set '.channels.telegram.enabled' 'true'
bashclaw gateway   # web + Telegram both active
```

See [Channels](#channels) for all platforms.

### 4. CLI Mode (Power Users)

For scripting, automation, or SSH sessions:

```sh
bashclaw agent -m "What is the mass of the sun?"   # one-shot
bashclaw agent -i                                    # interactive REPL
```

## Why BashClaw

```
+---------------------+------------------+------------------+
|                     |  OpenClaw (TS)   | BashClaw (Bash)  |
+---------------------+------------------+------------------+
| Runtime             | Node.js 22+      | Bash 3.2+        |
| Dependencies        | 52 npm packages  | jq + curl        |
| Memory              | 200-400 MB       | < 10 MB          |
| Cold start          | 2-5 seconds      | < 100 ms         |
| Install             | npm / Docker     | curl | bash      |
| macOS out-of-box    | No (needs Node)  | Yes              |
| Android Termux      | Complex          | pkg install jq   |
| Hot self-modify     | No (needs build) | Yes              |
| Tests               | Vitest           | All pass         |
+---------------------+------------------+------------------+
```

BashClaw is shell script -- the agent can **read, modify, and reload its own source code** at runtime. No compilation, no restart, instant self-bootstrapping.

### Bash 3.2: Universal Runtime

Bash 3.2 was released in **October 2006** as the last GPLv2-licensed version. Apple froze it on every Mac starting with macOS Leopard (2007) and has shipped 3.2 on every Mac since, because later versions (4.0+) switched to GPLv3 which conflicts with Apple's licensing policy.

BashClaw targets Bash 3.2 deliberately: no `declare -A`, no `mapfile`, no `|&`. This means it runs on:

- **macOS** -- every version since 2007, zero additional installs
- **Linux** -- any distribution (Ubuntu, Debian, Fedora, Alpine, Arch...)
- **Android Termux** -- no root required
- **Windows** -- WSL2, Git Bash, Cygwin
- **Embedded** -- Alpine containers, Raspberry Pi, CI runners, NAS boxes

## Features

- **Web dashboard** -- Built-in browser UI for chat, config, and monitoring. First-run setup wizard. No external tools.
- **Multi-channel** -- Telegram, Discord, Slack, Feishu/Lark. Each channel is one shell script. Auto-starts with gateway.
- **Dual engine** -- Claude Code CLI (reuses subscription) or builtin (direct API via curl). Per-agent configurable.
- **Multi-provider** -- 18 providers: Claude, GPT, Gemini, DeepSeek, Qwen, Zhipu, Moonshot, MiniMax, Groq, xAI, Mistral, Ollama, vLLM, and more.
- **Pure shell** -- Zero dependencies beyond bash 3.2, curl, jq. Already on your machine.
- **14 built-in tools** -- Web fetch, search, shell exec, memory, cron, file I/O, inter-agent messaging.
- **Plugin system** -- 4 discovery paths. Register tools, hooks, commands, providers.
- **8-layer security** -- SSRF protection, command filters, pairing codes, rate limiting, RBAC, audit.
- **Session management** -- 5 scope modes, JSONL persistence, idle reset, context compaction.
- **Cron scheduler** -- `at` / `every` / `cron` expressions, backoff, stuck job detection.
- **14 hook events** -- Pre/post message, tool, compaction, session lifecycle. Modifying + sync strategies.
- **Hot config reload** -- `kill -USR1` the gateway to reload without restart.
- **Daemon support** -- systemd, launchd, Termux boot, crontab fallback.
- **Tested** -- Unit, compatibility, integration. `bash tests/run_all.sh`.

## Web Dashboard

Start the gateway and open `http://localhost:18789`:

```sh
bashclaw gateway
```

```
+------------------------------------------------------------------+
|  BashClaw Dashboard    [Chat] [Status] [Agents] [Sessions] [Config] [Logs]|
+------------------------------------------------------------------+
|                                                                   |
|  You: What's the weather in Tokyo?                                |
|                                                                   |
|  Agent: Let me check that for you...                              |
|  [tool: web_search] ...                                           |
|  Currently 12C and partly cloudy in Tokyo.                        |
|                                                                   |
|  [____________________________________] [Send]                    |
+------------------------------------------------------------------+
```

**Chat** -- Talk to the agent from the browser. Markdown rendering, syntax highlight.
**Status** -- Gateway state, active sessions, provider info, engine detection.
**Agents** -- List and manage configured agents.
**Sessions** -- Browse all sessions with message counts.
**Config** -- API keys, model selection, channel status. Keys stored server-side only.
**Logs** -- Live log viewer with level filtering.
**First-run** -- If no API key is set, shows a setup overlay on first visit.

### Web + Channels + CLI

All three modes share the same config, sessions, and state. Changes in one take effect in the others immediately.

| Mode | Best For | Command |
|------|----------|---------|
| Web | First-time setup, visual config, casual chat | `bashclaw gateway` then open browser |
| Channels | Always-on team bot, mobile access | `bashclaw gateway` with channels enabled |
| CLI | Automation, scripting, SSH, CI/CD | `bashclaw agent -m "..."` or `bashclaw agent -i` |

### REST API

```
GET  /api/status        System status
GET  /api/config        Read config (secrets masked)
PUT  /api/config        Update config (partial merge)
GET  /api/models        List models, aliases, providers
GET  /api/sessions      List active sessions
POST /api/sessions/clear  Clear a session
POST /api/chat          Send message to agent
GET  /api/channels      List channels
GET  /api/env           Check which API keys are set
PUT  /api/env           Save API keys
```

<details>
<summary><strong>Platform access notes</strong></summary>

| Platform | Access | Notes |
|----------|--------|-------|
| macOS / Linux | `localhost:18789` | Full browser experience |
| Android Termux | `localhost:18789` in phone browser | Responsive touch UI |
| Cloud server | `ssh -L 18789:localhost:18789 server` | Port forward |
| Windows WSL2 | `localhost:18789` in Windows browser | Auto port forward |
| Headless / CI | CLI only | `bashclaw agent -m "..."` |

</details>

## Providers

The builtin engine supports 18 providers with data-driven routing. All configuration is in `lib/models.json` -- adding a provider is a JSON entry, no code changes.

### Pre-configured Providers and Models

BashClaw ships with 25+ pre-configured models. Set the API key and go:

| Provider | API Key Env | Pre-configured Models | API Format |
|----------|------------|----------------------|------------|
| **Anthropic** | `ANTHROPIC_API_KEY` | claude-opus-4-6, claude-sonnet-4, claude-haiku-3 | Anthropic |
| **OpenAI** | `OPENAI_API_KEY` | gpt-4o, gpt-4o-mini, o1, o3-mini | OpenAI |
| **Google** | `GOOGLE_API_KEY` | gemini-2.0-flash, gemini-2.0-flash-lite, gemini-1.5-pro | Google |
| **DeepSeek** | `DEEPSEEK_API_KEY` | deepseek-chat, deepseek-reasoner | OpenAI |
| **Qwen** | `QWEN_API_KEY` | qwen-max, qwen-plus, qwq-plus | OpenAI |
| **Zhipu** | `ZHIPU_API_KEY` | glm-5, glm-4-flash | OpenAI |
| **Moonshot** | `MOONSHOT_API_KEY` | kimi-k2.5 | OpenAI |
| **MiniMax** | `MINIMAX_API_KEY` | MiniMax-M2.5, MiniMax-M2.1 | OpenAI |
| **Xiaomi** | `XIAOMI_API_KEY` | mimo-v2-flash | Anthropic |
| **Baidu Qianfan** | `QIANFAN_API_KEY` | deepseek-v3.2, ernie-5.0-thinking-preview | OpenAI |
| **NVIDIA** | `NVIDIA_API_KEY` | llama-3.1-nemotron-70b | OpenAI |
| **Groq** | `GROQ_API_KEY` | llama-3.3-70b-versatile | OpenAI |
| **xAI** | `XAI_API_KEY` | grok-3 | OpenAI |
| **Mistral** | `MISTRAL_API_KEY` | mistral-large-latest | OpenAI |
| **OpenRouter** | `OPENROUTER_API_KEY` | any model via OpenRouter | OpenAI |
| **Together** | `TOGETHER_API_KEY` | any model via Together | OpenAI |
| **Ollama** | -- | any local model | OpenAI |
| **vLLM** | -- | any local model | OpenAI |

```sh
# Anthropic (default)
export ANTHROPIC_API_KEY="sk-ant-..."
bashclaw agent -m "hello"

# OpenAI
export OPENAI_API_KEY="sk-..."
MODEL_ID=gpt-4o bashclaw agent -m "hello"

# Google Gemini
export GOOGLE_API_KEY="..."
MODEL_ID=gemini-2.0-flash bashclaw agent -m "hello"

# OpenRouter (any model)
export OPENROUTER_API_KEY="sk-or-..."
MODEL_ID=anthropic/claude-sonnet-4 bashclaw agent -m "hello"
```

<details>
<summary><strong>Chinese providers</strong></summary>

All Chinese providers use OpenAI-compatible APIs:

```sh
# DeepSeek
export DEEPSEEK_API_KEY="sk-..."
MODEL_ID=deepseek-chat bashclaw agent -m "hello"

# Qwen (Alibaba DashScope)
export QWEN_API_KEY="sk-..."
MODEL_ID=qwen-max bashclaw agent -m "hello"

# Zhipu GLM
export ZHIPU_API_KEY="..."
MODEL_ID=glm-5 bashclaw agent -m "hello"

# Moonshot Kimi
export MOONSHOT_API_KEY="sk-..."
MODEL_ID=kimi-k2.5 bashclaw agent -m "hello"

# MiniMax
export MINIMAX_API_KEY="..."
MODEL_ID=MiniMax-M2.5 bashclaw agent -m "hello"

# Baidu Qianfan
export QIANFAN_API_KEY="..."
MODEL_ID=ernie-5.0-thinking-preview bashclaw agent -m "hello"
```

</details>

<details>
<summary><strong>Model aliases</strong></summary>

```sh
MODEL_ID=smart      # -> claude-opus-4-6
MODEL_ID=balanced   # -> claude-sonnet-4
MODEL_ID=fast       # -> gemini-2.0-flash
MODEL_ID=cheap      # -> gpt-4o-mini
MODEL_ID=opus       # -> claude-opus-4-6
MODEL_ID=sonnet     # -> claude-sonnet-4
MODEL_ID=haiku      # -> claude-haiku-3
MODEL_ID=gpt        # -> gpt-4o
MODEL_ID=gemini     # -> gemini-2.0-flash
MODEL_ID=deepseek   # -> deepseek-chat
MODEL_ID=qwen       # -> qwen-max
MODEL_ID=glm        # -> glm-5
MODEL_ID=kimi       # -> kimi-k2.5
MODEL_ID=minimax    # -> MiniMax-M2.5
MODEL_ID=grok       # -> grok-3
MODEL_ID=mistral    # -> mistral-large-latest
```

</details>

### Custom Base URL

Every provider supports base URL override via environment variable. This is useful for proxies, private deployments, or self-hosted models:

```sh
# Anthropic-format endpoint (e.g., proxy or compatible service)
export ANTHROPIC_API_KEY="your-key"
export ANTHROPIC_BASE_URL="https://your-proxy.example.com/v1"
bashclaw agent -m "hello"

# OpenAI-format endpoint (e.g., Azure OpenAI, LiteLLM, or any compatible service)
export OPENAI_API_KEY="your-key"
export OPENAI_BASE_URL="https://your-endpoint.example.com/v1"
MODEL_ID=gpt-4o bashclaw agent -m "hello"

# Google-format endpoint
export GOOGLE_API_KEY="your-key"
export GOOGLE_AI_BASE_URL="https://your-proxy.example.com/v1beta"
MODEL_ID=gemini-2.0-flash bashclaw agent -m "hello"

# Local Ollama (no API key needed)
export OLLAMA_BASE_URL="http://localhost:11434/v1"
MODEL_ID=llama3.3 bashclaw agent -m "hello"

# Local vLLM server
export VLLM_BASE_URL="http://127.0.0.1:8000/v1"
MODEL_ID=your-model bashclaw agent -m "hello"

# OpenRouter (access any model through a single API)
export OPENROUTER_API_KEY="sk-or-..."
MODEL_ID=meta-llama/llama-3.3-70b-instruct bashclaw agent -m "hello"
```

If you provide a base URL without the version path (e.g., `http://localhost:8000`), BashClaw auto-appends `/v1` (or `/v1beta` for Google).

### Three API Formats

The builtin engine supports three API formats. Most providers use OpenAI-compatible format:

| Format | Endpoint | Providers |
|--------|----------|-----------|
| **Anthropic** | `POST /v1/messages` | Anthropic, Xiaomi |
| **OpenAI** | `POST /v1/chat/completions` | OpenAI, DeepSeek, Qwen, Zhipu, Moonshot, MiniMax, Groq, xAI, Mistral, OpenRouter, Ollama, vLLM, Qianfan, NVIDIA, Together |
| **Google** | `POST /v1beta/models/{model}:generateContent` | Google |

Any service that implements one of these formats works out of the box.

## Engines

BashClaw has a pluggable engine layer that determines how agent tasks are executed. Each agent can use a different engine.

### Claude Engine (Recommended)

The **claude** engine delegates execution to [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code). It reuses your existing Claude subscription -- no API keys needed, no per-token cost.

```sh
# Set claude as the default engine
bashclaw config set '.agents.defaults.engine' '"claude"'

# Use it
bashclaw agent -m "Refactor this function for readability"
```

**How it works:**
- Invokes `claude -p --output-format json` as a subprocess
- Claude Code handles the tool loop with its native tools (Read, Write, Bash, Glob, Grep, etc.)
- BashClaw-specific tools (memory, cron, spawn, agent_message) are bridged via `bashclaw tool <name>` CLI calls
- Session state tracked in both BashClaw JSONL and Claude Code's native session
- Hooks bridged via `--settings` JSON injection

**Requirements:** `claude` CLI installed and authenticated (`claude login`).

<details>
<summary><strong>Claude engine configuration</strong></summary>

```json
{
  "agents": {
    "defaults": {
      "engine": "claude",
      "maxTurns": 50
    },
    "list": [
      {
        "id": "coder",
        "engine": "claude",
        "engineModel": "opus",
        "maxTurns": 30
      }
    ]
  }
}
```

| Config Field | Description |
|-------------|-------------|
| `engine` | `"claude"` to use Claude Code CLI |
| `engineModel` | Override model (e.g. `"opus"`, `"sonnet"`, `"haiku"`). If empty, uses your subscription's default. |
| `maxTurns` | Max agentic turns per invocation |

| Environment Variable | Default | Purpose |
|---------------------|---------|---------|
| `ENGINE_CLAUDE_TIMEOUT` | `300` | Timeout (seconds) for Claude CLI execution |
| `ENGINE_CLAUDE_MODEL` | -- | Override model (alternative to `engineModel` in config) |

</details>

### Builtin Engine

The **builtin** engine calls LLM APIs directly via curl. It supports 18 providers and 25+ pre-configured models, and works with any OpenAI-compatible endpoint.

```sh
# Builtin is the default engine (no config change needed)
export ANTHROPIC_API_KEY="sk-ant-..."
bashclaw agent -m "hello"
```

**How it works:**
- Calls provider APIs directly (Anthropic, OpenAI, Google, and 15 more)
- Runs BashClaw's own tool loop (max iterations configurable via `maxTurns`)
- Handles context overflow with automatic compaction, model fallback, and session reset
- Three API formats: Anthropic (`/v1/messages`), OpenAI-compatible (`/v1/chat/completions`), Google (`/v1beta/.../generateContent`)

### Auto Engine

Set `engine` to `"auto"` to let BashClaw detect: uses `claude` if the CLI is installed, otherwise falls back to `builtin`.

```sh
bashclaw config set '.agents.defaults.engine' '"auto"'
```

### Tool Mapping (Claude Engine)

When using the Claude engine, BashClaw tools are mapped to Claude Code's native equivalents where possible. Tools without a native counterpart are bridged through the CLI:

| BashClaw Tool | Claude Code Tool | Method |
|---------------|-----------------|--------|
| `web_fetch` | WebFetch | native |
| `web_search` | WebSearch | native |
| `shell` | Bash | native |
| `read_file` | Read | native |
| `write_file` | Write | native |
| `list_files` | Glob | native |
| `file_search` | Grep | native |
| `memory` | -- | `bashclaw tool memory` |
| `cron` | -- | `bashclaw tool cron` |
| `agent_message` | -- | `bashclaw tool agent_message` |
| `spawn` | -- | `bashclaw tool spawn` |

### Mixed Engine Configuration

Different agents can use different engines:

```json
{
  "agents": {
    "defaults": { "engine": "claude" },
    "list": [
      {
        "id": "coder",
        "engine": "claude",
        "engineModel": "opus"
      },
      {
        "id": "chat",
        "engine": "builtin",
        "model": "gpt-4o"
      },
      {
        "id": "local",
        "engine": "builtin",
        "model": "llama-3.3-70b-versatile"
      }
    ]
  }
}
```

**Both engines share the same:**
- Lifecycle hooks (before_agent_start, pre_message, post_message, agent_end)
- Session persistence (JSONL)
- Workspace loading (SOUL.md, MEMORY.md, BOOT.md, IDENTITY.md)
- Security layer (rate limiting, tool policies, RBAC)
- Config format (`maxTurns`, tool allow/deny lists, tool profiles)

## Channels

Each channel is a standalone shell script under `channels/`.

| Channel | Status | Mode |
|---------|--------|------|
| Telegram | Stable | Bot API long-poll |
| Discord | Stable | REST API + typing |
| Slack | Stable | Socket Mode / Webhook |
| Feishu / Lark | Stable | Webhook + App Bot |

<details>
<summary><strong>Channel setup</strong></summary>

**Telegram**
```sh
bashclaw config set '.channels.telegram.botToken' '"BOT_TOKEN"'
bashclaw config set '.channels.telegram.enabled' 'true'
bashclaw gateway
```

**Discord**
```sh
bashclaw config set '.channels.discord.botToken' '"BOT_TOKEN"'
bashclaw config set '.channels.discord.enabled' 'true'
bashclaw gateway
```

**Slack**
```sh
bashclaw config set '.channels.slack.botToken' '"xoxb-YOUR-TOKEN"'
bashclaw config set '.channels.slack.enabled' 'true'
bashclaw gateway
```

**Feishu / Lark** (two modes)
```sh
# Webhook (outbound only)
bashclaw config set '.channels.feishu.webhookUrl' '"https://open.feishu.cn/..."'

# App Bot (full bidirectional)
bashclaw config set '.channels.feishu.appId' '"cli_xxx"'
bashclaw config set '.channels.feishu.appSecret' '"secret"'
bashclaw config set '.channels.feishu.monitorChats' '["oc_xxx"]'

# International (Lark)
bashclaw config set '.channels.feishu.region' '"intl"'
bashclaw gateway
```

</details>

## Architecture

```
                       +------------------+
                       |   CLI / Browser  |
                       +--------+---------+
                                |
                 +--------------+--------------+
                 |       bashclaw (main)       |
                 |     CLI router + loader     |
                 +--------------+--------------+
                                |
       +------------------------+------------------------+
       |                        |                        |
+------+------+        +-------+-------+        +-------+-------+
|   Channels  |        |  Core Engine  |        |  Background   |
+------+------+        +-------+-------+        +-------+-------+
| telegram.sh |        | engine.sh     |        | heartbeat.sh  |
| discord.sh  |        |   +- agent.sh |        | cron.sh       |
| slack.sh    |        |   +- claude.sh|        | events.sh     |
| feishu.sh   |        | routing.sh    |        | process.sh    |
| (plugins)   |        | session.sh    |        | daemon.sh     |
+-------------+        | tools.sh (14) |        +---------------+
                       | memory.sh     |
                       | config.sh     |
                       +---------------+
                                |
       +------------------------+------------------------+
       |                        |                        |
+------+------+        +-------+-------+        +-------+-------+
|  Web / API  |        |   Security    |        |  Extensions   |
+------+------+        +-------+-------+        +-------+-------+
| http_handler |       | SSRF filter   |        | plugin.sh     |
| ui/index.html|       | rate limiting |        | skills.sh     |
| OpenAI API   |       | pairing codes |        | hooks.sh (14) |
| REST API (9) |       | tool policies |        | autoreply.sh  |
+--------------+       | RBAC + audit  |        | boot.sh       |
                       +---------------+        | dedup.sh      |
                                                +---------------+
```

### Message Flow

```
User Message --> Dedup --> Auto-Reply Check --> Hook: pre_message
  |
  v
Routing (7-level: peer > parent > guild > channel > team > account > default)
  |
  v
Security Gate (rate limit -> pairing -> tool policy -> RBAC)
  |
  v
Process Queue (main: 4, cron: 1, subagent: 8 concurrent lanes)
  |
  v
Engine Dispatch (builtin: direct API | claude: Claude Code CLI)
  |
  v
Agent Runtime
  1. Resolve model + provider (data-driven, models.json)
  2. Load workspace (SOUL.md, MEMORY.md, BOOT.md, IDENTITY.md)
  3. Build system prompt (10 segments)
  4. API call (Anthropic / OpenAI / Google / ...)
  5. Tool loop (max 10 iterations)
  6. Overflow: reduce history -> compact -> model fallback -> reset
  |
  v
Session Persist (JSONL) --> Hook: post_message --> Delivery
```

### Directory Structure

```
bashclaw/
  bashclaw              # main entry (CLI router)
  install.sh            # standalone installer
  lib/
    agent.sh            # agent runtime, model/provider dispatch
    engine.sh           # engine abstraction (builtin / claude / auto)
    engine_claude.sh    # Claude Code CLI engine integration
    config.sh           # JSON config (jq-based)
    session.sh          # JSONL session persistence
    routing.sh          # 7-level message routing
    tools.sh            # 14 built-in tools + dispatch
    memory.sh           # KV store + BM25 search
    security.sh         # 8-layer security model
    process.sh          # dual-layer queue + typed lanes
    cron.sh             # scheduler (at/every/cron)
    hooks.sh            # 14 event types, 3 strategies
    plugin.sh           # 4-source plugin discovery
    skills.sh           # skill loader
    heartbeat.sh        # autonomous heartbeat
    events.sh           # FIFO event queue
    boot.sh             # BOOT.md parser
    autoreply.sh        # pattern-based auto-reply
    dedup.sh            # TTL dedup cache
    log.sh              # structured logging
    utils.sh            # UUID, hash, retry, timestamp
    cmd_*.sh            # CLI subcommand handlers
  channels/
    telegram.sh         # Telegram Bot API
    discord.sh          # Discord REST + typing
    slack.sh            # Slack Socket Mode + webhook
    feishu.sh           # Feishu/Lark webhook + App Bot
  gateway/
    http_handler.sh     # HTTP request handler + REST API
  ui/
    index.html          # single-file SPA (CSS+JS inline, 6 tabs)
  tools/                # external tool scripts
  tests/
    framework.sh        # test runner
    test_*.sh           # test suites
```

## Commands

| Command | Subcommands | Description |
|---------|-------------|-------------|
| `agent` | `-m MSG`, `-i`, `-a AGENT` | Chat with agent |
| `gateway` | `-p PORT`, `-d`, `--stop` | HTTP gateway + channels |
| `daemon` | `install`, `uninstall`, `status`, `logs`, `restart`, `stop` | System service |
| `config` | `show`, `get`, `set`, `init`, `validate`, `edit`, `path` | Configuration |
| `session` | `list`, `show`, `clear`, `delete`, `export` | Sessions |
| `memory` | `list`, `get`, `set`, `delete`, `search`, `export`, `import`, `compact`, `stats` | KV store |
| `cron` | `list`, `add`, `remove`, `enable`, `disable`, `run`, `history` | Scheduler |
| `hooks` | `list`, `add`, `remove`, `enable`, `disable`, `test` | Event hooks |
| `boot` | `run`, `find`, `status`, `reset` | Boot sequence |
| `security` | `pair-generate`, `pair-verify`, `tool-check`, `audit` | Security |
| `onboard` | | Setup wizard |
| `doctor` | | Diagnostics |
| `status` | | System status |
| `update` | | Update to latest |
| `completion` | `bash`, `zsh` | Shell completions |

## Built-in Tools

| Tool | Description | Elevation |
|------|-------------|-----------|
| `web_fetch` | HTTP GET/POST with SSRF protection | none |
| `web_search` | Web search (Brave / Perplexity) | none |
| `shell` | Execute commands (security filtered) | elevated |
| `memory` | Persistent KV store with tags | none |
| `cron` | Schedule recurring tasks | none |
| `message` | Send to channels | none |
| `agents_list` | List available agents | none |
| `session_status` | Current session info | none |
| `sessions_list` | List all sessions | none |
| `agent_message` | Inter-agent messaging | none |
| `read_file` | Read file contents | none |
| `write_file` | Write to file | elevated |
| `list_files` | List directory | none |
| `file_search` | Search files by pattern | none |

## Security

```
Layer 1: SSRF Protection      -- block private/internal IPs in web_fetch
Layer 2: Command Filters       -- block rm -rf /, fork bombs, etc.
Layer 3: Pairing Codes         -- 6-digit time-limited channel auth
Layer 4: Rate Limiting         -- token-bucket per-sender
Layer 5: Tool Policy           -- per-agent allow/deny lists
Layer 6: Elevated Policy       -- authorization for dangerous tools
Layer 7: RBAC                  -- role-based command authorization
Layer 8: Audit Logging         -- JSONL trail for all security events
```

## Plugin System

```
Plugin Discovery (4 sources):
  ${BASHCLAW_ROOT}/extensions/      # bundled
  ~/.bashclaw/extensions/           # global user
  .bashclaw/extensions/             # workspace-local
  config: plugins.load.paths        # custom paths
```

Plugins can register tools, hooks, commands, and providers:

```sh
plugin_register_tool "my_tool" "Description" '{"input":{"type":"string"}}' handler.sh
plugin_register_hook "pre_message" filter.sh 50
plugin_register_command "my_cmd" "Description" cmd.sh
plugin_register_provider "my_llm" "My LLM" '["model-a"]' '{"envKey":"MY_KEY"}'
```

## Hook System

| Event | Strategy | When |
|-------|----------|------|
| `pre_message` | modifying | Before processing (can modify input) |
| `post_message` | void | After processing |
| `pre_tool` | modifying | Before tool exec (can modify args) |
| `post_tool` | modifying | After tool exec (can modify result) |
| `on_error` | void | On error |
| `on_session_reset` | void | Session reset |
| `before_agent_start` | sync | Before agent begins |
| `agent_end` | void | After agent finishes |
| `before_compaction` | sync | Before context compaction |
| `after_compaction` | void | After context compaction |
| `message_received` | modifying | Message arrives at gateway |
| `message_sending` | modifying | Before reply dispatch |
| `message_sent` | void | After reply dispatch |
| `session_start` | void | New session created |

## Configuration

Config file: `~/.bashclaw/bashclaw.json`

```json
{
  "agents": {
    "defaults": {
      "model": "claude-opus-4-6",
      "maxTurns": 50,
      "contextTokens": 200000,
      "tools": ["web_fetch", "web_search", "memory", "shell"]
    }
  },
  "channels": {
    "telegram": { "enabled": true, "botToken": "$TELEGRAM_BOT_TOKEN" }
  },
  "gateway": { "port": 18789 },
  "session": { "scope": "per-sender", "idleResetMinutes": 30 }
}
```

<details>
<summary><strong>Environment variables</strong></summary>

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Anthropic Claude |
| `OPENAI_API_KEY` | OpenAI |
| `GOOGLE_API_KEY` | Google Gemini |
| `OPENROUTER_API_KEY` | OpenRouter |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `QWEN_API_KEY` | Qwen (DashScope) |
| `ZHIPU_API_KEY` | Zhipu GLM |
| `MOONSHOT_API_KEY` | Moonshot Kimi |
| `MINIMAX_API_KEY` | MiniMax |
| `MODEL_ID` | Override default model |
| `BASHCLAW_STATE_DIR` | State dir (default: `~/.bashclaw`) |
| `LOG_LEVEL` | `debug` / `info` / `warn` / `error` / `silent` |

</details>

## Use Cases

**Web dashboard on a Mac**
```sh
bashclaw gateway
# Open http://localhost:18789 -- first-run wizard configures API keys
# Chat with the agent in your browser immediately
```

**Multi-channel team bot**
```sh
# One agent, multiple channels -- all served by a single gateway
bashclaw config set '.channels.telegram.enabled' 'true'
bashclaw config set '.channels.discord.enabled' 'true'
bashclaw config set '.channels.slack.enabled' 'true'
bashclaw gateway
# Messages from all platforms routed to the same agent
```

**Always-on server agent**
```sh
# Install on a fresh Ubuntu server
curl -fsSL .../install.sh | bash
bashclaw daemon install --enable
# Agent runs 24/7, accessible via Telegram, Discord, Slack, or web dashboard
```

**CI/CD pipeline agent**
```sh
# In a Dockerfile or CI step (< 10MB overhead)
bashclaw agent -m "Review this diff and suggest improvements" < diff.patch
```

**SSH / headless CLI**
```sh
bashclaw agent -i
# Interactive REPL for power users. No browser needed.
```

## Testing

```sh
bash tests/run_all.sh                # all tests
bash tests/run_all.sh --unit         # unit tests only
bash tests/run_all.sh --integration  # live API tests
bash tests/test_agent.sh             # single suite
```

## Troubleshooting

```sh
bashclaw doctor        # check dependencies, config, API key
bashclaw status        # gateway state, session count
bashclaw config show   # dump current config
LOG_LEVEL=debug bashclaw agent -m "test"  # verbose output
```

**Common issues:**
- `command not found` after install -- run `source ~/.zshrc` (macOS) or `source ~/.bashrc` (Linux), or open a new terminal
- `jq: command not found` -- the installer auto-installs jq; if it failed, run `brew install jq` (macOS) or `apt install jq` (Linux)
- Gateway shows no HTTP -- install `socat` for full HTTP server: `brew install socat` (macOS) or `apt install socat` (Linux)

## License

MIT
