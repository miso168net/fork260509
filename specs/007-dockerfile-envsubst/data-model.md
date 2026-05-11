# Phase 1 Data Model: admin-api envsubst template

**Feature**: 007-dockerfile-envsubst
**Status**: Completed

本 feature 是部署 artefact 改造，無 runtime data model。列 6 個 artefact entities。

---

## Entity 1: `admin-api/server/resources/application.yaml.tpl`（新增）

- **Path**: `admin-api/server/resources/application.yaml.tpl`
- **Action**: **新增**（取代既有 `application.yaml`）
- **Role**: envsubst template；image 內唯讀；entrypoint 階段讀此檔渲染為 `application.yaml`
- **內容**（diff vs 既有 application.yaml）：
  ```yaml
  database:
      url: "${APP_DATABASE_URL}"                  # was hardcode postgres://...@pgbouncer:6432/...
      max_connections: ${APP_DATABASE_MAX_CONNECTIONS:-10}
      min_connections: 1
      connect_timeout: 30
      idle_timeout: 600
  server:
      host: "${APP_SERVER_HOST:-0.0.0.0}"
      port: ${APP_SERVER_PORT:-10001}
  jwt:
      jwt_secret: "${APP_JWT_JWT_SECRET}"         # was hardcode "soybean-admin-rust"
      issuer: "${APP_JWT_ISSUER}"                 # was hardcode "https://github.com/ByteByteBrew/..."
      expire: ${APP_JWT_EXPIRE:-7200}
  redis:
      mode: single
      url: "${APP_REDIS_URL}"                     # was hardcode "redis://:123456@redis:6379/10"
  ```
- **占位符規則**：
  - **無 default** (`${APP_VAR}`)：secret 類、entrypoint 預先驗證必設（FR-605）
  - **有 default** (`${APP_VAR:-fallback}`)：non-secret 設定，envsubst 支援 default expansion

---

## Entity 2: `admin-api/server/resources/application.yaml`（刪除）

- **Action**: **刪除**（per constitution §II「server/resources/ 不再有 application.yaml」）
- **影響**：dev mode（`cargo run`）改讀 `application-test.yaml`（既 main.rs 之 debug_assertions 分支）；prod 由 entrypoint 渲染產生
- **VCS**: `git rm` 從 admin-api 倉移除

---

## Entity 3: `admin-api/entrypoint.sh`（新增）

- **Path**: `admin-api/entrypoint.sh`
- **Action**: **新增**
- **Role**: container 啟動時被 Dockerfile ENTRYPOINT 呼叫；責 4 件事：
  1. **Required env 驗證**（FR-605）：`APP_DATABASE_URL` / `APP_REDIS_URL` / `APP_JWT_JWT_SECRET` / `APP_JWT_ISSUER` 不可空字串或未設
  2. **Sentinel rejection**（FR-606）：`APP_JWT_ISSUER` 不可等於 3 個 sentinel 之任一
  3. **envsubst render**：`envsubst < application.yaml.tpl > application.yaml`
  4. **exec server**：`exec /bin/server`（透過 exec，PID 1 換成 server，signal 正確傳遞）
- **Shell**: sh / busybox ash（alpine 預設、無 bash dep）
- **Exit codes** per [contracts/entrypoint-contract.md](./contracts/entrypoint-contract.md)

---

## Entity 4: `admin-api/Dockerfile`（修改）

- **Path**: `admin-api/Dockerfile`
- **Action**: 修改 runtime stage
- **Diff 概要**：
  - **新增** `apk add` 加 `gettext`（提供 envsubst）
  - **COPY 改名**：`application.yaml` → `application.yaml.tpl`
  - **新增** `COPY --chown=...:... entrypoint.sh /usr/local/bin/entrypoint.sh` + `chmod +x`
  - **新增** `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`
  - **保留** `CMD ["/bin/server"]`（entrypoint exec 時 args 由 CMD 提供）

---

## Entity 5: `deploy/compose.yaml`（修改）

