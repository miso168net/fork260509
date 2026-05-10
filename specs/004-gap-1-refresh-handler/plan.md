# Implementation Plan: gap-1-refresh-handler

**Branch**: `004-gap-1-refresh-handler` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-gap-1-refresh-handler/spec.md`

## Summary

新增 `POST /auth/refreshToken` endpoint（admin-api 倉）：admin-web 帶舊 refresh token 來，admin-api 驗證後 rotate 出新 access + refresh token、寫新 `sys_tokens` row、標舊 row 為 `REFRESHED`。涵蓋 GAP-1，採 INTEGRATION-PLAN §4 GAP-1 方案 A（DB-backed）。

技術路線：

1. **input layer**：新 struct `RefreshTokenInput { refresh_token: String }` 在 `model/admin/input/sys_authentication.rs`，含 `#[serde(rename = "refreshToken")]` + `#[validate(length(min = 1))]`。
2. **route**：在 `init_authentication_router()` 加 `.route("/refreshToken", post(...))`，掛在 `/auth` 同層、不過 Casbin / User extension。
3. **handler**：`refresh_token_handler` 接 `ConnectInfo` + `HeaderMap` + `UserAgent` + `RequestId` + `Extension(service)` + `ValidatedForm(input)`（與 login handler 同 signature pattern），組 `LoginContext` 後委派給 service。
4. **service**：`refresh_token(input, context)` 在 `SysAuthService`，流程 = DB 查舊 row（`status='ACTIVE' AND expires_at > now()`）→ 重用 `generate_auth_output()` 生新 token pair → Sea-ORM transaction 內：INSERT 新 sys_tokens row（透過 `AccessTokenEvent::handle` 或對等內聯 insert，含 `expires_at = now() + REFRESH_EXPIRE`）+ UPDATE 舊 row `status='REFRESHED'`。失敗（查無 row / DB error）→ `AppError { code: 401, message: ... }`。
5. **migration**：新 migration `mYYYYMMDD_HHMMSS_add_expires_at_to_sys_tokens.rs` 用 3-step ALTER：(a) `add_column(expires_at TIMESTAMP NULL)`、(b) raw SQL `UPDATE sys_tokens SET expires_at = created_at + INTERVAL '14 days' WHERE expires_at IS NULL`、(c) `alter_column(expires_at NOT NULL)`。
6. **entity**：`model/admin/entities/sys_tokens.rs` 加 `pub expires_at: DateTime` field（對齊 migration column）。
7. **config**：新 env var `APP_REFRESH_TOKEN_EXPIRE`（default 1209600 = 14 days）對齊既有 `APP_JWT_EXPIRE` 命名 pattern；plan 階段 read `jwt_config.rs` 與 `env_config.rs` 確認載入路徑。

走 constitution §V **兩段式 submodule commit**（inner: admin-api worktree 內、outer: `chore(submodule): bump admin-api`）。動態驗證依本機 `cargo run` 或 feature 6 docker stack。

## Technical Context

**Language/Version**: Rust 1.86+（admin-api 既有，無變更）

**Primary Dependencies**（全部既有、不新增）:
- `axum 0.8` — web framework
- `sea-orm 1.1` / `sea-orm-migration 1.1` — ORM + migration
- `validator` — input validation（既有 ValidatedForm 框架）
- `ulid` — refresh token 生成（既有）
- `chrono` — DateTime（既有）
- `serde` — JSON serialize / deserialize
- `tracing` — 既有 instrument macro
- `server_constant::definition::consts::TokenStatus` — 既有 enum，含 `Active` / `Refreshed` / `Revoked` 三 variants

**Storage**: Postgres 17（既有），`sys_tokens` 表加 `expires_at TIMESTAMP NOT NULL` 欄位（透過新 migration backfill `created_at + INTERVAL '14 days'`）

**Testing**:
- 靜態：`cargo build --release -p server-api -p server-service -p server-model`、`cargo check`、grep `RefreshTokenInput` / `/refreshToken` / `refresh_token_handler` 全部命中
- migration：`cargo run -p migration -- up`（從空 DB 跑 PASS、從既有 DB 跑 PASS、第二次 idempotent）
- 動態（本機 cargo run 或 feature 6 docker）：curl login → curl refreshToken → psql 查 sys_tokens 兩 row 狀態 + expires_at

**Target Platform**: Linux x86_64（admin-api docker image runtime；本機 dev 可 `cargo run` 在 macOS/Linux/WSL）

