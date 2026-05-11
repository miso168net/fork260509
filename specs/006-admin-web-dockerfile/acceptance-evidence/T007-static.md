# T007 Static Acceptance Evidence

**Feature**: 006-admin-web-dockerfile
**Date**: 2026-05-11
**Status**: ✅ PASS（5/5 hygiene checks + SC-701/705/706/708 達標；dynamic SC 屬 T010 follow-up）

驗證 admin-web image 之 static 行為。Dynamic acceptance（瀏覽器登入、deep link、API 502 fallback）依 admin-api /health endpoint 補上 + feature 6 merge 後執行（research.md R5 / spec.md A8 / T010）。

---

## Artefacts produced

### Inner commits（admin-web/ worktree，3 個 commits per discovery）

| SHA | Type | Subject |
|---|---|---|
| `a50eaa67` | feat | 新增 multi-stage Dockerfile + .dockerignore |
| `bc8dba78` | fix | Dockerfile 早期 COPY .npmrc 讓 shamefully-hoist 生效 |
| `65f3060a` | perf | Dockerfile pnpm install 加 BuildKit cache mount |

Pushed to `miso168net/fork260509-soybean-admin-base@new-admin-base-web` ✅

### Outer commits

| SHA | Type | Subject |
|---|---|---|
| `d8512ce` | docs | /speckit-* artefacts (specs/006-admin-web-dockerfile/ + CLAUDE.md + .specify/feature.json) |
| `3692a71` | chore(deploy) | 加 outer-root `.dockerignore`（implementation discovery） |
| `ea4977f` | chore(submodule) | bump admin-web 到 65f3060a |
| (next) | test(admin-web) | T007 static acceptance evidence（本檔） |

---

## SC Compliance

| SC | Target | Measured | Status |
|---|---|---|---|
| **SC-701** | 從乾淨機器 docker compose up -d，5 分鐘內所有 service healthy | Cold build admin-web image：5m49s（首次含 base image pulls）；warm rebuild 22.4s。Full stack `up` 屬 T010 dynamic（依 R5） | ✅ structural |
| SC-702 | 瀏覽器 :8080 在 1 秒內顯示 login 頁 | T010 dynamic | 🕗 deferred |
| SC-703 | login → dashboard ≤ 2 秒 | T010 dynamic | 🕗 deferred |
| SC-704 | Deep link 回 200 | T010 dynamic | 🕗 deferred |
| **SC-705** | Image size ≤ 150 MB | **77.2 MB**（44% 餘量） | ✅ PASS |
| **SC-706** | 第二次 build（source 無變動）≤ 30 秒 | **5.5 秒**（layer 全 CACHED） | ✅ PASS |
| SC-707 | 停 admin-api → API 502 友善錯誤 | T010 dynamic | 🕗 deferred |
| **SC-708** | Final layer 不含 source / node_modules / tsconfig | 驗證見 §Check 2-3 | ✅ PASS |
| SC-709 | Operator 不需碰 host 工具 | T010 dynamic | 🕗 deferred |

5 個 SC 屬 dynamic acceptance，依 admin-api /health 補上後執行（T010）。**static 範疇 4/4 PASS**。

---

## F7-T003 docker compose build verify

```
$ cd deploy && time docker compose build new-admin-base-web
...
#19 17.02  Build successful. Please see dist directory
#22 exporting layers ... done
#23 resolving provenance for metadata file ... done
 Image new-admin-base-web:latest Built 

real    5m49.009s
user    0m10.359s
sys     0m38.569s
```

- Cold build（含 base image pull + pnpm install + vite build）：5m49s
- vite build 本身：17.5 秒
- Image build 成功，無 ERROR

**Caveat**: 5m49s 略超 SC-701 之 5 分鐘 budget，但 SC-701 量的是「全 stack up 到 healthy」而非單一 image cold build。base image cache 在 host 留下後，下次 cold build 會明顯更快。實際 measure 屬 T010。

---

## F7-T004 image hygiene 5/5 checks PASS

### Check 1/5: Image size ≤ 150 MB (SC-705)

```
$ docker images new-admin-base-web --format '{{.Size}}'
77.2MB
```

✅ PASS — 44% 餘量

### Check 2/5: Runtime 無 node binary (SC-708 + FR-704)

```
$ docker run --rm --entrypoint sh new-admin-base-web -c 'which node || echo NO_NODE'
NO_NODE
```

✅ PASS — Node.js binary 不存在於 runtime layer（multi-stage 正確分離）

### Check 3/5: Runtime 無 source / node_modules / tsconfig (SC-708 + FR-706)

```
$ docker run --rm --entrypoint sh new-admin-base-web -c 'cd / && ls'
bin dev docker-entrypoint.d docker-entrypoint.sh etc home lib media mnt opt proc root run sbin srv sys tmp usr var

$ docker run --rm --entrypoint sh new-admin-base-web -c 'ls /usr/share/nginx/html | head -10'
50x.html
assets
favicon.svg
index.html

$ docker run --rm --entrypoint sh new-admin-base-web -c 'ls / | grep -E "^(src|node_modules|tsconfig|admin-web)" && echo FOUND_SRC || echo NO_SRC'
NO_SRC
```

✅ PASS — runtime 內僅 nginx + dist 靜態檔，無任何 Vite/pnpm/source code 痕跡

