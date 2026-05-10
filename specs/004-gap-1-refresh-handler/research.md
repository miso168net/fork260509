# Phase 0 Research: gap-1-refresh-handler

**Feature**: 004-gap-1-refresh-handler
**Date**: 2026-05-11
**Status**: Completed

把 spec.md「待驗證的上游慣例」7 項加上 Q1 clarification 落地後的 mirror policy 具現化、atomic rotation 策略決定、§V 兩段式 commit 流程具現化全部解析。所有 R# 都已透過 read 既有 admin-api source 完成 — implementation 階段不需要再額外探勘。

---

## R1: login handler 是否查 user.status / user.is_deleted（FR-434 mirror policy 依據）

- **Decision**: refresh **不查 user.status / user.is_deleted**（mirror login）
- **Rationale**: read `admin-api/server/service/src/admin/sys_auth_service.rs::verify_user`（line 222-254）：
  ```rust
  //TODO validate user status and domain status
  ```
  - login 既有實作**未**對 user.status 做檢查（只查 user 存在 + 密碼正確 + 取 role）
  - 依 Q1 clarification mirror policy → refresh 也維持「不檢查」一致行為
- **Alternatives considered**:
  - 在 refresh 主動查 user.status — 拒絕：違反 mirror policy、製造 login/refresh 行為 drift
  - 順手把 login 的 TODO 補上 — 拒絕：超出 feature 4 scope（屬獨立 security 強化 feature）
- **Implementer note**: 若未來 login 補上 user.status 檢查，refresh 必須同步補（mirror policy 是 invariant）

---

## R2: `sys_tokens` 既有欄位精確命名

- **Decision**: 採用實際 entity / migration 列出的欄位名（spec 用「client_ip」是概念、實際 column 是 `ip`；spec 用「user_name」是概念、實際是 `username`）
- **Rationale**: read `admin-api/server/model/src/admin/entities/sys_tokens.rs` + migration `m20241023_091204_create_sys_tokens.rs`：

| 欄位（DB column） | Rust 名 | type | 備註 |
|---|---|---|---|
| `id` | `id` | Text PK | Ulid 字串 |
| `access_token` | `access_token` | Text | JWT 字串 |
| `refresh_token` | `refresh_token` | Text | Ulid 字串 |
| `status` | `status` | Text | `TokenStatus` enum 的 `.to_string()`（SCREAMING_SNAKE_CASE） |
| `user_id` | `user_id` | Text | FK 概念但無 DB constraint |
| `username` | `username` | Text | 不是 `user_name` |
| `domain` | `domain` | Text | login 用 `"built-in"` |
| `login_time` | `login_time` | timestamp | login / refresh 時間 |
| `ip` | `ip` | Text | **不是 client_ip**（spec 概念名） |
| `port` | `port` | Option<i32> | nullable |
| `address` | `address` | Text | xdb IP 地理位置查詢結果（如「Unknown Location」） |
| `user_agent` | `user_agent` | Text | request UserAgent header |
| `request_id` | `request_id` | Text | tracing request_id |
| `type` | `r#type` | Text | login_type（"PC" / "Mobile" 等） |
| `created_at` | `created_at` | timestamp | default `now()` |
| `created_by` | `created_by` | Text | 由 username 填 |
| **`expires_at`**（本 feature 加） | `expires_at` | timestamp NOT NULL | 由 migration backfill `created_at + INTERVAL '14 days'`、後續 default `now() + INTERVAL '14 days'` |

- **Alternatives considered**: 用 `ip_address`/`user_login_ip` 等更明確命名 — 拒絕：要動既有 entity + migration 屬 breaking change、out of scope
- **Implementer note**: 寫 refresh sys_tokens row 時 `ip` 來自 `ClientIp::get_real_ip(&headers)` + `addr.ip()` fallback（沿用 login）；不要寫 `client_ip`

---

## R3: `TokenStatus` enum variants + 序列化

