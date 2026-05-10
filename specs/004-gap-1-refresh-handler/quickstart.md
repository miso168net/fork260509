# Quickstart: gap-1-refresh-handler

**Feature**: 004-gap-1-refresh-handler
**Audience**: Rust backend implementer（admin-api 倉）+ operator / QA（dynamic smoke）

兩部分：implementer 走兩段式 submodule commit 完成 feature；operator 跑 wire-level smoke 驗收。

---

## Part A — Implementer Quickstart

### A.0 Pre-flight 健檢

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git status                    # 應在 outer branch 004-gap-1-refresh-handler，clean
git submodule status          # admin-api 行首應為空格（clean），SHA = f8a21b2

cd admin-api
git status -sb                # 應在 inner branch new-admin-rust-api
git log --oneline -3          # 確認 feature 3 已合進來（最新 SHA f8a21b2）
```

若任一檢查失敗 → 參照 CLAUDE.md §9 重建 worktree / 對齊 pin。

---

### A.1 改動順序（對應 3 個 inner commits）

#### Inner commit 1：migration + entity

**新增 migration 檔**：`admin-api/migration/src/schemas/m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens.rs`

```rust
use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        // Step 1: add as nullable
        manager.alter_table(
            Table::alter()
                .table(SysTokens::Table)
                .add_column(ColumnDef::new(SysTokens::ExpiresAt).timestamp().null())
                .to_owned()
        ).await?;

        // Step 2: backfill via raw SQL
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
        ).await
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.alter_table(
            Table::alter()
                .table(SysTokens::Table)
                .drop_column(SysTokens::ExpiresAt)
                .to_owned()
        ).await
    }
}

#[derive(DeriveIden)]
enum SysTokens {
    Table,
    ExpiresAt,
}
```

**改 `admin-api/migration/src/schemas/mod.rs`**：尾端加一行

```rust
pub mod m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens;
```

**改 `admin-api/migration/src/lib.rs`**：「架构迁移」段尾端（在 `m20241023_091210_create_sys_user_role` 之後）加：

```rust
Box::new(schemas::m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens::Migration),
```

**改 `admin-api/server/model/src/admin/entities/sys_tokens.rs`**：在 `created_by: String,` 之後加：

```rust
    pub expires_at: DateTime,
```

**驗**：

```bash
cd admin-api
cargo build --release -p server-model -p migration
# PASS = 進下一步
```

**(本機 dev DB)**：

```bash
# 確保 dev postgres 跑著（feature 1 deploy stack 或本機 postgres）
cargo run -p migration -- up
# 觀察：應看到「Applying ... add_expires_at_to_sys_tokens ... done」
psql $DATABASE_URL -c "\d sys_tokens" | grep expires_at
# 應看到：expires_at | timestamp without time zone | not null
psql $DATABASE_URL -c "SELECT expires_at FROM sys_tokens LIMIT 1"
# 應看到非空 timestamp（== created_at + 14 days）
```

**inner commit 1**：

```bash
git add server/model/src/admin/entities/sys_tokens.rs \
        migration/src/schemas/m*_add_expires_at_to_sys_tokens.rs \
        migration/src/schemas/mod.rs \
        migration/src/lib.rs
git commit -m "feat(admin-api): GAP-1 加 sys_tokens.expires_at migration + entity"
```

---

#### Inner commit 2：input + route

**改 `admin-api/server/model/src/admin/input/sys_authentication.rs`**：尾端加：

```rust
#[derive(Deserialize, Validate)]
pub struct RefreshTokenInput {
    #[serde(rename = "refreshToken")]
    #[validate(length(min = 1, message = "Refresh token cannot be empty"))]
    pub refresh_token: String,
}
```

別忘記 `RefreshTokenInput` 加入 `model/admin/input/mod.rs` 的 `pub use` re-export（看既有 `LoginInput` 怎麼 export 跟著做）。

**改 `admin-api/server/router/src/admin/sys_authentication_route.rs`** line 12-15：

```rust
pub async fn init_authentication_router() -> Router {
    let router = Router::new()
        .route("/login", post(SysAuthenticationApi::login_handler))
        .route("/refreshToken", post(SysAuthenticationApi::refresh_token_handler));  // ★
    Router::new().nest("/auth", router)
}
```

**驗**：

```bash
cargo check -p server-model -p server-router
# 必須 PASS（refresh_token_handler 尚未實作會錯 — 暫時 stub 一個 fn 讓編譯過、commit 3 補正）
```

由於 router 引用尚未實作的 handler，建議實作順序改為：先寫 handler stub → commit 2 → 改 handler 內容 → commit 3。或把 commit 2 + 3 合併（彈性）。

**inner commit 2**：

```bash
git add server/model/src/admin/input/sys_authentication.rs \
        server/model/src/admin/input/mod.rs \
        server/router/src/admin/sys_authentication_route.rs
