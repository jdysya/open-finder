# OpenFinder Local Code Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `script/build_and_run.sh` sign the fully staged OpenFinder bundle with a stable local identity when available, while retaining an explicit verified ad-hoc fallback.

**Architecture:** Signing remains inside the existing single build/run entrypoint. The script selects an identity from `OPENFINDER_SIGNING_IDENTITY` or the default `OpenFinder Local Development`, signs only after all bundle files are staged, and strictly verifies the resulting bundle before any launch mode executes.

**Tech Stack:** Bash, SwiftPM, macOS `security`, macOS `codesign`, Swift XCTest.

## Global Constraints

- Only `script/build_and_run.sh` changes in production behavior.
- Default stable identity is exactly `OpenFinder Local Development`.
- A non-empty `OPENFINDER_SIGNING_IDENTITY` overrides the default.
- Missing identities must fall back to an explicit ad-hoc signature with a warning.
- Every staged bundle must pass `codesign --verify --deep --strict --verbose=2` before launch.
- Public Developer ID distribution and notarization remain out of scope.
- Do not commit unless the user separately authorizes a commit.

---

### Task 1: Pin the Existing Broken Bundle-Signing Behavior

**Files:**
- Inspect: `script/build_and_run.sh:1-94`
- Artifact: `dist/OpenFinder.app`

**Interfaces:**
- Consumes: Existing `./script/build_and_run.sh` entrypoint.
- Produces: RED evidence proving the unchanged script does not create a stable, strictly valid signed bundle.

- [ ] **Step 1: Capture the current script and identity preconditions**

Run:

```bash
git status --short --branch
security find-identity -p codesigning -v
sed -n '1,180p' script/build_and_run.sh
```

Expected: the worktree contains only the approved design/plan documents; the local identity `OpenFinder Local Development` is valid; the script contains no final bundle `codesign` call.

- [ ] **Step 2: Run the unchanged real build entrypoint**

Run:

```bash
./script/build_and_run.sh
```

Expected: SwiftPM build succeeds and `dist/OpenFinder.app` is staged and launched.

- [ ] **Step 3: Verify the RED failure and clean up the launched process**

Run:

```bash
set +e
codesign --verify --deep --strict --verbose=4 dist/OpenFinder.app
verify_status=$?
codesign -dvvv dist/OpenFinder.app 2>&1 | rg 'Signature=|Authority=|Info.plist=|TeamIdentifier='
pkill -x OpenFinder 2>/dev/null || true
test "$verify_status" -ne 0
```

Expected: strict verification is non-zero or the bundle reports ad-hoc signing without `Authority=OpenFinder Local Development`; the process is stopped.

### Task 2: Add Stable Signing with an Explicit Fallback

**Files:**
- Modify: `script/build_and_run.sh:4-70`

**Interfaces:**
- Consumes: `OPENFINDER_SIGNING_IDENTITY: String?`, login-keychain identities, staged `APP_BUNDLE`.
- Produces: `sign_app_bundle()`, a strictly verified final bundle, and a warning-only ad-hoc compatibility path.

- [ ] **Step 1: Add identity selection beside the existing bundle constants**

Insert after `MIN_SYSTEM_VERSION`:

```bash
DEFAULT_SIGNING_IDENTITY="OpenFinder Local Development"
SIGNING_IDENTITY="${OPENFINDER_SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
```

- [ ] **Step 2: Add the signing function after the Info.plist heredoc**

Insert before `open_app()`:

```bash
sign_app_bundle() {
  local identities
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"

  if grep -Fq -- "\"$SIGNING_IDENTITY\"" <<<"$identities"; then
    echo "Signing $APP_BUNDLE with identity: $SIGNING_IDENTITY"
    codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  else
    echo "warning: code-signing identity '$SIGNING_IDENTITY' is unavailable; using ad-hoc signing. Keychain and TCC approvals may not persist across rebuilds." >&2
    codesign --force --deep --timestamp=none --sign - "$APP_BUNDLE"
  fi

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_app_bundle
```

- [ ] **Step 3: Run shell syntax validation**

Run:

```bash
bash -n script/build_and_run.sh
```

Expected: exit 0 and no output.

### Task 3: Prove Stable Signing and Rebuild Identity

**Files:**
- Verify: `script/build_and_run.sh`
- Artifact: `dist/OpenFinder.app`

**Interfaces:**
- Consumes: Installed `OpenFinder Local Development` identity.
- Produces: GREEN strict-validation evidence and certificate-based designated requirement evidence.

- [ ] **Step 1: Run the stable signing path**

Run:

```bash
./script/build_and_run.sh
```

Expected output includes `Signing ... with identity: OpenFinder Local Development` and strict verification succeeds.

- [ ] **Step 2: Inspect and pin the signed bundle**

Run:

