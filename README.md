# agent-os

AI Agent 开发与运维工具集工作区。本仓库是**聚合仓库**（母仓），通过 git submodule 管理三个相互关联但各自独立的子项目（作者：小傅哥 xiaofuge / fuzhengwei），每个子项目保留自己独立的 git 仓库和 origin，可单独拉取与更新。

## 子项目一览

| 子项目 | 说明 | 形态 | 上游仓库 |
|---|---|---|---|
| `WaLiAPI/` | 本地 LLM API 网关：将 10 家模型供应商统一为 OpenAI 兼容协议 | Tauri 2 桌面应用（React 19 + Rust/Axum） | [fuzhengwei/WaLiAPI](https://github.com/fuzhengwei/WaLiAPI) |
| `walicode/` | WaLiCode：AI 辅助编码/运维系统（AI Coding + DevOps） | Tauri 桌面客户端 + Spring Boot 服务端 | gitcode.net/KnowledgePlanet |
| `walissh/` | WaLiSSH：AI 驱动的智能 SSH 运维终端（walicode 的前身） | Tauri 桌面客户端 + Spring Boot 服务端 | gitcode.net/KnowledgePlanet |

三者关系：**WaLiAPI 作为本地模型网关，为 walicode / walissh 等下游提供统一的模型接入**；walicode 由 walissh 演进而来（代码中仍有大量 `walissh` 命名残留），两者服务端架构几乎一致。

## 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                        客户端（Tauri 桌面）                    │
│  walicode-client              walissh-client                 │
│  React19 + xterm.js + Monaco  React19 + xterm.js            │
│  内含 PTY + 本地回调 HTTP服务    Rust 侧极薄                  │
└──────────────┬───────────────────────────┬──────────────────┘
               │ HTTP REST + SSE           │ HTTP REST + SSE
               │ (含终端 HTTP 轮询)          │ (终端 HTTP 轮询)
┌──────────────▼───────────────────────────▼──────────────────┐
│                服务端（Spring Boot 3.4.3, Java 17）           │
│  walicode-server / walissh-server（DDD 七模块，同一脚手架）    │
│                                                              │
│  ┌─ ReAct 执行引擎 ─────────────────────────────────────┐    │
│  │ RootNode → AiCallNode → ToolCallNode                │    │
│  │     ↑          ↓（循环）                             │    │
│  │  LoopDecisionNode ← UserFeedbackNode                │    │
│  └──────────────────────────────────────────────────────┘    │
│  双层意图识别(规则+LLM) · 上下文裁剪/压缩 · 核心记忆           │
│  SSH 工具(JSch) · MCP · Skills · 权限确认流程                  │
│  Agent 由 agent/*.yml 声明式装配（改 YAML 不改 Java）          │
└──────────────┬───────────────────────────────────────────────┘
               │ OpenAI 兼容协议
┌──────────────▼───────────────────────────────────────────────┐
│  WaLiAPI 本地 LLM 网关（http://127.0.0.1:8777）               │
│  OpenAI / Claude / DeepSeek / Gemini / 智谱 / 通义 /          │
│  Moonshot / 豆包 / Ollama / 自定义  →  统一 OpenAI 协议       │
│  渠道优先级+权重负载均衡 · 故障切换 · 安全审计/脱敏 · 请求日志  │
└──────────────────────────────────────────────────────────────┘
```

**核心架构决策**：SSH 操作和 AI 推理全部在服务端执行，客户端只做 UI 壳（企业级风险管控）。危险操作经由 `PermissionGuard` + 客户端确认弹窗的权限确认流程。

## 快速开始

### 一键启动（推荐）

```bash
./quick-start.sh walicode          # 中间件 + 服务端(8091) + Tauri 客户端
./quick-start.sh walissh --web     # 客户端改用纯前端模式（Vite @5173）
./quick-start.sh walicode --no-client   # 只起中间件 + 服务端
./quick-start.sh walicode stop     # 停止后台服务端
```

脚本会自动完成：依赖检查 → 子模块初始化 → docker 中间件 → 建库导 SQL → 服务端构建与后台启动（日志在 `.quick-start/`）→ 客户端启动。首次使用前仍需手动配置 LLM API Key（见下文第 3 步）。

### 手动分步启动

#### 0. 克隆本仓库（含子模块）

```bash
git clone --recursive https://github.com/wuxiy/agent-os.git
# 已克隆但未拉子模块时：
git submodule update --init
```

#### 1. 启动 WaLiAPI（模型网关，可选但推荐）

```bash
cd WaLiAPI
pnpm install
pnpm tauri dev        # 桌面应用 + 内嵌网关服务 http://127.0.0.1:8777
```

在界面中配置上游渠道 API Key 后，下游可用 `sk-waliapi-*` 密钥以 OpenAI 协议接入。

#### 2. 启动中间件（walicode / walissh 通用）

```bash
cd <walicode|walissh>/xxx-server/docs/dev-ops
docker-compose -f docker-compose-environment.yml up -d
# MySQL 8 @13306 · Redis @16379 · phpMyAdmin @8899 · redis-commander @8081
```

然后手动建库 `walissh` 并导入 `mysql/sql/walissh.sql`（walicode 还需 `core_memory_ddl.sql`）。

#### 3. 启动服务端（端口 8091）

先配置 LLM Key（`xxx-server-app/src/main/resources/application-dev.yml` 与 `agent/*.yml` 两处，可指向 WaLiAPI 网关），然后：

```bash
cd xxx-server
mvn clean install -DskipTests
cd xxx-server-app && mvn spring-boot:run
```

#### 4. 启动客户端

```bash
cd xxx-client
npm install
bash docs/dev-ops/start-dev.sh   # 一键桌面开发（需 Node 22+ 与 Rust 工具链）
npm run dev                      # 或纯前端调试（Vite @5173，/api 代理到 8091）
```

## 端口速查

| 端口 | 用途 |
|---|---|
| 8091 | walicode / walissh 服务端 |
| 8777 | WaLiAPI 网关 |
| 5173 | 客户端 Vite dev |
| 1420 | WaLiAPI Vite dev |
| 17890 | walicode-client 本地回调 HTTP 服务 |
| 13306 / 16379 | MySQL / Redis（docker） |
| 8899 / 8081 | phpMyAdmin / redis-commander |

## 仓库结构说明

- 本仓库只跟踪子模块指针与根级文档（`AGENTS.md`、`walissh/CLAUDE.md`），子项目代码由各自仓库管理。
- 子项目内开发后，在其目录内 `git pull / push` 与各自 origin 同步；需要更新母仓指针时，在本仓库 `git add <子项目路径> && git commit`。
- 注意子模块默认为游离 HEAD，在子目录改代码前先 `git checkout main`（或对应分支）。
- `walissh/data/` 为运行时日志目录，已被 `.gitignore` 排除。

## 文档与约定

- `AGENTS.md` —— 面向 AI 编码代理的完整开发指南（技术栈、构建命令、代码组织、安全注意事项）
- `walissh/CLAUDE.md` —— walissh 项目的权威开发指南（同样适用于 walicode）
- `WaLiAPI/waliapi_build_complete_20260718.md` —— WaLiAPI 架构决策记录
- `WaLiAPI/waliapi_usage_guide_20260718.md` —— WaLiAPI 使用指南

## 安全提示

- 两个服务端**无认证机制**（Controller 全 `@CrossOrigin("*")`），仅限本机/内网部署。
- 子项目配置文件中可能包含真实 API Key 与数据库密码（历史遗留），请勿将含密钥的文件外发；SSH 密码加密密钥生产环境必须用环境变量覆盖（如 `WALISSH_SECRET_KEY`）。
- WaLiAPI 的上游 Key 明文存于本地 SQLite，注意本机数据目录保护。

## License

见 [LICENSE](LICENSE)。子项目各自适用其仓库中的许可证。
