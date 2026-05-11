---

description: "Tasks for feature 008 sys_tokens TIMESTAMP→TIMESTAMPTZ migration"
---

# Tasks: sys_tokens TIMESTAMP → TIMESTAMPTZ Migration

**Input**: Design documents from `/specs/008-gap-tz-1-timestamptz-migration/`
**Prerequisites**: plan.md, spec.md, research.md (R1-R8), data-model.md, contracts/{migration,entity}-contract.md, quickstart.md

**Tests**: 本 feature 不要求新寫 unit test（per spec — 既有 `cargo test --workspace` 涵蓋 schema 與 entity 改動的編譯期 + runtime invariants；dynamic 驗證在 US1/US2/US3 phase 收集 acceptance evidence）。

**Organization**: Tasks 依 user story 分組（US1/US2/US3）；Phase 1-2 是 shared infra + foundational implementation（前置整個 feature）；Phase 3-5 是 3 個 user story 的 dynamic acceptance evidence；Phase 6 為 polish + 兩段式 commit。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可並行（不同檔、無互相依賴）
- **[Story]**: User story 標籤（US1 / US2 / US3）— 僅 user story phase tasks 需

## Path Conventions

- admin-api 倉內：`admin-api/<path>`（worktree 模式，inner branch `new-admin-rust-api`）
- 外層 docs：`specs/008-gap-tz-1-timestamptz-migration/<path>`、`docs/<path>`、`CLAUDE.md`

---

## Phase 1: Setup（前置檢查與資料備份）

**Purpose**: 確認套用環境符合 spec Assumptions + 備份既有 row 作 instant 對照

- [ ] T001 確認 `deploy/.env` 設 `TZ=Asia/Taipei`（per spec A-001 + Phase 0 R1）。執行 `grep "^TZ=" deploy/.env`，預期輸出 `TZ=Asia/Taipei`；若否則停止此 feature、回報需先對齊 TZ 或重評 USING clause
- [ ] T002 確認 admin-api / admin-web 處於 worktree 模式且 inner branch 正確。執行 `ls -la admin-api/.git admin-web/.git` 確認皆為 file（非 dir）；執行 `cd admin-api && git branch --show-current` 確認在 `new-admin-rust-api`
- [ ] T003 [P] 備份既有 sys_tokens row（為 US3 SC-004 instant preserve 比對用）+ 掃描可疑外部寫入 row（spec Edge Case「既有 row 由非 admin-api 寫入」）。若 stack 已起：(a) `docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -c "COPY (SELECT id, refresh_token, EXTRACT(EPOCH FROM expires_at) AS expires_epoch, EXTRACT(EPOCH FROM created_at) AS created_epoch, EXTRACT(EPOCH FROM login_time) AS login_epoch FROM sys_tokens) TO STDOUT WITH CSV HEADER" > /tmp/sys_tokens_before_epoch.csv` 備份 epoch (b) 同 psql 跑 `SELECT COUNT(*) FROM sys_tokens WHERE ABS(EXTRACT(EPOCH FROM created_at) - EXTRACT(EPOCH FROM login_time)) > 5` 找 created_at 與 login_time 偏差 > 5 秒的可疑 row（admin-api 寫入時兩欄都用同一 `now`、差為 0；若有偏差暗示外部 SQL 介入）；若 count > 0、在 T017/T025 evidence 中標示「警示：N 筆可疑外部寫入 row，instant preserve 可能不對齊 A-001 假設」。若 stack 未起或表為空、產生空檔案並在 evidence 中註記「無既有 row、SC-004 trivially pass」

**Checkpoint**: Setup 完成 — 環境符合 A-001、worktree 就緒、既有 row epoch 已記錄

---

## Phase 2: Foundational（Migration + Entity + Write paths — 阻擋全部 user story）

**Purpose**: 完成 admin-api 倉內所有 code 改動 + 編譯驗證 + compose stack 起動 + migration 套用。**任何 user story 都不能在此 phase 完成前開始**。

