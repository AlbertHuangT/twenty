# 把 Twenty 跑起来（本地开发环境搭建记录）

记录在这台 Mac 上从零把 Twenty 跑起来的完整步骤。其中标注 **【本机特殊】** 的部分是为了绕过本机网络问题（IPv6 损坏），普通网络环境可跳过。

环境：macOS (Apple Silicon)、已装 Homebrew。

---

## TL;DR — 已经装好后，每次启动只需

```bash
# 在仓库根目录
eval "$(fnm env)"                                              # 切到 Node 24
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"        # 让 psql 可用
export NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"  # 【本机特殊】强制 IPv4
export YARN_NPM_REGISTRY_SERVER=https://registry.npmmirror.com # 国内镜像（可选）

# 确保数据库在跑（brew services，开机自启，一般已经在跑）
brew services start postgresql@16
brew services start redis

# 启动前端 + 后端 + worker
node .yarn/releases/yarn-4.13.0.cjs start
```

启动后访问：
- 前端：http://localhost:3001 （点 “Continue with Email” 用预填测试账号登录）
- 后端：http://localhost:3000 （健康检查 `/healthz`）

> 注：因为没把环境变量写进 `~/.zshrc`，每开一个新终端都要先执行上面那几条 `export`。

---

## 组件构成

Twenty 是 Nx monorepo，跑起来需要 3 个进程 + 2 个数据服务：

| 组件 | 说明 | 地址 |
|------|------|------|
| `twenty-front` | React 前端 | http://localhost:3001 |
| `twenty-server` | NestJS 后端 | http://localhost:3000 |
| worker | 后台异步任务处理 | — |
| PostgreSQL 16 | 主数据库 | localhost:5432 |
| Redis | 缓存 / 队列 | localhost:6379 |

`yarn start` 一条命令拉起前 3 个；数据库和 Redis 由 brew 常驻。**不需要 Docker**（Docker 只是提供 pg/redis 的一种方式）。

---

## 工具链要求

- **Node**：`^24.5.0`（仓库 `.nvmrc` = 24.16.0）。系统自带的更高版本（如 26）不兼容。
- **Yarn**：4.x。仓库已把二进制提交在 `.yarn/releases/yarn-4.13.0.cjs`，直接 `node` 调用即可，**不必依赖 corepack 联网下载**。
- **npm 被禁用**（`package.json` 里 `"npm": "please-use-yarn"`），一律用 `yarn` / `npx nx`。

---

## 首次搭建步骤

### 1. Node 24（用 fnm 管理）

```bash
brew install fnm
eval "$(fnm env)"
fnm install 24.16.0
fnm default 24.16.0
node -v          # 应显示 v24.16.0
```

### 2. PostgreSQL 16 + Redis（brew，无 Docker）

```bash
brew install postgresql@16 redis
brew services start postgresql@16      # 后台常驻 + 开机自启
brew services start redis

# postgresql@16 是 keg-only，二进制不在默认 PATH，先指向它
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"

# Twenty 默认连接是 postgres/postgres，需建这个超级用户并设密码
createuser -s postgres
psql postgres -c "ALTER USER postgres PASSWORD 'postgres';"

# 验证
PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -c "SELECT 1;"
```

> Twenty 的默认连接串在 `packages/twenty-server/.env`：
> `PG_DATABASE_URL=postgres://postgres:postgres@localhost:5432/default`、`REDIS_URL=redis://localhost:6379`

### 3. 【本机特殊】网络问题与修复

**现象**：`yarn install` / corepack / 任何 Node 发起的网络请求都 `ETIMEDOUT`，但 `curl` 同样的地址却正常。

**根因**：本机 IPv6 损坏，且部分 Cloudflare IPv4 被运营商黑洞。`curl` 会快速轮询找到可用 IP，而 Node 的 fetch/undici 会卡在不可达地址上超时。

**修复**：强制 Node 只走 IPv4，并改用国内 npm 镜像。

```bash
export NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"
export YARN_NPM_REGISTRY_SERVER=https://registry.npmmirror.com
```

> 关键是 `--no-network-family-autoselection`，仅 `ipv4first` 不够。
> 普通网络环境不需要这两条。

### 4. 安装依赖

```bash
eval "$(fnm env)"
export NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"   # 【本机特殊】
export YARN_NPM_REGISTRY_SERVER=https://registry.npmmirror.com                          # 【本机特殊】
node .yarn/releases/yarn-4.13.0.cjs install
```

注意：
- 这是大 monorepo，安装较慢（本机约 40 分钟，仅「解析」阶段就花 19 分钟），因为 `.yarnrc.yml` 开了 `enableHardenedMode`（供应链审计）+ `npmMinimalAgeGate`。
- 过程中大量 `YN0060`（peer dependency）/ `YN0002`（doesn't provide）/ build scripts disabled 都是**正常警告，不是错误**。

### 5. 初始化数据库（建库 + 迁移）

仓库自带一键脚本，会自动检测到 pg/redis 已在跑 → 跳过 Docker，建 `default`/`test` 库、拷 `.env`、跑迁移：

```bash
eval "$(fnm env)"
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"        # 脚本要用 psql/pg_isready 检测
export NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"   # 【本机特殊】
export YARN_NPM_REGISTRY_SERVER=https://registry.npmmirror.com                          # 【本机特殊】
bash packages/twenty-utils/setup-dev-env.sh
```

看到 `Dev environment ready.` 即成功。

> 该脚本其他用法：`--down` 停服务、`--reset` 清数据重来、`--docker` 强制用 Docker。

### 6. 启动

见上面的 **TL;DR**。验证：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/healthz   # 期望 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001/          # 期望 200
```

---

## 可选：让配置长期生效

不想每次手动 `export`，可把以下三行加进 `~/.zshrc`（本机用，团队仓库不要提交）：

```bash
eval "$(fnm env --use-on-cd)"   # 进入带 .nvmrc 的目录自动切 Node 版本
export NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection"   # 【本机特殊】
export YARN_NPM_REGISTRY_SERVER=https://registry.npmmirror.com
```

---

## 常见问题

- **新终端跑 `yarn start` 报错 / node 版本不对**：忘了 `eval "$(fnm env)"`，node 退回系统版本。
- **`yarn install` 卡住超时**：缺少【本机特殊】的 IPv4 环境变量。
- **`yarn: command not found`**：直接用 `node .yarn/releases/yarn-4.13.0.cjs <cmd>`，不依赖 corepack。
- **脚本说找不到数据库**：`postgresql@16` keg-only，记得 `export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"`。
- **应用停了**：之前是挂在临时会话后台，会话结束就停；自己跑 `node .yarn/releases/yarn-4.13.0.cjs start` 即可。