**Project Type**: Rust backend endpoint + migration patch — admin-api 倉內：
- 5 個檔小幅修改（input / route / api / service / entity）
- 1 個檔新增（migration）
- 1 個檔小改（migration/src/schemas/mod.rs 註冊 + migration/src/lib.rs 加入 `Migrator::migrations()` 序列）

**Performance Goals**:
- diff ≤ 120 行（SC-406 cap，含 migration）
- cargo build PASS、無 new warnings（SC-401）
- migration up idempotent（SC-402）
- refresh request 延遲 ≤ login 既有水準（單 SELECT + INSERT + UPDATE，本機 dev <50ms）

**Constraints**:
- 單一倉（admin-api），跨 §V 兩段式 commit
- 不動 admin-web 任何檔（FR-451）
- 不引新 crate（FR-453）
- 不動 Casbin / sys_endpoint（FR-454）
- 不改 access token JWT 簽章 / `APP_JWT_*` env（FR-452）
- User.status 檢查 mirror login（login 未檢查 → refresh 也不檢查）— Q1 clarification

**Scale/Scope**: ~80 行 Rust（4 個 .rs 檔小幅新增）+ ~30 行 migration + ~3 行 entity field + ~2 行 lib.rs/mod.rs 註冊 = total ≈ 115 行（在 SC-406 ≤120 cap 內）。

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 原則 | 通過 / 違反 / 不適用 | 證據 |
|---|---|---|
| **§I 同源反代優先** | N/A | 不動部署層；nginx 反代由 feature 1（已 merged）負責；不在 Rust 加 CorsLayer |
| **§II 外部化設定** | ✅ 通過 | 新 env var `APP_REFRESH_TOKEN_EXPIRE` 對齊既有 `APP_JWT_EXPIRE` 命名 pattern + envsubst 框架（feature 6 接管）；不 hardcode 過期值 |
| **§III 最小 GAP 修補** | ✅ 通過 | spec.md Scope 顯式列 GAP-1 + 「單一 GAP、單一倉、單一主題；不合併」說明；FR-450 ~ FR-455 六個 negative requirement 劃定範圍邊界；SC-406 鎖 ≤ 120 行；inner commits 將拆 (a) entity+migration、(b) input+route+handler+service、(c) lib.rs 註冊 — 三個 inner commits 保留語意拆分 |
| **§IV 上游驗證** | ✅ 通過 | spec Assumptions 列 7 項 §IV 待驗證項；Phase 0 research 已對其中 6 項 read code 解析（剩餘 1 項 `APP_REFRESH_TOKEN_EXPIRE` 載入路徑、在 implementation 階段對照 `jwt_config.rs` confirm） |
| **§V 兩段式 submodule commit (NON-NEGOTIABLE)** | ✅ 通過（將遵守） | 本 feature 動 admin-api/ submodule，**必走兩段 commit**：第一段 admin-api/ worktree 內 + push fork branch `new-admin-rust-api`；第二段 outer `chore(submodule): bump admin-api 到 <SHA>` + push outer。重用 feature 3 模式 |
| **§VI Spec-Driven Development** | ✅ 通過 | spec → clarify（1 question Q1 user.status mirror policy）→ 本 plan → tasks → analyze → implement 流程已具現化 |
| **§VII Conventional Commits 中文** | ✅ 通過（流程內遵循） | inner: `feat(admin-api): GAP-1 ...`；outer: `chore(submodule): bump admin-api 到 <SHA>: GAP-1 refresh handler` |

**附加技術棧鎖定**：admin-api 既有 Rust 1.86 / axum 0.8 / Sea-ORM 1.1 — 全對齊 constitution §技術棧。本 feature 不改任何依賴版本。

**結論**：Constitution Check **PASS**，無違反、無 Complexity Tracking 需 justify。

## Project Structure

### Documentation (this feature)

```text
specs/004-gap-1-refresh-handler/
├── plan.md                          # 本檔
├── research.md                      # Phase 0：7 個 §IV 待驗證項的具現化解析 + atomic rotation 策略
├── data-model.md                    # Phase 1：entity / column / DTO / status 流轉
├── quickstart.md                    # Phase 1：implementer 兩段式 + operator 動態 smoke
├── contracts/
│   └── refresh-token-endpoint.md    # POST /auth/refreshToken wire-level 契約
├── checklists/
│   └── requirements.md              # 既有，全綠
└── tasks.md                         # /speckit-tasks 產出（Phase 2，本 plan 不負責）
```

### Source Code（admin-api 倉內，feature 將動）