- **Decision**: refresh 後標 **`Refreshed`**（不是 `Revoked`）
- **Rationale**: read `admin-api/server/constant/src/definition/consts.rs:1-23`：
  ```rust
  #[derive(... AsRefStr, Display, EnumString)]
  #[strum(serialize_all = "SCREAMING_SNAKE_CASE")]
  pub enum TokenStatus {
      Active,      // 活跃状态，可以正常使用
      Refreshed,   // 已被刷新，表示该 token 已被新 token 替换
      Revoked,     // 已被撤销（手动注销或安全原因）
  }
  ```
  - 上游 enum 已預留 **`Refreshed`** variant，明確表達「已被新 token 替換」語意
  - `Revoked` 保留給「手動 logout」/「安全強制下線」場景（feature 5 / 未來功能）
  - strum `SCREAMING_SNAKE_CASE` → `.to_string()` 產出 `"ACTIVE"` / `"REFRESHED"` / `"REVOKED"`，這是 DB column 實際內容
  - `TokenStatus::can_refresh()` helper 已存在 — `matches!(self, TokenStatus::Active)` — refresh service 查詢可用此 helper 過濾（更語意化）但用直接 `eq("ACTIVE")` 也可（與 login 寫入流程一致）
- **Alternatives considered**:
  - 標 `Revoked` — 拒絕：語意混淆（無法區分「自動 rotate」vs「主動撤銷」），未來 audit / 統計困難
  - 引入新 variant `Rotated` — 拒絕：上游已有 `Refreshed`，重複引入違反 §III「不擴展 scope」
- **Implementer note**: spec FR-430 step 2 / acceptance scenarios / SC-405 都已對齊「REFRESHED」字串

---

## R4: login `generate_access_token` 實際介面 + 寫 sys_tokens row 的責任分層

- **Decision**: refresh service 重用 `generate_auth_output(...)` 生新 token pair；寫 sys_tokens 新 row 直接呼叫 `AccessTokenEvent { ... }.handle(db)`（同步 INSERT，**不**走 `global::send_dyn_event` 異步 event 路徑）
- **Rationale**: read `sys_auth_service.rs::generate_auth_output`（line 336-359）+ `pwd_login`（line 105-130）+ `send_login_event`（line 272-296）+ `access_token_event.rs`：

  **(a) `generate_auth_output` 簽章**：
  ```rust
  pub async fn generate_auth_output(
      user_id: String,
      username: String,
      role_codes: Vec<String>,
      domain_code: String,
      organization_name: Option<String>,
      audience: Audience,
  ) -> Result<AuthOutput, JwtError>
  ```
  - **只負責生 JWT + Ulid**：`AuthOutput { token: <jwt>, refresh_token: <ulid> }`
  - **不寫 DB**
  - top-level `pub async fn`、可從 refresh service 直接呼叫

  **(b) login 寫 sys_tokens row 的路徑**：
  ```
  pwd_login()
    → verify_user (DB query, 不寫)
    → generate_auth_output (不寫)
    → send_login_event → global::send_dyn_event(SystemEvent::AuthLoggedInEvent, Box::new(auth_event))
        → (async event handler) AuthEventHandler::handle_login(AuthEvent)
            → (內部會建構 AccessTokenEvent + call .handle(db))
  ```
  - login 走「異步 event」是為了把 audit / log / Redis 多個副作用解耦
  - `AccessTokenEvent::handle(db)` 是最後一步、直接 `SysTokensActiveModel::insert(db)` 同步 INSERT

  **(c) refresh service 走 sync 路徑**：
  - refresh 必須在同一 transaction 內完成「INSERT 新 sys_tokens row + UPDATE 舊 row REFRESHED」（FR-431 atomic）
  - 異步 event 無法在 transaction 內 await（會破壞 atomic 邊界）
  - 所以 refresh **直接呼叫 `AccessTokenEvent::handle()`**（或內聯 `SysTokensActiveModel { ... }.insert(txn)`），不走 event dispatch
- **Alternatives considered**:
  - refresh 也走 `send_dyn_event` — 拒絕：違反 FR-431 atomic（event 是 fire-and-forget）
  - refresh 自寫 INSERT helper、不重用 `AccessTokenEvent` — 拒絕：duplicate 程式碼、未來 sys_tokens 欄位變動時兩處要同步改
  - 把 `AccessTokenEvent::handle` 包成 transaction-aware 版本傳 `&DatabaseTransaction` 而非 `&DatabaseConnection` — 待 implementation 階段視 sea-orm trait bound 決定（若 `ActiveModelTrait::insert` 接受 `&impl ConnectionTrait` 則直接過、若強型別 `&DatabaseConnection` 則需小調整）