git commit -m "feat(admin-api): GAP-1 加 RefreshTokenInput + /auth/refreshToken route"
```

---

#### Inner commit 3：handler + service + config

**改 `admin-api/server/config/src/model/jwt_config.rs`**：加一 field

```rust
#[serde(default = "default_refresh_token_expire")]
pub refresh_token_expire: u64,

// 檔尾或同檔內
fn default_refresh_token_expire() -> u64 { 1209600 }
```

**改 `admin-api/server/api/src/admin/sys_authentication_api.rs`**：在 `login_handler` 之後加：

```rust
pub async fn refresh_token_handler(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    TypedHeader(user_agent): TypedHeader<UserAgent>,
    Extension(request_id): Extension<RequestId>,
    Extension(service): Extension<Arc<SysAuthService>>,
    ValidatedForm(input): ValidatedForm<RefreshTokenInput>,
) -> Result<Res<AuthOutput>, AppError> {
    let client_ip = {
        let header_ip = ClientIp::get_real_ip(&headers);
        if header_ip == "unknown" { addr.ip().to_string() } else { header_ip }
    };
    let address = xdb::searcher::search_by_ip(client_ip.as_str())
        .unwrap_or_else(|_| "Unknown Location".to_string());
    let context = LoginContext {
        client_ip,
        client_port: Some(addr.port() as i32),
        address,
        user_agent: user_agent.as_str().to_string(),
        request_id: request_id.to_string(),
        audience: Audience::ManagementPlatform,
        login_type: "PC".to_string(),       // 將在 service 內被舊 row.type 覆寫（保留原 session type）
        domain: "built-in".to_string(),     // 將在 service 內被舊 row.domain 覆寫
    };
    service.refresh_token(input, context).await.map(Res::new_data)
}
```

**改 `admin-api/server/service/src/admin/sys_auth_service.rs`**：

1. trait `TAuthService` 加 method 簽章
2. impl `TAuthService for SysAuthService` 加 method 實作（依 research.md R8 骨架）

關鍵：用 Sea-ORM `db.transaction::<_, AuthOutput, AppError>(|txn| Box::pin(async move { ... }))` 包覆四步驟（query 舊 row → generate_auth_output → AccessTokenEvent.handle(txn) → UPDATE 舊 row）。

3. **改 `admin-api/server/service/src/admin/events/access_token_event.rs`**（如 `AccessTokenEvent::handle` signature 是 `&DatabaseConnection`，改為 generic `&impl ConnectionTrait`），並加 `expires_at: Set(expires_at)` 一行對齊 NOT NULL 欄位（login 既有寫入流程也必須含 expires_at，否則 login 會 break）。

**驗**：

```bash
cargo build --release -p server-config -p server-api -p server-service
# 必須 PASS
cargo check
# 全 crate PASS
```

**inner commit 3**：

```bash
git add server/config/src/model/jwt_config.rs \
        server/api/src/admin/sys_authentication_api.rs \
        server/service/src/admin/sys_auth_service.rs \
        server/service/src/admin/events/access_token_event.rs
git commit -m "feat(admin-api): GAP-1 加 refresh_token_handler + service rotation"
```

---

### A.2 inner push

```bash
git push origin new-admin-rust-api
# 應成功推到 miso168net/fork260509-soybean-admin-rust
```

### A.3 outer commit（第二段）

```bash
cd ..   # 回 outer
git status
# 應看到：
#   modified content: admin-api (new commits)

