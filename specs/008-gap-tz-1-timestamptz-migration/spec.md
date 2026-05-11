# Feature Specification: sys_tokens TIMESTAMP → TIMESTAMPTZ Migration

**Feature Branch**: `008-gap-tz-1-timestamptz-migration`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "feature 8 gap-tz-1-timestamptz-migration — sys_tokens 表的 expires_at / created_at / login_time 3 欄從 TIMESTAMP WITHOUT TIME ZONE 改為 TIMESTAMPTZ，配合 Rust entity 改用 sea-orm DateTimeWithTimeZone，並把 3 處寫入點的 Local::now().naive_local() 改為 Utc::now().fixed_offset()，根治 retrospective code review 4-I1（TZ-skew silent prod risk）"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Refresh token 過期判定不受外部 SQL session TZ 影響 (Priority: P1)

當運維人員或外部工具（psql session、其他客戶端、未來 cross-stack 服務）以非 UTC TZ 介入 `sys_tokens` 表時，admin-api 的 refresh token 過期判定仍應對齊真實 instant、不受 session TZ 偏移影響。

**Why this priority**: P1 是因為這是 silent prod risk — 平時看似正常（admin-api 容器內讀寫一致），但任何外部 SQL 介入（運維手動 UPDATE、未來新增的 cron job、其他工具的 query）都可能誤判 token 為 expired/active off by ±8h（Asia/Taipei vs UTC）。當前 feature 4 retrospective code review 4-I1 明確列為 backlog 危險項。

**Independent Test**: 用 host psql `SET TIME ZONE 'Asia/Taipei'` 連入觀察 `sys_tokens.expires_at` 顯示、再切回 `'UTC'` 觀察同一 row，確認顯示格式不同但 instant 相同；再以 admin-api `/auth/refreshToken` 對該 token 操作確認 200。

**Acceptance Scenarios**:

1. **Given** sys_tokens 表已遷移為 TIMESTAMPTZ + admin-api 啟動完成，**When** 使用者完成 login → 取得 refresh_token → host psql 以 `SET TIME ZONE 'Asia/Taipei'` SELECT expires_at，**Then** 顯示 `+08:00` 格式且時間值對應「login instant + refresh_token_expire 秒」、與容器內 UTC instant 一致
2. **Given** 同一 refresh_token 仍在有效期內，**When** host psql 以 `SET TIME ZONE 'UTC'` SELECT expires_at，**Then** 顯示 UTC 格式（無 ± 或 `+00`）但 epoch instant 與情境 1 相同
3. **Given** 同一 refresh_token 仍在有效期內、且外部 psql 已用任意 TZ 觀察過，**When** 客戶端 curl `POST /api/auth/refreshToken` 帶該 refresh_token，**Then** 回 HTTP 200 + 新 access/refresh token（不受 session TZ 偏移影響、不誤判 expired）

---

### User Story 2 - Login + refresh flow 在 schema migration 後維持正常 (Priority: P1)

既有 admin-api 的 login / refresh 流程在套用本 feature migration 後維持完全相同的對外行為（HTTP 200 + 相同 JSON 結構 + JWT 有效期不變）。

**Why this priority**: P1 是因為本 feature 是 schema-level 改動，任何 regression 都會打斷 admin-web 的核心登入 flow。必須與 feature 4/6/7 同等 dynamic functional verification 確保無 regression。

**Independent Test**: `docker compose up -d` → 等 healthy → `POST /api/auth/login` 200 + JWT → `POST /api/auth/refreshToken` 200 + 新 JWT。與 feature 4 T009 / feature 7 T010 同 pattern。

**Acceptance Scenarios**:

1. **Given** docker compose 全 stack healthy（含已套用本 feature migration），**When** 客戶端 `POST /api/auth/login` 帶 `{identifier: "Soybean", password: "123456"}`，**Then** 回 HTTP 200 + JSON body 含 `accessToken`、`refreshToken`、`tokenType: "Bearer"`、`expiresIn`
2. **Given** login 取得的 refresh_token，**When** 客戶端 `POST /api/auth/refreshToken` 帶該 refresh_token，**Then** 回 HTTP 200 + 新 accessToken/refreshToken（舊 refresh_token 在 sys_tokens 表 status 轉為 INVALID、新 row INSERT 為 ACTIVE）
3. **Given** login 與 refresh 完成，**When** `SELECT login_time, created_at, expires_at FROM sys_tokens ORDER BY created_at DESC LIMIT 2;`，**Then** 3 個欄位皆是 timestamptz 顯示格式（含 TZ offset），且 instant 對應實際 login/refresh 時間（不會 off by 8h）

