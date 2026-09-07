## 4.3.2 - 2026-09-07

**Highlights:** Explicit typing dispatch acceptance for scripts, plus more reliable app installation and release recovery.

- Let standalone scripts opt into `type --accept-dispatched` while preserving strict defaults, unverified outcomes, retry warnings, and confirmed-only character counts; thanks @jandubois for #686.
- Recover transactional app installs using authenticated GUI Bridge identity when atomic socket publication leaves `lsof` reporting the temporary bind path.
- Recover authenticated draft releases and accept npm's singleton-array publication metadata without weakening validation.
- Treat release-preparation binary paths literally during permission, architecture, and help checks to prevent shell interpretation.
- Fix the screenshot command documentation's link to the exact-window capture testing guide.
- Update pnpm setup in release validation and hosted build preparation to 6.1.0.
