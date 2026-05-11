# Phase 1 Data Model: admin-web-cleanup

**Feature**: 005-admin-web-cleanup
**Date**: 2026-05-11
**Status**: Completed

本檔列出 feature 5 涉及的所有 file / function / ref 變動。本 feature **不動** application data model（DB schema、API contract、TS interface 全部既有）— 純 service layer / store 邏輯整理。

---

## 1. File Entities（3 個檔修改）

### 1.1 `admin-web/src/service/api/auth.ts`（GAP-2）

**變動**：刪除 `fetchCustomBackendError` 函式（含 JSDoc）

**Before**（line 40-48）：
```ts
/**
 * return custom backend error
 *
 * @param code error code
 * @param msg error message
 */
export function fetchCustomBackendError(code: string, msg: string) {
  return request({ url: '/auth/error', params: { code, msg } });
}
```

**After**：整塊刪除（含上方空行，淨 -8 至 -9 行）

**理由**：
- 函式 dev-only（偽錯誤觸發器，admin-api 沒 `/auth/error` endpoint）
- grep `fetchCustomBackendError` 在 admin-web `src/` 內**僅 1 hit（定義自身）**— 0 callers
- 屬 dead code，刪除無 break

### 1.2 `admin-web/src/service/api/route.ts`（GAP-3 + GAP-4）

**變動 A**（GAP-4 path rename，line 10）：
```ts
// Before
return request<Api.Route.UserRoute>({ url: '/route/getUserRoutes' });

// After
return request<Api.Route.UserRoute>({ url: '/auth/getUserRoutes' });
```

**變動 B**（GAP-3 刪 fetchIsRouteExist，line 13-20）：
```ts
// Before
/**
 * whether the route is exist
 *
 * @param routeName route name
 */
export function fetchIsRouteExist(routeName: string) {
  return request<boolean>({ url: '/route/isRouteExist', params: { routeName } });
}
```

**After**：整塊刪除（淨 -8 行）

**最終檔內容**（預期）：
```ts
import { request } from '../request';

/** get constant routes */
export function fetchGetConstantRoutes() {
  return request<Api.Route.MenuRoute[]>({ url: '/route/getConstantRoutes' });
}

/** get user routes */
export function fetchGetUserRoutes() {
  return request<Api.Route.UserRoute>({ url: '/auth/getUserRoutes' });
}
```

**理由**：
- `fetchGetConstantRoutes` 不動（R2 verified admin-api `/route/getConstantRoutes` 存在）
- `fetchGetUserRoutes` URL 改對齊 admin-api `/auth/getUserRoutes`（R1 verified）
- `fetchIsRouteExist` 全刪（admin-api 無此 endpoint；GAP-3 後 admin-web 改本地查）

### 1.3 `admin-web/src/store/modules/route/index.ts`（GAP-3 dynamic-mode 改寫）

**變動 A**（line 7 import 整理）：
```ts
// Before
import { fetchGetConstantRoutes, fetchGetUserRoutes, fetchIsRouteExist } from '@/service/api';

// After
import { fetchGetConstantRoutes, fetchGetUserRoutes } from '@/service/api';
```

**變動 B**（line 294-309 `getIsAuthRouteExist` dynamic-mode 改寫）：
```ts
// Before（line 306-308 — dynamic mode）
const { data } = await fetchIsRouteExist(routeName);
return data;

// After
return isRouteExistByRouteName(routeName, authRoutes.value);
```

**完整 After 函式形態**（line 294-309 替換為 line 294-307）：
```ts
async function getIsAuthRouteExist(routePath: RouteMap[RouteKey]) {
  const routeName = getRouteName(routePath);

  if (!routeName) {
    return false;
  }

  if (authRouteMode.value === 'static') {
    const { authRoutes: staticAuthRoutes } = createStaticRoutes();
    return isRouteExistByRouteName(routeName, staticAuthRoutes);
  }

  // dynamic-mode：從本地 cached authRoutes 查（既有 shallowRef，由 addAuthRoutes() 在 fetchGetUserRoutes 後 populate）
  return isRouteExistByRouteName(routeName, authRoutes.value);
}
```

**理由**：
- 函式 signature 保留 `async` + return `Promise<boolean>`（caller in `router/guard/route.ts:139` 用 `await`，相容性必須保留）
- dynamic-mode 從 `authRoutes.value`（既有 ref，line 67）查
- static-mode 路徑（line 301-304）**完全不動**（FR-535）

---

## 2. Function / Ref Entities

### 2.1 `isRouteExistByRouteName` helper（既有，**不修改**）

**Location**: `admin-web/src/store/modules/route/shared.ts:173`

**Signature**:
```ts
export function isRouteExistByRouteName(routeName: RouteKey, routes: ElegantConstRoute[]) {
  // ... 既有實作
}
```

**Role**: 純函式，input(routeName, routes[]) → boolean。GAP-3 dynamic-mode 重用此 helper 對 `authRoutes.value` 查 — 與 static-mode 共用同一 helper。

### 2.2 `authRoutes` ref（既有，**不修改**）

**Location**: `admin-web/src/store/modules/route/index.ts:67`

**Definition**:
```ts
const authRoutes = shallowRef<ElegantConstRoute[]>([]);
```

**Populated by**: `addAuthRoutes(routes)`（line 69-77），在 `fetchGetUserRoutes` callback 內被呼叫

**GAP-3 新讀者**: `getIsAuthRouteExist`（dynamic-mode 分支）

### 2.3 `getRouteName` / `getRoutePath` helpers（既有，**不修改**）

**Location**: `admin-web/src/router/elegant/transform.ts`

**Role**: path ↔ name 轉換。`getIsAuthRouteExist` 既有用法保留不變（dynamic / static 兩個分支都先 `getRouteName(routePath)`）。

---

## 3. 不變更項

明列以避免誤動：

- `admin-web/src/router/guard/route.ts`（含 line 139 caller）— **不動**（函式 signature 相容、caller 介面不變）
- `admin-web/src/store/modules/route/shared.ts::isRouteExistByRouteName` — **不動**（helper 既有）
- `admin-web/src/store/modules/route/index.ts::addAuthRoutes` — **不動**（既有 populator）
- `admin-web/src/store/modules/route/index.ts::authRouteMode = 'static'` 分支 — **不動**（FR-535）
- admin-web `.env*` — **不動**（FR-532）
- admin-web `auth/index.ts` login error path — **不動**（FR-531，2-M4 follow-up）
- admin-web Dockerfile / vite config / package.json — **不動**（FR-533）
- admin-api 任何檔 — **不動**（FR-530）

---

## 4. 變動行數摘要（對齊 SC-507 ≤ 30 行）

| 檔 | +/- 行數 | 內容 |
|---|---|---|
| `src/service/api/auth.ts` | -8 | 刪 fetchCustomBackendError + JSDoc（含上方空行） |
| `src/service/api/route.ts` | -8 / +1 / -1 | 刪 fetchIsRouteExist + JSDoc；改 fetchGetUserRoutes path 1 行 |
| `src/store/modules/route/index.ts` | -1 / +1 / -2 / +1 | import 整理（刪 fetchIsRouteExist）；dynamic-mode 兩行替換為一行 |
| **總計** | **~ -18 / +3 ≈ 21 行 diff** | 在 SC-507 ≤ 30 行 cap 內、留 ~9 行 buffer |
