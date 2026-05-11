# Feature Specification: admin-api application.yaml envsubst template + Hardening 收尾

**Feature Branch**: `007-dockerfile-envsubst`
**Created**: 2026-05-11
**Status**: Draft
**Input**: 把 admin-api `application.yaml` 換成 envsubst template 模式（per constitution §II）；entrypoint 階段 envsubst 渲染；移除 application.yaml 內 hardcoded 預設值；compose.yaml `APP_*` env vars 改 `:?` required gate（含 1-I3 JWT_ISSUER 不可 ship placeholder）；redis healthcheck 改 CMD-SHELL form 避 password 在 argv 暴露（1-I1）；順帶處理 1-M1~M5 hardening（postgres start_period、nginx WebSocket header、gzip_proxied 與 doc 漂移）。本 feature 不動 admin-web。

> **Note on numbering**：spec 目錄編號 `007` 是 sequential next-available（feature 7 admin-web-dockerfile 用了 006）；roadmap 上稱「feature 6」（實施順序排在 feature 7 之後）。兩種編號脫鉤是預期行為。

> **Scope adjustment**（session 進度更新後）：原 feature 6 規劃包含的 hardening 中 4 條已在 feature 7 期間以 §VI(b) hotfix 完成（1-I2 已 wired、1-I4 APP_ prefix 已修、新發現的 1-I5 IPv6 healthcheck 已修、7-I1 /health endpoint 已加）。本 feature 剩 **envsubst migration 主軸 + 1-I1 + 1-I3 + 1-M1~M5**。

## Clarifications

### Session 2026-05-11

- Q: `APP_JWT_ISSUER` placeholder rejection 偵測策略？ → A: **Sentinel exact-match list** —— 維護明確 placeholder 清單，env value **完全等於** 清單內任一字串時 abort。初始清單：`https://github.com/your-org/new-admin`、`change-me-issuer-url`、空字串 `""`。不用 regex / substring（避 false positive）

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator 透過 env 完全外部化 admin-api 設定（Priority: P1）🎯 MVP

Operator 在 prod 部署 admin-api 時，所有可變設定（DB URL、JWT secret、redis 連線、server port）必須透過 docker compose env 注入；image layer 內**不可**有任何 hardcoded prod 值或 placeholder（如 `pgbouncer:6432`、`https://github.com/your-org/...` 樣板字串）。Operator 若忘記 set 必要 env，啟動時 **fail fast**，不可 silently fall back 到 hardcoded 預設。

**Why this priority**: Constitution §II「外部化設定」NON-NEGOTIABLE 明文要求 envsubst template；目前 application.yaml 含 hardcoded `pgbouncer:6432` / `soybean-admin-rust` JWT secret / `redis://:123456` 等敏感預設值，**ship image 即含 weak secrets** —— 這是 prod readiness 阻礙。

**Independent Test**:
- `grep -rn "pgbouncer\|soybean-admin-rust\|123456\|your-org" admin-api/server/resources/` 必須 **0 命中**（無 hardcoded prod-like 值）
- 移除 `deploy/.env` 任一必要 var（如 `APP_JWT_JWT_SECRET`）後 `docker compose up` 必 **fail fast**（compose abort 或 admin-api startup error），**不可** silently 用預設值繼續

**Acceptance Scenarios**:

1. **Given** clean repo clone，**When** operator `cp deploy/.env.example deploy/.env` 並填寫必要 secrets 後 `docker compose up -d`，**Then** admin-api 啟動成功、healthy、可登入
2. **Given** `deploy/.env` 內 `APP_JWT_JWT_SECRET` 缺失，**When** operator `docker compose up`，**Then** compose 或 admin-api **明確 abort**（非預設 fallback 繼續）
3. **Given** admin-api runtime container，**When** `docker exec ... cat <rendered-config-path>/application.yaml`，**Then** 內容是 **rendered values from env**（無 `${VAR}` placeholder、無 `pgbouncer` / `your-org` 樣板）
4. **Given** image 構建完成、**未**啟動 container，**When** `docker run --rm new-admin-rust-api:latest ls /app/server/resources/`，**Then** **不**含 `application.yaml`（只有 `application.yaml.tpl` 或 wrapper script）—— 確保 hardcoded 值不在 image layer
5. **Given** prod compose，**When** operator 把 `APP_JWT_ISSUER` 留 placeholder（如 `https://github.com/your-org/...` 或 sentinel），**Then** admin-api 啟動 **fail fast** 並提示明確錯誤訊息（1-I3）

---

### User Story 2 — Stack 啟動穩定性 hardening 收尾（Priority: P2）

