# INTEGRATION-CHECKLIST — 整合進度追蹤

> 此檔記錄當前進度與 7-feature roadmap。每完成一個 feature 就更新狀態。
> 不放原則（原則在 `.specify/memory/constitution.md`）、不放規格（規格在 `specs/<###-feature>/`）、不放操作參考事實（如預設帳號在 CLAUDE.md §5）。

## 已完成里程碑

- [x] outer git init + push GitHub (`miso168net/fork260509@new-admin-root`)
- [x] 建立 worktree + submodule 配置（admin-web / admin-api 雙重身分；commits `07e6ba3`、CLAUDE.md §9 操作手冊）
- [x] 引入 spec-kit v0.8.7（commit `6209238`）
- [x] 制定 constitution v1.1.0（commits `73a4f17`、`22da195`；含 §III 合併例外條款）

## 7-feature roadmap

依 constitution §III 合併例外條款拆出：

| # | feature | 涵蓋 GAP | 倉/層 | 主題 | 規模 | spec | plan | impl | 狀態 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `deploy-infra` | (順帶 0e CORS) | outer | docker-compose + nginx + .env.example | 中 | ✅ | ✅ | ✅ | 完成 (3ff40de..1dbd3e9) |
| 2 | `gap-0ab0f-frontend-env-and-login` | 0a, 0b, 0f | admin-web | admin-web env 對齊 + login body field | 5-7 行 | ✅ | ✅ | ✅ | 完成 (b873f69..c86358f) |
| 3 | `gap-0cd-rust-output-camel` | 0c, 0d | admin-api | admin-api serialize 對齊 admin-web (camelCase) | ~5 行 | ✅ | ✅ | ✅ | 完成 (e5e912b..143574d) |
| 4 | `gap-1-refresh-handler` | 1 | admin-api | refresh token endpoint | ~80 行 | ✅ | ✅ | ✅ | 完成 (8c4e901..81b1a1a，admin-api inner 719ab75..b502528；含 retrospective review M1/4-M2 doc fixes) |
| 5 | `admin-web-cleanup` | 2, 3, 4 | admin-web | admin-api 對齊後的 admin-web 清理 | ~25 行 | ✅ | ✅ | ✅ | 完成 (05929e4..052748f，admin-web inner 29874dd3..7b167559) |
| 7 | `admin-web-dockerfile` | (非 GAP) | admin-web | multi-stage Dockerfile (pnpm build → nginx serve) | 中 | ✅ | ✅ | ✅ | 完成 (d8512ce..184e3ea + T010 evidence，admin-web inner a50eaa67..65f3060a；含 3 個 implementation discoveries + T010 dynamic 5/5 PASS via local compose.override workaround；發現 1-I4 critical bug 需 feature 6 fix) |
| 6 | `dockerfile-envsubst` | (非 GAP) | admin-api | envsubst 模板化 + 吸收 retrospective review 三條 hardening：1-I1（redis healthcheck CMD-SHELL form）、1-I2（compose env wire APP_JWT_REFRESH_TOKEN_EXPIRE，已 hotfix）、1-I3（JWT_ISSUER required gate） | 中-大 | ✅ | ✅ | ✅ | 完成 (0476962..後續，admin-api inner 766456f..cdf5a16，admin-web inner a31a869c；含 2 條 implementation discoveries：envsubst 不支援 ${VAR:-default} bash syntax + admin-web HEALTHCHECK IPv6 6-I2 同 1-I5) |
| 8 | `gap-tz-1-timestamptz-migration` | (非原 GAP；retrospective review 4-I1) | admin-api | `sys_tokens.{expires_at, created_at, login_time}` TIMESTAMP → TIMESTAMPTZ schema migration + Rust 改用 `DateTimeWithTimeZone` + write-path 改 `Utc::now()` 避免 TZ skew | 中 | ✅ | ✅ | ✅ | 完成 (admin-api inner 48a20bc；T017/T021/T025 acceptance evidence — SC-001/002/003/004/006 PASS) |