**⚠️ CRITICAL**: 本 phase 是 foundation — T003~T013 全部完成才可進 US1/US2/US3 phase

### Migration（per contracts/migration-contract.md）

- [ ] T004 新增檔 `admin-api/migration/src/schemas/m20260512_000000_alter_sys_tokens_timestamptz.rs`，內容依 `contracts/migration-contract.md` 的 Rust 骨架（up() 用 raw SQL `ALTER COLUMN ... TYPE TIMESTAMPTZ USING <col> AT TIME ZONE 'Asia/Taipei'` 3 條、down() 用 `ALTER COLUMN ... TYPE TIMESTAMP` 3 條 + 註解標示「dev 緊急回退、prod 應 fix-forward」per Phase 0 R8）
- [ ] T005 在 `admin-api/migration/src/schemas/mod.rs` 註冊 `m20260512_000000_alter_sys_tokens_timestamptz`：(1) `mod` 宣告 (2) `Migrator::migrations()` vec 加新 entry 在最末（保 lexical order per R5）

### Entity + write paths（per contracts/entity-contract.md，可並行 — 不同檔）

- [ ] T006 [P] 改 `admin-api/server/model/src/admin/entities/sys_tokens.rs`：3 個 field `login_time` / `created_at` / `expires_at` 型別 `DateTime` → `DateTimeWithTimeZone`（`use sea_orm::entity::prelude::*;` 已 export、不需新 import）
- [ ] T007 [P] 改 `admin-api/server/service/src/admin/events/access_token_event.rs`：(1) 移除 `use chrono::NaiveDateTime;`、新增 `use sea_orm::prelude::DateTimeWithTimeZone;` (2) `AccessTokenEvent.expires_at` field 型別 `NaiveDateTime` → `DateTimeWithTimeZone` (3) line 25 `let now = chrono::Local::now().naive_local();` → `let now = chrono::Utc::now().fixed_offset();`
- [ ] T008 [P] 改 `admin-api/server/service/src/admin/event_handlers/auth_event_handler.rs`：(1) `use chrono::Local;` → `use chrono::Utc;`（先 grep 確認該檔內所有 `Local::now()` 都是本 feature scope 內、若有其他 keep `Local`）(2) line 51 `let expires_at = Local::now().naive_local() + Duration::seconds(...)` → `let expires_at = Utc::now().fixed_offset() + Duration::seconds(...)`
- [ ] T009 [P] 改 `admin-api/server/service/src/admin/sys_auth_service.rs`：(1) `use chrono::Local;` → `use chrono::Utc;`（同 T008 先 grep 確認 scope） (2) `refresh_token` fn 內 `let now = Local::now().naive_local();` → `let now = Utc::now().fixed_offset();` (3) 移除以 `NOTE (T009 動態驗證發現): sys_tokens.expires_at 是 TIMESTAMP WITHOUT TIME ZONE` 開頭、`本問題在正常運作不顯現；僅當運維外部 SQL 介入時暴露。` 結尾的整個 inline comment block（per Phase 0 R7 — 已被本 feature 根治、註解不再成立；用 comment 內文定位而非行號避免漂移）

### 編譯與單元測試（sequential — 依賴 T004~T009）

- [ ] T010 在 admin-api 倉內執行 `cargo build -p server_model --all-features` + `cargo build -p server_service --all-features` + `cargo build -p migration --all-features` 全部通過
- [ ] T011 在 admin-api 倉內執行 `cargo clippy --all-targets --all-features -- -D warnings` 通過
- [ ] T012 在 admin-api 倉內執行 `cargo test --workspace` 通過（既有 unit test 因 entity 型別變動可能需小調整、但本 feature 不主動新增 test）

### Stack 起動 + migration 套用

