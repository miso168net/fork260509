# Phase 0 Research: admin-web Dockerfile

**Feature**: 006-admin-web-dockerfile
**Date**: 2026-05-11
**Status**: Completed

把 spec.md「待驗證 R1-R7」+ Q1 clarify decision 落地。所有 evidence 透過 read 既有 admin-web / admin-api / deploy 檔案取得；implementation 階段不需要再額外探勘。

---

## R1：pnpm 版本 pin 策略

- **Decision**: Dockerfile builder stage 使用 `RUN npm install -g pnpm@10.5.0` pin 到精確 minor（10.5.x latest patch）
- **Rationale**:
  - admin-web/package.json **沒**設 `packageManager` 欄位（無 corepack pin）
  - 但 `engines.pnpm: ">=10.5.0"`（已驗證 via `grep "pnpm"` package.json）
  - 不依賴 corepack：corepack 在 Node 22 已預載但版本 mismatch 處理較弱；直接 `npm install -g pnpm@10.5.0` 邏輯最簡單透明
  - Pin 到 10.5.0 而非 latest：reproducibility（feature 5 也是 pnpm 10.x 測過、無 11.x approve-builds gate 問題）
- **Alternatives considered**:
  - `corepack enable + corepack prepare pnpm@10.5.0 --activate`：官方推薦但 boot time 多 0.5-1s；之後 corepack 行為改變風險
  - `npm install -g pnpm@latest`：每次 build hit cache 都可能拉新 minor，違反 reproducibility 原則
  - `pnpm@11`：feature 5 已遇 11.0.8 approve-builds gate 問題，避開
- **Implementer note**: 寫成 ARG 方便將來升 minor — `ARG PNPM_VERSION=10.5.0`

---

## R2：Vite 輸出位置（outDir）

- **Decision**: ✅ **預設 `dist/`** —— Dockerfile builder stage 完成 `pnpm build` 後 COPY `/app/dist` 到 runtime stage 的 nginx html dir
- **Rationale**:
  - `admin-web/vite.config.ts` 之 `build:` block 內**沒有顯式 outDir** 設定（已 grep verify）
  - Vite 預設 outDir = `dist/`（per Vite docs，無 config override 即用預設）
  - `pnpm build` 解析為 `vite build --mode prod`（package.json scripts.build）
- **Alternatives considered**: 若未來 vite config 改 outDir（如 `build/`），須同步改 Dockerfile COPY path；列為 future maintenance note
- **Implementer note**: Dockerfile 寫死 `COPY --from=builder /app/dist /usr/share/nginx/html`

---

## R3：WebSocket / SSE 使用

- **Decision**: ✅ admin-web 預設**不**用 WebSocket / SSE / socket.io —— nginx config 不需要為 admin-web 特別加 Upgrade headers
- **Rationale**: `grep -rln "WebSocket\|EventSource\|socket\.io" admin-web/src/` → **0 命中**
- **Implementer note**: 既有 `deploy/nginx/default.conf` 已預備 `proxy_set_header Upgrade $http_upgrade` + `proxy_set_header Connection "upgrade"`（line 26-27），無害留著。將來若 admin-api 加 SSE / WS endpoint，這些 header 已就位。

---

## R4：feature 1 既有 nginx service 之關係（Q1 已敲定）

- **Decision**: ✅ **Option A 合併**（§Clarifications Q1）—— admin-web image 內 nginx = compose 唯一 nginx；feature 1 既有設計**已**對齊此決策
- **Verification (from reading feature 1 產出)**:
  - `deploy/compose.yaml` 沒有獨立的 `nginx` service entry —— 只有：`postgres / redis / migration / new-admin-rust-api / new-admin-base-web` 5 個
  - `new-admin-base-web` service entry (line 106-125) 直接指向 `admin-web/Dockerfile`、build context 是 outer 倉根 `..`
  - `deploy/nginx/default.conf` 是個 stand-alone config 檔，明顯是為了被 admin-web image COPY 進 runtime stage（不是給 stand-alone nginx service 用）
  - feature 1 compose.yaml line 125 註解：「nginx HEALTHCHECK 由 admin-web/Dockerfile 自帶（feature 7 處理）」—— 明確把 nginx 行為交給 admin-web image
- **結論**: Q1 clarify 是**confirm** feature 1 既定設計，不是新決策。feature 7 直接 fulfil 既有 contract。
- **Implementer note**: Dockerfile runtime stage 從 build context 用 `COPY ../deploy/nginx/default.conf /etc/nginx/conf.d/default.conf`（build context = outer 倉根，path 是相對 outer 倉根的 `deploy/nginx/default.conf`）

---

## R5：admin-api `/health` endpoint 缺失（**critical finding**）

- **Decision**: ❌ admin-api **沒有** `/health` endpoint —— 列為 feature 6 prereq；feature 7 dynamic acceptance 必須在 /health 補上後才能執行
- **Rationale**:
  - `grep -rn '"/health"' admin-api/server/` → **0 命中**
  - `admin-api/server/bin/src/main.rs` 之 `initialize_admin_router()` 包含的 12 個 routes（sys_access_key、sys_authentication、sys_domain、sys_endpoint、sys_login_log、sys_menu、sys_operation_log、sys_organization、sys_role、sys_sandbox、sys_user、mod）**全無** `/health` mount
  - 但 `deploy/compose.yaml` line 99 預設 `wget -q -O - http://localhost:10001/health` 作為 admin-api healthcheck → 此 healthcheck **必失敗**
  - 影響 chain：admin-api 永遠 unhealthy → `new-admin-base-web.depends_on: new-admin-rust-api.condition: service_healthy`（compose.yaml line 121-122）→ admin-web 永遠不啟動
