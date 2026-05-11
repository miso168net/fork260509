# Feature Specification: gap-1-refresh-handler（admin-api 新增 POST /auth/refreshToken endpoint）

**Feature Branch**: `004-gap-1-refresh-handler`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "feature 4 gap-1-refresh-handler"

## Scope（依 constitution §III）

| 項目 | 說明 |
|---|---|
| 主題 | admin-api 新增 refresh token endpoint：消費 admin-web 傳來的 refresh token，rotate 後發新 access + refresh token，並維護 `sys_tokens` audit trail |
| 涵蓋 GAP | **GAP-1**（`POST /auth/refreshToken` handler 完全不存在） |
| 倉/層 | **admin-api**（=`fork260509-soybean-admin-rust@new-admin-rust-api`，本機透過 worktree 在 `admin-api/` 操作） |
| 分組理由 | 單一 GAP、單一倉、單一主題；不合併（規模 ~80 行 Rust + 1 個 migration 已超過「小修補合併」門檻；獨立 feature 利 review）。 |
| 不涵蓋 | admin-web 端任何改動（既有 `fetchRefreshToken` 已對 camelCase）、stateless JWT 改造（決策走 DB-backed，見 INTEGRATION-PLAN §4 GAP-1 方案 A）、refresh token TTL 之外的 jwt access token TTL 變更、login handler 行為變更、其他 GAP 修補 |
| 規模 | ~80 行 Rust（4 個檔小幅新增） + 1 個 migration 檔（新增 `sys_tokens.expires_at` 欄位） |

## Clarifications

### Session 2026-05-11

- Q: refresh 進來時 admin-api 是否要重新驗 user 帳號狀態（active / disabled / deleted）？ → A: **對齊 login 既有政策** — plan 階段 read 既有 login handler 取得 user.status 檢查方式並沿用；login 若已查 user.status，refresh 跟著查（同樣的 query / JOIN / 失敗 envelope）；login 沒查則 refresh 也不查。避免兩條 token 發放路徑語意 drift。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - admin-web 用合法 refresh token 換新一組 token（Priority: P1）

當 admin-web 的 access token 過期或被攔截器標 401 時，admin-web 會把 storage 內的 refresh token 帶到 `POST /auth/refreshToken`。admin-api MUST 驗證該 token 仍有效（DB 內 `sys_tokens.status='ACTIVE'`、`expires_at > now`），通過則：
1. 把舊 token row 標為 `REFRESHED`
2. 為同一 user 重新發新 access token（JWT）與新 refresh token（ULID）
3. 新 row 插入 `sys_tokens` 表（與 login 同樣的 audit 流程，`status='ACTIVE'`、`expires_at=now+APP_JWT_REFRESH_TOKEN_EXPIRE`）
4. 回傳 `AuthOutput { token, refreshToken }`（同 login response shape，已是 camelCase — feature 3 已對齊）

**Why this priority**：feature 4 的核心唯一目的就是「讓 admin-web session 能持續」。沒有 P1 = feature 沒交付。admin-web 攔截器在 access token 401 時會 trigger refresh flow，refresh 失敗會 force re-login（破壞 UX）。

**Independent Test**:

1. 前置：feature 1（deploy stack）+ feature 3（admin-api response camelCase）+ feature 6（envsubst startup，未開但靜態驗證可代替）任一可運轉的 admin-api 容器（or `cargo run` 本機跑）
2. 用 `POST /auth/login` 拿 `{ token, refreshToken }`
3. 跑 `curl -sS -X POST http://localhost:8080/api/auth/refreshToken -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$REFRESH\"}" | jq`
4. **預期**：response body `{ code: 200, data: { token: "...", refreshToken: "..." }, message: "..." }`；兩個 token 都非空且**與輸入不同**（rotation 已執行）
5. `psql` 查 `sys_tokens` 看舊 row `status='REFRESHED'`、新 row `status='ACTIVE'`

**Acceptance Scenarios**:

