# 整合實施計畫：new-admin-root（new-admin-base-web worktree × new-admin-rust-api worktree、Docker Compose 編排）

> 日期：2026-05-10
> 來源：以 `INTEGRATION-RESEARCH.md` 為基礎，深入到實際 runtime 層級（Cargo.toml / Dockerfile / 各 entity / Res<T> / LoginInput / sys_tokens 表 / Casbin model / 預設 seed 資料）後產出
> 範圍：在 `fork260509-soybean-admin` 開分支 `new-admin-base-web` 並 worktree 到 `admin-web/`、在 `fork260509-soybean-admin-rust` 開分支 `new-admin-rust-api` 並 worktree 到 `admin-api/`，外層 `new-admin-root` 傘狀 repo 用 docker-compose 整合運行環境

## 命名約定（重要 — 整篇文件以此為準）

| 名稱 | 是什麼 | 對應目錄 | git remote |
|---|---|---|---|
| **`new-admin-root`** | 傘狀 monorepo（追蹤 docs/、deploy/、本計畫） | `.`（workspace root） | TBD（推到自己的 GitHub） |
| **`new-admin-base-web`** | `fork260509-soybean-admin` 上的新分支 | `admin-web/` (git worktree) | `miso168net/fork260509-soybean-admin` 的 `new-admin-base-web` 分支 |
| **`new-admin-rust-api`** | `fork260509-soybean-admin-rust` 上的新分支 | `admin-api/` (git worktree) | `miso168net/fork260509-soybean-admin-rust` 的 `new-admin-rust-api` 分支 |

**重點**：`admin-web/` 與 `admin-api/` 不是檔案複製，是 git worktree。`.git` 是檔案而非目錄，指向源倉的 `worktrees/`。在 `admin-web/` 內 commit 會直接寫入 fork260509-soybean-admin 的 `new-admin-base-web` 分支；外層 `new-admin-root` 不追蹤這兩個目錄（已在 .gitignore）。

---

## 0. TL;DR

| 項目 | 結論 |
|---|---|
| 兩個 fork 是否能無縫整合 | ❌ 直接拼**不能 work** — 至少 10 個必修 GAP（含 4 個 critical：response code、field naming、login body、CORS） |
| 是否值得整合 | ✅ 修完 10 個 GAP（合計 < 200 行 code 變動）後可運行 |
| 主要風險 | (1) new-admin-rust-api 原本就是配 NestJS 前端設計的（README 有官方說明）；standalone admin 是更精簡的 starter，要做的對齊比 NestJS frontend 更多。(2) 預設 success code 是 `200` 不是 `0000`，env 對齊就解決 |
| 部署拓樸 | 推薦：單機 Docker Compose（postgres + redis + migration init + new-admin-rust-api + new-admin-base-web）。dev 模式：infra 三件 + new-admin-rust-api 用 docker，admin-web用 vite host 模式 + proxy |
| 預估工時 | dev pipeline 跑通：~半天；prod compose + smoke test 全綠：~1 天 |

---

## 1. 整合架構與部署拓樸

### 1.1 服務元件

```
┌─────────────────────────────────────────────────────────────────┐
│                        host:8080 (HTTP)                         │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                  ┌──────────────────────────┐
                  │  new-admin-base-web      │   ← 對外唯一入口
                  │  - 靜態 dist/            │     1. /          → static SPA
                  │  - reverse proxy         │     2. /api/*     → new-admin-rust-api:10001
                  └────────────┬─────────────┘
                               │ /api/*
                  ┌──────────────────────────┐
                  │  new-admin-rust-api      │   ← Rust + axum + Casbin
                  │  port 10001 (intra)      │
                  └─────┬──────────────┬─────┘
                        │              │
              ┌─────────▼─────┐   ┌────▼────────┐
              │  postgres     │   │  redis      │   ← 6379, AUTH 123456
              │  port 5432    │   │             │
              └───────────────┘   └─────────────┘
                        ▲
              ┌─────────┴───────┐
              │  migration      │   ← run-once init container
              │  (Sea-ORM)      │     成功後 exit 0
              └─────────────────┘
```

**為何這樣切**：
- **new-admin-base-web 與 new-admin-rust-api 同源**（都從 nginx 出去）→ 解決 CORS（GAP-0e）不需在 Rust 加 CorsLayer
- **migration 獨立成 init container** → 第一次啟動不需 SSH 進去手跑、後續滾動更新自動 schema 升級
- **redis、postgres 內網不對外** → 預設安全；除錯時可在 dev compose 暴露
- **不放 pgbouncer** → admin app 流量低，Sea-ORM 自帶 pool（max 10）夠用；要時可加（見選項）

### 1.2 反向代理選擇

| 選項 | 優點 | 缺點 | 推薦 |
|---|---|---|---|
| **A. nginx**（推薦） | 最熟、image 1MB（alpine）、靜態 + proxy 一次搞定 | conf 語法繁瑣 | ⭐ |
| B. caddy | conf 簡潔、自動 HTTPS、HTTP/3 開箱 | image 較大、社群略小 | 需要自動 HTTPS 時改用 |
| C. traefik | 服務發現、多服務動態路由、Dashboard | overkill for 2 services | 微服務化時改用 |
| D. 不用 reverse proxy（vite preview + Rust 各暴露） | 最簡 | CORS 必須在 Rust 開、兩個 port 對外、TLS 要兩份證書 | 不推薦 |

### 1.3 Network / Volume 設計

```yaml
networks:
  admin-net:        # 內網：所有服務通訊
    driver: bridge

volumes:
  pg-data:          # postgres 持久資料
  redis-data:       # redis 持久資料（appendonly）
  web-dist:          # （可選）跨 build/runtime container 共享 new-admin-base-web dist
```

對外只暴露 `new-admin-base-web` 的 `8080`。其他全在 `admin-net` 內互通。

### 1.4 部署拓樸選項

| 選項 | 適用 | 取捨 |
|---|---|---|
| **A. 單機 docker-compose**（推薦起手） | 內部 admin、< 1000 並發 | 單點故障、無水平擴展 |
| B. 同 stack + traefik / caddy 自動 HTTPS | 外網需 HTTPS | +1 service |
| C. K8s（Helm chart） | 多環境、HA | 顯著複雜 |
| D. 純 systemd（無 docker） | 嚴格的內網裸機 | 失去 reproducibility |

本計畫只展開 A；B/C 未來可從 A 平滑遷移。

---

## 2. 倉儲結構選項

| 選項 | 結構 | 優點 | 缺點 |
|---|---|---|---|
| **A. 傘狀 + 兩個 worktree**（推薦，本計畫採用） | `new-admin-root/{docs,deploy}` 為自身追蹤；`admin-web/` `admin-api/` 各為一個 fork repo 的 git worktree | 各 fork 仍可正常 push、保留 upstream rebase 能力、外層只追蹤跨倉產出、單一目錄看到所有東西、**不需 history merge** | 要記得 `cd admin-web/` 或 `cd admin-api/` 才 commit 到對的地方；初始化要做兩次 `git worktree add` |
| B. 真 monorepo（合併 history） | `new-admin/{ui,server,deploy,docs}` 全部合併（git subtree / 三方 merge） | 真正單一 PR 改前後端、共用 history | 失去 upstream rebase 能力、history 巨大、若上游改了同樣檔案要手動 reconcile |
| C. 三個獨立 repo | `new-admin-root` / `new-admin-base-web` / `new-admin-rust-api` 三個遠端 | 各自獨立發布 | 跨 repo 改動需協調多個 PR；deploy 配對版本要靠 tag |
| D. 1 deploy repo + 2 git submodule | 外層用 submodule 釘住兩個 fork 的 commit | deploy 版本固定到精確 commit | submodule 操作麻煩、改 admin-web/server 要先 commit 才能更新 deploy pin |

### 2.1 採用結構：傘狀 + worktree

