---

description: "Tasks for feature 002-gap-0ab0f-frontend-env-and-login"
---

# Tasks: gap-0ab0f-frontend-env-and-login

**Input**: Design documents from `/specs/002-gap-0ab0f-frontend-env-and-login/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/ ✅、quickstart.md ✅

**Tests**: 本 feature 規模 ≤ 5 行 diff、無 application logic 變動，「test」即靜態 grep + diff 驗證 + （依 feature 6 merge）動態 manual smoke。**不另寫 unit test**。

**Organization**: tasks 依 1 個 P1 user story（US1 login flow）+ §V 兩段式 commit 結構展開。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-web 倉內檔以 `admin-web/<path>` 表示（從 outer repo root 看）；outer 倉檔以 root-relative path
- §V 兩段式 commit：T001/T002 在 admin-web/ worktree 內 commit、T003 push fork、T004 是 outer SHA pin commit + push outer

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 worktree health + 切到對的 branch。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑 `git submodule status` 確認 admin-web 行行首為空格（clean）；跑 `cd admin-web && git branch --show-current` 確認在 `new-admin-base-web` branch、不在的話 `git checkout new-admin-base-web`；跑 `git status` 確認 worktree clean（未 commit 改動會在後續 task 累進，本 setup 確認**起始狀態**乾淨）

---

## Phase 2: Foundational

**Purpose**: 無 — 本 feature 無共享產物或 blocking prerequisite。直接進 user story。

---

## Phase 3: User Story 1 - Login flow wire-level 對齊 (Priority: P1) 🎯 MVP

**Goal**: admin-web 對 admin-rust-api 的 wire-level（HTTP code + login body field）完整對齊，operator 可在 dev 模式用 Soybean@123. login 通過。

**Independent Test**:
- 靜態（本 feature 自身可跑）：`grep -cE '...' admin-web/.env` ≥ 4 + `grep -qE 'identifier:\\s*userName' admin-web/src/service/api/auth.ts`
- 動態（依賴 feature 6 merge）：dev stack + `pnpm dev` + 瀏覽器 manual smoke login Soybean@123. 看到首頁

### Inner Commits（在 admin-web/ worktree 內，§V 第一段）

- [ ] T002 [US1] 在 `admin-web/.env` 改 4 行 value（GAP-0a + GAP-0b）：`VITE_SERVICE_SUCCESS_CODE=200`（line 32 由 0000）、`VITE_SERVICE_LOGOUT_CODES=`（line 35 由 8888,8889 清空）、`VITE_SERVICE_MODAL_LOGOUT_CODES=`（line 38 由 7777,7778 清空）、`VITE_SERVICE_EXPIRED_TOKEN_CODES=401`（line 41 由 9999,9998,3333）。在 admin-web/ worktree 內 inner commit：`fix(admin-web): GAP-0a + 0b 對齊 admin-rust-api wire-level codes`（commit message 範本見 quickstart.md §1.2）。
- [ ] T003 [US1] 在 `admin-web/src/service/api/auth.ts` 改 1 行 data field rename（GAP-0f）：`fetchLogin` 函式內 data 物件 `{ userName, password }` 改為 `{ identifier: userName, password }`（保留入參名 `userName`）。在 admin-web/ worktree 內 inner commit：`fix(admin-web): GAP-0f login body field userName → identifier`（commit message 範本見 quickstart.md §1.2）。
- [ ] T004 [US1] 在 `admin-web/` worktree 內 push fork branch：`cd admin-web && git push origin new-admin-base-web` 推 T002 + T003 兩個 inner commits 到 `https://github.com/miso168net/fork260509-soybean-admin-base.git` 的 `new-admin-base-web` branch。

### Outer Commit（§V 第二段）

- [ ] T005 [US1] 在 outer 倉（`/mnt/d/AnewSpaces/x_Project/fork260509`）做 SHA pin 提交：`git add admin-web` 把 admin-web 新 SHA pin 加入 staging（git 會記 gitlink 而非檔案 diff）；用 `cd admin-web && git rev-parse --short HEAD` 取新 SHA、寫進 outer commit message：`chore(submodule): bump admin-web 到 <短SHA>: feature 2 GAP-0ab0f`（commit message body 列入 T002/T003 兩 inner commit subjects；範本見 quickstart.md §1.4）。

### Static Acceptance（本 feature 自身可跑）

