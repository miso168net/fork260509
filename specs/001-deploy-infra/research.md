# Phase 0 Research: deploy-infra

**Feature**: `001-deploy-infra`
**Date**: 2026-05-11
**Purpose**: 解 spec 已通過 `/speckit-clarify` 後仍剩的 plan-level unknowns，並把 constitution §IV 上游驗證項落為具體指令。

> 本檔目標是補 plan 決策的「為何選此方案」+「驗證指令具現化」，避免重複 `docs/INTEGRATION-PLAN.md §5` 既有的 yaml 範例內容。

---

## R1: Compose v2 dependency model（service_healthy / service_completed_successfully）

**Decision**: 採 `depends_on` 的 long-form `condition` 語法（v2 標準）：

```yaml
depends_on:
  postgres:
    condition: service_healthy
  redis:
    condition: service_healthy
  migration:
    condition: service_completed_successfully
```

**Rationale**:
- `service_healthy` 強制等 healthcheck 連續綠才推進，比舊版 `depends_on: [postgres]` 純啟動順序更可靠。
- `service_completed_successfully` 是 init container 模型的關鍵：new-admin-rust-api 必須等 migration `Exited (0)` 後才起，避免「app 啟動時 schema 還沒就緒」的 race。
- 失敗回饋：若 migration `Exited (1)`，compose 會 abort 整個 stack，operator 立即看到錯誤；不會讓 new-admin-rust-api 在 schema 缺失下啟動。

**Alternatives considered**:
- `restart: on-failure` 讓 new-admin-rust-api 自己 retry 等 schema：拒絕。增加非確定性、log 雜訊、不利診斷。
- 用 `wait-for-it.sh` 在 entrypoint 等 DB：拒絕。compose v2 原生 `service_healthy` 已蓋此案例，多一層 sh script 增加維護面。

**Compose 最低版本**: v2.20+（`service_completed_successfully` 自 2022 年起穩定可用；現代 Docker Desktop / Linux package 皆已涵蓋）。在 plan 將 `compose.yaml` 加註釋說明此最低需求。

---

## R2: Healthcheck 推薦值（postgres / redis / new-admin-rust-api）

**Decision**:

| Service | test | interval | timeout | retries | start_period |
|---|---|---|---|---|---|
| postgres | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` | 10s | 5s | 10 | 30s |
| redis | `redis-cli -a $REDIS_PASSWORD ping` | 10s | 5s | 10 | 5s |
| new-admin-rust-api | `wget -q -O - http://localhost:10001/health` | 15s | 5s | 5 | 30s |

**Rationale**:
- **postgres** `start_period: 30s`：alpine image 冷啟動 + initdb 約 15-25 秒，30 秒留 buffer 避免假性失敗。`retries: 10` × `interval: 10s` = 100 秒給最惡劣 case。
- **redis** `start_period: 5s`：alpine image 啟動非常快（< 2 秒）。
- **new-admin-rust-api** `start_period: 30s`：Rust release binary 啟動 + DB pool 連線約 5-15 秒，30 秒 buffer；`interval: 15s` 比資料層長，因為 new-admin-rust-api 重啟昂貴。
- 對齊 SC-004「migration ≤ 30 秒總耗時」：postgres healthy（30s）+ migration 跑完（< 5s）= ≤ 35s，留 5s margin。

**Alternatives considered**:
- 用 `HEALTHCHECK` 寫在 image Dockerfile：拒絕。compose 層集中管理 healthcheck 較易調整（不需要 rebuild）。本 feature 只動 outer，符合此原則。
- start_period 一律 60s：拒絕。redis 5 秒就 ready，60s 是浪費 onboarding 時間（違反 SC-001 ≤ 10 分鐘目標）。

---

## R3: nginx → docker service-name DNS 解析

**Decision**: nginx conf 直接寫 `proxy_pass http://new-admin-rust-api:10001/`，不寫 IP，靠 docker embedded DNS（127.0.0.11）解析 service short name。

**Rationale**:
- Docker compose v2 在每個 user-defined network（admin-net）內為所有 service 自動註冊 short name DNS（`new-admin-rust-api`、`postgres` 等）+ FQDN（`new-admin-rust-api.admin-net`）。
- nginx 1.27 alpine 預設 resolver 從 `/etc/resolv.conf` 取，container 內這就是 `127.0.0.11` → docker DNS。