```
new-admin-root/                  ← 傘狀 repo（== workspace root，僅追蹤本倉檔案）
├── CLAUDE.md
├── .gitignore
├── docs/                        ← 跨倉設計產出
│   ├── INTEGRATION-RESEARCH.md
│   ├── INTEGRATION-PLAN.md      ← 本文件
│   ※ GRAPH_REPORT.md 在 ../graphify-out/（不放 symlink，Windows TortoiseGit 處理異常）
├── graphify-out/                ← 知識圖譜（本倉追蹤 graph.json/manifest/cost/REPORT）
├── deploy/                      ← docker-compose / nginx / .env.example（在 §5）
│   ├── compose.yaml
│   ├── compose.dev.yaml
│   ├── nginx/default.conf
│   ├── redis/redis.conf
│   └── .env.example
│
│  === 以下是 worktree 與來源倉，外層 .gitignore 已排除 ===
├── fork260509-soybean-admin/    ← worktree 源倉（must remain）
├── fork260509-soybean-admin-rust/   ← worktree 源倉（must remain）
├── fork260509-soybean-admin-docs/   ← reference, untouched
├── fork260509-soybean-admin-nestjs/ ← reference, untouched
│
├── admin-web/  (worktree, branch: new-admin-base-web)        ← cd admin-web && git status 顯示是這個分支
│   ├── .git                     ← FILE 指向 fork260509-soybean-admin/.git/worktrees/admin-web
│   ├── src/  build/  packages/  public/
│   ├── package.json  vite.config.ts  pnpm-lock.yaml
│   ├── .env  .env.dev  .env.prod   ← 改寫（GAP 修補）
│   ├── Dockerfile               ← 新建（commit 到 new-admin-base-web 分支）
│   └── ...（其餘 fork260509-soybean-admin 原內容）
│
└── admin-api/  (worktree, branch: new-admin-rust-api)  ← cd admin-api && git status 顯示是這個分支
    ├── .git                     ← FILE 指向 fork260509-soybean-admin-rust/.git/worktrees/admin-api
    ├── server/                  ← 原內部 Cargo workspace
    ├── migration/  axum-casbin/  sea-orm-adapter/  xdb/
    ├── Cargo.toml  Dockerfile   ← Dockerfile 在新分支上改造
    ├── scripts/entrypoint.sh    ← 新增
    └── server/resources/
        ├── application.yaml.tpl ← 改名 + 改寫成 envsubst template
        ├── rbac_model.conf
        └── ip2region.xdb
├── deploy/
│   ├── compose.yaml          ← 主要 prod 編排
│   ├── compose.dev.yaml      ← dev override
│   ├── nginx/
│   │   └── default.conf
│   ├── postgres/
│   │   └── init.sql          ← (optional) 額外的 DB init
│   ├── redis/
│   │   └── redis.conf
│   ├── .env.example          ← 全部 env 變數樣板
│   └── README.md
├── docs/
│   ├── INTEGRATION-RESEARCH.md  ← 從原 root 移入
│   ├── INTEGRATION-PLAN.md      ← 本文件移入
│   └── GRAPH_REPORT.md          ← graphify 產出移入
├── .gitignore
├── LICENSE
└── README.md                 ← 統合說明
```

---

## 3. 建立 worktree 與初始改動

**核心觀念**：不複製任何檔案、不 fork 出新 repo。只在原本 fork 的兩個源倉上**開新分支**並 `git worktree add` 到 `admin-web/` 與 `admin-api/`，然後在新分支上做 GAP 修補與 Dockerfile 改造。改動天然 commit 到新分支，可隨時 push 回該 fork repo。

### 3.0 建立 worktree（一次性）

```bash
cd /home/anew/x_Project/fork260509       # workspace root

# === admin-web worktree ===
cd fork260509-soybean-admin
git fetch origin                          # 確保拿到最新
git worktree add -b new-admin-base-web ../admin-web    # 從 HEAD 開分支 new-admin-base-web，checkout 到 ../admin-web
cd ..

# === server worktree ===
cd fork260509-soybean-admin-rust
git fetch origin
git worktree add -b new-admin-rust-api ../admin-api
cd ..

# 驗證
ls -la admin-web/.git      # 應該是 file，內容指向 fork260509-soybean-admin/.git/worktrees/admin-web
ls -la admin-api/.git  # 應該是 file，內容指向 fork260509-soybean-admin-rust/.git/worktrees/admin-api
(cd admin-web && git branch --show-current)        # → new-admin-base-web
(cd admin-api && git branch --show-current)    # → new-admin-rust-api
```

> 推回 GitHub：`cd admin-web && git push -u origin new-admin-base-web`、`cd admin-api && git push -u origin new-admin-rust-api`。第一次 push 用 `-u` 設 upstream 後，之後 `git push` 即可。

#### 3.0b 註冊為外層 submodule（worktree 推完 fork branch 後做一次）

worktree 給本機操作（commit/push 推回 fork），submodule 給外層 git 追蹤「當前用哪個 fork SHA」。兩者並存。

```bash
# 在 workspace root
cat > .gitmodules << 'EOF'
[submodule "admin-web"]
    path = admin-web
    url = https://github.com/miso168net/fork260509-soybean-admin.git
    branch = new-admin-base-web
[submodule "admin-api"]
    path = admin-api
    url = https://github.com/miso168net/fork260509-soybean-admin-rust.git
    branch = new-admin-rust-api
EOF

git submodule init                        # 註冊到 .git/config
git add .gitmodules admin-web admin-api   # 跳 "warning: adding embedded git repository" 是正常
git commit -m "init: register admin-web/admin-api as submodules"
```

之後改 worktree 內檔案 → 兩段 commit（詳見 CLAUDE.md §6.1 / §9）：第一段在 worktree 內 push 到 fork，第二段回外層 `git add admin-web && git commit` 更新 SHA pin。

⚠️ **不要用 `git submodule add` 指令** — 會試圖 clone 進已存在的 admin-web/、與 worktree 衝突。一定要手寫 `.gitmodules`。

### 3.1 在 `new-admin-rust-api` 分支上的改動（commit 到 admin-api/ worktree）

| 動作 | 對象 | 說明 |
|---|---|---|
| 改造 | `admin-api/server/resources/application.yaml` → 改名 `application.yaml.tpl`，改用 `${ENV_VAR:default}` 取代 hardcode | 見 §5.3 |
| 新增 | `admin-api/scripts/entrypoint.sh` | envsubst 把 env 注入 yaml.tpl，再 exec server 二進位 |
| 改造 | `admin-api/Dockerfile` | 多一個 build stage 跑 migration binary、加 entrypoint.sh、wget 給 healthcheck | 見 §5.3 |
| 修補 | GAP-0c：`admin-api/server/model/src/admin/output/sys_authentication.rs` | 加 `#[serde(rename_all = "camelCase")]` |
| 修補 | GAP-0d：同檔 + `admin-api/server/api/src/admin/sys_authentication_api.rs` | UserInfoOutput 加 `buttons` |
| 新增 | GAP-1：refresh handler — `admin-api/server/{model,router,api,service}/.../sys_authentication*.rs` | ~80 行 Rust（見 §4 GAP-1） |
| 新增 migration | `admin-api/migration/src/schemas/mXXXXXXXX_add_expires_at_to_sys_tokens.rs` | refresh token 過期判斷需要 |
| 新增 health endpoint | `admin-api/server/api/src/admin/sys_authentication_api.rs` 與 router | compose healthcheck 用 |
| 不動 | `admin-api/{deploy/,compose.yaml,README.md,README_ENV_CONFIG.md}` | 留在源倉的 main 分支即可；本 branch 不刻意刪 |

### 3.2 在 `new-admin-base-web` 分支上的改動（commit 到 admin-web/ worktree）

| 動作 | 對象 | 說明 |
|---|---|---|
| 改寫 | `admin-web/.env`、新增 `admin-web/.env.dev`、改寫 `admin-web/.env.prod`、刪除 `admin-web/.env.test` | 對齊 Rust（GAP-0a / 0b、見 §5.7-5.8） |
| 新增 | `admin-web/Dockerfile`、`admin-web/.dockerignore` | multi-stage（pnpm build → nginx serve）見 §5.4 |
| 修補 | GAP-0f：`admin-web/src/service/api/auth.ts` | `userName` → `identifier`（1 行） |
| 修補 | GAP-2：同檔 | 刪 `fetchCustomBackendError` 函式 |
| 修補 | GAP-3：`admin-web/src/store/modules/route/index.ts` + `admin-web/src/router/guard/route.ts` | `getIsAuthRouteExist` 改成查本地 routeStore |
| 修補 | GAP-4：`admin-web/src/service/api/route.ts:9` | `/route/getUserRoutes` → `/auth/getUserRoutes` |

### 3.3 在 `new-admin-root`（本傘狀 repo）上的改動