---

### User Story 3 - 既有 sys_tokens row 在 migration 過程中 instant 不偏移 (Priority: P2)

migration 套用前已存在的 sys_tokens row（如開發機保留的 dev session token），在 `ALTER COLUMN ... USING ... AT TIME ZONE 'UTC'` 轉換後，timestamp 對應的真實 instant 不偏移。

**Why this priority**: P2 是因為 sys_tokens 主要是 session 狀態、即使資料遺失只是強迫重新登入，不致命；但保留資料可以避免 dev environment 中斷、且能作為「migration 沒搞砸 instant」的反證。

**Independent Test**: migration 套用前 SELECT 一筆 row 的 expires_at（記下 naive 值）→ 套用 migration → 套用後 SELECT 同 row（轉換後是 timestamptz）→ 確認 epoch instant 與套用前一致（差異 0）。

**Acceptance Scenarios**:

1. **Given** migration 套用前 sys_tokens 有 row R，**When** 從 R.expires_at（TIMESTAMP naive）讀出值並記為 V_before（解讀為 Asia/Taipei instant），**Then** V_before 可被記錄為對照基準
2. **Given** migration 套用後同一 row R 仍存在，**When** SELECT R.expires_at（TIMESTAMPTZ），**Then** 該值 cast 為 UTC instant 後與 V_before（Asia/Taipei → 對應 UTC）完全相等（差異 0 秒）

---

### Edge Cases

- **既有 row 由非 admin-api 寫入（如 maintenance SQL）的不確定情境**：若 sys_tokens 中存在「過去由外部 psql session（TZ≠Asia/Taipei）寫入」的 row，本 feature `USING ... AT TIME ZONE 'Asia/Taipei'` 會把該 naive 值誤標為 Asia/Taipei（實際應該是 session TZ） → 該 row 的 instant 偏移量 = ±(session TZ − Asia/Taipei)。當前 dev environment 無已知此類 row（admin-api 寫入是唯一來源），但需在 quickstart / migration 註解明確標示此假設。
- **同時併發運行的 admin-api instance**：本 feature 假設 migration 套用時無正在運作的 admin-api（standard sea-orm migration deploy practice — migration run 在 deploy init 階段）。若實際 prod 有 zero-downtime 需求，本 feature 不涵蓋（out of scope）。
- **Down migration 在 prod 觸發**：down 從 timestamptz → timestamp 不帶 USING，Postgres 預設用 session TZ 投影 naive。若 down 在 session TZ ≠ UTC 環境執行，會把 instant 偏移到 session TZ — 因此 down 僅作為「dev 緊急回退」用途，prod 不應 down。

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Migration MUST 將 `sys_tokens.expires_at`、`sys_tokens.created_at`、`sys_tokens.login_time` 3 欄位的 column type 從 `TIMESTAMP WITHOUT TIME ZONE` 改為 `TIMESTAMP WITH TIME ZONE`（即 PostgreSQL `TIMESTAMPTZ`）
- **FR-002**: Migration up() MUST 在 ALTER COLUMN TYPE 時帶 `USING <col> AT TIME ZONE 'Asia/Taipei'` clause，將既有 naive 值標註為 Asia/Taipei (UTC+8) instant — 對齊 deploy/.env 設定的 `TZ=Asia/Taipei`，使既有 row 的真實 instant 被正確保留（避免被 session TZ 預設行為偏移）。**註**：此 TZ 字串對應 `deploy/.env.example` 設定；若 future 改部署到不同 TZ 區域需 retrospectively 重新評估 USING clause
- **FR-003**: Migration up() MUST 在所有 3 個欄位都成功 ALTER 完成後才回傳 Ok（任一欄位失敗則整體失敗、不留 partial state）
- **FR-004**: Migration down() MUST 將 3 個欄位 ALTER 回 `TIMESTAMP WITHOUT TIME ZONE`（down 不要求 instant 保真、不帶 USING）
- **FR-005**: Rust entity `server_model::admin::entities::sys_tokens::Model` 中 `login_time`、`created_at`、`expires_at` 3 個欄位的 Rust 型別 MUST 從 `DateTime`（NaiveDateTime alias）改為 `DateTimeWithTimeZone`（`DateTime<FixedOffset>` alias）
- **FR-006**: 所有將值寫入 `sys_tokens.login_time` / `created_at` / `expires_at` 的 write site MUST 改為 `chrono::Utc::now().fixed_offset()`（chrono 0.4.31+ 內建 method、回傳 `DateTime<FixedOffset>` = sea-orm `DateTimeWithTimeZone`；per research.md R2 鎖定 idiom），不得繼續使用 `Local::now().naive_local()` 或任何 strip TZ 的 conversion
- **FR-007**: 跨 module 傳遞的 struct field（如 `AccessTokenEvent.expires_at`）若會落到 sys_tokens 的 3 欄位 MUST 採用 `DateTimeWithTimeZone` 型別、不得在 type system 中途降為 NaiveDateTime
- **FR-008**: Refresh token expiry 比較邏輯（`SysTokensColumn::ExpiresAt.gt(now)` filter）MUST 在 schema 改 timestamptz 後正確比較 instant（不需額外 TZ conversion code，sea-orm `DateTimeWithTimeZone` binding 自動處理）
- **FR-009**: admin-api 對外 API 回傳的 JSON shape MUST 保持不變（accessToken / refreshToken / expiresIn 欄位語意與型別與 feature 4/5 後一致；本 feature 不修改 HTTP contract）
- **FR-010**: 其他 9+ tables 的 timestamp 欄位（sys_user / sys_role / sys_menu / sys_domain / sys_endpoint / sys_access_key / sys_organization / sys_login_log / sys_operation_log）MUST NOT 在本 feature 內被修改（明確 out of scope）

