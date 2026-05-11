# Phase 1 Data Model: admin-web Dockerfile

**Feature**: 006-admin-web-dockerfile
**Status**: Completed

本 feature 是**部署 artefact**，沒有 runtime data model（無 DB schema、無 API request/response struct）。本檔列「artefact entities」—— 即本 feature 產出與引用的 4 個檔案級實體。

---

## Entity 1: Dockerfile

- **Path**: `admin-web/Dockerfile`（admin-web/ submodule 根，由本 feature **新增**）
- **Role**: Multi-stage build 定義；產出 `new-admin-base-web:latest` image
- **Stages**:
  - **builder** (FROM `node:22-alpine`)：install pnpm@10.5.0 → COPY package.json + pnpm-lock.yaml → `pnpm install --frozen-lockfile` → COPY source → `pnpm build` → 輸出 `/app/dist`
  - **runtime** (FROM `nginx:1.27-alpine`)：COPY `--from=builder /app/dist` → `/usr/share/nginx/html`；COPY `deploy/nginx/default.conf`（從 build context outer 根）→ `/etc/nginx/conf.d/default.conf`；EXPOSE 80；HEALTHCHECK；CMD nginx
- **Build context**: outer 倉根 (`..` from `admin-web/`)；compose.yaml line 108 已設 `context: ..`
- **Build args** (per R6 mapping)：
  - `PNPM_VERSION=10.5.0`（toolchain）
  - `VITE_BASE_URL=/`
  - `VITE_SERVICE_BASE_URL=/api`
  - `VITE_APP_TITLE=NewAdmin`
  - `VITE_AUTH_ROUTE_MODE=static`
  - `VITE_STATIC_SUPER_ROLE=R_SUPER`
- **Output image labels** (建議)：
  - `org.opencontainers.image.source=https://github.com/miso168net/fork260509-soybean-admin`
  - `org.opencontainers.image.title=new-admin-base-web`
  - `org.opencontainers.image.description=SoybeanAdmin frontend served by nginx`

---

## Entity 2: .dockerignore

- **Path**: `admin-web/.dockerignore`（admin-web/ submodule 根，由本 feature **新增**）
- **Role**: build context 排除清單；減少 docker build 傳輸量 + 避免 stale node_modules 污染 builder layer
- **Excludes**:
  - `node_modules/`
  - `dist/`
  - `.git/`
  - `.vscode/`
  - `.idea/`
  - `*.log`
  - `coverage/`
  - `.turbo/`
  - `.DS_Store`
  - `Dockerfile`（self，不需傳給自己）
  - `.dockerignore`（self）
- **不**排除：`.env*`、`build/`（Vite plugins 目錄）、`src/`、`public/` —— 這些 Vite build 需要

---

## Entity 3: nginx config（既有，本 feature 引用）

- **Path**: `deploy/nginx/default.conf`（feature 1 既有）
- **Role**: SPA fallback + `/api/*` reverse proxy + static cache + gzip；被 Dockerfile runtime stage COPY 進 image
- **本 feature 不修改**，只在 Dockerfile COPY 引用
- **既有設定關鍵點**（已 read verify）：
  - `listen 80;`
  - SPA: `try_files $uri $uri/ /index.html;`
  - API: `proxy_pass http://new-admin-rust-api:10001/;` (strip /api/)
  - Health: `location = /health { return 200 "ok\n"; }`（給 admin-web 自身 HEALTHCHECK 用）
  - Static cache: `expires 30d; immutable`
  - gzip on

---

## Entity 4: compose service entry（既有，本 feature 不修改）

- **Path**: `deploy/compose.yaml` 之 `services.new-admin-base-web` block (line 106-125)
- **Role**: 把 admin-web image 註冊進 compose；對外暴露 `${WEB_PORT:-8080}:80`；`depends_on: new-admin-rust-api: service_healthy`
- **本 feature 不修改**（feature 1 已寫好）
- **dev override**: `deploy/compose.dev.yaml` line 29-30 — `new-admin-base-web.profiles: ["never"]`（dev 模式 admin-web 走 host vite，不啟此 service）

---

## Relationships

```
admin-web/Dockerfile  ──[COPY ../deploy/nginx/default.conf]──→  nginx config
        ▲
        │ build context = outer root (..)
        │
admin-web/.dockerignore  (gates what's sent to builder)
        ▲
        │
deploy/compose.yaml: new-admin-base-web.build.dockerfile = admin-web/Dockerfile
                                     build.context = ..
                                     build.args = {VITE_BASE_URL, VITE_SERVICE_BASE_URL, ...}
                                     ports = ["${WEB_PORT:-8080}:80"]
                                     depends_on = {new-admin-rust-api: service_healthy}
```

**Key invariant**: build context (outer 根) **必須**包含 `deploy/nginx/default.conf` 與 `admin-web/` 全部 source；`.dockerignore` 不能把 `deploy/` 排掉。

---

## Validation rules

| Rule | Verification |
|------|--------------|
| Dockerfile 必有 builder + runtime 兩 stage | `grep -c "^FROM " admin-web/Dockerfile` 應 ≥ 2 |
| Runtime 不含 node | `docker run --rm --entrypoint sh new-admin-base-web -c 'which node \|\| echo NO_NODE'` 應 echo NO_NODE |
| .dockerignore 排除 node_modules | `grep -q "^node_modules" admin-web/.dockerignore` |
| nginx config 從 outer 倉根 COPY | `grep -E "COPY.*deploy/nginx" admin-web/Dockerfile` 應 hit |
| Final image size ≤ 150 MB | `docker images new-admin-base-web --format '{{.Size}}'` |
| HEALTHCHECK 在 Dockerfile | `grep -q "^HEALTHCHECK" admin-web/Dockerfile` |