| 動作 | 對象 | 說明 |
|---|---|---|
| 新增目錄 | `deploy/` | 整個 §5 的 docker-compose / nginx / .env.example 都在這 |
| 新增 | `deploy/compose.yaml` | 主 prod 編排（見 §5.1） |
| 新增 | `deploy/compose.dev.yaml` | dev override（見 §5.2） |
| 新增 | `deploy/nginx/default.conf` | reverse proxy 設定（見 §5.5） |
| 新增 | `deploy/redis/redis.conf` | redis 自訂設定（如要） |
| 新增 | `deploy/.env.example` | env 變數樣板（見 §5.6） |
| 已有 | `docs/INTEGRATION-RESEARCH.md`、`docs/INTEGRATION-PLAN.md`、`graphify-out/GRAPH_REPORT.md` | 跨倉設計產出 |
| 已有 | `CLAUDE.md`、`.gitignore`、`graphify-out/` | workspace 配置與圖譜 |

### 3.4 `fork260509-soybean-admin-docs` 和 `fork260509-soybean-admin-nestjs` 怎麼處理

| 對象 | 處理 |
|---|---|
| `fork260509-soybean-admin-docs` | **不納入**。是上游官方文件站，跟我們的 admin 無直接關係。要保留時放外部 reference link 即可 |
| `fork260509-soybean-admin-nestjs` | **不納入**，但**留為參考**：它的 `frontend/src/service/api/system-manage.ts` 是未來 new-admin-base-web 擴充管理頁面時的 API client 範本（複製過去改 2 條 endpoint 即可） |

---

## 4. 完整 GAP 清單與修補方案

從 graphify 圖譜 + 直接讀 `Res<T>` / `LoginInput` / `AuthOutput` / admin-web `auth/index.ts` 對比後發現 **10 個 GAP**（比原 INTEGRATION-RESEARCH.md 的 4 個更全面）：

### 概觀

| # | GAP | 嚴重度 | 推薦修法 | 改動規模 |
|---|---|---|---|---|
| 0a | response success code (`'0000'` vs `200`) | 🔴 critical | 改 admin-web `.env` | 1 行 |
| 0b | error code 類別（logout/expired/modal） | 🔴 critical | 改 admin-web `.env` | 3 行 |
| 0c | `AuthOutput.refresh_token` 駝峰問題 | 🔴 critical | Rust serde rename | 1 行 |
| 0d | `UserInfoOutput` 缺 `buttons` | 🟡 major | Rust 加欄位（空陣列） | 2 行 |
| 0e | Rust 沒 CORS layer | 🟡 major | nginx 同源（推薦）/ tower-http CorsLayer（備案） | 0 行（同源）/ 5 行 |
| 0f | login body field 名稱（`userName` vs `identifier`） | 🔴 critical | 改 admin-web `auth.ts` | 1 行 |
| 1 | `POST /auth/refreshToken` 不存在 | 🔴 critical | Rust 加 handler（複用 `sys_tokens` 表） | ~80 行 |
| 2 | `GET /auth/error` 不存在 | 🟢 minor | admin-web 刪掉 `fetchCustomBackendError` | -8 行 |
| 3 | `GET /route/isRouteExist` 不存在 | 🟡 major | admin-web 改成本地查 routeStore | ~15 行 |
| 4 | `/route/getUserRoutes` 路徑不一致 | 🟡 major | admin-web 改成 `/auth/getUserRoutes` | 1 行 |

**累計**：~110 行 code + ~5 行 env

### GAP-0a：success code

**問題**：Rust `Res::new_data` 設 `code = StatusCode::OK.as_u16() = 200`。admin-web `.env` 寫 `VITE_SERVICE_SUCCESS_CODE=0000`，admin-web會把所有成功 response 當失敗。

| 選項 | 方案 | 推薦 |
|---|---|---|
| A | admin-web `.env.prod`：`VITE_SERVICE_SUCCESS_CODE=200` | ⭐ |
| B | Rust `Res::new_data` 改設 `code = 0` 並另寫字串 `"0000"` | 違反 HTTP semantics |
| C | Rust 包一層 outer enveloper，code 用業務碼 | 過度工程 |

### GAP-0b：error code 類別

**問題**：admin-web預設：

```
VITE_SERVICE_LOGOUT_CODES=8888,8889
VITE_SERVICE_MODAL_LOGOUT_CODES=7777,7778
VITE_SERVICE_EXPIRED_TOKEN_CODES=9999,9998,3333
```

Rust 用 HTTP status codes：401（unauthorized）、403（forbidden）、404、500。

**對齊策略**：
- token 過期 → Rust 401 `"Unauthorized"` → admin-web應 refresh token
- 無權限 → Rust 403 → admin-web不應 logout、應顯示 403 頁
- 其他 4xx/5xx → 顯示 toast

| 選項 | 方案 | 推薦 |
|---|---|---|
| A | admin-web `.env.prod`：`VITE_SERVICE_EXPIRED_TOKEN_CODES=401`、`VITE_SERVICE_LOGOUT_CODES=`（清空）、`VITE_SERVICE_MODAL_LOGOUT_CODES=`（清空） | ⭐ |
| B | Rust 建立業務碼層級（401 內細分為「token 過期」vs「token 無效」） | 改 Rust 5 個檔，未來再說 |

### GAP-0c：`AuthOutput.refresh_token` 駝峰問題

**問題**：Rust serialize 出來會是 `{"token": "...", "refresh_token": "..."}`，admin-web store `loginToken.refreshToken` 會是 `undefined`。

**檔案**：`server/model/src/admin/output/sys_authentication.rs`

| 選項 | 方案 | 推薦 |
|---|---|---|
| A | 加 `#[serde(rename_all = "camelCase")]` derive | ⭐ |
| B | 加 `#[serde(rename = "refreshToken")]` 在欄位上 | 同樣可行、稍冗 |
| C | 改admin-web type 接 `refresh_token`（snake） | 整套admin-web types 都要改、不推薦 |

**Patch**：

```rust
// server/model/src/admin/output/sys_authentication.rs
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]   // ← 加這行
pub struct AuthOutput {
    pub token: String,
    pub refresh_token: String,
}
```

### GAP-0d：`UserInfoOutput` 缺 `buttons`

**問題**：admin-web `Api.Auth.UserInfo`：

```ts
interface UserInfo {
  userId: string;
  userName: string;
  roles: string[];
  buttons: string[];   // ← Rust 沒回
}
```

| 選項 | 方案 | 推薦 |
|---|---|---|
| A | Rust 加空陣列欄位 | ⭐（現在沒按鈕級權限就先給 `[]`） |
| B | 真的實作 button 權限：把每個 menu 的 `meta.buttons` 收集起來 | 未來功能、目前先 placeholder |
| C | 改admin-web type 為 `buttons?: string[]` | 違反admin-web期望、可能其他元件壞掉 |

**Patch**：

```rust
// server/model/src/admin/output/sys_authentication.rs
#[derive(Debug, Serialize)]
pub struct UserInfoOutput {
    #[serde(rename = "userId")]
    pub user_id: String,
    #[serde(rename = "userName")]
    pub user_name: String,
    pub roles: Vec<String>,
    #[serde(default)]
    pub buttons: Vec<String>,        // ← 新增
}
```

API handler 也要回傳：

```rust
// server/api/src/admin/sys_authentication_api.rs
let user_info = UserInfoOutput {
    user_id: user.user_id(),
    user_name: user.username(),
    roles: user.subject(),
    buttons: vec![],                 // ← TODO: 未來從 menu meta 收集
};
```

### GAP-0e：CORS

**問題**：Rust 沒掛 `tower_http::cors::CorsLayer`。瀏覽器發 cross-origin request 會被擋。

| 選項 | 方案 | 推薦 |
|---|---|---|
| **A. 同源 reverse proxy**（推薦） | nginx 把 `/api/*` 反代到 new-admin-rust-api，瀏覽器只看到 nginx 一個 origin → CORS 不存在 | ⭐ |
| B. 在 Rust 開 CorsLayer | 在 `apply_layers` 加 `.layer(CorsLayer::permissive())` 或更嚴格設定 | 開發方便、prod 要小心設 origin allowlist |
| C. dev 用 vite proxy + prod 用 nginx | dev 跟 prod 行為一致需小心 | dev 模式採此 |