1. **Given** admin-api 容器 healthy + 已 login 拿到 refresh token，**When** 跑 refreshToken curl 帶該 token，**Then** response code 200 + `data.token` 與 `data.refreshToken` 為非空字串、且 `data.refreshToken` 與輸入不同（rotation）。
2. **Given** refresh 完成，**When** 查 `sys_tokens`，**Then** 找到 2 個 row：原 row `status='REFRESHED'`、新 row `status='ACTIVE'` 且 `expires_at > now`，皆關聯同一 `user_id`。
3. **Given** refresh 成功拿到新 access token，**When** 拿新 token 跑 `GET /auth/getUserInfo`，**Then** 200 OK（新 access token 簽章有效）。
4. **Given** 新 refresh token，**When** 立刻再跑 refreshToken curl，**Then** 同樣 rotate 成功（連續 refresh 行為對稱）。

---

### User Story 2 - 非法 / 過期 / 已 refreshed / 已 revoked 的 refresh token 一律 401（Priority: P2）

當 admin-web 帶來的 refresh token 不存在、已過期、或已被前次 refresh rotate 掉時，admin-api MUST 一律回 401（envelope `code:401`，與 login 失敗對齊）；MUST NOT 發新 token、MUST NOT 動 DB（其他 row 不影響）。

**Why this priority**：安全邊界。沒有 P2 = replay attack（攻擊者拿舊 refresh token 永遠能換新 token）。

**Independent Test**:

1. 前置同 US1
2. 三種非法 case：
   - 帶完全亂編的 ULID 字串
   - 帶已過期的 refresh token（手動 `UPDATE sys_tokens SET expires_at=now()-interval '1 hour'`）
   - 帶已被前次 refresh 用過 → rotate 後標 `Refreshed` 的 token
3. **預期**：三種 case 全回 401（envelope `code:401`），response 不含 `data.token`

**Acceptance Scenarios**:

1. **Given** 帶完全不存在的 refresh token 字串，**When** 跑 refreshToken curl，**Then** response `code:401`、message 為人類可讀錯誤（如 "Refresh token invalid" 或對齊上游 i18n key）。
2. **Given** 帶已過期的 refresh token（`expires_at < now`），**When** 跑 refreshToken curl，**Then** response `code:401`、且 `sys_tokens` 表內該 row 不被本次呼叫修改（status 留原值）。
3. **Given** 帶已 refreshed 或 revoked 的 refresh token，**When** 跑 refreshToken curl，**Then** response `code:401`、無新 row 寫入。
4. **Given** body 為 `{}` 或 `{"refreshToken":""}`，**When** 跑 refreshToken curl，**Then** validation error（400 或對齊既有 `ValidatedForm` 失敗行為），不進 DB 查詢。

### Edge Cases

- **同一 refresh token 並發 race**（admin-web 兩個 tab 同時 401 → 同時打 refreshToken）：本 feature 不做 row lock 或樂觀鎖；接受「先到先 rotate、後到拿到 `REFRESHED` 狀態 → 401」。admin-web 端攔截器若需 dedupe 是 admin-web 責任（features 5 可能涵蓋）。
- **`sys_tokens` 表 `expires_at` 欄位不存在**：本 feature MUST 含新 migration 把欄位加上（既有 row 給 default 值 `created_at + INTERVAL '14 days'`）。
- **JWT 簽發時 `JWT_SECRET` 環境變數未設**：與 login handler 同樣失敗行為（既有 startup-time fail-fast，不在本 feature 範圍）。
- **refresh token 已被人手動 DB DELETE**：與「不存在」case 同（401）。
- **time skew**：refresh token 過期判斷用 DB 時間（Postgres `now()`），不用 Rust process 時間，避免容器時鐘飄移觸發誤判。service 層比較 `expires_at` 用「query WHERE 子句帶 `expires_at > now()`」。
- **AccessTokenEvent / audit 既有流程**：本 feature 新 row 寫入流程 MUST 沿用既有 `AccessTokenEvent` 或對等機制（login 寫入時用什麼，refresh 就用什麼）；不引入新的 event 種類。
- **rotate 後新 refresh token 沒被 admin-web 存起來**（admin-web bug 或網路中斷）：本 feature 接受此情況的後果（user 變成「下次再 401 時、之前 rotate 的 refresh 已被 revoke」，被迫重 login）。屬 client 責任。

## Requirements *(mandatory)*

### Functional Requirements

#### admin-api 新 input 結構（`server/model/src/admin/input/sys_authentication.rs`）

