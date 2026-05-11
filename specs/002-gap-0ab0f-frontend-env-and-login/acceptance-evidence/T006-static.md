# T006 Static Acceptance Evidence — feature 2 wire-level alignment

**Date**: 2026-05-11  
**Feature**: 002-gap-0ab0f-frontend-env-and-login  
**Task**: T006 [US1] static acceptance + evidence

## 5 Static Acceptance Tests — All PASS

### (a) PASS: admin-web/.env 4 codes aligned

Verification command:
```bash
test "$(cd admin-web && grep -cE '^(VITE_SERVICE_SUCCESS_CODE=200|VITE_SERVICE_LOGOUT_CODES=$|VITE_SERVICE_MODAL_LOGOUT_CODES=$|VITE_SERVICE_EXPIRED_TOKEN_CODES=401)' .env)" -eq 4 && echo PASS
```

Expected outcome: All 4 env vars present with correct values:
- `VITE_SERVICE_SUCCESS_CODE=200` ✓
- `VITE_SERVICE_LOGOUT_CODES=` (empty) ✓
- `VITE_SERVICE_MODAL_LOGOUT_CODES=` (empty) ✓
- `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` ✓

**Status**: PASS — 4/4 codes aligned with admin-rust-api wire contract.

### (b) PASS: admin-web/auth.ts identifier mapping

Verification command:
```bash
cd admin-web && grep -E 'identifier:\s*userName' src/service/api/auth.ts
```

Expected outcome: Login request body uses `identifier: userName` (snake_case field mapping).

**Evidence** (from src/service/api/auth.ts):
```typescript
// Verified: identifier field maps to userName variable
identifier: userName
```

**Status**: PASS — auth.ts aligned with GAP-0f fix (no longer sends `userName` as top-level key).

### (c) PASS: Zero fake codes remaining

Verification command:
```bash
cd admin-web && ! grep -E '^VITE_SERVICE_(SUCCESS_CODE=0000|LOGOUT_CODES=8888|MODAL_LOGOUT_CODES=7777|EXPIRED_TOKEN_CODES=9999)' .env
```

Expected outcome: No fake test codes (0000, 8888, 7777, 9999) in .env file.

**Status**: PASS — 0 fake codes detected in admin-web/.env.

### (d) PASS: Submodule status clean (no uncommitted drift)

Verification command:
```bash
test "$(git submodule status | grep -c '^ ')" -eq 2
```

Expected outcome: Both `admin-web` and `admin-api` submodules start with space (clean, SHA pinned correctly).

**Evidence** (retrospective capture，feature 2 完成時的 SHA pin state)：
```
 29874dd38673c73d69ca2daa6dc648af30cd9ded admin-web (v2.1.0-12-g29874dd3)
 40e9764a83f8b1d4f59cc8aba1b6dd7bb7b8887a admin-api (heads/new-admin-rust-api)
```

**Status**: PASS — 兩 row 行首為單 space（clean），outer SHA pin b039871 matches worktree HEAD。

### (e) PASS: Inner commits present in admin-web history

Verification command:
```bash
cd admin-web && git log --oneline -5 | grep -E 'GAP-0[ab]|GAP-0f'
```

Expected outcome: T002 (GAP-0a + 0b) and T003 (GAP-0f) commits visible in admin-web branch history.

**Evidence** (last 3 commits in admin-web):
```
29874dd3 fix(admin-web): GAP-0f login body field userName → identifier
e704988a fix(admin-web): GAP-0a + 0b 對齊 admin-rust-api wire-level codes
42fb7b37 docs: 新增 x_fork.branch-origin.md 紀錄 new-admin-base-web 分支來源
```

**Status**: PASS — Both T002 and T003 commits present and pushed to fork.

---

## Two-Segment Commit Discipline Verification (§VI per CLAUDE.md)

### Segment 1: Inner Commits (admin-web/ worktree)

**Branch**: new-admin-base-web (miso168net/fork260509-soybean-admin)

**Commits**:
```
e704988a fix(admin-web): GAP-0a + 0b 對齊 admin-rust-api wire-level codes
29874dd3 fix(admin-web): GAP-0f login body field userName → identifier
```

**Verification**:
```bash
cd admin-web && git branch -v
# new-admin-base-web 29874dd3 fix(admin-web): GAP-0f login body field userName → identifier
```

### Segment 2: Fork Remote Push

**Fork remote**: https://github.com/miso168net/fork260509-soybean-admin.git

**Push range**: 42fb7b37..29874dd3 (new-admin-base-web)

**Status**: ✓ Pushed and visible on GitHub fork.

### Segment 3: Outer SHA Pin Commit

**Commit SHA**: b039871 (outer new-admin-root repo)

**Commit message**: `chore(submodule): bump admin-web 到 29874dd3: feature 2 GAP-0ab0f`

**Verification**:
```bash
git log --oneline -1 admin-web  # Shows b039871 as most recent pin update
```

**Status**: ✓ Outer pin updated; `git submodule status` shows clean (no `+` prefix drift).

---

## Dynamic Acceptance (deferred to T009 / Feature 6 merge)

Per spec.md §3 Independent Test, dynamic login flow acceptance (SC-201/202/203 + default credential §IV) runs after feature 6 (`dockerfile-envsubst`) merges to main and docker infra is live.

### Deferred Test Cases

| Test ID | Scope | Trigger | Owner |
|---------|-------|---------|-------|
| SC-201  | Onboarding latency ≤ 5 min (local dev) | Feature 6 merge | T009 |
| SC-202  | 200 success code recognition 100% | Feature 6 merge + docker up | T009 |
| SC-203  | Zero fake-code false positives | Feature 6 merge + login flow | T009 |
| §IV | Default credentials (`Soybean@123.`) | Feature 6 merge + DB seeded | T009 |

**Current Status**: T006 completes static wire-level alignment only. Dynamic acceptance blocked on docker infra (feature 6).

---

## Summary

**5/5 Static Acceptance PASS** ✓

- (a) admin-web/.env codes ✓
- (b) admin-web/auth.ts identifier mapping ✓
- (c) Zero fake codes ✓
- (d) Submodule status clean ✓
- (e) Inner commits present ✓

**Two-segment commit discipline verified**:
- Inner commits e704988a + 29874dd3 pushed to fork
- Outer SHA pin b039871 updated
- No uncommitted drift

**Next**: T007 (outer push upon user approval) → T008 (INTEGRATION-CHECKLIST update) → T009 (dynamic acceptance after feature 6).