**選 A 不需改 Rust 任何 code**。詳細的 nginx conf 見 §5.5。

### GAP-0f：login body field 名稱

**問題**：

```ts
// admin-web src/service/api/auth.ts
data: { userName, password }     // ← 送出 {"userName":"Soybean","password":"..."}
```

```rust
// Rust server/model/src/admin/input/sys_authentication.rs
pub struct LoginInput {
    pub identifier: String,        // ← 期望 {"identifier":"...","password":"..."}
    pub password: String,
}
```

| 選項 | 方案 | 推薦 |
|---|---|---|
| A | 改admin-web `data: { identifier: userName, password }` | ⭐ 1 行 |
| B | 改 Rust `pub identifier` → `pub user_name` + `#[serde(rename = "userName")]` | 改 schema 影響其他可能的呼叫者 |

**Patch**：

```ts
// admin-web/src/service/api/auth.ts
export function fetchLogin(userName: string, password: string) {
  return request<Api.Auth.LoginToken>({
    url: '/auth/login',
    method: 'post',
    data: {
      identifier: userName,    // ← 改這行
      password
    }
  });
}
```

### GAP-1：`POST /auth/refreshToken`

**現況**：login 時 Rust 已用 `Ulid::new()` 生 refresh_token 並透過 `AccessTokenEvent` 寫入 `sys_tokens` 表。但**沒有**對應的 refresh handler 來消費這個 token。

| 選項 | 方案 | 評估 |
|---|---|---|
| **A. DB-backed refresh**（推薦） | 新 handler 收到 `refreshToken`，查 `sys_tokens.refresh_token` + `status='Active'`，發新 JWT 並 rotate refresh token，更新 `sys_tokens` | ⭐ 與現有 `AccessTokenEvent` 寫入流程對稱、有 audit trail |
| B. Stateless JWT refresh | refresh_token 改成另一個長效 JWT（exp = 14d），refresh handler 純粹解碼驗簽發新 access token | 較簡、沒 DB I/O；但 revoke 困難 |
| C. 改長效 JWT 不刷新 | 把 `jwt.expire: 7200` 改 86400+，admin-web `fetchRefreshToken` 改 no-op | internal admin 可接受、安全弱 |

**選 A 的 patch（核心 ~80 行）**：

```rust
// 1. server/model/src/admin/input/sys_authentication.rs
#[derive(Deserialize, Validate)]
pub struct RefreshTokenInput {
    #[serde(rename = "refreshToken")]
    pub refresh_token: String,
}

// 2. server/router/src/admin/sys_authentication_route.rs
pub async fn init_authentication_router() -> Router {
    let router = Router::new()
        .route("/login", post(SysAuthenticationApi::login_handler))
        .route("/refreshToken", post(SysAuthenticationApi::refresh_token_handler));   // ← 新增
    Router::new().nest("/auth", router)
}

// 3. server/api/src/admin/sys_authentication_api.rs
pub async fn refresh_token_handler(
    Extension(service): Extension<Arc<SysAuthService>>,
    ValidatedForm(input): ValidatedForm<RefreshTokenInput>,
) -> Result<Res<AuthOutput>, AppError> {
    service.refresh_token(input.refresh_token)
        .await
        .map(Res::new_data)
}

// 4. server/service/src/admin/sys_auth_service.rs
async fn refresh_token(&self, refresh_token: String) -> Result<AuthOutput, AppError> {
    let db = db_helper::get_db_connection().await?;
    let token_row = SysTokens::find()
        .filter(sys_tokens::Column::RefreshToken.eq(&refresh_token))
        .filter(sys_tokens::Column::Status.eq(TokenStatus::Active.to_string()))
        .one(&*db)
        .await?
        .ok_or_else(|| AppError { code: 401, message: "Refresh token invalid".into() })?;

    // Rotate: 標記舊 token revoked、issue 新組
    let mut active: SysTokensActiveModel = token_row.into();
    active.status = Set(TokenStatus::Revoked.to_string());
    active.update(&*db).await?;

    // 重新生 access + refresh
    generate_access_token(...).await
}
```

> 注意：要在 `sys_tokens` 表加 `expires_at` 欄位（migration 補一次）才能正確判斷 refresh token 是否過期。或者用 `created_at + REFRESH_EXPIRE` 做運算。

### GAP-2：`GET /auth/error`

**現況**：admin-web `fetchCustomBackendError(code, msg)` 把 code/msg 當 query string 送給 `/auth/error`，故意觸發 admin-api 回對應錯誤碼來測試攔截器。生產環境不會用。

| 選項 | 方案 | 推薦 |
|---|---|---|
| **A. 從admin-web刪除函式**（推薦） | `auth.ts` 刪 `fetchCustomBackendError`，找出 0 個呼叫點即可 | ⭐ |
| B. Rust 加 5 行 echo handler | `Router::new().route("/error", get(echo_error))` | 仍然只有 dev 用 |
| C. vite-plugin-mock 在admin-web模擬 | 開發時攔截 `/auth/error` 回 fake | dev 即可、prod 不需要 |

### GAP-3：`GET /route/isRouteExist`

**現況**：admin-web在 `router/guard/route.ts:139` 的 `initRoute()` 內呼叫 `routeStore.getIsAuthRouteExist(to.path)` 判斷 not-found 路由是否其實有權限的存在 → Rust 沒這 endpoint。

| 選項 | 方案 | 評估 |
|---|---|---|
| **A. admin-web本地查 routeStore**（推薦） | `getIsAuthRouteExist` 改成從本地已 fetch 的 user routes 查 | ⭐ 0 行 admin-api、admin-web ~15 行 |
| B. Rust 加 endpoint | `sys_menu_route.rs` 加 `.route("/isRouteExist", get(...))`，handler 查 SysMenu | ~30 行 Rust |
| C. 用 Casbin enforce 替代 | `enforcer.enforce(user, route, "read")` | 語意稍偏：是「是否有權限」不是「是否存在」 |

**選 A 的 patch**：

```ts
// admin-web/src/store/modules/route/index.ts （已存在 routeStore）
function getIsAuthRouteExist(routePath: RoutePath) {
  // 從 cached user routes 查；user routes 由 fetchGetUserRoutes 一次拿完
  return Boolean(findRouteByPath(routePath, allRoutes.value));
}
```

### GAP-4：`/route/getUserRoutes` 路徑

| 選項 | 方案 | 推薦 |
|---|---|---|
| **A. 改admin-web**（推薦） | `src/service/api/route.ts:9` `'/route/getUserRoutes'` → `'/auth/getUserRoutes'` | ⭐ 1 行 |
| B. 改 Rust | 在 `init_protected_menu_router` 加 alias route `/getUserRoutes` | 1 行 Rust |
| C. 走 `/authorization/getUserRoutes` | Rust 已有；改admin-web prefix | 跟 A 等價 |

---

## 5. Docker Compose 完整實作

### 5.1 `deploy/compose.yaml`（生產編排）

```yaml
name: new-admin-root

services:
  postgres:
    image: postgres:17.4-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-new_admin}
      POSTGRES_USER: ${POSTGRES_USER:-admin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?must set POSTGRES_PASSWORD}
      TZ: ${TZ:-Asia/Taipei}
    volumes:
      - pg-data:/var/lib/postgresql/data
    networks:
      - admin-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-admin} -d ${POSTGRES_DB:-new_admin}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  redis:
    image: redis:7.4-alpine
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:?must set REDIS_PASSWORD}", "--appendonly", "yes"]
    volumes:
      - redis-data:/data
    networks:
      - admin-net
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  migration:
    build:
      context: ../admin-api
      dockerfile: Dockerfile
      target: build                # 從 build stage 拿 cargo migration binary
    image: new-admin-rust-api-build:latest
    command: ["cargo", "run", "-p", "migration", "--", "up"]
    working_dir: /app
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-new_admin}
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - admin-net
    restart: "no"                  # init container, exit 0 後不重啟

  new-admin-rust-api:
    build:
      context: ../admin-api
      dockerfile: Dockerfile
    image: new-admin-rust-api:latest
    restart: unless-stopped
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-new_admin}
      DATABASE_MAX_CONNECTIONS: ${DATABASE_MAX_CONNECTIONS:-10}
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      JWT_SECRET: ${JWT_SECRET:?must set JWT_SECRET}
      JWT_ISSUER: ${JWT_ISSUER:-https://github.com/your-org/new-admin}
      JWT_EXPIRE: ${JWT_EXPIRE:-7200}
      SERVER_HOST: 0.0.0.0
      SERVER_PORT: 10001
      RUST_LOG: ${RUST_LOG:-info}
      TZ: ${TZ:-Asia/Taipei}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      migration:
        condition: service_completed_successfully
    networks:
      - admin-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:10001/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    # 不對外暴露 port，只透過 new-admin-base-web 反代

  new-admin-base-web:
    build:
      context: ..
      dockerfile: admin-web/Dockerfile
      args:
        VITE_BASE_URL: /
        VITE_SERVICE_BASE_URL: /api
        VITE_APP_TITLE: ${VITE_APP_TITLE:-NewAdmin}
        VITE_AUTH_ROUTE_MODE: ${VITE_AUTH_ROUTE_MODE:-static}
        VITE_STATIC_SUPER_ROLE: ${VITE_STATIC_SUPER_ROLE:-R_SUPER}
    image: new-admin-base-web:latest
    restart: unless-stopped
    ports:
      - "${WEB_PORT:-8080}:80"
    depends_on:
      new-admin-rust-api:
        condition: service_healthy
    networks:
      - admin-net

networks:
  admin-net:
    driver: bridge

volumes:
  pg-data:
  redis-data:
```