**Edge case**: nginx 啟動時 new-admin-rust-api **還沒就緒** → nginx 會在第一個 request 時 DNS resolve、若 service 還沒起就回 502。不會 nginx 啟動失敗。
- 對策：nginx service 不需要 `depends_on: new-admin-rust-api`（讓 nginx 先起，502 由 healthcheck `/health`（nginx 自己的 200 ok）保證 nginx 仍 healthy）。
- 但 spec FR-114 / INTEGRATION-PLAN §5.1 仍把 new-admin-base-web `depends_on: new-admin-rust-api: service_healthy` —理由：避免 nginx 啟動後馬上有大量 502，給 user 較好 UX。

**Alternatives considered**:
- nginx conf 用 `resolver 127.0.0.11 valid=10s;` + `set $upstream "http://new-admin-rust-api:10001";` + `proxy_pass $upstream;`：解 service 重啟時 DNS cache 失效問題。**未採用**（new-admin-rust-api 重啟頻率低、且 docker DNS 本來就會更新；增加 conf 複雜度）。如未來觀察到 stale DNS 問題再加。

---

## R4: Migration idempotency（spec assumption #2 待驗證項）

**Decision**: Sea-ORM `MigratorTrait::up` 對已套用的 migration 會跳過（依 `seaql_migrations` 表的 record 判斷），對 seed data 的處理依該 migration 自身寫法決定。

**Verification 指令**:

```bash
# 第一次跑
docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis
docker compose run --rm migration   # 預期 Exited (0)
docker compose exec postgres psql -U admin -d new_admin -c "SELECT version, applied_at FROM seaql_migrations ORDER BY applied_at;"
COUNT_FIRST=$(docker compose exec postgres psql -U admin -d new_admin -t -c "SELECT count(*) FROM sys_user;")

# 第二次跑（idempotent 驗證）
docker compose run --rm migration   # 應 Exited (0) 且 stdout 包含「nothing to do」之類
COUNT_SECOND=$(docker compose exec postgres psql -U admin -d new_admin -t -c "SELECT count(*) FROM sys_user;")

# Assertion
test "$COUNT_FIRST" = "$COUNT_SECOND"   # 必相等（不應重複 insert seed）
```

**Rationale**: 此 verification 對應 spec US1 acceptance scenario #3。若不 idempotent，operator 第二次部署會破壞既有資料 — production 風險。

**Alternatives considered**:
- 跑 migration 前先 `DROP DATABASE` 確保 clean state：拒絕。production 不可用、dev 也煩。應該設計 migration 本身 idempotent（責任在 admin-api 倉的 seed migration 寫法，feature 1 只負責驗證）。

**Risk note**: 若驗證失敗 → 上報 admin-api 倉的 issue，可能要調整 seed migration 用 `ON CONFLICT DO NOTHING`。本 feature 不主動修補，只 detect。

---

## R5: Compose project name 隔離

**Decision**: 在 `compose.yaml` 頂層宣告 `name: new-admin-root`，不依賴 directory name 自動推導。

**Rationale**:
- Compose v2 預設 project name = 目錄名（小寫、特殊字元 → `_`）。如 operator 把 repo clone 到不同目錄（`/srv/admin/`、`my-admin/`），會產生不同 project namespace、container name 衝突 / 重複建立 volume。
- 顯式 `name: new-admin-root` 確保跨機器一致：`docker container ls | grep new-admin-root` 在所有 host 上都能正確過濾。
- 與 INTEGRATION-PLAN §5.1 範例對齊。

**Verification**:
```bash
docker compose -f compose.yaml config | head -3   # 應顯示 "name: new-admin-root"
```

**Alternatives considered**:
- 讓 operator 用 `COMPOSE_PROJECT_NAME` env 自訂：拒絕。增加 onboarding 變數、且不同 operator 設不一致會導致誤連 stack（spec edge case 第二項就是擔心這個）。

---

## R6: Dev override 的 profile / never 模式

**Decision**: `compose.dev.yaml` 用 `profiles: ["never"]` 排除 new-admin-base-web，搭配 `compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration new-admin-rust-api` 顯式列要起的 service（不指定 new-admin-base-web 即可，profile 是雙保險）。

**Rationale**:
- Profile 機制（compose v1.28+）讓 service 可被 tag、僅在指定 profile active 時啟動。`never` profile 在任何時候都不會被 active（除非 explicitly `--profile never`），等於「永不啟」。
- 為什麼不直接「dev compose 不起 new-admin-base-web」？因為 `compose -f a -f b up -d`（不指定 service）會起所有定義的 service。`profiles: ["never"]` 是 yaml 層級的禁令、不依賴 operator 記得只列特定 service。

**Alternatives considered**:
- 把 new-admin-base-web 從 dev compose 拿掉：但 dev compose 是 override，不能「移除」prod 已定義的 service，只能改它的設定。
- 用 `replicas: 0` (deploy 模式)：compose 不全支援、且增加複雜度。
- 用兩份完全獨立的 compose 文件（dev 不繼承 prod）：拒絕。雙份維護成本高、易漂移；override 機制就是為這場景設計的。

