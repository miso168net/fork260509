# Contract: Environment Variables

**Feature**: `001-deploy-infra`
**Owners**: outer repo `deploy/.env.example` 為 source of truth；下游 admin-api、admin-web、nginx 為 consumer。

> 本契約規範 `.env.example` 與 compose.yaml 之間的變數傳遞，並標明每個變數的 consumer 與 fallback 策略。違反此契約 = 違反 spec FR-130~134。

---

## 必填變數（4 個）— 用 `${VAR:?must set VAR}` 強制

| Var | 類型 | 範例值（`.env.example` 寫法） | Consumer | Fallback | 驗證規則 |
|---|---|---|---|---|---|
| `POSTGRES_PASSWORD` | string | `change-me-strong-password` | postgres image (POSTGRES_PASSWORD env)、new-admin-rust-api（組 DATABASE_URL）、migration（同） | **無**（缺則 compose 直接 abort） | ≥ 12 字元、含大小寫+數字+符號（建議；compose 不強制） |
| `REDIS_PASSWORD` | string | `change-me-redis-password` | redis（`--requirepass`）、new-admin-rust-api（組 REDIS_URL） | 無 | ≥ 16 字元、隨機（建議） |
| `JWT_SECRET` | string | `change-me-jwt-secret-at-least-32-chars` | new-admin-rust-api（簽 JWT） | 無 | ≥ 32 字元（HS256 安全下限） |
| `TZ` | IANA timezone | `Asia/Taipei` | postgres / redis / new-admin-rust-api 三個 service 的 TZ env | 無（為了強制 operator 顯式選） | 必須是有效 IANA tz（如 `Asia/Taipei` / `UTC` / `Europe/London`） |

**為何 TZ 改必填**：原 INTEGRATION-PLAN §5.1 用 `${TZ:-Asia/Taipei}`（可選 + fallback）。本 contract 升為必填，理由：跨地區部署 / log timestamp 對齊 / postgres 內 TIMESTAMP 行為一致性，三者任一錯了都難排查；強制顯式設定避免「忘記改」。

---

## 可選變數（≥ 8 個）— 用 `${VAR:-default}` 提供 fallback

| Var | 類型 | Default | Consumer | 用途 |
|---|---|---|---|---|
| `POSTGRES_DB` | string | `new_admin` | postgres / new-admin-rust-api / migration | 資料庫名 |
| `POSTGRES_USER` | string | `admin` | 同上 | 資料庫超級使用者（dev 用；prod 應改 application 用 user） |
| `WEB_PORT` | int | `8080` | new-admin-base-web 對外 port | 對外 HTTP 入口 port |
| `RUST_LOG` | string | `info` | new-admin-rust-api | log level（trace/debug/info/warn/error） |
| `JWT_EXPIRE` | int (秒) | `7200` | new-admin-rust-api | access token TTL |
| `DATABASE_MAX_CONNECTIONS` | int | `10` | new-admin-rust-api | Sea-ORM pool 上限（admin tool 流量低，10 夠用） |
| `JWT_ISSUER` | URL | `https://github.com/your-org/new-admin` | new-admin-rust-api | JWT iss claim |
| `VITE_APP_TITLE` | string | `NewAdmin` | new-admin-base-web Dockerfile build args | 瀏覽器 tab title |
| `VITE_AUTH_ROUTE_MODE` | enum | `static` | 同上 | `static`（前端定義路由）/ `dynamic`（後端推路由） |
| `VITE_STATIC_SUPER_ROLE` | string | `R_SUPER` | 同上 | 靜態模式下的 super role code |

> dev override 不引入新變數，但會用相同 `.env`（pgsql / redis / new-admin-rust-api 三個 service 在 dev 模式下對 host 暴露 port，仍從同一 `.env` 讀 PASSWORD 等）。

---

## 變數 Lifecycle

```
.env.example  (committed, in deploy/.env.example)
     │
     ├──[operator copy]──> .env  (gitignored, in deploy/.env)
     │
     │   ┌────────────[compose 啟動時 read]──────────────┐
     │   │                                              │
     ▼   ▼                                              ▼
 build args (VITE_*)                              runtime env (POSTGRES_*, REDIS_*, JWT_*)
     │                                                  │
     ▼                                                  ▼
 new-admin-base-web image (vite 固化)              new-admin-rust-api / postgres / redis container
                                                        │
                                                        ▼
                                              （feature 6 完成後）envsubst → application.yaml
```

**關鍵時序**：
- VITE_* 是 **build-time**（Dockerfile 用 ARG + ENV 接，vite build 時固化進 dist），改 VITE_* 必須 rebuild image 才生效。
- 其他變數是 **runtime**（compose 啟動時讀 .env、塞 container env），改後 `docker compose restart <service>` 即可生效（new-admin-rust-api 還需要 envsubst 重渲 yaml，feature 6 處理）。

---

## 變更政策

- **新增變數**：先在 `.env.example` 加並標明必填/可選 + Consumer + 用途、再在 compose.yaml 加引用、最後在本 contract 表更新一行。
- **改 default 值**：必須在本 contract 寫變更歷程（記日期 + 改動原因 + 影響面）；若是必填變數的 default 改為「無」反之亦然，視為 breaking change，需新 spec。
- **移除變數**：把該變數從 .env.example 與 compose.yaml 一併刪、本 contract 表移除該行；若 consumer（admin-api / admin-web）仍引用，視為 breaking change，需協調對應 feature。

---

## Validation 指令（給 task 階段引用）

```bash
# 必填變數用 :? 強制
test "$(grep -cE '\$\{(POSTGRES_PASSWORD|REDIS_PASSWORD|JWT_SECRET|TZ):\?' deploy/compose.yaml)" -ge 4 \
  && echo "PASS: 4 個必填變數都用 :? 強制" \
  || echo "FAIL: 必填變數未全用 :? 強制"

# 可選變數用 :- 提供 fallback（抽 5 個 spot check）
for var in POSTGRES_DB POSTGRES_USER WEB_PORT RUST_LOG JWT_EXPIRE; do
  grep -qE "\\\$\\{${var}:-" deploy/compose.yaml \
    && echo "PASS: $var 有 fallback" \
    || echo "FAIL: $var 缺 fallback"
done

# .env.example 不含真實 secret
! grep -qE '(password|secret).*[a-zA-Z0-9]{32,}' deploy/.env.example \
  && echo "PASS: .env.example 無真實 secret" \
  || echo "FAIL: .env.example 疑似有真實 secret"

# .env 在 .gitignore（防止意外 commit）
git check-ignore -q deploy/.env \
  && echo "PASS: deploy/.env 被 gitignore" \
  || echo "FAIL: deploy/.env 沒被 gitignore（高風險！）"
```