### 5.2 `deploy/compose.dev.yaml`（開發疊加）

```yaml
# Override for local dev:
#   docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration new-admin-rust-api
# 然後在 host 上跑 admin-web:  cd admin-web && pnpm dev
# Vite 會 proxy /proxy-default → http://localhost:10001

name: new-admin-root-dev

services:
  postgres:
    ports:
      - "5432:5432"        # dev 暴露給 host 工具（DBeaver 等）

  redis:
    ports:
      - "6379:6379"        # dev 暴露 redis-cli

  new-admin-rust-api:
    ports:
      - "10001:10001"      # dev 暴露給 host vite proxy
    environment:
      RUST_LOG: debug

  # 不需要 new-admin-base-web — admin-web走 host vite dev server
  new-admin-base-web:
    profiles: ["never"]    # 用 profile 排除
```

### 5.3 Rust Dockerfile 改造

**現有 Dockerfile 的問題**：把 `application.yaml` hardcode 進 image。改成讀 env 變數。

| 選項 | 方案 | 推薦 |
|---|---|---|
| **A. 程式碼讀 env**（推薦） | `application.yaml` 用 `${VAR:default}` 語法，server bootstrap 時 envsubst 或用 `config::Environment` | ⭐ |
| B. Volume mount 整個 yaml | compose 把外部 yaml 掛進去 | 配置漂移風險 |
| C. ConfigMap pattern（K8s 思路） | 略 |  |

**改造後的 `admin-api/Dockerfile`**（在現有基礎上小幅調整）：

```dockerfile
ARG RUST_VERSION=1.86.0
ARG APP_NAME=server
ARG ALPINE_VERSION=3.21
ARG APP_PORT=10001
ARG APP_USER=appuser
ARG APP_UID=10001
ARG TZ=Asia/Taipei

# ===== build stage =====
FROM rust:${RUST_VERSION}-alpine AS build
ARG APP_NAME
WORKDIR /app
RUN apk add --no-cache clang lld musl-dev git pkgconfig openssl-dev openssl-libs-static
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release --bin ${APP_NAME} --no-default-features && \
    cp target/release/${APP_NAME} /bin/server && \
    cargo build --release --bin migration && \
    cp target/release/migration /bin/migration && \
    strip /bin/server /bin/migration

# ===== runtime stage =====
FROM alpine:${ALPINE_VERSION} AS final
ARG APP_USER
ARG APP_UID
ARG TZ
ARG APP_PORT
ENV TZ=${TZ} \
    LANG=en_US.UTF-8 \
    RUST_ENV=production
RUN apk add --no-cache openssl ca-certificates tzdata wget gettext && \
    adduser --disabled-password --gecos "" --home "/nonexistent" --shell "/sbin/nologin" \
            --no-create-home --uid "${APP_UID}" ${APP_USER} && \
    mkdir -p /app/server/resources && \
    chown -R ${APP_USER}:${APP_USER} /app

COPY --from=build /bin/server /bin/migration /bin/
COPY --from=build --chown=${APP_USER}:${APP_USER} \
     /app/server/resources/application.yaml.tpl /app/server/resources/
COPY --from=build --chown=${APP_USER}:${APP_USER} \
     /app/server/resources/ip2region.xdb /app/server/resources/
COPY --from=build --chown=${APP_USER}:${APP_USER} \
     /app/server/resources/rbac_model.conf /app/server/resources/
COPY --from=build --chown=${APP_USER}:${APP_USER} \
     /app/scripts/entrypoint.sh /app/

WORKDIR /app
USER ${APP_USER}
EXPOSE ${APP_PORT}
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/bin/server"]
```

**配套 `admin-api/scripts/entrypoint.sh`**：

```sh
#!/bin/sh
set -e
# 把 env 注入 application.yaml
envsubst < /app/server/resources/application.yaml.tpl \
       > /app/server/resources/application.yaml
exec "$@"
```

**配套 `admin-api/server/resources/application.yaml.tpl`**（改名加 `.tpl`，內容改用 env 預設值）：

```yaml
database:
    url: "${DATABASE_URL}"
    max_connections: ${DATABASE_MAX_CONNECTIONS:-10}
    min_connections: 1
    connect_timeout: 30
    idle_timeout: 600
server:
    host: "${SERVER_HOST:-0.0.0.0}"
    port: ${SERVER_PORT:-10001}
jwt:
    jwt_secret: "${JWT_SECRET}"
    issuer: "${JWT_ISSUER:-https://github.com/your-org/new-admin}"
    expire: ${JWT_EXPIRE:-7200}
redis:
    mode: single
    url: "${REDIS_URL}"
```

### 5.4 UI Dockerfile（新建）

```dockerfile
# ===== build stage =====
FROM node:22-alpine AS build
WORKDIR /app

# build args 接到 env，vite 會在 build 時固化
ARG VITE_BASE_URL=/
ARG VITE_SERVICE_BASE_URL=/api
ARG VITE_APP_TITLE=NewAdmin
ARG VITE_AUTH_ROUTE_MODE=static
ARG VITE_STATIC_SUPER_ROLE=R_SUPER
ARG VITE_SERVICE_SUCCESS_CODE=200
ARG VITE_SERVICE_LOGOUT_CODES=
ARG VITE_SERVICE_MODAL_LOGOUT_CODES=
ARG VITE_SERVICE_EXPIRED_TOKEN_CODES=401
ARG VITE_HTTP_PROXY=N
ARG VITE_ROUTER_HISTORY_MODE=history
ARG VITE_STORAGE_PREFIX=NA_

ENV VITE_BASE_URL=${VITE_BASE_URL} \
    VITE_SERVICE_BASE_URL=${VITE_SERVICE_BASE_URL} \
    VITE_APP_TITLE=${VITE_APP_TITLE} \
    VITE_AUTH_ROUTE_MODE=${VITE_AUTH_ROUTE_MODE} \
    VITE_STATIC_SUPER_ROLE=${VITE_STATIC_SUPER_ROLE} \
    VITE_SERVICE_SUCCESS_CODE=${VITE_SERVICE_SUCCESS_CODE} \
    VITE_SERVICE_LOGOUT_CODES=${VITE_SERVICE_LOGOUT_CODES} \
    VITE_SERVICE_MODAL_LOGOUT_CODES=${VITE_SERVICE_MODAL_LOGOUT_CODES} \
    VITE_SERVICE_EXPIRED_TOKEN_CODES=${VITE_SERVICE_EXPIRED_TOKEN_CODES} \
    VITE_HTTP_PROXY=${VITE_HTTP_PROXY} \
    VITE_ROUTER_HISTORY_MODE=${VITE_ROUTER_HISTORY_MODE} \
    VITE_STORAGE_PREFIX=${VITE_STORAGE_PREFIX}

# pnpm 透過 corepack
RUN corepack enable && corepack prepare pnpm@10.5.0 --activate

# 只複製 lockfile 與 manifest 先做 deps cache
COPY admin-web/package.json admin-web/pnpm-lock.yaml admin-web/pnpm-workspace.yaml ./
COPY admin-web/packages/ ./packages/
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# 複製其餘 source 並 build
COPY admin-web/ ./
RUN pnpm build

# ===== runtime stage =====
FROM nginx:1.27-alpine AS final
COPY --from=build /app/dist /usr/share/nginx/html
COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
```

