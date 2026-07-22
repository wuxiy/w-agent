# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

**WaLiSSH（Web AI SSH）** 是一个 AI 驱动的智能 SSH 运维终端，分两端：

- `walissh-server/` — Spring Boot 3.4.3 + Java 17 + DDD 多模块后端
- `walissh-client/` — Tauri 2 + React 19 + Vite 7 + TypeScript 桌面客户端

**核心架构决策（重要）**：SSH 操作与 AI Agent 操作**全部放在服务端**，客户端仅作 UI 壳。这是刻意的——便于企业统一管控风险、防止危险命令误执行、避免核心服务器信息泄露。**不要把 SSH/AI 逻辑下沉到客户端。**

启动顺序：**先启服务端（端口 8091），再启客户端。**

---

## 常用命令

### 服务端（walissh-server，根目录运行）

```bash
# 构建全部模块（默认 dev profile）
mvn clean package

# 指定 profile 构建：mvn clean package -P {dev|test|prod}

# 启动（app 模块，端口 8091）
java -jar walissh-server-app/target/walissh-server-app.jar

# 运行单个测试类 / 单个方法
mvn -pl walissh-server-app test -Dtest=ApiTest
mvn -pl walissh-server-app test -Dtest=ParallelAgentTest#testParallel

# 启动依赖中间件（MySQL 13306 / Redis 16379）
docker-compose -f walissh-server/docs/dev-ops/docker-compose-environment.yml up -d

# 构建并运行应用镜像
cd walissh-server/walissh-server-app && bash build.sh
docker-compose -f walissh-server/docs/dev-ops/docker-compose-app.yml up -d
```

前置依赖：JDK 17、Maven 3.8.x、MySQL（需建库 `walissh`，建表 SQL 在 `walissh-server/docs/dev-ops/mysql/sql/walissh.sql`）。**首次运行前必须配置 LLM**：
- `application-dev.yml` 的 `intent-ai-api.api-key`
- `agent/ssh-agent.yml` 的 `module.ai-api.api-key` 和 `module.chat-model.model`

### 客户端（walissh-client 目录）

```bash
cd walissh-client

# 桌面开发（推荐，自动安装依赖 + 启 Tauri + Vite）
bash docs/dev-ops/start-dev.sh          # Windows: docs/dev-ops/start-dev.bat

# 仅前端开发（端口 5173，走 Vite proxy 到 8091）
npm run dev

# 构建
npm run build          # tsc 类型检查 + vite build
npm run tauri build    # 打包桌面应用
```

前置依赖：Node 22+、Rust（rustup）、Tauri CLI。`npm run build` 会先跑 `tsc`，**类型错误会导致构建失败**。

---

## 服务端架构（DDD 七模块）

依赖方向单向：`trigger / case → domain ← infrastructure`，`types` 被所有层依赖，`api` 定义对外契约，`app` 负责装配启动。

| 模块 | 职责 |
|------|------|
| `walissh-server-types` | 公共枚举（`ResponseCode`、`AuthTypeEnum`）、异常、工具类 |
| `walissh-server-api` | 对外服务接口（`IAgentService`、`ISshConnectionService`、`ISshTerminalService`、`ISshFileService`）+ DTO |
| `walissh-server-domain` | **核心领域层**，两个子域：`ssh/`（终端/文件/连接）、`agent/`（AI 智能体） |
| `walissh-server-infrastructure` | MyBatis DAO/PO + **JSch** SSH 实现（端口适配器：`SshSessionPort`/`TerminalSessionPort`/`SshFilePort`） |
| `walissh-server-trigger` | HTTP Controller 层（`SshTerminalController`/`SshFileController`/`SshAgentController`/`SshConnectionController`/`AgentServiceController`） |
| `walissh-server-case` | 业务用例编排层，**ReAct 模式实现** |
| `walissh-server-app` | Spring Boot 启动入口 `Application.java` + 配置 + `resources`（`application*.yml`、`agent/*.yml`、MyBatis mapper） |

### 必须理解：设计模式框架（xfg-wrench）

后端大量依赖脚手架 `cn.bugstack.wrench:xfg-wrench-starter-design-framework`，核心是 **`AbstractMultiThreadStrategyRouter`** —— 一棵多线程策略路由树。**改 Agent 相关代码前必须理解这套节点链机制**：

- 每个「节点」继承对应的 `AbstractXxxSupport`（后者继承 `AbstractMultiThreadStrategyRouter`），实现 `doRouter` 等方法。
- 节点间通过 **`DynamicContext`** 传递状态，靠 Spring Bean 名称做路由。
- 两处典型节点链：
  - **智能体装配链**（`domain/agent/service/armory/node/`）：`RootNode → AiApiNode → ChatModelNode → AgentWorkflowNode → {LoopAgentNode | SequentialAgentNode | ParallelAgentNode}`
  - **ReAct 推理链**（`case/react/node/`）：`RootNode → AiCallNode → ToolCallNode → UserFeedbackNode → LoopDecisionNode`