- **Implementer note**: 本 feature **不**在 admin-api 加 /health endpoint（constitution §III 跨倉禁制——admin-web feature 不應該夾 admin-api 修改）。處理路徑：
  1. 列入 feature 6 (dockerfile-envsubst) prereq scope（feature 6 反正要動 admin-api source）
  2. 或者獨立一個 micro-feature `health-endpoint`（~10 行 Rust，獨立 PR）
  3. Feature 7 自身：static acceptance 可獨立完成（image build + size + structural check）；dynamic acceptance 屬 follow-up（A8 已 framed）
- **Alternatives considered**:
  - 改 admin-api compose.yaml healthcheck 用其他 check（如 TCP socket connect `nc -z localhost 10001`）—— 違反 feature 1 既有設計，留作 retrospective backlog
  - 在 feature 7 admin-web Dockerfile 內把 healthcheck 重做 —— 不對；admin-web 自己的 healthcheck 是 nginx `/health`（既有 default.conf line 9-13 return 200），與 admin-api 健康無關

---

## R6：VITE_SERVICE_BASE_URL prod 來源 + Vite env precedence

- **Decision**: Dockerfile 用 `ARG VITE_SERVICE_BASE_URL=/api` + `ENV VITE_SERVICE_BASE_URL=$VITE_SERVICE_BASE_URL` 注入；prod 時 compose build args 已 override 為 `/api`（已 read compose.yaml line 112）
- **Evidence**:
  - `admin-web/.env`（feature 5 整理過）內**沒有** `VITE_SERVICE_BASE_URL` 設定 → base 沒設
  - `admin-web/.env.prod` 內 `VITE_SERVICE_BASE_URL=https://mock.apifox.cn/m1/3109515-0-default`（上游 mock，**不適合 prod**）
  - `deploy/compose.yaml` line 112 在 `new-admin-base-web.build.args` 注入 `VITE_SERVICE_BASE_URL: /api` —— 這是正確 prod 設定
- **Vite env precedence**（per Vite docs）：
  ```
  process.env (build-time ENV)  ←  最高優先（Dockerfile ENV 屬此）
  .env.[mode].local
  .env.[mode]                    ←  .env.prod 屬此（被上面 override）
  .env.local
  .env                            ←  最低
  ```
- **Decision rationale**: Dockerfile ARG + ENV 注入會被 Vite 視為 `process.env`，優先級最高，**覆蓋** `.env.prod` 內 mock URL —— 這是合 §II 外部化設定原則的正確做法
- **Implementer note**: Dockerfile 要寫 **6 個** ARG（對齊 compose build args）：
  ```dockerfile
  ARG VITE_BASE_URL=/
  ARG VITE_SERVICE_BASE_URL=/api
  ARG VITE_APP_TITLE=NewAdmin
  ARG VITE_AUTH_ROUTE_MODE=static
  ARG VITE_STATIC_SUPER_ROLE=R_SUPER
  ARG PNPM_VERSION=10.5.0          # 不對外（compose 不傳）但 ARG 形式方便 future upgrade
  ```
  每個 ARG 後跟 ENV 同名暴露給 Vite（除 PNPM_VERSION 是 toolchain 用）

---

## R7：admin-web/src/ 內 hardcoded backend URL

- **Decision**: ✅ **0 hardcoded URL** —— Dockerfile **不需** patch src 內任何 URL；只需透過 VITE_SERVICE_BASE_URL build arg 控制
- **Evidence**: `grep -rln "localhost:10001\|127\.0\.0\.1:1000\|http://.*10001" admin-web/src/` → **0 命中**
- **Implementer note**: 此 finding 確認 R6 的 build arg approach 是完整解—— src 內所有 backend URL 都讀 `VITE_SERVICE_BASE_URL` env

---

## 結論：所有 Phase 0 unknowns 已具現化

| R# | Status | Action |
|---|---|---|
| R1 | ✅ Resolved | Dockerfile use `pnpm@10.5.0` via npm global install |
| R2 | ✅ Resolved | COPY `/app/dist` (Vite default outDir) |
| R3 | ✅ Resolved | No WS — nginx Upgrade headers harmless (留 default.conf 既有) |
| R4 | ✅ Resolved | Q1 + feature 1 既有設計對齊；COPY `deploy/nginx/default.conf` 進 image |
| **R5** | ⚠️ **Open (cross-feature)** | admin-api /health 缺失；列 feature 6 prereq；feature 7 dynamic acceptance 屬 follow-up |
| R6 | ✅ Resolved | ARG+ENV 6 個 VITE_* override `.env.prod` mock URL |
| R7 | ✅ Resolved | 0 hardcoded URL；build arg approach 完整 |

implementation 階段不需要再做額外 code 探勘。R5 是 cross-feature gating issue，不阻塞 feature 7 static delivery。
