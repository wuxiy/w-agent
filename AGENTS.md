# AGENTS.md

本文件面向 AI 编码代理，描述此工作区的结构、技术栈、构建与开发约定。

## 工作区概览

`/Users/wuxi/workspace/tool/agent-os` **不是一个单一项目，也不含顶层构建配置**，它是三个相互关联但各自独立的子项目的工作区目录（作者均为小傅哥 xiaofuge / fuzhengwei，文档与注释以中文为主）：

| 子项目 | 说明 | 形态 |
|---|---|---|
| `WaLiAPI/` | 本地 LLM API 网关：将多家上游模型供应商统一为 OpenAI 兼容协议 | Tauri 2 桌面应用（React + Rust），独立 git 仓库 |
| `walicode/` | WaLiCode：AI 辅助编码/运维系统（AI Coding + DevOps） | `walicode-client`（Tauri 桌面端）+ `walicode-server`（Spring Boot 服务端），各自独立 git 仓库 |
| `walissh/` | WaLiSSH：AI 驱动的智能 SSH 运维终端 | `walissh-client`（Tauri 桌面端）+ `walissh-server`（Spring Boot 服务端），根目录有 `CLAUDE.md` |

三者关系：WaLiAPI 可作为 WaLiCode 等下游客户端的模型网关；walicode 由 walissh 演进/改名而来（代码、配置、SQL 中仍大量残留 `walissh` 命名）。两个服务端都基于同一脚手架 `cn.bugstack.ai` 体系，架构高度相似。

**注意**：服务端配置文件（`application-dev.yml`、`agent/*.yml`、`docker-compose-app.yml` 等）中目前提交有真实样式的 LLM API Key（`sk-...`）和数据库密码，修改或对外分享这些文件时务必留意，不要新增真实凭据。

---

## WaLiAPI（`WaLiAPI/`）

### 项目用途
本地运行的 LLM API 网关桌面应用。把 OpenAI、Claude、DeepSeek、Gemini、智谱、通义、Moonshot、豆包、Ollama、自定义共 10 种渠道统一为 OpenAI 兼容协议，内嵌 Axum HTTP 服务（默认 `http://127.0.0.1:8777`），暴露 `/v1/chat/completions`、`/v1/responses`、`/v1/messages`（Anthropic）、`/v1/models`、`/health` 等端点，下游用自生成的 `sk-waliapi-*` 密钥认证。附带仪表盘、请求审计日志、安全审计中心（敏感信息扫描/脱敏/阻断）、渠道优先级+权重负载均衡与故障切换。

### 技术栈
- 前端（`WaLiAPI/src/`）：React 19 + TypeScript + Vite 7，Tailwind CSS 4（shadcn/ui 风格），React Router 7、Zustand 5、TanStack Query 5、`@tauri-apps/api` v2。包管理器用 **pnpm**（有 `pnpm-lock.yaml`）。
- 后端（`WaLiAPI/src-tauri/`，Rust Edition 2021）：Tauri 2 + 多个官方插件（sql/store/clipboard/notification/autostart 等）；Axum 0.8 + Tokio 内嵌 HTTP 服务；reqwest（SSE 流式转发）；sqlx 0.8（SQLite，自动迁移）。

### 构建与开发
```bash
cd WaLiAPI
pnpm install
pnpm tauri dev      # 完整桌面开发（自动先跑 vite dev，端口 1420）
pnpm build          # tsc && vite build（唯一的前端检查）
pnpm tauri build    # 发布构建
```
- 无 Makefile；`start.sh` 仅一行 `npm run tauri dev`。
- **没有任何测试**：无测试框架、无测试代码（Rust 侧也无 `#[test]`），无 ESLint/Prettier/rustfmt 配置。代码保障仅靠 `pnpm build` 中的 `tsc` 类型检查。
- 发布：`.github/workflows/` 下 4 个 tauri-action 工作流，按平台前缀 tag 触发（`macos-arm64-v*`、`all-v*`、`all-win-v*`、`linux-v*`）。版本号需在 `package.json`、`Cargo.toml`、`tauri.conf.json` 三处同步。

### 代码组织
- 前端 `src/`：入口 `main.tsx` → `App.tsx`（6 条路由）；`pages/` 6 个页面（Dashboard/Channels/ApiKeys/Logs/Usage/Settings）；`lib/api.ts` 封装全部 Tauri invoke；`lib/constants.ts` 定义 10 种渠道类型。
- 后端 `src-tauri/src/`：
  - `server/`：Axum 路由与三大协议处理器（`handlers.rs`）；
  - `adaptor/`：`Adaptor` trait + openai/claude/deepseek/gemini/custom 实现（其余渠道类型落到 custom）；
  - `protocol/`：OpenAI ↔ Anthropic/Responses 协议双向转换（含 SSE）；
  - `core/`：`dispatcher.rs`（优先级+权重选渠道）、`proxy.rs`（转发主流程：安全扫描→脱敏/阻断→调度→调用→写日志）；
  - `security/`：风险扫描、脱敏、内置规则；
  - `commands/`：9 个模块共 43 个 Tauri Commands（在 `lib.rs` 注册）；
  - `db/`：sqlx 连接池 + `sqlx::migrate!`（迁移在 `src-tauri/migrations/`，注意存在两个 005 前缀文件）+ repository。