### 5.5 nginx 反向代理 `deploy/nginx/default.conf`

```nginx
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # 健康檢查
    location = /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # 反代到 new-admin-rust-api（同源解 CORS）
    location /api/ {
        proxy_pass http://new-admin-rust-api:10001/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-Id $request_id;
        # axum 連線上限 / timeout 配合
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        # WebSocket（未來如果加）
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # SPA fallback：所有非 /api 開頭的 path 都回 index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 靜態資源 cache
    location ~* \.(?:css|js|jpe?g|png|gif|svg|ico|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    gzip_min_length 1024;
}
```

### 5.6 `deploy/.env.example`

```bash
# ============================================================
# new-admin-root docker-compose 環境變數模板
# 複製為 .env 後填入實際值
# ============================================================

# --- Postgres ---
POSTGRES_DB=new_admin
POSTGRES_USER=admin
POSTGRES_PASSWORD=change-me-strong-password

# --- Redis ---
REDIS_PASSWORD=change-me-redis-password

# --- new-admin-rust-api ---
JWT_SECRET=change-me-jwt-secret-at-least-32-chars
JWT_ISSUER=https://github.com/your-org/new-admin
JWT_EXPIRE=7200                # access token TTL（秒）
DATABASE_MAX_CONNECTIONS=10
RUST_LOG=info                  # trace|debug|info|warn|error

# --- UI ---
WEB_PORT=8080                   # 對外暴露 port
VITE_APP_TITLE=NewAdmin
VITE_AUTH_ROUTE_MODE=static    # static | dynamic
VITE_STATIC_SUPER_ROLE=R_SUPER

# --- 通用 ---
TZ=Asia/Taipei
```

### 5.7 `admin-web/.env.dev`（取代原 `.env.test`）

```bash
# 開發模式：vite dev server + proxy 到 docker 的 new-admin-rust-api
VITE_BASE_URL=/
VITE_APP_TITLE=NewAdmin (dev)
VITE_APP_DESC=NewAdmin development environment

VITE_HTTP_PROXY=Y
VITE_PROXY_LOG=Y
VITE_SERVICE_BASE_URL=http://localhost:10001
VITE_OTHER_SERVICE_BASE_URL='{"demo": "http://localhost:10001"}'

# === 對齊 new-admin-rust-api ===
VITE_SERVICE_SUCCESS_CODE=200
VITE_SERVICE_LOGOUT_CODES=
VITE_SERVICE_MODAL_LOGOUT_CODES=
VITE_SERVICE_EXPIRED_TOKEN_CODES=401

# === Auth 與路由 ===
VITE_AUTH_ROUTE_MODE=static
VITE_ROUTE_HOME=home
VITE_STATIC_SUPER_ROLE=R_SUPER
VITE_ROUTER_HISTORY_MODE=history

# === UI 雜項 ===
VITE_ICON_PREFIX=icon
VITE_ICON_LOCAL_PREFIX=icon-local
VITE_MENU_ICON=mdi:menu
VITE_SOURCE_MAP=N
VITE_STORAGE_PREFIX=NA_
VITE_AUTOMATICALLY_DETECT_UPDATE=Y
```

### 5.8 `admin-web/.env.prod`

```bash
# 生產模式：build artifact 由 nginx 服務、走 /api 同源
VITE_BASE_URL=/
VITE_APP_TITLE=NewAdmin
VITE_APP_DESC=NewAdmin

VITE_HTTP_PROXY=N
VITE_SERVICE_BASE_URL=/api
VITE_OTHER_SERVICE_BASE_URL='{"demo": "/api"}'

VITE_SERVICE_SUCCESS_CODE=200
VITE_SERVICE_LOGOUT_CODES=
VITE_SERVICE_MODAL_LOGOUT_CODES=
VITE_SERVICE_EXPIRED_TOKEN_CODES=401

VITE_AUTH_ROUTE_MODE=static
VITE_ROUTE_HOME=home
VITE_STATIC_SUPER_ROLE=R_SUPER
VITE_ROUTER_HISTORY_MODE=history

VITE_ICON_PREFIX=icon
VITE_ICON_LOCAL_PREFIX=icon-local
VITE_MENU_ICON=mdi:menu
VITE_SOURCE_MAP=N
VITE_STORAGE_PREFIX=NA_
VITE_AUTOMATICALLY_DETECT_UPDATE=Y
```

---

## 6. 啟動與初始化流程

### 6.1 第一次 boot 順序

```
0. （前置）已完成 §3.0 worktree 建立（admin-web/ 與 admin-api/ 都存在且分支正確）
1. cd <workspace>/deploy                     # 從 new-admin-root 根進到 deploy/
2. cp .env.example .env  &&  vim .env       # 填入 secrets
3. docker compose build                      # 建 new-admin-rust-api + new-admin-base-web image
4. docker compose up -d postgres redis       # 起資料層
5. docker compose run --rm migration         # 跑一次 schema + seed
6. docker compose up -d new-admin-rust-api new-admin-base-web # 起 new-admin-rust-api + new-admin-base-web
7. docker compose ps                         # 檢查 healthcheck 全綠
```

預期 timeline：
- postgres / redis healthy：~30s
- migration 跑完：~5s
- new-admin-rust-api healthy：~15s
- new-admin-base-web ready：~3s

### 6.2 Migration 與 seed 資料

Sea-ORM migration 會跑 `migration/src/schemas/` 的 13 張表 + `migration/src/datas/` 的 7 個 seed：

| 表 | 用途 |
|---|---|
| `sys_user` | 預設 3 個帳號（Soybean/Administrator/GeneralUser），全用 argon2id 雜湊 |
| `sys_role` | 預設角色 |
| `sys_user_role` | user ↔ role 多對多 |
| `sys_menu` | 路由（即「動態 menu」資料源） |
| `sys_role_menu` | role ↔ menu 多對多 |
| `sys_domain` | 多租戶域；預設 `built-in` |
| `sys_endpoint` | 由 `process_collected_routes()` 啟動時自動填，不在 seed 裡 |
| `sys_organization` | 組織樹 |
| `sys_access_key` | API Key 管理 |
| `sys_login_log` / `sys_operation_log` | 日誌（startup 時空表） |
| `sys_tokens` | refresh / access token 軌跡 |
| `casbin_rule` | RBAC 政策表（由 sea-orm-adapter 管）|

> **預設管理員密碼**：3 個 seed user 共用同一個 argon2id 雜湊，依上游 `soybean-admin-rust` 慣例為 `Soybean@123.`（請務必登入後立即改密碼，或改 seed migration 後重建 DB）。

### 6.3 Casbin endpoint 自動註冊驗證

new-admin-rust-api boot 後 `router_initialization.rs:328 process_collected_routes()` 把所有掛載 router 的 path/method 寫入 `sys_endpoint` 表。第一次 boot 完跑：

```bash
docker compose exec postgres psql -U admin -d new_admin -c "SELECT path, method, controller, summary FROM sys_endpoint ORDER BY path;"
```

預期可看到 `/auth/login POST`、`/auth/getUserInfo GET`、`/route/getConstantRoutes GET`、`/role/* CRUD`、`/user/* CRUD` 等。沒看到代表 `process_collected_routes` 沒跑成功 → 看 `docker compose logs new-admin-rust-api`。

### 6.4 Smoke test（7 條 API + login flow）

```bash
BASE=http://localhost:8080/api

# 1. login
TOKEN=$(curl -s -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq -r '.data.token')
echo "TOKEN=$TOKEN"

# 2. getUserInfo
curl -s $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq

# 3. refresh token（確認 GAP-1 補完後）
REFRESH=$(curl -s -X POST $BASE/auth/login -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' | jq -r '.data.refreshToken')
curl -s -X POST $BASE/auth/refreshToken -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}" | jq

# 4. constant routes（不需 token）
curl -s $BASE/route/getConstantRoutes | jq

# 5. user routes
curl -s $BASE/auth/getUserRoutes -H "Authorization: Bearer $TOKEN" | jq

# 6. user list（驗證 Casbin enforce 對 super role 放行）
curl -s $BASE/user -H "Authorization: Bearer $TOKEN" | jq

# 7. 故意打沒權限的 path（驗證 Casbin 擋）
curl -s -o /dev/null -w "%{http_code}\n" \
  $BASE/some-non-existent-path -H "Authorization: Bearer $TOKEN"   # 期望 404 或 403
```

