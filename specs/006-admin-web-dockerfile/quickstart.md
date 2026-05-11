# Quickstart: admin-web Dockerfile

**Feature**: 006-admin-web-dockerfile
**Audience**: implementer（容器化 admin-web）+ operator / QA（image smoke 驗收）

兩部分：implementer 走兩段式 submodule commit；operator 跑 image build + 瀏覽器登入 smoke。

---

## Part A — Implementer Quickstart

### A.0 Pre-flight 健檢

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git status                    # 應在 outer branch 006-admin-web-dockerfile，clean
git submodule status          # admin-web 行首應為空格（clean），SHA = 7b167559

cd admin-web
git status -sb                # 應在 inner branch new-admin-base-web
git log --oneline -3          # feature 5 SHA 7b167559 應為最新

ls Dockerfile .dockerignore 2>&1 | head -3
# 預期：兩者都 "No such file or directory"
```

確認 build context 完整：
```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
ls deploy/nginx/default.conf    # 必存（feature 1 產出，由本 feature COPY）
ls deploy/compose.yaml          # 必存（feature 1 產出，line 106-125 已含 new-admin-base-web entry）
```

若任一檢查失敗 → 參照 CLAUDE.md §9 重建 worktree / 對齊 pin。

---

### A.1 改動順序（對應 1 個 inner commit —— scope 集中、無 phased rollout 需求）

#### Inner commit 1：新增 admin-web/Dockerfile + .dockerignore — MVP

**新增 `admin-web/Dockerfile`** —— multi-stage（builder + runtime）：

```dockerfile
# syntax=docker/dockerfile:1.7

#################################################
# Stage 1: builder — pnpm install + vite build
#################################################
ARG NODE_VERSION=22-alpine
ARG NGINX_VERSION=1.27-alpine
ARG PNPM_VERSION=10.5.0

FROM node:${NODE_VERSION} AS builder
ARG PNPM_VERSION

# admin-web Vite build args（per research.md R6；compose 從 .env 帶入）
ARG VITE_BASE_URL=/
ARG VITE_SERVICE_BASE_URL=/api
ARG VITE_APP_TITLE=NewAdmin
ARG VITE_AUTH_ROUTE_MODE=static
ARG VITE_STATIC_SUPER_ROLE=R_SUPER

# 把 ARG 升級為 ENV，讓 Vite build 時 process.env.VITE_* 拿得到（覆蓋 .env.prod 內 mock URL）
ENV VITE_BASE_URL=${VITE_BASE_URL} \
    VITE_SERVICE_BASE_URL=${VITE_SERVICE_BASE_URL} \
    VITE_APP_TITLE=${VITE_APP_TITLE} \
    VITE_AUTH_ROUTE_MODE=${VITE_AUTH_ROUTE_MODE} \
    VITE_STATIC_SUPER_ROLE=${VITE_STATIC_SUPER_ROLE}

WORKDIR /app

# Pin pnpm 版本 reproducibility
RUN npm install -g pnpm@${PNPM_VERSION}

# 先 COPY lockfile + package manifest（讓 deps 變動才重 install layer）
# build context = outer 倉根（compose.yaml line 108: context: ..）
COPY admin-web/package.json admin-web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# COPY 其餘 source（.dockerignore 已排除 node_modules / dist / .git）
COPY admin-web/ ./

# Vite production build → /app/dist
RUN pnpm build

#################################################
# Stage 2: runtime — nginx serve static + /api proxy
#################################################
FROM nginx:${NGINX_VERSION} AS runtime

# COPY built dist → nginx html dir
COPY --from=builder /app/dist /usr/share/nginx/html

# COPY 既有 nginx config（feature 1 deploy/nginx/default.conf，已含 SPA fallback + /api proxy + cache + gzip）
COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf

# OCI image labels
LABEL org.opencontainers.image.title="new-admin-base-web" \
      org.opencontainers.image.description="SoybeanAdmin frontend served by nginx" \
      org.opencontainers.image.source="https://github.com/miso168net/fork260509-soybean-admin"

