#!/usr/bin/env bash
#
# quick-start.sh — agent-os 工作区一键启动脚本
#
# 用法:
#   ./quick-start.sh walicode          # 启动 walicode 全栈（中间件 + 服务端 + Tauri 客户端）
#   ./quick-start.sh walissh           # 启动 walissh 全栈
#   ./quick-start.sh walicode --web    # 客户端用纯前端模式（Vite @5173，不启动桌面壳）
#   ./quick-start.sh walicode --no-client   # 只启动中间件 + 服务端
#   ./quick-start.sh walicode stop     # 停止该项目的后台服务端
#
# 前置要求: docker、Java 17、Maven、Node 22+（Tauri 模式还需要 Rust 工具链）
# 注意: 首次启动前请先在 <project>-server-app/src/main/resources/application-dev.yml
#       与 agent/*.yml 中配置好 LLM API Key（可指向 WaLiAPI 网关 127.0.0.1:8777）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT/.quick-start"
mkdir -p "$STATE_DIR"

# ---------- 参数解析 ----------
PROJECT="${1:-}"
MODE="tauri"          # tauri | web | none
ACTION="start"        # start | stop
for arg in "${@:2}"; do
  case "$arg" in
    --web)       MODE="web" ;;
    --no-client) MODE="none" ;;
    stop)        ACTION="stop" ;;
    *) echo "未知参数: $arg" >&2; exit 1 ;;
  esac
done
if [[ "$PROJECT" == "stop" ]]; then echo "用法: $0 <walicode|walissh> stop"; exit 1; fi

if [[ "$PROJECT" != "walicode" && "$PROJECT" != "walissh" ]]; then
  sed -n '2,15p' "${BASH_SOURCE[0]}"
  exit 1
fi

SERVER_DIR="$ROOT/$PROJECT/${PROJECT}-server"
APP_DIR="$SERVER_DIR/${PROJECT}-server-app"
CLIENT_DIR="$ROOT/$PROJECT/${PROJECT}-client"
COMPOSE_DIR="$SERVER_DIR/docs/dev-ops"
SQL_DIR="$COMPOSE_DIR/mysql/sql"
PID_FILE="$STATE_DIR/${PROJECT}-server.pid"
LOG_FILE="$STATE_DIR/${PROJECT}-server.log"
DB_NAME="walissh"
MYSQL_ROOT_PASSWORD="123456"   # 与 docker-compose-environment.yml 保持一致

log()  { printf '\033[1;34m[quick-start]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[quick-start]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[quick-start]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- stop ----------
if [[ "$ACTION" == "stop" ]]; then
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && log "已停止 $PROJECT 服务端 (PID $(cat "$PID_FILE"))"
  else
    warn "没有找到运行中的 $PROJECT 服务端"
  fi
  rm -f "$PID_FILE"
  exit 0
fi

# ---------- 1. 环境检查 ----------
log "检查依赖环境..."
command -v docker >/dev/null || die "未找到 docker，请先安装并启动 Docker Desktop"
docker info >/dev/null 2>&1  || die "Docker 守护进程未运行，请先启动 Docker Desktop"
command -v mvn    >/dev/null || die "未找到 mvn（Maven 3.8+）"
command -v java   >/dev/null || die "未找到 java（需要 JDK 17）"
JAVA_VER="$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)"
[[ "$JAVA_VER" == "17" || "$JAVA_VER" -ge 17 ]] 2>/dev/null || warn "当前 Java 版本为 $JAVA_VER，项目要求 17+"
if [[ "$MODE" != "none" ]]; then
  command -v node >/dev/null || die "未找到 node（需要 22+）"
  command -v npm  >/dev/null || die "未找到 npm"
fi
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  die "未找到 docker compose / docker-compose"
fi

# ---------- 2. 子模块 ----------
if [[ ! -f "$SERVER_DIR/pom.xml" ]]; then
  log "初始化 git 子模块..."
  git -C "$ROOT" submodule update --init
fi

# ---------- 3. LLM Key 提醒 ----------
if grep -qE 'sk-waliapi-\*|your-api-key|sk-xxx' "$APP_DIR/src/main/resources/application-dev.yml" 2>/dev/null; then
  warn "检测到 application-dev.yml 中的 API Key 疑似占位符，请先配置真实 LLM Key"
fi

# ---------- 4. 中间件 ----------
log "启动中间件（MySQL @13306 / Redis @16379）..."
$COMPOSE -f "$COMPOSE_DIR/docker-compose-environment.yml" up -d

log "等待 MySQL 就绪..."
for i in $(seq 1 36); do
  if [[ "$(docker inspect -f '{{.State.Health.Status}}' mysql 2>/dev/null || echo none)" == "healthy" ]]; then
    break
  fi
  [[ "$i" == "36" ]] && die "MySQL 等待超时，请检查: docker logs mysql"
  sleep 5
done
log "MySQL 已就绪"

mysql_exec() { docker exec -i mysql mysql -uroot"-p$MYSQL_ROOT_PASSWORD" "$@" 2>/dev/null; }

# 建库（SQL 挂载进 initdb 目录，但数据卷已初始化过时不会重放，这里统一兜底）
mysql_exec -e "CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
TABLE_COUNT="$(mysql_exec -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';")"
if [[ "$TABLE_COUNT" == "0" ]]; then
  log "数据库为空，导入 SQL 脚本..."
  mysql_exec "$DB_NAME" < "$SQL_DIR/walissh.sql"
  [[ -f "$SQL_DIR/core_memory_ddl.sql" ]] && mysql_exec "$DB_NAME" < "$SQL_DIR/core_memory_ddl.sql"
  log "SQL 导入完成"
else
  log "数据库 $DB_NAME 已有 $TABLE_COUNT 张表，跳过导入"
fi

# ---------- 5. 服务端 ----------
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  log "$PROJECT 服务端已在运行 (PID $(cat "$PID_FILE"))，跳过启动"
else
  log "构建服务端（跳过测试）..."
  mvn -q -f "$SERVER_DIR/pom.xml" clean install -DskipTests
  log "后台启动服务端（日志: $LOG_FILE）..."
  ( cd "$APP_DIR" && nohup mvn spring-boot:run > "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE" )
  log "等待服务端 8091 端口..."
  for i in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/8091) 2>/dev/null; then break; fi
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || die "服务端进程已退出，请查看日志: $LOG_FILE"
    [[ "$i" == "60" ]] && die "服务端启动超时，请查看日志: $LOG_FILE"
    sleep 3
  done
  log "服务端已启动: http://localhost:8091"
fi

# ---------- 6. 客户端 ----------
case "$MODE" in
  none)
    log "已完成（--no-client，未启动客户端）"
    ;;
  web)
    log "安装客户端依赖并启动 Vite dev（http://localhost:5173）..."
    [[ -d "$CLIENT_DIR/node_modules" ]] || ( cd "$CLIENT_DIR" && npm install )
    cd "$CLIENT_DIR" && exec npm run dev
    ;;
  tauri)
    log "安装客户端依赖并启动 Tauri 桌面开发模式..."
    [[ -d "$CLIENT_DIR/node_modules" ]] || ( cd "$CLIENT_DIR" && npm install )
    cd "$CLIENT_DIR" && exec npm run tauri dev
    ;;
esac