全部 200（response.code = 200, success = true）即整合成功。

---

## 7. 開發 vs 生產

### 7.1 開發模式（推薦工作流）

```bash
# Terminal 1：起 infra + new-admin-rust-api（在 new-admin-root 根）
cd <workspace>/deploy
docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration new-admin-rust-api

# Terminal 2：跑admin-web（host 端，在 admin-web/ worktree）
cd <workspace>/admin-web
pnpm install
pnpm dev   # vite dev server on :9527, proxy /proxy-default → http://localhost:10001
```

優點：
- admin-web hot reload < 1s
- vite devtools 可用
- DB 可直接從 host 連 5432（用 DBeaver 等）
- new-admin-rust-api 也可改成 host cargo watch（但通常不需要，images 改一次而已）

### 7.2 生產模式

```bash
cd <workspace>/deploy
docker compose build --pull
docker compose up -d
# 透過 http://your-host:8080 訪問
```

### 7.3 hot reload 策略

| 元件 | dev | prod |
|---|---|---|
| new-admin-base-web | vite dev server (HMR) | nginx static |
| new-admin-rust-api | docker compose restart（或 host 跑 `cargo watch -x run`） | image 重 build |
| migration | `cargo run -p migration -- up` | init container 自動 |

---

## 8. CI/CD outline（每個 repo 各一份 workflow）

> 本計畫採「傘狀 + 兩個 worktree」結構，CI 也分三處：
> - `fork260509-soybean-admin` 的 `new-admin-base-web` 分支：build new-admin-base-web Docker image → push ghcr
> - `fork260509-soybean-admin-rust` 的 `new-admin-rust-api` 分支：build rust Docker image → push ghcr
> - `new-admin-root`（傘狀）：lint compose、跑 e2e smoke（拉兩個 image 起來測 §6.4）

### 8.1 `new-admin-base-web` 分支 CI（push 到 fork260509-soybean-admin/.github/workflows/ci-base-web.yaml）

```yaml
name: build-base-web
on:
  push: { branches: [new-admin-base-web] }
  pull_request: { branches: [new-admin-base-web] }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v3
        with: { version: 10.5.0 }
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm typecheck && pnpm lint
      - run: pnpm build
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          tags: ghcr.io/${{ github.repository_owner }}/new-admin-base-web:${{ github.sha }}
          push: ${{ github.event_name == 'push' }}
```

### 8.2 `new-admin-rust-api` 分支 CI（push 到 fork260509-soybean-admin-rust/.github/workflows/ci-rust-api.yaml）

```yaml
name: build-rust-api
on:
  push: { branches: [new-admin-rust-api] }
  pull_request: { branches: [new-admin-rust-api] }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --check && cargo clippy -- -D warnings
      - run: cargo test --workspace
        env:
          DATABASE_URL: postgres://test:test@localhost:5432/test
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          tags: ghcr.io/${{ github.repository_owner }}/new-admin-rust-api:${{ github.sha }}
          push: ${{ github.event_name == 'push' }}
```

### 8.3 `new-admin-root` 傘狀 repo CI

```yaml
name: e2e
on:
  push: { branches: [main] }
  workflow_dispatch:

jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f deploy/compose.yaml config   # validate compose
      - name: pull pre-built images
        run: |
          docker pull ghcr.io/${{ github.repository_owner }}/new-admin-base-web:latest
          docker pull ghcr.io/${{ github.repository_owner }}/new-admin-rust-api:latest
      - name: start stack
        run: cd deploy && cp .env.example .env && docker compose up -d
      - name: smoke test
        run: bash deploy/scripts/smoke.sh
```

---

## 9. 風險、護欄、未來擴充

### 9.1 已知風險與緩解

| 風險 | 緩解 |
|---|---|
| `sys_tokens` 沒 expires_at 欄位 → refresh token 永不過期 | 加 migration 補欄位 + 在 refresh handler 檢查 |
| `process_collected_routes()` 是「啟動時 idempotent upsert」嗎？ | 需要驗證；若不是，多次 boot 會插重複 row。讀 `router_initialization.rs:328+` 確認 upsert 邏輯 |
| Rust 沒有 `/health` endpoint（compose healthcheck 要） | 在 `init_authentication_router` 加 `.route("/health", get(\|\| async { "ok" }))` 或在 `init_admin_router` 最外層加 |
| nginx 把 `/api/auth/login` proxy 到 rust 的 `/auth/login` 沒問題；但若上游 path 改變要小心 | 在 nginx 加註解 + e2e smoke test 涵蓋 |
| Casbin 對 super role `R_SUPER` 預設怎麼處理？ | Read `casbin_rule` seed migration 確認超級角色繞過邏輯 |
| admin-web `R_SUPER` 是 static 模式才生效（`VITE_AUTH_ROUTE_MODE=static`）；切 dynamic 行為不同 | dev 與 prod 都鎖 static、切 dynamic 時做完整回歸 |
| pnpm-workspace 在 Docker build 中要 mount 整個 admin-web/ 才能 resolve `@sa/*` workspace package | UI Dockerfile 已處理（先 COPY packages/ 再 install） |

### 9.2 護欄（dev 必備）

1. **Pre-commit**：`admin-web/` 的 simple-git-hooks 已設好（typecheck + lint + fmt）；server 加 `cargo fmt --check && cargo clippy`
2. **Smoke test 自動化**：把 §6.4 那段寫成 `deploy/scripts/smoke.sh`，CI 與 deploy 後都跑
3. **Secret 不進 git**：`.env` 進 `.gitignore`、`.env.example` 進 git
4. **DB backup**：每天 `docker compose exec postgres pg_dump` 排程
5. **Image 版本鎖**：postgres / redis / nginx 都鎖到 patch 版（避開 latest）

### 9.3 未來擴充路徑

| 階段 | 動作 |
|---|---|
| **第一階段**（now） | starter new-admin-base-web + new-admin-rust-api，跑通 7 條 API |
| **第二階段** | 移植 NestJS frontend 的 `system-manage.ts` 到 admin-web，開啟管理頁面（user/role/menu/endpoint） |
| **第三階段** | 加 HTTPS（nginx 加 SSL or 換 caddy） |
| **第四階段** | 加 Prometheus exporter（Rust 側用 `axum-prometheus`），Grafana dashboard |
| **第五階段** | 多 instance：把 nginx 換 traefik、new-admin-rust-api scale=N、postgres 改 streaming replication |
| **第六階段** | 多租戶實裝：啟用 `db_helper::get_named_connection`、每個 domain 一條 DB connection string |

---

## 附錄 A：完整環境變數總表

| 變數 | 用於 | 預設 | 說明 |
|---|---|---|---|
| `POSTGRES_DB` | postgres + new-admin-rust-api | `new_admin` | DB 名 |
| `POSTGRES_USER` | postgres + new-admin-rust-api | `admin` | DB 使用者 |
| `POSTGRES_PASSWORD` | postgres + new-admin-rust-api | (必填) | DB 密碼 |
| `REDIS_PASSWORD` | redis + new-admin-rust-api | (必填) | Redis 密碼 |
| `JWT_SECRET` | new-admin-rust-api | (必填) | JWT HS256 密鑰，至少 32 chars |
| `JWT_ISSUER` | new-admin-rust-api | github URL | JWT iss |
| `JWT_EXPIRE` | new-admin-rust-api | `7200` | access token TTL（秒） |
| `DATABASE_MAX_CONNECTIONS` | new-admin-rust-api | `10` | Sea-ORM pool size |
| `RUST_LOG` | new-admin-rust-api | `info` | 日誌等級 |
| `WEB_PORT` | new-admin-base-web | `8080` | host 對外 port |
| `TZ` | all | `Asia/Taipei` | 時區 |
| `VITE_*` | admin-web build | （見 §5.7/5.8） | admin-web build-time env |

## 附錄 B：完整檔案清單對照（worktree 模型）

由於採用 `git worktree`，沒有「複製檔案」這個動作 — 所有 Rust / UI 檔案**仍在原 fork repo**，只是新分支 `new-admin-base-web` / `new-admin-rust-api` 從 main 分歧出來，在分支上做改動。