- **Path**: `deploy/compose.yaml`
- **Action**: 修改既有 services 區段
- **Diff 概要**：
  - **postgres service**：healthcheck `start_period: 30s`（per 1-M1，避免 cold init 誤判 unhealthy）
  - **redis service**：healthcheck 改 `CMD-SHELL` form + `$$REDIS_PASSWORD` env interpolation（per 1-I1）
  - **new-admin-rust-api service**：APP_* env vars 已是 1-I4 hotfix 加 APP_ 前綴的版本，本 feature **不需再改 env names**；但需驗證所有 secret env 已用 `${VAR:?must set VAR}` required gate（per FR-610）
- **不動**: ports、networks、volumes、image tag、build context

---

## Entity 6: `deploy/nginx/default.conf`（修改）

- **Path**: `deploy/nginx/default.conf`
- **Action**: 修改既有 nginx config
- **Diff 概要**：
  - `/api/` proxy 區段確認含 `proxy_set_header Upgrade $http_upgrade;` 與 `proxy_set_header Connection "upgrade";`（per 1-M2 WebSocket prep）
  - gzip 區段補 `gzip_proxied any;`（per 1-M3，確保 reverse-proxy response 也被壓縮）
  - inline 註解小漂移修（per 1-M4/M5）
- **驗證後不重 build admin-web image**：default.conf 是 admin-web image build 時 COPY 進去的，故需 rebuild admin-web image 才生效

---

## Entity 7: `deploy/.env.example`（修改）

- **Path**: `deploy/.env.example`
- **Action**: 修改 placeholder 樣板
- **Diff 概要**：
  - `APP_JWT_ISSUER` 樣板值改為 `change-me-issuer-url`（per FR-611；當前是 GitHub URL placeholder 容易誤當合法 default）
  - `.env.example` doc 段補：「APP_JWT_ISSUER 之 sentinel placeholder 清單」說明 + redis main argv password 暴露限制
  - 其他必要 env 加 `# 必填` 標註

---

## Relationships

```
.tpl  ──[entrypoint envsubst render]──→  application.yaml (runtime, in /app/server/resources/)
        ▲                                       ▲
        │                                       │
admin-api/Dockerfile COPY                  admin-api/bin reads (hardcode 相對 CWD 路徑)
        │
        ▼
ENTRYPOINT entrypoint.sh ──[validate envs + sentinel reject + envsubst + exec]──→ /bin/server

deploy/compose.yaml ─[APP_* env]──→ container env ──[entrypoint reads + envsubst substitutes]
deploy/nginx/default.conf ─[admin-web image build COPY]──→ admin-web nginx config
deploy/.env.example ─[operator copies to .env]──→ compose 注入
```

---

## Validation rules

| Rule | Verification |
|------|--------------|
| .tpl 存在 + .yaml 不存在 | `ls admin-api/server/resources/` 應見 `.tpl`、不見 `.yaml` |
| .tpl 內無 hardcoded prod values | `grep -E "pgbouncer\|soybean-admin-rust\|ByteByteBrew\|123456" application.yaml.tpl` 應 0 命中 |
| entrypoint.sh 是 executable | `ls -la admin-api/entrypoint.sh` 應有 +x |
| Image 內無 application.yaml | `docker run --rm new-admin-rust-api:latest ls /app/server/resources/` 不含 `application.yaml`（只有 `.tpl` 與其他靜態 resource） |
| Required env 預檢生效 | 故意 unset `APP_JWT_JWT_SECRET` 啟動 → container exit 非 0 + stderr 含 "FATAL" |
| Sentinel rejection 生效 | `APP_JWT_ISSUER=https://github.com/your-org/new-admin` 啟動 → container exit 非 0 + stderr 提示 placeholder |
| Rendered yaml 正確 | container 啟動後 `docker exec ... cat /app/server/resources/application.yaml` → 看到實際 env 值 |
| redis healthcheck argv 不含明文 password | `docker top redis-container` → `redis-cli -a "$REDIS_PASSWORD"` 字面字串（不展開） |
| postgres start_period ≥ 30s | `docker inspect postgres-container` healthcheck 段 |
| nginx config 完整 | image build 內 grep `Upgrade`、`gzip_proxied any` 命中 |