- **Implementer note**:
  - 若 `AccessTokenEvent::handle(db: &DatabaseConnection)` 在 transaction 內無法直接接 `&txn`，建議在 access_token_event.rs 加 generic `&impl ConnectionTrait`（單行 signature 變動、不破壞既有 caller）
  - refresh service 不觸發 `SystemEvent::AuthLoggedInEvent`（refresh 是 token rotation、非 new login）

---

## R5: `AccessTokenEvent` 寫入機制

- **Decision**: 沿用既有 `AccessTokenEvent` struct，**不**新增 variant 或 enum
- **Rationale**: read `admin-api/server/service/src/admin/events/access_token_event.rs`：
  ```rust
  pub struct AccessTokenEvent {
      pub access_token: String,
      pub refresh_token: String,
      pub user_id: String,
      pub username: String,
      pub domain: String,
      pub ip: String,
      pub port: Option<i32>,
      pub address: String,
      pub user_agent: String,
      pub request_id: String,
      pub login_type: String,
  }
  ```
  - struct 11 field 全部對應 refresh 場景所需（context 同 login）
  - `.handle(db)` 直接 `SysTokensActiveModel { id: Ulid::new().to_string(), status: TokenStatus::Active.to_string(), login_time: now, created_at: now, created_by: username, ... }.insert(db)`
- **Refresh 場景 field mapping**：
  - `access_token` ← 新 JWT（refresh 生成）
  - `refresh_token` ← 新 Ulid（refresh 生成）
  - `user_id` / `username` / `domain` ← 從**舊 sys_tokens row**讀（保留 session 身份）
  - `ip` / `port` / `address` / `user_agent` / `request_id` ← 從**當下 refresh request context**讀（記錄 token 實際 rotate 的位置）
  - `login_type` ← 「refresh」或從舊 row 讀（待 plan 確認；保守選從舊 row 讀以保留原 session type）
- **Alternatives considered**:
  - 新 struct `RefreshTokenEvent`（or `TokenRotationEvent`） — 拒絕：與 AccessTokenEvent 99% 重複、duplicate
  - `AccessTokenEvent` 加 `is_refresh: bool` field — 拒絕：本 feature 不擴 event 介面（屬未來 audit 強化）

---

## R6: migration 框架對 NOT NULL with backfill

- **Decision**: 3-step ALTER（sea-orm `alter_table` 兩呼叫 + 一段 raw SQL UPDATE）
- **Rationale**:
  - 既有 13 個 migrations 全是 `create_table`，**無 alter_table 範例** — 本 feature 是首個 ALTER migration
  - Postgres `ALTER TABLE ADD COLUMN NOT NULL` 對既有 row 必須有 DEFAULT；DEFAULT 是常數運算（不能用 `created_at + ...` 引用其他 column）
  - 解：先 add nullable → backfill (raw SQL `UPDATE` 用 column 運算) → alter NOT NULL
- **3-step pattern**：
  ```rust
  async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
      // Step 1: add column as nullable
      manager.alter_table(
          Table::alter()
              .table(SysTokens::Table)
              .add_column(ColumnDef::new(SysTokens::ExpiresAt).timestamp().null())
              .to_owned()
      ).await?;

      // Step 2: backfill via raw SQL（用 column 運算 — DEFAULT 不能引用其他 column）
      let db = manager.get_connection();
      db.execute_unprepared(
          "UPDATE sys_tokens SET expires_at = created_at + INTERVAL '14 days' WHERE expires_at IS NULL"
      ).await?;

      // Step 3: alter to NOT NULL
      manager.alter_table(
          Table::alter()
              .table(SysTokens::Table)
              .modify_column(ColumnDef::new(SysTokens::ExpiresAt).timestamp().not_null())
              .to_owned()
      ).await?;

      Ok(())
  }

  async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
      manager.alter_table(
          Table::alter()
              .table(SysTokens::Table)
              .drop_column(SysTokens::ExpiresAt)
              .to_owned()
      ).await
  }
  ```
