# Quickstart: admin-web-cleanup

**Feature**: 005-admin-web-cleanup
**Audience**: TypeScript frontend implementer（admin-web 倉）+ operator / QA（dynamic smoke，依 feature 6 merge）

兩部分：implementer 走兩段式 submodule commit 完成 feature；operator 跑 admin-web wire-level smoke 驗收。

---

## Part A — Implementer Quickstart

### A.0 Pre-flight 健檢

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git status                    # 應在 outer branch 005-admin-web-cleanup，clean
git submodule status          # admin-web 行首應為空格（clean），SHA = 29874dd3

cd admin-web
git status -sb                # 應在 inner branch new-admin-base-web
git log --oneline -3          # 確認 feature 2 已合進來（最新 SHA 29874dd3）
```

若任一檢查失敗 → 參照 CLAUDE.md §9 重建 worktree / 對齊 pin。

確認 admin-web pnpm 環境 ready：
```bash
cd admin-web
pnpm --version    # 應 >= 10.5
pnpm install      # 若 node_modules 未 install
```

---

### A.1 改動順序（對應 3 個 inner commits — 按 user story priority：US1 P1 GAP-4 → US2 P2 GAP-2 → US2 P2 GAP-3）

#### Inner commit 1 (US1 P1)：GAP-4 fetchGetUserRoutes path rename — MVP

**改 `admin-web/src/service/api/route.ts`**：line 10 path：

```diff
-  return request<Api.Route.UserRoute>({ url: '/route/getUserRoutes' });
+  return request<Api.Route.UserRoute>({ url: '/auth/getUserRoutes' });
```

**驗**：
```bash
cd admin-web
pnpm typecheck   # 必 PASS
grep -rn "'/route/getUserRoutes'" src/   # 應 0 hits
grep -rn "'/auth/getUserRoutes'" src/    # 應 ≥ 1 hit (just-changed line)
```

**inner commit 1**：
```bash
git add src/service/api/route.ts
git commit -m "fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes

對齊 admin-api init_protected_router 內既有 /auth/getUserRoutes 註冊。"
```

---

#### Inner commit 2 (US2 P2)：GAP-2 刪 fetchCustomBackendError

**改 `admin-web/src/service/api/auth.ts`**：刪除 line 40-48 整塊（含 JSDoc 註解 + 函式）：

```diff
-
-/**
- * return custom backend error
- *
- * @param code error code
- * @param msg error message
- */
-export function fetchCustomBackendError(code: string, msg: string) {
-  return request({ url: '/auth/error', params: { code, msg } });
-}
```

最終檔尾應在 `fetchRefreshToken` 函式結束處（line 38）。

**驗**：
```bash
cd admin-web
pnpm typecheck   # 必 PASS
grep -rn "fetchCustomBackendError" src/   # 應 0 hits
```

**inner commit 2**：
```bash
git add src/service/api/auth.ts
git commit -m "fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError

admin-api 無 /auth/error endpoint；函式在 src/ 內 0 callers，純 dead code。"
```

---

#### Inner commit 3 (US2 P2)：GAP-3 刪 fetchIsRouteExist + dynamic-mode 改本地查

**改 `admin-web/src/service/api/route.ts`**：刪除 line 13-20 整塊（含 JSDoc + 函式）。注意：line 10 已在 inner commit 1 改過 path，此 commit 動 line 13-20 region 不影響 line 10：

```diff
-
-/**
- * whether the route is exist
- *
- * @param routeName route name
- */
-export function fetchIsRouteExist(routeName: string) {
-  return request<boolean>({ url: '/route/isRouteExist', params: { routeName } });
-}
```

最終 route.ts 含 2 個函式：`fetchGetConstantRoutes` + `fetchGetUserRoutes`（後者 path 已是 `/auth/getUserRoutes` 自 inner commit 1）。

**改 `admin-web/src/store/modules/route/index.ts`**：

(a) line 7 import 整理 — 刪 `fetchIsRouteExist`：
```diff
-import { fetchGetConstantRoutes, fetchGetUserRoutes, fetchIsRouteExist } from '@/service/api';
+import { fetchGetConstantRoutes, fetchGetUserRoutes } from '@/service/api';
```

(b) line 306-308 dynamic-mode 路徑改寫：
```diff
   if (authRouteMode.value === 'static') {
     const { authRoutes: staticAuthRoutes } = createStaticRoutes();
     return isRouteExistByRouteName(routeName, staticAuthRoutes);
   }

