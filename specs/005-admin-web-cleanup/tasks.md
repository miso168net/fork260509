---

description: "Tasks for feature 005-admin-web-cleanup"
---

# Tasks: admin-web-cleanup

**Input**: Design documents from `/specs/005-admin-web-cleanup/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/admin-web-api-cleanup.md ✅、quickstart.md ✅

**Tests**: admin-web 既有 `pnpm typecheck` + `pnpm lint` + `pnpm build` 三大 verify 即靜態 acceptance；動態 acceptance（curl / browser DevTools）依 feature 6 docker stack merge 後跑 follow-up。**不另寫 unit test**（與 features 2/3 同模式，承襲 admin-web 倉既有 CI 範圍）。

**Organization**: tasks 依 2 個 user stories（US1 P1 = GAP-4 user routes path / US2 P2 = GAP-2 + GAP-3 cleanup）+ §V 兩段式 commit（admin-web 版，第 2 次走 — 重用 feature 2 模式）展開。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-web 倉內檔以 `admin-web/<path>` 表示；outer 倉檔以 root-relative path
- §V 兩段式 commit（**admin-web** 版、第 2 個使用本模式的 feature）：T002/T003/T004 在 admin-web/ worktree 內各自 commit、T006 push fork、T007 是 outer SHA pin commit

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 admin-web/ worktree health + 切到對的 branch（new-admin-base-web）+ pnpm 環境 ready。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑 `git submodule status` 確認 admin-web 行行首為空格（clean，SHA 為 feature 2 完成時的 29874dd3）；`cd admin-web && git branch --show-current` 確認在 `new-admin-base-web`；`git status` 確認 worktree clean；`ls -la admin-web/.git` 確認是 ASCII text（worktree mode）；`cd admin-web && pnpm --version` 確認 ≥ 10.5、必要時跑 `pnpm install` ready node_modules。

---

## Phase 2: Foundational

**Purpose**: 無 — 所有改動位於 admin-web 倉內，各 inner commit 自我 `pnpm typecheck` PASS 即可推進；foundational concept 不適用本 feature 結構。

---

## Phase 3: User Story 1 - admin-web 取得 user routes 後正常進 dashboard (Priority: P1) 🎯 MVP

**Goal**: admin-web `fetchGetUserRoutes` 打對 admin-api 既有 `/auth/getUserRoutes` endpoint，user routes 載入成功、dashboard 進得去。

**Independent Test**:
- 靜態（本 feature 自身可跑）：grep `'/route/getUserRoutes'` 在 admin-web `src/` 內 0 hits + grep `'/auth/getUserRoutes'` ≥ 1 hits + `pnpm typecheck` PASS
- 動態（依 feature 6 docker stack 或本機 admin-api cargo run）：login 後 DevTools Network 確認 fetchGetUserRoutes 命中 `/auth/getUserRoutes` + response 200 + dashboard 顯示對應 menu

### Inner Commit（在 admin-web/ worktree 內，§V 第一段、admin-web 版）

- [ ] T002 [US1] 在 `admin-web/src/service/api/route.ts` 改 line 10：把 `fetchGetUserRoutes` 函式內 `url: '/route/getUserRoutes'` 改為 `url: '/auth/getUserRoutes'`（GAP-4，**1 行**改動；對齊 admin-api `init_protected_router()` 內既有 `/auth/getUserRoutes` 註冊，R1 已驗）。跑 `cd admin-web && pnpm typecheck` 驗 PASS。在 admin-web/ worktree 內 inner commit：`fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes`。

**Checkpoint**: T002 完成 = US1 MVP 主交付完成；admin-web 在 dynamic 與 static mode 皆能成功載 user routes 進 dashboard（feature 6 merged 後可動態驗）。

---

## Phase 4: User Story 2 - admin-web 不再呼叫不存在的 admin-api endpoints (Priority: P2)

**Goal**: 刪除 admin-web 內呼叫 admin-api 不存在 endpoints 的 callers — `fetchCustomBackendError`（dead code）+ `fetchIsRouteExist`（dynamic-mode 用、改本地查 `authRoutes.value`）。

**Independent Test**:
- 靜態：grep `fetchCustomBackendError` 在 admin-web `src/` 內 0 hits + grep `fetchIsRouteExist` 與 `/route/isRouteExist` 0 hits + `pnpm typecheck` PASS
- 動態（依 feature 6 merge）：在 dynamic-mode 下 navigate 到 not-found URL，DevTools Network 應 0 個 `/route/isRouteExist` request；UI 跳 not-found 頁面

### Inner Commits（在 admin-web/ worktree 內，§V 第一段續）

- [ ] T003 [US2] 在 `admin-web/src/service/api/auth.ts` 刪除 line 40-48 整塊（含 JSDoc 與 `fetchCustomBackendError` 函式定義；上方空行也一併清掉，淨 -8 至 -9 行；GAP-2，骨架見 quickstart.md §A.1 inner commit 1）。跑 `cd admin-web && pnpm typecheck` 驗 PASS（grep 確認 `fetchCustomBackendError` 在 src/ 內 0 hits，純 dead code、刪除無 break）。在 admin-web/ worktree 內 inner commit：`fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError`。

- [ ] T004 [US2] **改 2 個檔**（GAP-3 整體）：
   - **改 `admin-web/src/service/api/route.ts`**：刪除 line 13-20 整塊（含 JSDoc 與 `fetchIsRouteExist` 函式；淨 -8 行）。最終檔內僅 `fetchGetConstantRoutes` 與 `fetchGetUserRoutes` 兩個 exports。
   - **改 `admin-web/src/store/modules/route/index.ts`**：
     - line 7 import 整理：把 `import { fetchGetConstantRoutes, fetchGetUserRoutes, fetchIsRouteExist } from '@/service/api';` 改為 `import { fetchGetConstantRoutes, fetchGetUserRoutes } from '@/service/api';`（刪 `fetchIsRouteExist`）。
     - line 306-308 dynamic-mode 路徑改寫：把 `const { data } = await fetchIsRouteExist(routeName); return data;` 改為 `return isRouteExistByRouteName(routeName, authRoutes.value);`（本地查既有 `authRoutes` shallowRef，R3 已驗；既有 `isRouteExistByRouteName` helper from `shared.ts` 重用）。
     - **不動** static-mode 分支（line 301-304）— FR-535 保留既有行為。
   - 跑 `cd admin-web && pnpm typecheck` 驗 PASS。在 admin-web/ worktree 內 inner commit：`fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes`。

**Checkpoint**: T002 + T003 + T004 完成 = US1 + US2 主交付完成；admin-web 全部對 admin-api 既有 endpoints 對齊；dead code 已清。

---

## Phase 5: Polish & Cross-Cutting

### Build verify（所有 inner commits 後跑完整 validation）

- [ ] T005 在 `admin-web/` 內跑完整 build verify：`pnpm typecheck` + `pnpm lint` + `pnpm build` 全部 PASS（vite production build 應產出 dist/）。對應 spec SC-501。任一 step 失敗 → 回上游 task 修正再跑。

### Inner Push（§V 第一段尾）

- [ ] T006 在 admin-web/ worktree 內 push fork branch：`cd admin-web && git push origin new-admin-base-web` 推 T002 + T003 + T004 三個 inner commits 到 `https://github.com/miso168net/fork260509-soybean-admin.git` 的 `new-admin-base-web` branch。**push 需 user 授權**（CLAUDE.md §5）。