- 数据库：SQLite，文件在应用数据目录 `waliapi.db`；核心表 `channels`、`api_keys`、`request_logs`。**上游真实 API Key 明文存本地 SQLite**。
- 运行时设置存 `tauri-plugin-store` 的 `settings.json`。
- 根目录另有两份中文过程文档：`waliapi_build_complete_20260718.md`（架构决策记录）、`waliapi_usage_guide_20260718.md`（使用指南）。

---

## walicode 与 walissh（Spring Boot 服务端 + Tauri 客户端）

两套系统架构几乎一致，以下合并说明，差异处单独标注。**核心架构决策：SSH 操作和 AI 操作全部放在服务端，客户端只做 UI 壳**（企业级风险管控）——不要把 SSH/AI 逻辑下沉到客户端。

### 技术栈
- 服务端（`walicode-server/`、`walissh-server/`，Maven 多模块，groupId `cn.bugstack.ai`）：
  - Java **17** + Spring Boot **3.4.3**，Maven 3.8.x（仓库走阿里云镜像），Lombok；
  - AI 生态多线并存：Google ADK 1.2.0、Spring AI 1.1.5、LangChain4j 1.4.0、`spring-ai-agent-utils`；
  - 策略树设计模式框架 `cn.bugstack.wrench:xfg-wrench-starter-design-framework`（`AbstractMultiThreadStrategyRouter` 多线程策略路由，节点间用 `DynamicContext` 传状态）；
  - MyBatis + MySQL 8 + HikariCP（无 Flyway/Liquibase，SQL 脚本手动导入：`docs/dev-ops/mysql/sql/walissh.sql`，库名 `walissh`）；
  - SSH 用老式 **JSch 0.1.54**（适配器在 infrastructure 的 `adapter/port/`）。
- 客户端（`walicode-client/`、`walissh-client/`）：
  - React 19 + TypeScript + Vite 7 + Tailwind CSS 4，Tauri 2 桌面壳；
  - xterm.js 终端、Monaco 编辑器、Zustand 状态管理；HTTP 用自封装 `src/api/request.ts`（原生 fetch，无 axios）；
  - walicode-client 的 Tauri Rust 侧较重：`portable-pty`（本地终端 PTY）+ 内嵌 Axum 本地 HTTP Server（默认 `127.0.0.1:17890`，供服务端 `LocalExecuteAdkTool` 反向回调执行本地命令）；walissh-client 的 Rust 侧极薄（只有 `greet` + opener）。

### 构建与开发
启动顺序：**先服务端，后客户端**。

```bash
# 1. 中间件（MySQL 8 @13306、Redis @16379、phpMyAdmin @8899、redis-commander @8081）
cd <xxx>-server/docs/dev-ops
docker-compose -f docker-compose-environment.yml up -d
# 需手动建库 walissh 并导入 mysql/sql/walissh.sql；并配置 LLM key（application-dev.yml 与 agent/*.yml 两处）

# 2. 服务端（端口 8091）
cd <xxx>-server
mvn clean install -DskipTests      # 或 mvn clean package（默认 dev profile，-P test|prod 切换）
cd <xxx>-server-app && mvn spring-boot:run
# 或 java -jar <xxx>-server-app/target/<xxx>-server-app.jar（主类 cn.bugstack.ai.Application）

# 3. 客户端
cd <xxx>-client
npm install
bash docs/dev-ops/start-dev.sh     # 一键桌面开发（检查 Node 22+/Rust 后 npm run tauri dev）；Windows 用 start-dev.bat
npm run dev                        # 纯前端 dev（Vite 端口 5173，/api 代理到 localhost:8091）
npm run build                      # tsc && vite build
```

- 生产部署：`<xxx>-server-app/Dockerfile`（openjdk:17-jdk-slim）+ `build.sh`（多架构镜像）+ `push.sh`（推阿里云杭州 registry）+ `docs/dev-ops/docker-compose-app.yml`（环境变量覆盖配置）。
- walissh 根目录的 `CLAUDE.md` 是该项目的权威开发指南，改动 walissh 前先读它；其中命令说明同样适用于 walicode。

### 服务端代码组织（DDD 七模块，包根 `cn.bugstack.ai`）
依赖方向单向：`trigger/case → domain ← infrastructure`。

