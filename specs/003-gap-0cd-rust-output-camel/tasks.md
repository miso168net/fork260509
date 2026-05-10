---

description: "Tasks for feature 003-gap-0cd-rust-output-camel"
---

# Tasks: gap-0cd-rust-output-camel

**Input**: Design documents from `/specs/003-gap-0cd-rust-output-camel/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/ ✅、quickstart.md ✅

**Tests**: 本 feature 規模 ≤ 5 行 Rust diff（實際 +3）、無 application logic 變動，「test」即靜態 grep + `cargo check` + （依 feature 6 merge）動態 curl wire smoke。**不另寫 unit test**。

**Organization**: tasks 依 1 個 P1 user story（US1 admin-web 完整消費 response）+ §V 兩段式 commit（admin-api 版）結構展開。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-api 倉內檔以 `admin-api/<path>` 表示；outer 倉檔以 root-relative path
- §V 兩段式 commit（**admin-api** 版，首次動）：T002/T003 在 admin-api/ worktree 內 commit、T005 push fork、T006 是 outer SHA pin commit + push outer

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 admin-api/ worktree health + 切到對的 branch（new-admin-rust-api）。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑 `git submodule status` 確認 admin-api 行行首為空格；`cd admin-api && git branch --show-current` 確認在 `new-admin-rust-api`；`git status` 確認 worktree clean；`ls -la admin-api/.git` 確認是 ASCII text（worktree mode）。

---

## Phase 2: Foundational

**Purpose**: 無 — 本 feature 無共享產物或 blocking prerequisite。直接進 user story。

---

## Phase 3: User Story 1 - admin-web 完整消費 admin-rust-api response (Priority: P1) 🎯 MVP

**Goal**: admin-rust-api response wire-level 對齊 admin-web 端期望（refreshToken 駝峰 + buttons array）。

**Independent Test**:
- 靜態（本 feature 自身可跑、不依賴 feature 6）：grep struct/handler 改動命中 + `cargo check --release` PASS
- 動態（依 feature 6 merge）：curl /api/auth/login `.data | keys` 含 `refreshToken`、curl /api/auth/getUserInfo `.data.buttons | type` = array

### Inner Commits（在 admin-api/ worktree 內，§V 第一段、admin-api 版）

- [ ] T002 [US1] 在 `admin-api/server/model/src/admin/output/sys_authentication.rs` 改 1 行（GAP-0c）：在 `pub struct AuthOutput` 前的 `#[derive(Clone, Debug, Serialize)]` 後加一行 `#[serde(rename_all = "camelCase")]`。跑 `cd admin-api && cargo check --release` 驗 cargo PASS。在 admin-api/ worktree 內 inner commit：`fix(admin-api): GAP-0c AuthOutput camelCase`（commit message 範本見 quickstart.md §1.3）。
- [ ] T003 [US1] 在 `admin-api/server/model/src/admin/output/sys_authentication.rs` 加 1 行 field（GAP-0d struct）：在 `UserInfoOutput` 內 `roles` field 後加 `pub buttons: Vec<String>,`。同時在 `admin-api/server/api/src/admin/sys_authentication_api.rs` 改 1 行（GAP-0d handler）：在 `get_user_info` 內 `UserInfoOutput { ... }` 初始化 block 內 `roles: ...` 後加 `buttons: vec![],`。跑 `cargo check --release` 驗 PASS。在 admin-web/ worktree 內 inner commit：`fix(admin-api): GAP-0d UserInfoOutput buttons placeholder`（涉 2 檔合 1 commit；commit message 範本見 quickstart.md §1.3）。
- [ ] T004 [US1] 在 admin-api/ 跑完整 `cargo build --release` 驗無 break（兩個 inner commits 完成後再跑、確認 release build PASS 對應 SC-301）。

### Inner Push（§V 第一段尾）

- [ ] T005 [US1] 在 admin-api/ worktree 內 push fork branch：`cd admin-api && git push origin new-admin-rust-api` 推 T002 + T003 兩個 inner commits 到 `https://github.com/miso168net/fork260509-soybean-admin-rust.git` 的 `new-admin-rust-api` branch。

### Outer Commit（§V 第二段）

- [ ] T006 [US1] 在 outer 倉做 SHA pin 提交：用 `cd admin-api && git rev-parse --short HEAD` 取 admin-api 新 SHA、回 outer `git add admin-api`、commit：`chore(submodule): bump admin-api 到 <短SHA>: feature 3 GAP-0cd`（commit message body 列入 T002/T003 兩 inner commit subjects；範本見 quickstart.md §1.6）。

### Static Acceptance

