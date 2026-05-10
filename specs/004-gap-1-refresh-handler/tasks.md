---

description: "Tasks for feature 004-gap-1-refresh-handler"
---

# Tasks: gap-1-refresh-handler

**Input**: Design documents from `/specs/004-gap-1-refresh-handler/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/refresh-token-endpoint.md ✅、quickstart.md ✅

**Tests**: 本 feature 含實際 business logic（service rotation transaction）— 但既有 admin-api 倉內**無 unit test framework / harness**（feature 3 / 2 也未引入）。本 feature 維持「靜態 grep + `cargo build`」+ 「動態 curl wire smoke」雙重 acceptance、**不另寫 unit test**。未來如要引入 cargo test，屬獨立 feature。

**Organization**: tasks 依 2 個 user stories（US1 P1 = happy path rotation、US2 P2 = 401 negative cases）+ §V 兩段式 commit（admin-api 版、3 個 inner commits + 1 個 outer commit）+ acceptance-evidence 結構（沿用 feature 3 T007 evidence file 模式）展開。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-api 倉內檔以 `admin-api/<path>` 表示；outer 倉檔以 root-relative path
- §V 兩段式 commit（**admin-api** 版、第 2 個使用本模式的 feature；T002/T003/T004 在 admin-api/ worktree 內各自 commit、T006 push fork、T007 是 outer SHA pin commit）

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 admin-api/ worktree health + 切到對的 branch（new-admin-rust-api） + dev DB 可寫。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑 `git submodule status` 確認 admin-api 行行首為空格；`cd admin-api && git branch --show-current` 確認在 `new-admin-rust-api`；`git status` 確認 worktree clean；`ls -la admin-api/.git` 確認是 ASCII text（worktree mode）；確認本機 dev postgres 可連（`psql $DATABASE_URL -c "SELECT 1"`，準備跑 migration）。

---

## Phase 2: Foundational

**Purpose**: 無 — 所有改動位於 admin-api 倉內，且各 inner commit 自我 cargo check / build PASS 即可推進。foundational concept 不適用本 feature 結構。

---

## Phase 3: User Story 1 - admin-web 用合法 refresh token 換新一組 token (Priority: P1) 🎯 MVP

**Goal**: admin-api 接收合法 refresh token → 透過 Sea-ORM transaction 原子地（INSERT 新 row + UPDATE 舊 row REFRESHED）rotate 出新 access + refresh token + 沿用既有 audit trail。

**Independent Test**:
- 靜態（本 feature 自身可跑）：grep `RefreshTokenInput` / route 註冊 / handler / service method 全部命中 + `cargo build --release` PASS + `cargo run -p migration -- up` PASS（dev DB）
- 動態（依本機 `cargo run` 或 feature 6 docker stack）：curl login → 用回來的 refresh token 跑 refreshToken → 驗回的 token / refreshToken 與輸入不同 + 用新 access token 跑 getUserInfo PASS + psql 查兩 row 狀態 = `(ACTIVE, REFRESHED)`

### Inner Commits（在 admin-api/ worktree 內，§V 第一段、admin-api 版）

- [ ] T002 [US1] 在 `admin-api/migration/src/schemas/m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens.rs` 建新 migration 檔（3-step ALTER：add nullable → raw SQL backfill `created_at + INTERVAL '14 days'` → modify NOT NULL；骨架見 quickstart.md §A.1 inner commit 1）。在 `admin-api/migration/src/schemas/mod.rs` 加 `pub mod m...add_expires_at_to_sys_tokens;`。在 `admin-api/migration/src/lib.rs` 的 `Migrator::migrations()` 「架构迁移」段尾端（在 `m20241023_091210_create_sys_user_role` 之後）加 `Box::new(schemas::m...add_expires_at_to_sys_tokens::Migration),`。在 `admin-api/server/model/src/admin/entities/sys_tokens.rs` 的 `pub created_by: String,` 後加 `pub expires_at: DateTime,`。跑 `cd admin-api && cargo build --release -p server-model -p migration` 驗 PASS。在 admin-api/ worktree 內 inner commit：`feat(admin-api): GAP-1 加 sys_tokens.expires_at migration + entity`。

- [ ] T003 [US1] 在 `admin-api/server/model/src/admin/input/sys_authentication.rs` 尾端加 `RefreshTokenInput` struct（含 `#[serde(rename = "refreshToken")]` + `#[validate(length(min = 1, message = "Refresh token cannot be empty"))]`，骨架見 data-model.md §2.1）。在 `admin-api/server/model/src/admin/input/mod.rs` 比照 `LoginInput` re-export 加 `pub use sys_authentication::RefreshTokenInput;`（或對應 export 慣例）。在 `admin-api/server/router/src/admin/sys_authentication_route.rs` 的 `init_authentication_router()` 內加 `.route("/refreshToken", post(SysAuthenticationApi::refresh_token_handler))`。同時在 `admin-api/server/api/src/admin/sys_authentication_api.rs` 加 `refresh_token_handler` **stub**（先回 `Err(AppError { code: 501, message: "Not implemented".into() })` 讓 router 可編譯；T004 補正內容）。跑 `cd admin-api && cargo check` 驗 PASS。在 admin-api/ worktree 內 inner commit：`feat(admin-api): GAP-1 加 RefreshTokenInput + /auth/refreshToken route`。

