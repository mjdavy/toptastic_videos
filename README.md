# TopTastic Videos (Canonical App)

This repository is now the **canonical** Flutter client for TopTastic Videos.

Recent improvements were merged here from the former `toptastic-client` repo:


* Timestamp + SHA256 verified chart database updates (atomic replace, integrity check)
* Preferences migration (legacy `lastDownloaded` key auto-migrated to new timestamp scheme)
* Dependency refresh (youtube_explode_dart, sqflite, shared_preferences, provider, logger, etc.)
* Added cryptographic integrity (`crypto` dependency) for database download
* Simplified and explicit utility method signatures
* Provider‑aware widget smoke test replaces boilerplate counter test

If you still have the `toptastic-client` repo locally, treat it as deprecated. New feature work should land here.

---

## Features

* Offline-first chart browsing (bundled SQLite download, refreshed only when remote timestamp changes)
* Online fallback + server-driven video update endpoints
* Favorites management (persisted via SharedPreferences)
* YouTube playlist / individual video integration
* Integrity-checked DB refresh with SHA-256 hash match

---

## Data Refresh & Migration Details

| Aspect | Old Behavior | New Behavior |
|--------|--------------|--------------|
| Refresh heuristic | Redownload if > 1 day | Compare remote `timestamp.txt` vs stored `lastDownloadedTimestamp` |
| Integrity | None | Verify `songs.sha256` before installing DB |
| Install method | Direct overwrite | Atomic: write temp, verify, rename |
| Pref key | `lastDownloaded` | `lastDownloadedTimestamp` + `lastDbSha256` |

On first run after upgrade:

* If only the legacy `lastDownloaded` key exists, it is removed and a fresh validated DB fetch is triggered.

Manual refresh (force re-check):

1. Open Settings → toggle Refresh DB
2. Return to home (next load will refetch if remote changed)

---

## Developer Workflow

Run the app:

```bash
flutter run
```

Analyze & format:

```bash
flutter analyze
flutter test
```

(Optional) build iOS / Android release:

```bash
flutter build ipa
flutter build appbundle
```

### Smoke Test

The widget test (`test/widget_test.dart`) mounts the provider + app and verifies core UI elements. Expand with additional tests for:

* Offline → Online toggle behavior
* Video update flow (mock HTTP)
* Favorites persistence

### Forcing a DB Refresh Programmatically

You can call:

```dart
await updateLastDownloaded(reset: true);
```

before fetching to invalidate the local timestamp.

---

## Configuration

Settings stored keys:

| Key | Purpose |
|-----|---------|
| `serverName` | Host for API (when not offline) |
| `port` | Port for API |
| `offlineMode` | Boolean flag deciding offline vs server fetch |
| `lastDownloadedTimestamp` | Remote timestamp last applied |
| `lastDbSha256` | Integrity hash of stored DB |
| `favorite_ids` | JSON list of favorited song IDs |

---

## Repository Hygiene
If `toptastic-client` is still active in remotes/CI:

1. Merge any outstanding unique changes (none expected beyond what is already here)
2. Archive or add a README pointer in that repo referencing this one
3. Update any CI/CD platform (Xcode Cloud) to ensure it targets this directory only

---

## Roadmap Ideas

* Add integration tests with a mocked HTTP server
* Introduce dependency injection for easier testability of data layer
* Add caching layer for online fetches
* Dark mode theming & theming settings
* Migrate lints to stricter profile gradually

---

## License
Private / Internal (adjust if you intend to publish).