-  const { data } = await fetchIsRouteExist(routeName);
-
-  return data;
+  // dynamic-mode：從本地 cached authRoutes 查（既有 shallowRef，由 addAuthRoutes() 在 fetchGetUserRoutes 後 populate）
+  return isRouteExistByRouteName(routeName, authRoutes.value);
```

**驗**：
```bash
cd admin-web
pnpm typecheck   # 必 PASS
grep -rn "fetchIsRouteExist\|/route/isRouteExist" src/   # 應 0 hits
```

**inner commit 3**：
```bash
git add src/service/api/route.ts \
        src/store/modules/route/index.ts
git commit -m "fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes

- 刪 src/service/api/route.ts::fetchIsRouteExist（admin-api 無此 endpoint）
- 改 src/store/modules/route/index.ts::getIsAuthRouteExist dynamic-mode 路徑
  由 fetchIsRouteExist API call → 本地查 isRouteExistByRouteName(name, authRoutes.value)
- 整理 import（刪 fetchIsRouteExist from @/service/api）

static-mode 路徑保留不動（FR-535 既有 user 體驗無變化）。"
```

---

### A.2 整套 build verify

```bash
cd admin-web
pnpm typecheck   # 必 PASS
pnpm lint        # 必 PASS
pnpm build       # production build，必 PASS（vite 產出 dist/）
```

對應 SC-501。

### A.3 inner push

```bash
cd admin-web
git push origin new-admin-base-web
# 應成功推到 miso168net/fork260509-soybean-admin
```

### A.4 outer commit（第二段）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer
git status
# 應看到：
#   modified content: admin-web (new commits)

SHORT_SHA=$(cd admin-web && git rev-parse --short HEAD)
git add admin-web

git commit -m "$(cat <<EOF
chore(submodule): bump admin-web 到 $SHORT_SHA: feature 5 admin-web cleanup (GAP-2/3/4)

3 個 inner commits（admin-web/ worktree，依 user story priority 順序）：
- fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes  (US1 P1)
- fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError  (US2 P2)
- fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes  (US2 P2)

完成 admin-web 對 admin-api 既有 endpoints 最後對齊。動態驗證依 feature 6 docker
stack merge 後跑 follow-up。
EOF
)"
# **不**直接 git push — 依 CLAUDE.md §5 全域 push 確認規則，等使用者授權
```

---

## Part B — Operator Quickstart（動態 smoke）

依本機 admin-web `pnpm dev` + admin-api docker stack（feature 6 merge 後可行）or `cargo run`。

### B.1 環境變數

```bash
# admin-web vite dev server（host 端）
cd admin-web
pnpm dev
# 預設 :9527
```

admin-api 後端任一啟動方式（依 feature 6 状態）：
- feature 6 merged → `docker compose up new-admin-rust-api`
- feature 6 未 merged → 本機 `cd admin-api && cargo run`（與 feature 4 T009 同方式，APP_* env 覆蓋）

### B.2 happy path（GAP-4 path 對齊）

1. 開瀏覽器 → http://localhost:9527
2. 輸入 `Soybean / 123456` 點 login
3. DevTools Network → 觀察 login 後第 2 個 API request
4. **預期**：URL 是 `/proxy-default/auth/getUserRoutes`（vite proxy + GAP-4 後 path）
5. Response 200 + body 含 `data.routes` array + `data.home` string
6. UI 跳轉到首頁、左側 menu 顯示 user 角色對應 routes
   - Soybean = ROLE_SUPER = 完整 menu tree

### B.3 GAP-3 dynamic-mode runtime 測試

前置：在 admin-web `.env` 設 `VITE_AUTH_ROUTE_MODE=dynamic` 後 reload（若已是 dynamic 直接測）。

1. Login 完成（按 B.2 流程）
2. 在 URL bar 輸入一個不存在的路徑：`http://localhost:9527/non-existent-page`
3. DevTools Network 觀察
4. **預期**：
   - **沒有** `/route/isRouteExist` request 發出（0 個）
   - 沒有 `/auth/getUserRoutes` 重複 request（已 cached in authRoutes）
   - UI 跳轉到 not-found 頁面（404 / 403 對應 routeKey）

### B.4 GAP-2 dead code 確認

```bash
cd admin-web
grep -rn "fetchCustomBackendError" src/
# 應 0 hits
```

### B.5 dynamic-mode dashboard 完整測試

1. Login
2. 點不同 menu 進不同 page
3. 預期：所有 user-authorized routes 可正常 navigate；無 404 toast / console error

---

## 不在本 Quickstart 範圍

- admin-api 啟動 / envsubst（feature 6） → 屬 feature 6 quickstart
- admin-web Dockerfile（feature 7） → 屬 feature 7 quickstart
- admin-web E2E 自動化測試 → 屬 admin-web 倉自身 CI
- login error path dedupe（2-M4） → 獨立 follow-up
