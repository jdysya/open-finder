# OpenFinder Local Code Signing Design

Date: 2026-07-12

## Goal

Make locally rebuilt OpenFinder bundles retain one stable macOS code identity so Keychain and TCC approvals can persist across builds on the same Mac, while preserving the existing build-and-run workflow on machines that do not have the local certificate.

## Scope

Only `script/build_and_run.sh` changes. The application source, Keychain storage model, entitlements, installation path, and public distribution workflow remain unchanged.

## Signing selection

The script resolves the signing identity in this order:

1. Use `OPENFINDER_SIGNING_IDENTITY` when it is non-empty.
2. Otherwise use `OpenFinder Local Development`.

Before signing, the script checks the login keychain's valid code-signing identities. If the selected identity is available, it signs the fully staged `dist/OpenFinder.app` bundle with that identity. Signing occurs only after the executable, resources, icon, and `Info.plist` have been written so the final bundle seal covers every shipped file.

## Compatibility fallback

If the selected identity is unavailable, the script applies an explicit ad-hoc signature to the final bundle and prints a warning that Keychain and TCC approvals may not persist across rebuilds. This preserves buildability for contributors and CI machines without the local certificate.

The fallback is compatibility behavior, not a claim of stable authorization. Public distribution remains out of scope and still requires Apple Developer ID signing and notarization.

## Verification and failure behavior

After either stable or ad-hoc signing, the script runs:

```sh
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
```

A signing or verification error fails the script before launch. The script reports which signing mode it selected without printing private key material or other secrets.

When stable signing is used, the bundle must show:

- `Authority=OpenFinder Local Development`
- `Identifier=dev.openfinder.OpenFinder`
- a designated requirement based on the fixed certificate fingerprint rather than the build's CDHash
- a sealed `Info.plist` and resources

## Test strategy

1. RED characterization: run the unchanged script and prove the staged bundle is ad-hoc or fails strict bundle verification.
2. GREEN stable path: run with the installed local certificate and prove strict verification succeeds, the authority is `OpenFinder Local Development`, and the designated requirement is certificate-based.
3. GREEN rebuild stability: rebuild or mutate a temporary staged resource, re-sign, and prove CDHash changes while the designated requirement remains identical.
4. GREEN fallback path: isolate the identity lookup from the login keychain or select a deliberately missing identity, then prove the script emits the warning, applies an ad-hoc signature, and still passes strict bundle verification.
5. Regression: run `swift test` and confirm the existing test suite remains green.

All launched OpenFinder processes and temporary signing artifacts must be removed after verification.
