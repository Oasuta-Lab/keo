# Keo — what applies

README.md explains **why** the code is the way it is. This file says **what applies**.
When in doubt about a design intent, read the matching section of the README.

## 1. Non-negotiable rule

**Keo never touches the data on the NAS.** No moving, no modifying, no deleting, no creating.
Never, under any pretext, even when asked in passing.

This is structural, not declarative:

- `ReadOnlyTransport` (`Keo/Freebox/Transport.swift`) is the only door to the NAS and
  exposes neither an HTTP method nor a request body. Writing would require adding a method to
  that type. Do not do it.
- The only `httpMethod = "POST"` in the app is the login handshake, in
  `LoginTransport`.
- `checkNothingWritesToTheNAS()` in `Tests/main.swift` re-reads the sources and fails if a
  `PUT`/`DELETE`/`PATCH`/`MOVE` or an `fs/mv`, `fs/rm`, `fs/mkdir`… route appears anywhere
  other than in a comment.

Never weaken, bypass or "temporarily" disable any of the three.

## 2. Before saying it is done

Run the check. It must be green, and this is **the** command: if a file is added to the
list, do it here and nowhere else.

```sh
rm -f /tmp/keocheck   # otherwise a failed compile re-runs the old binary and lies
swiftc -swift-version 6 -D DEBUG \
  Keo/Freebox/Item.swift Keo/Freebox/MediaSection.swift Keo/Freebox/Transport.swift \
  Keo/Freebox/FreeboxClient.swift Keo/Freebox/VideoAsset.swift \
  Keo/Downloads/DownloadJob.swift \
  Keo/Media/DiskCache.swift Keo/Media/PreviewPolicy.swift Keo/Media/FolderStamp.swift \
  Keo/Media/WalkOutcome.swift Keo/Media/SearchQuery.swift Keo/Media/Statistics.swift \
  Keo/Media/LivePhotos.swift Keo/Media/FolderExclusion.swift Keo/Media/FilenameDate.swift \
  Keo/Media/IndexStore.swift Keo/Media/PrefetchWindow.swift Keo/Media/Plural.swift \
  Keo/Media/VideoDate.swift Keo/Media/WalkSummary.swift Keo/Media/LastPass.swift Keo/Media/WidgetManifest.swift Keo/Sync/SyncModel.swift \
  Keo/UI/MediaDate.swift Keo/UI/RailLayout.swift Keo/UI/BrowserSource.swift \
  Keo/UI/DeepLink.swift Keo/UI/HumanDate.swift Keo/UI/IndexingLine.swift \
  Keo/UI/Climb.swift \
  Tests/main.swift Tests/store.swift Tests/favourites.swift Tests/videodatechecks.swift \
  Tests/sync.swift Tests/search.swift Tests/covers.swift Tests/notes.swift \
  Tests/stats.swift Tests/widget.swift Tests/links.swift Tests/live.swift Tests/dates.swift \
  Tests/exclusions.swift Tests/prefetch.swift Tests/previews.swift Tests/summary.swift \
  Tests/indexation.swift Tests/breadcrumb.swift Tests/videorange.swift \
  -o /tmp/keocheck && /tmp/keocheck
```

Then build for the device, since the check above compiles no SwiftUI file:

```sh
xcodebuild -project Keo.xcodeproj -scheme Keo -configuration Debug \
  -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|\*\* BUILD"
```

Three files exist twice, byte for byte, because the two targets share no file:
`WidgetManifest.swift`, `Theme.swift` and `Plural.swift`, in `Keo/` and in
`KeoWidget/`. Editing one without the other makes the check fail, and that is intended: it is
the only safeguard. Copy them (`cp`), do not let them diverge.

A fourth duplication cannot be byte-identical: `Photo.downsample`
(`KeoWidget/KeoWidget.swift`) and `ImageDecoding.downsample` (`Keo/Media/`) return two
different types. `checkTheDownsampleLogicMatches` compares their ImageIO options. Touching one
means touching the other.

A file in `Tests/` must not bear the name of a file in `Keo/`, case aside: the file system is
case-insensitive, both produce the same object file, and linking fails on missing symbols
without ever naming the cause. `DeepLink.swift` and `HumanDate.swift` each cost that error.

Any non-trivial logic added leaves a check behind it, in `Tests/`, in French, on the real
SQLite when it is storage. No framework, no fixtures.

## 3. Conventions

- Swift 6 with strict concurrency, targeting iOS 18, **no external dependency**: system
  frameworks only. Do not add any.
- Comments in **English**. User-facing strings and checks in **French**.
- A comment explains **why**, never what. A comment that paraphrases the line below it is to
  be deleted.