- [ ] T013 在 `deploy/` 目錄執行 `docker compose up -d --build` 重新 build + 起 stack（**不**加 `-v`、保留既有 postgres volume 中的 sys_tokens row 給 SC-004 instant preserve 驗證用；migration init container 會自動偵測 m20260512_000000 尚未套用、forward 套用即可）。確認 logs：`docker compose logs migration` 顯示 migration 成功完成（包含 m20260512_000000）、`docker compose ps` 顯示 `new-admin-rust-api` `healthy`。**例外**：若 dev 機 postgres volume 有壞掉的 partial migration state、需手動 `docker compose down -v && docker compose up -d --build` wipe 重來；但 wipe 會清空 sys_tokens、SC-004 退化為 trivial PASS（無既有 row 可比、在 T024 evidence 註明）

**Checkpoint**: Foundation 完成 — admin-api code 改完、cargo 全綠、stack healthy、migration 已套用。可開始 US1/US2/US3 phase 收集 acceptance evidence

---

## Phase 3: User Story 1 — Refresh token 過期判定不受外部 SQL session TZ 影響 (P1) 🎯 MVP

**Goal**: 驗證 sys_tokens.expires_at 改為 timestamptz 後，外部 psql session 用不同 TZ 觀察同一 row 得到同一 UTC instant；admin-api refreshToken 不受 session TZ 偏移影響。

**Independent Test**: 在 host psql 連入 postgres 容器、用 `SET TIME ZONE 'Asia/Taipei'` 與 `SET TIME ZONE 'UTC'` 兩次 SELECT 同一 ACTIVE row 的 expires_at、確認 `EXTRACT(EPOCH FROM expires_at)` 完全相等。

- [ ] T014 [P] [US1] curl `POST http://localhost:8080/api/auth/login` body `{"identifier":"Soybean","password":"123456"}` 取得 access/refresh token、記錄 refresh_token 字串 R 與當下 unix epoch T_login
- [ ] T015 [US1] 從 host 連入 postgres 容器：`docker exec -it new-admin-root-postgres-1 psql -U admin -d new_admin`。在同一 session 跑：(1) `SELECT EXTRACT(EPOCH FROM expires_at) FROM sys_tokens WHERE refresh_token = '<R>';` 記為 E_default (2) `SET TIME ZONE 'Asia/Taipei'; SELECT expires_at, EXTRACT(EPOCH FROM expires_at) FROM sys_tokens WHERE refresh_token = '<R>';` 記為 E_taipei + 觀察文字 format `+08` (3) `SET TIME ZONE 'UTC'; SELECT expires_at, EXTRACT(EPOCH FROM expires_at) FROM sys_tokens WHERE refresh_token = '<R>';` 記為 E_utc + 觀察文字 format `+00` (4) 驗證 `E_default == E_taipei == E_utc`（差為 0）
- [ ] T016 [US1] 在外部 psql 觀察過 row 之後（session TZ 任意）執行 curl `POST http://localhost:8080/api/auth/refreshToken` body `{"refreshToken":"<R>"}`、驗證回應 HTTP 200 + 新 access/refresh token（不誤判 expired、不受外部 session TZ 偏移影響）
- [ ] T017 [US1] 寫 acceptance evidence 到 `specs/008-gap-tz-1-timestamptz-migration/acceptance-evidence/T017-tz-skew-repro.md`：包含 (a) feature 8 SHA + admin-api inner SHA (b) T014~T016 完整 SQL/curl 輸出 (c) E_default/taipei/utc 三 epoch 數值比對表 (d) 標示 SC-003 PASS

**Checkpoint**: US1 完成 — TZ-skew 反證測試證明 4-I1 已根治、refreshToken 不受外部 TZ 影響

---

## Phase 4: User Story 2 — Login + Refresh flow 在 migration 後維持正常 (P1)

**Goal**: schema migration + Rust 改動後 admin-api 對外 login/refresh API 行為與 feature 4/5/6/7 後完全相同（HTTP 200 + JSON shape 不變 + JWT 有效）。

**Independent Test**: curl `/api/auth/login` 200 + JWT、接著 `/api/auth/refreshToken` 200 + 新 JWT、SELECT 新 row 確認 3 個 timestamp 欄是 timestamptz 且 instant 對應 login/refresh 時間。

