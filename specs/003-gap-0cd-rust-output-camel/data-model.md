# Phase 1 Data Model: gap-0cd-rust-output-camel

**Feature**: `003-gap-0cd-rust-output-camel`
**Date**: 2026-05-11

> 本 feature 不動 application data schema（不動 sys_user / sys_token 等 DB 表），本檔列被改動的 file entity + 跨組件 wire-level contract。

---

## 1. File Entities（admin-api 倉內被動的檔）

| ID | File | Type | 改動範圍 | GAP 對應 |
|---|---|---|---|---|
| F1 | `admin-api/server/model/src/admin/output/sys_authentication.rs` | Rust struct module | 2 處改：`AuthOutput` 加 derive attribute（1 行）+ `UserInfoOutput` 加 buttons field（1 行） | GAP-0c + GAP-0d (struct part) |
| F2 | `admin-api/server/api/src/admin/sys_authentication_api.rs` | Rust API handler module | 1 處改：`get_user_info` 內初始化 `buttons: vec![]`（1 行） | GAP-0d (handler part) |

### F1 改動細項（model/sys_authentication.rs）

當前內容（前幾行）：

```rust
use serde::Serialize;
use super::MenuRoute;

#[derive(Clone, Debug, Serialize)]
pub struct AuthOutput {
    pub token: String,
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct UserInfoOutput {
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "userName")]
    pub user_name: String,
    pub roles: Vec<String>,
}
```

改為：

```rust
use serde::Serialize;
use super::MenuRoute;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]              // ← GAP-0c：加 1 行 derive attribute
pub struct AuthOutput {
    pub token: String,
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct UserInfoOutput {
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "userName")]
    pub user_name: String,
    pub roles: Vec<String>,
    pub buttons: Vec<String>,                    // ← GAP-0d：加 1 行 field
}
```

行數 diff：2 行（+2 / -0）。

### F2 改動細項（api/sys_authentication_api.rs，line 58-68）

當前內容：

```rust
pub async fn get_user_info(
    Extension(user): Extension<User>,
) -> Result<Res<UserInfoOutput>, AppError> {
    let user_info = UserInfoOutput {
        user_id: user.user_id(),
        user_name: user.username(),
        roles: user.subject(),
    };

    Ok(Res::new_data(user_info))
}
```

改為：

```rust
pub async fn get_user_info(
    Extension(user): Extension<User>,
) -> Result<Res<UserInfoOutput>, AppError> {
    let user_info = UserInfoOutput {
        user_id: user.user_id(),
        user_name: user.username(),
        roles: user.subject(),
        buttons: vec![],                          // ← GAP-0d：加 1 行 placeholder
    };

    Ok(Res::new_data(user_info))
}
```

行數 diff：1 行（+1 / -0）。

### 總計 diff

- F1: +2 行
- F2: +1 行
- **總 +3 行（無 - 行）**，遠低於 SC-304「≤ 5 行」hard cap

---

## 2. Wire-Level Contracts（admin-rust-api 送 → admin-web 收）

### W1: POST `/api/auth/login` response body（success 200）

修補後完整 wire shape：

```json
{
  "code": 200,
  "data": {
    "token": "<JWT access token>",
    "refreshToken": "<ULID-format refresh token>"
  },
  "msg": "..."
}
```

| Field | Type | admin-rust-api Source | 修補狀態 |
|---|---|---|---|
| `code` | number | `Res::new_data` 設 200 | 既有（feature 1 nginx 反代後 admin-web 已對齊；feature 2 已修補識別） |
| `data.token` | string | `AuthOutput.token` | 既有，camelCase 友善（單字，無底線） |
| `data.refreshToken` | string | `AuthOutput.refresh_token` 透過 `#[serde(rename_all = "camelCase")]` 序列化 | **本 feature 修補**（GAP-0c）|
| `msg` | string | admin-rust-api 自填 | 不變 |

### W2: GET `/api/auth/getUserInfo` response body（success 200）

修補後完整 wire shape：

```json
{
  "code": 200,
  "data": {
    "userId": "<user UUID/ULID>",
    "userName": "Soybean",
    "roles": ["R_SUPER", "R_ADMIN"],
    "buttons": []
  },
  "msg": "..."
}
```

