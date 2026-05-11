# Implementation Plan: sys_tokens TIMESTAMP → TIMESTAMPTZ Migration

**Branch**: `008-gap-tz-1-timestamptz-migration` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/008-gap-tz-1-timestamptz-migration/spec.md`

## Summary

**Primary requirement**：把 `sys_tokens.{login_time, created_at, expires_at}` 3 欄從 `TIMESTAMP WITHOUT TIME ZONE` 改為 `TIMESTAMPTZ`、Rust entity 對應改 `DateTimeWithTimeZone`、3 處 write-path 改 `Utc::now().fixed_offset()` — 根治 retrospective 4-I1 silent prod risk。

**Technical approach（per Phase 0 research）**：

1. 1 個 sea-orm migration file（raw SQL `ALTER COLUMN ... USING <col> AT TIME ZONE 'Asia/Taipei'`，per Phase 0 R1 修正 spec A-001、對齊實際 deploy TZ）
2. Entity diff：3 個 field type 改 + cross-module struct field `AccessTokenEvent.expires_at` 同步改
3. Write-path：3 處 `Local::now().naive_local()` → `Utc::now().fixed_offset()`
4. 3 層 acceptance：schema dump（SC-001/006）+ functional curl（SC-002）+ TZ-skew 反證 SELECT（SC-003/004）

## Technical Context

**Language/Version**: Rust 1.86（per constitution Additional Constraints 鎖定）
**Primary Dependencies**: chrono 0.4.41、sea-orm 1.1.14、sea-orm-migration 1.1.14（per Phase 0 R2/R3 確認 lock）
**Storage**: PostgreSQL 17（per constitution 鎖定）
**Testing**: cargo test --workspace + cargo clippy + dynamic acceptance（compose stack + curl + psql）
**Target Platform**: Linux container（alpine 3.21 final image，per admin-api/Dockerfile）；dev 可 cargo run on Linux/WSL
**Project Type**: Web-service backend（admin-api）— 本 feature 純 admin-api 改動、無 frontend / mobile 涉及
**Performance Goals**: SC-002 login/refresh API < 5 秒 SLA（與 feature 4/6/7 同水位）
**Constraints**: 不破壞既有 HTTP contract（FR-009）、不動 9+ 其他 tables（FR-010）、deploy TZ 假設為 Asia/Taipei（per R1）
**Scale/Scope**: ~30 行 Rust diff + 1 個 migration file (~50 行) + 3-4 個 acceptance evidence markdown。中等規模。

## Constitution Check

依 constitution v1.1.0、本 feature 對 §I-§VII 的 compliance：

| 原則 | Compliance | 說明 |
|---|---|---|
| §I 同源反代優先 | ✅ N/A | 本 feature 不涉及 CORS / port 暴露 |
| §II 外部化設定 | ✅ | 沒新增 hardcode；TZ 設定仍由 deploy/.env 注入 |
| §III 最小 GAP 修補 | ✅ | scope 限縮 sys_tokens 單表 3 欄；明確列出 Out of Scope 9 表、FR-010 enforced。spec scope 段標示這是 retrospective 4-I1 根治、不順手 refactor 其他表 |
| §IV 上游驗證 | ✅ | spec.md Assumptions A-001~A-007 列出 + Phase 0 R1-R8 個別驗證 + 修正 A-001。impl 階段需附 verification commands 在 commit body |
| §V 兩段式 submodule commit | ✅ | quickstart.md 已記錄第一段（admin-api inner）+ 第二段（outer SHA pin）操作 |
| §VI Spec-Driven Development | ✅ | 走 /speckit-specify → /speckit-clarify（觀察無 critical ambiguity） → /speckit-plan → 將續 /speckit-tasks → /speckit-implement |
| §VII Conventional Commits 中文 | ✅ | quickstart.md commit message 範例使用 `feat(admin-api):` / `chore(submodule):` 中文 |

**Gate result**: ✅ PASS（無 Complexity Tracking 條目需 justify）

## Project Structure

### Documentation (this feature)

```text
specs/008-gap-tz-1-timestamptz-migration/
├── plan.md              # This file (/speckit-plan command output)
├── spec.md              # /speckit-specify output（A-001 已於 Phase 0 修正）
├── research.md          # Phase 0 R1-R8（含 A-001 修正、container TZ Asia/Taipei 證據）
├── data-model.md        # Phase 1 sys_tokens schema diff + Rust entity/struct diff
├── quickstart.md        # Phase 1 套用流程 + 5 層 verify + 兩段 commit 範例
├── contracts/
│   ├── migration-contract.md   # m20260512_000000 SQL + Rust 骨架
│   └── entity-contract.md      # sys_tokens.rs + 3 write-path diff
├── checklists/
│   └── requirements.md  # /speckit-specify quality checklist（已 pass）
└── tasks.md             # 待 /speckit-tasks 產
```

### Source Code（admin-api worktree）

```text
admin-api/                                                       ← worktree（branch new-admin-rust-api）
├── migration/
│   └── src/
│       └── schemas/
│           ├── mod.rs                                            ← 註冊新 migration
│           └── m20260512_000000_alter_sys_tokens_timestamptz.rs  ← ⭐ 新增
├── server/
│   ├── model/
│   │   └── src/
│   │       └── admin/
│   │           └── entities/
│   │               └── sys_tokens.rs                             ← 改 3 個 field 型別
│   └── service/
│       └── src/
│           └── admin/
│               ├── sys_auth_service.rs                           ← 改 line 153 + 移除 inline TZ-skew comment
│               ├── event_handlers/
│               │   └── auth_event_handler.rs                     ← 改 line 51
│               └── events/
│                   └── access_token_event.rs                     ← 改 struct field type + line 25
```

**Structure Decision**: 本 feature 純 admin-api 倉內改動、不涉及外層 deploy/、不涉及 admin-web/。所有 source code 改動在 worktree（會 push 回 fork branch `new-admin-rust-api`）；外層只追蹤 spec/plan 文件與 submodule SHA pin 變動。

## Complexity Tracking

> 本 feature 無 Constitution Check 違規條目；本段保持空。

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |

---

## Phase 0 Outline & Research（已執行、見 research.md）

Phase 0 已完成、產出 `research.md` 涵蓋 R1-R8：

| Item | Resolved |
|---|---|
| R1 container TZ 實際是 Asia/Taipei（修正 A-001） | ✅ spec 已修正 |
| R2 chrono 0.4.41 `fixed_offset()` 可用 | ✅ |
| R3 sea-orm DateTimeWithTimeZone binding 行為 | ✅（待 impl 運行驗證） |
| R4 PostgreSQL ALTER USING semantics | ✅ |
| R5 migration lexical order | ✅ |
| R5b admin-api 等 migration 完成才啟動 | ✅（compose service_completed_successfully） |
| R6 write sites 完整性 enumeration | ✅（3 處 + 1 struct field） |
| R7 4-I1 root cause confirmation | ✅（順帶移除 inline comment） |
| R8 down migration 政策 | ✅（保守實作 + comment 標示） |

## Phase 1 Design & Contracts（已執行）

| 產出 | 路徑 |
|---|---|
| data-model.md（sys_tokens schema diff、Rust entity diff、cross-module struct diff、write-path 對齊） | `specs/008-.../data-model.md` |
| contracts/migration-contract.md（migration up/down Rust 骨架 + SQL） | `specs/008-.../contracts/migration-contract.md` |
| contracts/entity-contract.md（4 個 Rust 檔 diff） | `specs/008-.../contracts/entity-contract.md` |
| quickstart.md（套用流程 + 5 層 verify + 兩段 commit + rollback） | `specs/008-.../quickstart.md` |
| Agent context update | 將更新 `CLAUDE.md` 的 `<!-- SPECKIT START --> ... <!-- SPECKIT END -->` 區段指向本 plan.md |

## Re-evaluate Constitution Check Post-Design

設計階段未發現任何新的 constitution 違規條目：

- §I～§VII 全 ✅
- 設計階段補強了「§IV 上游驗證」— Phase 0 修正 A-001 後、USING TZ 已對齊實際 deploy
- §III 嚴格遵守 — sys_tokens 單表、3 欄、明確排除其他表

**Final gate result**: ✅ PASS — 可進入 `/speckit-tasks` 階段。

## Outstanding Items / Notes

- **A-003 sea-orm binding 運行驗證** 列在 tasks.md（編譯 + cargo test 涵蓋；dynamic curl 也涵蓋）
- **dev 機環境清理**：若 dev 機既有 sys_tokens row 是用奇怪 TZ 寫入（如過去 cargo run 時 host TZ 不一致），個別 row 可能轉換後 instant 偏移；建議套用前 truncate dev sys_tokens 或接受 dev session 重設
- **inline TZ-skew comment 移除**：作為 entity-contract 一部分（sys_auth_service.rs 改動）、不另立 task