### Outer Commit（§V 第二段）

- [ ] T007 在 outer 倉做 SHA pin 提交：
   - 用 `cd admin-web && git rev-parse --short HEAD` 取 admin-web 新 SHA
   - 回 outer：`git add admin-web`
   - outer commit：`chore(submodule): bump admin-web 到 <短SHA>: feature 5 admin-web cleanup (GAP-2/3/4)`（commit message body 列入 T002/T003/T004 三個 inner commit subjects；範本見 research.md R5）

### Static Acceptance

- [ ] T008 在 outer repo root 跑 7 條 static acceptance 並記錄結果到 `specs/005-admin-web-cleanup/acceptance-evidence/T008-static.md`：
   - (a) `fetchCustomBackendError` 已刪：`grep -rn 'fetchCustomBackendError' admin-web/src/` 應 0 hits（FR-501/502, SC-502）
   - (b) `fetchIsRouteExist` 已刪：`grep -rn 'fetchIsRouteExist' admin-web/src/` 應 0 hits（FR-510/521, SC-503）
   - (c) `/route/isRouteExist` literal 已 0 hits：`grep -rn "/route/isRouteExist" admin-web/src/` 應 0 hits（SC-503）
   - (d) `/route/getUserRoutes` literal 已 0 hits：`grep -rn "'/route/getUserRoutes'" admin-web/src/` 應 0 hits（SC-504）
   - (e) `/auth/getUserRoutes` ≥ 1 hits：`grep -rn "'/auth/getUserRoutes'" admin-web/src/` 應命中 route.ts line 10（SC-504, FR-511）
   - (f) `pnpm typecheck` + `pnpm lint` + `pnpm build` 全 PASS（SC-501；證據可引 T005 結果或重跑）
   - (g) **diff line cap 驗證**（SC-507 ≤ 30 行）：`cd admin-web && git diff origin/new-admin-base-web~3..origin/new-admin-base-web --shortstat` insertions+deletions 合計應 ≤ 30 行（含 import 整理；shortstat 粗略 cap，若稍超出可手動 inspect diff 排除註解 / 空行後核對）

   寫好 evidence 後 outer 倉 `git add specs/005-admin-web-cleanup/acceptance-evidence/T008-static.md && git commit -m "test(admin-web): T008 static acceptance evidence PASS"`。

**Checkpoint**: T001-T008 完成 = feature 5 主交付完成，可 push outer + open PR / FF merge to new-admin-root。

### Push outer

- [ ] T009 push outer：`git push origin 005-admin-web-cleanup`（依 CLAUDE.md §5 push 須 user 同意；**不要**在 implement 階段自動跑）。

### CHECKLIST sync