| 模块 | 职责 |
|---|---|
| `<xxx>-server-types` | 常量、枚举（`ResponseCode`，`0000` 为成功）、异常 |
| `<xxx>-server-api` | 接口契约（`IAgentService`、`ISshXxxService`）+ DTO + 统一 `Response` |
| `<xxx>-server-domain` | 核心领域：`domain/ssh/`（连接/终端/文件，端口接口 `adapter/port/`）与 `domain/agent/`（装配链节点 `armory/node`、双层意图识别 `intent/`（规则+LLM）、上下文裁剪 `context/`、工具 `matter/tools/`、MCP、skills） |
| `<xxx>-server-infrastructure` | MyBatis DAO/PO + Repository 实现 + JSch 端口适配 + `PasswordEncryptor`（AES-256-GCM 加密 SSH 密码，密钥用环境变量覆盖，walissh 用 `WALISSH_SECRET_KEY`） |
| `<xxx>-server-trigger` | HTTP Controller（全部 `@CrossOrigin("*")`） |
| `<xxx>-server-case` | ReAct 执行引擎：`AIAgentReActServiceCase` + 节点链 `RootNode → AiCallNode → ToolCallNode → UserFeedbackNode → LoopDecisionNode`（walicode 还多了 `TaskBreakdownNode` 与权限确认 `PermissionConfirmManager`） |
| `<xxx>-server-app` | 启动入口 `Application.java`、`AiAgentAutoConfig`、resources（`application*.yml`、`agent/*.yml`、MyBatis mapper XML、logback） |

关键机制：
- **Agent 声明式装配**：Agent 由 `agent/*.yml` YAML 定义，经 `spring.config.import` 引入，`ApplicationReadyEvent` 时由 `AiAgentAutoConfig` 解析装配；**一次只启用一个 Agent YAML，新增/调整 Agent 优先改 YAML 不动 Java**。
- **AI 对话两条并存路径**：① ADK 装配路径（`IChatService`，响应式 `Flowable<Event>`）；② ReAct 路径（case 层 `chatStream`，SSE 流式，每行一个 JSON 事件无 `data:` 前缀，事件类型 `text`/`tool_call`/`tool_result`/`round_end`/`done`/`error`）。
- SSH 工具通过 `Application.java` 注册为 Spring AI `ToolCallbackProvider` 供 Agent 调用。
- 统一响应信封 `{ code, info, data }`。
- 日志：`logback-spring.xml` 输出到 `./data/log/`（walissh 根目录的 `data/` 就是这个运行时日志目录，不是数据文件）。

### 客户端代码组织
`src/`：`api/`（各服务 fetch 封装）、`stores/`（zustand）、`components/`（TerminalPanel、CodeEditor、FileWorkspace、SFTPWorkspace 等）、`views/MainView.tsx`、`types/`。入口 `main.tsx` → `App.tsx`。服务端地址在设置页可改，持久化于 localStorage。

### 通信方式（无 WebSocket）
- 全部 **HTTP REST + SSE**：服务端端口 **8091**；`chat_stream` 返回 `ResponseBodyEmitter`。
- **终端是 HTTP 轮询模型**：`open` 建会话 → `write` 发字节 → `read` 轮询读缓冲，不是 WebSocket。
- 客户端消费 SSE 用 `fetch` + `res.body.getReader()` 手动解析。

### 端口速查
服务端 8091；Vite dev 5173；walicode Tauri 本地 HTTP Server 17890；MySQL 13306；Redis 16379；phpMyAdmin 8899；redis-commander 8081；WaLiAPI 网关 8777。

---

## 测试约定

- 仅两个 Java 服务端的 `*-server-app/src/test/java/cn/bugstack/ai/test/` 下有 JUnit/Spring Boot Test 测试（`ApiTest`、Loop/Sequential/Parallel Agent 测试、ChatServiceTest 等）。**这些是集成测试，需要可用的 LLM 配置和中间件才能跑**；构建默认 `-DskipTests`。
  ```bash
  mvn -pl walissh-server-app test -Dtest=ApiTest   # 运行指定测试
  ```
- 所有前端/Rust 代码均无测试、无 lint/format 配置；前端唯一检查是 `npm run build` 里的 `tsc`。新增代码应跟随现有文件的中文注释与命名风格。

## 安全注意事项

- 两个服务端**无任何认证/授权机制**（Controller 全 `@CrossOrigin("*")`，pom 里声明的 JWT 库未实际使用），只适合本机/内网部署。
- 仓库配置文件中现存真实样式的 API Key 与数据库密码（见上文警告）；提交代码前检查不要新增真实凭据。
- SSH 连接密码用 AES-256-GCM 加密落库，但加密密钥有硬编码默认值，生产环境必须用环境变量覆盖。
- WaLiAPI 的上游 API Key 以明文存于本地 SQLite。
- walicode 允许 AI 在服务端执行远程 SSH 命令、并通过反向通道在用户机器上执行本地命令，危险操作依赖权限确认流程（`PermissionGuard` + `/api/permission` + 客户端确认弹窗），改动相关代码时不得绕过该流程。