GAP 詳細描述見 `docs/INTEGRATION-PLAN.md §4`。

**建議實施順序**：1（基礎設施）→ 2（admin-web env 對齊）→ 3（admin-api 對齊）→ 驗 login（含 CDP）→ 4（refresh handler）→ 5（admin-web cleanup）→ 7（admin-web Dockerfile）→ 6（Dockerfile envsubst 收尾 + 吸收 retrospective hardening）→ 8（TZ-skew 根治）。

**8-feature roadmap 收尾**（feature 1-8 全完成）：實施順序為 1 / 2 / 3 / 4 / 5 / 7 / 6 / 8；4-I1 TZ-skew 於 feature 8 schema-level migration 根治（`sys_tokens` 三欄改 TIMESTAMPTZ + Rust `DateTimeWithTimeZone` + `Utc::now()`）。

## 跨 feature 的待驗證項

依 constitution §IV「上游驗證」規則，這些項目會在對應 feature 的 spec.md Assumptions 段帶上、實作時驗、驗完勾掉並回填結果：

- [x] **驗證預設密碼是不是 `Soybean@123.`** — ✅ **驗完為 `123456`**（T009 動態 acceptance 實測，2026-05-11；CLAUDE.md §5.1 已更新）
- [x] **驗證 `process_collected_routes()` 是 idempotent upsert** — ✅ **驗完 idempotent**（2026-05-11 feature 8 後補驗：sys_endpoint baseline count = 36；`docker compose restart new-admin-rust-api` ×1 後 = 36；再 restart ×1 後 = 36；3 次 observation 全部 0 duplicate `(path, method)` pair → upsert 邏輯正確、re-boot 不會 N×膨脹）
- [x] **驗證 Rust 是否有 `/health` endpoint** — ✅ **hotfix 8ae2432（admin-api inner）+ outer 93d728c**：feature 7 R5 verify 為 0 命中後，per constitution §VI(b) 救火例外補上；驗證 `docker compose up -d` 全 stack 自動 healthy
- [x] **在 `sys_tokens` 表加 `expires_at` 欄位** — ✅ **feature 4 完成**（admin-api inner commit `719ab75` migration + entity）

## Retrospective code review backlog（2026-05-11）

review 4 features 完成後留下的 backlog 條目：

