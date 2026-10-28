# X / Twitter thread

Attach: `promo/assets/ccbar-demo.gif` to tweet 2.

---

1/ I use Claude Code, Codex, GLM and Trae every day. My usage is spread across four tools, and Trae credits live on a separate web page.

So I built CCBar: a local-first usage tracker that sits in the macOS menu bar (and Windows tray).

2/ The menu bar shows today's token total and changes color as usage grows. Click it for requests, cache hit rate, hours, credits, model mix and 7 / 30-day trends. It refreshes every 30s.

There is also an optional pixel cat that runs faster as you burn more tokens.

3/ The insights center goes deeper: 90-day heatmap, model chronicle, channel breakdown, cost ranking, monthly budget, and a credits page with balance + days remaining based on your 7-day burn rate.

4/ Under the hood: today is queried live from each source, while yesterday and older are backfilled daily into a local SQLite store. The source databases are opened read-only and never modified. No account, no telemetry, no upload.

5/ Trae has no local DB, so CCBar talks to its HTTP API directly with your own credentials. v1.9.20 accepts a bare sessionid, `sessionid=...`, a full cookie string, or `X-Cloudide-Session=...`. Everything stays on your machine.

6/ Also included: CSV import/export with idempotent dedupe, daily backups with 7-copy rotation, six themes + JSON theme packs, English/Chinese UI, weekly and battle-report share cards, and a Windows tray build.

MIT licensed, built with SwiftUI + SQLite.

7/ Download:
macOS 13+ universal DMG: https://github.com/bmfish/ccbar-native/releases/latest
Windows exe: https://github.com/bmfish/ccbar-win/releases/latest/download/ccBar.exe
Site: https://ccbar-jjawpfzj0an.qoder.website

The macOS build is unsigned for now: right-click → Open on first launch, or run `xattr -dr com.apple.quarantine /Applications/CCBar.app`.

Feedback welcome.