- [ ] T004 [US1] 完整實作：
   - **改 `admin-api/server/config/src/model/jwt_config.rs`**：在 `JwtConfig` struct 加 `#[serde(default = "default_refresh_token_expire")] pub refresh_token_expire: u64,` + 同檔加 `fn default_refresh_token_expire() -> u64 { 1209600 }`（research.md R9）。
   - **改 `admin-api/server/service/src/admin/events/access_token_event.rs`**：(a) 確保 `AccessTokenEvent::handle` signature 接受 `&impl ConnectionTrait`（非 `&DatabaseConnection`）以支援 refresh transaction 路徑；(b) 在 `SysTokensActiveModel { ... }.insert(db)` 內加 `expires_at: Set(now + chrono::Duration::seconds(refresh_token_expire as i64)),` — 這對齊 migration NOT NULL，避免 login 既有路徑 break。改 signature 後對應同檔 import 補 `sea_orm::ConnectionTrait` 與 `chrono::Duration`。
   - **改 `admin-api/server/api/src/admin/sys_authentication_api.rs`**：把 T003 的 `refresh_token_handler` stub 換成完整實作（骨架見 quickstart.md §A.1 inner commit 3）— 接 `ConnectInfo / HeaderMap / TypedHeader<UserAgent> / Extension<RequestId> / Extension<Arc<SysAuthService>> / ValidatedForm<RefreshTokenInput>`、組 `LoginContext`、call `service.refresh_token(input, context).await.map(Res::new_data)`。
   - **改 `admin-api/server/service/src/admin/sys_auth_service.rs`**：(a) `TAuthService` trait 加 method 簽章 `async fn refresh_token(&self, input: RefreshTokenInput, context: LoginContext) -> Result<AuthOutput, AppError>;`；(b) `impl TAuthService for SysAuthService` 加實作（骨架見 research.md R8）—— 用 `db.transaction::<_, AuthOutput, AppError>(|txn| Box::pin(async move { ... }))` 包覆「query 舊 row（filter `RefreshToken.eq(&refresh_token)` + `Status.eq(TokenStatus::Active.to_string())` + `ExpiresAt.gt(Local::now().naive_local())`，無 row → `AppError { code: 401, message: "Refresh token invalid".into() }`）→ 從舊 row 取 user_id / username / domain / type → 走 `get_user_roles` 拿 role_codes（重用 R8 建議 (2) DB 重查路徑）→ call `generate_auth_output(...)` 生新 JWT + Ulid → 用 `AccessTokenEvent { ... }.handle(txn).await` 寫新 sys_tokens row（fields mapping 見 data-model.md §4 對照表）→ 把舊 row `SysTokensActiveModel.status = Set(TokenStatus::Refreshed.to_string()); .update(txn).await` → Ok(auth_output)」。
   - 在 admin-api/ 跑 `cargo build --release` 驗 PASS（無 compile error / new warning）對應 SC-401。
   - 在 admin-api/ worktree 內 inner commit：`feat(admin-api): GAP-1 加 refresh_token_handler + service rotation`（commit message body 列入 4 個檔的改動主旨）。

### Dev DB 驗證（在 inner commits 之後、push 之前跑）

- [ ] T005 [US1] 在 `admin-api/` 內跑 `cargo run -p migration -- up` 對本機 dev postgres 跑 migration；觀察 log 確認 `m...add_expires_at_to_sys_tokens` 列為 applied。跑 `psql $DATABASE_URL -c "\d sys_tokens"` 確認 `expires_at` column 為 `timestamp without time zone NOT NULL`。若 sys_tokens 表已有舊 row，跑 `psql $DATABASE_URL -c "SELECT count(*) FROM sys_tokens WHERE expires_at IS NULL"` 期望 `0`（backfill 完成）。再跑一次 `cargo run -p migration -- up` 驗 idempotent（第二次不報錯、無新 migration applied）對應 SC-402。

