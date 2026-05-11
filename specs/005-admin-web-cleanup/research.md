# Phase 0 Research: admin-web-cleanup

**Feature**: 005-admin-web-cleanup
**Date**: 2026-05-11
**Status**: Completed

把 spec.md「待驗證的上游慣例」4 項 + §V 兩段式 commit 流程具現化全部解析。所有 R# 都已透過 read 既有 admin-web / admin-api source 完成 — implementation 階段不需要再額外探勘。

---

## R1: admin-api 是否真有 `/auth/getUserRoutes` endpoint（GAP-4 修補對齊的目標）

- **Decision**: ✅ **CONFIRMED** — `/auth/getUserRoutes` 存在於 admin-api，且**還有第二個 alias** `/authorization/getUserRoutes`
- **Rationale**: read `admin-api/server/router/src/admin/sys_authentication_route.rs`：
  - Line 25（`init_protected_router`）：`.route("/getUserRoutes", get(SysAuthenticationApi::get_user_routes))`，nest 在 `/auth` 下 → 完整 URL = `/auth/getUserRoutes`
  - Line 54（`init_authorization_router`）：`.route("/getUserRoutes", get(SysAuthenticationApi::get_user_routes))`，nest 在 `/authorization` 下 → 完整 URL = `/authorization/getUserRoutes`
- **Implementer note**: 採 `/auth/getUserRoutes`（與 INTEGRATION-PLAN §4 GAP-4 推薦一致；`/authorization` alias 是上游多餘的 dual-mount，admin-web 不需切過去）

---

## R2: admin-api 是否有 `/route/getConstantRoutes` endpoint（與 admin-web `fetchGetConstantRoutes` 對齊）

- **Decision**: ✅ **CONFIRMED** — `/route/getConstantRoutes` 存在於 admin-api
- **Rationale**: read `admin-api/server/router/src/admin/sys_menu_route.rs:15`：
  ```rust
  .route("/getConstantRoutes", ...)
  ```
  nest 在 `/route` 下（per file naming `sys_menu_route` + 既有 admin-api router 慣例）→ 完整 URL = `/route/getConstantRoutes`
- **結論**: admin-web `fetchGetConstantRoutes` 打 `/route/getConstantRoutes` **正確對齊 admin-api**；**無 GAP-4b 需求**
- **Alternatives considered**: 若 admin-api 把 constantRoutes 也移到 `/auth/`（如某些 admin tool 風格），需要 admin-web 端也對齊；但目前不是這個情況、無需動

---

## R3: admin-web routeStore 內 user routes cached ref 名稱（FR-520 占位 `<local-cached-user-routes>` 的對應）

- **Decision**: ref 名為 **`authRoutes`**（`shallowRef<ElegantConstRoute[]>`）
- **Rationale**: read `admin-web/src/store/modules/route/index.ts:67`：
  ```ts
  /** auth routes */
  const authRoutes = shallowRef<ElegantConstRoute[]>([]);

  function addAuthRoutes(routes: ElegantConstRoute[]) {
    const authRoutesMap = new Map<string, ElegantConstRoute>([]);
    routes.forEach(route => {
      authRoutesMap.set(route.name, route);
    });
    authRoutes.value = Array.from(authRoutesMap.values());
  }
  ```
  - `authRoutes` 是 module-level `shallowRef`
  - `addAuthRoutes(routes)` 在 `fetchGetUserRoutes` 成功後被呼叫，將 user routes 寫入 `authRoutes.value`
  - 既有 dynamic-mode → fetch → addAuthRoutes 流程已 wire-up；GAP-3 新邏輯直接讀 `authRoutes.value`
- **Implementer note**: dynamic-mode 替換片段：
  ```ts
  // Before (line 306-308):
  const { data } = await fetchIsRouteExist(routeName);
  return data;

  // After:
  return isRouteExistByRouteName(routeName, authRoutes.value);
  ```
  注意：函式 signature 仍是 `async`（caller in `router/guard/route.ts:139` 用 `await`），return type 仍 `Promise<boolean>`；只是新實作沒有 await DB 操作，但保持 async 介面以維持 caller 相容。

---

## R4: admin-web `router/guard/route.ts:139` caller invariant — `getIsAuthRouteExist` 被呼叫時 `authRoutes.value` 是否已 populated