Operator 對既有 stack 啟動行為的小瑕疵期望被收斂：redis password 不應暴露在 process argv（`docker top` / `ps -ef` 可見）；postgres start_period 應夠長避免 healthy 誤判；nginx 對 WebSocket 與 gzip 行為應 production-grade。

**Why this priority**: 屬 hardening 而非 blocker；retrospective backlog 1-I1 + 1-M1~M5。本 feature 收尾這段以結束 feature 1 deploy-infra retrospective 區段。

**Independent Test**:
- `docker top new-admin-root-redis-1` 不應在 args 看到 `${REDIS_PASSWORD}` 真實值（至少 healthcheck argv 不暴露；redis-server `--requirepass` 屬既有 limitation，文件化）
- `docker inspect new-admin-root-postgres-1` 顯示 healthcheck `start_period` ≥ 30s
- nginx config grep `proxy_set_header Upgrade` / `gzip_proxied any` 都應 present

**Acceptance Scenarios**:

1. **Given** stack 啟動後，**When** `docker top new-admin-root-redis-1`，**Then** redis-cli ping healthcheck process args **不含明文 password**（用 `CMD-SHELL` form + `$$REDIS_PASSWORD` env interpolation，env 在 container 內 lookup 而非 docker compose 展開到 argv）
2. **Given** postgres 首次冷啟動，**When** healthcheck 跑，**Then** 給足 `start_period`（≥ 30s）避免 init 過程被誤判 unhealthy（**verified implicitly** via T014 sc 1 全 stack cold start happy path 不卡 postgres healthcheck timeout）
3. **Given** nginx config，**When** 檢查 `default.conf`，**Then** 含 `gzip_proxied any` 或等效設定（feature 1 1-M3 backlog 修），WebSocket Upgrade/Connection header 完整（per 1-M2）

---

### Edge Cases

- **Operator 跑 dev mode（compose.dev.yaml）**：dev override 也需被 envsubst 模式相容（dev mode admin-api 走本機 cargo run、不走容器，所以 envsubst 在容器內生效不影響 dev flow）
- **Multi-line yaml 值**：envsubst 對單行 yaml 值 OK；若 application.yaml 內有 multi-line string（如 multi-line PEM key），須驗證 envsubst 不破壞 indentation
- **Env value 含特殊字元**（如 `:` `@` `$`）：envsubst 預設不 escape；DB URL 之 password 若含 `$` 等字元，**必須** `${...}` 包夾正確
- **未設 env var**：envsubst 預設 render 為空字串（silent failure 風險）。改用 entrypoint 顯式 required check 或 `envsubst -v` strict 模式
- **重啟 container**：entrypoint 每次都重 render（idempotent）；目標檔 `application.yaml` 應 overwrite 不 append
- **rootless container**：envsubst write target file 需 owner 對應 admin-api Dockerfile 既定 USER（appuser 10001）

## Requirements *(mandatory)*

### Functional Requirements

#### envsubst Template & 渲染（核心）

- **FR-601**: admin-api MUST 用 `application.yaml.tpl` 作為設定 source-of-truth；image layer 內**不**含 `application.yaml`（無 hardcoded 預設值 ship）
- **FR-602**: container entrypoint MUST 在啟動 server binary 前先跑 `envsubst < application.yaml.tpl > application.yaml`（或 streaming 寫入指定路徑）
- **FR-603**: `application.yaml.tpl` 內所有可變設定 MUST 使用 `${APP_*}` 占位符（bare form 即可，無 fallback）。**重要更正**（F6-T014 dynamic acceptance 發現）：GNU envsubst（gettext-runtime 0.22.5）**不**支援 POSIX shell `${VAR:-default}` syntax；遇到此 form 視為 invalid identifier 保留字面字串。因此 .tpl 之預設值不可寫 inline `${APP_VAR:-default}` 形式 —— 改由 compose.yaml 在 env 層保證對應值有設定（compose 之 `${VAR:-default}` 是 compose-level 解析、不依賴 envsubst）
- **FR-604**: 不可變設定（如 `server.host: "0.0.0.0"`、`database.connect_timeout: 30`）**MAY** 保留 yaml inline，不需 env 化（permissive by design：implementer 自由度，非 strict requirement）
- **FR-605**: entrypoint MUST 對 **secrets**（`APP_JWT_JWT_SECRET`、`APP_DATABASE_URL`、`APP_REDIS_URL`）做 **explicit required check**：若 env 未設或為空字串，**abort 啟動** 並 print 明確錯誤訊息
- **FR-606**: entrypoint MUST 對 `APP_JWT_ISSUER` 做 **placeholder rejection**（1-I3，per §Clarifications Q1 = sentinel exact-match list）：env value **完全等於** 下列任一 sentinel 時 abort 啟動：
  - `https://github.com/your-org/new-admin`（feature 1 既有 default 值，**最高優先**清除目標）
  - `change-me-issuer-url`（`.env.example` placeholder 值）
  - `""`（空字串）
  - （未來增 sentinel 時需更新此清單）
  匹配採 **完全相等**（不 regex、不 substring），避免合法 issuer URL 內含 placeholder 子字串時誤拒
