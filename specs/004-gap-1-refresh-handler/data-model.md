# Phase 1 Data Model: gap-1-refresh-handler

**Feature**: 004-gap-1-refresh-handler
**Date**: 2026-05-11
**Status**: Completed

本檔列出 feature 4 涉及的所有 entity / DTO / column / state 變動，與既有 admin-api 模型對齊。所有實際命名以 `admin-api/` worktree 內 source 為準（research.md R2-R5 已具現化）。

---

## 1. DB schema 變動

### 1.1 `sys_tokens` 表（既有 + 加 1 欄位）

| 欄位 | type | 變動 | 來源 |
|---|---|---|---|
| `id` | Text PK | 不變 | 既有 |
| `access_token` | Text | 不變 | 既有 |
| `refresh_token` | Text | 不變 | 既有（unique 概念，無 DB constraint） |
| `status` | Text | 不變（值域擴用，見下方 §3） | 既有 |
| `user_id` | Text | 不變 | 既有 |
| `username` | Text | 不變 | 既有 |
| `domain` | Text | 不變 | 既有 |
| `login_time` | timestamp | 不變 | 既有 |
| `ip` | Text | 不變 | 既有（refresh 場景填 refresh request IP） |
| `port` | Option<i32> | 不變 | 既有 |
| `address` | Text | 不變 | 既有 |
| `user_agent` | Text | 不變 | 既有 |
| `request_id` | Text | 不變 | 既有 |
| `type` | Text | 不變 | 既有（refresh 場景保留原 session type） |
| `created_at` | timestamp | 不變 | 既有，default `now()` |
| `created_by` | Text | 不變 | 既有 |
| **`expires_at`** | timestamp NOT NULL | **新增** | 本 feature；既有 row backfill `created_at + INTERVAL '14 days'` |

**Migration**: `m<YYYYMMDD>_<HHMMSS>_add_expires_at_to_sys_tokens.rs`（3-step ALTER，見 research.md R6）

**Entity 變動**（`admin-api/server/model/src/admin/entities/sys_tokens.rs`）：

```rust
#[derive(Clone, Debug, PartialEq, DeriveEntityModel, Eq)]
#[sea_orm(table_name = "sys_tokens")]
pub struct Model {
    // ... 既有 16 fields ...
    pub created_by: String,
    pub expires_at: DateTime,    // ★ 新加
}
```

---

## 2. DTO / Input / Output 模型

### 2.1 `RefreshTokenInput`（**新加**，位於 `model/admin/input/sys_authentication.rs`）

```rust
use serde::Deserialize;
use validator::Validate;

#[derive(Deserialize, Validate)]
pub struct RefreshTokenInput {
    #[serde(rename = "refreshToken")]
    #[validate(length(min = 1, message = "Refresh token cannot be empty"))]
    pub refresh_token: String,
}
```

- **JSON in**：`{"refreshToken": "<ulid-string>"}`
- **Rust field**：`refresh_token: String`（snake，serde rename 反射 camel）
- **Validation**：非空字串

### 2.2 `AuthOutput`（既有，feature 3 已 camelCase 對齊，**不變**）

```rust
// model/admin/output/sys_authentication.rs（既有）
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthOutput {
    pub token: String,           // → JSON "token"
    pub refresh_token: String,   // → JSON "refreshToken"（feature 3 已加 derive）
}
```

- refresh handler 成功回傳 `AuthOutput` — 與 login response 同 shape

### 2.3 `LoginContext`（既有，refresh handler 重用，**不變**）

```rust
// server/service/src/admin/dto/sys_auth_dto.rs（既有）
pub struct LoginContext {
    pub client_ip: String,         // 對映 sys_tokens.ip
    pub client_port: Option<i32>,  // 對映 sys_tokens.port
    pub address: String,           // 對映 sys_tokens.address
    pub user_agent: String,
    pub request_id: String,
    pub audience: Audience,
    pub login_type: String,
    pub domain: String,
}
```

- refresh handler 走相同 context 組裝流程（與 login_handler line 29-50 同 pattern）

---

## 3. `TokenStatus` enum 狀態流轉

```
                ┌─────────┐
   login        │         │   refresh
   ─────────►   │ ACTIVE  │   ─────────►  REFRESHED
                │         │   manual
                │         │   ─────────►  REVOKED
                └─────────┘
                     │
                     │  expires_at < now()
                     ▼
              （隱式失效，DB row 仍是 ACTIVE
               但查詢加 expires_at > now()
               filter 自動排除）
```

- **`Active`**：login / refresh 寫入時 default 狀態
- **`Refreshed`**：本 feature 標記 — 舊 row 被 refresh handler rotate 替換
- **`Revoked`**：手動 logout / 安全強制下線（**本 feature 不負責、不寫入此狀態**）

實際 DB column 字串值由 strum `SCREAMING_SNAKE_CASE` 產出：`ACTIVE` / `REFRESHED` / `REVOKED`。

---

## 4. sys_tokens row 寫入欄位對照表（login vs refresh）

