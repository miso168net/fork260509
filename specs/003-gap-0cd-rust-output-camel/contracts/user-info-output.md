# Contract: UserInfoOutput Wire-Level（admin-rust-api → admin-web）

**Feature**: `003-gap-0cd-rust-output-camel`
**Files**:
- `admin-api/server/model/src/admin/output/sys_authentication.rs`（被本 feature 加 1 行 buttons field）
- `admin-api/server/api/src/admin/sys_authentication_api.rs`（被本 feature 加 1 行 buttons init）
**Endpoint**: `GET /api/auth/getUserInfo` response

> 本契約鎖 admin-rust-api 對 user info query 的 response shape。違反此契約 = 違反 spec FR-310 + FR-311 + GAP-0d 修補意圖。

---

## 1. Response Body — Success 200 OK（修補後）

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

| Field | Path | Type | Source（admin-rust-api） | 修補狀態 |
|---|---|---|---|---|
| `userId` | `.data.userId` | string | `UserInfoOutput.user_id` 透過 `#[serde(rename = "userId")]` | 既有 |
| `userName` | `.data.userName` | string | `UserInfoOutput.user_name` 透過 `#[serde(rename = "userName")]` | 既有 |
| `roles` | `.data.roles` | string array | `UserInfoOutput.roles` | 既有 |
| `buttons` | `.data.buttons` | string array | `UserInfoOutput.buttons` 由 `get_user_info` 初始化為 `vec![]` | **本 feature 修補**（GAP-0d） |

---

## 2. Rust Source Mapping

### 2.1 Struct（model/sys_authentication.rs）

```rust
#[derive(Debug, Serialize)]
pub struct UserInfoOutput {
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "userName")]
    pub user_name: String,
    pub roles: Vec<String>,
    pub buttons: Vec<String>,    // ← 本 feature 加（FR-310）
}
```

**為何不換成 struct-level `rename_all = "camelCase"`**：見 `data-model.md §3`（最小修補 + cross-struct 風格不是本 feature 主旨 + FR-310 明確要求保留 per-field rename）。

### 2.2 Handler（api/sys_authentication_api.rs）

```rust
pub async fn get_user_info(
    Extension(user): Extension<User>,
) -> Result<Res<UserInfoOutput>, AppError> {
    let user_info = UserInfoOutput {
        user_id: user.user_id(),
        user_name: user.username(),
        roles: user.subject(),
        buttons: vec![],          // ← 本 feature 加（FR-311）
    };

    Ok(Res::new_data(user_info))
}
```

**為何 `buttons: vec![]`**：placeholder。admin-web 期望 `buttons: string[]`（array type）但暫不需具體權限資料。未來「button 級權限」實作時替換為從 menu meta 收集 button code（如 `["btn:user:add", "btn:user:edit"]`）。

---

## 3. admin-web 端消費

```ts
// admin-web/src/typings/api/auth.d.ts（既有 admin-web type）
namespace Api.Auth {
  interface UserInfo {
    userId: string;
    userName: string;
    roles: string[];
    buttons: string[];           // admin-web 既有期望此 field
  }
}

// admin-web auth store / 元件
const userInfo: Api.Auth.UserInfo = response.data;
userInfo.buttons.includes('btn:user:add');   // 永遠 false（修補後 placeholder 為 []，無 element）
```

---

## 4. 修補前 vs 修補後

### 修補前（GAP-0d 問題）

```json
{
  "code": 200,
  "data": {
    "userId": "...",
    "userName": "Soybean",
    "roles": ["R_SUPER"]
  }
}
```

問題：admin-web `userInfo.buttons` → `undefined` → `userInfo.buttons.includes(...)` runtime error → admin-web 元件 crash。

### 修補後

```json
{
  "code": 200,
  "data": {
    "userId": "...",
    "userName": "Soybean",
    "roles": ["R_SUPER"],
    "buttons": []
  }
}
```

`userInfo.buttons` 是空 array、`.includes(...)` 返回 false（無 runtime error）。

---

## 5. End-to-End Validation

### 5.1 靜態

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# 確認 buttons field 加在 UserInfoOutput
grep -A 8 'pub struct UserInfoOutput' server/model/src/admin/output/sys_authentication.rs \
  | grep -q 'pub buttons: Vec<String>' \
  && echo "PASS: UserInfoOutput 有 buttons field" \
  || echo FAIL

# 確認 handler 加 buttons: vec![] init
grep -A 6 'fn get_user_info' server/api/src/admin/sys_authentication_api.rs \
  | grep -q 'buttons: vec!\[\]' \
  && echo "PASS: get_user_info 含 buttons init" \
  || echo FAIL

# cargo check 過
cargo check --release 2>&1 | grep -qE 'Finished' \
  && echo "PASS: cargo check" \
  || echo FAIL
```

### 5.2 動態（feature 6 merge 後）

```bash
BASE=http://localhost:8080/api

# 拿 token 後查 user info
TOKEN=$(curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' | jq -r '.data.token')

# 看 4 個 fields
curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq '.data | keys'
# 期望：["buttons", "roles", "userId", "userName"]

# 驗 buttons 是 array 且長度 0（placeholder）
curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq '.data.buttons | length'
# 期望：0
curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq '.data.buttons | type'
# 期望：array
```

---

## 6. 變更政策

- **改 buttons placeholder 行為**（從永空 → 真實 button code 收集）：屬獨立 feature（button 權限），不在本 feature 範圍；本 contract 標明該 field 預設空、未來填值由獨立 feature 處理
- **加新 field**（如 `permissions`、`extraInfo`）：協同 admin-web Api.Auth.UserInfo 變更
- **改既有 fields rename strategy**（per-field → struct-level）：屬 refactor、不需新 spec、admin-web 視角無差異

---

## 7. Out of Scope

- button 權限的真實邏輯（從 menu meta 收集 button code）— 未來獨立 feature
- `User.subject()` / `user.user_id()` / `user.username()` 的內部實作 — admin-rust-api 既有 method、本 contract 不涵蓋
- admin-web 元件如何展示 / 用 buttons array — admin-web 倉自身範圍