### Key Entities

- **sys_tokens**: 儲存 active access/refresh token 與其生命週期狀態的表；本 feature 涉及 3 個 timestamp 欄位
  - `login_time`：使用者完成 login 的時間點
  - `created_at`：sys_tokens row 被建立的時間點（與 login_time 通常相同；於 refresh 時新 row 的 created_at = refresh instant）
  - `expires_at`：refresh_token 到期時間（= login/refresh instant + `JwtConfig.refresh_token_expire` 秒；feature 4 引入）
- **AccessTokenEvent**（cross-module struct，service layer）：login flow 中把 token 與 expiry metadata 傳遞給 access_token_event handler 用；其 `expires_at` field 是本 feature 唯一在 type system 中需同步改型別的 struct field

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 套用 migration 後，`\d sys_tokens` 顯示 `login_time`、`created_at`、`expires_at` 三欄的 Type 欄均為 `timestamp with time zone`（不再是 `timestamp without time zone`）
- **SC-002**: 套用 migration + Rust 改動後，docker compose 全 stack 啟動 → `POST /api/auth/login` 在 5 秒內回 HTTP 200 + 包含 `accessToken/refreshToken`；接著 `POST /api/auth/refreshToken` 在 5 秒內回 HTTP 200 + 新 token（與 feature 4/6/7 acceptance 同等 SLA）
- **SC-003**: 套用 migration 後從 host psql 用任意 TZ（`SET TIME ZONE 'Asia/Taipei'` 與 `SET TIME ZONE 'UTC'`）SELECT 同一 sys_tokens row 的 expires_at，兩次讀取的 epoch instant 完全相等（顯示格式不同但 unix timestamp 一致）
- **SC-004**: migration 套用前已存在的 sys_tokens row 在套用後 instant 不偏移 — 同一 row 在 migration 前後對 epoch unix timestamp 的差為 0 秒
- **SC-005**: `cargo clippy --all-targets --all-features -- -D warnings` 與 `cargo test --workspace` 在 admin-api 倉內全 pass（包含本 feature 改 entity / struct 型別後的編譯）
- **SC-006**: 套用 migration 不影響其他 9+ tables 的 schema — `\d sys_user`、`\d sys_role` 等表的 timestamp 欄位仍維持 `timestamp without time zone`（明確驗證 out of scope 範圍未被誤動）

## Assumptions

依 constitution §IV「上游驗證」原則，下列假設於 plan / impl 階段需驗證後在對應 spec / plan 段勾選；當前以「合理 default」記錄：