| 欄位 | login 新 row（既有 `AuthEventHandler::handle_login` → `AccessTokenEvent::handle`） | refresh 新 row（本 feature） | refresh 舊 row UPDATE |
|---|---|---|---|
| `id` | `Ulid::new().to_string()` | `Ulid::new().to_string()` | 不變（同舊 row） |
| `access_token` | login 生成的 JWT | refresh 重生的 JWT | 不變 |
| `refresh_token` | login 生成的 Ulid | refresh 重生的 Ulid | 不變 |
| `status` | `ACTIVE` | `ACTIVE` | **`ACTIVE` → `REFRESHED`** |
| `user_id` | login 認證後的 user.id | **舊 sys_tokens row.user_id**（保留 session 身份） | 不變 |
| `username` | login 認證後的 user.username | **舊 row.username** | 不變 |
| `domain` | login_context.domain（`"built-in"`） | **舊 row.domain** | 不變 |
| `login_time` | `Local::now().naive_local()` | `Local::now().naive_local()`（refresh 當下） | 不變 |
| `ip` | login_context.client_ip（從 refresh request 抓） | **refresh request 當下 IP**（記錄 token 實際 rotate 的位置，非原 login IP） | 不變 |
| `port` | login_context.client_port | refresh request 當下 port | 不變 |
| `address` | xdb 查 IP → 地理位置 | xdb 查 refresh IP → 地理位置 | 不變 |
| `user_agent` | refresh request UA header | refresh request UA header | 不變 |
| `request_id` | login request tracing ID | refresh request tracing ID | 不變 |
| `type` | login_context.login_type（`"PC"`） | **舊 row.type**（保留原 session type） | 不變 |
| `created_at` | `Local::now().naive_local()` | `Local::now().naive_local()` | 不變 |
| `created_by` | login_context.username | **舊 row.username** | 不變 |
| `expires_at` | （新欄位、由 refresh handler 寫入；login 也需 backfill — 但 login 屬不同 feature scope） | `Local::now().naive_local() + chrono::Duration::seconds(jwt_config.refresh_token_expire as i64)` | 不變 |

> **注意**：login handler 既有的 `AccessTokenEvent::handle` 寫入流程**尚未**填 `expires_at`（既有 code 不知道此欄位）。Feature 4 migration 加 column 後，既有 login 路徑會因 NOT NULL 寫入失敗。**implementation 階段 mandatory** 要把 `AccessTokenEvent::handle` 內 `SysTokensActiveModel { ... }.insert(db)` 加 `expires_at: Set(now + REFRESH_EXPIRE)` 一行，否則 login flow 會 break。本變動列入 inner commit 3 內。

---

## 5. Service / API 介面變動

### 5.1 `SysAuthService` trait 加 method

```rust
// server/service/src/admin/sys_auth_service.rs（既有 trait）
#[async_trait]
pub trait TAuthService: Send + Sync {
    async fn pwd_login(&self, input: LoginInput, context: LoginContext)
        -> Result<AuthOutput, AppError>;

    async fn get_user_routes(&self, role_codes: &[String], domain: &str)
        -> Result<UserRoute, AppError>;

    // ★ 新加
    async fn refresh_token(&self, input: RefreshTokenInput, context: LoginContext)
        -> Result<AuthOutput, AppError>;
}
```

### 5.2 `SysAuthenticationApi` impl 加 handler

```rust
// server/api/src/admin/sys_authentication_api.rs（既有 impl）
impl SysAuthenticationApi {
    // ... 既有 5 handlers ...

    // ★ 新加
    pub async fn refresh_token_handler(
        ConnectInfo(addr): ConnectInfo<SocketAddr>,
        headers: HeaderMap,
        TypedHeader(user_agent): TypedHeader<UserAgent>,
        Extension(request_id): Extension<RequestId>,
        Extension(service): Extension<Arc<SysAuthService>>,
        ValidatedForm(input): ValidatedForm<RefreshTokenInput>,
    ) -> Result<Res<AuthOutput>, AppError> {
        // 組 LoginContext（與 login_handler line 29-50 同 pattern）
        // 呼叫 service.refresh_token(input, context)
        // map Res::new_data
    }
}
```

### 5.3 Router 加 route

```rust
// server/router/src/admin/sys_authentication_route.rs
impl SysAuthenticationRouter {
    pub async fn init_authentication_router() -> Router {
        let router = Router::new()
            .route("/login", post(SysAuthenticationApi::login_handler))
            .route("/refreshToken", post(SysAuthenticationApi::refresh_token_handler));  // ★ 新加
        Router::new().nest("/auth", router)
    }
    // ... 其他既有 routers 不變
}
```

---

## 6. Config 變動

`JwtConfig` 加 `refresh_token_expire: u64` field（research.md R9）：

```rust
// server/config/src/model/jwt_config.rs（既有 struct）
pub struct JwtConfig {
    pub secret: String,
    pub expire: u64,
    pub issuer: String,
    #[serde(default = "default_refresh_token_expire")]
    pub refresh_token_expire: u64,    // ★ 新加（APP_REFRESH_TOKEN_EXPIRE，default 1209600 = 14 天）
}

fn default_refresh_token_expire() -> u64 { 1209600 }
```

`deploy/.env.example`（外層 outer commit 範圍）加一行：

```
APP_REFRESH_TOKEN_EXPIRE=1209600
```

---

## 7. 不變更項

明列以避免誤動：

- `sys_user` 表 / `sys_role` 表 / `sys_user_role` 表 — 不動
- Casbin policy / `sys_endpoint` 表 — 不動（refresh 是 auth endpoint，不需 Casbin enforce — FR-454）
- `LoginInput` / `UserInfoOutput` / `UserRoute` 等其他 input/output — 不動
- JWT 簽章 / `APP_JWT_SECRET` / `APP_JWT_EXPIRE` / `APP_JWT_ISSUER` — 不動（FR-452）
- admin-web 端任何檔 — 不動（FR-451）