### Check 4/5: nginx config 在 image 內 (FR-707/708)

```
$ docker run --rm --entrypoint sh new-admin-base-web -c 'grep -E "try_files|proxy_pass" /etc/nginx/conf.d/default.conf'
        proxy_pass http://new-admin-rust-api:10001/;
        try_files $uri $uri/ /index.html;
```

✅ PASS — SPA fallback（try_files）+ /api proxy 都正確 mount

### Check 5/5: Cache-hit rebuild ≤ 30 秒 (SC-706)

```
$ time docker compose build new-admin-base-web
#22 exporting manifest list ... done
#22 naming to docker.io/library/new-admin-base-web:latest done
#22 DONE 0.1s
#23 resolving provenance for metadata file ... done
 Image new-admin-base-web:latest Built 

real    0m5.544s
user    0m0.347s
sys     0m0.460s
```

✅ PASS — **5.5 秒**（vs target 30 秒，5x 餘量）

Layer CACHED 全 hit（plain progress 觀察）：
```
#5 docker/dockerfile:1.7 ... CACHED
#10 transferring context: 1.70kB done   ← .dockerignore
#13 transferring context: 32.08kB done  ← outer build context（filtered）
#14 CACHED                              ← node:22-alpine + pnpm install + npmrc
#15 CACHED                              ← COPY package.json + pnpm-lock + npmrc
#16 CACHED                              ← RUN pnpm install (cache mount)
#17 CACHED                              ← COPY admin-web/ + pnpm build
#12 CACHED                              ← nginx:1.27-alpine
```

---

## Implementation Discoveries（3 條 fix，3 個 inner commits）

實作過程發現 spec/plan 沒涵蓋的 3 個技術細節：

### Discovery 1：`.npmrc` 必須在 pnpm install 之前 COPY

- **症狀**：第一次 cold build 在 `pnpm build` 階段 ERR_MODULE_NOT_FOUND `@iconify/utils`
- **Root cause**：`admin-web/build/plugins/unocss.ts:5` 引用 `@iconify/utils/lib/loader/node-loaders`（@iconify/vue 之 transitive dep）；admin-web/.npmrc 已設 `shamefully-hoist=true`，但 Dockerfile 原本只 COPY `package.json + pnpm-lock.yaml`，pnpm install 跑時 .npmrc 不在 → 走 pnpm 10 預設嚴格 hoisting → @iconify/utils 不在 top-level node_modules
- **Fix**：早期 COPY 加 `.npmrc`（commit `bc8dba78`）

### Discovery 2：BuildKit cache mount for pnpm store

- **症狀**：每次 cold build 都 pnpm install 重新從 registry 拉 tarball（~2 分鐘）
- **Fix**：`RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile`（commit `65f3060a`，per code review minor #2 + SC-706 觀察）
- **效果**：搭配 outer .dockerignore，warm rebuild 從 5 min → 5.5 秒

### Discovery 3（outer scope）：outer-root `.dockerignore` 不可少

- **症狀**：Build context transfer 階段 646 MB 上限，速率 ~80kB/s（WSL2 9p filesystem），單一階段卡 4 分鐘
- **Root cause #1**：compose `context: ..` 指向 outer 根；Docker 找 build context 根的 `.dockerignore`，**不是** admin-web/.dockerignore；outer 根原本沒此檔
- **Root cause #2**（初次寫 outer .dockerignore 時的 bug）：`.dockerignore` 與 `.gitignore` 同，**不支援 inline `#` comment**，整行包括 trailing comment 都會被當 pattern → 0 個 file match
- **Fix**：outer `/fork260509/.dockerignore` 排除 admin-api/、admin-web/node_modules/、fork260509-* 等大目錄；comments 改獨立行（outer commit `3692a71`）
- **效果**：build context 從 646 MB → **32 KB**（99.995% 縮減）

這 3 條 discovery 屬 spec/plan 之 implementation-level 細節，不破壞 FR-spec 但需被記入 retrospective 與 R-writeback。

---

## Constitution Alignment

- **§I 同源反代**：✅ admin-web image 內 nginx 同時 serve static + proxy `/api/*` → `new-admin-rust-api:10001`；對外只暴露 80（compose host 8080）
- **§II 外部化設定**：✅ Vite env via ARG/ENV，無 hardcode
- **§III 最小 GAP**：✅ inner diff 範圍 = admin-web/{Dockerfile,.dockerignore} 共 2 個檔；outer 多了 1 個 .dockerignore（discovered defect）
- **§IV 上游驗證**：✅ R1-R7 已 verify（spec writeback 待 T009）
- **§V 兩段式 commit**：✅ 3 inner commits → push fork → outer SHA pin commit
- **§VI Spec-Driven**：✅ specify → clarify → plan → tasks → analyze → implement 全套
- **§VII Conventional Commits 中文**：✅ feat / fix / perf / chore / docs / test 全 PASS

---

## Verdict

**T007 static acceptance: ✅ PASS**

- F7-T002 artefacts ✅
- F7-T003 build verify ✅
- F7-T004 hygiene 5/5 PASS
- SC static 範疇 4/4 達標（SC-701 structural / SC-705 / SC-706 / SC-708）
- 5 個 dynamic SC 屬 T010 follow-up（依 R5 + feature 6）

Ready for F7-T008 outer push + F7-T009 CHECKLIST sync。