- [ ] T018 [P] [US2] curl `POST http://localhost:8080/api/auth/login` body `{"identifier":"Soybean","password":"123456"}` 應回 HTTP 200，JSON body 含 `data.token`（JWT）+ `data.refreshToken`（26 字元 ULID）+ `data.tokenType: "Bearer"`。decode JWT claims 確認 `sub`/`username=Soybean`/`role=[ROLE_SUPER]`/`exp` 合理（feature 4 同 SC 模式）
- [ ] T019 [P] [US2] 使用 T018 取得的 refresh_token curl `POST http://localhost:8080/api/auth/refreshToken` body `{"refreshToken":"<R>"}` 應回 HTTP 200 + 新 token + 舊 token rotation。驗證 psql `SELECT refresh_token, status FROM sys_tokens WHERE refresh_token IN ('<old>', '<new>')` 顯示舊 row `status='REFRESHED'`、新 row `status='ACTIVE'`
- [ ] T020 [US2] psql SELECT 確認新 row 的 3 個欄位 instant 正確：`SELECT login_time, created_at, expires_at, EXTRACT(EPOCH FROM expires_at)-EXTRACT(EPOCH FROM login_time) AS diff_seconds FROM sys_tokens ORDER BY created_at DESC LIMIT 1`。預期 (a) 3 欄都帶 TZ offset 顯示（如 `2026-05-11 18:00:00+08`）(b) `diff_seconds` 與 `JwtConfig.refresh_token_expire` 一致（feature 6 預設 14 天 = 1209600 秒）
- [ ] T021 [US2] 寫 acceptance evidence 到 `specs/008-gap-tz-1-timestamptz-migration/acceptance-evidence/T021-functional.md`：包含 (a) feature 8 SHA + admin-api inner SHA (b) T018~T020 完整輸出 (c) login/refresh JWT decoded claims (d) 新 row instant 與 expected diff 比對 (e) 標示 SC-002 PASS

**Checkpoint**: US2 完成 — login/refresh API 對外行為與 feature 7 之後一致、無 regression

---

## Phase 5: User Story 3 — 既有 row instant 不偏移 + 其他 table 未受影響 (P2)

**Goal**: 驗證 (a) sys_tokens 3 欄已是 timestamptz（SC-001） (b) 其他 9+ table 的 timestamp 欄仍 without TZ（SC-006、FR-010 enforced） (c) migration 套用前 backup 的 row epoch == 套用後 epoch（SC-004、instant 不偏移）

**Independent Test**: psql `\d sys_tokens` 對 3 欄；`\d sys_user / sys_role / sys_login_log` 對其餘 timestamp 欄；epoch 比對。

- [ ] T022 [P] [US3] psql `\d sys_tokens`：確認 `login_time` / `created_at` / `expires_at` 三欄 Type 顯示 `timestamp with time zone`、`Nullable: not null`（SC-001）
- [ ] T023 [P] [US3] psql `\d sys_user`、`\d sys_role`、`\d sys_menu`、`\d sys_domain`、`\d sys_endpoint`、`\d sys_access_key`、`\d sys_organization`、`\d sys_login_log`、`\d sys_operation_log`：確認所有 timestamp 欄位仍是 `timestamp without time zone`（FR-010 + SC-006）
- [ ] T024 [US3] 若 T003 備份 csv 非空：對備份的每一筆 row id，psql SELECT 套用後同 id 的 `EXTRACT(EPOCH FROM expires_at)`，與 csv 中 `expires_epoch` 完全相等（差 0 秒）；同樣比 `created_at` 與 `login_time`（SC-004）。若備份 csv 為空、記為「無既有 row、trivially PASS」
- [ ] T025 [US3] 寫 acceptance evidence 到 `specs/008-gap-tz-1-timestamptz-migration/acceptance-evidence/T025-schema-preserve.md`：包含 (a) feature 8 SHA + admin-api inner SHA (b) T022 `\d sys_tokens` 完整輸出 (c) T023 其他 9 表 `\d` 部分輸出（只截 timestamp 欄）(d) T024 epoch 比對表（before/after/diff）(e) 標示 SC-001 / SC-004 / SC-006 PASS