| ID | Feature | 處理方式 | 備註 |
|---|---|---|---|
| 1-I1 | 001 | ✅ **已修**（feature 6 d4453e7） | redis healthcheck 改 CMD-SHELL form + `$$REDIS_PASSWORD` env interpolation；`docker inspect` healthcheck config 不再洩漏密碼 |
| 1-I2 | 001 | ✅ **已修**（hotfix b7a74b5） | `APP_JWT_REFRESH_TOKEN_EXPIRE` wire 進 compose.yaml；與 1-I4 同 hotfix 一併補 |
| 1-I3 | 001 | ✅ **已修**（feature 6 d4453e7 + admin-api a79837e） | compose.yaml `APP_JWT_ISSUER: ${APP_JWT_ISSUER:?must set ...}` required gate + admin-api entrypoint sentinel rejection（3 字串 exact-match：empty / github your-org URL / change-me-issuer-url）；雙層防護 |
| 1-I4 | 001 | ✅ **已修**（hotfix b7a74b5） | compose.yaml `new-admin-rust-api.environment` 全部 env vars 加 `APP_` 前綴（per admin-api `APP_` prefix + `_` separator config 約定）；F7-T010 dynamic acceptance 發現後立即 hotfix（per constitution §VI(b) 救火例外）；驗證：無 override 純 compose.yaml 起 stack 成功、`/api/auth/login` 200 + JWT |
| 1-M1~M5 | 001 | ✅ **已修**（feature 6 d4453e7） | postgres start_period 30s verify（既已 compliant）/ WebSocket header verify（既已 compliant）/ nginx gzip_proxied any 補上 / 小 doc 漂移 best-effort 修 |
| 6-I1 | 006 | ✅ **已修**（feature 6 cdf5a16） | F6-T014 發現：GNU envsubst 不支援 `${VAR:-default}` bash syntax；spec FR-603 wording error 已修；.tpl 4 處 fallback 改回 bare `${APP_VAR}` |
| 6-I2 | 006 | ✅ **已修**（feature 6 a31a869c） | F6-T014 發現：admin-web/Dockerfile HEALTHCHECK localhost → 127.0.0.1（同 1-I5 IPv6 同 root cause 同 fix pattern） |
| 2-M4 | 002 | feature 9 follow-up（新開、cross-feature review 2026-05-11 確診） | `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` 會讓 wrong-password 401 也觸發 refresh flow — admin-web 端 login error 路徑需 dedupe。2026-05-11 cross-feature review 重評：F5 spec.md FR-531 明示 MUST NOT 改、F5 沒解；目前 dormant 因 admin-api 實回 code:1003（不是 contracts/login-body.md §3 寫的 401）；contract 與 reality drift、stale refresh_token 在 localStorage 可能觸發 silent re-login。詳見下方 2-N1 |
| 4-I1 | 004 | ✅ **已修**（feature 8 admin-api inner `48a20bc`） | TZ-skew column-type 範疇外 issue — schema-level TIMESTAMPTZ migration；`sys_tokens.{expires_at, created_at, login_time}` 改 TIMESTAMPTZ、Rust entity 改 `DateTimeWithTimeZone`、write-path 改 `Utc::now().fixed_offset()`；ALTER USING `'Asia/Taipei'` 對齊 deploy/.env TZ；T017 SC-003 證明 3 個 session TZ 同 epoch instant |
| 4-I2 | 004 | ✅ **重評確認不可達**（2026-05-11） | `JwtConfig::get_config` 500 fallback：cross-feature review 重評 main.rs:17-21 → `initialize_config_with_multi_instance_env`（loads JwtConfig）→ `initialize_keys_and_validation`（reads JwtConfig）皆在 `initialize_admin_router`（line 30）+ `axum::serve` 之前。Router 未綁定前 JwtConfig 必已 in global registry，否則 JWT signing 整段壞、login 不可能 work → 500 路徑運行期不可達。風格可選收緊為 `.expect("JwtConfig must be initialized...")`、非必要 |
| 4-M2 ~ M5 | 004 | 部分已修 / minor | M2 已修（race comment 加在 b502528）；M3 map_err style 也順帶修；M4/M5 留作 future cleanup |
| 7-I1 | 007 | ✅ **已修**（hotfix admin-api 8ae2432 + outer 93d728c） | admin-api `/health` endpoint：directly `app.route("/health", get(\|\| async { "ok" }))` in `initialize_admin_router`，不走 add_route!（不污染 sys_endpoint）、不掛 auth/casbin（public probe）；返回 HTTP 200 "ok" |
| 1-I5 | 001 | ✅ **已修**（hotfix 7b05f11） | admin-api healthcheck `localhost` → `127.0.0.1`：alpine /etc/hosts 同時 map localhost 到 IPv4/IPv6，wget 可能先試 ::1，但 admin-api 只 bind 0.0.0.0 IPv4 → IPv6 連線 refused → healthcheck 失敗；改 127.0.0.1 直連避免 hostname 解析。7-I1 驗證時發現 |
| 7-M1 | 007 | future hardening | Dockerfile base image 用 floating minor tag（node:22-alpine, nginx:1.27-alpine），可進階 pin 到 digest 提升 true reproducibility |
| 7-M2 | 007 | future hardening（**internet-facing 應升 Important**） | runtime 仍 master-as-root（nginx 預設）；2026-05-11 cross-feature review 重評：若 admin SPA 將 internet-facing prod 部署、priority 應升 Important。Workers 已 drop 到 nginx user（驗證 `Config.User` 空 + nginx.conf `user nginx`），但 master-as-root 是 container-hardening checklist 項。Fix: 換 `nginxinc/nginx-unprivileged` base image（1 行 FROM swap + EXPOSE 8080 + HEALTHCHECK port 改 8080） |
| 7-M3 | 007 | future / hygiene | outer .dockerignore 與 admin-web/.dockerignore 雙存；admin-web/.dockerignore 在 outer-root context 下無效但作 fallback；future 若 context 改回 admin-web/ 即可直用 |
| 7-M4 | 007 | future enhancement | OCI image labels 可加 `image.revision`（git SHA）+ `image.created`（build timestamp），透過 ARG 注入；當前 build 不便追溯產出對應 commit |
| 7-M5 | 007 | commit msg minor | a50eaa67 commit body 寫「6 個 VITE_*」實際 Dockerfile 為 5 個 VITE_* + 1 個 PNPM_VERSION（toolchain）；不 amend，記為歷史 |

