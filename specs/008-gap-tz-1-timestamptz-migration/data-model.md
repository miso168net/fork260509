# Data Model: sys_tokens TIMESTAMPTZ Migration

**Date**: 2026-05-11
**Feature**: `008-gap-tz-1-timestamptz-migration`

## Entity: `sys_tokens`

### Schema 變更（PostgreSQL）

| 欄位 | 改前型別 | 改後型別 | NOT NULL | 變更性質 |
|---|---|---|---|---|
| `id` | `TEXT` (PK) | 不變 | ✓ | — |
| `access_token` | `TEXT` | 不變 | ✓ | — |
| `refresh_token` | `TEXT` | 不變 | ✓ | — |
| `status` | `TEXT` | 不變 | ✓ | — |
| `user_id` | `TEXT` | 不變 | ✓ | — |
| `username` | `TEXT` | 不變 | ✓ | — |
| `domain` | `TEXT` | 不變 | ✓ | — |
| **`login_time`** | **`TIMESTAMP WITHOUT TIME ZONE`** | **`TIMESTAMP WITH TIME ZONE`** | ✓ | ⭐ 本 feature |
| `ip` | `TEXT` | 不變 | ✓ | — |
| `port` | `INTEGER` | 不變 | nullable | — |
| `address` | `TEXT` | 不變 | ✓ | — |
| `user_agent` | `TEXT` | 不變 | ✓ | — |
| `request_id` | `TEXT` | 不變 | ✓ | — |
| `type` | `TEXT` | 不變 | ✓ | — |
| **`created_at`** | **`TIMESTAMP WITHOUT TIME ZONE`** | **`TIMESTAMP WITH TIME ZONE`** | ✓ | ⭐ 本 feature |
| `created_by` | `TEXT` | 不變 | ✓ | — |
| **`expires_at`** | **`TIMESTAMP WITHOUT TIME ZONE`** | **`TIMESTAMP WITH TIME ZONE`** | ✓ | ⭐ 本 feature |

### 既有資料轉換規則（FR-002）

對 3 個變更欄位執行：

```sql
ALTER TABLE sys_tokens
  ALTER COLUMN <col> TYPE TIMESTAMPTZ
  USING <col> AT TIME ZONE 'Asia/Taipei';
```

語意：既有 naive value 被解讀為 Asia/Taipei 本地時間、轉換成對應 UTC instant、存入 timestamptz column。instant 不偏移（per R1：既有 row 確實是 Asia/Taipei 寫入）。

---

## Entity: Rust `sys_tokens::Model`（sea-orm）

**檔案**: `admin-api/server/model/src/admin/entities/sys_tokens.rs`

### Field type 變更

| Field | 改前型別 | 改後型別 | 對應 PG column |
|---|---|---|---|
| `login_time` | `DateTime`（= `chrono::NaiveDateTime`） | `DateTimeWithTimeZone`（= `chrono::DateTime<chrono::FixedOffset>`） | `login_time` (timestamptz) |
| `created_at` | 同上 | 同上 | `created_at` (timestamptz) |
| `expires_at` | 同上 | 同上 | `expires_at` (timestamptz) |

其他 field 不變。

### Import 變更

```rust
// 移除：use sea_orm::entity::prelude::DateTime;（若 prelude 已含、不用改 import）
// 新增：use sea_orm::prelude::DateTimeWithTimeZone;（從 sea_orm prelude 引入）
```

sea-orm prelude 預設 export `DateTimeWithTimeZone`（type alias `chrono::DateTime<chrono::FixedOffset>`）；只需確認 `use sea_orm::entity::prelude::*;` 或 explicit import 涵蓋即可。

---

## Cross-module struct: `AccessTokenEvent`

**檔案**: `admin-api/server/service/src/admin/events/access_token_event.rs`

### Field type 變更

| Field | 改前型別 | 改後型別 | 用途 |
|---|---|---|---|
| `expires_at` | `NaiveDateTime`（chrono） | `DateTimeWithTimeZone`（sea-orm prelude） | 從 `auth_event_handler.rs:51` 傳入、被 `handle()` INSERT 到 `sys_tokens.expires_at` |

### Import 變更

```rust
// 移除：use chrono::NaiveDateTime;
// 新增：use sea_orm::prelude::DateTimeWithTimeZone;
```

---

## Write-path 對齊（FR-006）

3 處原本 `Local::now().naive_local()` 改為 `Utc::now().fixed_offset()`：

| 檔案 | 行 | 改前 | 改後 |
|---|---|---|---|
| `admin-api/server/service/src/admin/sys_auth_service.rs` | 153 | `let now = Local::now().naive_local();` | `let now = Utc::now().fixed_offset();` |
| `admin-api/server/service/src/admin/event_handlers/auth_event_handler.rs` | 51 | `let expires_at = Local::now().naive_local() + Duration::seconds(jwt_config.refresh_token_expire);` | `let expires_at = Utc::now().fixed_offset() + Duration::seconds(jwt_config.refresh_token_expire);` |
| `admin-api/server/service/src/admin/events/access_token_event.rs` | 25 | `let now = chrono::Local::now().naive_local();` | `let now = chrono::Utc::now().fixed_offset();` |

`use chrono::Local;` → `use chrono::Utc;`（前兩檔；第三檔是 fully-qualified `chrono::Utc::now()` 可不改 use）。

---

## State Transitions（sys_tokens.status，本 feature 不變）

本 feature 不改 sys_tokens.status 的狀態機（仍是 `ACTIVE → REFRESHED / INVALID / EXPIRED`，由 feature 4 定義）。3 個 timestamp 欄位只改型別、不改 lifecycle 語意。

---

## Out of Scope（per spec）

下列 entity 不在本 feature 涵蓋範圍（保持 `DateTime` / `TIMESTAMP WITHOUT TIME ZONE`）：

- `sys_user` (`created_at`, `updated_at`)
- `sys_role` (`created_at`, `updated_at`)
- `sys_menu` (`created_at`, `updated_at`)
- `sys_domain` (`created_at`, `updated_at`)
- `sys_endpoint` (`created_at`, `updated_at`)
- `sys_access_key` (`created_at`)
- `sys_organization` (`created_at`, `updated_at`)
- `sys_login_log` (`login_time`, `created_at`)
- `sys_operation_log` (`created_at`, `updated_at`, ...)

→ FR-010 enforced
