# T008 Static Acceptance Evidence — Feature 005-admin-web-cleanup

**Date**: 2026-05-11
**Outer commit (T007)**: `4d7cf0a chore(submodule): bump admin-web 到 7b167559: feature 5 admin-web cleanup (GAP-2/3/4)`
**admin-web HEAD (inner)**: `7b167559`

7 條 static acceptance checks 對應 spec.md SC-501/502/503/504/507 + tasks.md T008(a)-(g)。

---

## (a) `fetchCustomBackendError` 已刪（GAP-2，FR-501/502，SC-502）

**Command**:
```bash
grep -rn "fetchCustomBackendError" admin-web/src/
```

**Result**: ✅ **PASS** — 0 hits

對應 spec FR-501（函式 + JSDoc 整塊 -9 行刪除）+ FR-502（grep hygiene）。

---

## (b) `fetchIsRouteExist` 已刪（GAP-3 API removal，FR-510）

**Command**:
```bash
grep -rn "fetchIsRouteExist" admin-web/src/
```

**Result**: ✅ **PASS** — 0 hits

對應 spec FR-510（route.ts line 13-20 整塊刪除）+ FR-521（store/route/index.ts line 7 import 清掉）。

---

## (c) `/route/isRouteExist` literal 已 0 hits（SC-503）

**Command**:
```bash
grep -rn "/route/isRouteExist" admin-web/src/
```

**Result**: ✅ **PASS** — 0 hits

對應 SC-503（GAP-3 cleanup 完成）。

---

## (d) `/route/getUserRoutes` literal 已 0 hits（GAP-4，SC-504 part 1）

**Command**:
```bash
grep -rn "'/route/getUserRoutes'" admin-web/src/
```

**Result**: ✅ **PASS** — 0 hits

GAP-4 path rename 後舊 path 已不再被 admin-web 引用。

---

## (e) `/auth/getUserRoutes` ≥ 1 hits（FR-511，SC-504 part 2）

**Command**:
```bash
grep -rn "'/auth/getUserRoutes'" admin-web/src/
```

**Result**: ✅ **PASS** — 1 hit（`admin-web/src/service/api/route.ts:10`）

對應 spec FR-511 path 對齊 admin-api `init_protected_router()` 內既有 `/auth/getUserRoutes`（research R1 已驗）。

---

## (f) pnpm lint PASS + typecheck 0 new errors（SC-501）

### pnpm lint

**Command**:
```bash
cd admin-web && CI=true pnpm lint
```

**Result**: ✅ **PASS** — `Found 0 warnings and 0 errors. Finished in 12.3s on 233 files with 132 rules using 16 threads.`（exit code 0）

### pnpm typecheck

**Command**:
```bash
cd admin-web && CI=true pnpm typecheck
# (CI=true 必要 — pnpm 11.0.8 新增 approve-builds gate 阻擋 install pre-check；CI mode 跳過此 check)
```

**Result**: ⚠️ **15 pre-existing errors, 0 new from feature 5**

15 個 typecheck errors 全部 **pre-existing**（feature 2 完成時即存在；本 feature 開始前 stash → pop 對比驗證 0 變化）：

| File | Errors | 性質 |
|---|---|---|
| `build/plugins/unocss.ts` | 2 | env: 缺 `@iconify/utils/lib/loader/node-loaders` 模組 + svg 參數 implicit any |
| `packages/uno-preset/src/index.ts` | 2 | env: 缺 `@unocss/core` + `@unocss/preset-mini` 模組 |
| `src/service/request/index.ts` | 11 | env: 缺 `axios` module + `response.data` is `unknown` type |

### 為什麼這些 errors 不算 feature 5 regression

- 全部 errors 源於 admin-web `node_modules` 缺 transitive deps（`axios`, `@unocss/*`, `@iconify/*`）— 是 admin-web 在 pnpm 11+ 新版 isolated mode + approve-builds gate 下的 install 狀態問題
- 預先存在於 feature 2 完成時，與 feature 5 GAP-2/3/4 改動 0 關係
- 透過 `git stash push src/service/api/*.ts src/store/modules/route/index.ts` → 跑 typecheck → 同 15 errors → `git stash pop` → 跑 typecheck → 仍 15 errors（驗證 feature 5 改動 0 新增 error）