本 feature 改動全部在 **admin-api/** worktree 內（= `fork260509-soybean-admin-rust@new-admin-rust-api` branch；本機透過 worktree 在 `admin-api/` 操作；外層 `new-admin-root` 透過 submodule SHA pin 追蹤）：

```text
admin-api/                                                                      ← worktree（branch: new-admin-rust-api）
├── server/model/src/admin/input/sys_authentication.rs                          ★ 加 RefreshTokenInput struct
├── server/model/src/admin/entities/sys_tokens.rs                               ★ 加 expires_at: DateTime field
├── server/router/src/admin/sys_authentication_route.rs                         ★ init_authentication_router() 加 .route("/refreshToken", post(...))
├── server/api/src/admin/sys_authentication_api.rs                              ★ 加 refresh_token_handler
├── server/service/src/admin/sys_auth_service.rs                                ★ 加 trait method `refresh_token` + impl + ulid 重用 generate_auth_output
├── migration/src/schemas/mYYYYMMDD_HHMMSS_add_expires_at_to_sys_tokens.rs      ★ 新檔（3-step ALTER）
├── migration/src/schemas/mod.rs                                                ★ 加 `pub mod m...add_expires_at_to_sys_tokens;`
└── migration/src/lib.rs                                                        ★ 加進 Migrator::migrations() 序列尾端
```

**外層 `new-admin-root`** 只追蹤 admin-api submodule 的 SHA pin（gitlink）+ 本 spec/plan/tasks 文件。

**Structure Decision**: 採 constitution §V 兩段式 submodule commit 模式（與 feature 3 同流程，目標 submodule 同為 admin-api）：

1. **第一段**（admin-api/ worktree 內）：建議拆 3 個 inner commits：
   - inner commit 1：`feat(admin-api): GAP-1 加 sys_tokens.expires_at migration + entity`（migration 新檔 + entity 加 field + mod.rs/lib.rs 註冊）
   - inner commit 2：`feat(admin-api): GAP-1 加 RefreshTokenInput + /auth/refreshToken route`（input struct + route 註冊）
   - inner commit 3：`feat(admin-api): GAP-1 加 refresh_token_handler + service rotation`（handler + service method + transaction）
   - `git push origin new-admin-rust-api` 推到 fork remote

2. **第二段**（outer `new-admin-root` 倉）：
   - 1 個 outer commit：`chore(submodule): bump admin-api 到 <短SHA>: feature 4 GAP-1 refresh handler`
   - push outer

理由：

1. **§V NON-NEGOTIABLE**：違反 = outer SHA pin 與 fork HEAD 不同步
2. **3 個 inner commits**（migration / route / service）讓 reviewer 可獨立 review schema 變動、API surface 變動、business logic 變動
3. **outer 單一 commit cover 三 inner pin shifts**：跟 feature 3 同模式

## Phase 0: Outline & Research

**Status**: 即將執行（本 plan commit 後產出 `research.md`）。

**Scope**：spec 的「待驗證的上游慣例」7 項，加上 Q1 clarification 落地後的 mirror policy 具現化、atomic rotation 策略決定：

| # | 項 | 解析方法 | 預期結論 |
|---|---|---|---|
| R1 | login handler 是否查 user.status / is_deleted | read `sys_auth_service.rs::verify_user` | **未檢查**（line 241 有 `//TODO validate user status`）— Q1 mirror → refresh 也不檢查 |
| R2 | `sys_tokens` 既有欄位精確命名 | read `sys_tokens.rs` entity + migration `m20241023_091204_create_sys_tokens.rs` | 欄位是 `id` / `access_token` / `refresh_token` / `status` / `user_id` / `username` / `domain` / `login_time` / `ip` / `port` / `address` / `user_agent` / `request_id` / `type` / `created_at` / `created_by`（**沒有** `client_ip` / `user_name`）— spec assumptions 用「client_ip」是概念，實際 column 是 `ip` |
| R3 | `TokenStatus` enum variants + serialize | read `server_constant::definition::consts.rs` | 3 個 variants：`Active` / `Refreshed` / `Revoked`，strum `SCREAMING_SNAKE_CASE` — refresh 後標 `Refreshed`（精準）非 `Revoked`（保留給 logout） |
| R4 | login `generate_access_token` helper 精確名 / signature / 寫 sys_tokens row 在 helper 內還是 service 內 | read `sys_auth_service.rs::generate_auth_output` + `pwd_login` + `send_login_event` | 實際名是 `generate_auth_output(user_id, username, role_codes, domain_code, organization_name, audience)`；**helper 只負責生 JWT + Ulid**，**不**寫 sys_tokens；寫 row 由 `send_login_event` 派 `AuthLoggedInEvent` → `AuthEventHandler::handle_login` → `AccessTokenEvent::handle(db)`（同步 insert） |
| R5 | `AccessTokenEvent` 寫入 sys_tokens 的介面 | read `access_token_event.rs` | `AccessTokenEvent { access_token, refresh_token, user_id, username, domain, ip, port, address, user_agent, request_id, login_type }` + `.handle(db)` 同步 INSERT。refresh 可重用此 struct |
| R6 | migration 框架對 NOT NULL with backfill | read 既有 `create_*` migrations + sea-orm docs（內推） | 既有 migration 全是 `create_table`，無 `alter_table` 範例。**首個 ALTER**。採 3-step：(a) add nullable → (b) raw SQL UPDATE backfill → (c) alter NOT NULL |
| R7 | `Res::new_data` / `AppError` envelope | read `res.rs` + `error.rs` | `Res::new_data(data)` → `{ code: 200, data, msg: "success", success: true }`；`AppError { code: 401, ... } → IntoResponse` → `Res::<()>::new_error(401, msg)` → `{ code: 401, data: null, msg, success: false }`，**HTTP status 永遠 200**（envelope code 才是 caller 的判斷依據）。對齊 admin-web 攔截器既有行為 |
| R8 | atomic rotation 策略決定 | spec FR-431 留 plan 決定 | **Sea-ORM transaction** 包覆「INSERT 新 row → UPDATE 舊 row REFRESHED」兩 statement；INSERT 在先：新 row 確定寫入後才標舊 row、若 transaction commit 失敗整個 rollback、若 INSERT 後但 UPDATE 前 panic → transaction abort 兩個都不生效。Sea-ORM 用 `db.transaction::<_, _, AppError>(|txn| Box::pin(async move { ... }))` |
| R9 | `APP_REFRESH_TOKEN_EXPIRE` env var 載入路徑 | implementation 階段 read `server/config/src/model/jwt_config.rs` + `env_config.rs` | plan 階段先假設「複用既有 `APP_` prefix + `JwtConfig` struct 加 `refresh_token_expire: u64` field（default 1209600）」；若 config 框架要求 separate struct，加 `RefreshTokenConfig` |
| R10 | §V 兩段式 commit 流程具現化（admin-api 視角） | reuse feature 3 模式 | inner: `cd admin-api && git add ... && git commit && git push origin new-admin-rust-api`；outer: `git add admin-api && git commit -m "chore(submodule): bump admin-api ..." && git push` |

**Output**: `research.md`（10 個 verification + 1 個 commit 流程）

## Phase 1: Design & Contracts

**Prerequisites**: research.md 完成。

### 1.1 Data Model

`data-model.md` 列：

- **新 entity field**：`sys_tokens.expires_at: DateTime`（migration 加；既有 row backfill `created_at + INTERVAL '14 days'`）
- **新 DTO struct**：`RefreshTokenInput { refresh_token: String }`（input layer，JSON key `refreshToken`）
- **重用 output struct**：`AuthOutput { token, refresh_token }`（feature 3 已 camelCase 對齊，不變）
- **TokenStatus 狀態流轉圖**：`Active` → `Refreshed`（refresh handler）/ `Active` → `Revoked`（手動 logout / 強制下線，本 feature 不負責）
- **sys_tokens row 寫入欄位 mapping**（refresh 新 row vs login 新 row 對照）

無新表、無 column rename、無 FK 變更。

### 1.2 Contracts

#### `contracts/refresh-token-endpoint.md`

POST `/auth/refreshToken` wire-level 契約：

- **Request**：method=POST、Path=`/auth/refreshToken`（nginx 同源 `/api/auth/refreshToken`）、Header `Content-Type: application/json`、Body `{"refreshToken": "<ulid-string>"}`
- **Success Response** (HTTP 200)：`{"code": 200, "data": {"token": "<jwt>", "refreshToken": "<new-ulid>"}, "msg": "success", "success": true}`
- **Failure Response** (HTTP 200，envelope `code:401`)：`{"code": 401, "data": null, "msg": "Refresh token invalid", "success": false}`
- **Validation Error** (HTTP 200，envelope `code:400` via `AppError::from(JwtError)`)：body 無 `refreshToken` field、或為空字串 → ValidatedForm rejects
- **副作用**：rotation 成功時 sys_tokens 表淨增 1 row（新 ACTIVE 含 expires_at）+ 舊 row status `ACTIVE` → `REFRESHED`；rotation 失敗時 sys_tokens 表 0 變動

含 admin-web 端消費路徑（`fetchRefreshToken` → service.ts → axios interceptor → 401 retry）+ 與 login response shape 完全對稱的說明。

### 1.3 Quickstart

`quickstart.md` 給 implementer + operator 用：

- **implementer**：
  1. admin-api/ worktree 健檢（`git status` + branch = `new-admin-rust-api`）
  2. 改 7 個檔（5 mod + 2 add）的精確 diff hint
  3. `cargo build` + `cargo check` 驗證
  4. `cargo run -p migration -- up`（本機 dev DB）
  5. 三段 inner commits（依 Project Structure 拆法）
  6. `git push origin new-admin-rust-api`
  7. 回外層 `git add admin-api && git commit && git push`

- **operator**（依本機 cargo run 或 feature 6 docker stack）：
  1. login 拿 refresh token
  2. curl refreshToken endpoint 驗 happy path
  3. psql 查 sys_tokens 兩 row 狀態
  4. 三個負面 case curl（不存在 / 過期 / 已 refreshed）
  5. 連續兩次 refresh 驗 rotation 對稱

不含 admin-api 一般 dev 流程（cargo run / sea-orm migrate / Casbin 設定 — 屬 admin-api 倉自身 README 範圍）。

### 1.4 Agent Context Update

更新 outer 倉 `CLAUDE.md` 內 `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` 區塊（line 249-254），把 active 從 feature 3（已 merged 為里程碑）切到 feature 4。

**Output**: `data-model.md`、`contracts/refresh-token-endpoint.md`、`quickstart.md`、`CLAUDE.md` SPECKIT 區塊更新。

## Phase 2 (out of scope for /speckit-plan)

`/speckit-tasks` 預期粒度（與 feature 3 同模式，~10-12 個 task）：

- T001 (setup): admin-api/ worktree health check + 確認 `new-admin-rust-api` branch
- T002 (entity+migration): sys_tokens entity 加 expires_at + 新 migration 檔 + mod.rs/lib.rs 註冊 + `cargo build -p model -p migration` 驗
- T003 (migration run): `cargo run -p migration -- up`（dev DB）驗 idempotent + psql 查欄位
- T004 (input+route): RefreshTokenInput struct + route 註冊 + `cargo check -p model -p router` 驗
- T005 (handler): refresh_token_handler 加在 api/sys_authentication_api.rs
- T006 (service): SysAuthService trait method `refresh_token` + impl + transaction logic
- T007 (cargo build): `cargo build --release` PASS 驗
- T008 (inner commits): 拆 3 個 inner commits（依 Project Structure §1 拆法）+ `git push origin new-admin-rust-api`
- T009 (outer commit): outer `git add admin-api && git commit -m "chore(submodule): ..." && git push`
- T010 (static acceptance): grep handler 註冊 + route 註冊 + migration 註冊 evidence
- T011 (dynamic acceptance): 本機 `cargo run` 跑 7 條 curl 驗 happy + 3 負面 + 連續 refresh
- T012 (CHECKLIST sync): 標 feature 4 完成 + 把跨 feature「sys_tokens.expires_at」勾掉 + 加 R1 mirror 結果回 spec.md

## Constitution Check — Post-Design Re-evaluation

Phase 0 + Phase 1 產出落地後回掃 7 條原則：

| 原則 | 狀態 | Phase 0/1 補強證據 |
|---|---|---|
| §I 同源反代 | N/A | 不變 |
| §II 外部化設定 | ✅ | research R9 把 `APP_REFRESH_TOKEN_EXPIRE` env var 載入路徑列入 implementation 階段 confirm |
| §III 最小 GAP | ✅ | scope 維持 ≤ 120 行；contracts 把 wire shape normative |
| §IV 上游驗證 | ✅ | research.md R1-R7 把 7 條待驗證項全部 read code 解析、R8/R9 做 plan 階段決策 |
| §V 兩段式 submodule | ✅ | research.md R10 admin-api 版兩段式藍本（reuse feature 3 結構）；3 inner commits + 1 outer commit |
| §VI Spec-Driven Development | ✅ | 流程完整、Q1 clarification 已落地 |
| §VII Conventional Commits 中文 | ✅ | 3 inner / 1 outer commit message 範本鎖定 |

**結論**：Post-design Constitution Check **PASS**，與 pre-design 一致。

## Complexity Tracking

> **Constitution Check 全部通過、無違反，本表留空。**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (無) | — | — |