- No speculative abstraction: no protocol with one implementation, no setting for a value
  that never changes.
- Dependencies point inwards: `UI` → `Media`/`Downloads` → `Freebox`. Nothing in `Freebox`
  knows about SwiftUI.
- Logic we want to be able to check lives outside SwiftUI (`RailLayout`, `WalkOutcome`,
  `SearchQuery`, `BrowserSource.parent(of:)`). Keep it that way.

## 4. Device

The project has had **two targets** since the widget. Build with
`-allowProvisioningUpdates`: the app group must be registered against the App ID, and without
that flag signing fails for the app *and* for the extension.
The Apple team is not in the project: it is read from `Local.xcconfig`, ignored by git, which
`Signing.xcconfig` includes if it exists. One line, `DEVELOPMENT_TEAM = <id>`. Without it, the
simulator builds and the device refuses to sign.

```sh
xcodebuild -project Keo.xcodeproj -scheme Keo -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
ls ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app/PlugIns/
```

The second line is not decorative: an edit to `project.pbxproj` that loses the embed phase
produces an app that builds and installs **without its extension**, with no error.

```sh
xcrun devicectl list devices                     # UDID of the connected devices
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app
xcrun devicectl device process launch --device <UDID> --console com.oasutalab.keo \
  2>&1 | grep -a --line-buffered "\[keo\]"
```

The `[keo]` traces are also written to the app container, because the `--console` session
dies as soon as the app is relaunched from the home screen. To retrieve them:

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.oasutalab.keo \
  --source "Library/Application Support/Keo/trace.log" --destination /tmp/
```

The same mechanism pulls out `index.sqlite` when you need to know what the device really has
in its database rather than ask it.

- `CFBundleVersion` is the commit count, stamped at build time. Do not type it by hand.
- **Never reinstall while a measurement or a test is running on the device**: the install
  kills the process, and the console session with it. That has already lost a measurement.
- If `codesign` returns `errSecInternalComponent`, the session Keychain is locked: it is for
  the owner to unlock it from Terminal.app, not something to work around.

## 5. Traps that have already cost dearly

- **Crash reports are on the device**, and they give the answer in a minute where reasoning
  gives a hypothesis:
  ```sh
  xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs | grep -i keo
  xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs \
    --source "Keo-….ips" --destination /tmp/
  ```
  The `.ips` file is two JSON objects glued together: metadata on the first line, the report
  on the rest.
- **Indexing lifecycle**: three plausible, wrong fixes before the one that worked. Change
  nothing there on the strength of reasoning: plug in the device console first and start from
  what it says. See README, "Reading the device traces".
- **`Pairing.appID` is what the box authorised**, not the bundle identifier: they coincide
  today, that is all. Changing it invalidates the authorisation: token refused,
  `Store.reconnectIfPossible` throws it away, and ✓ has to be pressed again on the front of
  the Freebox. Do not touch it without saying so.
- **`navigationDestination` in a view that pushes itself.** `BrowserView` is recursive: each
  instance redeclared the destination for the same types, so a three-level stack had three
  competing ones. SwiftUI promises nothing in that case and rebuilds the destination: the
  view's state is destroyed, the grid reloads every few seconds and the playback position is
  lost. Destinations are declared **once, at the root of the stack** (`PushTargets`); pushed
  views inherit them. **The `navigationDestination(item:)` variant counts too**: the trap was
  closed for `for:` and left open for `item:`, and it came back intact, with the breadcrumb
  looping. **It came back a third time**: `HomeView` declared an `item:` *on top of* the
  `PushTargets` of the same root, and `StatsView`, which is pushed onto that stack, declared a
  third. So the rule has no exception: **no view declares a destination except the root of
  its own stack**. To push or pop, a view reads `\.stackPath`, the path the stack publishes
  in the environment. A view that can be *either* pushed *or* presented as a sheet
  (`StatsView`) opens its own stack with its own path and republishes `\.stackPath` on it;
  otherwise it inherits the path of the stack that presented it and pushes behind the sheet.
- **The modification date is not a capture date.** On a NAS it is the copy date. Never let it
  feed sorting, sections or the timeline: it pushes to the top photos nobody took that day.
  It is stated under the photo, and nowhere else.
- **SQLite schema migration**: a `NOT NULL DEFAULT 0` column on `kind` turned every
  already-indexed photo into a folder. Check what the default value means in the enumeration,
  not only in the SQL.
- **Measure, do not assume**: a benchmark that replays the same files measures the cache. A
  single sample does not replace an assumption, it disguises it.
- **Do not claim to have tested what needs the device or real iCloud.** Write the manual test
  plan in the README instead.