- **FR-401**: MUST 新增 struct `RefreshTokenInput { refresh_token: String }`，含 `#[derive(Deserialize, Validate)]`，並對 `refresh_token` field 加 `#[serde(rename = "refreshToken")]` 讓 JSON body key 為 camelCase（與 admin-web 端 `Api.Auth.LoginToken.refreshToken` 對齊）。
- **FR-402**: `refresh_token` field MUST 帶 `validator` crate 的非空約束（如 `#[validate(length(min = 1))]`），讓空字串 / 缺欄位透過既有 `ValidatedForm` 攔截器在進 service 前就回 validation error。

#### admin-api 新 route（`server/router/src/admin/sys_authentication_route.rs`）

- **FR-410**: MUST 在既有 `init_authentication_router()` 內加一行 `.route("/refreshToken", post(SysAuthenticationApi::refresh_token_handler))`，掛在既有 `/auth` nest 下（最終 URL = `/auth/refreshToken`，與 admin-web `fetchRefreshToken` 期望對齊）。
- **FR-411**: 新 route MUST NOT 套用「需 access token 通過 Casbin」的 middleware（refresh 不應依賴已過期的 access token；身份驗證來自 refresh token 本身）。掛點與 `/auth/login` 在同個層級即可。

#### admin-api 新 handler（`server/api/src/admin/sys_authentication_api.rs`）

- **FR-420**: MUST 加 `pub async fn refresh_token_handler(ConnectInfo(addr): ConnectInfo<SocketAddr>, headers: HeaderMap, TypedHeader(user_agent): TypedHeader<UserAgent>, Extension(request_id): Extension<RequestId>, Extension(service): Extension<Arc<SysAuthService>>, ValidatedForm(input): ValidatedForm<RefreshTokenInput>) -> Result<Res<AuthOutput>, AppError>` — 與既有 `login_handler` signature 對稱（refresh 寫 sys_tokens 新 row 需要 IP / port / user_agent / request_id 等 context）。handler body 在組好 `LoginContext` 後委派給 service：`service.refresh_token(input, context).await.map(Res::new_data)`。
- **FR-421**: handler MUST NOT 自行做 DB 查詢 / token 生成（business logic 全在 service 層）— 符合既有 login handler 的分層慣例。

#### admin-api 新 service 邏輯（`server/service/src/admin/sys_auth_service.rs`）

- **FR-430**: MUST 加 `pub async fn refresh_token(&self, input: RefreshTokenInput, context: LoginContext) -> Result<AuthOutput, AppError>` 方法（接 input + context 與既有 `pwd_login(input, context)` signature 對稱）。流程：
  1. 從 `sys_tokens` 表查 `refresh_token = $1 AND status = 'ACTIVE' AND expires_at > now()`；無 row → `AppError { code: 401, message: "Refresh token invalid" }`（或對齊上游既有 i18n key）。status 欄位實際存的是 SCREAMING_SNAKE_CASE 字串（`TokenStatus` enum strum serialize）。
  2. 把該 row 的 `status` 標為 `'REFRESHED'`（不是 `REVOKED`；上游 `TokenStatus` enum 已預留 `Refreshed` variant 表「已被刷新」、`Revoked` 留給手動 logout / 安全強制下線）— 不刪除 row，保留 audit。
  3. 用該 row 的 `user_id` 重新生成 access token + refresh token（沿用既有 `generate_auth_output(user_id, username, role_codes, domain_code, organization_name, audience)` helper — R4 確認位於 `sys_auth_service.rs`；access token 期限沿用既有 `APP_JWT_EXPIRE`、新 refresh token 用 ULID 新生）。
  4. 新 row 插入 `sys_tokens` 表（與 login 寫入同樣的欄位：`access_token` / `refresh_token` / `user_id` / `username` / `domain` / `login_time` / `ip`（**非** `client_ip` — 實際 column 名；refresh 場景沿用 login `ClientIp::get_real_ip(&headers)` + `ConnectInfo<SocketAddr>` fallback）/ `port` / `address` / `user_agent` / `request_id` / `type` / `created_at` / `created_by` / `status='ACTIVE'` / `expires_at = now() + APP_JWT_REFRESH_TOKEN_EXPIRE`），透過既有 `AccessTokenEvent::handle()`（R5 確認）寫入。
  5. 回傳 `AuthOutput { token, refresh_token }`（serde 已 camelCase rename — feature 3 已對齊）。
