# Contract: admin-web Docker Image

**Image tag**: `new-admin-base-web:latest`
**Built from**: `admin-web/Dockerfile` with build context = outer 倉根

本 image 是 prod stack 對外唯一入口。Contract 定義 image 之外部介面（哪些 port、哪些路徑、哪些 build args、哪些 env vars、健康檢查介面）—— 是 compose / 上層 LB / operator 與 image 的契約。

---

## 1. Network 介面

### 1.1 Listening ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | HTTP | nginx 監聽；container 內固定為 80（compose port mapping `${WEB_PORT:-8080}:80` 暴露給 host） |

container **僅**監聽 80；不開 https（TLS 終結在外層 LB，本 stack 範圍外）。

### 1.2 Exposed HTTP routes

| Route | Method | Behavior |
|-------|--------|----------|
| `/` | GET | nginx serve `/usr/share/nginx/html/index.html`（Vue SPA 入口） |
| `/*` (任意路徑) | GET | nginx 嘗試 `try_files $uri $uri/ /index.html` — static asset hit 即回；否則 fallback 到 SPA index（vue-router history mode） |
| `/api/*` | ANY | reverse proxy 到 `http://new-admin-rust-api:10001/`（strip `/api/` 前綴）；保留 Host / Authorization / X-Forwarded-* headers；timeouts 60s read/send |
| `/health` | GET | return `200 "ok\n"`（healthcheck endpoint，access_log off） |

### 1.3 Upstream dependency

- `new-admin-rust-api:10001`（compose service name）—— 必須在同 docker network (`admin-net`)
- 若 upstream 不可達：nginx 回 `502 Bad Gateway`（per nginx default proxy 行為）
- **不**直接連 postgres / redis；那是 admin-api 的責任

---

## 2. Build 介面

### 2.1 Build args（compose `build.args` 注入）

| Arg | Default in Dockerfile | Compose 注入值 | Vite 中使用 |
|-----|------------------------|----------------|--------------|
| `PNPM_VERSION` | `10.5.0` | （不傳，用預設） | toolchain only |
| `VITE_BASE_URL` | `/` | `/` | Vite base config |
| `VITE_SERVICE_BASE_URL` | `/api` | `/api` | axios baseURL（admin-web request 走同源） |
| `VITE_APP_TITLE` | `NewAdmin` | `${VITE_APP_TITLE:-NewAdmin}` | HTML `<title>` + UI brand |
| `VITE_AUTH_ROUTE_MODE` | `static` | `${VITE_AUTH_ROUTE_MODE:-static}` | router guard 行為 |
| `VITE_STATIC_SUPER_ROLE` | `R_SUPER` | `${VITE_STATIC_SUPER_ROLE:-R_SUPER}` | static auth mode super role name |

每個 VITE_* ARG 後接 `ENV VITE_* = $VITE_*`，讓 Vite build 時 `process.env.VITE_*` 拿到值（覆蓋 `.env.prod` 內 mock URL —— 見 research.md R6）。

### 2.2 Build context invariants

- Build context = outer 倉根（compose.yaml line 108: `context: ..`）
- `.dockerignore` 在 admin-web/ 內，**僅**排除 admin-web/ 內無用檔（node_modules、dist 等）
- Dockerfile COPY path **必須**對應 outer 倉根結構，例如：
  - `COPY admin-web/package.json admin-web/pnpm-lock.yaml ./`
  - `COPY admin-web/ ./`（builder source）
  - `COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf`（runtime nginx config）

---

## 3. Runtime 介面

### 3.1 Filesystem 結構（runtime container 內）

| Path | Purpose | Owner |
|------|---------|-------|
| `/usr/share/nginx/html/` | static assets (dist) | nginx default web root |
| `/usr/share/nginx/html/index.html` | SPA entry | (same) |
| `/etc/nginx/conf.d/default.conf` | server block config | nginx |
| `/etc/nginx/nginx.conf` | main nginx config | nginx (inherited from nginx:1.27-alpine) |
| `/var/log/nginx/access.log` | access log | nginx (symlinked to stdout per official image) |
| `/var/log/nginx/error.log` | error log | nginx (symlinked to stderr per official image) |

### 3.2 Environment variables（runtime 階段）

container runtime **不需**任何 env vars —— VITE_* 已 baked 進 dist。
container 預設用 `TZ` env（compose.yaml 注入，nginx 用於 access log timestamp）。

### 3.3 健康檢查

- **Dockerfile HEALTHCHECK**：`HEALTHCHECK --interval=15s --timeout=5s --retries=3 --start-period=5s CMD wget --spider --quiet http://localhost/health || exit 1`
- nginx `/health` route 在 `deploy/nginx/default.conf` line 9-13 已定義，return `200 "ok\n"`
- Compose `new-admin-base-web` service **不**另設 healthcheck（依賴 Dockerfile HEALTHCHECK），per compose.yaml line 125 註解

### 3.4 Logging contract

- nginx access log → stdout（nginx:alpine official image 已 symlink）
- nginx error log → stderr
- `docker logs new-admin-base-web` 可看完整 access + error log
- access_log **不**寫到本機 file（避免容器 fs growth）

---

## 4. 失敗模式契約

| Scenario | Image 行為 |
|----------|-----------|
| `new-admin-rust-api` 容器 down | nginx 對 `/api/*` 請求回 `502 Bad Gateway`（不 crash） |
| `new-admin-rust-api` 響應慢 > 60s | nginx 對 `/api/*` 請求回 `504 Gateway Timeout` |
| Direct nav 到 `/non-existent-route` | nginx fallback `/index.html` → Vue router 處理為「not-found page」 |
| Static asset 不存在（如 `/missing.js`） | nginx try_files fallback `/index.html`（注意：這會把 missing asset 變成 200 + html 內容，可能造成 JS parse error；vite hash filename 保證 build 後 assets 一致，不會 hit） |
| nginx process crash | container exit；docker `restart: unless-stopped`（compose.yaml line 117）會自動重啟 |
| `/health` 不可達（理論上不會） | Docker HEALTHCHECK 連續 3 次失敗 → container marked unhealthy；compose depends_on chain 受影響但因為**無**下游 depends on admin-web，所以沒實質衝擊 |

---

## 5. 不在本契約範圍

- TLS / HTTPS（外層 LB 處理）
- CDN / cache 層（外層）
- WAF / rate limiting（外層）
- 多語系 base URL（如 `/en/` `/zh/` 分區）—— Vue i18n 走 client-side route，不需 nginx 額外設定
- Image push / tag scheme（A7 explicitly out of scope）
- 多架構 build（amd64 only）
