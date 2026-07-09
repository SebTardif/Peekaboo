---
summary: 'Release Peekaboo CLI, npm package, signed macOS app, and Sparkle appcast.'
read_when:
  - 'preparing, publishing, or verifying a Peekaboo release'
---

# Peekaboo release checklist

Run from the repository root. Releases publish `@steipete/peekaboo`, universal CLI archives, checksums, and a
OpenClaw Foundation Developer ID signed/notarized `Peekaboo.app` with a Sparkle appcast entry.

The standalone CLI intentionally remains signed by the legacy `Y5PE65HELJ` release team so current CLI releases can still authenticate to pre-3.8 GUI bridge hosts. Peekaboo 3.8 and later trust both the legacy and Foundation team IDs. The release driver uses Apple's system `codesign` only for that compatibility binary because the managed helper scopes all normal signing to the Foundation-only keychain; it then verifies the CLI's exact authority and Team ID in both archives. Treat changing the CLI team as a separate compatibility migration.

## 1. Prepare

- Confirm `main` is clean, current, and all submodules are at the intended commits.
- Update `package.json`, both `version.json` files, `Apps/CLI/Sources/Resources/Info.plist`,
  `Apps/CLI/TestHost/Info.plist`, `PeekabooMCPVersion.current`, the README badge, and `MARKETING_VERSION` in the Mac,
  Inspector, and Playground Xcode projects.
- Move release changes into matching dated sections in `CHANGELOG.md` and `Apps/CLI/CHANGELOG.md`.
- Update user-facing docs and `release/release-notes.md`. Release notes contain only that version's changelog section.
- Update submodule repositories first only when their code or release metadata changed, then commit the gitlink here.

## 2. Validate

```bash
pnpm run format
pnpm run lint
pnpm run lint:docs
pnpm run docs:site
pnpm run test:safe
pnpm run prepare-release
```

Run `pnpm run test:automation` and live provider tests when the release changes those surfaces. Before committing,
run the repository autoreview workflow until no accepted actionable findings remain.

## 3. Commit and push

Use `./scripts/committer` with Conventional Commits. Push `main`, pull with `--ff-only`, and confirm a clean tree
before building release artifacts; dirty trees produce invalid version metadata.

## 4. Publish

Load release credentials through the maintainer 1Password workflow, then run interactively:

```bash
./scripts/release-binaries.sh \
  --create-github-release \
  --publish-npm
```

The script runs release preparation, builds the universal CLI and npm package, signs/notarizes/staples the macOS app,
generates checksums and Sparkle metadata, and uploads a draft GitHub release. When it pauses at the npm confirmation,
leave the process waiting, inspect the draft assets and notes, then answer `y` to publish npm. The signing identity must
be:

```text
Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)
```

The CLI artifact must report `Developer ID Application: Peter Steinberger (Y5PE65HELJ)` and Team ID `Y5PE65HELJ`; the release driver verifies this exact compatibility signer in the standalone and npm archives.

After npm verification, append a `Verification` section to the draft body with the npm version page, registry tarball
URL, integrity value, publish time, and exact CI/test proof. Keep the changelog section intact, update the draft with
`gh release edit v<version> --notes-file <reviewed-body-file>`, inspect the rendered body once more, then publish it:

```bash
gh release edit v<version> --draft=false
```

For beta versions, the script publishes with the `beta` tag. Peekaboo beta releases are still the default release, so
also run `npm dist-tag add @steipete/peekaboo@<version> latest` before publishing the GitHub draft.

## 5. Verify

- `npm view @steipete/peekaboo@<version>` reports the version, tarball, integrity, and publish time; `latest` points to
  the new version for stable and beta releases.
- Git tag and non-draft GitHub Release `v<version>` exist.
- Release body contains the complete changelog section plus npm metadata and exact CI/test proof.
- GitHub assets include the CLI archive, npm tarball, app zip, and checksums expected by the script.
- `appcast.xml` is valid and its newest item points to the new GitHub app zip with matching length and signature.
- Extracted CLI and app report the new version; codesign, stapler, and Gatekeeper verification pass.
- A fresh temporary `npx @steipete/peekaboo@<version> --help` succeeds.
- Release and Homebrew workflows complete successfully.

Commit and push the generated `appcast.xml` update if the release script leaves it dirty.

## 6. Close out

After all public verification passes, add `Unreleased` sections to both changelogs for the next patch version, commit,
push, pull `--ff-only`, and finish on clean `main`.
