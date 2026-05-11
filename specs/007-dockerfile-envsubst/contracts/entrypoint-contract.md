# Contract: admin-api entrypoint.sh

**Script path in image**: `/usr/local/bin/entrypoint.sh`
**Invoked by**: admin-api/Dockerfile `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`
**Args from Dockerfile CMD**: `["/bin/server"]`（entrypoint 把 args 透過 `exec "$@"` 啟動）

---

## 1. Inputs（env vars）

### 1.1 Required envs（缺一即 abort）

| Name | Description | Sentinel reject |
|------|-------------|-----------------|
| `APP_DATABASE_URL` | Postgres 連線字串 | only `""` |
| `APP_REDIS_URL` | Redis 連線字串 | only `""` |
| `APP_JWT_JWT_SECRET` | JWT 簽名 secret | only `""` |
| `APP_JWT_ISSUER` | JWT issuer claim | 完全等於 sentinel 清單任一即 abort |

### 1.2 `APP_JWT_ISSUER` sentinel rejection 清單（FR-606 / Clarifications Q1）

env 值**完全等於**下列任一即 abort（不 regex、不 substring）：

```
""                                                  (空字串)
"https://github.com/your-org/new-admin"             (feature 1 既有 default 值)
"change-me-issuer-url"                              (.env.example placeholder)
```

清單寫死 in entrypoint.sh；future 增 sentinel 時直接編輯。

### 1.3 Optional envs（with default fallback in .tpl）

| Name | Default |
|------|---------|
| `APP_DATABASE_MAX_CONNECTIONS` | `10` |
| `APP_SERVER_HOST` | `0.0.0.0` |
| `APP_SERVER_PORT` | `10001` |
| `APP_JWT_EXPIRE` | `7200` |
| `APP_JWT_REFRESH_TOKEN_EXPIRE` | `1209600` |

defaults 由 .tpl 內 `${VAR:-default}` 提供（envsubst 支援）；entrypoint 不需驗證。

---

## 2. Outputs

### 2.1 成功路徑

1. 寫入 `/app/server/resources/application.yaml`（rendered yaml，no `${...}` 殘留）
2. `exec "$@"`（將 PID 1 換成 `/bin/server`）
3. server 接管：admin-api 啟動正常

### 2.2 失敗路徑 — Exit codes

| Exit code | 條件 | stderr 訊息（範例） |
|-----------|------|---------------------|
| `1` | Required env 缺失或為空字串 | `[entrypoint] FATAL: APP_JWT_JWT_SECRET is empty or unset` |
| `2` | `APP_JWT_ISSUER` 命中 sentinel | `[entrypoint] FATAL: APP_JWT_ISSUER='${value}' is a known placeholder; set a real issuer URL` |
| `3` | envsubst 命令執行失敗 | `[entrypoint] FATAL: envsubst rendering failed: <error>` |
| `4` | rendered yaml file 寫入失敗（permission / disk） | `[entrypoint] FATAL: failed to write application.yaml: <error>` |
| `0` | 不會由 entrypoint 自己 return（exec 接管） | — |

container restart policy `unless-stopped` 會觸發 retry，但若 env 本身錯則無限失敗 loop —— **預期行為**，operator 應從 stderr 看到 FATAL 立即修 .env

### 2.3 stderr 格式

所有 entrypoint log 用 prefix `[entrypoint]`，便於 `docker logs` 過濾：

```
[entrypoint] starting...
[entrypoint] validating required envs...
[entrypoint] validating APP_JWT_ISSUER not placeholder...
[entrypoint] rendering application.yaml from template...
[entrypoint] exec /bin/server
```

FATAL 訊息：

```
[entrypoint] FATAL: <reason>
```

---

## 3. Side effects

### 3.1 Filesystem

- **Read**: `/app/server/resources/application.yaml.tpl`（template，唯讀）
- **Write**: `/app/server/resources/application.yaml`（每次啟動 overwrite，idempotent）
- **Permission**: 以 USER `appuser` (uid 10001) 執行；`/app/server/resources/` 已 chown 給 appuser

### 3.2 Process

- 透過 `exec "$@"` 啟動 server，**不**用 fork/wait，PID 1 直接是 server process
- 確保 docker 之 `SIGTERM` / `SIGKILL` 直達 server，沒有 shell 攔截

### 3.3 No-op on rerun

每次 container 啟動：先 overwrite `application.yaml`、再 exec server；無 state leak、無 append；idempotent。

---

## 4. Reference shell skeleton（pseudo-code，非 final）

```sh
#!/bin/sh
set -eu

TEMPLATE=/app/server/resources/application.yaml.tpl
OUTPUT=/app/server/resources/application.yaml

log() { echo "[entrypoint] $*" >&2; }
fatal() { echo "[entrypoint] FATAL: $*" >&2; exit "${2:-1}"; }

log "starting..."

# 1. Required env 預檢
log "validating required envs..."
for v in APP_DATABASE_URL APP_REDIS_URL APP_JWT_JWT_SECRET APP_JWT_ISSUER; do
  eval "value=\${${v}:-}"
  [ -n "${value}" ] || fatal "${v} is empty or unset" 1
done

# 2. Sentinel rejection
log "validating APP_JWT_ISSUER not placeholder..."
case "${APP_JWT_ISSUER}" in
  ""|"https://github.com/your-org/new-admin"|"change-me-issuer-url")
    fatal "APP_JWT_ISSUER='${APP_JWT_ISSUER}' is a known placeholder; set a real issuer URL" 2
    ;;
esac

# 3. envsubst render
log "rendering application.yaml from template..."
envsubst < "${TEMPLATE}" > "${OUTPUT}" || fatal "envsubst rendering failed" 3
[ -s "${OUTPUT}" ] || fatal "rendered file is empty or write failed" 4

# 4. exec server
log "exec $*"
exec "$@"
```

**Implementer's note**: pseudo-code 為 reference；final entrypoint.sh 可微調但須維持本契約之 exit codes、stderr format、idempotency。

---

## 5. 不在本契約範圍

- HTTPS / TLS（外層 LB）
- Secrets 從 file 讀（docker secret mount）—— future enhancement
- 多 instance config（per env_config.rs 之 multi-instance pattern）—— future
- 動態 reload（SIGHUP）—— admin-api 不支援
