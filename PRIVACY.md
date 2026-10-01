# ClipyMe privacy

Updated October 1, 2026.

Clipboard history, snippets, preferences, favorites, and the text search index stay on your Mac. ClipyMe does not send clipboard contents or search queries to external services. Data is not encrypted by the app. Installer backups are private to your user account and retained until you remove them.

Automatic update checks contact `api.github.com` for the latest public release of `khandelwaly940/clipy.me`. GitHub receives standard network information, including your IP address and an app-version User-Agent. Checks run at most once daily unless you explicitly click Check Now; disabled or longer-interval settings are respected. Opening a release page or running the installer also contacts GitHub and its download hosts.

The public build includes no Firebase configuration, so inherited Firebase analytics and crash reporting are not configured. Developers who add their own Firebase configuration change that behavior and must disclose it. The inherited Sparkle updater is disabled; updates use this repository's release-notice service.

The installer does not upload clipboard data, preferences, backups, or its local signing key. Its backup verifier reports counts and verification status, not clip contents. The signing key remains in your login Keychain.

For issues, visit https://github.com/khandelwaly940/clipy.me/issues. Do not include clipboard databases, secrets, or private snippets in public reports.
