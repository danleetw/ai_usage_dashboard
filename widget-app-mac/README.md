# AI Usage Widget - macOS

Swift/AppKit + WKWebView port of the Windows floating widget (`widget-app/` on the Windows
side). Same behavior: borderless, transparent, always-on-top window pinned to the top-right of
the screen, showing `index.html` in widget mode (`?widget=1[&mini=1]`), draggable by clicking
anywhere on non-interactive content.

This was written and only build-checked via `swift build` locally where a macOS toolchain was
available at write time -- it has **not** been run on an actual Mac. Build it once via the GitHub
Actions workflow (or locally on a Mac) and report back anything that breaks.

## Building

### Via GitHub Actions (no local Mac needed)

Push to `main` (touching `widget-app-mac/**`) or trigger the **Build macOS Widget** workflow
manually from the Actions tab. Download the `AI-Usage-Widget-macOS` artifact when it finishes --
it's a zip containing both `.app` bundles.

### Locally, on a Mac

```
cd widget-app-mac
swift build -c release
```

Then package into a `.app` by hand (see `.github/workflows/build-mac-widget.yml` for the exact
steps) or just run the raw binary directly for a quick check:

```
.build/release/AiDashWidgetMac
.build/release/AiDashWidgetMiniMac
```

## Installing

Unzip the downloaded artifact so both `.app` bundles end up **inside (or next to) the
`ai_dashboard` project folder** -- e.g. `ai_dashboard/mac-widget/AI Usage Widget.app`. This
matters: the app locates `server.js` by walking up from its own location, the same way the
Windows exe does, so it needs to stay somewhere under the project tree rather than being moved to
`/Applications`.

First launch: right-click the `.app` and choose **Open** (not double-click) once, since it's only
ad-hoc signed, not notarized -- Gatekeeper will otherwise refuse it outright. After the first
approved launch, double-clicking works normally.

## Command-line options

Both `.app`s accept the same flags as the Windows build (`--mini`, `--width`, `--height`,
`--margin`, `--provider`, `--base-url`); `AiDashWidgetMiniMac` just forces `--mini` on regardless
of what's passed.

## Known gaps vs. the Windows version

- No corner/edge resize (Windows' resize-by-dragging-the-border isn't ported) -- the window still
  self-sizes to fit content on load, same as Windows.
- Not notarized (see Gatekeeper note above) -- would need an Apple Developer account to fix.