**Checkpoint**: 全部 user story 完成 — schema 正確、既有 row instant 保存、其他 table 未受影響

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: 文件更新 + 兩段式 commit（per constitution §V）+ retrospective backlog 標完成

- [ ] T026 [P] 更新 `docs/INTEGRATION-CHECKLIST.md`：(a) 7-feature roadmap 表把 feature 8 各欄改 ✅ + 狀態欄改「完成」+ 加實作 commit SHA (b) Retrospective code review backlog 4-I1 行改 ✅「已修（feature 8 <短SHA>）」標示根治 (c) 8-feature roadmap 描述順序註腳更新
- [ ] T027 [P] 確認 `CLAUDE.md` SPECKIT marker 兩處（line 249-254 + 369-373）仍指向 008（plan 階段已更新、僅 verify）
- [ ] T028 第一段 commit（admin-api worktree inner）：`cd admin-api && git add migration/src/schemas/m20260512_000000_alter_sys_tokens_timestamptz.rs migration/src/schemas/mod.rs server/model/src/admin/entities/sys_tokens.rs server/service/src/admin/sys_auth_service.rs server/service/src/admin/event_handlers/auth_event_handler.rs server/service/src/admin/events/access_token_event.rs` → `git commit -m "feat(admin-api): F8 sys_tokens TIMESTAMP→TIMESTAMPTZ + DateTimeWithTimeZone"`（commit body 描述 6 個改動：migration / entity / 3 write-path / 移除 inline comment；註明根治 4-I1）
- [ ] T029 第一段 push（等用戶確認）：在 admin-api worktree 內 `git push origin new-admin-rust-api`（per global CLAUDE.md §5 — push 需用戶 OK；先報 commit landed、等用戶 go-ahead）
- [ ] T030 第二段 commit（outer SHA pin）：回到外層、`git add admin-api specs/008-gap-tz-1-timestamptz-migration/ docs/INTEGRATION-CHECKLIST.md CLAUDE.md` → `git commit -m "chore(submodule): bump admin-api 到 <短SHA>: F8 timestamptz migration"`（commit body 帶 inner commit SHA + 一行描述）
- [ ] T031 第二段 push（等用戶確認）：`git push`（同樣 per global CLAUDE.md §5、需用戶 go-ahead）

**Checkpoint**: feature 8 完成 — 兩段式 commit 對齊 constitution §V、roadmap 標完成、4-I1 backlog 結案

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 Setup（T001~T003）**：無前置；T001/T002 sequential（確認環境）、T003 可在 T002 後並行
- **Phase 2 Foundational（T004~T013）**：依賴 Phase 1
  - T004 (migration file) → T005 (mod.rs 註冊) sequential
  - T006/T007/T008/T009 (4 個 Rust 檔 diff) 可並行（不同檔）
  - T010 (build) / T011 (clippy) / T012 (test) sequential、依賴 T004~T009 全完成
  - T013 (compose up) 依賴 T010 通過
- **Phase 3~5 (US1/US2/US3)**：全部依賴 Phase 2 完成
  - US1/US2/US3 phase **彼此可並行**（不同 evidence file、psql / curl 觀察互不衝突）
  - 同 phase 內：T014/T018/T022 可立刻並行；T015→T016、T019→T020 sequential（資料相依）
- **Phase 6 Polish**：依賴 Phase 3-5 全完成（acceptance evidence 都寫好才能 commit）

### User Story Dependencies

- **US1 (P1, MVP)**：只依賴 Phase 2、不依賴 US2 / US3。實作 US1 即足以驗證 4-I1 已根治
- **US2 (P1)**：只依賴 Phase 2、不依賴 US1 / US3。驗證 login/refresh 無 regression
- **US3 (P2)**：只依賴 Phase 2、不依賴 US1 / US2。驗證 schema 正確 + 既有 row instant 保存

