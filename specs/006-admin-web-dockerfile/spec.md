# Feature Specification: admin-web Dockerfile (multi-stage build + nginx serve)

**Feature Branch**: `006-admin-web-dockerfile`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "feature 7 admin-web-dockerfile" — produce production Docker image for admin-web (Vue 3 SPA) so operator can `docker compose up` 起整套 stack 而不需要 host 端 `pnpm dev`

> **Note on numbering**: spec 目錄編號 `006` 是 sequential next-available；roadmap 上稱「feature 7」（實施順序排在 feature 5 之後、feature 6 envsubst 之前）。兩種編號脫鉤是預期行為（CLAUDE.md §2 / .specify config `sequential` mode）。

## Clarifications

### Session 2026-05-11

- Q: feature 7 之 admin-web image 與 feature 1 既有 nginx service 之關係？ → A: **合併**（admin-web image 內 nginx = compose 唯一 nginx；移除 feature 1 獨立 nginx service entry；compose 對外只剩 admin-web :8080，內建 nginx 同時負責 serve static + proxy `/api/*` → `new-admin-rust-api:10001`）

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator 可用單一指令啟動完整 prod stack 並從瀏覽器登入 (Priority: P1) — MVP

Operator 在新機器上 clone outer repo + `git submodule update --init`，然後在 `deploy/` 跑 `docker compose up -d`。等待約 1-5 分鐘（首次 cold build），打開瀏覽器到 `http://localhost:8080`，看到 admin-web login 頁面。輸入 `Soybean / 123456` 點 login，成功進入 dashboard 並看到完整 menu tree。

**Why this priority**: 沒有這個 image，prod 部署需要 host 端 `pnpm install + pnpm build + 自行 serve dist`，違反「全 docker compose 對外只暴露 :8080」的部署決策（CLAUDE.md §4）。是 prod readiness 的必要條件。

**Independent Test**: 在乾淨 docker host（無 node、無 pnpm）跑 `docker compose up -d` → 等待 healthy → 瀏覽器登入 `Soybean/123456` → 看到 dashboard。**不需要任何 host 端工具鏈**。

**Acceptance Scenarios**:

1. **Given** 乾淨機器（無本機 node/pnpm）只有 docker 與 outer repo checkout，**When** operator 在 `deploy/` 跑 `docker compose up -d`，**Then** 約 5 分鐘內所有 service healthy
2. **Given** stack 已啟動，**When** 瀏覽器訪問 `http://localhost:8080`，**Then** admin-web login 頁面在 1 秒內顯示
3. **Given** login 頁面顯示，**When** 輸入 `Soybean / 123456` 點 login，**Then** dashboard 出現、左側 menu 顯示完整 ROLE_SUPER 樹、無 CORS / Network error
4. **Given** 已 login 的 session，**When** 在 URL bar 直接輸入 `http://localhost:8080/home/analysis` 並 Enter，**Then** 頁面正常載入（不是 404）
5. **Given** stack 已啟動，**When** operator 跑 `docker compose stop new-admin-rust-api`，**Then** 瀏覽器嘗試任何 API 請求得到「服務不可用」友善錯誤訊息（不是空白頁、瀏覽器不 crash）

---

### User Story 2 — Build 與 image 符合 image hygiene 最佳實踐 (Priority: P2)

Operator 在 CI 或本機反覆 build admin-web image。每次 build 都使用 deterministic / cacheable 流程：lockfile 變動才重 install、source 變動才重 build。Final image 不含 source code、node_modules、開發工具。

**Why this priority**: 確保 CI build time 可預測、image 大小不暴漲、不洩漏 source code 或開發 metadata。對 operator 維運與安全性都重要，但不是 MVP；MVP 是 "image 能跑出來、能登入"。

**Independent Test**:
- `docker image inspect <admin-web-image>` 顯示 size < 150 MB
- 第二次 `docker compose build admin-web`（source 無變動）< 30 秒（layer cache hit）
- `docker run --rm <admin-web-image> ls /` 不應該看到 `node_modules` / `src` / `tsconfig.json` 等 build artefact