- **`SysTokens` iden enum 已存在**（位於 `m20241023_091204_create_sys_tokens.rs`），需要本 migration 自己定義一份小 iden enum（或 re-use 既有的 — 但跨檔 import sea-orm iden 在不同 migration 通常重定義一份）— 待 implementation 階段視既有慣例決定。簡單 path：本 migration 自定義小 iden enum：`#[derive(DeriveIden)] enum SysTokens { Table, ExpiresAt, CreatedAt }`
- **Alternatives considered**:
  - `ALTER ... ADD COLUMN ... NOT NULL DEFAULT 'fixed-value'`（一步走，全部既有 row 同值） — 拒絕：違反 spec FR-441「`expires_at = created_at + INTERVAL '14 days'`」（既有 row 應該按 created_at 推算）
  - 全用 raw SQL（一段 ALTER + UPDATE + ALTER） — 拒絕：偏離 sea-orm 既有 builder pattern、降低 portability
- **Implementer note**:
  - migration 命名：`mYYYYMMDD_HHMMSS_add_expires_at_to_sys_tokens.rs`，YYYYMMDD/HHMMSS 用本檔 commit 當下時間
  - 註冊到 `Migrator::migrations()` 的「架构迁移」段尾端（在 `m20241023_091210_create_sys_user_role` 之後、`m20241023_102950_insert_sys_domain` 之前）

---

## R7: `Res::new_data` / `AppError` envelope 行為

- **Decision**: refresh handler 走「成功 `Res::new_data(AuthOutput)`、失敗 `Err(AppError { code: 401, message: ... })`」與 login 對稱
- **Rationale**: read `admin-api/server/core/src/web/res.rs:58-65` + `error.rs:19-23`：

  **成功 envelope**:
  ```rust
  pub fn new_data(data: T) -> Self {
      Self { code: StatusCode::OK.as_u16(), data: Some(data), msg: "success", success: true }
  }
  ```
  → JSON `{ "code": 200, "data": {...}, "msg": "success", "success": true }` + HTTP 200

  **失敗 envelope**:
  ```rust
  impl IntoResponse for AppError {
      fn into_response(self) -> Response {
          Res::<()>::new_error(self.code, self.message.as_str()).into_response()
      }
  }
  ```
  → `AppError { code: 401, ... }` → `{ "code": 401, "data": null, "msg": "...", "success": false }` + **HTTP status 永遠 200**（envelope code 才是 caller 的判斷依據）
- **admin-web 攔截器既有約定**：feature 2 已對齊 `VITE_SERVICE_SUCCESS_CODE=200`，攔截器看 `response.code === 200` 判斷成功、`response.code === 401` 觸發 force re-login。refresh 失敗 envelope code 401 → 攔截器自動 force re-login（符合 spec US2）
- **Alternatives considered**:
  - 失敗回 HTTP 401（不是 envelope 200 + code 401） — 拒絕：違反既有 admin-api `AppError::into_response` 機制、admin-web 攔截器需改

---

## R8: atomic rotation 策略（FR-431）

- **Decision**: Sea-ORM transaction 包覆「INSERT 新 sys_tokens row → UPDATE 舊 row status='REFRESHED'」兩 statement
- **Rationale**:
  - 兩 statement 都是 sys_tokens 同表寫操作 → 同一 connection、同一 transaction 完美 fit
  - INSERT 在先：新 row 確定寫入後才 UPDATE 舊 row；若 transaction commit 失敗整個 rollback → 結束狀態跟未進入 handler 一致
  - 若 INSERT 後 panic / UPDATE 前 fail → transaction abort、兩個都不生效（user 看到的是 refresh 失敗、可重試）
  - Sea-ORM transaction API：`db.transaction::<_, _, AppError>(|txn| Box::pin(async move { ... }))` 接 `Fn(&DatabaseTransaction) -> Future`，回 `Result<T, E>`