- **FR-607**: 已 render 的 `application.yaml` MUST 寫入容器 writable 路徑；原 `/app/server/resources/` 維持唯讀 `.tpl`
- **FR-608**: admin-api server binary MUST 從 entrypoint render 後的路徑讀 config（透過環境變數指向，或約定路徑）

#### Compose env required gates（1-I3 收尾）

- **FR-610**: `deploy/compose.yaml` 之 `new-admin-rust-api.environment` 區段所有 secret 類 `APP_*` env vars MUST 用 `${VAR:?must set VAR}` required gate 形式
- **FR-611**: `deploy/.env.example` MUST 列出所有必要 vars（不附真實值，僅 `change-me-` 樣板）；其中 `APP_JWT_ISSUER` MUST 帶 `change-me-` placeholder 而**非** github URL 樣板

#### Redis Hardening（1-I1）

- **FR-620**: `deploy/compose.yaml` redis healthcheck MUST 用 `CMD-SHELL` form + `$$REDIS_PASSWORD` env interpolation（雙 `$` escape，避免 docker compose 提前展開）；確保 `docker top redis-container` 之 healthcheck process args 內**不**含明文 password
- **FR-621**: redis container 啟動命令以 `--requirepass` 仍會在 main process argv 暴露 password（屬既有 redis-server limitation）；本 FR 接受此 limitation 並在 `deploy/README.md` 或 `.env.example` 內 doc 說明

#### Postgres / nginx Hardening（1-M1~M5）

- **FR-630**: postgres healthcheck MUST 維持 `start_period` ≥ 30s（feature 1 既有 compose.yaml 已 compliant；本 feature **verify-only**，避免後續 regression）—— 對應 1-M1
- **FR-631**: `deploy/nginx/default.conf` MUST 對 `/api/*` proxy 段補 `proxy_set_header Upgrade` 與 `Connection "upgrade"` 完整 WebSocket 支援（即使當前 admin-api 無 WS endpoint，預備未來 SSE / WS 不影響）—— 對應 1-M2
- **FR-632**: `deploy/nginx/default.conf` gzip 區段 MUST 含 `gzip_proxied any`（或等效），確保被反代之 response 也被壓縮 —— 對應 1-M3
- **FR-633**: 同 nginx config 與 compose.yaml 之 inline 註解 MUST 對齊既有實際設計（best-effort：implementer 在 T010/T012 過程中**發現的**註解漂移即修；不要求事前列舉所有漂移點，因屬清掃性工作）—— 對應 1-M4/M5

#### 既有功能保護（regression gate）

- **FR-640**: FR-601~FR-633 任一變動 MUST **不**破壞 feature 7 已驗證之 dynamic acceptance（瀏覽器登入 / deep link / 502 fallback 五個 scenarios）

### Key Entities

- **`application.yaml.tpl`**: admin-api `server/resources/` 下的 envsubst template；含 `${APP_*}` 占位符；image build 時 COPY 進來、runtime 唯讀
- **Entrypoint script**: admin-api Dockerfile 之 ENTRYPOINT（新增或改寫）；責 (a) check required envs、(b) reject `APP_JWT_ISSUER` placeholder、(c) envsubst render `.tpl` → 寫入容器 writable 路徑、(d) `exec` admin-api server binary
- **Rendered `application.yaml`**: entrypoint 產出的實際 config 檔；位於 container writable 路徑；對 admin-api server binary 透明（binary 讀此檔的路徑由 entrypoint 控制）
- **`deploy/.env.example`**: contract source of truth；列必要 env vars + placeholder 值；本 feature 更新後 `APP_JWT_ISSUER` 顯式為 `change-me-issuer-url`
- **`deploy/compose.yaml`** environment 區段 + redis 區段（hardening）

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-601**: `grep -rn "pgbouncer\|soybean-admin-rust\|123456\|your-org" admin-api/server/resources/` **0 命中**（無 hardcoded prod-like 預設值在 source 樹中）
- **SC-602**: `docker run --rm new-admin-rust-api:latest cat /app/server/resources/application.yaml.tpl` 看到的是 `${APP_*}` template，**非** rendered values
- **SC-603**: `docker run --rm new-admin-rust-api:latest ls /app/server/resources/` 列表**不**含 `application.yaml`（僅 `.tpl` + 其他資源）
- **SC-604**: `docker compose up -d` 一旦缺少必要 env（如刪除 `.env` 內 `APP_JWT_JWT_SECRET` 行）必失敗、container exit 非 0，**不**用預設值靜默繼續
- **SC-605**: `docker exec <admin-api-container> cat <rendered-path>/application.yaml` 看到實際 env 值（無 `${...}` 殘留）
- **SC-606**: `docker top new-admin-root-redis-1` 之 **healthcheck** process args 不含明文 `REDIS_PASSWORD` 值
- **SC-607**: `docker compose up -d` 全 stack 從 cold ≤ 5 分鐘進 healthy（refresh feature 1 SC，搭配 hardening verify start_period ≥ 30s 不會誤判）
- **SC-608**: feature 7 dynamic acceptance 5 scenarios 重跑全綠（envsubst 改造不可破壞既有功能）
- **SC-609**: 以下三種值 set 給 `APP_JWT_ISSUER` 後 `docker compose up` 必失敗，error message 明確指出 placeholder 不允許：(a) `https://github.com/your-org/new-admin`、(b) `change-me-issuer-url`、(c) 空字串。**反向**：`https://my-company.example.com/auth` 等合法值不應被誤拒（即使含「com」「auth」等常見子字串）