```bash
codesign --verify --deep --strict --verbose=4 dist/OpenFinder.app
codesign -dvvv --entitlements :- dist/OpenFinder.app 2>&1
codesign -dr - dist/OpenFinder.app 2>&1
```

Expected:

```text
Authority=OpenFinder Local Development
Identifier=dev.openfinder.OpenFinder
designated => identifier "dev.openfinder.OpenFinder" and certificate root = H"977319a63d2c24caf916eb52f08bced78ea1d807"
```

- [ ] **Step 3: Prove designated-requirement stability across rebuilds**

Run the script twice, capturing each CDHash and designated requirement:

```bash
first_cdhash="$(codesign -dvvv dist/OpenFinder.app 2>&1 | awk -F= '/^CDHash=/{print $2}')"
first_req="$(codesign -dr - dist/OpenFinder.app 2>&1 | sed -n 's/^designated => //p')"
./script/build_and_run.sh
second_cdhash="$(codesign -dvvv dist/OpenFinder.app 2>&1 | awk -F= '/^CDHash=/{print $2}')"
second_req="$(codesign -dr - dist/OpenFinder.app 2>&1 | sed -n 's/^designated => //p')"
test "$first_req" = "$second_req"
test -n "$first_cdhash"
test -n "$second_cdhash"
```

Expected: both requirements are identical and certificate-based. CDHash equality is permitted when SwiftPM emits byte-identical output; stability is defined by the designated requirement, not forced CDHash churn.

- [ ] **Step 4: Stop launched processes**

Run:

```bash
pkill -x OpenFinder 2>/dev/null || true
! pgrep -x OpenFinder >/dev/null
```

Expected: exit 0.

### Task 4: Prove the Missing-Identity Fallback

**Files:**
- Verify: `script/build_and_run.sh`
- Artifact: `dist/OpenFinder.app`

**Interfaces:**
- Consumes: `OPENFINDER_SIGNING_IDENTITY="OpenFinder Missing Test Identity"`.
- Produces: warning evidence plus a strictly valid ad-hoc bundle.

- [ ] **Step 1: Run with a deliberately missing identity**

Run:

```bash
OPENFINDER_SIGNING_IDENTITY="OpenFinder Missing Test Identity" ./script/build_and_run.sh 2>&1 | tee /tmp/openfinder-signing-fallback.log
```

Expected output includes:

```text
warning: code-signing identity 'OpenFinder Missing Test Identity' is unavailable; using ad-hoc signing. Keychain and TCC approvals may not persist across rebuilds.
```

- [ ] **Step 2: Verify fallback bundle and warning**

Run:

```bash
rg -F "using ad-hoc signing" /tmp/openfinder-signing-fallback.log
codesign --verify --deep --strict --verbose=4 dist/OpenFinder.app
codesign -dvvv dist/OpenFinder.app 2>&1 | rg 'Signature=adhoc'
pkill -x OpenFinder 2>/dev/null || true
```

Expected: all commands exit 0.

- [ ] **Step 3: Restore the final artifact to stable signing**

Run:

```bash
./script/build_and_run.sh
codesign --verify --deep --strict --verbose=4 dist/OpenFinder.app
codesign -dvvv dist/OpenFinder.app 2>&1 | rg -F 'Authority=OpenFinder Local Development'
pkill -x OpenFinder 2>/dev/null || true
```

Expected: stable signing is restored and the process is stopped.

### Task 5: Regression, Cleanup, and Final Review

**Files:**
- Verify: `script/build_and_run.sh`
- Verify: `docs/superpowers/specs/2026-07-12-local-code-signing-design.md`
- Verify: `docs/superpowers/plans/2026-07-12-local-code-signing.md`

**Interfaces:**
- Consumes: Final script and stable signed bundle.
- Produces: clean regression evidence and no runtime/test artifacts.

- [ ] **Step 1: Run the full Swift test suite**

Run:

```bash
swift test
```

Expected: 92 tests execute with 0 failures and 0 unexpected failures.

- [ ] **Step 2: Remove QA-only artifacts**

Run:

```bash
rm -f /tmp/openfinder-signing-fallback.log
pkill -x OpenFinder 2>/dev/null || true
test ! -e /tmp/openfinder-signing-fallback.log
! pgrep -x OpenFinder >/dev/null
```

Expected: exit 0.

- [ ] **Step 3: Review the final diff and repository state**

Run:

```bash
bash -n script/build_and_run.sh
git diff --check
git diff -- script/build_and_run.sh
git status --short --branch
```

Expected: no syntax or whitespace errors; only the approved script and documentation files differ; no debug artifacts remain.

- [ ] **Step 4: Prepare handoff without committing**

Report the stable identity fingerprint, RED and GREEN evidence, fallback result, full test result, final bundle path, and remaining uncommitted files. Do not stage or commit unless the user explicitly asks.