### AI Agent：两条并存的路径

项目同时引入了 Google ADK 1.2.0、Spring AI 1.1.5、LangChain4j 1.4.0、spring-ai-agent-utils：

1. **ADK 装配路径**（`domain/agent`）：`IChatService`，响应式 `Flowable<Event>`，由 `ArmoryService` 装配。
2. **ReAct 路径**（`walissh-server-case`）：`IAIAgentReActServiceCase.chatStream`，**SSE 流式输出**（每行一个 JSON 事件，无 `data:` 前缀）。事件类型：`text` / `tool_call` / `tool_result` / `round_end` / `done` / `error`。

**Agent 是声明式 YAML 配置 + 自动装配**：`application-dev.yml` 通过 `spring.config.import` 引入 `agent/*.yml`（当前为 `ssh-agent.yml`）；应用启动到 `ApplicationReadyEvent` 时，`AiAgentAutoConfig` 调用 `IArmoryService.acceptArmoryAgents(...)` 把 YAML 解析装配为运行时智能体。新增/改 Agent = 改 YAML，通常不用动 Java。

**SSH 工具如何接入 Agent**：`Application.java` 把 `SshExecuteMcpService` 注册为 Spring AI 的 `ToolCallbackProvider`（Bean 名 `sshToolCallbackProvider`），Agent 调用 `executeCommand` 工具即执行远程命令。

### 终端 ↔ 智能体绑定（非显然）

`SshAgentController` 用 `ConcurrentHashMap` 维护 `chatSessionId → terminalSessionId` 映射，并通过 **ThreadLocal** 把当前终端会话绑定到执行线程，使 AI 工具能定位到正确的 SSH 终端。改工具调用链路时注意这个绑定。

### 持久层

MyBatis，表：`ssh_connection`、`ssh_connection_config`、`chat_session`、`chat_message`、`chat_milestone`。domain 的 repository 接口在 infrastructure 用 DAO（`@Mapper`）实现，PO ↔ Entity 在 service 层转换。**里程碑（milestone）独立于消息裁剪**，用于持久化关键事件记忆。

### 意图识别

`domain/agent/service/intent/` 下两层分类器：`RuleIntentClassifier`（关键词，快）+ `LLMIntentClassifier`（语义，准），由 `IntentService` 编排，在 ReAct 的 `AiCallNode` 中用于动态增强 prompt。使用独立的 `intent-ai-api` 配置。设计文档见 `docs/intent-recognition-enhancement-design.md`。

---

## 客户端架构

- **Tauri 壳极薄**：`src-tauri/src/lib.rs` 几乎无业务逻辑（仅 `greet` + opener 插件），所有数据走 HTTP 调服务端。
- **状态管理**：Zustand（`src/stores/`：`connectionStore`、`sshAgentStore`、`fileExplorerStore`、`themeStore`、`agentStore`）。
- **终端**：xterm.js（addon-fit / web-links / webgl）。
- **编辑器**：Monaco（`vite-plugin-monaco-editor`，按需引入语言 worker）。
- **HTTP**：自封装 `src/api/request.ts`（原生 fetch，**无 axios**）。
- **布局**：类 VSCode（ActivityBar + LeftSidebar + Workbench + 右侧 AI 对话面板 + 终端），`MainView.tsx` 统一管理终端会话、多文件标签与分屏模式。

### 终端协议（非显然，非 WebSocket）

终端基于 **HTTP 轮询**而非 WebSocket：`open` 建会话 → `write` 发原始输入字节 → `read` 轮询服务端缓冲输出（`api/terminal.ts`）。改终端交互时按此模型来。

### 服务端地址解析

`api/request.ts` 中：dev 模式 `baseUrl=''`（走 Vite proxy，`/api` → `localhost:8091`）；用户在设置页改地址后直连；生产模式（Tauri）从 localStorage 读。`getBaseUrl()`/`setBaseUrl()` 控制切换。

### 响应信封（前后端契约）

后端统一返回 `{ code, info, data }`，**`code === '0000'` 表示成功**；失败可能返回 HTTP 状态字符串、`TIMEOUT`、`NETWORK_ERROR`。前端按此判断。

---

## 工程约定

- 改 Agent/ReAct/装配链代码前，先读懂 `AbstractMultiThreadStrategyRouter` 节点机制。
- 新增 Agent 优先改 `agent/*.yml` 而非写死在 Java。
- SSH/AI 逻辑留在服务端，客户端只做展示与编排。
- 配置中的 `api-key` 等敏感信息勿提交真实值到公开仓库（仓库内现有的是示例值）。