- **FR-431**: rotation MUST atomic：steps 2 + 4 MUST 在同一 DB transaction 內（**plan R8 已決策**：Sea-ORM `db.transaction::<_, AuthOutput, AppError>(|txn| Box::pin(async move { ... }))` 包覆「query 舊 row → INSERT 新 row → UPDATE 舊 row 為 `REFRESHED`」整鏈；INSERT 在 UPDATE 之前以保證任一失敗都不會留下「舊已 REFRESHED 但新 row 沒寫入」狀態）。
- **FR-432**: refresh 失敗（步驟 1 查無 row）MUST NOT 觸發任何 DB 寫操作，MUST NOT 修改其他 row。
- **FR-433**: refresh token 有效期 MUST 為環境變數 `APP_JWT_REFRESH_TOKEN_EXPIRE`（沿用既有 `APP_JWT_*` prefix 慣例 — R9 確認透過 `JwtConfig` struct + serde default 載入）可組態；無設則用 default 值 14 天（1209600 秒）— 與 INTEGRATION-PLAN §4 GAP-1 推薦一致。
- **FR-434 (Clarification 2026-05-11)**: refresh service MUST 對齊既有 login handler 的 user 帳號狀態檢查政策（mirror policy）：plan 階段 read 既有 login handler 取得「在 token issue 前對 user.status / user.is_deleted / 對等欄位的檢查方式（query、failure envelope、error message）」並沿用相同邏輯；login 若有此檢查、refresh 也要做（檢查失敗時 envelope 與 login 一致）；login 若無此檢查、refresh 也不做（保持兩路徑語意一致、避免 drift）。檢查的具體形式（JOIN、額外 query、或在現有 query 加 condition）由 implementer 在 plan / impl 階段決定。

#### admin-api 新 migration（`migration/src/schemas/mYYYYMMDD_HHMMSS_add_expires_at_to_sys_tokens.rs`）

- **FR-440**: MUST 新增 migration 在 `sys_tokens` 表加 `expires_at TIMESTAMP NOT NULL` 欄位（無時區，對齊既有 `created_at` 用 `.timestamp()` 慣例 — 既有 sys_tokens 表也沒 `updated_at` 欄位；R6 已驗）。
- **FR-441**: migration MUST 處理既有 row 的 backfill：給 `expires_at = created_at + INTERVAL '14 days'`（用 default 推算貼近實際 token 生命週期，不無謂延長舊 token 壽命）。
- **FR-442**: migration MUST 註冊到 `migration/src/lib.rs` 的 `Migrator::migrations()` 序列尾端，遵守既有 migration 編號慣例（`m<YYYYMMDD>_<HHMMSS>_<descriptive_name>` 形式）。
- **FR-443**: migration MUST 可獨立 idempotent 跑（`cargo run -p migration -- up` 跑兩次第二次不報錯；既有 migration framework 行為已保證，不需 feature 端額外處理）。

#### 範圍邊界（負面 requirement）

- **FR-450**: 本 feature MUST NOT 改 login handler 行為或 login response shape（login 仍走原 `AuthOutput`、原 expires 機制）。**例外（schema 對齊副改動）**：為對齊本 feature 新 migration 加的 NOT NULL `expires_at` 欄位，既有 login 寫入路徑（`AccessTokenEvent::handle`）必須同步補 `expires_at: Set(now + APP_JWT_REFRESH_TOKEN_EXPIRE)` 一行，否則 login 寫 sys_tokens row 會 break。此為 schema 對齊、不算 login 行為變更（caller 無感、response shape 不變）。
- **FR-451**: 本 feature MUST NOT 改 admin-web 任何檔（admin-web `fetchRefreshToken` 既有實作已對 `POST /auth/refreshToken` + body `{ refreshToken }`，符合 wire contract — 對齊責任在本 feature）。
- **FR-452**: 本 feature MUST NOT 改 access token JWT 簽章演算法、`JWT_SECRET`、`JWT_EXPIRE`、`JWT_ISSUER` 等既有設定（refresh 完用同樣設定簽新 access token）。
- **FR-453**: 本 feature MUST NOT 引入新的 dependency crate（用既有 `sea-orm` / `validator` / `chrono` / `axum` / `ulid` 就好）。
- **FR-454**: 本 feature MUST NOT 動 Casbin policy / `sys_endpoint` 表內容（refresh endpoint 是 auth endpoint 不需 Casbin enforce）。
- **FR-455**: 本 feature MUST NOT 在 admin-rust-api 加 stateless refresh path（決策走 DB-backed，方案 A only）。