git add admin-api
# 若 R9 順帶在 deploy/.env.example 加一行：
git add deploy/.env.example

git commit -m "chore(submodule): bump admin-api 到 <短SHA>: feature 4 GAP-1 refresh handler"
# **不**直接 git push — 依 CLAUDE.md §5 全域 push 確認規則，等使用者授權
```

---

## Part B — Operator Quickstart（動態 smoke）

依本機 `cargo run` 或 feature 6 docker stack 任一可運轉的 admin-api 容器。

### B.1 環境變數

```bash
export BASE=http://localhost:8080/api      # nginx 同源（feature 1 deploy）
# 或本機 cargo run：
export BASE=http://localhost:10001
```

### B.2 happy path

```bash
# 1. login 拿 token
LOGIN_RESP=$(curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}')
echo "$LOGIN_RESP" | jq
ACCESS=$(echo "$LOGIN_RESP" | jq -r .data.token)
REFRESH=$(echo "$LOGIN_RESP" | jq -r .data.refreshToken)
echo "ACCESS=$ACCESS"
echo "REFRESH=$REFRESH"

# 2. refresh
REFRESH_RESP=$(curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}")
echo "$REFRESH_RESP" | jq

# 預期：
# {
#   "code": 200,
#   "data": { "token": "<new-jwt>", "refreshToken": "<new-ulid>" },
#   "msg": "success",
#   "success": true
# }

NEW_ACCESS=$(echo "$REFRESH_RESP" | jq -r .data.token)
NEW_REFRESH=$(echo "$REFRESH_RESP" | jq -r .data.refreshToken)

# 驗 rotation：新 refresh 應不等於舊
test "$NEW_REFRESH" != "$REFRESH" && echo "✓ rotation OK" || echo "✗ rotation FAIL"

# 3. psql 查 sys_tokens 兩 row
psql $DATABASE_URL -c "SELECT refresh_token, status, expires_at FROM sys_tokens WHERE refresh_token IN ('$REFRESH', '$NEW_REFRESH') ORDER BY created_at"
# 預期 2 row：
# - 舊：status=REFRESHED
# - 新：status=ACTIVE, expires_at > now()

# 4. 用新 access token 驗 getUserInfo
curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $NEW_ACCESS" | jq
# 預期：code: 200, data: { userId, userName, roles, buttons: [] }
```

### B.3 負面 cases

```bash
# Case 1: 完全不存在的 refresh token
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d '{"refreshToken":"01ARZ3NDEKTSV4RRFFQ69G5FAV"}' | jq
# 預期：code: 401, data: null, success: false

# Case 2: 已被 refreshed 的 token（用上面 happy path 跑完後的舊 REFRESH）
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}" | jq
# 預期：code: 401（這個 token 上面已被 rotate 過、status=REFRESHED）

# Case 3: 強制過期（手動 update DB）
psql $DATABASE_URL -c "UPDATE sys_tokens SET expires_at = now() - interval '1 hour' WHERE refresh_token = '$NEW_REFRESH'"
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$NEW_REFRESH\"}" | jq
# 預期：code: 401

# Case 4: 空 body
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d '{}' | jq
# 預期：code: 400 (validation)

# Case 5: 空字串
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d '{"refreshToken":""}' | jq
# 預期：code: 400 (validation)
```

### B.4 連續 refresh（SC-407 驗 rotation 對稱）

```bash
# 拿 happy path 的 NEW_REFRESH 立刻再 refresh
curl -sS -X POST $BASE/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$NEW_REFRESH\"}" | jq
# 預期：code: 200, 又拿到第三組 token
```

---

## 不在本 Quickstart 範圍

- admin-api 一般 dev 流程（cargo run / sea-orm migrate 初設定 / Casbin 設定） → 屬 admin-api 倉自身 README
- 多 device 並發 refresh 測試 → 屬 feature 5 admin-web 攔截器測試
- prod stack（feature 6 docker envsubst startup） → 屬 feature 6 quickstart
- admin-web 端 attempt force re-login flow → 屬 admin-web E2E 測試（features 5）