**Verification**:
```bash
docker compose -f compose.yaml -f compose.dev.yaml config --services
# 預期輸出包含 new-admin-base-web 但 docker compose up -d（無指定）不會起它
```

---

## R7: 跨平台換行（LF）

**Decision**: 在 outer 倉根新增 `.gitattributes`（若尚未存在），鎖 `deploy/**` 與 `**/*.sh` 為 LF：

```gitattributes
* text=auto eol=lf
*.sh text eol=lf
*.conf text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
deploy/.env.example text eol=lf
```

**Rationale**:
- Windows 上 git autocrlf=true 預設會把 LF → CRLF on checkout，alpine container 內 sh / nginx -t 看到 CRLF 會報錯（特別是 `entrypoint.sh` 在 feature 6 才寫，但若先有 `.env` / nginx conf 就影響）。
- `.gitattributes` 是 in-tree 規範，比要求每個 dev 設 `git config` 可靠。
- 與 constitution「跨平台相容」條款對齊。

**Verification**:
```bash
file deploy/compose.yaml deploy/nginx/default.conf deploy/.env.example
# 預期：每行尾為 \n（LF），不含 \r\n（CRLF）
```

**Alternatives considered**:
- 在 CI 加 lint 檢查 CRLF：未來可加，但 `.gitattributes` 是預防、CI 是補救。先做預防。
- 不管：拒絕。Windows operator 已知會踩坑（CLAUDE.md §7「不要做的事」也提到 Windows TortoiseGit 對 symlink 處理的歷史問題）。

---

## R8: §IV 上游驗證指令具現化

把 spec.md 的 4 項待驗證上游慣例落為**具體可執行**指令（plan 階段必交付物）：

### 驗證項 1：預設管理員密碼是 `Soybean@123.`

**待 feature 2/3 完成 login flow 後驗**（本 feature 1 不負責）：

```bash
BASE=http://localhost:8080/api
TOKEN=$(curl -s -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' | jq -r '.data.token // empty')
test -n "$TOKEN" && echo "PASS: 預設密碼是 Soybean@123." || echo "FAIL"
```

**結果回填處**：CLAUDE.md §5.1（依 INTEGRATION-CHECKLIST 維護指引）。

### 驗證項 2：Migration idempotent

見 R4 上方完整指令清單。本 feature 1 US1 acceptance scenario #3 直接驗。

### 驗證項 3：postgres/redis 60 秒內穩定 healthy

```bash
docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis
START=$(date +%s)
until docker compose ps --format json | jq -e '.[] | select(.Name | test("postgres|redis")) | .Health == "healthy"' > /dev/null 2>&1; do
  ELAPSED=$(( $(date +%s) - START ))
  test $ELAPSED -gt 60 && { echo "FAIL: $ELAPSED 秒未 healthy"; exit 1; }
  sleep 2
done
echo "PASS: $(( $(date +%s) - START )) 秒內 healthy"
```

### 驗證項 4：`name: new-admin-root` 隔離

```bash
# 在乾淨 host 上：
docker compose -f compose.yaml config | grep -E '^name:' | head -1
# 預期：name: new-admin-root

# 同時起兩個 stack 模擬撞名場景（用不同 .env）：
mkdir -p /tmp/test-isolation && cd /tmp/test-isolation
cp -r <repo>/deploy ./deploy-a
cp -r <repo>/deploy ./deploy-b
sed -i 's/name: new-admin-root/name: new-admin-root-test-a/' deploy-a/compose.yaml
docker compose -f deploy-a/compose.yaml up -d postgres
docker compose -f deploy-b/compose.yaml up -d postgres   # 應為 new-admin-root project
docker container ls --format '{{.Names}}' | grep -E 'new-admin-root(-test-a)?-postgres'
# 預期：兩個 container 各自獨立、不撞名
docker compose -f deploy-a/compose.yaml down -v
docker compose -f deploy-b/compose.yaml down -v
```

---

## 摘要：Phase 0 結論

- **8 項決策已落地**，每項含 Decision / Rationale / Alternatives / Verification（適用時）。
- **0 個 NEEDS CLARIFICATION 殘留**（spec 階段已 0、plan 階段亦無新增）。
- **Verification 指令清單已具現化**，作為 tasks 階段 acceptance test 的執行藍本。
- **Constitution Check 通過**（plan §Constitution Check 已記錄），無 Complexity Tracking 需 justify。

進入 Phase 1: Design & Contracts。
