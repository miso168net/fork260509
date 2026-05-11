# Migration Contract: `m20260512_000000_alter_sys_tokens_timestamptz`

**Date**: 2026-05-11
**Feature**: `008-gap-tz-1-timestamptz-migration`

## 檔案位置

`admin-api/migration/src/schemas/m20260512_000000_alter_sys_tokens_timestamptz.rs`

並於 `admin-api/migration/src/schemas/mod.rs` 註冊。

## up() — 升級 SQL

對 3 個欄位逐一執行 raw SQL（sea-orm `modify_column` API 不支援 `USING` clause）：

```sql
ALTER TABLE sys_tokens ALTER COLUMN expires_at TYPE TIMESTAMPTZ USING expires_at AT TIME ZONE 'Asia/Taipei';
ALTER TABLE sys_tokens ALTER COLUMN created_at TYPE TIMESTAMPTZ USING created_at AT TIME ZONE 'Asia/Taipei';
ALTER TABLE sys_tokens ALTER COLUMN login_time TYPE TIMESTAMPTZ USING login_time AT TIME ZONE 'Asia/Taipei';
```

### Rust 實作骨架

```rust
use sea_orm_migration::{prelude::*, sea_orm::Statement};

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        let backend = manager.get_database_backend();

        // FR-002: AT TIME ZONE 'Asia/Taipei' 對齊 deploy/.env 設定（per Phase 0 R1）；
        // 既有 naive value 被解讀為 Asia/Taipei 本地時間、轉換成 UTC instant 後存 timestamptz。
        let alter_stmts = [
            "ALTER TABLE sys_tokens ALTER COLUMN expires_at TYPE TIMESTAMPTZ USING expires_at AT TIME ZONE 'Asia/Taipei'",
            "ALTER TABLE sys_tokens ALTER COLUMN created_at TYPE TIMESTAMPTZ USING created_at AT TIME ZONE 'Asia/Taipei'",
            "ALTER TABLE sys_tokens ALTER COLUMN login_time TYPE TIMESTAMPTZ USING login_time AT TIME ZONE 'Asia/Taipei'",
        ];

        for sql in alter_stmts {
            db.execute(Statement::from_string(backend, sql.to_string()))
                .await?;
        }
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        // NOTE (per spec Edge Cases + Phase 0 R8): down 不帶 USING、Postgres 用 session TZ
        // 投影 naive → 若 session TZ ≠ Asia/Taipei 會偏移 instant。down 僅作 dev 緊急回退、
        // prod 應採 fix-forward 寫 corrective migration、不應 down。
        let db = manager.get_connection();
        let backend = manager.get_database_backend();

        let alter_stmts = [
            "ALTER TABLE sys_tokens ALTER COLUMN expires_at TYPE TIMESTAMP",
            "ALTER TABLE sys_tokens ALTER COLUMN created_at TYPE TIMESTAMP",
            "ALTER TABLE sys_tokens ALTER COLUMN login_time TYPE TIMESTAMP",
        ];

        for sql in alter_stmts {
            db.execute(Statement::from_string(backend, sql.to_string()))
                .await?;
        }
        Ok(())
    }
}
```

## Side effects

- 對既有 sys_tokens 表執行三次 `ALTER COLUMN`（schema-level lock、row-level 不重寫）
- PostgreSQL 17 文件保證 `TIMESTAMP → TIMESTAMPTZ` 改型別不重寫表（only metadata change + per-row USING expression）
- 預計 dev 環境（< 100 row）秒級完成

## 不變式（invariants）

1. 3 個欄位都成功 ALTER 完成 → 回傳 Ok；任一失敗 → 整體 rollback（sea-orm migration trait 預設行為）
2. 既有 row 的真實 instant 不偏移（per Phase 0 R4 + R1：USING TZ 對齊既有寫入 TZ）
3. 不修改其他 sys_tokens 欄位、不修改其他 table（FR-010）

## 接續檔的 lexical order 保證

| 既有最末 migration | 本 feature 新檔 |
|---|---|
| `m20260511_070000_add_expires_at_to_sys_tokens.rs`（feature 6） | `m20260512_000000_alter_sys_tokens_timestamptz.rs`（本 feature） |

`20260512_000000` > `20260511_070000`（lexical 比較）→ sea-orm 自動以本 feature 為最後執行（per Phase 0 R5）。