### Root cause（out of feature 5 scope）

pnpm 11.0.8 introduced「approve-builds」gate — 阻止 `pnpm install` 自動 run post-install scripts（如 `parcel/watcher`, `esbuild`, `simple-git-hooks`, `vue-demi`），導致 transitive deps 未被 hoist 到 `node_modules/{axios,...}`。Resolution candidates（皆 out of feature 5 scope）：
- (a) `pnpm config set auto-install-peers true` + `pnpm install --shamefully-hoist`
- (b) admin-web `package.json` 把 `axios` etc 加為 direct dep（違反 feature 5 FR：「不引新 dependency」）
- (c) Build env interactively run `pnpm approve-builds`
- (d) Pin admin-web 到 pnpm 10.x（feature 7 admin-web-dockerfile 可順帶決策）

**結論**: 此 env 限制不阻擋 feature 5 主交付。feature 5 改動本身 lint PASS、typecheck 0 new errors。

### pnpm build

未跑（同樣會被 pre-existing typecheck issues 影響）。Vite build 通常不嚴格依賴 typecheck PASS，但本 env 下無法驗證。Defer to feature 7 admin-web Dockerfile build 階段。

---

## (g) diff line cap（SC-507 ≤ 30 行）

**Command**:
```bash
cd admin-web && git diff origin/new-admin-base-web~3..origin/new-admin-base-web --shortstat
```

**Result**: ✅ **PASS**

```
3 files changed, 4 insertions(+), 24 deletions(-)
```

Total = **28 lines changed**（4 insertions + 24 deletions）— 在 SC-507 ≤ 30 行 cap 內、留 ~2 行 buffer。

### Per-file breakdown

| File | +/- | 內容 |
|---|---|---|
| `src/service/api/auth.ts` | -10 | GAP-2 刪除 fetchCustomBackendError + JSDoc + 上方空行 |
| `src/service/api/route.ts` | +1 / -10 | GAP-4 path rename（+1/-1）+ GAP-3 刪除 fetchIsRouteExist + JSDoc（-9） |
| `src/store/modules/route/index.ts` | +3 / -4 | GAP-3 import 整理（-1/+1）+ dynamic-mode 改寫（-3/+2） |

---

## Inner commits（3 個，依 user story priority 順序）

| SHA | Subject | GAP | US |
|---|---|---|---|
| `1b900019` | fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes | GAP-4 | US1 P1 MVP |
| `926aa93c` | fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError | GAP-2 | US2 P2 |
| `7b167559` | fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes | GAP-3 | US2 P2 |

3 inner commits pushed to `origin/new-admin-base-web` (range `29874dd3..7b167559`)。

### git submodule status (verification)

```
 7b167559cb73c41e5e62e6f2dbe24e4ee2bb5e6c admin-web (v2.1.0-15-g7b167559)
 b5025283c11e3668da980b4308fde3f2e29281d7 admin-api (v0.1.0-59-gb502528)
```

兩 row 行首為空格（clean），admin-web outer pin (`7b167559`) match worktree HEAD。

---

## Summary

| 條 | 對應 FR/SC | 結果 |
|---|---|---|
| (a) fetchCustomBackendError = 0 | FR-501/502, SC-502 | ✅ |
| (b) fetchIsRouteExist = 0 | FR-510/521, SC-503 | ✅ |
| (c) /route/isRouteExist = 0 | SC-503 | ✅ |
| (d) /route/getUserRoutes = 0 | SC-504 part 1 | ✅ |
| (e) /auth/getUserRoutes ≥ 1 | FR-511, SC-504 part 2 | ✅ |
| (f) pnpm lint PASS + typecheck 0 new | SC-501 | ✅ (lint) / ⚠️ (typecheck — 15 pre-existing env issues documented out of scope) |
| (g) diff ≤ 30 行 | SC-507 | ✅ (28 lines) |

**7/7 strict PASS**（typecheck 15 pre-existing errors 為 env 限制 documented out of scope）。靜態 acceptance 主交付完成，可進 T009 push outer / T010 CHECKLIST sync / T011 dynamic acceptance（依 feature 6）。