# 對外暴露 80（compose 映射 ${WEB_PORT:-8080}:80）
EXPOSE 80

# 健康檢查（呼叫 nginx /health endpoint，由 default.conf 提供）
HEALTHCHECK --interval=15s --timeout=5s --retries=3 --start-period=5s \
  CMD wget --spider --quiet http://localhost/health || exit 1

# nginx 預設 CMD = ["nginx", "-g", "daemon off;"]，繼承 nginx:alpine
```

**新增 `admin-web/.dockerignore`**：

```dockerignore
# Dependencies & build output（每次 builder 重 install）
node_modules/
dist/
.turbo/

# VCS / IDE
.git/
.vscode/
.idea/

# Logs / coverage
*.log
coverage/

# OS metadata
.DS_Store
Thumbs.db

# Docker artefacts（self）
Dockerfile
.dockerignore
```

**驗**：
```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web
ls Dockerfile .dockerignore                    # 兩者皆應存在
grep -c "^FROM " Dockerfile                    # 應 ≥ 2（multi-stage）
grep -c "^node_modules" .dockerignore          # 應 ≥ 1
```

**inner commit 1**：
```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web
git add Dockerfile .dockerignore
git commit -m "$(cat <<'EOF'
feat(admin-web): 新增 multi-stage Dockerfile + .dockerignore

- builder stage：node:22-alpine + pnpm@10.5.0 + frozen-lockfile install + vite build → /app/dist
- runtime stage：nginx:1.27-alpine，COPY dist 到 html dir、COPY deploy/nginx/default.conf
- 6 個 VITE_* build args（VITE_SERVICE_BASE_URL=/api 等）以 ARG+ENV 形式覆蓋 .env.prod 內 mock URL
- HEALTHCHECK wget --spider /health（依 deploy/nginx/default.conf 內既有 location）

build context = outer 倉根（compose.yaml line 108 既定）；無 cross-repo 改動；不夾帶 admin-api /health（feature 6 prereq）。
EOF
)"
```

---

### A.2 整套 build verify

⚠️ **R5 未補上之前**（admin-api 尚無 /health），整套 stack `docker compose up -d` 會卡在 admin-api healthcheck 失敗 → admin-web 不會啟動。但**單一 image build 可獨立完成**：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509

# 單獨 build admin-web image（不啟容器、不需 admin-api healthy）
docker compose build new-admin-base-web

# 驗 image size
docker images new-admin-base-web --format '{{.Repository}}:{{.Tag}} {{.Size}}'
# 預期：≤ 150 MB（SC-705）

# 驗 runtime 無 node / node_modules / src
docker run --rm --entrypoint sh new-admin-base-web -c '
  which node || echo "✓ NO_NODE"
  ls /usr/share/nginx/html | head -3
  ls /usr/share/nginx/html | grep -E "^(src|node_modules)$" && echo "✗ FOUND SOURCE" || echo "✓ NO SOURCE"
'

# 驗 nginx config 有 SPA fallback + /api proxy
docker run --rm --entrypoint sh new-admin-base-web -c '
  grep -E "try_files|proxy_pass" /etc/nginx/conf.d/default.conf
'
```

對應 SC-705 / SC-708 / R4。

---

### A.3 inner push

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web
git push origin new-admin-base-web
# 應成功推到 miso168net/fork260509-soybean-admin
```

---

### A.4 outer commit（第二段）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer
git status
# 應看到：
#   modified content: admin-web (new commits)

SHORT_SHA=$(cd admin-web && git rev-parse --short HEAD)
git add admin-web

git commit -m "$(cat <<EOF
chore(submodule): bump admin-web 到 $SHORT_SHA: feature 7 Dockerfile + .dockerignore

1 個 inner commit（admin-web/ worktree）：
- feat(admin-web): 新增 multi-stage Dockerfile + .dockerignore

完成 admin-web 容器化（multi-stage build：node + pnpm@10.5.0 → vite build → nginx:1.27-alpine
serve）。Dockerfile 從 build context outer 倉根 COPY deploy/nginx/default.conf，VITE_*
build args 對齊 deploy/compose.yaml line 110-115。

動態驗證（docker compose up + 瀏覽器登入）依 admin-api /health endpoint 補上 + feature 6
merge 後執行（research.md R5 / spec.md A8）。
EOF
)"
# **不**直接 git push — 依 CLAUDE.md §5 全域 push 確認規則，等使用者授權
```

