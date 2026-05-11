# Implementation Plan: admin-api envsubst template + Hardening 收尾

**Branch**: `007-dockerfile-envsubst` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/007-dockerfile-envsubst/spec.md`

## Summary

把 admin-api `application.yaml` 替換成 `application.yaml.tpl`（envsubst template），admin-api/Dockerfile runtime stage 增 entrypoint script：(a) required env 預檢 + (b) `APP_JWT_ISSUER` sentinel rejection + (c) `envsubst < .tpl > .yaml` 渲染 + (d) `exec /bin/server`。runtime image 不含任何 hardcoded prod-like 預設（per constitution §II NON-NEGOTIABLE）。

順帶 hardening：1-I1（redis healthcheck CMD-SHELL）、1-M1（postgres start_period）、1-M2/M3（nginx WebSocket / gzip_proxied）、1-M4/M5（doc 漂移）。

**Scope**: admin-api 改動（Dockerfile + entrypoint.sh + application.yaml.tpl）+ deploy/ 改動（compose.yaml redis/postgres hardening、nginx default.conf hardening、.env.example）。**不動** admin-web。

## Technical Context

**Language/Version**: 無新語言；admin-api Rust 1.86 binary 不變；entrypoint 用 sh / busybox ash（alpine 預設）
**Primary Dependencies**: `gettext` (envsubst 提供者，`apk add --no-cache gettext`)；無新 Rust crate
**Storage**: N/A
**Testing**: 無新 unit test；驗證走 static acceptance（grep 命中數 / docker ls + cat）+ dynamic acceptance（重跑 feature 7 T010 五場景 + 新 fail-fast 場景）
**Target Platform**: Linux x86_64 容器（alpine 3.21 runtime）
**Project Type**: deploy artefact / config externalization
**Performance Goals**: SC-607 cold start ≤ 5 分鐘（與 feature 7 SC-701 對齊）
**Constraints**: §II 外部化 NON-NEGOTIABLE / §III 最小 GAP（envsubst 是 admin-api 範疇、redis/nginx hardening 是 deploy/ 範疇、可同 PR）/ §V 兩段式 commit
**Scale/Scope**: ~5 個檔（admin-api/Dockerfile + admin-api/entrypoint.sh + admin-api/server/resources/application.yaml.tpl + deploy/compose.yaml + deploy/nginx/default.conf + deploy/.env.example），~50-80 行 diff

## Constitution Check

| 條目 | 適用？ | 評估 |
|---|---|---|
| **§I 同源反代** | ✅ | 不變、不引入 CorsLayer、admin-api 容器內部 :10001 不對外 |
| **§II 外部化設定（NON-NEGOTIABLE）** | ✅ **本 feature 主軸** | 把 application.yaml → .tpl、entrypoint envsubst 渲染、`server/resources/` 不再有 application.yaml；secrets 改 required env gate；**完全達成** §II 規範 |
| **§III 最小 GAP** | ✅ | scope 控在 admin-api/{Dockerfile, entrypoint.sh, .tpl} + deploy/{compose, nginx, .env.example}；不夾帶 admin-web 改動；hardening 與 envsubst 同主題（部署設定）可合併 per §III 例外條款 2 |
| **§IV 上游驗證** | ✅ | R1-R6 全部用 read 既有 source / grep / docker compose up 驗證；無揣測 |
| **§V 兩段式 commit** | ✅ | admin-api 改動走 inner commit + push fork + outer SHA pin；deploy/ 改動屬 outer 直接 commit |
| **§VI Spec-Driven** | ✅ | specify + clarify Q1 + 本 plan + 後續 tasks/analyze/implement |
| **§VII Conventional Commits 中文** | ✅ | feat(admin-api) / fix(deploy) / chore(submodule) / docs |

**Gate 結論**：✅ PASS — 0 violation；`Complexity Tracking` 段不需填。

## Project Structure

### Documentation (this feature)

```text
specs/007-dockerfile-envsubst/
├── plan.md              # 本檔
├── spec.md
├── research.md          # Phase 0 R1-R6 解
├── data-model.md        # Phase 1 entities
├── quickstart.md        # implementer + operator
├── contracts/
│   └── entrypoint-contract.md   # entrypoint 之 input/output 契約
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks 產
```

### Source Code

```text
fork260509/                                ← outer
├── admin-api/                             ← submodule，本 feature 主動區
│   ├── Dockerfile                         ← 修：加 ENTRYPOINT、apk add gettext、COPY .tpl 取代 .yaml
│   ├── entrypoint.sh                      ← **新增**（runtime 階段 pre-validate + envsubst + exec）
│   └── server/
│       └── resources/
│           ├── application.yaml           ← **刪除**（per constitution §II）
│           ├── application.yaml.tpl       ← **新增**（envsubst template）
│           ├── application-test.yaml      ← 不動（dev mode 使用，cargo run 直讀）
│           ├── application-test.toml      ← 不動
│           ├── application-test.json      ← 不動
│           ├── ip2region.xdb              ← 不動
│           └── rbac_model.conf            ← 不動
├── deploy/                                ← feature 1 區，本 feature 部分動
│   ├── compose.yaml                       ← 修：redis healthcheck CMD-SHELL、postgres start_period、env required gate
│   ├── nginx/
│   │   └── default.conf                   ← 修：proxy Upgrade/Connection、gzip_proxied any
│   └── .env.example                       ← 修：APP_JWT_ISSUER 改 `change-me-issuer-url` placeholder
└── specs/007-dockerfile-envsubst/         ← 本 feature 規格
```

**Structure Decision**:
- admin-api/ submodule 內動 3 個檔（Dockerfile + entrypoint.sh 新檔 + application.yaml→.tpl rename）
- deploy/ 內動 3 個檔（compose.yaml + nginx/default.conf + .env.example）
- 兩段式 commit：admin-api inner 與 outer 各自 commit；outer chore(submodule) bump 一次

## Complexity Tracking

> 不適用 —— 0 violation。

---

## Phase 0：詳見 [research.md](./research.md)

R1-R6 全解：
- **R1**: admin-api 從 `server/resources/application.yaml` **相對 CWD** 讀（main.rs hardcode）；CWD = `/app`；entrypoint 寫 rendered file 到 `/app/server/resources/application.yaml`（appuser 已 chown 此目錄，可寫）
- **R2**: envsubst 未設 env 時 render 為空字串 → admin-api config crate 可能 parse 失敗或用 struct default。entrypoint **預先** validate required envs（FR-605）→ 不依賴 config crate 之 second-line defense
- **R3**: Dockerfile 已 `chown -R appuser:appuser /app`，entrypoint 以 appuser 身分執行 envsubst 寫入 `/app/server/resources/` OK
- **R4**: envsubst 純文字替換 `${VAR}`，不解析 yaml 結構；secret 值含 `:` `@` `$` 等字元安全（env 值內字元不被 envsubst 解析）
- **R5**: redis `--requirepass $X` 在 redis-server main process argv 暴露 password 屬 redis-server 既有 limitation —— 本 feature 只解決 **healthcheck argv** 暴露（CMD-SHELL form + `$$REDIS_PASSWORD` env interpolation）；main process argv 列入 doc 限制
- **R6**: hardcoded 值在 application.yaml 共 4 行（database.url / jwt.jwt_secret / jwt.issuer / redis.url）；application-test.yaml/toml/json 之 hardcoded 值**保留**（debug build only，prod 不 ship 該檔）

## Phase 1：詳見 [data-model.md](./data-model.md)、[contracts/](./contracts/)、[quickstart.md](./quickstart.md)

- **data-model.md**: 6 個 artefact entities（.tpl / entrypoint.sh / Dockerfile patches / compose.yaml patches / nginx patches / .env.example patches）
- **contracts/entrypoint-contract.md**: entrypoint script 對外契約（required envs / sentinel list / exit codes / output paths）
- **quickstart.md**: implementer 兩段式 commit + operator dynamic acceptance（重跑 feature 7 T010 + 新增 fail-fast 場景）

---

## Re-evaluate Constitution Check (post Phase 1)

- §I：不變 → ✅
- §II：✅ **完全達成**（image 內無 application.yaml、無 hardcoded 預設值、entrypoint envsubst render、secret env required）
- §III：✅ scope 控在 admin-api/ + deploy/ 6 個檔；hardening + envsubst 同 deploy 主題、可合併
- §IV：✅ R1-R6 evidence-based
- §V：✅ admin-api inner commit + outer SHA pin + outer deploy/ commits
- §VI：✅ spec/plan/tasks 流程
- §VII：✅ commit message 中文

**Post-Phase 1 Gate**：✅ PASS。

下一步：`/speckit-tasks` 產 tasks.md。