### Inner Push（§V 第一段尾）

- [ ] T006 [US1] 在 admin-api/ worktree 內 push fork branch：`cd admin-api && git push origin new-admin-rust-api` 推 T002 + T003 + T004 三個 inner commits 到 `https://github.com/miso168net/fork260509-soybean-admin-rust.git` 的 `new-admin-rust-api` branch。

### Outer Commit（§V 第二段）

- [ ] T007 [US1] 在 outer 倉做 SHA pin 提交：
   - 用 `cd admin-api && git rev-parse --short HEAD` 取 admin-api 新 SHA
   - 回 outer：在 `deploy/.env.example` 適當位置（建議 `APP_JWT_EXPIRE=` 行之後）加 `APP_REFRESH_TOKEN_EXPIRE=1209600`（research.md R9）
   - `git add admin-api deploy/.env.example`
   - outer commit：`chore(submodule): bump admin-api 到 <短SHA>: feature 4 GAP-1 refresh handler`（commit message body 列入 T002/T003/T004 三個 inner commit subjects + `deploy/.env.example` 加新 env var；範本見 research.md R10）

### US1 Acceptance（靜態）

- [ ] T008 [US1] 在 outer repo root 跑 7 條 static acceptance 並記錄結果到 `specs/004-gap-1-refresh-handler/acceptance-evidence/T008-static.md`：
   - (a) `RefreshTokenInput` struct 存在：`grep -q 'pub struct RefreshTokenInput' admin-api/server/model/src/admin/input/sys_authentication.rs`
   - (b) `/refreshToken` route 已註冊：`grep -q '"/refreshToken"' admin-api/server/router/src/admin/sys_authentication_route.rs`
   - (c) `refresh_token_handler` 存在且**不是** stub：`grep -A 12 'pub async fn refresh_token_handler' admin-api/server/api/src/admin/sys_authentication_api.rs | grep -q 'service.refresh_token'`
   - (d) `TAuthService` trait 含 `refresh_token` method + impl 含 `db.transaction`：`grep -q 'async fn refresh_token' admin-api/server/service/src/admin/sys_auth_service.rs && grep -q 'db.transaction' admin-api/server/service/src/admin/sys_auth_service.rs`
   - (e) `sys_tokens.expires_at` migration 已註冊：`grep -q 'add_expires_at_to_sys_tokens' admin-api/migration/src/lib.rs`
   - (f) `cargo build --release` 過 + `git submodule status` 兩行行首空格 + admin-api submodule SHA match T007 commit log
   - (g) **diff line cap 驗證**（SC-406 ≤ 120 行）：`cd admin-api && git diff <merge-base>...HEAD --shortstat | grep -oE '[0-9]+ insertion' | awk '{s+=$1} END {print s}'` 應 ≤ 120（含 migration 檔；不含 use 純空行 / 註解 — 但 shortstat 是粗略 cap、若稍超出可手動 inspect diff 排除 boilerplate 後核對）

   寫好 evidence 後 outer 倉 `git add specs/004-gap-1-refresh-handler/acceptance-evidence/T008-static.md && git commit -m "test(admin-api): T008 static acceptance evidence PASS"`。

**Checkpoint**: T001-T008 完成 = US1 MVP 主交付完成，可進 US2 dynamic acceptance / push outer / open PR。

---

## Phase 4: User Story 2 - 非法 / 過期 / 已 refreshed 的 refresh token 一律 401 (Priority: P2)

**Goal**: 對 admin-api refresh handler 的安全邊界做動態 wire-level 驗證 — 三個負面 case（不存在 / 過期 / 已 refreshed）全部回 envelope `code:401` + `sys_tokens` 表 0 變動。

**Independent Test**: 依本機 `cargo run` 或 feature 6 docker stack（任一）可運轉的 admin-api，跑 4 條負面 case curl + psql 驗 sys_tokens 表 row count 不變。

### US2 Acceptance（動態）