- **Decision**: 正常 flow 下 ✅ already populated；edge case（首次直接 navigate 到 not-found URL 且未經 login → fetchUserRoutes）回 `false` 是 acceptable fallback
- **Rationale**: read `admin-web/src/router/guard/route.ts:125-145`：
  ```ts
  routeStore.onRouteSwitchWhenLoggedIn();

  // the auth route is initialized
  // it is not the "not-found" route, then it is allowed to access
  if (!isNotFoundRoute) {
    return null;
  }

  // it is captured by the "not-found" route, then check whether the route exists
  const exist = await routeStore.getIsAuthRouteExist(to.path as RoutePath);
  ```
  Pre-conditions on call site:
  1. `routeStore.onRouteSwitchWhenLoggedIn()` 已執行 — 表示 user 已 logged-in 狀態（pre-check by 上游 guard）
  2. `isNotFoundRoute === true` — 表示 vue-router 沒匹配到任何 registered route
  3. Logged-in user 走過 login flow 已 trigger `fetchGetUserRoutes` → `addAuthRoutes(routes)` → `authRoutes.value` populated

- **Edge case**: 若用戶在 logged-in 狀態下 manual reload 一個 not-found URL，admin-web 可能尚未重 fetch user routes 而直接 trigger guard：
  - 若 router init 流程已重 fetch（既有 admin-web flow） → `authRoutes.value` 已 populated → 正常工作
  - 若 not yet fetched（罕見 race） → `authRoutes.value === []` → `isRouteExistByRouteName(routeName, [])` 回 `false` → guard 認為「route 不存在」→ fall back not-found 頁面（與 spec edge case「保守處理」一致）
- **Alternatives considered**:
  - 在 `getIsAuthRouteExist` 內加 `if (!authRoutes.value.length) await fetchGetUserRoutes()` 強制保證 freshness — 拒絕：複雜度上升、可能引入 race；spec 接受保守 fallback
- **Implementer note**: 不在 `getIsAuthRouteExist` 內加 fetch trigger；維持函式單純查 cache 即可

---

## R5: §V 兩段式 commit 流程（admin-web 視角，feature 5 版）

- **Decision**: 重用 feature 2 模式、target submodule 同樣是 admin-web
- **流程**：

**第一段（admin-web/ worktree 內，分 3 個 inner commits — 按 user story priority 順序：US1 P1 GAP-4 先；US2 P2 GAP-2/GAP-3 後）**：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web
git status              # 確認 branch = new-admin-base-web、無 untracked 雜訊
```

```bash
# inner commit 1 (US1 P1): GAP-4 path rename — MVP
git add src/service/api/route.ts
git commit -m "fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes"
```

```bash
# inner commit 2 (US2 P2): GAP-2 刪 fetchCustomBackendError
git add src/service/api/auth.ts
git commit -m "fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError"
```

```bash
# inner commit 3 (US2 P2): GAP-3 刪 fetchIsRouteExist + dynamic-mode 改本地查
git add src/service/api/route.ts \
        src/store/modules/route/index.ts
git commit -m "$(cat <<'EOF'
fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes

- 刪 src/service/api/route.ts::fetchIsRouteExist（admin-api 無此 endpoint）
- 改 src/store/modules/route/index.ts::getIsAuthRouteExist dynamic-mode 路徑
  由 fetchIsRouteExist API call → 本地查 isRouteExistByRouteName(name, authRoutes.value)
- 整理 import（刪 fetchIsRouteExist 從 @/service/api）
EOF
)"
```

```bash
# Note: inner commit 1 + 3 都動 route.ts，但動不同 region（commit 1 line 10 path；
# commit 3 line 13-20 區塊刪除）— 無 conflict。

git push origin new-admin-base-web
```

**第二段（外層 new-admin-root）**：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer worktree root
git status                                   # 應看到 "modified content" 在 admin-web
git add admin-web
git commit -m "$(cat <<'EOF'
chore(submodule): bump admin-web 到 <短SHA>: feature 5 admin-web cleanup (GAP-2/3/4)

3 個 inner commits：
- <SHA1> fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError
- <SHA2> fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes
- <SHA3> fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes

完成 admin-web 對 admin-api 既有 endpoints 的最後對齊。動態驗證依 feature 6 docker
stack merge 後跑 follow-up。
EOF
)"
```

**outer push 待使用者授權**（依 CLAUDE.md §5 全域規則）。

---

## 結論：所有 spec assumptions 已具現化

4 條「待驗證的上游慣例」全部解析完成（R1-R4）：
- R1 ✅ `/auth/getUserRoutes` 確認、GAP-4 對齊有效
- R2 ✅ `/route/getConstantRoutes` 確認、**無 GAP-4b 需求**（scope 不擴）
- R3 ✅ routeStore ref 名 `authRoutes`、GAP-3 dynamic-mode 替換片段定案
- R4 ✅ caller invariant 確認、edge case fallback 行為 acceptable

R5 §V 兩段式 commit 流程藍本完整。implementation 階段不需要再做額外 code 探勘 — tasks.md 可直接落地。
