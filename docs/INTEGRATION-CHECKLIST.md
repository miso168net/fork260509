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
| 6 | `dockerfile-envsubst` | (非 GAP) | admin-api | envsubst 模板化 + 吸收 retrospective review 三條 hardening：1-I1（redis healthcheck CMD-SHELL form）、1-I2（compose env wire APP_JWT_REFRESH_TOKEN_EXPIRE）、1-I3（JWT_ISSUER required gate） | 中-大 | ☐ | ☐ | ☐ | 待 |
| 8 | `gap-tz-1-timestamptz-migration` | (非原 GAP；retrospective review 4-I1) | admin-api | `sys_tokens.{expires_at, created_at, login_time}` TIMESTAMP → TIMESTAMPTZ schema migration + Rust 改用 `DateTimeWithTimeZone` + write-path 改 `Utc::now()` 避免 TZ skew | 中 | ☐ | ☐ | ☐ | 待 |

GAP 詳細描述見 `docs/INTEGRATION-PLAN.md §4`。

**建議實施順序**：1（基礎設施）→ 2（admin-web env 對齊）→ 3（admin-api 對齊）→ 驗 login（含 CDP）→ 4（refresh handler）→ 5（admin-web cleanup）→ 7（admin-web Dockerfile）→ 6（Dockerfile envsubst 收尾 + 吸收 retrospective hardening）→ 8（TZ-skew 根治）。

**更新後 8-feature roadmap**（feature 1-4 完成、剩 5-8）：5 / 7 / 6 / 8 順序視 priority 與 prod readiness 需求；4-I1 TZ-skew 是 silent prod risk 但當前 admin-api UTC container 內部一致、可排在 feature 6 之後。

## 跨 feature 的待驗證項

依 constitution §IV「上游驗證」規則，這些項目會在對應 feature 的 spec.md Assumptions 段帶上、實作時驗、驗完勾掉並回填結果：

- [x] **驗證預設密碼是不是 `Soybean@123.`** — ✅ **驗完為 `123456`**（T009 動態 acceptance 實測，2026-05-11；CLAUDE.md §5.1 已更新）
- [ ] **驗證 `process_collected_routes()` 是 idempotent upsert**（feature 1 first/second boot 對比 sys_endpoint count）
- [x] **驗證 Rust 是否有 `/health` endpoint** — ✅ **hotfix 8ae2432（admin-api inner）+ outer 93d728c**：feature 7 R5 verify 為 0 命中後，per constitution §VI(b) 救火例外補上；驗證 `docker compose up -d` 全 stack 自動 healthy
- [x] **在 `sys_tokens` 表加 `expires_at` 欄位** — ✅ **feature 4 完成**（admin-api inner commit `719ab75` migration + entity）

## Retrospective code review backlog（2026-05-11）

review 4 features 完成後留下的 backlog 條目：

| ID | Feature | 處理方式 | 備註 |
|---|---|---|---|
| 1-I1 | 001 | feature 6 一起做 | redis-cli healthcheck `CMD` form 用 `${REDIS_PASSWORD}` interpolated 不夠 robust，改 `CMD-SHELL` + `$$REDIS_PASSWORD` |
| 1-I2 | 001 | ✅ **已修**（hotfix b7a74b5） | `APP_JWT_REFRESH_TOKEN_EXPIRE` wire 進 compose.yaml；與 1-I4 同 hotfix 一併補 |
| 1-I3 | 001 | feature 6 一起做 | `JWT_ISSUER` 預設值 `https://github.com/your-org/new-admin` placeholder 可能 ship prod；改 required gate 或 sentinel |
| 1-I4 | 001 | ✅ **已修**（hotfix b7a74b5） | compose.yaml `new-admin-rust-api.environment` 全部 env vars 加 `APP_` 前綴（per admin-api `APP_` prefix + `_` separator config 約定）；F7-T010 dynamic acceptance 發現後立即 hotfix（per constitution §VI(b) 救火例外）；驗證：無 override 純 compose.yaml 起 stack 成功、`/api/auth/login` 200 + JWT |
| 1-M1~M5 | 001 | future hardening / 不阻塞 | postgres start_period / WebSocket header / gzip_proxied / 小 doc 漂移 |
| 2-M4 | 002 | feature 5 一起 evaluate | `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` 會讓 wrong-password 401 也觸發 refresh flow — admin-web 端 login error 路徑需 dedupe |
| 4-I1 | 004 | feature 8 解（已加進 roadmap） | TZ-skew column-type 範疇外 issue — schema-level TIMESTAMPTZ migration |
| 4-I2 | 004 | 觀察、不修 | `JwtConfig::get_config` 500 fallback 可能 silent regress；當前 startup ordering 正確、不修；future config refactor 時順帶評估 |
| 4-M2 ~ M5 | 004 | 部分已修 / minor | M2 已修（race comment 加在 b502528）；M3 map_err style 也順帶修；M4/M5 留作 future cleanup |
| 7-I1 | 007 | ✅ **已修**（hotfix admin-api 8ae2432 + outer 93d728c） | admin-api `/health` endpoint：directly `app.route("/health", get(\|\| async { "ok" }))` in `initialize_admin_router`，不走 add_route!（不污染 sys_endpoint）、不掛 auth/casbin（public probe）；返回 HTTP 200 "ok" |
| 1-I5 | 001 | ✅ **已修**（hotfix 7b05f11） | admin-api healthcheck `localhost` → `127.0.0.1`：alpine /etc/hosts 同時 map localhost 到 IPv4/IPv6，wget 可能先試 ::1，但 admin-api 只 bind 0.0.0.0 IPv4 → IPv6 連線 refused → healthcheck 失敗；改 127.0.0.1 直連避免 hostname 解析。7-I1 驗證時發現 |
| 7-M1 | 007 | future hardening | Dockerfile base image 用 floating minor tag（node:22-alpine, nginx:1.27-alpine），可進階 pin 到 digest 提升 true reproducibility |
| 7-M2 | 007 | future hardening | runtime 仍 master-as-root（nginx 預設）；加 `USER nginx` + 改 pid 路徑可進一步硬化（接觸面小，當前可接受） |
| 7-M3 | 007 | future / hygiene | outer .dockerignore 與 admin-web/.dockerignore 雙存；admin-web/.dockerignore 在 outer-root context 下無效但作 fallback；future 若 context 改回 admin-web/ 即可直用 |
| 7-M4 | 007 | future enhancement | OCI image labels 可加 `image.revision`（git SHA）+ `image.created`（build timestamp），透過 ARG 注入；當前 build 不便追溯產出對應 commit |
| 7-M5 | 007 | commit msg minor | a50eaa67 commit body 寫「6 個 VITE_*」實際 Dockerfile 為 5 個 VITE_* + 1 個 PNPM_VERSION（toolchain）；不 amend，記為歷史 |

## 維護指引

每次 feature 推進後，**在同一個 commit 內**更新本檔：

| 階段 | 改 roadmap 表的哪欄 |
|---|---|
| `/speckit-specify` 完成 | spec 欄改 ✅ |
| `/speckit-plan` 完成 | plan 欄改 ✅ |
| 實作 PR merge | impl 欄改 ✅、狀態欄改「完成」、加上實作 commit SHA |
| 上游驗證項勾掉 | 把對應勾選改 ✅、結果回填 CLAUDE.md（密碼）或 spec.md（其他） |

驗證證據（curl 輸出、psql 結果、cargo test log）放在 spec.md 或 plan.md 內，本檔僅勾選與簡述。