## Assumptions

- **A1**: admin-api 目前用 `config` crate + `APP_` prefix + `_` separator 讀 env override（per feature 1-I4 hotfix 之發現）。envsubst 模式不取代此機制，而是在 entrypoint 階段把 env 寫進 yaml 後 binary 讀 yaml；env override 機制仍保留作為 second layer（envsubst 之後 binary 啟動時 config crate 仍可進一步 override）
- **A2**: alpine 基底 image 加 `apk add --no-cache gettext` 取得 `envsubst`（gettext 包提供）；額外 image size ~ 200 KB 可接受
- **A3**: entrypoint script 以 shell（sh / busybox ash）撰寫，因 alpine 沒有 bash by default
- **A4**: dev mode（`cargo run` on host）**不**走 docker entrypoint，dev developer 仍直接讀 host 上 `application.yaml`（可能需保留一個 `.example` 或 dev-only 版本不被 ship 進 prod image）
- **A5**: 既有 feature 7 之 admin-web image 與 admin-web/Dockerfile **不動**（envsubst 是 admin-api 範疇 / constitution §II 也指 admin-api `application.yaml`）
- **A6**: feature 7 期間之 hotfix（1-I2 + 1-I4 + 1-I5 + 7-I1）已 land，本 feature **不**重做、不 revert，只在其上加 envsubst 層
- **A7**: 預設帳號 `Soybean / 123456`（CLAUDE.md §5.1）seed 仍由 migration 容器處理；本 feature 不改 migration 行為
- **A8**: 本 feature 之 dynamic acceptance 在實作後執行（不依賴外部 PR）；feature 7 之 T010 已驗證 baseline，本 feature 改造後 re-run 同 5 scenarios（per FR-640）

### 待驗證的上游慣例（依 constitution §IV，於 plan / implement 階段以 running infra 驗證）

- **R1**: admin-api server binary 是否支援透過環境變數（如 `APP_CONFIG_PATH`）覆寫 yaml 讀取路徑？若否，entrypoint 需在預期路徑（如 `/app/server/resources/application.yaml`）寫 rendered file（grep `main.rs` 或 `config_init.rs` 確認讀檔路徑來源）
- **R2**: `config` crate 對「yaml 內含 `${VAR}` 字面字串」的行為——若 envsubst 漏掉某 placeholder（未設 env），rendered yaml 含 `${VAR}` 字面，admin-api parse 是否 fail？或 silently 用此字串？
- **R3**: rootless 模式下 entrypoint 寫入 yaml 之 target 路徑（writable + binary 可讀）—— 視 admin-api Dockerfile 用的 USER（appuser 10001 per Dockerfile）
- **R4**: envsubst 是否處理 yaml `:` 字元正確（yaml structural 字元 vs env value 內含 `:`）—— 預期 envsubst 不解析 yaml structure，純文字替換 `${VAR}`，OK
- **R5**: feature 1 redis container 之 `--requirepass ${REDIS_PASSWORD}` 啟動 command 是否仍會在 `docker top` 暴露 password —— 屬既有 limitation（redis-server flag 本身就會出現在 argv），文件化說明而非完全消除
- **R6**: 既有 application.yaml 之 inline mock `pgbouncer:6432` / mock JWT secret 等 hardcoded 值的**所有出現位置**（grep）—— 確認 .tpl 覆蓋全部
