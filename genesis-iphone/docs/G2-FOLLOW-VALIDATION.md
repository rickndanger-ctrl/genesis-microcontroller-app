# Native G2 Follow validation

Validated 2026-11-14. Native 0.2.1 / build 18; standalone Genesis G2 0.3.0. This supplements the earlier build-15 app audit rather than extending its results to new features.

- Native Follow session checks: 36 passed; HTTP/store integration: 184 passed; duplicate-slot regression: 26 targeted Codex/Claude checks passed, including a pre-fix failure. Follow UI checks passed on phone and tablet; the later Conversation/Draft control wording passed its focused iPhone UI check.
- Existing transcript, audio lifecycle, and remote-core checks passed during the Follow integration. The accepted build-15 speech implementation was preserved.
- Mac display session checks: 107 passed. Ownership is explicit, state expires, stale revisions are rejected, and display updates cannot send prompts.
- User-confirmed physical iPad flow: change chats on the Mac and glasses, review a released draft on the glasses, explicitly send once, and return to the chat reply.
- User-confirmed physical same-iPhone flow: native Genesis foreground with the installed Even Beta background relay. The initial test used the wrong iPad owner; a valid takeover corrected it.
- User-confirmed G2 0.3.0 layout: exact selected Codex conversation, older/newer paging, and released draft staying in its separate bottom box. An initial failed page test was on Home with no chat selected; selecting the mapped chat restored the intended test. Live target/page/draft metadata independently matched the display acknowledgments.
- Build 18 changes only two setup-help strings and the build number after build-17 physical acceptance. Signed Release build and strict signature verification passed. In-place installs and independent version queries confirmed 0.2.1 / 18 on the intended iPhone and iPad. No speech, Send, routing, or Follow logic changed in that final copy update.

Locked relay-phone operation, full Even restart behavior, and long-duration reliability remain unverified. Leaving the native controller intentionally releases Follow. Claude reply reading, Muse integration, and automatic artifact discovery remain unavailable as documented in the README. The standalone G2 repository records its separate reader, renderer, bridge, package, and hardware evidence in [VALIDATION.md](https://github.com/rickndanger-ctrl/genesis-g2/blob/main/VALIDATION.md).