### Key Entities

- **`RefreshTokenInput`**（新 struct，input layer）：admin-web POST body 的 deserialize target。Fields: `refresh_token: String`（JSON key = `refreshToken`，非空）。
- **`AuthOutput`**（既有 struct，output layer）：refresh 成功時 response shape，與 login response 同形（feature 3 已加 `#[serde(rename_all = "camelCase")]`）。Fields: `token: String`（JWT access token）、`refresh_token: String`（ULID refresh token）。
- **`sys_tokens` table**（既有 16 columns + 本 feature 加 `expires_at` 第 17 欄位）：refresh token audit trail。Columns: `id` (PK Text/Ulid)、`access_token` (Text)、`refresh_token` (Text)、`status` (Text，`TokenStatus` enum strum SCREAMING_SNAKE_CASE)、`user_id` (Text)、`username` (Text)、`domain` (Text)、`login_time` (timestamp)、`ip` (Text — **不是** `client_ip`)、`port` (int nullable)、`address` (Text)、`user_agent` (Text)、`request_id` (Text)、`type` (Text — login_type)、`created_at` (timestamp default now())、`created_by` (Text)、`expires_at` (timestamp NOT NULL — 本 feature 加)。**沒有** `updated_at` 欄位。
- **`TokenStatus` enum**（既有，位於 `server_constant::definition::consts`）：3 個 variants — `Active`（活躍可用）/ `Refreshed`（已被刷新替換）/ `Revoked`（手動 logout / 安全撤銷）。strum 序列化為 SCREAMING_SNAKE_CASE（`ACTIVE` / `REFRESHED` / `REVOKED`）。refresh handler 查 `Active`、rotate 後標 `Refreshed`。本 feature 不新增 enum variant；過期判斷用「DB WHERE `expires_at > now()`」不引入 `Expired` variant。
- **`POST /auth/refreshToken`**（新 endpoint）：URL=`/auth/refreshToken`、Method=POST、Body=`{ "refreshToken": "<ulid-string>" }`、Success Response=`{ code: 200, data: { token, refreshToken }, message: "..." }`、Failure Response=`{ code: 401, message: "..." }`（envelope code 與 login 失敗對齊）。
- **`generate_auth_output` helper**（既有 `pub async fn`，位於 `server/service/src/admin/sys_auth_service.rs` line 336，R4 已確認）：login 既有的 token 生成流程，只生 JWT + Ulid、**不寫 DB**；refresh service 直接呼叫此 helper 拿新 `AuthOutput`，避免邏輯 drift。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-401**: `cargo build --release` 在 admin-api 倉 PASS（無 compile error / warning）— 代表新 struct / handler / service / migration 不破壞既有 build。
- **SC-402**: `cargo run -p migration -- up` PASS（新 migration 在乾淨 DB + 既有 DB 兩種狀態都能跑完、且第二次跑 idempotent）。
- **SC-403**: POST `/auth/refreshToken` 帶合法 refresh token 100% 回 `code:200` + `data.token` + `data.refreshToken`（兩 field 非空、refreshToken 與輸入不同）。
- **SC-404**: POST `/auth/refreshToken` 帶非法 / 過期 / revoked refresh token 100% 回 `code:401` + 0 個新 row 寫入 `sys_tokens`。
- **SC-405**: rotation 完成後 `sys_tokens` 表內舊 row `status='REFRESHED'`、新 row `status='ACTIVE'` 且 `expires_at > now()`，皆關聯同一 `user_id`。
- **SC-406**: 本 feature 的 diff 行數 ≤ **120 行**（含 migration 檔；不含 use / blank lines / comment）— 對齊 CLAUDE.md §4 的 ~80 行核心 Rust + ~30 行 migration 估計，留 50% buffer。
- **SC-407**: 連續兩次 refresh（用第一次 refresh 出來的新 refresh token 立刻再 refresh）100% 成功 — 驗 rotation 行為對稱。

