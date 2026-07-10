## [3.8.0] - 2026-07-09

### Added
- The agent, CLI, macOS model pickers, and session UI now support Claude Fable 5, Claude Sonnet 5, and the GPT-5.6 Sol, Terra, and Luna preview models, including their current context, output, effort, pricing, and non-streaming safety behavior.

### Changed
- The menu bar icon was redesigned as a crisp template ghost with a camera-lens belly that echoes the app icon, now rendered at proper 1x/2x/3x resolutions; it previously shipped a single blurry 18px bitmap reused for all Retina scales.
- Peekaboo.app releases now use the OpenClaw Foundation Developer ID identity while retaining the bundle identifier and Sparkle update key; the standalone CLI keeps its legacy signing team so it remains compatible with pre-3.8 GUI bridge hosts, and 3.8 hosts trust both release teams. macOS may ask once to reconfirm protected-data access after the app signing-team migration.

### Fixed
- The macOS Sessions window and agent popover stay unavailable while Agent mode is disabled, including Dock reopens, global shortcuts, notifications, and windows already open when the setting is turned off.
- The GUI bridge now enforces both signing Team ID and bundle ID on every request, preventing unrelated same-team processes from borrowing Peekaboo's protected macOS permissions.