- [ ] T009 [US2] 動態 wire-level acceptance（同 task 涵蓋 US1 happy path + US2 negative case 共 3 個 SC：SC-403 / SC-404 / SC-405 / SC-407）：
   - 前置：本機跑 `cd admin-api && cargo run --release` 或 docker stack 起 admin-api（依環境二擇一）
   - **US1 happy path（SC-403 / SC-405）**：依 quickstart.md §B.2 跑 login → refreshToken curl，jq 驗 response code 200 + data.token + data.refreshToken 非空 + refreshToken ≠ 輸入；psql 查 sys_tokens 兩 row 狀態 `(REFRESHED, ACTIVE)`
   - **US2 negative cases（SC-404）**：跑 quickstart.md §B.3 的 5 個負面 case curl（不存在 token / 已 refreshed token / 強制過期 token / 空 body / 空字串）— 期望全部回 envelope `code:401`（不存在 / refreshed / 過期）或 `code:400`（validation：空 body / 空字串）；每 case 前後跑 `psql $DATABASE_URL -c "SELECT count(*) FROM sys_tokens"` 對比 count 應**不變**（FR-432 驗證）
   - **連續 rotation 對稱（SC-407）**：依 quickstart.md §B.4 連續兩次 refresh 應全部成功
   - 記錄結果到 `specs/004-gap-1-refresh-handler/acceptance-evidence/T009-dynamic.md`（含 happy + 5 個 negative + 連續 refresh 全部 curl + jq + psql 輸出）
   - 寫好 evidence 後 outer 倉 `git add specs/004-gap-1-refresh-handler/acceptance-evidence/T009-dynamic.md && git commit -m "test(admin-api): T009 dynamic acceptance US1 happy + US2 negative PASS"`
   - **若 cargo run 在本機 dev DB 也無法啟動**（環境 hard block，例如 envsubst template 缺、xdb 資源缺），此 task 標 follow-up、由 feature 6 merge 後跑；主 PR 仍可走（靜態 acceptance T008 已涵蓋 SC-401/402/406 程度的驗證）

**Checkpoint**: US2 動態驗證完成（或標 follow-up）後，整個 feature 4 主交付完成。

---

## Phase 5: Polish & Cross-Cutting

- [ ] T010 push outer：`git push origin 004-gap-1-refresh-handler`（依 CLAUDE.md §5 push 須 user 同意；**不要**在 implement 階段自動跑）。
- [ ] T011 同步 `docs/INTEGRATION-CHECKLIST.md` + 把 spec.md「待驗證的上游慣例」全 7 項 R1-R7 結論回填：
   - **CHECKLIST**：feature 4 那行的 spec/plan/impl 三欄 ☐ → ✅、狀態「待」→「完成」、加 commit SHA range（含 T007 + T008/T009 evidence commits）；跨 feature 待驗證項「在 sys_tokens 表加 expires_at 欄位」勾掉 ✅
   - **spec.md「待驗證的上游慣例」段 7 項全部前綴 ✅ 並 inline 結論**：
     - R1 → `✅ login verify_user 未檢查 user.status（line 241 TODO）— refresh handler 已對齊不檢查（mirror policy 落地）`
     - R2 → `✅ sys_tokens 16 既有欄位確認（id/access_token/refresh_token/status/user_id/username/domain/login_time/ip/port/address/user_agent/request_id/type/created_at/created_by），column 名 ip 而非 client_ip；本 feature 加 expires_at 為第 17 欄位`
     - R3 → `✅ TokenStatus 三 variants 確認（Active/Refreshed/Revoked，strum SCREAMING_SNAKE_CASE）；refresh 標 Refreshed`
     - R4 → `✅ helper 真實名為 generate_auth_output（位於 sys_auth_service.rs:336）；只生 JWT+Ulid 不寫 DB`
     - R5 → `✅ AccessTokenEvent::handle(db) 直接 sync INSERT；refresh 直接呼叫（不走異步 event）以滿足 atomic`
     - R6 → `✅ 既有無 ALTER 範例；本 feature 用 3-step（add nullable → raw SQL backfill → modify NOT NULL）`
     - R7 → `✅ AppError → Res::new_error envelope code:401，HTTP status 永遠 200（admin-web 攔截器既有約定）`
   - outer 倉 commit：`docs: INTEGRATION-CHECKLIST feature 4 標完成 + spec R1-R7 mirror writeback`

---

## Out-of-Scope (Follow-up，依後續 features)

- [ ] T012 (follow-up，依 feature 6 dockerfile-envsubst merge) docker 動態 acceptance smoke：依 quickstart.md §B 走 `docker compose up -d ... new-admin-rust-api` + nginx 同源 `/api/auth/refreshToken` curl 驗（happy path + 5 個負面 case）。記錄結果到 `specs/004-gap-1-refresh-handler/acceptance-evidence/T012-dynamic-docker.md`。

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: 無依賴。
- **Phase 2 (Foundational)**: 無（本 feature 不需）。
- **Phase 3 (US1)**: 依 Phase 1。
- **Phase 4 (US2)**: 依 Phase 3（admin-api 可運轉、refresh handler 已實作）。
- **Phase 5 (Polish)**: 依 Phase 3 完成（T010 push 與 T011 CHECKLIST 同步可在 T008 evidence commit 後做、T009 可選）。
- **T012 follow-up**: 依 features 6 merge。

