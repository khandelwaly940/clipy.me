# ClipyMe

A lightweight, native macOS clipboard manager based on [Clipy](https://github.com/Clipy/Clipy), with search inside the original menu, sorting, favorites, and a text editor. macOS 13 or newer; Apple Silicon and Intel.

## Install or migrate from Clipy

Run in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/khandelwaly940/clipy.me/main/scripts/install.sh -o /tmp/clipyme-install.sh && bash /tmp/clipyme-install.sh
```

[Read the installer](scripts/install.sh) · [Download release](https://github.com/khandelwaly940/clipy.me/releases/latest)

No Xcode, Homebrew, or Python is needed. The installer downloads the latest universal release, checks its SHA-256 checksum and signatures, stops the clipboard monitors, makes a private verified backup, preserves preferences and login settings, and launches ClipyMe. Run the same command to update.

Supported migrations: Clipy 1.2.x (its existing Realm importer) and Clipy 1.3.0 (verified SQLite copy), plus existing ClipyMe installations. Newer unknown Clipy database schemas are refused to protect data. SQLite migrations and updates compare every stored row and asset byte before switching. Realm conversion has fixture coverage, but has not been tested on every historical Clipy release. Keep the backup until you have checked your history and snippets.

Original Clipy and its data remain on disk. Backups live in `~/Library/Application Support/ClipyMe Backups/`. The installer restores the previous app/data if installation fails after the switch. Do not run both clipboard managers at once.

On first installation, enable **ClipyMe** in **System Settings → Privacy & Security → Accessibility**. macOS does not transfer Clipy's permission. The installer creates a signing identity in your login Keychain and reuses it on updates so the app's identity stays stable. This is a community build, locally signed by the installer, not an Apple-notarized distribution.

## Everyday use

- Open the normal Clipy menu using your existing shortcut (for example Control–Space), then type. Results appear in that menu immediately after the database query finishes. There is no debounce delay or flashing “Searching…” row.
- Clear the query to restore the original history folders and menu layout. Click a clip or press Return on a result to use the original paste action.
- **Sort History** offers Best Match, original order, newest, oldest, alphabetical, or content type. Best Match ranks exact titles, prefixes, phrases, then matches across the title ahead of matches only in the body. Every query word must occur in the clip; unrelated fuzzy matches are excluded. Existing explicitly selected sort preferences are preserved.
- Hover over a search result for the normal tooltip preview, respecting your existing preview setting and length. A match-context preview loads on demand, including matches beyond the menu title.
- **Command–F** opens the advanced history panel, with filters, favorites, copy/paste, and plain-text editing. The redundant Search/Edit menu row is hidden.
- Text replacement is transactional. Rich content can be edited as a new plain-text clip, preserving the original. Favorites survive automatic history pruning; an explicit Clear History still clears them.

Search uses SQLite's existing database pool and a small full-text index. It does not decode images, poll the history, or maintain a duplicate in-memory clipboard cache. Text verification uses small, overlapping reads so a large clip is not loaded in full for a simple match. Queries run off the UI thread; superseded queued requests are cancelled and stale results discarded. The menu displays up to 30 matches; Command–F supports more results. Actual latency depends on history size, query, hardware, and sort order.

## Updates

ClipyMe checks [this repository's releases](https://github.com/khandelwaly940/clipy.me/releases) at most once daily by default. Existing disabled, weekly, or monthly preferences are respected. Change them in **Preferences → Updates**. “Check Now” is available regardless of automatic settings.

A new version prompts once with **View Release** or **Later**. Nothing is downloaded or installed automatically. Run the installer again when ready. Official Clipy releases cannot overwrite this custom build.

## Build and validate

Developed with Xcode 27; the upstream project requires a recent Swift/Xcode toolchain.

```sh
xcodebuild -project Clipy.xcodeproj -scheme Clipy -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
bash scripts/package_release.sh
```

For Release-mode tests, also pass `-configuration Release CLIPYME_TESTABILITY=YES CLIPYME_BUNDLE_IDENTIFIER=local.clipyme.tests` so test preferences stay separate from the installed app.

The packaging script builds both architectures and the standalone migration helpers, verifies signatures, runs migration verification tests, and produces `build/release/ClipyMe-macos-universal.zip` and its checksum. Developer tools are required only for building. Release packaging does not include signing keys, clipboard data, settings, or Firebase configuration.

To verify a downloaded release without installation:

```sh
bash /tmp/clipyme-install.sh --verify-only
```

## Recovery

Quit ClipyMe before restoring. Each backup includes `Previous.app`, `preferences.plist`, and the source application's support data when present. For migration from original Clipy, quit ClipyMe and reopen `/Applications/Clipy.app`; its original settings/data remain available. Clips captured only in ClipyMe are separate, so retain its data as well. For an update rollback, restore the backup app and corresponding custom support/preferences together while both apps are closed.

## Credits and license

Maintained by [Yash Khandelwal](https://github.com/khandelwaly940). Based on Clipy 1.3.0; this is an independent fork, not an official Clipy release. Thanks to the Clipy Project and ClipMenu contributors. The original MIT license and notices are retained in [LICENSE](LICENSE). Third-party notices are included in the app's acknowledgements and dependencies. [Privacy policy](PRIVACY.md).