- **A-001（已於 Phase 0 修正）**：admin-api container 過去寫入 sys_tokens 的所有 row 都是用 `Local::now().naive_local()`、且 container TZ = `Asia/Taipei`（per `deploy/.env.example` + `deploy/.env` 設定 `TZ=Asia/Taipei`、compose.yaml `TZ: ${TZ:?must set TZ}` require → admin-api / postgres / redis 三 container 都 Asia/Taipei） → 既有 naive 值在語意上等價 Asia/Taipei (UTC+8) instant。本假設使 `USING ... AT TIME ZONE 'Asia/Taipei'` 為正確轉換策略（FR-002）。**修正記**：spec 初稿假設 container TZ=UTC（誤襲自 `admin-api/server/service/src/admin/sys_auth_service.rs:158-166` 的 T009 inline comment，該 comment 在 cargo run（host）模式下寫的、混淆了 host 與 container TZ）；Phase 0 經 `.env.example` / Dockerfile / entrypoint.sh / host `date` 多源證據確認實際是 Asia/Taipei、已修正
- **A-002**：workspace `chrono = "0.4"` 解到 lock 版本 ≥ 0.4.31（`DateTime::<Utc>::fixed_offset()` method 自 0.4.31 起內建）→ `Utc::now().fixed_offset()` 可用、不需額外 dep change
- **A-003**：sea-orm `DateTimeWithTimeZone`（= `chrono::DateTime<chrono::FixedOffset>`）對 timestamptz column 的 binding 是正確的 — INSERT/UPDATE 寫入時帶 TZ offset、SELECT 回讀時 sea-orm 正確 deserialize；不需額外 conversion helper
- **A-004**：PostgreSQL `ALTER COLUMN <col> TYPE TIMESTAMPTZ USING <col> AT TIME ZONE 'UTC'` 在 row 數量小（dev 環境通常 < 100 row）時於秒級完成、不需 lock 規劃；prod 若 row 數量大需 plan 階段補 row count 估計
- **A-005**：sea-orm migration up()/down() 在現有 `m20260511_070000_add_expires_at_to_sys_tokens.rs`（feature 6）之後依檔名 lexical order 執行；本 feature 新檔以 `m20260512_*` 起頭可確保正確排序
- **A-006**：本 feature 套用時 admin-api instance 已停（standard migration deploy practice）；zero-downtime 需求 out of scope
- **A-007**：feature 4 retrospective code review 4-I1 backlog 條目（TZ-skew silent prod risk）的描述對 root cause 的判斷正確 — 即 `TIMESTAMP WITHOUT TIME ZONE` + 外部 SQL session TZ 介入是唯一 skew root cause（非 chrono / Postgres 其他層 bug）

## Out of Scope（明確排除）

依 constitution §III 合併例外條款，下列項目本 feature 不包含、需另起 feature 處理：

- **其他 9+ tables 的 timestamp 欄位**：sys_user / sys_role / sys_menu / sys_domain / sys_endpoint / sys_access_key / sys_organization / sys_login_log / sys_operation_log 的 created_at / updated_at / login_time / operation_time 等 timestamp 欄位仍保持 `TIMESTAMP WITHOUT TIME ZONE` + `Local::now().naive_local()` 寫法。理由：這些是 audit / metadata 性質、TZ skew 僅影響 log 顯示、不影響 access control 決策；未來可另起 feature 9（schema-level full sweep）統一處理
- **admin-web 任何改動**：admin-web 只讀回傳的 token JSON、不直接操作 sys_tokens；本 feature HTTP contract 不變、admin-web 無需改動
- **JWT token 內 claims 的 timestamp（iat/exp）TZ 處理**：JWT spec 規定 iat/exp 是 Unix timestamp（int seconds since epoch、本身無 TZ 概念），與本 feature 處理的 DB column TZ 是兩個獨立問題；本 feature 不涉及 JWT claim 結構
- **prod zero-downtime migration 規劃**：本 feature 假設 deploy 時 admin-api 已停；zero-downtime（如 dual-write / shadow column / phased rollout）out of scope
- **chrono / sea-orm 版本升級**：假設當前 workspace lock 已可用；若 plan 階段驗證發現 chrono < 0.4.31 則僅作最小升級、不順帶升其他 dep

## References

- **retrospective backlog 4-I1**：`docs/INTEGRATION-CHECKLIST.md` retrospective code review backlog 條目；本 feature 是 4-I1 的根治
- **TZ-skew 內聯文件**：`admin-api/server/service/src/admin/sys_auth_service.rs:159-166` 有 feature 4 T009 留下的 inline comment 描述 TZ-skew root cause；本 feature 套用後該 comment 可移除或改為「已修」標記
- **constitution §III 合併例外條款**：定義「相關性 + 規模小 + 風險可控」的合併標準；本 feature 依此原則限制 scope 在 sys_tokens 單表
- **constitution §IV 上游驗證**：本 feature Assumptions A-001 ~ A-007 需於 plan / impl 階段個別驗證並回填