**Acceptance Scenarios**:

1. **Given** 第一次 build，**When** 全程跑完，**Then** final image size < 150 MB
2. **Given** image 已 build 過，**When** 修改 `admin-web/src/views/login/index.vue` 後 rebuild，**Then** install 階段 layer 命中 cache（不重跑 `pnpm install`），只重跑 build 階段
3. **Given** image 已 build 過，**When** 修改 `admin-web/package.json` dep 後 rebuild，**Then** install 階段重跑，build 階段重跑
4. **Given** final image，**When** `docker run --rm --entrypoint sh <image> -c 'ls /'`，**Then** root 不含 `node_modules`、`src`、`tsconfig*.json`、`vite.config.ts`
5. **Given** 無 internet 環境，**When** 嘗試 build admin-web image（且本機 cache 已有相同 base image + node_modules layer），**Then** build 失敗訊息明確指出無法存取 registry，**不**靜悄悄使用 stale cache

---

### Edge Cases

- **SPA deep link 重新整理 / 直接輸入 URL**：admin-web nginx 必須 fallback 到 `/index.html`，否則所有非 `/` 與 `/api/*` 的路徑會 404
- **Admin-api healthcheck 失敗或啟動慢**：admin-web 不應 race condition 提早 ready；compose `depends_on: condition: service_healthy` 應抓得到
- **Browser 訪問 `/api/auth/login` 但 backend 未上線**：nginx 應回 502 Bad Gateway（不是空白頁或 timeout）
- **Build 階段網路不穩 / registry 暫時 down**：build 必須失敗並回非 0 exit code，不可使用 partial / stale 結果繼續
- **VITE_* env 在 build 階段已 baked 進 bundle**：runtime 改 env 不會生效；operator 需重 build 並重 deploy（spec 必須明確指出此 limitation 避免 ops 混淆）
- **WebSocket 連線**：admin-web 預設無 WebSocket（per SoybeanAdmin 5.x 基礎模板），nginx 不需特別處理 Upgrade header；若未來引入 WS 再補（不在本 feature 範圍）

## Requirements *(mandatory)*

### Functional Requirements

#### admin-web Image 打包

- **FR-701**: admin-web MUST 被打包為單一可執行 Docker image
- **FR-702**: Dockerfile MUST 採 multi-stage build —— 至少包含 builder stage（含 Node.js + pnpm + 完整 source）與 runtime stage（僅含 nginx + 靜態 dist + nginx config）
- **FR-703**: Runtime stage MUST 基於 nginx 官方 image（具體版本由 plan 階段決定，但須為非 latest tag）
- **FR-704**: Builder stage MUST 使用 pnpm（與 admin-web/package.json `packageManager` 欄位宣告版本一致），透過 `--frozen-lockfile` 確保 reproducible install
- **FR-705**: Build 流程 MUST 先 copy `package.json` + `pnpm-lock.yaml` 並 `pnpm install`，再 copy 其餘 source 並 `pnpm build` —— 讓 source-only 變動 hit install layer cache
- **FR-706**: Final runtime image MUST **不**包含：Node.js binary、pnpm、node_modules、source code（`src/`、`*.ts`、`*.vue` 原檔）、開發設定（`tsconfig*.json`、`vite.config.ts`、`.env*` 原檔）

#### nginx 與 SPA 路由

- **FR-707**: admin-web image 內 nginx config MUST 設定 SPA history-mode fallback —— 任何非 static asset、非 `/api/*` 的路徑都 try_files fallback 到 `/index.html`
- **FR-708**: nginx config MUST reverse-proxy `/api/*` 到 admin-api backend（service name `new-admin-rust-api`、port `10001`）
- **FR-709**: nginx config MUST 在 proxy 時保留 `Host`、`Authorization`、`Content-Type`、`X-Forwarded-For` headers（不主動 strip）
- **FR-710**: nginx config MUST 對靜態 asset（`*.js`、`*.css`、`*.png`、`*.svg`、`*.woff*`）回應適當 `Cache-Control`（建議 immutable + max-age 長期、配合 Vite hash filename）
- **FR-711**: 對 `/index.html` MUST 回應 `Cache-Control: no-cache`（確保 SPA 部署新版時 client 拿到新版）

