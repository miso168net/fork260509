# Phase 0 Research: sys_tokens TIMESTAMP → TIMESTAMPTZ Migration

**Date**: 2026-05-11
**Feature**: `008-gap-tz-1-timestamptz-migration`

依 constitution §IV「上游驗證」原則，對 spec.md Assumptions A-001 ~ A-007 個別執行驗證 / 釐清。

---

## R1 — Container TZ 實際設定（修正 A-001）

**Decision**: deploy 環境的 admin-api / postgres / redis container TZ = `Asia/Taipei`（UTC+8），**不是** spec 初稿假設的 UTC。

**Rationale**：

| 來源 | 證據 |
|---|---|
| `deploy/.env.example` line 43 | `TZ=Asia/Taipei` |
| `deploy/.env`（已 commit 設值） | `TZ=Asia/Taipei` |
| `deploy/compose.yaml` postgres / redis / migration / new-admin-rust-api 四個 service | 都有 `TZ: ${TZ:?must set TZ}`、無 fallback default → require .env 提供 |
| `admin-api/Dockerfile` ARG line 7 | `ARG TZ=Asia/Shanghai`（image-level default、同樣 UTC+8、行為等價） |
| `admin-api/entrypoint.sh` | 無 TZ 操作（不 override） |
| host `date "+%Z %z"` | `CST +0800`（dev 機本身即 UTC+8） |

→ 不論 deploy mode (compose container) 或 dev mode (cargo run on host)，`Local::now()` 都 = UTC+8 (Asia/Taipei 或等價)；既有 sys_tokens.naive 值都是 Asia/Taipei 語意。

**spec 中 A-001 誤判的源頭**：`admin-api/server/service/src/admin/sys_auth_service.rs:158-166` 的 T009 inline comment 寫「admin-api 容器內 Local::now() (UTC)」，這在 T009 測試的具體環境下可能成立（host TZ 設成 UTC 跑 cargo run），但對「正式 deploy」與「當前 dev 機」都不成立。spec 初稿襲用該 comment 是錯的，已於 Phase 0 修正為 Asia/Taipei。

**Alternatives considered**：

- **TRUNCATE sys_tokens 後 ALTER**：用戶 brainstorming 階段已評估、拒絕（強迫所有 user 重新 login）
- **仍用 'UTC' 接受偏移**：拒絕（會讓既有 row instant 偏移 -8h，expires_at 提前 8 小時、user 約 6 天後被踢下線、屬 silent corruption）
- **參數化 USING TZ（env var）**：拒絕（增加 migration 配置面、A-001 已確定為 Asia/Taipei、不需 future-proofing）

**Impact on FR**：FR-002 已從 `AT TIME ZONE 'UTC'` 改為 `AT TIME ZONE 'Asia/Taipei'`。

---

## R2 — chrono `fixed_offset()` method 可用性（A-002）

**Decision**: 確認 chrono 0.4.41 lock 解析、`Utc::now().fixed_offset()` 可直接使用、不需升 dep。

**Rationale**：

```
admin-api/Cargo.lock:
  name = "chrono"
  version = "0.4.41"
```