- [ ] T010 同步 `docs/INTEGRATION-CHECKLIST.md`：
   - feature 5 row spec/plan/impl 三欄 ☐ → ✅、狀態「待」→「完成」、加 commit SHA range（feature 5 全部 outer commits 含 T007 SHA pin commit + T008 evidence commit）
   - 不需動跨 feature 待驗證項（feature 5 沒新增 §IV 待驗）
   - outer 倉 commit：`docs: INTEGRATION-CHECKLIST feature 5 標完成`

---

## Out-of-Scope (Follow-up，依後續 features)

- [ ] T011 (follow-up，依 feature 6 dockerfile-envsubst merge) dynamic acceptance smoke：依 quickstart.md §B 走 admin-web `pnpm dev` + admin-api docker stack → 開瀏覽器 login → 驗 fetchGetUserRoutes 命中 `/auth/getUserRoutes` + dynamic-mode not-found URL 不打 `/route/isRouteExist`。記錄結果到 `specs/005-admin-web-cleanup/acceptance-evidence/T011-dynamic.md`。

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: 無依賴。
- **Phase 2 (Foundational)**: 無（本 feature 不需）。
- **Phase 3 (US1)**: 依 Phase 1。
- **Phase 4 (US2)**: 依 Phase 1（**不**依 Phase 3 — 兩 user stories 互相獨立）。
- **Phase 5 (Polish)**: 依 Phase 3 + Phase 4 完成。
- **T011 follow-up**: 依 features 6 merge。

### Within US1（Phase 3 內順序）

- T002 單一 task；含 cargo / pnpm typecheck 驗、加 inner commit。

### Within US2（Phase 4 內順序）

- T003 → T004（序列；T003 涉 auth.ts 獨立檔、T004 涉 route.ts + index.ts。技術上 T003 / T004 可順序顛倒，但建議 T003 先（單檔簡單刪除）— 與 quickstart §A.1 順序一致）。

### Polish 內

- T005 build verify（依 T002+T003+T004 全部 inner commits 完成）
- T006 inner push（依 T005 PASS）
- T007 outer SHA pin commit（依 T006 push 後）
- T008 static acceptance evidence + commit（依 T007 outer commit）
- T009 push outer（依 user 同意）
- T010 CHECKLIST sync（獨立可隨時做，建議 T008 後）

### Parallel Opportunities

- **無 [P] 機會**：本 feature 全 task 序列依賴（§V 兩段式紀律 + pnpm 序列驗證）。
- 唯一可考慮：T002（US1 GAP-4）與 T003+T004（US2 GAP-2/GAP-3）user-story 維度上**獨立**，技術上可平行做（T002 動 route.ts line 10，T003 動 auth.ts，T004 動 route.ts line 13-20 + index.ts；T002 與 T004 都動 route.ts 但不同 region）。實務上單 implementer 序列做最 clean。

---

## Implementation Strategy

### MVP First（US1 P1 only）

US1 GAP-4 即 MVP — T001 + T002 = 主交付：

1. T001 健檢 worktree
2. T002 inner: GAP-4 path rename（1 line + typecheck + commit）
3. 此時 admin-web fetchGetUserRoutes 對齊 admin-api ✅，dashboard 在 dynamic / static mode 都能進

預估時間：5-10 分鐘。

### Incremental Delivery

4. T003 inner: GAP-2 dead code 刪除（auth.ts + typecheck + commit）
5. T004 inner: GAP-3 dynamic-mode 改寫（route.ts + index.ts + typecheck + commit）
6. T005 build verify: pnpm typecheck + lint + build 全 PASS
7. T006 inner push: cd admin-web && git push origin new-admin-base-web
8. T007 outer SHA pin commit
9. T008 static acceptance + evidence commit
10. 此時可 push outer（T009）+ open PR / FF merge（user 同意後）+ T010 CHECKLIST 同步

預估全套時間：30-45 分鐘（含 pnpm install/build cache、3 個 inner commits 各 typecheck）。

### Follow-up（feature 6 merge 後）

11. T011 dynamic acceptance（admin-web dev + admin-api docker → browser smoke）

---

## Notes

- §V 兩段式 NON-NEGOTIABLE：T006 inner push fork 與 T007 outer SHA pin commit 兩段紀律不可省略。
- T002 wording 含 commit message 範本，implementer 直接從 quickstart §A.1 inner commit 3 copy。
- T003 / T004 涉 2 個檔（route.ts 被 T004 動，但只動 line 13-20 region — 與 T002 動 line 10 region 互不干擾）。
- T008 evidence file 格式參考 feature 3 `specs/003-.../acceptance-evidence/T007-static.md` 或 feature 4 T008。
- 本 feature 是**第二個動 admin-web submodule** 的 feature（feature 2 為第一次）— T001-T008 重用 feature 2 心智模型，差異僅在改動範圍（feature 5 較廣，3 個 inner commits 而非 2 個）。
- 動態 acceptance（T011）跨 feature 依賴 → 標 follow-up、不阻塞主 PR merge。
- pnpm install 首次可能慢（~2-5 分鐘），typecheck / build 通常 < 30s。