#### Compose 整合

- **FR-712**: deploy/compose.yaml MUST 註冊 admin-web service，採**長名** `new-admin-base-web`（feature 1 既定，per CLAUDE.md §1 命名分工：compose service 用長名）
- **FR-713**: admin-web service MUST 暴露 host port 8080 → container port 80
- **FR-714**: admin-web service MUST `depends_on: new-admin-rust-api: condition: service_healthy`（確保 admin-api 啟動完成才啟動 admin-web）
- **FR-715**: admin-web image MUST 提供 Dockerfile HEALTHCHECK：`wget --spider --quiet http://localhost/health`（依 deploy/nginx/default.conf 既有 `location = /health` return 200 "ok\n"）
- **FR-716**: 對外暴露 port 必須**只有** 8080（其餘 service port 不對外）
- **FR-716a**: ✅ **Resolved by §Clarifications Q1 + Phase 0 R4 verification** —— feature 1 既有設計**已**對齊 Option A：`deploy/compose.yaml` 從未含獨立 nginx service entry（只有 5 個 service：postgres / redis / migration / new-admin-rust-api / new-admin-base-web），nginx 角色內建於 admin-web image。本 feature 無「移除既有 service」動作需執行

#### Build context 與 reproducibility

- **FR-717**: admin-web/.dockerignore MUST 排除：`node_modules/`、`dist/`、`.git/`、`.vscode/`、`*.log`、`coverage/`、`.turbo/`
- **FR-718**: Build MUST 不需要 admin-api runtime 可達 —— 純 static build，無 backend dep
- **FR-719**: Build 流程 MUST 對未 freeze 的 lockfile drift fail-fast（pnpm `--frozen-lockfile` 預設行為）

#### Build-time env 與環境配置

- **FR-720**: admin-web .env 檔策略 MUST 遵循 feature 2 既有設定（base URL、success code、auth route mode 等已在 feature 2 對齊；本 feature **不**改 .env 內容）
- **FR-721**: Spec MUST 明確聲明：因 Vite build-time 替換特性、VITE_* 改動後 runtime 不會生效，operator 須 rebuild image —— 此 limitation 須寫進 quickstart 與 deploy README

### Key Entities

- **Dockerfile**: admin-web/ 根目錄下的 multi-stage build 定義；builder + runtime 兩個 stage
- **nginx.conf**: 隨 admin-web image 一起的 nginx config 檔（含 SPA fallback + /api proxy + cache headers）
- **.dockerignore**: build context 排除清單
- **Compose service entry**: deploy/compose.yaml 內的 admin-web service 區塊

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-701**: 從乾淨機器（無本機 node/pnpm 工具鏈）執行 `docker compose up -d`，5 分鐘內所有 service 進入 healthy 狀態
- **SC-702**: 瀏覽器訪問 `http://localhost:8080` 在 1 秒內顯示 admin-web login 頁面（local docker host loopback）
- **SC-703**: 使用 `Soybean / 123456` 完成 login 並進入 dashboard，整段流程從點 login button 到 dashboard render 完成 ≤ 2 秒
- **SC-704**: 直接訪問 deep link（如 `http://localhost:8080/home/analysis`）回 200 + 頁面正常 render，不會 404
- **SC-705**: Final admin-web image size ≤ 150 MB
- **SC-706**: 第二次 build（source 無變動）≤ 30 秒（layer cache 命中）
- **SC-707**: 停掉 admin-api 後，瀏覽器發 API request 得到 502 友善錯誤（不是瀏覽器空白頁或 console JS crash）
- **SC-708**: `docker image inspect <admin-web-image>` 顯示 final layer 不含 source code / node_modules / tsconfig
- **SC-709**: Operator 不需要碰任何 host 端工具就能完整 deploy 並 demo login

## Assumptions