### Within Each User Story

- 沒有「test 先寫」紀律（per Tests OPTIONAL section、本 feature 不要求新 unit test）
- 取 token → 觀察 schema → 寫 evidence 的 linear flow

### Parallel Opportunities

- **Phase 2 內**：T006/T007/T008/T009（4 個 Rust 檔不同檔）可同時
- **Phase 3-5 跨 phase**：US1/US2/US3 的 evidence collection 可同時跑（psql query 互不衝突、curl 不會破壞既有 row）
- **Phase 6 內**：T026（docs/INTEGRATION-CHECKLIST.md）與 T027（CLAUDE.md verify）並行

---

## Parallel Example: Phase 2 Foundational

```bash
# 並行改 4 個 Rust 檔（T006~T009）：
Task: "改 admin-api/server/model/src/admin/entities/sys_tokens.rs 3 個 field 型別（T006）"
Task: "改 admin-api/server/service/src/admin/events/access_token_event.rs（T007）"
Task: "改 admin-api/server/service/src/admin/event_handlers/auth_event_handler.rs（T008）"
Task: "改 admin-api/server/service/src/admin/sys_auth_service.rs + 移除 inline comment（T009）"

# 等 4 個完成、串行 build/clippy/test：
T010 → T011 → T012 → T013
```

## Parallel Example: Phase 3-5 User Stories

```bash
# Phase 2 完成後、3 個 user story 的 evidence collection 可並行：
# US1 (T014-T017) — TZ-skew 反證
# US2 (T018-T021) — functional login/refresh
# US3 (T022-T025) — schema + preserve

# Phase 6 polish 也可部分並行：T026 (CHECKLIST.md) 與 T027 (CLAUDE.md verify)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

US1 是 feature 8 的核心 — 驗證 4-I1 silent prod risk 已根治。如果只跑 US1：

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US1
2. **STOP and VALIDATE**：US1 evidence + acceptance-evidence/T017 已寫成、SC-003 PASS、4-I1 退役

但實務上 feature 8 應該全跑（3 個 user story 都要求、且皆 P1/P2 高優先級）— US2 確保無 regression、US3 確保資料保存與 scope 不漂移。

### Incremental Delivery

1. Phase 1 → Phase 2 完成 = foundation 就緒
2. 加 US1 → STOP and VALIDATE → 4-I1 root cause 驗證已修
3. 加 US2 → STOP and VALIDATE → 無 regression
4. 加 US3 → STOP and VALIDATE → schema + 資料保存正確
5. 加 Phase 6 → 兩段式 commit + roadmap 結案

### Parallel Team Strategy

本 feature 規模小（single dev session 可 < 1 day 完成）、不建議多人並行；但若多人協作：

1. Dev A: Phase 1-2 全部（foundation）
2. Phase 2 完成後：
   - Dev A: US2 (functional 驗證)
   - Dev B: US1 (TZ-skew 反證)
   - Dev C: US3 (schema + preserve)
3. Phase 6 由 Dev A（或 leader）統一收尾

---

## Notes

- 本 feature 是 schema migration + Rust 型別改動的整合改造；scope 嚴格限縮 sys_tokens 單表 3 欄、Out of Scope 9 表明確排除（per FR-010 + constitution §III）
- 所有 cargo / docker / psql 命令在 quickstart.md 有完整版本；本 tasks.md 是執行 sequence 與檢查清單
- 兩段式 commit（T028→T030）對齊 constitution §V — 第一段 push 與第二段 push 都需用戶確認（per global CLAUDE.md §5）
- Phase 0 R1 修正：USING TZ 已對齊 deploy `Asia/Taipei`、不再用初稿 `'UTC'`；若 future 改部署到其他 TZ 區域、本 feature 假設失效、需 retrospectively 重評
- 移除 sys_auth_service.rs:158-166 inline TZ-skew comment（T009）— per Phase 0 R7、不另立 task
- acceptance-evidence/ 子目錄路徑與 feature 4/6/7 同 convention