## Cross-feature review backlog（2026-05-11 補）

8-feature 全跑完後對 `001-deploy-infra` ~ `008-gap-tz-1-timestamptz-migration` 做的跨 feature code review（用 `superpowers:requesting-code-review` 8 個 reviewer subagent 並行對照各 feature spec.md）新發現的條目。0 個 Critical、6 個 Important、5 個 Future/Minor。詳細 review 報告見對話 history。

| ID | Feature | 處理方式 | 備註 |
|---|---|---|---|
| 1-N1 | 001 | TBD（Important） | redis healthcheck 認證實質失效：compose.yaml:50 `test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]`，但 redis service `environment:` 內**無** `REDIS_PASSWORD` env var、容器內 `$$REDIS_PASSWORD` 展開為空字串；redis 7 預設允許 PING 不需 AUTH → healthcheck 永遠 PONG、無法偵測配錯密碼。Fix: redis.environment: 加 `REDIS_PASSWORD: ${REDIS_PASSWORD}` |
| 1-N2 | 001 | TBD（Important docs） | `specs/001-deploy-infra/contracts/env-variables.md` drift：仍列 `JWT_ISSUER`（無 prefix）作 optional 並給 GitHub URL default、實際 `.env.example` + compose.yaml 已是 `APP_JWT_ISSUER` required（feature 6 absorb 1-I3 後）；`APP_JWT_REFRESH_TOKEN_EXPIRE` 完全沒列。Fix: 契約檔同步到實際 |
| 2-N1 | 002 | feature 9 follow-up | （= 2-M4 確診擴寫）feature 9 需解 3 件事：(1) 改寫 `specs/002-gap-0ab0f-frontend-env-and-login/contracts/login-body.md §3` 為 ground truth（1001/1002/1003 for pwd_login failures、401 reserved for token middleware）+ 同步 FR-204；(2) admin-web `auth/index.ts` login 加 `skipAuthRefresh` config flag（~10 LOC）讓 `request/index.ts` `onBackendFail` + `onError` 在 login context 不走 expiredTokenCodes 分支；(3) `handleRefreshToken` 加 early-return when `localStg.get('refreshToken')` empty（~3 LOC、kill stale-token silent re-login 風險） |
| 4-N1 | 004 | future minor 加固 | READ COMMITTED 下 refresh in-txn re-SELECT 非完全 atomic：兩個 thread 並發、在彼此 commit 前 start txn 都看到 ACTIVE row、都 INSERT 新 ACTIVE row → end state **2 個 ACTIVE row** 對同一 user_id（UPDATE 舊 row 為 REFRESHED 是 idempotent）。非 data corruption / security breach（用戶取得 2 個 working token），但 invariant violation。Fix: `SysTokens::find().lock_exclusive()` 在 in-txn re-SELECT 加 row-level lock（1 行 sea-orm API） |
| 4-N2 | 004 | 觀察 / 文件化 | refresh handler context audience 硬編 `ManagementPlatform`；若 admin-api 未來服務第二 audience（如 mobile client）→ refresh silently 轉換 audience。當前 single-audience by design、N/A。Fix 選項：(a) audience 存 sys_tokens 表 + refresh 讀回（schema-level）(b) spec 明寫 single-audience（doc-level） |
| 6-N1 | 006 | docs sync | `specs/007-dockerfile-envsubst/contracts/entrypoint-contract.md §1.3` 仍寫「defaults 由 .tpl 內 `${VAR:-default}` 提供（envsubst 支援）」— 6-I1 發現 GNU envsubst 不支援 `:-` 後 .tpl 已改 bare `${VAR}` + 改由 compose.yaml `:-` substitution 提供；spec FR-603 已更新但 contract 漏更。Fix: 契約檔同步 |
| 7-M6 | 007 | future nginx hardening | nginx response 回 `Server: nginx/1.27.5` patch version leak（T010 Scenario 5 confirm）；fix: `deploy/nginx/default.conf` 加 `server_tokens off;` |
| 7-M7 | 007 | future nginx hardening | nginx 無 security headers（X-Content-Type-Options / X-Frame-Options / Referrer-Policy / CSP / HSTS）；admin SPA 經 TLS 終端 proxy prod 部署需求；fix: `default.conf` `add_header` directives（admin SPA 也可 meta-tag inject CSP） |
| 8-N1 | 008 | docs sync | F8 acceptance evidence 3 檔（`acceptance-evidence/T017-tz-skew-repro.md` / `T021-functional.md` / `T025-schema-preserve.md`）header 記 admin-api inner SHA `cdf5a16`（pre-F8、無 m20260512_000000 migration）；實際 evidence 內容（timestamptz 欄 + `+08` offset + Utc::now() 寫入）對應 `48a20bc`。Root cause: evidence 在 worktree 帶未 commit F8 改動時收集、`git rev-parse HEAD` 仍回舊值。Fix: 3 個 header 改 `48a20bc` 或加 parenthetical 註明 |
| 8-M5 | 008 | future F9 prep | `admin-api/server/resource/templates/service.rs.askama` codegen template 仍用 `Local::now().naive_local()` pattern；未來 F9 sweep 其他 9 表（sys_user/role/menu/domain/endpoint/access_key/organization/login_log/operation_log）改 TIMESTAMPTZ 時、若不順帶修 template → pattern 在新生成 service 檔 silently 再生 |
| 0-process | 跨 feature | future process refinement | `speckit-implement` workflow 應在 acceptance evidence collection 階段 record `git rev-parse HEAD` at 命令執行當下（不是 retrospectively 從 commit 推回）、避免 8-N1 那種 SHA stale class 錯誤再發生 |
| 1-M-cache | 001 | future minor cache | outer `.dockerignore` 沒擋 `admin-web/Dockerfile` 本身 → Dockerfile 編輯會 invalidate `COPY admin-web/` layer cache。Real impact 小（COPY 在 install 之後、且 Dockerfile 改動本來就值得 rebuild）；接觸面小、可選 |