- **A1**: Feature 1 (deploy-infra) 已產出 `deploy/compose.yaml`、`deploy/.env.example`、`deploy/nginx/`（含初版 nginx config）。本 feature **合併**該 nginx 角色進 admin-web image：admin-web image 內 nginx 同時負責 serve static + proxy `/api/*` → `new-admin-rust-api:10001`；feature 1 既有獨立 nginx service entry 與 nginx config 由本 feature 移除 / 接收（具體遷移由 plan 階段比對 feature 1 產出後拍板 —— 見 §Clarifications Q1）
- **A2**: Feature 2 (gap-0ab0f-frontend-env-and-login) 已調好 admin-web `.env*` 環境變數，本 feature **不**改 .env 內容；如有 prod 專用 env 需求由 plan 決定是否加 `.env.production`
- **A3**: ⚠️ admin-api 容器化由 feature 1 完成（compose.yaml 已寫 healthcheck `wget /health`），但 `/health` endpoint 在 admin-api 端**尚未實作**（research.md R5 verify：`grep` admin-api/server/ 0 命中）。feature 7 image build 不受影響（static acceptance 可獨立完成），但**dynamic acceptance** 必須等 R5 補上 + feature 6 merge 後執行（A8 已 framed；不在本 feature 範圍動 admin-api，§III 跨倉禁制）
- **A4**: SoybeanAdmin v5 基礎模板 frontend 預設**不**用 WebSocket（無 `socket.io`、無 `EventSource` 主用例）。若實際存在 WS 使用，由 plan 階段 grep `src/` 驗證並補 nginx Upgrade headers
- **A5**: 預設帳號 `Soybean / 123456`（CLAUDE.md §5.1 已驗證 feature 4 dynamic acceptance）
- **A6**: 本 feature **不**處理 envsubst / runtime env injection —— 該議題留給 feature 6 dockerfile-envsubst 統一處理 admin-api 端 application.yaml；admin-web 因 Vite build-time bake 特性，runtime env injection 屬另一議題（如需，未來獨立 feature 用 Nginx sub_filter 或 placeholder.js 模式）
- **A7**: Image registry / 推送策略不在本 feature 範圍 —— 本地 build 即可，不要求推 docker hub / ghcr.io
- **A8**: 本 feature 內 dynamic acceptance（瀏覽器登入 + deep link 測試）在 docker compose 完整可運作後執行；若 feature 6 尚未 merge 導致 admin-api 容器化無法跑，先做 static acceptance（image build + size + structural 檢查），dynamic 走 follow-up

### 待驗證的上游慣例（依 constitution §IV，於 plan 階段透過讀 admin-web 與 deploy/ 既有檔案驗證 + writeback；不在本 spec 階段揣測）

- **R1**: `admin-web/package.json` 的 `packageManager` 欄位實際是哪個 pnpm 版本（影響 Dockerfile 是否需 corepack activate vs 直接 install pnpm@<x>.<y>.<z>）
- **R2**: `admin-web/package.json` `scripts.build` 命令的精確輸出目錄（預設 `dist/` 但 vite config 可能 override）
- **R3**: admin-web 是否在任何頁面使用 WebSocket / SSE / 長連線（grep `src/` for `WebSocket\|EventSource\|socket.io`）
- **R4**: ✅ **Resolved**（§Clarifications Q1 + research.md R4）—— feature 1 `deploy/nginx/default.conf` 已 read：含 SPA fallback、`/api/*` proxy、`/health` location、static cache、gzip；本 feature Dockerfile runtime stage 直接 `COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf` 採用既有 config，無 merge 動作
- **R5**: feature 1 是否已為 admin-api 補 `/health` endpoint（影響 `depends_on: service_healthy` 是否可用）
- **R6**: admin-web .env 在 prod build 時實際被讀的優先順序（`.env` < `.env.production` < `.env.local`）—— 確認 prod build 用的是哪份、bake 後值為何
- **R7**: 既有 admin-web `src/` 是否含 backend hardcoded URL（grep `localhost:10001\|127\.0\.0\.1`），確認 Dockerfile 沒漏掉任何需 rebuild 的點