- **實作骨架**：
  ```rust
  let db = db_helper::get_db_connection().await?;
  db.transaction::<_, AuthOutput, AppError>(|txn| Box::pin(async move {
      // Step 1: query 舊 row（必須在 transaction 內以避免 race）
      let old_row = SysTokens::find()
          .filter(sys_tokens::Column::RefreshToken.eq(&refresh_token))
          .filter(sys_tokens::Column::Status.eq(TokenStatus::Active.to_string()))
          .filter(sys_tokens::Column::ExpiresAt.gt(Local::now().naive_local()))
          .one(txn)
          .await?
          .ok_or_else(|| AppError { code: 401, message: "Refresh token invalid".into() })?;

      // Step 2: 生新 token pair（不寫 DB）
      let auth_output = generate_auth_output(
          old_row.user_id.clone(),
          old_row.username.clone(),
          /* role_codes 需要從 user 表查 — 或從舊 JWT decode；plan 階段二選一 */
          /* domain_code */ old_row.domain.clone(),
          None,
          Audience::ManagementPlatform,
      ).await?;

      // Step 3: INSERT 新 row（重用 AccessTokenEvent 但傳 &txn）
      AccessTokenEvent {
          access_token: auth_output.token.clone(),
          refresh_token: auth_output.refresh_token.clone(),
          user_id: old_row.user_id.clone(),
          username: old_row.username.clone(),
          domain: old_row.domain.clone(),
          ip: context.ip,
          port: context.port,
          address: context.address,
          user_agent: context.user_agent,
          request_id: context.request_id,
          login_type: old_row.r#type.clone(),  // 保留原 session type
      }.handle(txn).await?;
      // 注意：需要 AccessTokenEvent::handle signature 改 generic <C: ConnectionTrait>

      // Step 4: UPDATE 舊 row REFRESHED
      let mut active: SysTokensActiveModel = old_row.into();
      active.status = Set(TokenStatus::Refreshed.to_string());
      active.update(txn).await?;

      Ok(auth_output)
  })).await
  ```
- **Role codes 來源（待 implementation 細化）**：refresh 場景需要 role_codes 才能生新 JWT claims。3 個 candidate：
  1. **JWT decode**：解 old access token 拿 claims.roles（**未必可解**，access token 可能已過期）
  2. **DB 重查 user 表**：用 user_id 查 sys_user_role + sys_role（多 1-2 個 query）
  3. **舊 sys_tokens row 加 roles 欄位**（schema 變動，out of scope）
  - **建議**：在 transaction 內走 (2) DB 重查（與 login `get_user_roles` 同 helper 重用、單 query），雖然多 1 query 但保證 role 是最新（user 角色被改也即時 reflect）
- **Alternatives considered**:
  - SELECT FOR UPDATE 鎖 row — 過度設計：本 feature 接受「並發 race 第二個 401」（spec edge case），無需 lock
  - 樂觀鎖（version column） — 同上、out of scope
  - 順序反過來：先 UPDATE 舊 row REFRESHED 再 INSERT 新 row — 拒絕：INSERT 若失敗會留下「舊已 REFRESHED 但無新 row」狀態、user 卡住

---

## R9: `APP_REFRESH_TOKEN_EXPIRE` env var 載入路徑

- **Decision**: 加 `refresh_token_expire: u64` field 到既有 `JwtConfig` struct（`server/config/src/model/jwt_config.rs`），對齊既有 `APP_JWT_EXPIRE` 載入 pattern；default 1209600（14 天）
- **Rationale**:
  - read `server/config/src/model/jwt_config.rs:8` 註解：「`APP_JWT_EXPIRE: JWT 过期时间（秒）`」+ `env_config.rs:192` example：「`env::set_var("APP_JWT_EXPIRE", "3600")`」
  - 既有 config 框架用 `APP_` prefix + serde load env var into struct，已支援 `JwtConfig`
  - refresh token expire 與 JWT expire 概念屬同一 auth domain → 加進同 struct 最合理
- **新 field**：
  ```rust
  // server/config/src/model/jwt_config.rs
  pub struct JwtConfig {
      pub secret: String,
      pub expire: u64,                    // 既有：APP_JWT_EXPIRE
      pub issuer: String,                 // 既有
      #[serde(default = "default_refresh_token_expire")]
      pub refresh_token_expire: u64,      // 新加：APP_REFRESH_TOKEN_EXPIRE，default 1209600
  }
  fn default_refresh_token_expire() -> u64 { 1209600 }
  ```
- **Service 層存取**：refresh service 透過既有 config singleton（`global::get_config()` 或對等）拿 `jwt_config.refresh_token_expire`，加到 `Local::now().naive_local()` 計算 expires_at
- **Alternatives considered**:
  - 新 struct `RefreshTokenConfig` — 拒絕：與 JwtConfig 同 domain、拆兩 struct 增加 loading 複雜度
  - 直接 `std::env::var("APP_REFRESH_TOKEN_EXPIRE")` 不過 config 框架 — 拒絕：違反 §II 外部化設定的「透過統一 config loader」精神
