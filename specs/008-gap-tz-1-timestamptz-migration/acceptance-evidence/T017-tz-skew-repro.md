# T017 — US1 Acceptance Evidence: TZ-skew Repro & Verification

## Header

| 項目 | 值 |
|---|---|
| Feature | 008-gap-tz-1-timestamptz-migration |
| User Story | US1 — TZ-skew (4-I1) no longer affects refresh behaviour |
| Date | 2026-05-11 |
| Outer repo (new-admin-root) SHA | `fce9a8f439b573ff2851c980802b54891487213e` |
| admin-api inner SHA | `cdf5a165de089a2c8856d982101a7311ec0140ae` |
| Postgres container | `new-admin-root-postgres-1` (the prod compose instance — the `-dev-` suffix container is the older dev infra and does NOT carry the timestamptz migration) |
| Migration applied | `m20260512_000000_alter_sys_tokens_timestamptz` |
| sys_tokens.expires_at column type | `timestamp with time zone` (verified via `\d sys_tokens`) |

---

## T014 — Login + capture refresh_token

### Request

```
POST http://localhost:8080/api/auth/login
Content-Type: application/json

{"identifier":"Soybean","password":"123456"}
```

### Response (HTTP 200)

```json
{
  "code": 200,
  "data": {
    "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi...",
    "refreshToken": "01KRBR880D5ZH5TPPCK90TY86H"
  },
  "msg": "success",
  "success": true
}
```

(JWT body redacted to first 24 chars.)

### Captured

| Variable | Value |
|---|---|
| `R` (refreshToken, 26-char ULID) | `01KRBR880D5ZH5TPPCK90TY86H` |
| `T_login` (approx unix epoch at login) | `1778510995` |

---

## T015 — TZ-skew reproduction (3 psql sessions, different TZ)

Single `psql -c` invocation running 3 sequential queries with `SET TIME ZONE` between them.

### Output

```
   tz    |             id             |       refresh_token        |        expires_at_text        |       epoch
---------+----------------------------+----------------------------+-------------------------------+-------------------
 default | 01KRBR880GH55G5CZQ94W5RFY6 | 01KRBR880D5ZH5TPPCK90TY86H | 2026-05-25 22:49:55.472196+08 | 1779720595.472196
(1 row)

SET
   tz   |        expires_at_text        |       epoch
--------+-------------------------------+-------------------
 taipei | 2026-05-25 22:49:55.472196+08 | 1779720595.472196
(1 row)

SET
 tz  |        expires_at_text        |       epoch
-----+-------------------------------+-------------------
 utc | 2026-05-25 14:49:55.472196+00 | 1779720595.472196
(1 row)
```

### Verification table

| Session TZ | `expires_at::text` | `EXTRACT(EPOCH FROM expires_at)` |
|---|---|---|
| default (server local — Asia/Taipei) | `2026-05-25 22:49:55.472196+08` | `1779720595.472196` |
| `Asia/Taipei` | `2026-05-25 22:49:55.472196+08` | `1779720595.472196` |
| `UTC` | `2026-05-25 14:49:55.472196+00` | `1779720595.472196` |

### Verdict

- **All 3 epochs identical** (`1779720595.472196`) — same UTC instant regardless of session TZ.
- **Text representation differs by exactly 8h** (`22:49:55+08` vs `14:49:55+00`) — Postgres renders in the session's TZ, but the underlying value is one canonical UTC instant.
- This is the **correct TIMESTAMPTZ behaviour**. Pre-fix (TIMESTAMP WITHOUT TIME ZONE) would have rendered the same naive `22:49:55` string in all 3 sessions, leading to an 8h off-by-one if a downstream client recomputed epoch using its own TZ.

---

## T016 — Refresh still works after external TZ observation

### Request

```
POST http://localhost:8080/api/auth/refreshToken
Content-Type: application/json

{"refreshToken":"01KRBR880D5ZH5TPPCK90TY86H"}
```

### Response (HTTP 200)

```json
{
  "code": 200,
  "data": {
    "token": "eyJ0eXAiOiJKV1QiLCJhbGciOi...",
    "refreshToken": "01KRBRA9Z61RP2NR7HZQ2W3RMS"
  },
  "msg": "success",
  "success": true
}
```

(JWT body redacted to first 24 chars.)

New refreshToken: `01KRBRA9Z61RP2NR7HZQ2W3RMS`.

### sys_tokens status rotation (DB verification)

```sql
SELECT refresh_token, status, expires_at::text, created_at::text
FROM sys_tokens
WHERE refresh_token IN ('01KRBR880D5ZH5TPPCK90TY86H', '01KRBRA9Z61RP2NR7HZQ2W3RMS')
ORDER BY created_at;
```

| `refresh_token` | `status` | `expires_at` | `created_at` |
|---|---|---|---|
| `01KRBR880D5ZH5TPPCK90TY86H` (R_old) | `REFRESHED` | `2026-05-25 22:49:55.472196+08` | `2026-05-11 22:49:55.472197+08` |
| `01KRBRA9Z61RP2NR7HZQ2W3RMS` (R_new) | `ACTIVE`    | `2026-05-25 22:51:03.012344+08` | `2026-05-11 22:51:03.015163+08` |

- Old token correctly marked `REFRESHED` (one-shot rotation enforced).
- New token issued with `ACTIVE` status.
- Both rows show `+08` suffix → write-path writes proper TIMESTAMPTZ values (`Utc::now().fixed_offset()` round-trip displays in session's local TZ).

---

## Verdict — SC-003 PASS

**TZ-skew root cause (4-I1) is verified fixed.**

Evidence:
1. `sys_tokens.expires_at` column is now `timestamp with time zone` (migration `m20260512_000000_alter_sys_tokens_timestamptz` applied).
2. External psql observers in `Asia/Taipei` and `UTC` agree on the same `EXTRACT(EPOCH)` for the same row — text rendering differs by 8h but represents one canonical UTC instant.
3. Refresh flow continues to work end-to-end (HTTP 200, status rotates `ACTIVE`→`REFRESHED`, new `ACTIVE` row created) — admin-api's interpretation of `expires_at` aligns with any external client's interpretation, regardless of session TZ.

US1 acceptance scenarios validated.

---

## Note on Setup T003 finding

Pre-migration backup (T003) confirmed **0 suspicious rows** — i.e. no rows in `sys_tokens` whose pre-fix naive value would have crossed the TZ-skew boundary. Migration was safe to apply with no data correction needed; the timestamptz cast preserved all existing instants under the assumption that pre-fix writers used the server's local TZ (Asia/Taipei), which matches reality.

---

## Reproduction commands (for future re-verification)

```bash
# 1. Login
curl -sS -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"123456"}'

# 2. Capture refreshToken value as $R, then:
docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -c "
SELECT 'default' AS tz, expires_at::text, EXTRACT(EPOCH FROM expires_at) AS epoch
  FROM sys_tokens WHERE refresh_token = '$R';
SET TIME ZONE 'Asia/Taipei';
SELECT 'taipei' AS tz, expires_at::text, EXTRACT(EPOCH FROM expires_at) AS epoch
  FROM sys_tokens WHERE refresh_token = '$R';
SET TIME ZONE 'UTC';
SELECT 'utc' AS tz, expires_at::text, EXTRACT(EPOCH FROM expires_at) AS epoch
  FROM sys_tokens WHERE refresh_token = '$R';
"

# 3. Refresh
curl -sS -X POST http://localhost:8080/api/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$R\"}"
```