## Repo health backlog（2026-05-11 verification 發現）

執行 `superpowers:verification-before-completion`（跑 全 admin-api `cargo clippy/test` + admin-web `pnpm typecheck/lint/build`）發現的 pre-existing repo 健康問題。**全部不是 features 1-8 引入**（git blame 確認均早於 feature 1）；canonical container build path（`docker compose build`）仍 PASS、運行期不受影響。這些是「想跑 host-side 完整驗證會撞到」的問題。

| ID | 範疇 | 處理方式 | 備註 |
|---|---|---|---|
| R-clippy-ptr_arg | admin-api / server-utils | 1 行 fix | `admin-api/server/utils/src/tree_util.rs:180` `nodes: &mut Vec<T>` → `&mut [T]`（clippy::ptr_arg）；`.cargo/config.toml:54` 設 `-D warnings` 把 clippy 所有 warning 升 error，這 1 個 ptr_arg violation 阻擋整個 workspace 的 `cargo clippy` 通過。git blame 確認 `7f0564f` initial add（早於 feature 1）。Fix: 改 signature 為 slice |
| R-clippy-lifetimes | admin-api / sea-orm-adapter（dep crate） | 中等 / 上游 patch | `admin-api/sea-orm-adapter/src/action.rs:140-152` 等 7 處 `clippy::needless_lifetimes` 違反；同樣被 `.cargo/config.toml -D warnings` 升 error → 阻擋 workspace clippy。sea-orm-adapter 是 path dep（在 admin-api repo 內、不是 crates.io）→ 可直接 patch 或等上游升版 |
| R-axum-version-conflict | admin-api / axum-casbin tests | 中等 / Cargo.toml dep alignment | `admin-api/axum-casbin/tests/{test_middleware,test_middleware_domain,test_set_enforcer}.rs` 編譯 fail：dep tree 同時引入 `axum_core 0.4.5`（axum-casbin 自己用）+ `axum_core 0.5.2`（axum-test-helpers 0.8.0 拉的）→ 兩個 `Body` 型別不相容、TestClient::new() 不能 accept axum-casbin 的 Router。Fix 選項：(a) axum-test-helpers 降版對齊 0.4 (b) axum-casbin 升版用 axum 0.5 (c) workspace `[patch.crates-io]` force-align axum_core 版本 |
| R-pnpm-flatten | admin-web / pnpm 11 monorepo | env / future feature 7 後續 | host `pnpm install` 後 `axios` / `@iconify/utils` / `@unocss/core` / `@unocss/preset-mini` 等 transitive deps 沒進 root node_modules（pnpm 11 stricter resolution + `shamefully-hoist=true` 沒涵蓋這些）→ `pnpm typecheck`（15 errors） / `pnpm build`（fail）host 都跑不過。F5 T008-static.md `(f)` 段已記、F7 docker container build path 為 canonical 解法（已驗證 PASS）。Fix 選項：(a) 確認 pnpm-workspace.yaml + 個別包的 dependencies 結構 (b) 把 transitive deps explicit lift 到 root package.json (c) 接受 host-only env 限制、container build 作為 canonical gate |
| R-eslint-v10-migration | admin-web / eslint config | docs / config migration | `npx eslint .` fail：ESLint v10 預設用 `eslint.config.js`（flat config）、project 仍用舊 `.eslintrc.*` 格式 → ESLint v10 拒絕 load。`oxlint` 不受影響、仍 PASS（0/0 over 233 files）。Fix: migration guide https://eslint.org/docs/latest/use/configure/migration-guide；轉成 flat config eslint.config.js |

> 註：以上 5 條都不是 features 1-8 引入的；F8 acceptance evidence 與 spec / code reviews 全 PASS（F8 modified file 0 命中在任何 clippy / test 錯誤訊息）。但若要把 host-side `cargo clippy` / `cargo test --workspace` / `pnpm typecheck/build/eslint` 開為 CI gate、這 5 條都得解。

## 維護指引

每次 feature 推進後，**在同一個 commit 內**更新本檔：

| 階段 | 改 roadmap 表的哪欄 |
|---|---|
| `/speckit-specify` 完成 | spec 欄改 ✅ |
| `/speckit-plan` 完成 | plan 欄改 ✅ |
| 實作 PR merge | impl 欄改 ✅、狀態欄改「完成」、加上實作 commit SHA |
| 上游驗證項勾掉 | 把對應勾選改 ✅、結果回填 CLAUDE.md（密碼）或 spec.md（其他） |

驗證證據（curl 輸出、psql 結果、cargo test log）放在 spec.md 或 plan.md 內，本檔僅勾選與簡述。