- [ ] T007 [US1] 在 outer repo root 跑 5 條 static acceptance 並記錄結果到 `specs/003-gap-0cd-rust-output-camel/acceptance-evidence/T007-static.md`：
   - (a) AuthOutput 有 `rename_all = "camelCase"` derive：`cd admin-api && grep -B 1 'pub struct AuthOutput' server/model/src/admin/output/sys_authentication.rs \| grep -q 'rename_all = "camelCase"'`
   - (b) UserInfoOutput 有 `pub buttons: Vec<String>`：`grep -A 8 'pub struct UserInfoOutput' .../sys_authentication.rs \| grep -q 'pub buttons: Vec<String>'`
   - (c) get_user_info handler 有 `buttons: vec![]` init：`grep -A 6 'fn get_user_info' .../sys_authentication_api.rs \| grep -q 'buttons: vec!\[\]'`
   - (d) `cargo check --release` 過：`cd admin-api && cargo check --release 2>&1 \| grep -qE 'Finished'`
   - (e) `git submodule status` 兩行行首空格：`test "$(git submodule status \| grep -c '^ ')" -eq 2`

   寫好 evidence 後 outer 倉 `git add specs/.../acceptance-evidence/T007-static.md && git commit -m "test(admin-api): T007 static acceptance evidence PASS"`。

**Checkpoint**: T002-T007 完成 = 本 feature 主交付完成，可 push outer + open PR。

---

## Phase Polish & Cross-Cutting

- [ ] T008 push outer：`git push origin 003-gap-0cd-rust-output-camel`（依 CLAUDE.md §5 push 須 user 同意；不要在 implement 階段自動跑）。
- [ ] T009 同步 `docs/INTEGRATION-CHECKLIST.md` 把 feature 3 那行的 spec/plan/impl 三欄 ☐ → ✅、狀態 「待」 → 「完成」、加 commit SHA range（feature 3 全部 outer commits）。outer 倉 commit。

---

## Out-of-Scope (Follow-up，依後續 features)

- [ ] T010 (follow-up，依 feature 6 dockerfile-envsubst merge) 動態 acceptance smoke：依 quickstart.md §2 走 `docker compose up -d ... new-admin-rust-api` + curl /auth/login + curl /auth/getUserInfo + jq 驗 wire shape（refreshToken 命中 + buttons array type）。記錄結果到 `specs/003-.../acceptance-evidence/T010-dynamic.md`。

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: 無依賴。
- **Phase 2 (Foundational)**: 無（本 feature 不需）。
- **Phase 3 (US1)**: 依 Phase 1。
- **Phase Polish**: 依 Phase 3 完成。
- **T010 follow-up**: 依 features 6 merge（feature 1 已 merged）。

### Within US1（Phase 3 內順序）

- T002 → T003 → T004 → T005 → T006 → T007（嚴格序列，§V 兩段式紀律）：
  - T002/T003 是 inner commits（admin-api/ worktree 內），各自跑 cargo check 確保不 break；可邏輯獨立但**必先**於 T005 push
  - T004 是完整 cargo build 驗證（在 inner commits 後跑、確保兩個改動合起來仍 PASS）
  - T005 是 push fork（必須在 T002-T004 都 commit + 驗完後做）
  - T006 是 outer SHA pin commit（必須在 T005 push 後做）
  - T007 static acceptance（在 T006 outer commit 後做）

### Polish 內

- T008（push outer）依 user 同意；T009（CHECKLIST 同步）獨立可隨時做。

### Parallel Opportunities

- **無 [P] 機會**：本 feature 全 task 序列依賴（§V 兩段式紀律 + cargo check 序列驗證）。
- 唯一可考慮：T002 與 T003 動不同 struct（AuthOutput vs UserInfoOutput），技術上 inner commits 可順序顛倒；但 GAP-0c 比 GAP-0d 直觀（only 1 行）、先做更舒服。維持 T002 → T003 順序。

---

## Implementation Strategy

### MVP First（單一 P1 user story）

整個 feature 即 MVP — T001-T007 = 主交付（含 acceptance）。

1. T001 健檢 worktree
2. T002 inner GAP-0c（含 cargo check）
3. T003 inner GAP-0d（含 cargo check）
4. T004 完整 cargo build 驗證
5. T005 inner push fork
6. T006 outer SHA pin commit
7. T007 static acceptance + commit evidence
8. 此時可 push outer（T008）+ open PR（user 同意後）+ T009 CHECKLIST 同步

預估時間：30-45 分鐘（含 cargo build 一次、第一次 build 可能 5-10 分鐘）。

### Follow-up（feature 6 merge 後）

9. T010 dynamic acceptance（curl wire smoke）

---

## Notes

- §V 兩段式 NON-NEGOTIABLE：T005 push fork 與 T006 outer commit 兩段紀律不可省略。
- T002/T003 wording 內含 commit message 範本，implementer 直接 copy quickstart.md §1.3 heredoc 用。
- T007 evidence 紀錄方式：依 constitution §IV「verification 證據」要求，本 feature 用獨立檔（不放 commit body 因為 cargo output 較長）。
- 本 feature 是**第一個動 admin-api submodule** 的 feature（feature 2 動的是 admin-web），T001-T007 路徑將被後續 feature 4（admin-api refresh handler）重用為兩段式 commit 範本。
- 動態 acceptance（T010）跨 feature 依賴 → 標 follow-up、不阻塞主 PR merge。
- cargo build 第一次可能慢（~10 分鐘）— admin-api 既有的 docker compose stack 應已有 cache（feature 1 跑過），但 host 端 `cargo check` 是首次（用本機 Cargo target/），仍可能 build cache miss。