---

## Part B — Operator Quickstart（image build + 瀏覽器登入 smoke）

### B.0 前置

**R5 prereq**：admin-api 必須有 `/health` endpoint —— 在 feature 6 (`dockerfile-envsubst`) 補上或獨立 micro-feature 處理。在此之前以下流程會卡在 admin-api healthcheck 步驟。

```bash
# 確認 admin-api /health 已實作
grep -rn '"/health"' admin-api/server/router/ admin-api/server/api/ 2>/dev/null | head -3
# 應 ≥ 1 命中；若 0 hits 代表 R5 未補，操作流程到 B.2 會卡住
```

### B.1 全 stack 啟動（依賴 R5 已補）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/deploy

# 複製 .env.example → .env 並填寫必要 secrets（POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET）
cp -n .env.example .env
$EDITOR .env       # 填 secrets

# 啟整套 prod stack
docker compose up -d
# 等所有 service healthy（postgres/redis/migration/new-admin-rust-api/new-admin-base-web）

docker compose ps
# 5 service 應全 healthy（new-admin-base-web 應暴露 :8080）
```

### B.2 happy path（US1 P1）

1. 瀏覽器訪問 `http://localhost:8080`
2. **預期**：admin-web login 頁面在 1 秒內顯示（SC-702）
3. 輸入 `Soybean / 123456`，點 login
4. DevTools Network 觀察：請求應走 `http://localhost:8080/api/auth/login`（同源），收 200
5. **預期**：dashboard 出現、ROLE_SUPER 完整 menu tree（SC-703）
6. 在 URL bar 直接輸入 `http://localhost:8080/home/analysis`，Enter
7. **預期**：頁面正常 render，非 404（SC-704，FR-707 SPA fallback）

### B.3 backend down 場景（US1 acceptance 5）

```bash
docker compose stop new-admin-rust-api
# 等 30 秒，admin-api container 變 stopped
```

回瀏覽器，重新整理 dashboard。觀察：
1. **預期**：任何 API 請求收到 `502 Bad Gateway`（FR-713，contract §4 row 1）
2. UI 應顯示友善錯誤訊息，不是空白頁、不 crash

恢復：
```bash
docker compose start new-admin-rust-api
```

### B.4 image hygiene 驗（US2 P2）

```bash
# 1. image size ≤ 150 MB（SC-705）
docker images new-admin-base-web --format '{{.Size}}'

# 2. final layer 無 source / node_modules / tsconfig（SC-708）
docker run --rm --entrypoint sh new-admin-base-web -c 'ls /' | grep -E "src|node_modules|tsconfig" && echo "✗" || echo "✓"

# 3. cache hit 重建 < 30 秒（SC-706）
time docker compose build new-admin-base-web
# 第一次：cold build
time docker compose build new-admin-base-web
# 第二次：應 ≤ 30 秒（全 layer cache hit）

# 4. 修 src 後 rebuild：install layer 應 hit cache
echo "// touch" >> /tmp/admin-web-src-touch  # 模擬 src 變動 — 實際請改一個 src 內檔
# 模擬：cd admin-web && touch src/App.vue
time docker compose build new-admin-base-web
# install layer 應 hit cache（不重跑 pnpm install）；build layer 重跑
```

---

## 不在本 Quickstart 範圍

- admin-api `/health` endpoint 實作 → 屬 feature 6 dockerfile-envsubst 或獨立 micro-feature
- TLS / HTTPS / WAF / CDN → 外層 LB
- arm64 多架構 build → future enhancement
- image push / tag scheme → A7 explicitly out of scope
- WebSocket 支援 → 預設無需（R3 verify）
