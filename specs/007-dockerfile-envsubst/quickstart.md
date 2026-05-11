# Quickstart: admin-api envsubst template + Hardening

**Feature**: 007-dockerfile-envsubst
**Audience**: implementer + operator

兩段：implementer 走兩段式 commit（admin-api inner + outer）；operator 跑 acceptance（包含 fail-fast 場景 + 重跑 feature 7 T010 五場景）。

---

## Part A — Implementer Quickstart

### A.0 Pre-flight 健檢

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git status -sb                    # 應在 007-dockerfile-envsubst branch
git submodule status              # admin-api SHA 應 = 8ae2432（7-I1 hotfix 後）
                                  # admin-web SHA 應 = 65f3060a

cd admin-api
git branch --show-current         # new-admin-rust-api
git status -sb                    # clean
ls server/resources/              # 確認 application.yaml 仍存在（本 feature 將刪）
ls entrypoint.sh 2>&1 | head -1   # "No such file or directory"（將新增）
```

### A.1 admin-api Inner 改動（在 admin-api/ worktree 內）

#### Step 1: 改 `server/resources/application.yaml` → `application.yaml.tpl`

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api
git mv server/resources/application.yaml server/resources/application.yaml.tpl
```

編輯 .tpl 把 hardcoded 值改 `${APP_*}` 占位（見 data-model.md Entity 1）：

```yaml
database:
    url: "${APP_DATABASE_URL}"
    max_connections: ${APP_DATABASE_MAX_CONNECTIONS:-10}
    min_connections: 1
    connect_timeout: 30
    idle_timeout: 600
server:
    host: "${APP_SERVER_HOST:-0.0.0.0}"
    port: ${APP_SERVER_PORT:-10001}
jwt:
    jwt_secret: "${APP_JWT_JWT_SECRET}"
    issuer: "${APP_JWT_ISSUER}"
    expire: ${APP_JWT_EXPIRE:-7200}
redis:
    mode: single
    url: "${APP_REDIS_URL}"
```

#### Step 2: 新增 `entrypoint.sh`

於 admin-api/ 根新增 `entrypoint.sh`（per contracts/entrypoint-contract.md §4 reference shell skeleton）。

```bash
chmod +x entrypoint.sh
```

#### Step 3: 修 `admin-api/Dockerfile` runtime stage

關鍵 diff（runtime stage 內）：

```dockerfile
RUN apk add --no-cache openssl ca-certificates tzdata gettext && \    # 加 gettext (envsubst)
    adduser ...

COPY --from=build /bin/server /bin/
COPY --from=build --chown=${APP_USER}:${APP_USER} /app/server/resources/application.yaml.tpl /app/server/resources/   # 改 .tpl
COPY --from=build --chown=${APP_USER}:${APP_USER} /app/server/resources/ip2region.xdb /app/server/resources/
COPY --from=build --chown=${APP_USER}:${APP_USER} /app/server/resources/rbac_model.conf /app/server/resources/
COPY --chown=${APP_USER}:${APP_USER} entrypoint.sh /usr/local/bin/entrypoint.sh   # 新增
RUN chmod +x /usr/local/bin/entrypoint.sh                                          # 確保 +x

WORKDIR /app
USER ${APP_USER}
EXPOSE ${APP_PORT}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]    # 新增
CMD ["/bin/server"]                            # 不變
```

#### Step 4: admin-api inner commit

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api
git add server/resources/application.yaml.tpl server/resources/application.yaml entrypoint.sh Dockerfile
git status                                    # 確認 application.yaml 是 deleted、.tpl 是 new file

git commit -m "$(cat <<'EOF'
feat(admin-api): envsubst template + entrypoint validate（per constitution §II）

- server/resources/application.yaml → application.yaml.tpl
- 移除 hardcoded prod-like 預設值（pgbouncer / soybean-admin-rust / 123456 / ByteByteBrew）
- 新增 entrypoint.sh：required env 預檢 + APP_JWT_ISSUER sentinel rejection + envsubst render + exec /bin/server
- Dockerfile runtime stage 加 gettext (envsubst 提供)、COPY entrypoint.sh、ENTRYPOINT 指向之

constitution §II 要求 envsubst template、不可 ship hardcoded prod 預設值。本 commit 完成此 alignment。
驗證：see specs/007-dockerfile-envsubst/quickstart.md Part B。
EOF
)"
```

### A.2 admin-api Inner Push（NEEDS USER AUTHORIZATION）

```bash
cd admin-api
git push origin new-admin-rust-api
```

### A.3 Outer 改動（deploy/ 區 + submodule pin）

#### Step 5: 修 `deploy/compose.yaml`（postgres start_period + redis CMD-SHELL）

```yaml
postgres:
  ...
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-admin} -d ${POSTGRES_DB:-new_admin}"]
    interval: 10s
    timeout: 5s
    retries: 10
    start_period: 30s        # 1-M1: 既有已是 30s — verify 即可

redis:
  ...
  healthcheck:
    # 1-I1 fix：CMD-SHELL form + $$REDIS_PASSWORD env interpolation
    # 避免 docker compose 提前展開 password 到 healthcheck argv
    test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]
    ...
```

#### Step 6: 修 `deploy/nginx/default.conf`（gzip_proxied + WebSocket header verify）

```nginx
location /api/ {
    proxy_pass http://new-admin-rust-api:10001/;
    ...
    # 1-M2: WebSocket header 預備（既有已含、verify 即可）
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    ...
}