## Assumptions

### 設計假設（自我決策、無需 clarify）

- 採 INTEGRATION-PLAN §4 GAP-1 推薦方案 A（DB-backed refresh）：與既有 `AccessTokenEvent` 寫入流程對稱、有 audit trail；不採方案 B（stateless JWT refresh，revoke 困難）或方案 C（長效 JWT 不刷新，安全性弱）。
- 採 INTEGRATION-CHECKLIST 跨 feature 待驗證項：「在 `sys_tokens` 表加 `expires_at` 欄位（feature 4 refresh handler 需要 + migration）」— 本 feature 自帶 migration，不另開 feature。
- `APP_JWT_REFRESH_TOKEN_EXPIRE` default = 14 天（1209600 秒）— 與 INTEGRATION-PLAN §4 GAP-1 推薦一致；環境變數可覆蓋。
- Token rotation 採「revoke 舊 + 發新 access + 新 refresh」全 rotate 模式（不採只發新 access、refresh 持續多次用）— 符合 INTEGRATION-PLAN「rotate refresh token」表述、且防 replay。
- 失敗 envelope 用 `code: 401`（與 login 失敗對齊），HTTP 狀態碼可仍回 200（既有 `Res` envelope 慣例）；implementation 階段對照既有 `AppError` 行為 confirm。
- migration backfill 採 `expires_at = created_at + INTERVAL '14 days'`（既有 row 給合理推算值，不無謂延長舊 token 壽命）。
- 寫入 `sys_tokens` 新 row 沿用既有 `AccessTokenEvent`（或對等）寫入流程；不引入新 event 種類。具體 helper 名稱在 plan 階段 confirm。
- `ip` 欄位來源（**非** `client_ip` — 實際 column 名）：refresh handler 沿用 login handler 既有的取得方式 — `ClientIp::get_real_ip(&headers)` 讀 X-Forwarded-For / X-Real-IP 等 header；無有效 header 時 fallback 到 `ConnectInfo<SocketAddr>` 的 `addr.ip().to_string()`。本 feature 不引入新的 IP 解析邏輯。
- Rotation atomic 策略（**R8 已 confirm**）：Sea-ORM `db.transaction(...)` 包覆「query 舊 row → INSERT 新 row → UPDATE 舊 row 為 `REFRESHED`」整鏈；INSERT 在 UPDATE 之前以保證任一失敗不會留下「舊已 `REFRESHED` 但新 row 未寫入」狀態（user 卡住）。

### 對其他 feature 的依賴（明列以利 plan 階段排序）

- **依賴 feature 3（已 merged）**：admin-api `AuthOutput` 已 camelCase（`#[serde(rename_all = "camelCase")]`）— refresh response 直接沿用、無需再加 derive。
- **依賴 feature 1（已 merged）**：dev compose stack 是 acceptance 的前提（postgres / redis / admin-rust-api docker network），或本機 `cargo run` 配 local postgres。
- **依賴 feature 6（dockerfile-envsubst，未開）**：admin-rust-api docker 容器要能成功啟動才能跑端到端 acceptance（curl /auth/refreshToken）；本 feature 自身可跑靜態 verification（cargo build PASS + grep handler 註冊 + migration up PASS + 本機 `cargo run` 跑 curl）— 動態 docker 驗證等 feature 6 merge 後補。
- **不依賴 feature 2（已 merged）**：admin-web 端 `fetchRefreshToken` 已對齊 wire contract（POST `/auth/refreshToken` body `{ refreshToken }`），不需 admin-web 端再動。
- **不依賴 feature 5**：admin-web 端的攔截器 retry / dedupe 是 feature 5 範圍；本 feature 只保證 admin-api 側對單次合法 / 非法 refresh 的正確回應。

### 待驗證的上游慣例（依 constitution §IV）— ✅ 全部已驗證 (T011 writeback 2026-05-11)