### B.1 `new-admin-base-web` 分支（在 fork260509-soybean-admin 上）

| 檔案 | 動作 | 在哪個分支 |
|---|---|---|
| 整個專案結構 | 不動，從 main 分支繼承 | `new-admin-base-web` ⊂ `fork260509-soybean-admin` |
| `.env`、`.env.dev`、`.env.prod`（刪 `.env.test`） | 改寫對齊 Rust | `new-admin-base-web` |
| `src/service/api/auth.ts` | GAP-0f / GAP-2 修補 | `new-admin-base-web` |
| `src/service/api/route.ts` | GAP-4 路徑修正 | `new-admin-base-web` |
| `src/store/modules/route/index.ts` + `src/router/guard/route.ts` | GAP-3 改本地查 | `new-admin-base-web` |
| `Dockerfile`、`.dockerignore` | 新增 | `new-admin-base-web` |

### B.2 `new-admin-rust-api` 分支（在 fork260509-soybean-admin-rust 上）

| 檔案 | 動作 | 在哪個分支 |
|---|---|---|
| 整個 Cargo workspace | 不動，從 main 分支繼承 | `new-admin-rust-api` ⊂ `fork260509-soybean-admin-rust` |
| `admin-api/server/resources/application.yaml` → `application.yaml.tpl` | 改名 + 改用 envsubst | `new-admin-rust-api` |
| `admin-api/scripts/entrypoint.sh` | 新增 | `new-admin-rust-api` |
| `admin-api/Dockerfile` | 改造（加 migration binary 與 entrypoint） | `new-admin-rust-api` |
| `admin-api/server/model/src/admin/output/sys_authentication.rs` | GAP-0c + GAP-0d 修補 | `new-admin-rust-api` |
| `admin-api/server/api/src/admin/sys_authentication_api.rs` | GAP-0d 回 `buttons:[]` + GAP-1 refresh handler | `new-admin-rust-api` |
| `admin-api/server/{router,service,model}/.../sys_authentication*.rs` | GAP-1 補 refresh 整鏈 | `new-admin-rust-api` |
| 新 migration: `add_expires_at_to_sys_tokens.rs` | sys_tokens 加 expires_at 欄位 | `new-admin-rust-api` |
| health endpoint | 在 router 加 `/health` | `new-admin-rust-api` |

### B.3 `new-admin-root` 傘狀 repo（當前 workspace）

| 檔案 | 動作 |
|---|---|
| `CLAUDE.md` | 已建立（workspace 指引） |
| `.gitignore` | 已建立（排除 worktree 與源倉） |
| `docs/INTEGRATION-RESEARCH.md`、`docs/INTEGRATION-PLAN.md` | 已搬入 docs/ |
| `graphify-out/GRAPH_REPORT.md` | 圖譜報告唯一位置（docs/ 不放 symlink） |
| `graphify-out/{graph.json,GRAPH_REPORT.md,manifest.json,cost.json}` | graphify 產出 |
| `deploy/compose.yaml` | 待建（§5.1） |
| `deploy/compose.dev.yaml` | 待建（§5.2） |
| `deploy/nginx/default.conf` | 待建（§5.5） |
| `deploy/redis/redis.conf` | 待建（如要） |
| `deploy/.env.example` | 待建（§5.6） |
| `deploy/scripts/smoke.sh` | 待建（§6.4 內容寫成腳本） |
| `LICENSE`、`README.md` | optional |

## 附錄 C：10 個 GAP 修補檔案清單

| # | 檔案 | 動作 |
|---|---|---|
| 0a | `admin-web/.env.prod`、`admin-web/.env.dev` | `VITE_SERVICE_SUCCESS_CODE=200` |
| 0b | `admin-web/.env.prod`、`admin-web/.env.dev` | logout/expired/modal codes |
| 0c | `admin-api/server/model/src/admin/output/sys_authentication.rs` | 加 `#[serde(rename_all = "camelCase")]` |
| 0d | `admin-api/server/model/src/admin/output/sys_authentication.rs` + `admin-api/server/api/src/admin/sys_authentication_api.rs` | 加 `buttons: Vec<String>` 與 `buttons: vec![]` |
| 0e | `deploy/nginx/default.conf` | `/api/` location 已含 |
| 0f | `admin-web/src/service/api/auth.ts` | `userName` → `identifier` |
| 1 | `admin-api/server/{model,router,api,service}/.../sys_authentication*.rs` | 加 refresh handler（4 個檔案） |
| 2 | `admin-web/src/service/api/auth.ts` | 刪 `fetchCustomBackendError` |
| 3 | `admin-web/src/store/modules/route/index.ts` + `admin-web/src/router/guard/route.ts` | 改本地查 |
| 4 | `admin-web/src/service/api/route.ts` | `/route/getUserRoutes` → `/auth/getUserRoutes` |

## 附錄 D：來自上游 Rust README 的相關提示

`fork260509-soybean-admin-rust/README.md` 第 24-58 行明確指出：本後端原本配 **NestJS 前端**（不是 standalone admin）。upstream 提供 5 個 patch 把 NestJS 前端改用 Rust 後端：

1. `frontend/src/service/api/route.ts` 把 `/authorization/getUserRoutes` 改 `/auth/getUserRoutes` ← 對應本計畫 GAP-4
2. `frontend/src/service/api/system-manage.ts` Casbin rules 用 `${item.v2}:${item.v3}` 而非 `${item.v1}:${item.v2}`
3. `frontend/src/views/manage/role/modules/api-endpoint-auth-modal.vue` 改用 `${item.path}:${item.method}`
4. `frontend/src/typings/api.d.ts` `EnableStatus` 改小寫 `'enabled' | 'disable'`
5. enum record 對應改小寫

**結論**：第 2-5 條是 NestJS 前端才有的元件（system-manage page、api-endpoint-auth-modal）— standalone admin 沒有這些頁面，所以**不適用**。如果未來 §9.3 第二階段移植 system-manage.ts 過去，就會碰到第 2-5 條。

## 附錄 E：JSON response 對照表

**Rust `Res<T>`**：

```json
{ "code": 200, "data": { ... }, "msg": "success", "success": true }
```

**admin-web期望（VITE_SERVICE_SUCCESS_CODE=200 對齊後）**：

```ts
isBackendSuccess: response => String(response.data.code) === '200'   // ✓
```

**錯誤 response（Rust AppError）**：

```json
{ "code": 401, "data": null, "msg": "Unauthorized", "success": false }
```

對應admin-web `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` 觸發 refresh token 流程。

---

## 結語

本計畫覆蓋從 fork → 修 GAP → docker-compose 編排 → 第一次 boot → smoke test 全鏈路。10 個 GAP 中有 6 個是 1-2 行 env / 1-2 行 code 的微改、2 個是中等改動（refresh handler、isRouteExist 改本地查）、2 個是純 nginx 配置（CORS、reverse proxy）。

**最大的不可逆決策**：選 nginx 同源 vs Rust CorsLayer。同源讓 CORS 永遠不存在、image 多一個 nginx；CorsLayer 讓 admin-web 與 admin-api 可分離部署、prod 要小心設 origin allowlist。本計畫推薦同源。

**最大的「未引爆地雷」**：refresh token 沒 expires_at；migration 補一次 + handler 檢查即可。

**之後動手的最小起點**：
1. 在 `fork260509-soybean-admin` 開分支 + worktree：`cd fork260509-soybean-admin && git worktree add -b new-admin-base-web ../admin-web`
2. 在 `fork260509-soybean-admin-rust` 開分支 + worktree：`cd fork260509-soybean-admin-rust && git worktree add -b new-admin-rust-api ../admin-api`
3. 在 `new-admin-root` 根建 `deploy/` 與 `cp deploy/.env.example deploy/.env`，填密碼
4. 在 `admin-web/` worktree 修 GAP-0a/0b/0f 的 ~5 行（先驗證能 login）
5. `docker compose up`（從 deploy/ 內），跑 smoke test 第 1-2 條
6. 在 `admin-api/` worktree 修 GAP-0c/0d，跑第 3 條前先實作 GAP-1（refresh handler）
7. 全部 7 條 smoke 綠 = 整合成功
8. 各 worktree commit 後 `cd admin-web && git push -u origin new-admin-base-web`、`cd admin-api && git push -u origin new-admin-rust-api`
