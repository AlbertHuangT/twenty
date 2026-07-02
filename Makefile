# ============================================================================
#  Twenty CRM 本地开发环境 Makefile
#  支持: Arch (含衍生) / Ubuntu·Debian (含衍生) / macOS(Homebrew)
#  Windows 10/11: 请在 WSL2(Ubuntu) 里使用,会自动走 debian 分支。
#                 原生 cmd/PowerShell 不支持 make,不予适配。
#
#  从零开始:   make setup      (装依赖→起服务→建库→配置→装包→初始化DB)
#  然后启动:   make start      (前端 3001 / 后端 3000,Ctrl+C 停止)
#  看状态:     make check
#  帮助:       make help
#
#  注意事项:
#   - Twenty 要求 Node ^24.5.0(>=24.5.0 且 <25),版本不对 yarn 会拒绝安装。
#   - Arch 官方仓库用 valkey 替代了 redis(协议兼容),本文件据此处理。
#   - 本机测试用的 DB 角色/密码写死为 twenty/twenty,生产请自行修改。
#   - postgres 18 官方主要测 16/17,如 db-reset 报兼容错再考虑降到 17。
# ============================================================================

SHELL := /bin/bash

# ---- 平台检测 --------------------------------------------------------------
UNAME_S := $(shell uname -s)
FAMILY  := $(shell \
  if [ "$(UNAME_S)" = "Darwin" ]; then echo macos; \
  elif [ -f /etc/os-release ]; then . /etc/os-release; \
    case "$$ID $$ID_LIKE" in \
      (*arch*)            echo arch;; \
      (*debian*|*ubuntu*) echo debian;; \
      (*)                 echo unknown;; \
    esac; \
  else echo unknown; fi)

# ---- 平台相关变量:postgres 超管入口 ---------------------------------------
#  Linux: 以 postgres 系统用户身份连(peer/trust)
#  macOS(brew): 没有 postgres 角色,超管是当前用户;用绝对路径避免 keg-only PATH 问题
ifeq ($(FAMILY),macos)
PG_PREFIX  := $(shell brew --prefix postgresql@16 2>/dev/null)
PSQL       := $(PG_PREFIX)/bin/psql
PSQL_SUPER := $(PSQL) postgres
else
PSQL       := psql
PSQL_SUPER := sudo -u postgres psql
endif

DB_URL := postgres://twenty:twenty@localhost:5432/default

.DEFAULT_GOAL := help
.PHONY: help setup deps services db-setup env install db-reset start \
        check check-node db-drop clean tailscale

# ---- 帮助 ------------------------------------------------------------------
help:
	@echo "Twenty 本地环境 (检测到平台: $(FAMILY))"
	@echo ""
	@echo "  make setup       一键: deps -> services -> db-setup -> env -> install -> db-reset"
	@echo "  make start       启动前端(3001)+后端(3000),前台常驻,Ctrl+C 停止"
	@echo ""
	@echo "  分步:"
	@echo "    make deps       安装系统依赖 (node24/postgres/redis-valkey/git + corepack)"
	@echo "    make services   启动 postgres 和 redis/valkey 服务"
	@echo "    make db-setup   创建 twenty 角色 + default/test 数据库 (幂等)"
	@echo "    make env        生成/修补 .env (PG连接串 + 随机 APP_SECRET,幂等)"
	@echo "    make install    yarn install"
	@echo "    make db-reset   初始化数据库并灌入 demo 数据"
	@echo ""
	@echo "  工具:"
	@echo "    make check              检查各组件是否就绪"
	@echo "    make db-drop            删除 default/test 库 (配合 db-reset 重来)"
	@echo "    make clean              删除 node_modules"
	@echo "    make tailscale HOST=x   把 SERVER_URL/FRONTEND_URL 指向 tailscale 主机"

# ---- 一键 ------------------------------------------------------------------
setup: deps services db-setup env install db-reset
	@echo ""
	@echo "==> 完成。运行 'make start' 启动,浏览器打开 http://localhost:3001"
	@echo "    (SIGN_IN_PREFILLED=true 会自动填好 demo 账号,直接登录)"

# ---- 系统依赖 --------------------------------------------------------------
deps:
ifeq ($(FAMILY),arch)
	sudo pacman -S --needed --noconfirm nodejs-lts-krypton npm postgresql valkey git
else ifeq ($(FAMILY),debian)
	sudo apt-get update
	sudo apt-get install -y curl ca-certificates gnupg git build-essential postgresql redis-server
	curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
	sudo apt-get install -y nodejs
else ifeq ($(FAMILY),macos)
	brew install node@24 postgresql@16 redis git
	brew link --overwrite --force node@24 || true
	@echo "[macOS] 如提示 keg-only,把这两行加进 ~/.zshrc 后重开终端:"
	@echo "  export PATH=\"$$(brew --prefix node@24)/bin:$$(brew --prefix postgresql@16)/bin:$$PATH\""
else
	@echo "未知平台,请手动安装 Node24 / PostgreSQL / Redis(或Valkey) / git"
	@exit 1
endif
	@npm install -g corepack >/dev/null 2>&1 || sudo npm install -g corepack
	@corepack enable 2>/dev/null || sudo corepack enable
	@$(MAKE) --no-print-directory check-node