- [x] **login handler 是否在 token issue 前檢查 user.status / user.is_deleted / 對等欄位**（FR-434 mirror policy 的依據）— ✅ login `verify_user` line 241 有 `//TODO validate user status` 但**未實作**；refresh handler 對齊不檢查（mirror policy 落地）。
- [x] `sys_tokens` table 既有欄位精確命名 — ✅ 實際 16 既有欄位：`id` / `access_token` / `refresh_token` / `status` / `user_id` / `username` / `domain` / `login_time` / `ip`（**不是** `client_ip`）/ `port` / `address` / `user_agent` / `request_id` / `type` / `created_at` / `created_by`；**無** `updated_at`；本 feature 加 `expires_at` 為第 17 欄位。
- [x] `TokenStatus` enum 既有 variants 命名 — ✅ 3 個 variants：`Active` / `Refreshed` / `Revoked`（**含 `Refreshed`，不需 `Expired`**；strum SCREAMING_SNAKE_CASE serialize 成 `ACTIVE`/`REFRESHED`/`REVOKED`）。refresh handler 標 `Refreshed`（不是 `Revoked`）。
- [x] login `generate_access_token` helper 精確介面 — ✅ 實際名為 `generate_auth_output(user_id, username, role_codes, domain_code, organization_name, audience) -> Result<AuthOutput, JwtError>`，位於 `sys_auth_service.rs:336`，是 `pub async fn`、**只生 JWT + Ulid 不寫 DB**。refresh 直接重用。
- [x] `AccessTokenEvent` 寫入機制精確介面 — ✅ `AccessTokenEvent { 11 fields }.handle(db)` 同步 INSERT 一個 sys_tokens row（直接 `SysTokensActiveModel::insert`），**不是異步 event**。refresh service 直接呼叫（T004 把 handle 改 generic `<C: ConnectionTrait>` 支援 `&DatabaseTransaction`，並加 `expires_at` field）。
- [x] migration framework 對「加 column NOT NULL with backfill」處理慣例 — ✅ 既有 migrations 全是 `create_table`、無 ALTER 範例。本 feature 採 3-step（add nullable → raw SQL `UPDATE` backfill → modify NOT NULL；raw SQL 用既有 `Statement::from_string` pattern）。
- [x] `Res::new_data` 把 `AuthOutput` 包進 `data` field — ✅（feature 3 已驗）`Res::<T>::new_data(data)` → `{ code: 200, data: {...}, msg: "success", success: true }`，HTTP 200。`AppError { code: 401 }` → IntoResponse → `Res::new_error` → `{ code: 401, data: null, msg: "...", success: false }`，HTTP **仍 200**（envelope code 為依據；admin-web 攔截器既有約定）。
- [x] axum middleware 注入 IP 的精確方式 — ✅ login handler 用 `ClientIp::get_real_ip(&headers)` 讀 X-Forwarded-For / X-Real-IP 等 header；無有效 header 時 fallback 到 `ConnectInfo<SocketAddr>` 的 `addr.ip().to_string()`。refresh handler 沿用同 pattern。
- [x] `REFRESH_TOKEN_EXPIRE` 環境變數命名 — ✅ 實際 binding 是 **`APP_JWT_REFRESH_TOKEN_EXPIRE`**（field 加在 `JwtConfig` struct 內，config crate 用 `APP` prefix + `_` 嵌套展開為 `APP_JWT_*`）。**spec FR-433 / research R9 寫的 `APP_JWT_REFRESH_TOKEN_EXPIRE` 是 spec bug**（已在 T004 fixup amend + analyze fix 修正、deploy/.env.example 用正確名）。

### 不在範圍

- admin-web 任何檔變更（既有 `fetchRefreshToken` 已對齊；features 5 處理 admin-web 攔截器 race / dedupe）。
- stateless JWT refresh / 長效 JWT 改造（方案 B / C 一律排除）。
- access token JWT 簽章演算法或 `JWT_SECRET` 變更。
- login handler 行為或 login response shape 變更。
- 其他 GAP 修補（features 5 / 6 / 7）。
- button 級權限、Casbin policy 內容、`sys_endpoint` 表內容（refresh endpoint 不需 Casbin enforce）。
- refresh token 並發 race 的 server 端 dedupe（admin-web 攔截器責任）。
- 多裝置 refresh token 管理 / 強制其他裝置登出（屬未來功能）。
- refresh token TTL 之外的 access token TTL 調整（用既有 `JWT_EXPIRE`）。