| Field | Type | admin-rust-api Source | 修補狀態 |
|---|---|---|---|
| `userId` | string | `UserInfoOutput.user_id` 透過 `#[serde(rename = "userId")]` | 既有 |
| `userName` | string | `UserInfoOutput.user_name` 透過 `#[serde(rename = "userName")]` | 既有 |
| `roles` | string array | `UserInfoOutput.roles` | 既有 |
| `buttons` | string array | `UserInfoOutput.buttons` 由 `get_user_info` 初始化為 `vec![]` | **本 feature 修補**（GAP-0d）— placeholder，永空陣列直到 button 權限實作 |

---

## 3. 為何 UserInfoOutput 不換成 struct-level `rename_all = "camelCase"`?

設計選擇 rationale（spec Assumption 已寫，本檔補完整）：

**選項 A**（本 feature 採用）：保留既有 per-field `#[serde(rename)]`，新增的 `buttons` field 不需 rename（單字）

```rust
#[derive(Debug, Serialize)]
pub struct UserInfoOutput {
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "userName")]
    pub user_name: String,
    pub roles: Vec<String>,
    pub buttons: Vec<String>,
}
```

**選項 B**（替代但本 feature 不採用）：改 struct-level `rename_all = "camelCase"`，移除既有 per-field rename

```rust
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInfoOutput {
    pub user_id: String,         // 自動 → "userId"
    pub user_name: String,       // 自動 → "userName"
    pub roles: Vec<String>,
    pub buttons: Vec<String>,
}
```

**為何選 A**：

1. **最小修補原則**（§III）：A 的 diff 是 +1 行（只加 buttons field）；B 的 diff 是 +1 行 buttons + +1 行 struct attr + -2 行 per-field rename = +/- 4 行（雖然行數仍 ≤ 5、但風險更高）
2. **Cross-struct consistency 不是本 feature 主旨**：`AuthOutput` 與 `UserInfoOutput` 是兩個獨立 struct、各自的 attribute 風格選擇是局部 trade-off，不必為了風格統一而引入「視覺改動但無語意變化」的修補
3. **未來轉換的彈性保留**：A 完成後，未來如想統一風格（B 路徑）可作獨立 refactor commit，與本 feature scope 不衝突

**追加 normative**：FR-310 明確要求「既有 fields 的 `#[serde(rename)]` attributes 不變」，B 違反此 FR、不可採用。

---

## 4. State Transitions（serialize lifecycle）

```
[admin-rust-api Rust struct]
        │
        ▼ axum handler 呼叫 Res::new_data(struct_instance)
[Res<T> wrapper]
        │
        ▼ axum 回傳 JSON response（serde_json）
[wire bytes JSON]
        │
        │  經過 nginx 反代（feature 1）→ admin-web vite proxy（dev）
        │
        ▼
[admin-web 收到 response]
        │
        ▼ TypeScript：response.data 被視為 Api.Auth.LoginToken / Api.Auth.UserInfo
[admin-web service 層 / store]
        │
        ▼ 修補後 .data.refreshToken 存在 ✅、.data.buttons 存在 ✅
[正確 type 對齊、無 undefined error]
```

無修補前：admin-web `loginToken.refreshToken === undefined`、`userInfo.buttons === undefined`（解構失敗）。
修補後：兩 field 都正常存在。

---

## 5. Cross-Reference

- **Spec FR**：F1 ↔ FR-301（GAP-0c）+ FR-310（GAP-0d struct）；F2 ↔ FR-311（GAP-0d handler）
- **Contracts**：W1 ↔ `contracts/auth-output.md`；W2 ↔ `contracts/user-info-output.md`
- **Source（admin-api）**：
  - `server/model/src/admin/output/sys_authentication.rs`（既有）
  - `server/api/src/admin/sys_authentication_api.rs`（既有，line 58-68 `get_user_info`）
  - `server/handler/...` 或 `server/model/src/admin/types/...` Res<T> impl（research R1 確認）

---

**Output 完成**：2 個 file entity（含改動精確 diff）+ 2 個 wire contract（W1/W2 完整 shape）+ rationale 段（為何 UserInfoOutput 不換 rename_all）+ state machine。
