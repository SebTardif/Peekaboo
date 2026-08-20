## [4.2.1] - 2026-08-17

### Highlights

- **Background keyboard automation now fails closed on complete target evidence.** CLI and MCP type, paste, and press share one planner that refuses fuzzy applications, partial window catalogs, ambiguous matches, and stale process identities before dispatch.
- **Protocol 1.30 makes inventory completeness and exact-target safety explicit.** New transport preserves complete-versus-partial application/window evidence while older hosts retain conservative protocol 1.29 compatibility.
- **More precise input remains off the shared cursor.** Exact-window background middle and triple clicks gain generation-bound native event sequences, while embedders can own held-pointer lifecycles with signed cleanup receipts.
- **Runtime evidence is independently verifiable.** Authenticated receipt validation and packaged digest commands let agents recompute certification evidence against the exact live Bridge that produced it.
- **Long-lived automation recovers more reliably.** Held-input cleanup is bounded to its original process generation, AX permission observation avoids cancellation deadlocks, and Realtime tool execution preserves the first terminal result.

### Added
- Add Bridge protocol 1.30 planner inventory transport with explicit complete/partial evidence, while protocol 1.29 hosts keep legacy list bytes and conservative exact-target compatibility.
- Add authenticated `peekaboo bridge receipt validate` for fail-closed, agent-readable verification of private protocol 1.29 bundles against the exact live listener that produced them.
- Add an embedding-only protocol 1.30 exact-window held-pointer lifecycle with opaque owner/hold receipts, cross-call lane ownership, and generation-bound release on explicit completion, revocation, disconnect, or watchdog expiry.
- Add capability-gated exact-window background middle/triple clicks with native center-button and 1/2/3 click-state sequences, signed target receipts, and fail-closed protocol 1.29 compatibility.
- Add a packaged version-2 digest specification plus `digest` and `verify-digests` commands so operators can independently recompute every live certification root and leaf without source access.
- Add a live-physical multi-target finalizer that binds exact protocol-1.30 background controllers, a source-owned epoch monitor, attributed foreground activity, restoration, crash evidence, and protocol-1.29 signed receipt validation into one fail-closed run.

### Fixed
- Route CLI and MCP background keyboard delivery through one completeness-aware target planner, refusing fuzzy application selectors and partial window catalogs before type, paste, or press dispatch.
- Keep exact background pointer routing and dialog postcondition checks correct for minimized and off-Space windows, while treating failed WindowServer catalog reads as unreadable instead of confirmed absence.
- Bound held-pointer owner and terminal-replay retention in long-lived hosts, make idle-owner disconnect a signed no-change close, and prevent cancelled begins from returning an already-terminated hold receipt.
- Release cancelled exact-window held hotkeys only to their original process generation, include cleanup events in typed unit counts, and never retarget cleanup to a recycled PID.
- Make application and window inventories report omitted or identity-incomplete rows as partial, while keeping complete AX-only window listings usable without Screen Recording.
- Update AXorcist and Tachikoma so Accessibility permission observation cancellation cannot deadlock the main queue or install timers after termination, while Realtime tool execution preserves the first completion/cancellation winner, keeps timeout returns bounded while owning delayed cleanup, preserves completed results during timer cancellation, and rejects invalid audio deadlines before dispatch. Thanks @SebTardif for AXorcist #46 and Tachikoma #68; follow-up fixes landed in AXorcist #48 and Tachikoma #69/#70.
