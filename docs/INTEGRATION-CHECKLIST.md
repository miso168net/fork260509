# INTEGRATION-CHECKLIST — 整合進度追蹤

> 此檔記錄當前進度與 6-feature roadmap。每完成一個 feature 就更新狀態。
> 不放原則（原則在 `.specify/memory/constitution.md`）、不放規格（規格在 `specs/<###-feature>/`）、不放操作參考事實（如預設帳號在 CLAUDE.md §5）。

## 已完成里程碑

- [x] outer git init + push GitHub (`miso168net/fork260509@new-admin-root`)
- [x] 建立 worktree + submodule 配置（admin-web / admin-api 雙重身分；commits `07e6ba3`、CLAUDE.md §9 操作手冊）
- [x] 引入 spec-kit v0.8.7（commit `6209238`）
- [x] 制定 constitution v1.1.0（commits `73a4f17`、`22da195`；含 §III 合併例外條款）

## 6-feature roadmap

依 constitution §III 合併例外條款拆出：

| # | feature | 涵蓋 GAP | 倉/層 | 主題 | 規模 | spec | plan | impl | 狀態 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `deploy-infra` | (順帶 0e CORS) | outer | docker-compose + nginx + .env.example | 中 | ☐ | ☐ | ☐ | 待 |
| 2 | `gap-0ab0f-frontend-env-and-login` | 0a, 0b, 0f | admin-web | admin-web env 對齊 + login body field | 5-7 行 | ☐ | ☐ | ☐ | 待 |
| 3 | `gap-0cd-rust-output-camel` | 0c, 0d | admin-api | admin-api serialize 對齊 admin-web (camelCase) | ~5 行 | ☐ | ☐ | ☐ | 待 |
| 4 | `gap-1-refresh-handler` | 1 | admin-api | refresh token endpoint | ~80 行 | ☐ | ☐ | ☐ | 待 |
| 5 | `admin-web-cleanup` | 2, 3, 4 | admin-web | admin-api 對齊後的 admin-web 清理 | ~25 行 | ☐ | ☐ | ☐ | 待 |
| 6 | `dockerfile-envsubst` | (非 GAP) | admin-api | envsubst 模板化 | 中 | ☐ | ☐ | ☐ | 待 |

GAP 詳細描述見 `docs/INTEGRATION-PLAN.md §4`。

**建議實施順序**：1（基礎設施）→ 2（admin-web env 對齊）→ 3（admin-api 對齊）→ 驗 login（含 CDP）→ 4（refresh handler）→ 5（admin-web cleanup）→ 6（Dockerfile envsubst 收尾）。

## 跨 feature 的待驗證項

依 constitution §IV「上游驗證」規則，這些項目會在對應 feature 的 spec.md Assumptions 段帶上、實作時驗、驗完勾掉並回填結果：

- [ ] **驗證預設密碼是不是 `Soybean@123.`**（feature 1/2 第一次 login 時驗）
  - 驗完若正確 → 更新 CLAUDE.md §5 把「待驗證」字樣移除
  - 驗完若不同 → 更新 CLAUDE.md §5 密碼欄為實際值
- [ ] **驗證 `process_collected_routes()` 是 idempotent upsert**（feature 1 first/second boot 對比 sys_endpoint count）
- [ ] **驗證 Rust 是否有 `/health` endpoint**（feature 1 compose healthcheck 用；若無，feature 1 會順帶補 endpoint）
- [ ] **在 `sys_tokens` 表加 `expires_at` 欄位**（feature 4 refresh handler 需要 + migration）

## 維護指引

每次 feature 推進後，**在同一個 commit 內**更新本檔：

| 階段 | 改 roadmap 表的哪欄 |
|---|---|
| `/speckit-specify` 完成 | spec 欄改 ✅ |
| `/speckit-plan` 完成 | plan 欄改 ✅ |
| 實作 PR merge | impl 欄改 ✅、狀態欄改「完成」、加上實作 commit SHA |
| 上游驗證項勾掉 | 把對應勾選改 ✅、結果回填 CLAUDE.md（密碼）或 spec.md（其他） |

驗證證據（curl 輸出、psql 結果、cargo test log）放在 spec.md 或 plan.md 內，本檔僅勾選與簡述。