- [ ] T006 [US1] 在 outer repo root 跑 5 條 static acceptance 並記錄結果到 `specs/002-gap-0ab0f-frontend-env-and-login/acceptance-evidence/T006-static.md`：
   - (a) `cd admin-web && grep -cE '^(VITE_SERVICE_SUCCESS_CODE=200\|VITE_SERVICE_LOGOUT_CODES=\|VITE_SERVICE_MODAL_LOGOUT_CODES=\|VITE_SERVICE_EXPIRED_TOKEN_CODES=401)$' .env` = 4
   - (b) `cd admin-web && grep -qE 'identifier:\\s*userName' src/service/api/auth.ts` 命中
   - (c) `cd admin-web && ! grep -E '^VITE_SERVICE_(SUCCESS_CODE=0000\|LOGOUT_CODES=8888\|MODAL_LOGOUT_CODES=7777\|EXPIRED_TOKEN_CODES=9999)' .env` 命中（殘留 fake codes 計數 = 0）
   - (d) `git submodule status \| grep -c '^ '` = 2（兩 submodule clean）
   - (e) `cd admin-web && git log --oneline -3` 看到 T002/T003 兩個 inner commits

   寫好 evidence 後 outer 倉 `git add specs/.../acceptance-evidence/T006-static.md && git commit -m "test(admin-web): T006 static acceptance evidence PASS"`。

**Checkpoint**: T002-T006 完成 = 本 feature 主交付完成，可 push outer + open PR。

---

## Phase Polish & Cross-Cutting

- [ ] T007 push outer：`git push origin 002-gap-0ab0f-frontend-env-and-login`（依 CLAUDE.md §5 push 須 user 同意；不要在 implement 階段自動跑）。
- [ ] T008 同步 `docs/INTEGRATION-CHECKLIST.md` 把 feature 2 那行的 spec/plan/impl 三欄 ☐ → ✅、狀態 「待」 → 「完成」、加 commit SHA range（feature 2 全部 commits，inner + outer 都列）。outer 倉 commit。

---

## Out-of-Scope (Follow-up，依賴後續 features)

- [ ] T009 (follow-up，依賴 feature 6 dockerfile-envsubst) 動態 acceptance smoke + 預設密碼驗證：依 quickstart.md §2.3 / §2.4 走 `cp .env.example .env` + `docker compose up -d ... new-admin-rust-api` + `cd admin-web && pnpm dev` + 瀏覽器手動 login Soybean@123. + 用 curl 驗 3 個 user 預設密碼。記錄結果到 `specs/002-.../acceptance-evidence/T009-dynamic.md`。回填 spec.md `Assumptions > 待驗證` 把預設密碼項勾 ✅；回填 CLAUDE.md §5.1 移除「待驗證」字樣。

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: 無依賴。
- **Phase 2 (Foundational)**: 無（本 feature 不需）。
- **Phase 3 (US1)**: 依 Phase 1。
- **Phase Polish**: 依 Phase 3 完成。
- **T009 follow-up**: 依 features 6 merge（feature 1 也已 merged）。

### Within US1（Phase 3 內順序）

- T002 → T003 → T004 → T005 → T006（嚴格序列，§V 兩段式紀律必遵守）：
  - T002/T003 是 inner commits（admin-web/ worktree 內），可邏輯獨立但**必先**於 T004 push
  - T004 是 push fork（必須在 T002/T003 都 commit 後做）
  - T005 是 outer SHA pin commit（必須在 T004 push 後做、否則 origin/new-admin-base-web 沒新 SHA）
  - T006 static acceptance（在 T005 outer commit 後做、避免 working tree 有 staged 但未 commit）

### Polish 內

- T007（push outer）依 user 同意；T008（CHECKLIST 同步）獨立可隨時做。

### Parallel Opportunities

- **Phase 3 內 [P]**：T002 與 T003 動不同檔（`.env` vs `auth.ts`），技術上可平行；但 §V 兩段式紀律要求「先 inner commit、再 push」、序列做更安全；故**不標 [P]**（避免實作者誤以為可同 commit）。
- **無其他 [P] 機會**：本 feature 全 task 序列依賴。

---

## Implementation Strategy

### MVP First（單一 P1 user story）

整個 feature 即 MVP — 5 個 task（T001 + T002-T006）= 主交付。

1. T001 健檢 worktree
2. T002 inner GAP-0a/0b
3. T003 inner GAP-0f
4. T004 inner push fork
5. T005 outer SHA pin commit
6. T006 static acceptance + commit evidence
7. 此時可 push outer（T007）+ open PR（user 同意後）

預估時間：30 分鐘（依 quickstart.md §1）。

### Follow-up（feature 6 merge 後）

8. T009 dynamic acceptance + 預設密碼驗證 + 回填 spec / CLAUDE.md

---

## Notes

- §V 兩段式 NON-NEGOTIABLE：T004 push fork 與 T005 outer commit 兩段紀律不可省略。
- T002/T003 wording 已內含 commit message 範本，implementer 直接 copy quickstart.md §1.2 內 heredoc 用。
- T006 evidence 紀錄方式：依 constitution §IV「verification 證據」要求，本 feature 用獨立檔（不放 commit body 因為跨多 task）。
- 本 feature 是**第一個動 submodule** 的 feature，T002-T005 路徑將被後續 features 4/5/7 重用為 §V 兩段式 commit 範本。
- 動態 acceptance（T009）跨 feature 依賴 → 標 follow-up、不阻塞主 PR merge。