# gzip
gzip on;
gzip_proxied any;             # 1-M3: 新增（被反代 response 也壓縮）
gzip_types ...;
```

#### Step 7: 修 `deploy/.env.example`（APP_JWT_ISSUER placeholder + doc）

```bash
# JWT 簽發者（issuer claim）
# 必填：必須改為真實 issuer URL；entrypoint 拒以下 sentinel：
#   - 空字串
#   - https://github.com/your-org/new-admin
#   - change-me-issuer-url
APP_JWT_ISSUER=change-me-issuer-url

# Limitation note：redis container 之 main process argv 仍會在 `docker top` 暴露
# REDIS_PASSWORD（redis-server --requirepass 之 CLI flag 設計）；future hardening
# 可透過 ACL config file 解決
```

#### Step 8: Outer commits

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
# Commit A: deploy hardening
git add deploy/compose.yaml deploy/nginx/default.conf deploy/.env.example
git commit -m "fix(deploy): 1-I1 + 1-M1~M5 hardening 收尾"

# Commit B: submodule SHA bump
SHORT_SHA=$(cd admin-api && git rev-parse --short HEAD)
git add admin-api
git commit -m "chore(submodule): bump admin-api 到 ${SHORT_SHA}: envsubst template + entrypoint"
```

### A.4 Build admin-api Image 驗證（local，不 push）

```bash
cd deploy
docker compose build new-admin-rust-api
# 預期 build 成功 + 多 ~200KB 因 gettext
```

### A.5 Outer Push（NEEDS USER AUTHORIZATION）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git push origin 007-dockerfile-envsubst
```

---

## Part B — Operator Quickstart（Dynamic Acceptance）

### B.0 前置

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/deploy
ls .env || cp .env.example .env
# 編輯 .env 填真實 secrets：POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET
# **特別注意** APP_JWT_ISSUER 必須改為真實 URL（如 https://your-company.com/auth）
$EDITOR .env
```

### B.1 Happy Path — 整套 stack 起 + login

```bash
docker compose up -d
sleep 60
docker compose ps                          # 4 service 全 healthy
curl -sS -X POST http://localhost:8080/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"identifier":"Soybean","password":"123456"}'
# 預期: HTTP 200 + JWT
```

### B.2 SC-602 Image 內無 hardcoded 預設

```bash
docker run --rm new-admin-rust-api:latest ls /app/server/resources/
# 預期: application.yaml.tpl / ip2region.xdb / rbac_model.conf
# **不應**含 application.yaml

docker run --rm new-admin-rust-api:latest cat /app/server/resources/application.yaml.tpl | grep -E "pgbouncer|soybean-admin-rust|ByteByteBrew|123456"
# 預期: 0 命中
```

### B.3 SC-605 Rendered yaml 正確

```bash
docker exec new-admin-root-new-admin-rust-api-1 cat /app/server/resources/application.yaml | head -20
# 預期: 看到 real env 值（postgres://admin:<password>@postgres:5432/new_admin 等）
# 不應殘留 ${APP_...} 字面字串
```

### B.4 SC-604 Required env 缺失必失敗

```bash
docker compose stop new-admin-rust-api
# 暫時 unset 一個必要 env (如 APP_JWT_JWT_SECRET) 注入：
# 把 .env 內該行 comment 掉
docker compose up -d new-admin-rust-api
sleep 15
docker compose logs new-admin-rust-api | tail -5
# 預期: stderr 含 "[entrypoint] FATAL: APP_JWT_JWT_SECRET is empty or unset"
# container exit non-zero、不 silently fall back
# 復原 .env 即可
```

### B.5 SC-609 Sentinel rejection

```bash
docker compose stop new-admin-rust-api
# 修 .env 設 APP_JWT_ISSUER=https://github.com/your-org/new-admin（既有 hotfix b7a74b5 default）
docker compose up -d new-admin-rust-api
sleep 10
docker compose logs new-admin-rust-api | tail -5
# 預期: "[entrypoint] FATAL: APP_JWT_ISSUER='https://github.com/your-org/new-admin' is a known placeholder"
# container exit non-zero

# 反向驗證 false positive：APP_JWT_ISSUER=https://my-company.example.com/auth
# 應成功啟動
```

### B.6 SC-606 Redis healthcheck argv 不含明文 password

```bash
docker top new-admin-root-redis-1
# 預期 healthcheck command args 顯示為:
#   sh -c redis-cli -a "$REDIS_PASSWORD" ping
# **不**應是:
#   redis-cli -a yourActualPassword ping
```

### B.7 SC-608 Feature 7 T010 五場景重跑

per `specs/006-admin-web-dockerfile/acceptance-evidence/T010-dynamic.md` 五場景：
1. Login `Soybean/123456` → dashboard
2. Deep link `/home` refresh
3. `/non-existent-page` → not-found page
4. API up baseline
5. Backend down → nginx 502

全綠表示 envsubst 改造未破壞既有功能。

---

## 不在本 Quickstart 範圍

- HTTPS / TLS / CDN（外層 LB）
- Image push / tag scheme（A7 of feature 7 同理）
- Multi-instance config（per env_config.rs multi-instance pattern，future）
- 動態 reload（admin-api 不支援 SIGHUP）