`DateTime::<Utc>::fixed_offset()` 自 chrono 0.4.31 起內建（[chrono changelog](https://github.com/chronotope/chrono/blob/main/CHANGELOG.md#0431---2023-10-09)）→ 0.4.41 包含。回傳 `DateTime<FixedOffset>` = sea-orm `DateTimeWithTimeZone` 完全 type-compatible。

**Alternatives considered**：

- `.into()` via `From<DateTime<Utc>> for DateTime<FixedOffset>` trait：可用但意圖不夠明確（讀者要 inference type 才知道目標）
- `Utc::now().with_timezone(&FixedOffset::east_opt(0).unwrap())`：明確但冗長
- `chrono::DateTime::<FixedOffset>::from(Utc::now())`：等價 `.into()`、同樣不夠明確

選 `.fixed_offset()` 因 method-call 形式 + 命名 self-documenting + chrono 提供的 idiomatic API。

---

## R3 — sea-orm `DateTimeWithTimeZone` binding 行為（A-003）

**Decision**: 確認 sea-orm 1.1.14 支援 `DateTimeWithTimeZone` 對 PostgreSQL timestamptz column 的 binding；INSERT/UPDATE 直接寫入 `DateTime<FixedOffset>`、SELECT 自動 deserialize、不需 manual conversion。

**Rationale**：

- `admin-api/Cargo.lock`: `sea-orm = "1.1.14"`、feature `"with-chrono"` 已啟用（per `Cargo.toml`：`features = ["runtime-tokio-native-tls", "macros", "with-chrono", "with-json"]`）
- sea-orm 官方 [type mapping table](https://www.sea-ql.org/SeaORM/docs/generate-entity/expanded-entity-structure/) 列：PostgreSQL `TIMESTAMPTZ` ↔ Rust `chrono::DateTime<FixedOffset>` ↔ sea-orm type alias `DateTimeWithTimeZone`
- 既有 codebase 無 `DateTimeWithTimeZone` 使用範例（`grep` 結果 0 命中）；本 feature 是首次引入但行為由 sea-orm 官方保證

**Verification（待實作階段驗證）**：

- 編譯通過：`cargo build -p server_model` 後 `sys_tokens::Model` struct 帶 3 個 `DateTimeWithTimeZone` field 通過
- runtime 行為：login → INSERT row → SELECT → `expires_at.timestamp()` 與 login 時間差 = `JwtConfig.refresh_token_expire` 秒

**Alternatives considered**：

- 使用 `chrono::DateTime<Utc>` 不轉 FixedOffset：sea-orm with-chrono feature 對 `DateTime<Utc>` 沒有正式 timestamptz mapping，會強制轉成 timestamp（無 TZ）— 與本 feature 目標衝突
- 自己 impl `From/Into`：違反 YAGNI，sea-orm 已提供 binding

---

## R4 — PostgreSQL `ALTER COLUMN ... USING ... AT TIME ZONE` 行為（A-004）

**Decision**: 確認 `ALTER TABLE sys_tokens ALTER COLUMN <col> TYPE TIMESTAMPTZ USING <col> AT TIME ZONE 'Asia/Taipei'` 對 naive value 的轉換是 **「treat naive as Asia/Taipei local time, then store as corresponding UTC instant in timestamptz column」**。

**Rationale**：

- PostgreSQL `<naive_timestamp> AT TIME ZONE 'X'` 的官方 [semantics](https://www.postgresql.org/docs/17/functions-datetime.html#FUNCTIONS-DATETIME-ZONECONVERT)：「Treat given timestamp without time zone as located in the specified time zone」→ 回傳 timestamptz（UTC-stored、按 session TZ render）
- 此意義正好對齊 R1 結論：既有 naive value 本來就是 Asia/Taipei 寫入、`AT TIME ZONE 'Asia/Taipei'` 是「告訴 Postgres 這個 naive 值的 TZ context」，conversion 正確
- 對 row 數量小（dev 通常 < 100 row）秒級完成；prod 若 row 大需評估 lock duration（本 feature 不涵蓋 prod scale，假設 row count manageable）

**Verification（待實作階段驗證）**：

- T002 contract test 後執行 psql `\d sys_tokens` 確認 3 欄 type = `timestamp with time zone`
- 取 migration up 前一筆 row 的 `EXTRACT(EPOCH FROM expires_at)` 為 V1、up 後同 row 為 V2、驗證 V2 == V1（差 0 秒）

**Alternatives considered**：

- `ALTER COLUMN ... TYPE TIMESTAMPTZ`（不帶 USING）：Postgres 預設用 session TZ 解讀 naive；session TZ 在 migration runtime 不可預測 → 可能引入 skew
- 拆兩段：先 `AT TIME ZONE 'Asia/Taipei' AT TIME ZONE 'UTC'`：多餘、`AT TIME ZONE 'X'` 已包含轉 UTC 的步驟

---

## R5 — Migration ordering vs admin-api startup（A-005 + A-006）

**Decision**: sea-orm migration 按檔名 lexical order 執行；compose.yaml 已用 `service_completed_successfully` condition 強制 `new-admin-rust-api` 等 `migration` service 完成才啟動 → migration 執行時無 admin-api instance 在運作、無 race condition。

**Rationale**：

- `admin-api/migration/src/schemas/` 既有檔案最後一個是 `m20260511_070000_add_expires_at_to_sys_tokens.rs`（feature 6 引入）；新檔以 `m20260512_*` 起頭可確保 lexical 在最後（A-005 satisfied）
- `deploy/compose.yaml` 已驗證：

```yaml
new-admin-rust-api:
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy
    migration:
      condition: service_completed_successfully  # ← 本 condition 保證 admin-api 等 migration 結束
```

→ A-006 satisfied（admin-api instance 不會在 migration 跑時開始 SELECT/INSERT sys_tokens）

**Alternatives considered**：

- 在 migration 加 advisory lock：multi-instance migration 並發場景才需要、單 init container 模式不需要
- 加 startup probe 確認 schema 已 ready：compose `service_completed_successfully` 已涵蓋

---

## R6 — Write sites enumeration（FR-006 + FR-007 完整性）

**Decision**: 完整列出 admin-api 內所有寫入 sys_tokens 3 欄的 site，確認本 feature 改動 3 處（+ 1 struct field type 改）已涵蓋全部。

**Rationale**：grep 結果

```
admin-api/server/service/src/admin/sys_auth_service.rs:153   let now = Local::now().naive_local();
  → 該 now 用於 SysTokensColumn::ExpiresAt.gt(now) filter（read-side 比較、非 write-side、但需同 TZ 才能正確比較）
  → 改 Utc::now().fixed_offset()（FR-006）

admin-api/server/service/src/admin/event_handlers/auth_event_handler.rs:51
  let expires_at = Local::now().naive_local() + Duration::seconds(jwt_config.refresh_token_expire);
  → 寫入 AccessTokenEvent.expires_at（cross-module struct field）
  → 改 Utc::now().fixed_offset() + Duration（FR-006）
  → 同步 AccessTokenEvent.expires_at 型別改 DateTimeWithTimeZone（FR-007）

admin-api/server/service/src/admin/events/access_token_event.rs:25
  let now = chrono::Local::now().naive_local();
  → 寫入 sys_tokens.login_time + sys_tokens.created_at（line 35 / 43）
  → 改 chrono::Utc::now().fixed_offset()（FR-006）
  → struct field expires_at 同上改 DateTimeWithTimeZone（FR-007）
```

**完整性 cross-check**（grep `SysTokensActiveModel\|sys_tokens.*Set\|expires_at:\s*Set` 全 codebase）：
- 寫 sys_tokens 的唯一 site = `access_token_event.rs::handle()`（INSERT only；UPDATE refresh status 在 `sys_auth_service.rs::refresh_token` 但不改 3 個 timestamp 欄）
- 寫 AccessTokenEvent.expires_at 的唯一 caller = `auth_event_handler.rs:51`
- → 改 3 處 write 即覆蓋全部

**Refresh path（read + write）特殊處理**：`sys_auth_service.rs::refresh_token` 在 rotate 時：
- read：用 `now` filter expired token → 改 Utc::now().fixed_offset() 後 binding 為 timestamptz vs timestamptz、正確比較 instant
- write：建新 sys_tokens row 走 `access_token_event.rs::handle()`（已涵蓋）；舊 row 只 UPDATE status 不改 timestamp 欄

**Alternatives considered**：

- 在 sea-orm ActiveModel 加 `created_at: Set(Utc::now().fixed_offset())` default：避免每處手寫，但會 over-engineer、且既有 pattern 是 explicit Set；保持 explicit Set 與既有 codebase consistent

---

## R7 — Retrospective 4-I1 root cause 確認（A-007）

**Decision**: 確認 4-I1 的 root cause 描述正確 — `TIMESTAMP WITHOUT TIME ZONE` column 對 TZ 模糊 + write/read TZ context 不一致是唯一 skew root cause。本 feature 的 fix（改 column type + 統一 write context 用 timezone-aware）涵蓋整個 root cause。

**Rationale**：

- 4-I1 描述見 `docs/INTEGRATION-CHECKLIST.md` retrospective backlog 第 `4-I1` 條
- inline comment 見 `admin-api/server/service/src/admin/sys_auth_service.rs:158-166` — 描述 dev 環境模式（cargo run on host）下的 TZ inconsistency；但 root cause 機制（TIMESTAMP 對 TZ 模糊 + 不同 session TZ 寫入）同 prod 場景
- 修補後：column 為 timestamptz（明確 TZ）+ Rust write 用 `Utc::now().fixed_offset()`（明確 UTC）→ 兩端都 TZ-aware、external session 用任何 TZ 觀察都得到同一 instant

**Side note — 該 inline comment 處理**：本 feature 套用後此 comment 描述的 "TZ skew" 不再成立、可移除（或改為「已修補 by feature 8」）。建議 implementation 階段（T011 task）順帶移除 comment、不另立 task。

---

## R8 — Down migration 政策（spec Edge Cases 補充）

**Decision**: down() 採取保守實作 — 直接 `ALTER COLUMN ... TYPE TIMESTAMP`（不帶 USING），文件化「down 僅作為 dev 緊急回退、prod 不應 down」並在 down() 註解內標示。

**Rationale**：

- down 從 timestamptz → timestamp 不帶 USING 時、Postgres 用 session TZ 投影 → 若 session TZ ≠ Asia/Taipei 會偏移；但 down 主要用途是 dev 緊急回退、可接受 session TZ 由 maintainer 自行控制
- 加 runtime guard（拒絕在 prod 執行）會複雜化（如何判定 prod 環境？env var 不可靠）→ 改採 comment 內標示 + spec Edge Cases 文件化
- prod rollback 的標準做法是「fix-forward」（再寫 corrective migration）而非 down；本 feature 對齊此 practice

**Alternatives considered**：

- down 帶 `USING <col> AT TIME ZONE 'Asia/Taipei'` 確保 instant 不偏移：更安全、但增加 down 不對稱性的認知負擔；本 feature 採保守實作（不額外加 USING）
- down 完全 unimplemented (`unimplemented!()`)：sea-orm migration trait require down impl、`unimplemented!()` runtime panic 不友好

---

## Summary — Phase 0 outcomes

| Item | Resolved | spec / plan impact |
|---|---|---|
| R1 container TZ 實際是 Asia/Taipei | ✅ | spec A-001 + FR-002 已修正 |
| R2 chrono 0.4.41 fixed_offset() 可用 | ✅ | 確認、無 dep change |
| R3 sea-orm DateTimeWithTimeZone binding | ✅（待 impl 階段運行驗證） | data-model.md + contracts/ entity diff |
| R4 ALTER USING semantics | ✅ | contracts/ migration SQL 已對齊 |
| R5 + R6 ordering + service_completed_successfully | ✅ | quickstart.md migration step 確認用既有 compose flow |
| R6 write sites 完整性 | ✅ | tasks.md 將涵蓋 3 處 + 1 struct field |
| R7 4-I1 root cause | ✅ | impl 階段順帶移除 inline comment |
| R8 down 政策 | ✅ | migration 檔註解 + spec Edge Cases 已說明 |