# ---- 启动服务 --------------------------------------------------------------
services:
ifeq ($(FAMILY),arch)
	@if [ ! -f /var/lib/postgres/data/PG_VERSION ]; then \
	   echo "初始化 postgres 数据目录..."; \
	   sudo -u postgres initdb -D /var/lib/postgres/data; \
	 fi
	sudo systemctl enable --now postgresql.service
	sudo systemctl enable --now valkey.service
else ifeq ($(FAMILY),debian)
	sudo systemctl enable --now postgresql.service
	sudo systemctl enable --now redis-server.service
else ifeq ($(FAMILY),macos)
	brew services start postgresql@16
	brew services start redis
else
	@echo "未知平台,请手动启动 postgres 与 redis/valkey"
endif

# ---- 数据库角色 + 库 (幂等) ------------------------------------------------
db-setup:
	@$(PSQL_SUPER) -tc "SELECT 1 FROM pg_roles WHERE rolname='twenty'" | grep -q 1 \
	  || $(PSQL_SUPER) -c "CREATE ROLE twenty WITH LOGIN SUPERUSER PASSWORD 'twenty';"
	@$(PSQL_SUPER) -tc "SELECT 1 FROM pg_database WHERE datname='default'" | grep -q 1 \
	  || $(PSQL_SUPER) -c 'CREATE DATABASE "default" OWNER twenty;'
	@$(PSQL_SUPER) -tc "SELECT 1 FROM pg_database WHERE datname='test'" | grep -q 1 \
	  || $(PSQL_SUPER) -c 'CREATE DATABASE test OWNER twenty;'
	@echo "db-setup 完成 (角色 twenty / 库 default,test)"

# ---- .env 生成与修补 (幂等) ------------------------------------------------
env:
	@[ -f packages/twenty-server/.env ] || cp packages/twenty-server/.env.example packages/twenty-server/.env
	@[ -f packages/twenty-front/.env ]  || cp packages/twenty-front/.env.example  packages/twenty-front/.env
	@# 仅当仍是模板默认 postgres:postgres 时才改,避免覆盖你的自定义
	@if grep -q '^PG_DATABASE_URL=postgres://postgres:postgres@' packages/twenty-server/.env; then \
	   sed 's|^PG_DATABASE_URL=.*|PG_DATABASE_URL=$(DB_URL)|' \
	     packages/twenty-server/.env > packages/twenty-server/.env.tmp \
	   && mv packages/twenty-server/.env.tmp packages/twenty-server/.env; \
	   echo "set PG_DATABASE_URL -> twenty:twenty"; \
	 fi
	@# 仅当 APP_SECRET 还是占位符时才生成,已设置则不动(改了会踢掉所有登录)
	@if grep -q '^APP_SECRET=replace_me' packages/twenty-server/.env; then \
	   SECRET=$$(openssl rand -base64 32 | tr -d '\n'); \
	   sed "s|^APP_SECRET=.*|APP_SECRET=$$SECRET|" \
	     packages/twenty-server/.env > packages/twenty-server/.env.tmp \
	   && mv packages/twenty-server/.env.tmp packages/twenty-server/.env; \
	   echo "generated APP_SECRET"; \
	 fi
	@echo "env 就绪"

# ---- Twenty 本体 -----------------------------------------------------------
install:
	yarn install

db-reset:
	npx nx database:reset twenty-server

start:
	yarn start

# ---- 检查 ------------------------------------------------------------------
check:
	@echo "平台      : $(FAMILY)"
	@printf "node      : "; node --version 2>/dev/null || echo "缺失"
	@printf "corepack  : "; corepack --version 2>/dev/null || echo "缺失"
	@printf "psql      : "; $(PSQL) --version 2>/dev/null || echo "缺失"
	@printf "redis     : "; (redis-cli ping 2>/dev/null || valkey-cli ping 2>/dev/null) || echo "未运行"

check-node:
	@node -e 'const v=process.versions.node.split(".").map(Number); \
	  if(v[0]!==24||v[1]<5){ \
	    console.error("\n[!] Node "+process.versions.node+" 不满足 Twenty 要求 (^24.5.0)。"); \
	    console.error("    用 nvm 修正: nvm install 24 && nvm use 24\n"); \
	    process.exit(1); \
	  } else { console.log("Node "+process.versions.node+" OK"); }'

# ---- 便捷维护 --------------------------------------------------------------
db-drop:
	@$(PSQL_SUPER) -c 'DROP DATABASE IF EXISTS "default";' -c 'DROP DATABASE IF EXISTS test;'
	@echo "已删除 default/test (重建: make db-setup db-reset)"

clean:
	rm -rf node_modules packages/*/node_modules
	@echo "已删除 node_modules (重装: make install)"

# ---- 跨机访问 (Tailscale) --------------------------------------------------
#  用法: make tailscale HOST=thinkpad   (或填 tailscale IP)
tailscale:
	@test -n "$(HOST)" || { echo "用法: make tailscale HOST=<主机名或IP>"; exit 1; }
	@sed '/^SERVER_URL=/d; /^FRONTEND_URL=/d; /^# SERVER_URL=/d' \
	   packages/twenty-server/.env > packages/twenty-server/.env.tmp \
	 && mv packages/twenty-server/.env.tmp packages/twenty-server/.env
	@printf 'SERVER_URL=http://%s:3000\nFRONTEND_URL=http://%s:3001\n' "$(HOST)" "$(HOST)" \
	   >> packages/twenty-server/.env
	@echo "SERVER_URL/FRONTEND_URL -> $(HOST);重启 make start 生效"