### Within US1（Phase 3 內順序）

- T002 → T003 → T004 → T005 → T006 → T007 → T008（嚴格序列，§V 兩段式紀律 + cargo check / build 序列驗證）：
  - T002 是 migration + entity（含 cargo build -p model -p migration verify），先做以建立 DB schema
  - T003 是 input + route + handler stub（含 cargo check verify），先做 route scaffolding 避免 T004 router 引用 handler 不存在
  - T004 是 handler 完整實作 + service rotation transaction + access_token_event 補 expires_at + JwtConfig 加 field（含 cargo build --release verify），是核心 business logic
  - T005 是 migration dev verify（依 T002 已 commit、不依 T003/T004，但**必須在 T006 push 前**跑、確認 migration 在本機 dev DB run PASS）
  - T006 是 push fork（必須在 T002-T005 都完成後做）
  - T007 是 outer SHA pin commit（必須在 T006 push 後做）
  - T008 是 static acceptance evidence file 寫入 + commit

### Within US2

- T009 一個 task；依 Phase 3 全部完成。

### Polish 內

- T010（push outer）依 user 同意；T011（CHECKLIST 同步 + R1 writeback）獨立可隨時做。

### Parallel Opportunities

- **無 [P] 機會**：本 feature 全 task 序列依賴（§V 兩段式紀律 + cargo check 序列驗證 + dev DB migration 驗證需要序列）。
- 唯一可考慮：T011 CHECKLIST 同步可與 T010 push outer 並行（不同 effect），但實務上順手做完一個再做另一個更安全。

---

## Implementation Strategy

### MVP First（US1 P1 only）

US1 即 MVP — T001-T008 = 主交付：

1. T001 健檢 worktree
2. T002 inner: migration + entity（含 cargo build -p model -p migration）
3. T003 inner: input + route + handler stub（含 cargo check）
4. T004 inner: handler 完整 + service rotation + access_token_event 補 + JwtConfig（含 cargo build --release）
5. T005 migration dev DB verify
6. T006 inner push fork
7. T007 outer SHA pin commit + .env.example
8. T008 static acceptance + evidence commit
9. 此時可 push outer（T010）+ open PR（user 同意後）

預估時間：60-90 分鐘（含 cargo build 兩次、首次 build 可能 10-15 分鐘；handler/service 含 transaction 邏輯需仔細推敲）。

### Incremental Delivery

10. T009 US2 dynamic acceptance（cargo run 或 feature 6 docker）
11. T011 CHECKLIST sync + R1 writeback
12. T012 follow-up（feature 6 merge 後 docker 端 dynamic）

### Parallel Team Strategy

不適用 — 本 feature 規模小、§V 紀律強，單 implementer 連續執行最有效。

---

## Notes

- §V 兩段式 NON-NEGOTIABLE：T006 inner push fork 與 T007 outer SHA pin commit 兩段紀律不可省略。
- **T002 migration + T004 access_token_event 補 expires_at 是耦合對**：T002 加 NOT NULL 欄位後，既有 login 路徑會因寫 sys_tokens row 沒填 expires_at 而 break。T004 內含的 access_token_event 補 expires_at 是修這個對等問題。如果只跑 T002 + T005 而不跑 T004，login 會 break — implementer **必須**把 T002-T004 視為**不可分割的單元**、不要在 T002/T003 commit 後暫停測試 login。
- T003 的「handler stub」是工程取巧（避免 router 引用未實作 handler）— T004 必須把 stub 換成真實作。如果 implementer 偏好把 T003+T004 合併為一個更大的 inner commit，也可（但 commit message 要對應廣域）。
- T008 evidence file 格式參考 feature 3 `specs/003-.../acceptance-evidence/T007-static.md`。
- T011 R1 writeback 是把 research.md R1 的結論「login 不查 user.status → refresh 也不查」回填到 spec.md「待驗證的上游慣例」第 1 條前面加 ✅、改為 prefix `✅ 已驗 (T011/2026-05-11)`。
- 本 feature 是**第二個動 admin-api submodule** 的 feature（feature 3 已驗證兩段式流程）— T001-T008 可重用 feature 3 T001-T007 心智模型，差異僅在改動範圍（feature 4 較廣，3 個 inner commits 而非 2 個）。
- 動態 acceptance（T009/T012）跨 feature 依賴 → 標 follow-up、不阻塞主 PR merge。
- cargo build 第一次可能慢（~15 分鐘）— feature 3 已 build 過、target/ cache 應在；但 access_token_event signature 改 generic 可能觸發較廣的重編。預留時間。