- **Implementer note**:
  - `.env.example`（外層 `deploy/.env.example`）加一行 `APP_REFRESH_TOKEN_EXPIRE=1209600`（feature 1 已 merged，本 feature 加 1 行 env example，屬 deploy/ 目錄變動 — 是 outer commit 範圍 而非 inner）
  - `deploy/.env.example` 不在 admin-api submodule 內、屬 outer repo，加在 outer commit 內即可

---

## R10: §V 兩段式 commit 流程（admin-api 視角，feature 4 版）

- **Decision**: 重用 feature 3 模式、target submodule 同樣是 admin-api
- **流程**：

**第一段（admin-api/ worktree 內，分 3 個 inner commits）**：

```bash
cd admin-web/../admin-api    # 或從 root: cd admin-api
git status                    # 確認 branch = new-admin-rust-api、無 untracked 雜訊
```

```bash
# inner commit 1：migration + entity
git add server/model/src/admin/entities/sys_tokens.rs \
        migration/src/schemas/m*_add_expires_at_to_sys_tokens.rs \
        migration/src/schemas/mod.rs \
        migration/src/lib.rs
git commit -m "$(cat <<'EOF'
feat(admin-api): GAP-1 加 sys_tokens.expires_at migration + entity

- 新 migration m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens（3-step ALTER：add nullable → backfill created_at+14d → NOT NULL）
- sys_tokens entity 加 expires_at: DateTime
- 註冊 migration 到 schemas/mod.rs + lib.rs Migrator::migrations()
EOF
)"
```

```bash
# inner commit 2：input + route
git add server/model/src/admin/input/sys_authentication.rs \
        server/router/src/admin/sys_authentication_route.rs
git commit -m "$(cat <<'EOF'
feat(admin-api): GAP-1 加 RefreshTokenInput + /auth/refreshToken route

- RefreshTokenInput { refresh_token: String } with serde(rename = "refreshToken") + validate
- init_authentication_router() 加 .route("/refreshToken", post(...))，掛 /auth 同層、不過 Casbin
EOF
)"
```

```bash
# inner commit 3：handler + service
git add server/api/src/admin/sys_authentication_api.rs \
        server/service/src/admin/sys_auth_service.rs \
        server/config/src/model/jwt_config.rs   # 加 refresh_token_expire field
git commit -m "$(cat <<'EOF'
feat(admin-api): GAP-1 加 refresh_token_handler + service rotation

- refresh_token_handler 接同 login 的 context（ConnectInfo / HeaderMap / UserAgent / RequestId）
- SysAuthService::refresh_token 用 Sea-ORM transaction 包：
  SELECT 舊 row（ACTIVE + expires_at > now）→ generate_auth_output → AccessTokenEvent.handle 寫新 row → UPDATE 舊 row REFRESHED
- 失敗回 AppError { code: 401 }，與 login 失敗對稱
- JwtConfig 加 refresh_token_expire field（APP_REFRESH_TOKEN_EXPIRE，default 1209600）
- User.status 檢查 mirror login（皆不檢查 — Q1 clarification）
EOF
)"
```

```bash
git push origin new-admin-rust-api
```

**第二段（外層 new-admin-root）**：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 或 worktree root
git status                                   # 應看到 "modified content" 在 admin-api
git add admin-api
git add deploy/.env.example                  # 若 R9 確定要加 .env.example 行
git commit -m "$(cat <<'EOF'
chore(submodule): bump admin-api 到 <短SHA>: feature 4 GAP-1 refresh handler

3 個 inner commits：
- migration + entity（sys_tokens.expires_at）
- RefreshTokenInput + /auth/refreshToken route
- refresh_token_handler + service rotation transaction

並在 deploy/.env.example 加 APP_REFRESH_TOKEN_EXPIRE=1209600（default 14 天）。
EOF
)"
```

**outer push 待使用者授權**（依 CLAUDE.md §5 全域規則）。

---

## 結論：所有 spec assumptions 已具現化

7 條「待驗證的上游慣例」全部解析完成（R1-R7），3 條 plan 階段決策（R8 atomic / R9 env / R10 兩段式）拍板。implementation 階段不需要再做額外 code 探勘 — tasks.md 可直接落地。
