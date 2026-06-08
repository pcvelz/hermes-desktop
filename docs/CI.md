# CI & pre-push verification

The only CI workflow that gates code is **`.github/workflows/macos-ci.yml`** (job
`build-and-verify`, runner `macos-15`). It runs on every `push`, every
`pull_request`, and `workflow_dispatch`.

Steps, in order:

1. **Run tests** — `./scripts/run-tests.sh` (`swift test`, the full swift-testing suite).
2. **Build app bundle** — `./scripts/build-macos-app.sh` (universal arm64 + x86_64).
3. **Package / verify / upload release** — only on `refs/tags/v*`. There is **no
   separate release workflow**; tagging `vX.Y.Z` is what produces a release artifact.

## Definition of "passing"

A change is **passing only when the macOS CI run on its pushed SHA is green.**
A local `swift build` succeeding is *not* sufficient — see the gap below.

After pushing, confirm:

```bash
gh run watch "$(gh run list --repo pcvelz/hermes-desktop -L1 --json databaseId --jq '.[0].databaseId')" \
  --repo pcvelz/hermes-desktop
```

If a notification email links a run that 404s, it has expired/been pruned — just
re-trigger an identical run on the same SHA and read that one:

```bash
gh workflow run macos-ci.yml --repo pcvelz/hermes-desktop --ref main
```

## Why local builds lie (the toolchain gap)

Local dev machines here run **Xcode 26 / Swift 6.3.x with Command Line Tools
only**. The CI runner runs **macos-15 with an older Swift**. Two consequences:

- **The CI Swift is stricter.** Newer Swift's region-based isolation accepts
  things the CI compiler rejects — e.g. returning a non-`Sendable` `[String: Any]`
  from a `nonisolated` context compiles locally but fails on CI. Fix: annotate the
  method `@MainActor` (or make the return type `Sendable`).
- **Tests don't run locally without full Xcode.** CLT cannot load
  `lib_TestingInterop.dylib`, so `swift test` (and the whole swift-testing suite,
  including `LocalizationCoverageTests`) never executes on a CLT-only box. A
  localization key added in code but missing from the `.strings` tables passes
  locally and fails on CI.

## What to run before pushing

```bash
./scripts/preflight.sh
```

It runs the **locally reproducible** CI gates:

1. `swift build` (host arch) — catches compile errors.
2. A Python replica of `LocalizationCoverageTests` — catches missing/desynced
   localization keys across `en` / `zh-Hans` / `ru`.

A **blocking pre-push hook** runs this automatically once installed:

```bash
git config core.hooksPath scripts/githooks   # one-time, per clone
```

Override an intentional WIP push with `git push --no-verify`.

**Preflight is a pre-filter, not a guarantee.** It cannot reproduce the
macos-15-only compiler strictness or actually execute the test suite. Treat a
green local preflight as "probably fine"; treat a green macos-15 CI run as "done".

## Localization rule of thumb

`L10n.string("...")` keys **must be static string literals** — never interpolated
(`L10n.string("... \(cond ? "a" : "b")")` produces a key that can never resolve
and breaks the coverage test). Pick between two fully-static localized strings
instead, and add every new key to **all three** tables
(`Sources/HermesDesktop/Resources/{en,zh-Hans,ru}.lproj/Localizable.strings`).
