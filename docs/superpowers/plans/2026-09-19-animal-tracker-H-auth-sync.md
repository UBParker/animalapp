# AnimalTracker Plan H: Sign in with Apple and Supabase sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate AnimalTracker behind native Sign in with Apple against Supabase Auth, and sync animals, voice recordings, vocalizations, voice tags and recorded audio to a per-user Supabase project while SwiftData stays the offline working store.

**Architecture:** SwiftData remains the single source of truth the UI reads. Every synced model gains `updatedAt`, every local delete writes a `DeletedRecord` tombstone, and a pure `SyncEngine` moves rows between a `LocalStore` (SwiftData) and a `RemoteStore` (PostgREST plus Storage) using last-write-wins on `updatedAt`. Auth is a small `@MainActor` `AuthService` over `supabase-swift`; `RootView` maps its state onto a screen through a pure `RootGate` so the gating logic is unit-testable without a network or a UI test.

**Tech Stack:** Swift 5 language mode, iOS 17, SwiftUI, SwiftData, XCTest, XcodeGen, AuthenticationServices, CryptoKit, supabase-swift 2.x (the only third-party package), Supabase Postgres with Row Level Security, Supabase Storage, the Supabase CLI.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md`, in particular "Addendum v7 (2026-09-19): Supabase backend and Sign in with Apple", plus `docs/superpowers/specs/2026-09-18-model-contract.md` for field names.

## Global Constraints

- Swift 5 language mode (`SWIFT_VERSION: "5.0"` in `project.yml`), iOS deployment target 17.0.
- The only third-party package in the app is `supabase-swift`. The two local packages `AnimalVoiceAudio` and `AnimalVoiceStats` stay as they are.
- Supabase project ref: `ojzmtyapkaxxliuurssc`. Project URL: `https://ojzmtyapkaxxliuurssc.supabase.co`.
- Bundle id `com.ashlab.AnimalTracker`. Apple Developer team `A5S59B326M`.
- `App/Config/Supabase.plist` ships the literal placeholder `REPLACE_WITH_ANON_KEY`. No other secret ever enters the repo: not the anon key, not the database password, not the Supabase access token.
- Every model that syncs (`Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`) has `@Attribute(.unique) var id: UUID`, `var createdAt: Date = Date()` and `var updatedAt: Date = Date()`. Every stored property has a default or is optional. CloudKit stays off (`cloudKitDatabase: .none`).
- Server columns are snake_case mirrors of the model fields. Every table has `id uuid primary key`, `user_id uuid not null references auth.users(id) on delete cascade`, `updated_at timestamptz not null default now()`, `deleted_at timestamptz`.
- Row Level Security is enabled on every table with select, insert, update and delete policies keyed on `user_id = auth.uid()`.
- Tests are XCTest, run with `scripts/test-app.sh`, and never touch the live network. Every remote interaction in a test goes through `InMemoryRemoteStore`.
- TDD per task: write the failing test, run it and see it fail, implement, run it and see it pass, commit.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Plan A is implemented (`AnimalTrackerApp`, `RootTabView`, `SettingsView`, `PersistenceController`, `Seeds`, `KeychainStore`, `MediaStore` with `\.mediaStore`, `ManageAnimalsView`, `AnimalFormView`). Plan B tasks 13 to 18 are implemented (`VoiceRecording`, `Vocalization`, `VoiceTag`, `VoiceTagSeed`, `TagPropagation`, `AnalysisService`, `AudioPlayer`, `VoiceTabView`, `RecordView`, `TagSheet`, `VoiceHistoryView`, `RecordingDetailView`, `VocalizationEditView`, `VocalizationPlayButton`, `AskView`, `InsightsView`, `ManageVoiceTagsView`).

---

## Assumptions

Every API name below was checked against live documentation on 2026-09-22. Nothing here is invented; where a documented sample omits something, that is called out with the fallback.

- **Package.** `https://github.com/supabase/supabase-swift`, pinned `from: "2.0.0"`, which resolves to the newest 2.x. The newest tag on 2026-09-22 is `v2.55.2` (`https://api.github.com/repos/supabase/supabase-swift/releases/latest`). The README lists the products `Supabase`, `Auth`, `PostgREST`, `Realtime`, `Storage`, `Functions`; this plan links only the umbrella `Supabase` product. Source: https://github.com/supabase/supabase-swift
- **Client.** `SupabaseClient(supabaseURL: URL, supabaseKey: String)`. Source: https://github.com/supabase/supabase-swift
- **Sign in.** `try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: "...", nonce: "..."))` returns a `Session`. Source: https://supabase.com/docs/reference/swift/auth-signinwithidtoken
- **Nonce.** The Swift sample on https://supabase.com/docs/guides/auth/social-login/auth-apple passes only `idToken` and omits the nonce, but the reference page above documents the `nonce:` parameter, and the same guide's Flutter sample shows the rule: Apple receives `sha256(rawNonce)` and the backend receives the raw nonce. This plan follows that rule: `request.nonce = Nonce.sha256(rawNonce)` (lowercase hex) and `nonce: rawNonce` to Supabase. Known risk: https://github.com/supabase/auth/issues/2378 reports a hex versus base64url mismatch in GoTrue's nonce check. Documented fallback if a live sign-in fails with "Nonces mismatch": drop the nonce on both sides (do not set `request.nonce`, and construct `OpenIDConnectCredentials(provider: .apple, idToken: idToken)`), which is exactly what the official Swift sample does. Task 11 records which of the two paths worked.
- **Session.** `try await supabase.auth.session` is an async throwing property; `supabase.auth.currentSession` is the non-validating accessor. Source: https://supabase.com/docs/reference/swift/auth-getsession. `Session.user` is a `User`; this plan reads `user.id` as `UUID` and `user.email` as `String?`. Fallback if the installed version types `id` as `String`: wrap with `UUID(uuidString:)` and treat nil as a sign-in failure.
- **Sign out.** `try await supabase.auth.signOut()`, no scope parameter. Source: https://supabase.com/docs/reference/swift/auth-signout
- **Upsert.** `try await supabase.from("table").upsert(encodableValueOrArray, onConflict: "id").execute()`. Primary keys must be present in the values. Source: https://supabase.com/docs/reference/swift/upsert
- **Select.** `let rows: [Row] = try await supabase.from("table").select().gt("updated_at", value: ...).execute().value`, decoding into a `Decodable`. Source: https://supabase.com/docs/reference/swift/select
- **Storage upload.** `try await supabase.storage.from("bucket").upload(path: "folder/file.m4a", file: data, options: FileOptions(cacheControl: "3600", contentType: "audio/mp4", upsert: true))`. Source: https://supabase.com/docs/reference/swift/storage-from-upload
- **Storage download.** `let data = try await supabase.storage.from("bucket").download(path: "folder/file.m4a")` returns `Data`. Source: https://supabase.com/docs/reference/swift/storage-from-download
- **Supabase side configuration** (done in the dashboard by Ash, not by this plan): the Apple provider is enabled and `com.ashlab.AnimalTracker` is listed under Client IDs. Native sign-in needs no OAuth secret. Source: https://supabase.com/docs/guides/auth/social-login/auth-apple
- **Date wire format.** Row structs are encoded and decoded on the wire by supabase-swift's own PostgREST coders. Our tests exercise our own `SyncCoding.encoder` and `SyncCoding.decoder` (ISO 8601 with fractional seconds) so the snake_case keys and the field set are covered without asserting anything about the SDK's internals.
- **Filter value typing.** `.gt("updated_at", value:)` is given an ISO 8601 `String`, not a `Date`, so no assumption about the SDK's date-to-filter conversion is needed.
- **`PersistenceController.destroy()` and `makeContainerWithRecovery()`** are being added in a separate fix wave. Task 4 checks for them and adds them with the exact bodies shown only if they are absent; if they are already there with those names, leave the existing bodies alone.
- **Container rebuild strategy (resolved).** `AnimalTrackerApp` holds the `ModelContainer` in `@State` and replaces it. `AuthService` publishes `storeResetToken: UUID`; the app observes it, calls `PersistenceController.destroy()`, builds a new container, re-runs `Seeds.runAll`, and bumps a generation counter used as `.id(...)` on `RootView` so every `@Query` re-subscribes. No relaunch prompt.
- **Foreign keys between synced tables are deliberately omitted** (`animal_id`, `recording_id` are plain `uuid` columns). Sync pushes tables in an arbitrary order, so a real FK would reject a child pushed before its parent.
- **Tombstone payloads.** A tombstone is a normal row upsert with `deleted_at` set and the other columns filled from each row type's `tombstone(id:userID:deletedAt:)` factory, so no column has to be nullable just for deletes.

---

## File map

**New, auth:**
- `App/Config/Supabase.plist`: project URL plus the placeholder anon key.
- `App/Config/SupabaseConfig.swift`: reads that plist, returns nil for the placeholder.
- `App/Auth/Nonce.swift`: random nonce and lowercase-hex SHA-256.
- `App/Auth/AuthService.swift`: `AuthState`, `AuthError`, `StoreResetPolicy`, `AuthService`.
- `App/Views/Auth/SignInView.swift`: Sign in with Apple button and the DEBUG offline button.
- `App/Views/Auth/RootView.swift`: `RootScreen`, `RootGate`, `RootView`, `OfflineBanner`.
- `App/AnimalTracker.entitlements`: generated by XcodeGen from `project.yml`.

**New, sync:**
- `App/Models/DeletedRecord.swift`: local tombstone model plus the `Tombstone` helper.
- `App/Sync/SyncState.swift`: `SyncTable`, `SyncState` (UserDefaults-backed).
- `App/Sync/SyncRows.swift`: `SyncCoding`, `RemoteAudioPath`, the four row structs.
- `App/Sync/RemoteStore.swift`: the `RemoteStore` protocol and `InMemoryRemoteStore`.
- `App/Sync/SupabaseRemoteStore.swift`: the PostgREST and Storage implementation.
- `App/Sync/LocalStore.swift`: `LocalStore`, `DeletedRecordInfo`, `PendingAudio`, `SwiftDataLocalStore`.
- `App/Sync/SyncEngine.swift`: push, pull, tombstones, last-write-wins, audio upload.
- `App/Sync/SyncService.swift`: main-actor driver, debounce, published status.
- `App/Sync/MediaResolver.swift`: on-demand audio download for playback.

**New, server:**
- `supabase/config.toml`
- `supabase/migrations/20260919120000_voice_milestone.sql`

**Modified:**
- `project.yml`: package, product dependency, entitlements, `DEVELOPMENT_TEAM`, plist resource, migration resource in the test target.
- `App/AnimalTrackerApp.swift`: auth object, replaceable container, scene-phase sync.
- `App/Persistence/PersistenceController.swift`: `DeletedRecord` plus the voice models in `modelTypes`; `destroy()` and `makeContainerWithRecovery()` if the fix wave has not added them.
- `App/Models/Animal.swift`, `App/Models/VoiceRecording.swift`, `App/Models/Vocalization.swift`, `App/Models/VoiceTag.swift`: `@Attribute(.unique)` on `id`, `updatedAt`, and `audioUploadedAt` on `VoiceRecording`.
- `App/Media/MediaStore.swift`: `write(_:as:)` on the protocol and on `InMemoryMediaStore`.
- `App/Media/FileMediaStore.swift`: `write(_:as:)`.
- `App/Views/Settings/SettingsView.swift`: Account section.
- `App/Views/Animals/AnimalFormView.swift`, `App/Views/Animals/ManageAnimalsView.swift`, `App/Views/Voice/RecordView.swift`, `App/Views/Voice/TagSheet.swift`, `App/Views/Voice/VoiceHistoryView.swift`, `App/Views/Voice/RecordingDetailView.swift`, `App/Views/Voice/VocalizationEditView.swift`, `App/Views/Voice/AskView.swift`, `App/Views/Voice/ManageVoiceTagsView.swift`: stamp `updatedAt`, write tombstones, request a sync.

**New tests:**
- `AppTests/SupabaseConfigTests.swift`, `AppTests/NonceTests.swift`, `AppTests/AuthServiceTests.swift`, `AppTests/RootGateTests.swift`, `AppTests/MigrationFileTests.swift`, `AppTests/SyncStateTests.swift`, `AppTests/SyncRowTests.swift`, `AppTests/LocalStoreTests.swift`, `AppTests/SyncEngineTests.swift`, `AppTests/MediaResolverTests.swift`.

---

### Task 1: XcodeGen wiring for supabase-swift, the Sign in with Apple entitlement, and the signing team

**Files:**
- Modify: `project.yml` (packages, settings.base, the `AnimalTracker` target's sources, entitlements and dependencies, the `AnimalTrackerTests` target's dependencies)
- Create: `AppTests/SupabasePackageLinkTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the `Supabase` module is importable from both `App/` and `AppTests/`; `SupabaseClient(supabaseURL:supabaseKey:)` is available; the app target carries `com.apple.developer.applesignin = [Default]` and `DEVELOPMENT_TEAM = A5S59B326M`; `App/Config/Supabase.plist` is copied into the app bundle as a resource; `supabase/migrations/*.sql` is copied into the test bundle as a resource.

- [ ] **Step 1: Write the failing test**

This test proves the package is linked and the umbrella product exposes the type we build everything else on. It makes no network call: constructing a `SupabaseClient` does no I/O.

Create `AppTests/SupabasePackageLinkTests.swift`:
```swift
import Supabase
import XCTest
@testable import AnimalTracker

final class SupabasePackageLinkTests: XCTestCase {
    func testSupabaseClientIsLinkedAndInitializesWithoutNetwork() {
        let client = SupabaseClient(supabaseURL: URL(string: "https://example.supabase.co")!,
                                    supabaseKey: "anon-key-not-real")
        XCTAssertNotNil(client.auth)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `no such module 'Supabase'` for `AppTests/SupabasePackageLinkTests.swift`.

- [ ] **Step 3: Add the package, the product, the entitlement, the team and the resources**

Replace the whole of `project.yml` with this. The changes against the current file are: the `Supabase` entry under `packages`, `DEVELOPMENT_TEAM` set to the real team, the split `sources` list that copies `App/Config/Supabase.plist` as a resource, the `entitlements` block, the `Supabase` product dependency on both targets, and the migration resource on the test target.

```yaml
name: AnimalTracker
options:
  bundleIdPrefix: com.ashlab
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
packages:
  AnimalVoiceAudio:
    path: Packages/AnimalVoiceAudio
  AnimalVoiceStats:
    path: Packages/AnimalVoiceStats
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: 2.0.0
settings:
  base:
    SWIFT_VERSION: "5.0"
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: A5S59B326M
targets:
  AnimalTracker:
    type: application
    platform: iOS
    sources:
      - path: App
        excludes:
          - Config/Supabase.plist
      - path: App/Config/Supabase.plist
        buildPhase: resources
    entitlements:
      path: App/AnimalTracker.entitlements
      properties:
        com.apple.developer.applesignin: [Default]
    dependencies:
      - package: AnimalVoiceAudio
      - package: AnimalVoiceStats
      - package: Supabase
        product: Supabase
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: AnimalTracker
        NSMicrophoneUsageDescription: AnimalTracker records your animal's sounds and your spoken check-ins.
        NSSpeechRecognitionUsageDescription: AnimalTracker transcribes your spoken check-in on this device.
        NSCameraUsageDescription: AnimalTracker takes photos and videos for health check-ins and animal avatars.
        NSPhotoLibraryUsageDescription: AnimalTracker attaches photos and videos from your library.
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
  AnimalTrackerTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: AppTests
      - path: supabase/migrations
        buildPhase: resources
        optional: true
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: AnimalTracker
      - package: AnimalVoiceAudio
      - package: AnimalVoiceStats
      - package: Supabase
        product: Supabase
schemes:
  AnimalTracker:
    build:
      targets:
        AnimalTracker: all
        AnimalTrackerTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets: [AnimalTrackerTests]
```

`optional: true` on the migrations path lets `xcodegen generate` succeed before Task 5 creates that folder.

- [ ] **Step 4: Create the placeholder plist so the resource path exists**

The full config plist arrives in Task 2, but `project.yml` now names the file, so create it here or `xcodegen generate` fails.

Create `App/Config/Supabase.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SupabaseURL</key>
	<string>https://ojzmtyapkaxxliuurssc.supabase.co</string>
	<key>SupabaseAnonKey</key>
	<string>REPLACE_WITH_ANON_KEY</string>
</dict>
</plist>
```

- [ ] **Step 5: Regenerate and resolve the package**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
xcodegen generate
xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker -resolvePackageDependencies 2>&1 | tail -5
```
Expected: resolution succeeds and prints a `supabase-swift` version of the form `2.x.y`. Record the resolved version; Task 11 quotes it in the commit message for the final push.

- [ ] **Step 6: Run the test to verify it passes, and verify the simulator build still signs**

Run: `scripts/test-app.sh`
Expected: `Executed N tests, with 0 failures`, including `testSupabaseClientIsLinkedAndInitializesWithoutNetwork`.

Then run: `scripts/build-app.sh`
Expected: `** BUILD SUCCEEDED **`.

Then confirm the entitlement really reached the built app:
```bash
APP="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 -path '*Build/Products/Debug-iphonesimulator/AnimalTracker.app' | head -1)"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -A2 applesignin
```
Expected: the output contains `com.apple.developer.applesignin` with `Default`.

- [ ] **Step 7: Fallback if the simulator build fails to sign**

Only do this if Step 6's `scripts/build-app.sh` fails with a code-signing or provisioning-profile error (for example `No profiles for 'com.ashlab.AnimalTracker' were found`). The scripts no longer pass `CODE_SIGNING_ALLOWED=NO`, so a Mac without the team's provisioning assets can fail here. The fallback applies the entitlements file to device builds only.

Replace the `entitlements:` block in the `AnimalTracker` target with a per-SDK setting, and commit the entitlements file by hand instead of letting XcodeGen write it:

```yaml
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]: App/AnimalTracker.entitlements
```

Create `App/AnimalTracker.entitlements` (XcodeGen no longer generates it in this configuration, so it has to exist in the repo):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
</dict>
</plist>
```

Re-run `xcodegen generate`, `scripts/build-app.sh` and `scripts/test-app.sh`. Expected: `** BUILD SUCCEEDED **` and all tests pass. With this fallback the simulator has no Sign in with Apple entitlement, so the simulator smoke test in Task 11 uses the DEBUG "Continue offline" path and the real Apple sign-in is exercised on the device only. Write one sentence in the commit body recording that the fallback was used.

- [ ] **Step 8: Commit**

```bash
git add project.yml App/Config/Supabase.plist AppTests/SupabasePackageLinkTests.swift App/AnimalTracker.entitlements
git commit -m "build: link supabase-swift, add the Sign in with Apple entitlement and the signing team

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

If `App/AnimalTracker.entitlements` is XcodeGen-generated (no fallback used), `git add` of a missing path fails; drop it from the `git add` line in that case and add `AnimalTracker.xcodeproj` only if it is tracked.

---

### Task 2: SupabaseConfig, with the placeholder anon key meaning "run offline"

**Files:**
- Modify: `App/Config/Supabase.plist` (already created in Task 1; verify its contents)
- Create: `App/Config/SupabaseConfig.swift`
- Create: `AppTests/SupabaseConfigTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct SupabaseConfig: Equatable { let url: URL; let anonKey: String }`, `SupabaseConfig.placeholderKey = "REPLACE_WITH_ANON_KEY"`, `SupabaseConfig.make(url: String?, anonKey: String?) -> SupabaseConfig?`, `SupabaseConfig.load(bundle: Bundle = .main) -> SupabaseConfig?`.

- [ ] **Step 1: Write the failing test**

Create `AppTests/SupabaseConfigTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SupabaseConfigTests: XCTestCase {
    func testMakeAcceptsARealLookingKey() {
        let config = SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig")
        XCTAssertEqual(config?.url.absoluteString, "https://ojzmtyapkaxxliuurssc.supabase.co")
        XCTAssertEqual(config?.anonKey, "eyJhbGciOiJIUzI1NiJ9.payload.sig")
    }

    func testMakeRejectsThePlaceholderKey() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: "REPLACE_WITH_ANON_KEY"))
    }

    func testMakeRejectsThePlaceholderKeyWithSurroundingWhitespace() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: "  REPLACE_WITH_ANON_KEY\n"))
    }

    func testMakeRejectsEmptyOrMissingValues() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: ""))
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: nil))
        XCTAssertNil(SupabaseConfig.make(url: "", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertNil(SupabaseConfig.make(url: nil, anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
    }

    func testMakeRejectsAUrlThatIsNotHttps() {
        XCTAssertNil(SupabaseConfig.make(url: "not a url", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertNil(SupabaseConfig.make(url: "http://ojzmtyapkaxxliuurssc.supabase.co", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
    }

    /// The shipped plist always names the project, whether or not the real key has been substituted.
    func testBundledPlistCarriesTheProjectUrl() throws {
        let bundle = SupabaseConfig.appBundle
        let path = try XCTUnwrap(bundle.path(forResource: "Supabase", ofType: "plist"),
                                 "App/Config/Supabase.plist is not in the app bundle")
        let dict = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
        XCTAssertEqual(dict["SupabaseURL"] as? String, "https://ojzmtyapkaxxliuurssc.supabase.co")
        XCTAssertNotNil(dict["SupabaseAnonKey"] as? String)
    }
}
```

`SupabaseConfig.appBundle` resolves through a token class declared in the app target, so it is the app bundle and not the test bundle. It is defined in Step 3.

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `cannot find 'SupabaseConfig' in scope`.

- [ ] **Step 3: Write the implementation**

Create `App/Config/SupabaseConfig.swift`:
```swift
import Foundation

/// The Supabase project the app talks to. `Supabase.plist` ships with a placeholder anon key so the
/// repo never holds a credential; until the real key is substituted, `load()` returns nil and the app
/// runs fully offline against the local SwiftData store.
struct SupabaseConfig: Equatable {
    /// The literal value committed to `App/Config/Supabase.plist`. Anything equal to this is "not configured".
    static let placeholderKey = "REPLACE_WITH_ANON_KEY"

    let url: URL
    let anonKey: String

    /// The bundle that carries `Supabase.plist`. Resolved through a type defined in the app target,
    /// so a test host resolves to the app bundle rather than the test bundle.
    static var appBundle: Bundle { Bundle(for: SupabaseConfigBundleToken.self) }

    static func make(url: String?, anonKey: String?) -> SupabaseConfig? {
        let trimmedKey = (anonKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey != placeholderKey else { return nil }
        let trimmedURL = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmedURL), parsed.scheme == "https", parsed.host != nil else { return nil }
        return SupabaseConfig(url: parsed, anonKey: trimmedKey)
    }

    static func load(bundle: Bundle = SupabaseConfig.appBundle) -> SupabaseConfig? {
        guard let path = bundle.path(forResource: "Supabase", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return make(url: dict["SupabaseURL"] as? String, anonKey: dict["SupabaseAnonKey"] as? String)
    }
}

/// Anchor for `Bundle(for:)`. Has no other purpose.
final class SupabaseConfigBundleToken: NSObject {}
```

- [ ] **Step 4: Verify the plist contents**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
/usr/libexec/PlistBuddy -c "Print" App/Config/Supabase.plist
```
Expected:
```
Dict {
    SupabaseURL = https://ojzmtyapkaxxliuurssc.supabase.co
    SupabaseAnonKey = REPLACE_WITH_ANON_KEY
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, six `SupabaseConfigTests` cases green.

- [ ] **Step 6: Document how the real key is supplied without committing it**

Append this section to `README.md`:
```markdown
## Supabase key

`App/Config/Supabase.plist` is committed with `SupabaseAnonKey = REPLACE_WITH_ANON_KEY`. With the
placeholder in place the app runs offline and shows an offline banner. To run against the real
project, substitute the anon key locally and tell git to ignore the change:

```bash
/usr/libexec/PlistBuddy -c "Set :SupabaseAnonKey <the anon key>" App/Config/Supabase.plist
git update-index --skip-worktree App/Config/Supabase.plist
```

To go back to the placeholder before committing:

```bash
git update-index --no-skip-worktree App/Config/Supabase.plist
git checkout -- App/Config/Supabase.plist
```
```

- [ ] **Step 7: Commit**

```bash
git add App/Config/SupabaseConfig.swift AppTests/SupabaseConfigTests.swift App/Config/Supabase.plist README.md
git commit -m "feat(config): load the Supabase project from a plist, treating the placeholder key as offline

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Nonce, sync bookkeeping state, and AuthService

**Files:**
- Create: `App/Auth/Nonce.swift`
- Create: `App/Sync/SyncState.swift`
- Create: `App/Auth/AuthService.swift`
- Create: `AppTests/NonceTests.swift`
- Create: `AppTests/SyncStateTests.swift`
- Create: `AppTests/AuthServiceTests.swift`

**Interfaces:**
- Consumes: `SupabaseConfig` (Task 2).
- Produces:
  - `enum Nonce { static let alphabet: [Character]; static func random(length: Int = 32) -> String; static func sha256(_ input: String) -> String }` (hex, lowercase).
  - `enum AuthState: Equatable { case unknown, signedOut, signedIn(userID: UUID, email: String?), offline }`.
  - `enum AuthError: Error, LocalizedError { case notConfigured, missingIdentityToken }`.
  - `enum StoreResetPolicy { static func shouldReset(lastSyncedUserID: String?, newUserID: UUID) -> Bool }`.
  - `enum SyncTable: String, CaseIterable { case animals = "animals", voiceRecordings = "voice_recordings", vocalizations = "vocalizations", voiceTags = "voice_tags" }`.
  - `struct SyncState: Codable, Equatable` with `var lastPulledAt: [String: Date]`, `var lastPushedAt: [String: Date]`, `var lastSyncStatus: String`, `var lastSyncedAt: Date?`, `var lastSyncedUserID: String?`, `func lastPulled(_:) -> Date`, `func lastPushed(_:) -> Date`, `mutating func setLastPulled(_:_:)`, `mutating func setLastPushed(_:_:)`, `mutating func forgetUser()`, `static func load(defaults:) -> SyncState`, `func save(defaults:)`, `static let defaultsKey = "animalTracker.syncState"`, `static let epoch: Date`.
  - `@MainActor final class AuthService: ObservableObject` with `init(config: SupabaseConfig? = SupabaseConfig.load())`, `let client: SupabaseClient?`, `var isConfigured: Bool`, `@Published private(set) var state: AuthState`, `@Published private(set) var storeResetToken: UUID`, `func restoreSession() async`, `func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws`, `func signOut() async`, `func leaveOfflineMode()`, and under `#if DEBUG` `func continueOffline()`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/NonceTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class NonceTests: XCTestCase {
    func testAlphabetIsExactlySixtyFourCharactersSoTheModuloIsUniform() {
        XCTAssertEqual(Nonce.alphabet.count, 64)
        XCTAssertEqual(Set(Nonce.alphabet).count, 64)
    }

    func testRandomHasTheRequestedLengthAndOnlyAlphabetCharacters() {
        let value = Nonce.random(length: 32)
        XCTAssertEqual(value.count, 32)
        XCTAssertTrue(value.allSatisfy { Nonce.alphabet.contains($0) })
    }

    func testRandomDefaultsToThirtyTwo() {
        XCTAssertEqual(Nonce.random().count, 32)
    }

    func testRandomDoesNotRepeat() {
        let values = (0..<50).map { _ in Nonce.random() }
        XCTAssertEqual(Set(values).count, 50)
    }

    /// Known SHA-256 vectors, so a change of encoding (hex versus base64, upper versus lower) is caught.
    func testSha256MatchesKnownVectors() {
        XCTAssertEqual(Nonce.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Nonce.sha256(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSha256IsLowercaseHexOfSixtyFourCharacters() {
        let digest = Nonce.sha256(Nonce.random())
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
```

Create `AppTests/SyncStateTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SyncStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "SyncStateTests-\(UUID().uuidString)")
    }

    func testTableRawValuesMatchTheServerTableNames() {
        XCTAssertEqual(SyncTable.animals.rawValue, "animals")
        XCTAssertEqual(SyncTable.voiceRecordings.rawValue, "voice_recordings")
        XCTAssertEqual(SyncTable.vocalizations.rawValue, "vocalizations")
        XCTAssertEqual(SyncTable.voiceTags.rawValue, "voice_tags")
        XCTAssertEqual(SyncTable.allCases.count, 4)
    }

    func testUnsetWatermarksAreTheEpoch() {
        let state = SyncState()
        XCTAssertEqual(state.lastPulled(.animals), SyncState.epoch)
        XCTAssertEqual(state.lastPushed(.voiceTags), SyncState.epoch)
    }

    func testWatermarksRoundTripThroughUserDefaults() {
        var state = SyncState()
        let pulled = Date(timeIntervalSince1970: 1_750_000_000)
        let pushed = Date(timeIntervalSince1970: 1_750_000_500)
        state.setLastPulled(.animals, pulled)
        state.setLastPushed(.vocalizations, pushed)
        state.lastSyncStatus = "Synced"
        state.lastSyncedAt = pushed
        state.lastSyncedUserID = "11111111-1111-1111-1111-111111111111"
        state.save(defaults: defaults)

        let loaded = SyncState.load(defaults: defaults)
        XCTAssertEqual(loaded.lastPulled(.animals).timeIntervalSince1970, pulled.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.lastPushed(.vocalizations).timeIntervalSince1970, pushed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.lastPulled(.voiceTags), SyncState.epoch)
        XCTAssertEqual(loaded.lastSyncStatus, "Synced")
        XCTAssertEqual(loaded.lastSyncedUserID, "11111111-1111-1111-1111-111111111111")
    }

    func testLoadOnEmptyDefaultsReturnsAFreshState() {
        let loaded = SyncState.load(defaults: defaults)
        XCTAssertEqual(loaded, SyncState())
    }

    func testForgetUserClearsTheUserAndEveryWatermark() {
        var state = SyncState()
        state.setLastPulled(.animals, Date(timeIntervalSince1970: 1_750_000_000))
        state.setLastPushed(.animals, Date(timeIntervalSince1970: 1_750_000_000))
        state.lastSyncedUserID = "abc"
        state.forgetUser()
        XCTAssertNil(state.lastSyncedUserID)
        XCTAssertEqual(state.lastPulled(.animals), SyncState.epoch)
        XCTAssertEqual(state.lastPushed(.animals), SyncState.epoch)
    }
}
```

Create `AppTests/AuthServiceTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class AuthServiceTests: XCTestCase {
    func testUnconfiguredServiceHasNoClient() {
        let auth = AuthService(config: nil)
        XCTAssertFalse(auth.isConfigured)
        XCTAssertEqual(auth.state, .unknown)
    }

    func testRestoreSessionWithoutConfigGoesOffline() async {
        let auth = AuthService(config: nil)
        await auth.restoreSession()
        XCTAssertEqual(auth.state, .offline)
    }

    func testSignOutFromOfflineReturnsToSignedOutAndResetsTheStore() async {
        let auth = AuthService(config: nil)
        let before = auth.storeResetToken
        await auth.signOut()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNotEqual(auth.storeResetToken, before)
    }

    func testLeaveOfflineModeDoesNotResetTheStore() {
        let auth = AuthService(config: nil)
        let before = auth.storeResetToken
        auth.leaveOfflineMode()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.storeResetToken, before)
    }

    func testStoreResetPolicy() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertFalse(StoreResetPolicy.shouldReset(lastSyncedUserID: nil, newUserID: a))
        XCTAssertFalse(StoreResetPolicy.shouldReset(lastSyncedUserID: "", newUserID: a))
        XCTAssertFalse(StoreResetPolicy.shouldReset(lastSyncedUserID: a.uuidString, newUserID: a))
        XCTAssertFalse(StoreResetPolicy.shouldReset(lastSyncedUserID: a.uuidString.lowercased(), newUserID: a))
        XCTAssertTrue(StoreResetPolicy.shouldReset(lastSyncedUserID: b.uuidString, newUserID: a))
    }

    func testAuthStateEquatability() {
        let a = UUID()
        XCTAssertEqual(AuthState.signedIn(userID: a, email: "x@y.z"), .signedIn(userID: a, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.signedIn(userID: a, email: nil), .signedIn(userID: a, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.offline, .signedOut)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `cannot find 'Nonce' in scope` and `cannot find 'AuthService' in scope`.

- [ ] **Step 3: Write Nonce and SyncState**

Create `App/Auth/Nonce.swift`:
```swift
import CryptoKit
import Foundation
import Security

/// Sign in with Apple nonce handling. Apple is given the SHA-256 hash of the nonce and puts that hash
/// in the identity token; Supabase is given the raw nonce and re-hashes it to check the token.
/// Both halves are pure so they can be tested without an Apple account.
enum Nonce {
    /// Exactly 64 characters, so `UInt8 % 64` is uniform (256 is a multiple of 64) and every
    /// character is URL-safe.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")

    static func random(length: Int = 32) -> String {
        precondition(length > 0, "nonce length must be positive")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status)")
        var result = ""
        result.reserveCapacity(length)
        for byte in bytes { result.append(alphabet[Int(byte) % alphabet.count]) }
        return result
    }

    /// Lowercase hex, which is what Apple's sample code and the Supabase guide both use.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

Create `App/Sync/SyncState.swift`:
```swift
import Foundation

/// The four synced tables. The raw value is the Postgres table name.
enum SyncTable: String, CaseIterable {
    case animals = "animals"
    case voiceRecordings = "voice_recordings"
    case vocalizations = "vocalizations"
    case voiceTags = "voice_tags"
}

/// Sync bookkeeping. Small enough to live in UserDefaults as one JSON blob, and deliberately not in
/// SwiftData, because wiping the store on a user change must not wipe the record of which user we are.
struct SyncState: Codable, Equatable {
    static let defaultsKey = "animalTracker.syncState"
    /// The watermark for "never pulled" and "never pushed".
    static let epoch = Date(timeIntervalSince1970: 0)

    var lastPulledAt: [String: Date] = [:]
    var lastPushedAt: [String: Date] = [:]
    var lastSyncStatus: String = "Never synced"
    var lastSyncedAt: Date?
    var lastSyncedUserID: String?

    func lastPulled(_ table: SyncTable) -> Date { lastPulledAt[table.rawValue] ?? SyncState.epoch }
    func lastPushed(_ table: SyncTable) -> Date { lastPushedAt[table.rawValue] ?? SyncState.epoch }

    mutating func setLastPulled(_ table: SyncTable, _ date: Date) { lastPulledAt[table.rawValue] = date }
    mutating func setLastPushed(_ table: SyncTable, _ date: Date) { lastPushedAt[table.rawValue] = date }

    /// Forgets the user and every watermark, so the next sign-in pulls everything from scratch.
    mutating func forgetUser() {
        lastSyncedUserID = nil
        lastPulledAt = [:]
        lastPushedAt = [:]
        lastSyncedAt = nil
        lastSyncStatus = "Never synced"
    }

    static func load(defaults: UserDefaults = .standard) -> SyncState {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
```

- [ ] **Step 4: Write AuthService**

Create `App/Auth/AuthService.swift`:
```swift
import AuthenticationServices
import Foundation
import Supabase

enum AuthState: Equatable {
    /// Before the first session restore finishes.
    case unknown
    case signedOut
    case signedIn(userID: UUID, email: String?)
    /// DEBUG "Continue offline", or a build whose anon key is still the placeholder.
    case offline
}

enum AuthError: Error, LocalizedError {
    case notConfigured
    case missingIdentityToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no Supabase anon key, so it cannot sign in."
        case .missingIdentityToken:
            return "Apple did not return an identity token."
        }
    }
}

/// Whether signing in as this user must wipe the local store first. One person's animals must never
/// appear under another person's account on the same phone.
enum StoreResetPolicy {
    static func shouldReset(lastSyncedUserID: String?, newUserID: UUID) -> Bool {
        guard let lastSyncedUserID, !lastSyncedUserID.isEmpty else { return false }
        return lastSyncedUserID.lowercased() != newUserID.uuidString.lowercased()
    }
}

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .unknown
    /// Bumped whenever the local SwiftData store must be destroyed and rebuilt. `AnimalTrackerApp`
    /// watches this value.
    @Published private(set) var storeResetToken = UUID()

    let client: SupabaseClient?

    init(config: SupabaseConfig? = SupabaseConfig.load()) {
        if let config {
            client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
        } else {
            client = nil
        }
    }

    var isConfigured: Bool { client != nil }

    /// Restores the SDK-persisted session on launch. With no anon key the app goes straight to offline.
    func restoreSession() async {
        guard let client else {
            state = .offline
            return
        }
        do {
            let session = try await client.auth.session
            apply(userID: session.user.id, email: session.user.email)
        } catch {
            state = .signedOut
        }
    }

    func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws {
        guard let client else { throw AuthError.notConfigured }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
        // Apple hands back the email only on the very first authorization, so fall back to it.
        apply(userID: session.user.id, email: session.user.email ?? credential.email)
    }

    func signOut() async {
        if let client { try? await client.auth.signOut() }
        var syncState = SyncState.load()
        syncState.forgetUser()
        syncState.save()
        state = .signedOut
        storeResetToken = UUID()
    }

    /// Leaves DEBUG offline mode without touching local data.
    func leaveOfflineMode() {
        state = .signedOut
    }

    #if DEBUG
    /// Simulator and review builds: reach the tabs without an Apple account.
    func continueOffline() {
        state = .offline
    }
    #endif

    private func apply(userID: UUID, email: String?) {
        if StoreResetPolicy.shouldReset(lastSyncedUserID: SyncState.load().lastSyncedUserID, newUserID: userID) {
            var fresh = SyncState()
            fresh.lastSyncedUserID = userID.uuidString
            fresh.save()
            storeResetToken = UUID()
        }
        state = .signedIn(userID: userID, email: email)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `NonceTests` six cases, `SyncStateTests` five cases and `AuthServiceTests` six cases are green, and nothing in them touches the network.

- [ ] **Step 6: Commit**

```bash
git add App/Auth/Nonce.swift App/Sync/SyncState.swift App/Auth/AuthService.swift \
        AppTests/NonceTests.swift AppTests/SyncStateTests.swift AppTests/AuthServiceTests.swift
git commit -m "feat(auth): nonce generation and hashing, sync watermarks, AuthService over Supabase Auth

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Sign-in screen, RootView gating, a replaceable ModelContainer, and the Settings Account section

**Files:**
- Create: `App/Views/Auth/RootView.swift`
- Create: `App/Views/Auth/SignInView.swift`
- Create: `AppTests/RootGateTests.swift`
- Create: `AppTests/ContainerResetTests.swift`
- Modify: `App/Persistence/PersistenceController.swift` (add `storeURLs`, `destroy()`, `makeContainerWithRecovery()` if the fix wave has not already added them)
- Modify: `App/AnimalTrackerApp.swift` (whole file replaced)
- Modify: `App/Views/Settings/SettingsView.swift` (add `@EnvironmentObject` and the Account section)

**Interfaces:**
- Consumes: `AuthState`, `AuthService`, `Nonce` (Task 3); `RootTabView`, `PersistenceController`, `Seeds` (Plan A).
- Produces: `enum RootScreen: Equatable { case loading, signIn, main(showsOfflineBanner: Bool) }`; `enum RootGate { static func screen(for state: AuthState) -> RootScreen }`; `struct RootView: View`; `struct OfflineBanner: View`; `struct SignInView: View`; `PersistenceController.storeURLs: [URL]`, `PersistenceController.destroy()`, `PersistenceController.makeContainerWithRecovery() throws -> ModelContainer`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/RootGateTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class RootGateTests: XCTestCase {
    func testUnknownShowsLoading() {
        XCTAssertEqual(RootGate.screen(for: .unknown), .loading)
    }

    func testSignedOutShowsTheSignInScreen() {
        XCTAssertEqual(RootGate.screen(for: .signedOut), .signIn)
    }

    func testSignedInShowsTheTabsWithNoBanner() {
        XCTAssertEqual(RootGate.screen(for: .signedIn(userID: UUID(), email: "ash@example.com")),
                       .main(showsOfflineBanner: false))
    }

    func testSignedInWithoutAnEmailStillShowsTheTabs() {
        XCTAssertEqual(RootGate.screen(for: .signedIn(userID: UUID(), email: nil)),
                       .main(showsOfflineBanner: false))
    }

    func testOfflineShowsTheTabsWithTheBanner() {
        XCTAssertEqual(RootGate.screen(for: .offline), .main(showsOfflineBanner: true))
    }

    /// The scripted-state walk a real session takes: launch, restore fails, sign in, sign out.
    func testScriptedStateSequence() {
        let userID = UUID()
        let script: [AuthState] = [.unknown, .signedOut, .signedIn(userID: userID, email: nil), .signedOut]
        XCTAssertEqual(script.map(RootGate.screen(for:)),
                       [.loading, .signIn, .main(showsOfflineBanner: false), .signIn])
    }
}
```

Create `AppTests/ContainerResetTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ContainerResetTests: XCTestCase {
    func testMakeContainerWithRecoveryOpensAStore() throws {
        let container = try PersistenceController.makeContainerWithRecovery()
        XCTAssertFalse(container.schema.entities.isEmpty)
    }

    func testDestroyRemovesEveryStoreFileAndTheStoreReopensEmpty() throws {
        let first = try PersistenceController.makeContainerWithRecovery()
        first.mainContext.insert(Animal(name: "Miso", species: "cat"))
        try first.mainContext.save()
        XCTAssertEqual(try first.mainContext.fetch(FetchDescriptor<Animal>()).count, 1)

        PersistenceController.destroy()
        for url in PersistenceController.storeURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "left behind \(url.lastPathComponent)")
        }

        let second = try PersistenceController.makeContainerWithRecovery()
        XCTAssertEqual(try second.mainContext.fetch(FetchDescriptor<Animal>()).count, 0)
    }
}
```

This test writes to the app's real on-disk store inside the simulator, which is the only place `destroy()` can be exercised honestly. It leaves the store empty, which is the state a fresh install is in.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'RootGate' in scope` and `type 'PersistenceController' has no member 'destroy'`. If the fix wave has already landed `destroy()` and `makeContainerWithRecovery()`, only `RootGate` fails; that is fine, keep going.

- [ ] **Step 3: Add the store lifecycle helpers**

Open `App/Persistence/PersistenceController.swift`. If it already declares `destroy()` and `makeContainerWithRecovery()` from the fix wave, leave those bodies alone and only add `storeURLs` if it is missing. Otherwise append these three members inside `enum PersistenceController`, after `makeContainer(inMemory:)`:

```swift
    /// The files SwiftData creates for the default on-disk configuration.
    static var storeURLs: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["default.store", "default.store-shm", "default.store-wal"].map {
            support.appendingPathComponent($0)
        }
    }

    /// Deletes every local record. Called when the signed-in user changes, so one person's animals
    /// never show up under another person's account on the same phone.
    static func destroy() {
        for url in storeURLs { try? FileManager.default.removeItem(at: url) }
    }

    /// Opens the store; on an unrecoverable schema or file error, wipes it and opens a fresh one.
    /// Losing local records is the right trade here: everything synced is still on the server.
    static func makeContainerWithRecovery() throws -> ModelContainer {
        do {
            return try makeContainer()
        } catch {
            destroy()
            return try makeContainer()
        }
    }
```

- [ ] **Step 4: Write RootView and the gate**

Create `App/Views/Auth/RootView.swift`:
```swift
import SwiftUI

/// What the root shows. Kept separate from the view so the gating rule is unit-testable.
enum RootScreen: Equatable {
    case loading
    case signIn
    case main(showsOfflineBanner: Bool)
}

enum RootGate {
    static func screen(for state: AuthState) -> RootScreen {
        switch state {
        case .unknown:
            return .loading
        case .signedOut:
            return .signIn
        case .signedIn:
            return .main(showsOfflineBanner: false)
        case .offline:
            return .main(showsOfflineBanner: true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        Group {
            switch RootGate.screen(for: auth.state) {
            case .loading:
                ProgressView("Loading")
            case .signIn:
                SignInView()
            case .main(let showsOfflineBanner):
                VStack(spacing: 0) {
                    if showsOfflineBanner { OfflineBanner() }
                    RootTabView()
                }
            }
        }
        .task { await auth.restoreSession() }
    }
}

struct OfflineBanner: View {
    var body: some View {
        Text("Offline. Records stay on this phone and are not backed up.")
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.orange.opacity(0.25))
            .accessibilityIdentifier("offlineBanner")
    }
}
```

- [ ] **Step 5: Write the sign-in screen**

Create `App/Views/Auth/SignInView.swift`:
```swift
import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService
    /// Regenerated for every authorization request; Apple gets its SHA-256, Supabase gets this value.
    @State private var rawNonce = Nonce.random()
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("AnimalTracker")
                .font(.largeTitle.bold())
            Text("Sign in to back up your animals, recordings and tags.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !auth.isConfigured {
                Text("This build has no Supabase key, so sign-in is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            SignInWithAppleButton(.signIn) { request in
                rawNonce = Nonce.random()
                request.requestedScopes = [.email]
                request.nonce = Nonce.sha256(rawNonce)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .disabled(isWorking || !auth.isConfigured)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            #if DEBUG
            Button("Continue offline") { auth.continueOffline() }
                .font(.footnote)
                .accessibilityIdentifier("continueOffline")
            #endif
            Spacer()
        }
        .padding(32)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            errorMessage = nil
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    try await auth.signInWithApple(authorization: authorization, rawNonce: rawNonce)
                } catch {
                    errorMessage = "Could not sign in: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            // A cancel is not an error worth shouting about.
            if (error as? ASAuthorizationError)?.code == .canceled {
                errorMessage = nil
            } else {
                errorMessage = "Could not sign in: \(error.localizedDescription)"
            }
        }
    }
}
```

- [ ] **Step 6: Replace the app entry point so the container can be swapped**

Replace the whole of `App/AnimalTrackerApp.swift`:
```swift
import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    @StateObject private var auth = AuthService()
    /// Held in @State so a user change can throw the store away and put a new one here.
    @State private var container: ModelContainer
    /// Bumped with the container; used as RootView's identity so every @Query re-subscribes.
    @State private var storeGeneration = 0

    init() {
        let opened: ModelContainer
        do {
            opened = try PersistenceController.makeContainerWithRecovery()
        } catch {
            fatalError("Cannot open the data store: \(error)")
        }
        Seeds.runAll(context: opened.mainContext)
        _container = State(initialValue: opened)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .id(storeGeneration)
                .onChange(of: auth.storeResetToken) { _, _ in resetStore() }
        }
        .modelContainer(container)
    }

    /// Destroys the local store and opens a fresh, seeded one. Triggered by AuthService when the
    /// user signs out or signs in as someone other than the last synced user.
    @MainActor
    private func resetStore() {
        PersistenceController.destroy()
        do {
            let fresh = try PersistenceController.makeContainerWithRecovery()
            Seeds.runAll(context: fresh.mainContext)
            container = fresh
            storeGeneration += 1
        } catch {
            fatalError("Cannot reopen the data store after a reset: \(error)")
        }
    }
}

/// One-time seeds. Later plans append their seed functions to `all`.
enum Seeds {
    static let all: [(ModelContext) -> Void] = [VoiceTagSeed.run]

    static func runAll(context: ModelContext) {
        for seed in all { seed(context) }
    }
}
```

`Seeds.all` already contains `VoiceTagSeed.run` from Plan B Task 13. If the file on disk lists more seed closures, keep that list exactly as it is and change only the `AnimalTrackerApp` struct above it.

- [ ] **Step 7: Add the Account section to Settings**

In `App/Views/Settings/SettingsView.swift`, add one property after line 4 (`@Environment(\.dismiss) private var dismiss`):
```swift
    @EnvironmentObject private var auth: AuthService
```

and insert this section as the first section inside `Form { ... }`, immediately before the existing `Section("Animals")` at line 13:
```swift
            Section("Account") {
                switch auth.state {
                case .signedIn(let userID, let email):
                    LabeledContent("Signed in as", value: email ?? userID.uuidString)
                    Button("Sign out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                case .offline:
                    Text("Offline. Records stay on this phone and are not backed up.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Sign in") { auth.leaveOfflineMode() }
                case .signedOut, .unknown:
                    Button("Sign in") { auth.leaveOfflineMode() }
                }
            }
```

`SettingsView` is presented as a sheet from `App/AnimalSwitcher.swift:61`, and a sheet inherits the presenter's environment, so the `.environmentObject(auth)` applied to `RootView` in Step 6 reaches it with no extra wiring.

Also change the About copy at line 39 from

```swift
                Text("All records and media stay on this phone. Only oral check-in transcripts are sent to Anthropic, using your own key.")
```

to

```swift
                Text("Animals, voice recordings and tags sync to your Supabase account. Oral check-in transcripts are sent to Anthropic, using your own key.")
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `RootGateTests` six cases and `ContainerResetTests` two cases are green, and every earlier test still passes.

- [ ] **Step 9: See it on the simulator**

Run: `scripts/run-sim.sh`
Expected: `build/screenshot.png` shows the five tabs with the orange "Offline. Records stay on this phone and are not backed up." banner above them. With the placeholder anon key `SupabaseConfig.load()` returns nil, `restoreSession()` sets `.offline`, and `RootGate` returns `.main(showsOfflineBanner: true)`, so the sign-in screen is skipped by design. The sign-in screen is exercised in Task 11 with the real key.

Correction if the screenshot shows the tabs without the banner: `OfflineBanner()` is not wired into the `main` branch of `RootView`. Correction if it shows the sign-in screen: `Supabase.plist` no longer holds `REPLACE_WITH_ANON_KEY`.

- [ ] **Step 10: Commit**

```bash
git add App/Views/Auth/RootView.swift App/Views/Auth/SignInView.swift App/AnimalTrackerApp.swift \
        App/Persistence/PersistenceController.swift App/Views/Settings/SettingsView.swift \
        AppTests/RootGateTests.swift AppTests/ContainerResetTests.swift
git commit -m "feat(auth): gate the tabs behind Sign in with Apple, rebuild the store on a user change

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The SQL migration, the Supabase CLI wiring, and a test that the migration says what it must

**Files:**
- Create: `supabase/config.toml`
- Create: `supabase/migrations/20260919120000_voice_milestone.sql`
- Create: `AppTests/MigrationFileTests.swift`
- Modify: `README.md` (how to apply the migration)

**Interfaces:**
- Consumes: nothing from earlier tasks. The table and column names here are what Task 7's row structs encode to.
- Produces: tables `public.animals`, `public.voice_recordings`, `public.vocalizations`, `public.voice_tags`; the private storage bucket `voice-audio`; the column names the app's row structs use.

- [ ] **Step 1: Write the failing test**

The migration ships into the test bundle as a resource (Task 1 already added `supabase/migrations` to the test target), so the test reads the real file rather than a copy.

Create `AppTests/MigrationFileTests.swift`:
```swift
import XCTest

final class MigrationFileTests: XCTestCase {
    private func migrationSQL() throws -> String {
        let bundle = Bundle(for: MigrationFileTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "20260919120000_voice_milestone", withExtension: "sql"),
                                "the migration is not in the test bundle; check project.yml")
        return try String(contentsOf: url, encoding: .utf8).lowercased()
    }

    func testCreatesTheFourTables() throws {
        let sql = try migrationSQL()
        for table in ["public.animals", "public.voice_recordings", "public.vocalizations", "public.voice_tags"] {
            XCTAssertTrue(sql.contains("create table if not exists \(table)"), "missing create table for \(table)")
        }
    }

    func testEnablesRowLevelSecurityOnEveryTable() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(sql.components(separatedBy: "enable row level security").count - 1, 4)
    }

    func testEveryTableIsOwnedByAUserWithCascadingDelete() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(sql.components(separatedBy: "references auth.users(id) on delete cascade").count - 1, 4)
    }

    func testPoliciesAreKeyedOnTheAuthenticatedUser() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("user_id = auth.uid()"))
        for verb in ["for select", "for insert", "for update", "for delete"] {
            XCTAssertTrue(sql.contains(verb), "missing a policy \(verb)")
        }
    }

    func testIndexesUserAndUpdatedAt() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(sql.components(separatedBy: "(user_id, updated_at)").count - 1, 4)
    }

    func testCreatesThePrivateAudioBucketAndItsPolicies() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("insert into storage.buckets"))
        XCTAssertTrue(sql.contains("'voice-audio'"))
        XCTAssertTrue(sql.contains("name like auth.uid()::text || '/%'"))
    }

    func testEveryTableCarriesUpdatedAtAndDeletedAt() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(sql.components(separatedBy: "updated_at timestamptz not null default now()").count - 1, 4)
        XCTAssertEqual(sql.components(separatedBy: "deleted_at timestamptz,").count - 1, 4)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-app.sh`
Expected: FAIL with "the migration is not in the test bundle; check project.yml".

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260919120000_voice_milestone.sql`:
```sql
-- Voice milestone schema: animals, voice recordings, vocalizations and voice tags, mirroring the
-- SwiftData models field for field in snake_case, plus the three sync columns (user_id, updated_at,
-- deleted_at) and a private bucket for the recorded audio.
--
-- animal_id and recording_id are plain uuid columns on purpose: sync pushes tables in an arbitrary
-- order, so a real foreign key would reject a child row that arrives before its parent.

create table if not exists public.animals (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    name text not null default '',
    species text not null default '',
    color_hex text not null default '',
    photo_filename text,
    photo_thumbnail_filename text,
    tracks_outdoor_time boolean not null default true,
    sort_order integer not null default 0,
    is_archived boolean not null default false,
    note text
);

create table if not exists public.voice_recordings (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    animal_id uuid,
    recorded_at timestamptz not null default now(),
    duration_s double precision not null default 0,
    audio_filename text not null default '',
    status_raw text not null default 'recorded',
    error_message text,
    note text not null default '',
    activity_tag text,
    meaning_tag text,
    user_confidence integer,
    edited_at timestamptz,
    audio_uploaded_at timestamptz
);

create table if not exists public.vocalizations (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    recording_id uuid,
    start_s double precision not null default 0,
    end_s double precision not null default 0,
    f0_mean double precision,
    f0_min double precision,
    f0_max double precision,
    f0_slope double precision,
    voiced_fraction double precision not null default 0,
    rms_db double precision not null default -160,
    spectral_centroid_hz double precision not null default 0,
    mfcc double precision[] not null default '{}',
    activity_tag text,
    meaning_tag text,
    user_confidence integer,
    overridden boolean not null default false
);

create table if not exists public.voice_tags (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    kind_raw text not null default 'activity',
    name text not null default '',
    is_built_in boolean not null default false,
    sort_order integer not null default 0
);

create index if not exists animals_user_updated_idx on public.animals (user_id, updated_at);
create index if not exists voice_recordings_user_updated_idx on public.voice_recordings (user_id, updated_at);
create index if not exists vocalizations_user_updated_idx on public.vocalizations (user_id, updated_at);
create index if not exists voice_tags_user_updated_idx on public.voice_tags (user_id, updated_at);

alter table public.animals enable row level security;
alter table public.voice_recordings enable row level security;
alter table public.vocalizations enable row level security;
alter table public.voice_tags enable row level security;

drop policy if exists animals_select_own on public.animals;
drop policy if exists animals_insert_own on public.animals;
drop policy if exists animals_update_own on public.animals;
drop policy if exists animals_delete_own on public.animals;
create policy animals_select_own on public.animals for select using (user_id = auth.uid());
create policy animals_insert_own on public.animals for insert with check (user_id = auth.uid());
create policy animals_update_own on public.animals for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy animals_delete_own on public.animals for delete using (user_id = auth.uid());

drop policy if exists voice_recordings_select_own on public.voice_recordings;
drop policy if exists voice_recordings_insert_own on public.voice_recordings;
drop policy if exists voice_recordings_update_own on public.voice_recordings;
drop policy if exists voice_recordings_delete_own on public.voice_recordings;
create policy voice_recordings_select_own on public.voice_recordings for select using (user_id = auth.uid());
create policy voice_recordings_insert_own on public.voice_recordings for insert with check (user_id = auth.uid());
create policy voice_recordings_update_own on public.voice_recordings for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy voice_recordings_delete_own on public.voice_recordings for delete using (user_id = auth.uid());

drop policy if exists vocalizations_select_own on public.vocalizations;
drop policy if exists vocalizations_insert_own on public.vocalizations;
drop policy if exists vocalizations_update_own on public.vocalizations;
drop policy if exists vocalizations_delete_own on public.vocalizations;
create policy vocalizations_select_own on public.vocalizations for select using (user_id = auth.uid());
create policy vocalizations_insert_own on public.vocalizations for insert with check (user_id = auth.uid());
create policy vocalizations_update_own on public.vocalizations for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy vocalizations_delete_own on public.vocalizations for delete using (user_id = auth.uid());

drop policy if exists voice_tags_select_own on public.voice_tags;
drop policy if exists voice_tags_insert_own on public.voice_tags;
drop policy if exists voice_tags_update_own on public.voice_tags;
drop policy if exists voice_tags_delete_own on public.voice_tags;
create policy voice_tags_select_own on public.voice_tags for select using (user_id = auth.uid());
create policy voice_tags_insert_own on public.voice_tags for insert with check (user_id = auth.uid());
create policy voice_tags_update_own on public.voice_tags for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy voice_tags_delete_own on public.voice_tags for delete using (user_id = auth.uid());

-- Private bucket for the recorded audio. Objects are stored at "<user_id>/<audioFilename>".
insert into storage.buckets (id, name, public)
values ('voice-audio', 'voice-audio', false)
on conflict (id) do nothing;

drop policy if exists voice_audio_select_own on storage.objects;
drop policy if exists voice_audio_insert_own on storage.objects;
drop policy if exists voice_audio_update_own on storage.objects;
drop policy if exists voice_audio_delete_own on storage.objects;
create policy voice_audio_select_own on storage.objects for select
    using (bucket_id = 'voice-audio' and name like auth.uid()::text || '/%');
create policy voice_audio_insert_own on storage.objects for insert
    with check (bucket_id = 'voice-audio' and name like auth.uid()::text || '/%');
create policy voice_audio_update_own on storage.objects for update
    using (bucket_id = 'voice-audio' and name like auth.uid()::text || '/%')
    with check (bucket_id = 'voice-audio' and name like auth.uid()::text || '/%');
create policy voice_audio_delete_own on storage.objects for delete
    using (bucket_id = 'voice-audio' and name like auth.uid()::text || '/%');
```

- [ ] **Step 4: Write the CLI config**

Create `supabase/config.toml`:
```toml
# Minimal config so `supabase link` and `supabase db push` know which project this folder belongs to.
project_id = "ojzmtyapkaxxliuurssc"
```

- [ ] **Step 5: Regenerate and run the test to verify it passes**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
xcodegen generate
scripts/test-app.sh
```
Expected: PASS. `MigrationFileTests` seven cases are green.

- [ ] **Step 6: Apply the migration to the live project**

The access token and the database password never enter the repo. Supply the token through the environment for the length of the shell command only.

```bash
cd /Users/asheslab/Documents/work/cat-voice
read -rs SUPABASE_ACCESS_TOKEN && export SUPABASE_ACCESS_TOKEN
supabase link --project-ref ojzmtyapkaxxliuurssc
supabase db push
unset SUPABASE_ACCESS_TOKEN
```
Expected: `supabase db push` reports `Applying migration 20260919120000_voice_milestone.sql...` and `Finished supabase db push.`

`read -rs` keeps the token off the screen and out of the shell history when history is on. `supabase link` prompts for the database password; type it, never paste it into a file.

Fallback with psql, for a machine without the Supabase CLI. The connection string comes from the project's database settings and holds the password, so it is typed into the shell, never written to a file:

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -v ON_ERROR_STOP=1 -f supabase/migrations/20260919120000_voice_milestone.sql
unset PGURI
```
Expected: `CREATE TABLE` four times, `CREATE INDEX` four times, `ALTER TABLE` four times, `CREATE POLICY` twenty times, `INSERT 0 1` (or `INSERT 0 0` on a re-run).

- [ ] **Step 7: Verify the schema landed**

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select tablename, rowsecurity from pg_tables where schemaname='public' order by tablename;"
psql "$PGURI" -c "select id, public from storage.buckets where id='voice-audio';"
unset PGURI
```
Expected: four rows with `rowsecurity = t`, and one bucket row with `public = f`.

If the CLI was used instead of psql, the equivalent check is `supabase db diff --linked`, which should report no differences.

- [ ] **Step 8: Document the commands in the README**

Append to `README.md`:
```markdown
## Supabase schema

The schema lives in `supabase/migrations/`. To apply it:

```bash
read -rs SUPABASE_ACCESS_TOKEN && export SUPABASE_ACCESS_TOKEN
supabase link --project-ref ojzmtyapkaxxliuurssc
supabase db push
unset SUPABASE_ACCESS_TOKEN
```

The access token and the database password are never stored in the repo. Without the CLI, apply
the same file with `psql "$PGURI" -v ON_ERROR_STOP=1 -f supabase/migrations/<file>.sql`.
```

- [ ] **Step 9: Commit**

```bash
git add supabase/config.toml supabase/migrations/20260919120000_voice_milestone.sql \
        AppTests/MigrationFileTests.swift README.md project.yml
git commit -m "feat(server): voice milestone schema with RLS and the private voice-audio bucket

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Sync fields on the models, the DeletedRecord tombstone, and a media store that can write a known filename

**Files:**
- Modify: `App/Models/Animal.swift:6` (unique id), after `App/Models/Animal.swift:7` (updatedAt)
- Modify: `App/Models/VoiceRecording.swift` (unique id, `updatedAt`, `audioUploadedAt`)
- Modify: `App/Models/Vocalization.swift` (unique id, `updatedAt`)
- Modify: `App/Models/VoiceTag.swift` (unique id, `updatedAt`)
- Create: `App/Models/DeletedRecord.swift`
- Modify: `App/Persistence/PersistenceController.swift:6-8` (`modelTypes`)
- Modify: `App/Media/MediaStore.swift` (protocol method plus the in-memory implementation)
- Modify: `App/Media/FileMediaStore.swift` (implementation)
- Create: `AppTests/SyncFieldTests.swift`

**Interfaces:**
- Consumes: `SyncTable` (Task 3); `Animal`, `MediaStore`, `InMemoryMediaStore`, `FileMediaStore`, `PersistenceController` (Plan A); `VoiceRecording`, `Vocalization`, `VoiceTag` (Plan B Task 13).
- Produces: `updatedAt: Date` on `Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`; `audioUploadedAt: Date?` on `VoiceRecording`; `@Model final class DeletedRecord` with `id`, `createdAt`, `entity: String`, `recordID: UUID`, `deletedAt: Date` and `init(entity:recordID:deletedAt:)`; `enum Tombstone { static func record(_ table: SyncTable, id: UUID, in context: ModelContext); static func recordRecording(_ recording: VoiceRecording, in context: ModelContext) }`; `MediaStore.write(_ data: Data, as filename: String) throws`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/SyncFieldTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class SyncFieldTests: XCTestCase {
    func testEverySyncedModelStampsUpdatedAtOnCreation() throws {
        let before = Date()
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Miso", species: "cat")
        let recording = VoiceRecording(audioFilename: "a-audio.m4a", durationS: 1)
        let vocalization = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        let tag = VoiceTag(kind: .meaning, name: "Hungry")
        context.insert(animal)
        context.insert(recording)
        context.insert(vocalization)
        context.insert(tag)
        try context.save()

        XCTAssertGreaterThanOrEqual(animal.updatedAt, before)
        XCTAssertGreaterThanOrEqual(recording.updatedAt, before)
        XCTAssertGreaterThanOrEqual(vocalization.updatedAt, before)
        XCTAssertGreaterThanOrEqual(tag.updatedAt, before)
        XCTAssertNil(recording.audioUploadedAt)
    }

    func testDeletedRecordStoresTheEntityAndTheId() throws {
        let context = try TestSupport.container().mainContext
        let gone = UUID()
        Tombstone.record(.animals, id: gone, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DeletedRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].entity, "animals")
        XCTAssertEqual(rows[0].recordID, gone)
    }

    func testRecordingTombstoneAlsoCoversItsVocalizations() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "b-audio.m4a", durationS: 1)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        vocalization.recording = recording
        context.insert(vocalization)
        try context.save()

        Tombstone.recordRecording(recording, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DeletedRecord>())
        XCTAssertEqual(Set(rows.map(\.entity)), ["voice_recordings", "vocalizations"])
        XCTAssertEqual(Set(rows.map(\.recordID)), [recording.id, vocalization.id])
    }

    func testDeletedRecordIsRegisteredInTheSchema() {
        let registered = PersistenceController.modelTypes.map(ObjectIdentifier.init)
        XCTAssertTrue(registered.contains(ObjectIdentifier(DeletedRecord.self)))
        XCTAssertTrue(registered.contains(ObjectIdentifier(VoiceRecording.self)))
    }

    func testMediaStoresCanWriteBytesUnderAKnownFilename() throws {
        let inMemory = InMemoryMediaStore()
        try inMemory.write(Data([1, 2, 3]), as: "known-audio.m4a")
        XCTAssertTrue(inMemory.exists("known-audio.m4a"))
        XCTAssertEqual(try Data(contentsOf: inMemory.url(for: "known-audio.m4a")), Data([1, 2, 3]))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mediawrite-\(UUID().uuidString)")
        let file = FileMediaStore(root: root)
        try file.write(Data([4, 5, 6]), as: "known-audio.m4a")
        XCTAssertTrue(file.exists("known-audio.m4a"))
        XCTAssertEqual(try Data(contentsOf: file.url(for: "known-audio.m4a")), Data([4, 5, 6]))
        try? FileManager.default.removeItem(at: root)
    }
}
```

`VoiceFixtures.features()` comes from `AppTests/VoiceModelTests.swift` (Plan B Task 13).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `value of type 'Animal' has no member 'updatedAt'` and `cannot find 'Tombstone' in scope`.

- [ ] **Step 3: Add the sync fields to the four models**

In `App/Models/Animal.swift`, replace lines 6 and 7:
```swift
    var id: UUID = UUID()
    var createdAt: Date = Date()
```
with:
```swift
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Bumped by every mutation site; sync pushes rows newer than the last push and resolves
    /// conflicts last-write-wins on this value.
    var updatedAt: Date = Date()
```

In `App/Models/VoiceRecording.swift`, replace:
```swift
    var id: UUID = UUID()
    var createdAt: Date = Date()
```
with:
```swift
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// When this recording's audio file reached Storage. Nil means "still to upload".
    var audioUploadedAt: Date?
```

In `App/Models/Vocalization.swift`, replace:
```swift
    var id: UUID = UUID()
    var createdAt: Date = Date()
```
with:
```swift
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
```

In `App/Models/VoiceTag.swift`, replace:
```swift
    var id: UUID = UUID()
    var createdAt: Date = Date()
```
with:
```swift
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
```

The unique constraint is what lets pull upsert by id without duplicating rows. Adding it changes the store schema, which is why `makeContainerWithRecovery()` from Task 4 exists: an existing simulator store that cannot migrate is wiped and rebuilt.

- [ ] **Step 4: Add the tombstone model**

Create `App/Models/DeletedRecord.swift`:
```swift
import Foundation
import SwiftData

/// A local record of something the user deleted, so the next push can tell the server about it.
/// Local only: it is never itself synced, and it is removed once the delete has been pushed.
@Model
final class DeletedRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// A `SyncTable` raw value, for example "voice_recordings".
    var entity: String = ""
    var recordID: UUID = UUID()
    var deletedAt: Date = Date()

    init(entity: String, recordID: UUID, deletedAt: Date = Date()) {
        self.entity = entity
        self.recordID = recordID
        self.deletedAt = deletedAt
    }
}

/// The one place that writes tombstones, so no delete site has to remember the entity string.
enum Tombstone {
    @MainActor
    static func record(_ table: SyncTable, id: UUID, in context: ModelContext) {
        context.insert(DeletedRecord(entity: table.rawValue, recordID: id))
    }

    /// A recording's vocalizations cascade locally, so the server has to be told about them too.
    @MainActor
    static func recordRecording(_ recording: VoiceRecording, in context: ModelContext) {
        for vocalization in recording.sortedVocalizations {
            record(.vocalizations, id: vocalization.id, in: context)
        }
        record(.voiceRecordings, id: recording.id, in: context)
    }
}
```

- [ ] **Step 5: Register the model**

In `App/Persistence/PersistenceController.swift`, the `modelTypes` array after Plan B Task 13 reads:
```swift
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        VoiceRecording.self,
        Vocalization.self,
        VoiceTag.self,
    ]
```
Add one line so it reads:
```swift
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        VoiceRecording.self,
        Vocalization.self,
        VoiceTag.self,
        DeletedRecord.self,
    ]
```
Keep any other entries the file already has; only `DeletedRecord.self` is being added.

- [ ] **Step 6: Let the media stores write a known filename**

In `App/Media/MediaStore.swift`, add one requirement to the protocol, after `func saveAudio(from url: URL) throws -> String`:
```swift
    /// Writes bytes under a filename that already exists in a record. Sync uses it to restore an
    /// audio file downloaded from Storage; the save* methods cannot, because they mint a new name.
    func write(_ data: Data, as filename: String) throws
```

and add this method to `InMemoryMediaStore`, after its `saveAudio(from:)`:
```swift
    func write(_ data: Data, as filename: String) throws {
        files[filename] = data
    }
```

In `App/Media/FileMediaStore.swift`, add this method after `saveAudio(from:)`:
```swift
    func write(_ data: Data, as filename: String) throws {
        try write(data, to: filename)
    }
```
It forwards to the existing private `write(_:to:)`, so it goes through `writeHook` and wraps failures in `MediaStoreError.writeFailed` exactly like every other write.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncFieldTests` five cases are green, and Plan A's and Plan B's model tests still pass.

Correction if an existing test fails with a SwiftData migration error on the simulator, delete the app's store and re-run:
```bash
xcrun simctl uninstall booted com.ashlab.AnimalTracker
scripts/test-app.sh
```

- [ ] **Step 8: Commit**

```bash
git add App/Models/Animal.swift App/Models/VoiceRecording.swift App/Models/Vocalization.swift \
        App/Models/VoiceTag.swift App/Models/DeletedRecord.swift \
        App/Persistence/PersistenceController.swift App/Media/MediaStore.swift \
        App/Media/FileMediaStore.swift AppTests/SyncFieldTests.swift
git commit -m "feat(sync): updatedAt on the synced models, audioUploadedAt, and local tombstones

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Codable row structs with snake_case keys, and the Storage path

**Files:**
- Create: `App/Sync/SyncRows.swift`
- Create: `AppTests/SyncRowTests.swift`

**Interfaces:**
- Consumes: `SyncTable` (Task 3). Column names come from Task 5's migration.
- Produces: `enum SyncCoding { static let formatter: ISO8601DateFormatter; static let encoder: JSONEncoder; static let decoder: JSONDecoder }`; `enum RemoteAudioPath { static let bucket = "voice-audio"; static func make(userID: UUID, filename: String) -> String }`; `struct AnimalRow`, `struct VoiceRecordingRow`, `struct VocalizationRow`, `struct VoiceTagRow`, each `Codable, Equatable`, each with `id`, `userID`, `createdAt`, `updatedAt`, `deletedAt` and a `static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> Self`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/SyncRowTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SyncRowTests: XCTestCase {
    private let userID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let moment = Date(timeIntervalSince1970: 1_750_000_000.25)

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try SyncCoding.encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnimalRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = AnimalRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment, deletedAt: nil,
                            name: "Miso", species: "cat", colorHex: "#FF8800",
                            photoFilename: "p.jpg", photoThumbnailFilename: "t.jpg",
                            tracksOutdoorTime: false, sortOrder: 3, isArchived: true, note: "shy")
        let keys = Set(try json(row).keys)
        XCTAssertTrue(keys.isSuperset(of: ["id", "user_id", "created_at", "updated_at", "color_hex",
                                           "photo_filename", "photo_thumbnail_filename",
                                           "tracks_outdoor_time", "sort_order", "is_archived"]))
        XCTAssertFalse(keys.contains("userID"))
        let back = try SyncCoding.decoder.decode(AnimalRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    func testVoiceRecordingRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VoiceRecordingRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment, deletedAt: nil,
                                    animalID: UUID(), recordedAt: moment, durationS: 1.25,
                                    audioFilename: "x-audio.m4a", statusRaw: "analyzed", errorMessage: nil,
                                    note: "loud", activityTag: "Door", meaningTag: "Hungry",
                                    userConfidence: 3, editedAt: moment, audioUploadedAt: moment)
        let keys = Set(try json(row).keys)
        XCTAssertTrue(keys.isSuperset(of: ["animal_id", "recorded_at", "duration_s", "audio_filename",
                                           "status_raw", "error_message", "activity_tag", "meaning_tag",
                                           "user_confidence", "edited_at", "audio_uploaded_at", "deleted_at"]))
        let back = try SyncCoding.decoder.decode(VoiceRecordingRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    func testVocalizationRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VocalizationRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment, deletedAt: nil,
                                  recordingID: UUID(), startS: 0.1, endS: 0.5, f0Mean: 600, f0Min: 550,
                                  f0Max: 650, f0Slope: 100, voicedFraction: 0.9, rmsDb: -20,
                                  spectralCentroidHz: 1500, mfcc: [1, 2, 3], activityTag: nil,
                                  meaningTag: "Hungry", userConfidence: 2, overridden: true)
        let keys = Set(try json(row).keys)
        XCTAssertTrue(keys.isSuperset(of: ["recording_id", "start_s", "end_s", "f0_mean", "f0_min", "f0_max",
                                           "f0_slope", "voiced_fraction", "rms_db", "spectral_centroid_hz",
                                           "mfcc", "overridden"]))
        let back = try SyncCoding.decoder.decode(VocalizationRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
        XCTAssertEqual(back.mfcc, [1, 2, 3])
    }

    func testVoiceTagRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VoiceTagRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment, deletedAt: nil,
                              kindRaw: "meaning", name: "Hungry", isBuiltIn: true, sortOrder: 2)
        let keys = Set(try json(row).keys)
        XCTAssertTrue(keys.isSuperset(of: ["kind_raw", "name", "is_built_in", "sort_order"]))
        let back = try SyncCoding.decoder.decode(VoiceTagRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    func testDatesSurviveARoundTripToTheMillisecond() throws {
        let row = VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: moment)
        let back = try SyncCoding.decoder.decode(VoiceTagRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(back.deletedAt).timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDatesEncodeAsIso8601WithFractionalSeconds() throws {
        let row = VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: moment)
        let encoded = try XCTUnwrap(try json(row)["deleted_at"] as? String)
        XCTAssertTrue(encoded.hasSuffix("Z"), encoded)
        XCTAssertTrue(encoded.contains("."), encoded)
    }

    func testTombstonesCarryTheIdTheUserAndTheDeletionTime() {
        let id = UUID()
        let animal = AnimalRow.tombstone(id: id, userID: userID, deletedAt: moment)
        XCTAssertEqual(animal.id, id)
        XCTAssertEqual(animal.userID, userID)
        XCTAssertEqual(animal.deletedAt, moment)
        XCTAssertEqual(animal.updatedAt, moment)
        XCTAssertEqual(VoiceRecordingRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
        XCTAssertEqual(VocalizationRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
        XCTAssertEqual(VoiceTagRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
    }

    func testRemoteAudioPathIsTheUserFolder() {
        XCTAssertEqual(RemoteAudioPath.bucket, "voice-audio")
        XCTAssertEqual(RemoteAudioPath.make(userID: userID, filename: "abc-audio.m4a"),
                       "33333333-3333-3333-3333-333333333333/abc-audio.m4a")
    }

    /// auth.uid()::text is lowercase in Postgres, and the storage policy compares the object name
    /// against it, so an uppercase UUID here would be rejected by RLS.
    func testRemoteAudioPathIsLowercase() {
        let mixed = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!
        XCTAssertEqual(RemoteAudioPath.make(userID: mixed, filename: "x-audio.m4a"),
                       "aabbccdd-1122-3344-5566-778899aabbcc/x-audio.m4a")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'SyncCoding' in scope` and `cannot find 'AnimalRow' in scope`.

- [ ] **Step 3: Write the rows**

Create `App/Sync/SyncRows.swift`:
```swift
import Foundation

/// JSON coding used by the tests and by anything that needs a stable wire shape. supabase-swift
/// applies its own PostgREST coders on the wire; these exist so the key names and the field set are
/// covered by tests without asserting anything about the SDK's internals.
enum SyncCoding {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}

/// Audio objects live at "<user id>/<audio filename>" in a private bucket, which is exactly the
/// prefix the storage.objects policies allow.
enum RemoteAudioPath {
    static let bucket = "voice-audio"

    static func make(userID: UUID, filename: String) -> String {
        // Lowercase: Postgres renders auth.uid()::text in lowercase and the storage.objects policy
        // compares the object name against that prefix.
        "\(userID.uuidString.lowercased())/\(filename)"
    }
}

struct AnimalRow: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var name: String
    var species: String
    var colorHex: String
    var photoFilename: String?
    var photoThumbnailFilename: String?
    var tracksOutdoorTime: Bool
    var sortOrder: Int
    var isArchived: Bool
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, species, note
        case userID = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case colorHex = "color_hex"
        case photoFilename = "photo_filename"
        case photoThumbnailFilename = "photo_thumbnail_filename"
        case tracksOutdoorTime = "tracks_outdoor_time"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
    }

    /// A delete is an ordinary upsert with deleted_at set; the other columns take their model defaults
    /// so no column has to be nullable just for deletes.
    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> AnimalRow {
        AnimalRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt,
                  name: "", species: "", colorHex: "", photoFilename: nil, photoThumbnailFilename: nil,
                  tracksOutdoorTime: true, sortOrder: 0, isArchived: false, note: nil)
    }
}

struct VoiceRecordingRow: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var animalID: UUID?
    var recordedAt: Date
    var durationS: Double
    var audioFilename: String
    var statusRaw: String
    var errorMessage: String?
    var note: String
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var editedAt: Date?
    var audioUploadedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, note
        case userID = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case animalID = "animal_id"
        case recordedAt = "recorded_at"
        case durationS = "duration_s"
        case audioFilename = "audio_filename"
        case statusRaw = "status_raw"
        case errorMessage = "error_message"
        case activityTag = "activity_tag"
        case meaningTag = "meaning_tag"
        case userConfidence = "user_confidence"
        case editedAt = "edited_at"
        case audioUploadedAt = "audio_uploaded_at"
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VoiceRecordingRow {
        VoiceRecordingRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt,
                          animalID: nil, recordedAt: deletedAt, durationS: 0, audioFilename: "",
                          statusRaw: "recorded", errorMessage: nil, note: "", activityTag: nil,
                          meaningTag: nil, userConfidence: nil, editedAt: nil, audioUploadedAt: nil)
    }
}

struct VocalizationRow: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var recordingID: UUID?
    var startS: Double
    var endS: Double
    var f0Mean: Double?
    var f0Min: Double?
    var f0Max: Double?
    var f0Slope: Double?
    var voicedFraction: Double
    var rmsDb: Double
    var spectralCentroidHz: Double
    var mfcc: [Double]
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var overridden: Bool

    enum CodingKeys: String, CodingKey {
        case id, mfcc, overridden
        case userID = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case recordingID = "recording_id"
        case startS = "start_s"
        case endS = "end_s"
        case f0Mean = "f0_mean"
        case f0Min = "f0_min"
        case f0Max = "f0_max"
        case f0Slope = "f0_slope"
        case voicedFraction = "voiced_fraction"
        case rmsDb = "rms_db"
        case spectralCentroidHz = "spectral_centroid_hz"
        case activityTag = "activity_tag"
        case meaningTag = "meaning_tag"
        case userConfidence = "user_confidence"
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VocalizationRow {
        VocalizationRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt,
                        recordingID: nil, startS: 0, endS: 0, f0Mean: nil, f0Min: nil, f0Max: nil,
                        f0Slope: nil, voicedFraction: 0, rmsDb: -160, spectralCentroidHz: 0, mfcc: [],
                        activityTag: nil, meaningTag: nil, userConfidence: nil, overridden: false)
    }
}

struct VoiceTagRow: Codable, Equatable {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var kindRaw: String
    var name: String
    var isBuiltIn: Bool
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case kindRaw = "kind_raw"
        case isBuiltIn = "is_built_in"
        case sortOrder = "sort_order"
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VoiceTagRow {
        VoiceTagRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt,
                    kindRaw: "activity", name: "", isBuiltIn: false, sortOrder: 0)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncRowTests` nine cases are green.

- [ ] **Step 5: Check the row fields against the migration**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -o '"[a-z0-9_]*"' App/Sync/SyncRows.swift | tr -d '"' | sort -u > /tmp/row-keys.txt
grep -oE '^    [a-z0-9_]+ ' supabase/migrations/20260919120000_voice_milestone.sql | tr -d ' ' | sort -u > /tmp/sql-cols.txt
comm -23 /tmp/row-keys.txt /tmp/sql-cols.txt
```
Expected: the only lines printed are `voice-audio`, `analyzed`, `recorded`, `activity`, `meaning` and similar literal values, never a column-looking name such as `duration_s`. Any snake_case name in the left column that is not a SQL column is a typo to fix before committing.

- [ ] **Step 6: Commit**

```bash
git add App/Sync/SyncRows.swift AppTests/SyncRowTests.swift
git commit -m "feat(sync): Codable row structs mirroring the server columns, plus the storage path

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The RemoteStore protocol with an in-memory double, and the SwiftData LocalStore

**Files:**
- Create: `App/Sync/RemoteStore.swift`
- Create: `App/Sync/LocalStore.swift`
- Create: `AppTests/LocalStoreTests.swift`

**Interfaces:**
- Consumes: the row structs and `RemoteAudioPath` (Task 7); `SyncTable` (Task 3); `DeletedRecord`, `Tombstone`, `MediaStore.write(_:as:)` (Task 6); `Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`, `InMemoryMediaStore`, `TestSupport` (Plans A and B).
- Produces:
  - `protocol RemoteStore` with `upsertAnimals`, `upsertRecordings`, `upsertVocalizations`, `upsertTags`, `fetchAnimals(since:)`, `fetchRecordings(since:)`, `fetchVocalizations(since:)`, `fetchTags(since:)`, `uploadAudio(path:data:)`, `downloadAudio(path:)`.
  - `final class InMemoryRemoteStore: RemoteStore` with `var animals/recordings/vocalizations/tags: [UUID: Row]`, `var audio: [String: Data]`, `var uploadCount: Int`, `var failNextCall: Bool`, `enum Failure: Error { case scripted }`.
  - `struct DeletedRecordInfo: Equatable { let table: SyncTable; let recordID: UUID; let deletedAt: Date }`.
  - `struct PendingAudio: Equatable { let recordingID: UUID; let filename: String; let data: Data }`.
  - `@MainActor protocol LocalStore: AnyObject` with `var userID: UUID { get }`, `changedAnimals(after:)`, `changedRecordings(after:)`, `changedVocalizations(after:)`, `changedTags(after:)`, `tombstones(after:)`, `clearTombstones(upTo:)`, `apply(animals:)`, `apply(recordings:)`, `apply(vocalizations:)`, `apply(tags:)`, `pendingAudioUploads()`, `markAudioUploaded(recordingID:at:)`, `save()`.
  - `@MainActor final class SwiftDataLocalStore: LocalStore` with `init(context: ModelContext, mediaStore: MediaStore, userID: UUID)`.
  - `protocol SyncIdentifiable: PersistentModel { var id: UUID { get } }` with conformances on `Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/LocalStoreTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class LocalStoreTests: XCTestCase {
    private let userID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makeStore() throws -> (SwiftDataLocalStore, ModelContext, InMemoryMediaStore) {
        let context = try TestSupport.container().mainContext
        let media = InMemoryMediaStore()
        return (SwiftDataLocalStore(context: context, mediaStore: media, userID: userID), context, media)
    }

    func testChangedAnimalsReturnsOnlyRowsNewerThanTheWatermark() throws {
        let (store, context, _) = try makeStore()
        let old = Animal(name: "Old", species: "cat")
        old.updatedAt = Date(timeIntervalSince1970: 100)
        let recent = Animal(name: "Recent", species: "dog")
        recent.updatedAt = Date(timeIntervalSince1970: 300)
        context.insert(old)
        context.insert(recent)
        try context.save()

        let rows = try store.changedAnimals(after: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(rows.map(\.name), ["Recent"])
        XCTAssertEqual(rows[0].userID, userID)
        XCTAssertEqual(rows[0].species, "dog")
        XCTAssertNil(rows[0].deletedAt)
    }

    func testChangedRecordingsAndVocalizationsCarryTheirParentIds() throws {
        let (store, context, _) = try makeStore()
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2, animal: animal)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0.1, endS: 0.4), features: VoiceFixtures.features())
        vocalization.recording = recording
        context.insert(vocalization)
        try context.save()

        let recordings = try store.changedRecordings(after: SyncState.epoch)
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].animalID, animal.id)
        XCTAssertEqual(recordings[0].audioFilename, "r-audio.m4a")

        let vocalizations = try store.changedVocalizations(after: SyncState.epoch)
        XCTAssertEqual(vocalizations.count, 1)
        XCTAssertEqual(vocalizations[0].recordingID, recording.id)
        XCTAssertEqual(vocalizations[0].mfcc.count, 13)
    }

    func testApplyInsertsNewRowsAndRelinksParents() throws {
        let (store, context, _) = try makeStore()
        let animalID = UUID()
        let recordingID = UUID()
        let now = Date(timeIntervalSince1970: 500)
        try store.apply(animals: [AnimalRow(id: animalID, userID: userID, createdAt: now, updatedAt: now,
                                            deletedAt: nil, name: "Remote", species: "horse", colorHex: "#112233",
                                            photoFilename: nil, photoThumbnailFilename: nil,
                                            tracksOutdoorTime: true, sortOrder: 1, isArchived: false, note: nil)])
        try store.apply(recordings: [VoiceRecordingRow(id: recordingID, userID: userID, createdAt: now,
                                                       updatedAt: now, deletedAt: nil, animalID: animalID,
                                                       recordedAt: now, durationS: 3, audioFilename: "z-audio.m4a",
                                                       statusRaw: "analyzed", errorMessage: nil, note: "",
                                                       activityTag: nil, meaningTag: "Hungry", userConfidence: 2,
                                                       editedAt: nil, audioUploadedAt: now)])
        try store.save()

        let animals = try context.fetch(FetchDescriptor<Animal>())
        XCTAssertEqual(animals.map(\.name), ["Remote"])
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>())
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].animal?.id, animalID)
        XCTAssertEqual(recordings[0].meaningTag, "Hungry")
        XCTAssertEqual(recordings[0].audioUploadedAt, now)
    }

    func testApplyKeepsTheNewerSideOnConflict() throws {
        let (store, context, _) = try makeStore()
        let animal = Animal(name: "Local wins", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 900)
        context.insert(animal)
        try context.save()

        let older = AnimalRow(id: animal.id, userID: userID, createdAt: SyncState.epoch,
                              updatedAt: Date(timeIntervalSince1970: 800), deletedAt: nil,
                              name: "Remote loses", species: "cat", colorHex: "#000000",
                              photoFilename: nil, photoThumbnailFilename: nil, tracksOutdoorTime: true,
                              sortOrder: 0, isArchived: false, note: nil)
        try store.apply(animals: [older])
        try store.save()
        XCTAssertEqual(animal.name, "Local wins")

        var newer = older
        newer.updatedAt = Date(timeIntervalSince1970: 1000)
        newer.name = "Remote wins"
        try store.apply(animals: [newer])
        try store.save()
        XCTAssertEqual(animal.name, "Remote wins")
    }

    func testApplyDeletesLocallyForATombstoneRow() throws {
        let (store, context, media) = try makeStore()
        let recording = VoiceRecording(audioFilename: "gone-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()
        try media.write(Data([9]), as: "gone-audio.m4a")

        try store.apply(recordings: [VoiceRecordingRow.tombstone(id: recording.id, userID: userID,
                                                                 deletedAt: Date(timeIntervalSince1970: 2000))])
        try store.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).count, 0)
        XCTAssertFalse(media.exists("gone-audio.m4a"), "the audio file must go with the recording")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 0,
                       "a pulled delete must not create a tombstone that would be pushed back")
    }

    func testTombstonesAreReportedAndCleared() throws {
        let (store, context, _) = try makeStore()
        let gone = UUID()
        context.insert(DeletedRecord(entity: SyncTable.voiceTags.rawValue, recordID: gone,
                                     deletedAt: Date(timeIntervalSince1970: 400)))
        context.insert(DeletedRecord(entity: SyncTable.animals.rawValue, recordID: UUID(),
                                     deletedAt: Date(timeIntervalSince1970: 100)))
        try context.save()

        let recent = try store.tombstones(after: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recent, [DeletedRecordInfo(table: .voiceTags, recordID: gone,
                                                  deletedAt: Date(timeIntervalSince1970: 400))])

        try store.clearTombstones(upTo: Date(timeIntervalSince1970: 400))
        try store.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 0)
    }

    func testPendingAudioUploadsAndMarking() throws {
        let (store, context, media) = try makeStore()
        let ready = VoiceRecording(audioFilename: "ready-audio.m4a", durationS: 1)
        let missingFile = VoiceRecording(audioFilename: "absent-audio.m4a", durationS: 1)
        let alreadyUp = VoiceRecording(audioFilename: "done-audio.m4a", durationS: 1)
        alreadyUp.audioUploadedAt = Date(timeIntervalSince1970: 10)
        context.insert(ready)
        context.insert(missingFile)
        context.insert(alreadyUp)
        try context.save()
        try media.write(Data([1, 2]), as: "ready-audio.m4a")
        try media.write(Data([3]), as: "done-audio.m4a")

        let pending = try store.pendingAudioUploads()
        XCTAssertEqual(pending, [PendingAudio(recordingID: ready.id, filename: "ready-audio.m4a", data: Data([1, 2]))])

        let stamp = Date(timeIntervalSince1970: 3000)
        try store.markAudioUploaded(recordingID: ready.id, at: stamp)
        try store.save()
        XCTAssertEqual(ready.audioUploadedAt, stamp)
        XCTAssertEqual(ready.updatedAt, stamp, "the flag has to be pushed, so updatedAt moves with it")
        XCTAssertTrue(try store.pendingAudioUploads().isEmpty)
    }

    func testInMemoryRemoteStoreRecordsWhatItWasGiven() async throws {
        let remote = InMemoryRemoteStore()
        let now = Date(timeIntervalSince1970: 600)
        let row = VoiceTagRow(id: UUID(), userID: userID, createdAt: now, updatedAt: now, deletedAt: nil,
                              kindRaw: "meaning", name: "Hungry", isBuiltIn: true, sortOrder: 0)
        try await remote.upsertTags([row])
        XCTAssertEqual(try await remote.fetchTags(since: SyncState.epoch), [row])
        XCTAssertTrue(try await remote.fetchTags(since: Date(timeIntervalSince1970: 700)).isEmpty)

        try await remote.uploadAudio(path: "u/x.m4a", data: Data([7]))
        XCTAssertEqual(remote.uploadCount, 1)
        XCTAssertEqual(try await remote.downloadAudio(path: "u/x.m4a"), Data([7]))

        remote.failNextCall = true
        do {
            try await remote.upsertTags([row])
            XCTFail("expected the scripted failure")
        } catch InMemoryRemoteStore.Failure.scripted {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'SwiftDataLocalStore' in scope` and `cannot find 'InMemoryRemoteStore' in scope`.

- [ ] **Step 3: Write the remote side**

Create `App/Sync/RemoteStore.swift`:
```swift
import Foundation

/// Everything the sync engine needs from the server. One method per table keeps it explicit and
/// keeps the test double trivial; no generics, no type erasure.
protocol RemoteStore {
    func upsertAnimals(_ rows: [AnimalRow]) async throws
    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws
    func upsertVocalizations(_ rows: [VocalizationRow]) async throws
    func upsertTags(_ rows: [VoiceTagRow]) async throws

    func fetchAnimals(since: Date) async throws -> [AnimalRow]
    func fetchRecordings(since: Date) async throws -> [VoiceRecordingRow]
    func fetchVocalizations(since: Date) async throws -> [VocalizationRow]
    func fetchTags(since: Date) async throws -> [VoiceTagRow]

    func uploadAudio(path: String, data: Data) async throws
    func downloadAudio(path: String) async throws -> Data
}

/// Test double. Holds rows in dictionaries keyed by id, so an upsert really does replace.
/// `failNextCall` scripts one failure, for testing that a sync leaves the watermarks alone.
final class InMemoryRemoteStore: RemoteStore {
    enum Failure: Error { case scripted, notFound }

    var animals: [UUID: AnimalRow] = [:]
    var recordings: [UUID: VoiceRecordingRow] = [:]
    var vocalizations: [UUID: VocalizationRow] = [:]
    var tags: [UUID: VoiceTagRow] = [:]
    var audio: [String: Data] = [:]
    var uploadCount = 0
    var downloadCount = 0
    var failNextCall = false

    init() {}

    private func checkFailure() throws {
        if failNextCall {
            failNextCall = false
            throw Failure.scripted
        }
    }

    func upsertAnimals(_ rows: [AnimalRow]) async throws {
        try checkFailure()
        for row in rows { animals[row.id] = row }
    }

    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws {
        try checkFailure()
        for row in rows { recordings[row.id] = row }
    }

    func upsertVocalizations(_ rows: [VocalizationRow]) async throws {
        try checkFailure()
        for row in rows { vocalizations[row.id] = row }
    }

    func upsertTags(_ rows: [VoiceTagRow]) async throws {
        try checkFailure()
        for row in rows { tags[row.id] = row }
    }

    func fetchAnimals(since: Date) async throws -> [AnimalRow] {
        try checkFailure()
        return animals.values.filter { $0.updatedAt > since }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func fetchRecordings(since: Date) async throws -> [VoiceRecordingRow] {
        try checkFailure()
        return recordings.values.filter { $0.updatedAt > since }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func fetchVocalizations(since: Date) async throws -> [VocalizationRow] {
        try checkFailure()
        return vocalizations.values.filter { $0.updatedAt > since }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func fetchTags(since: Date) async throws -> [VoiceTagRow] {
        try checkFailure()
        return tags.values.filter { $0.updatedAt > since }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func uploadAudio(path: String, data: Data) async throws {
        try checkFailure()
        audio[path] = data
        uploadCount += 1
    }

    func downloadAudio(path: String) async throws -> Data {
        try checkFailure()
        downloadCount += 1
        guard let data = audio[path] else { throw Failure.notFound }
        return data
    }
}
```

- [ ] **Step 4: Write the local side**

Create `App/Sync/LocalStore.swift`:
```swift
import Foundation
import SwiftData

struct DeletedRecordInfo: Equatable {
    let table: SyncTable
    let recordID: UUID
    let deletedAt: Date
}

struct PendingAudio: Equatable {
    let recordingID: UUID
    let filename: String
    let data: Data
}

/// Everything the sync engine needs from the device. Main actor because a ModelContext is.
@MainActor
protocol LocalStore: AnyObject {
    var userID: UUID { get }

    func changedAnimals(after: Date) throws -> [AnimalRow]
    func changedRecordings(after: Date) throws -> [VoiceRecordingRow]
    func changedVocalizations(after: Date) throws -> [VocalizationRow]
    func changedTags(after: Date) throws -> [VoiceTagRow]
    func tombstones(after: Date) throws -> [DeletedRecordInfo]
    func clearTombstones(upTo: Date) throws

    func apply(animals: [AnimalRow]) throws
    func apply(recordings: [VoiceRecordingRow]) throws
    func apply(vocalizations: [VocalizationRow]) throws
    func apply(tags: [VoiceTagRow]) throws

    func pendingAudioUploads() throws -> [PendingAudio]
    func markAudioUploaded(recordingID: UUID, at date: Date) throws

    func save() throws
}

@MainActor
final class SwiftDataLocalStore: LocalStore {
    let context: ModelContext
    let mediaStore: MediaStore
    let userID: UUID

    init(context: ModelContext, mediaStore: MediaStore, userID: UUID) {
        self.context = context
        self.mediaStore = mediaStore
        self.userID = userID
    }

    // MARK: push side

    func changedAnimals(after: Date) throws -> [AnimalRow] {
        try fetchAll(Animal.self).filter { $0.updatedAt > after }.map { animal in
            AnimalRow(id: animal.id, userID: userID, createdAt: animal.createdAt, updatedAt: animal.updatedAt,
                      deletedAt: nil, name: animal.name, species: animal.species, colorHex: animal.colorHex,
                      photoFilename: animal.photoFilename, photoThumbnailFilename: animal.photoThumbnailFilename,
                      tracksOutdoorTime: animal.tracksOutdoorTime, sortOrder: animal.sortOrder,
                      isArchived: animal.isArchived, note: animal.note)
        }
    }

    func changedRecordings(after: Date) throws -> [VoiceRecordingRow] {
        try fetchAll(VoiceRecording.self).filter { $0.updatedAt > after }.map { recording in
            VoiceRecordingRow(id: recording.id, userID: userID, createdAt: recording.createdAt,
                              updatedAt: recording.updatedAt, deletedAt: nil, animalID: recording.animal?.id,
                              recordedAt: recording.recordedAt, durationS: recording.durationS,
                              audioFilename: recording.audioFilename, statusRaw: recording.statusRaw,
                              errorMessage: recording.errorMessage, note: recording.note,
                              activityTag: recording.activityTag, meaningTag: recording.meaningTag,
                              userConfidence: recording.userConfidence, editedAt: recording.editedAt,
                              audioUploadedAt: recording.audioUploadedAt)
        }
    }

    func changedVocalizations(after: Date) throws -> [VocalizationRow] {
        try fetchAll(Vocalization.self).filter { $0.updatedAt > after }.map { vocalization in
            VocalizationRow(id: vocalization.id, userID: userID, createdAt: vocalization.createdAt,
                            updatedAt: vocalization.updatedAt, deletedAt: nil,
                            recordingID: vocalization.recording?.id, startS: vocalization.startS,
                            endS: vocalization.endS, f0Mean: vocalization.f0Mean, f0Min: vocalization.f0Min,
                            f0Max: vocalization.f0Max, f0Slope: vocalization.f0Slope,
                            voicedFraction: vocalization.voicedFraction, rmsDb: vocalization.rmsDb,
                            spectralCentroidHz: vocalization.spectralCentroidHz, mfcc: vocalization.mfcc,
                            activityTag: vocalization.activityTag, meaningTag: vocalization.meaningTag,
                            userConfidence: vocalization.userConfidence, overridden: vocalization.overridden)
        }
    }

    func changedTags(after: Date) throws -> [VoiceTagRow] {
        try fetchAll(VoiceTag.self).filter { $0.updatedAt > after }.map { tag in
            VoiceTagRow(id: tag.id, userID: userID, createdAt: tag.createdAt, updatedAt: tag.updatedAt,
                        deletedAt: nil, kindRaw: tag.kindRaw, name: tag.name, isBuiltIn: tag.isBuiltIn,
                        sortOrder: tag.sortOrder)
        }
    }

    func tombstones(after: Date) throws -> [DeletedRecordInfo] {
        try fetchAll(DeletedRecord.self)
            .filter { $0.deletedAt > after }
            .compactMap { record in
                guard let table = SyncTable(rawValue: record.entity) else { return nil }
                return DeletedRecordInfo(table: table, recordID: record.recordID, deletedAt: record.deletedAt)
            }
            .sorted { $0.deletedAt < $1.deletedAt }
    }

    func clearTombstones(upTo: Date) throws {
        for record in try fetchAll(DeletedRecord.self) where record.deletedAt <= upTo {
            context.delete(record)
        }
    }

    // MARK: pull side

    func apply(animals rows: [AnimalRow]) throws {
        let existing = try byID(Animal.self)
        for row in rows {
            let local = existing[row.id]
            if row.deletedAt != nil {
                if let local {
                    if let photo = local.photoFilename { mediaStore.delete(photo) }
                    if let thumb = local.photoThumbnailFilename { mediaStore.delete(thumb) }
                    context.delete(local)
                }
                continue
            }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            let animal = local ?? Animal(name: row.name, species: row.species)
            animal.id = row.id
            animal.createdAt = row.createdAt
            animal.updatedAt = row.updatedAt
            animal.name = row.name
            animal.species = row.species
            animal.colorHex = row.colorHex
            animal.photoFilename = row.photoFilename
            animal.photoThumbnailFilename = row.photoThumbnailFilename
            animal.tracksOutdoorTime = row.tracksOutdoorTime
            animal.sortOrder = row.sortOrder
            animal.isArchived = row.isArchived
            animal.note = row.note
            if local == nil { context.insert(animal) }
        }
    }

    func apply(recordings rows: [VoiceRecordingRow]) throws {
        let existing = try byID(VoiceRecording.self)
        let animals = try byID(Animal.self)
        for row in rows {
            let local = existing[row.id]
            if row.deletedAt != nil {
                if let local {
                    mediaStore.delete(local.audioFilename)
                    context.delete(local)
                }
                continue
            }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            let recording = local ?? VoiceRecording(audioFilename: row.audioFilename, durationS: row.durationS)
            recording.id = row.id
            recording.createdAt = row.createdAt
            recording.updatedAt = row.updatedAt
            recording.recordedAt = row.recordedAt
            recording.durationS = row.durationS
            recording.audioFilename = row.audioFilename
            recording.statusRaw = row.statusRaw
            recording.errorMessage = row.errorMessage
            recording.note = row.note
            recording.activityTag = row.activityTag
            recording.meaningTag = row.meaningTag
            recording.userConfidence = row.userConfidence
            recording.editedAt = row.editedAt
            recording.audioUploadedAt = row.audioUploadedAt
            // A parent that has not arrived yet stays nil and is relinked by a later pull.
            recording.animal = row.animalID.flatMap { animals[$0] }
            if local == nil { context.insert(recording) }
        }
    }

    func apply(vocalizations rows: [VocalizationRow]) throws {
        let existing = try byID(Vocalization.self)
        let recordings = try byID(VoiceRecording.self)
        for row in rows {
            let local = existing[row.id]
            if row.deletedAt != nil {
                if let local { context.delete(local) }
                continue
            }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            let vocalization = local ?? Vocalization(segment: Segment(startS: row.startS, endS: row.endS),
                                                     features: VocalFeatures(durationS: row.endS - row.startS,
                                                                             f0Mean: row.f0Mean, f0Min: row.f0Min,
                                                                             f0Max: row.f0Max, f0Slope: row.f0Slope,
                                                                             voicedFraction: row.voicedFraction,
                                                                             rmsDb: row.rmsDb,
                                                                             spectralCentroidHz: row.spectralCentroidHz,
                                                                             mfcc: row.mfcc))
            vocalization.id = row.id
            vocalization.createdAt = row.createdAt
            vocalization.updatedAt = row.updatedAt
            vocalization.startS = row.startS
            vocalization.endS = row.endS
            vocalization.f0Mean = row.f0Mean
            vocalization.f0Min = row.f0Min
            vocalization.f0Max = row.f0Max
            vocalization.f0Slope = row.f0Slope
            vocalization.voicedFraction = row.voicedFraction
            vocalization.rmsDb = row.rmsDb
            vocalization.spectralCentroidHz = row.spectralCentroidHz
            vocalization.mfcc = row.mfcc
            vocalization.activityTag = row.activityTag
            vocalization.meaningTag = row.meaningTag
            vocalization.userConfidence = row.userConfidence
            vocalization.overridden = row.overridden
            vocalization.recording = row.recordingID.flatMap { recordings[$0] }
            if local == nil { context.insert(vocalization) }
        }
    }

    func apply(tags rows: [VoiceTagRow]) throws {
        let existing = try byID(VoiceTag.self)
        for row in rows {
            let local = existing[row.id]
            if row.deletedAt != nil {
                if let local { context.delete(local) }
                continue
            }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            let tag = local ?? VoiceTag(kind: .activity, name: row.name)
            tag.id = row.id
            tag.createdAt = row.createdAt
            tag.updatedAt = row.updatedAt
            tag.kindRaw = row.kindRaw
            tag.name = row.name
            tag.isBuiltIn = row.isBuiltIn
            tag.sortOrder = row.sortOrder
            if local == nil { context.insert(tag) }
        }
    }

    // MARK: audio

    func pendingAudioUploads() throws -> [PendingAudio] {
        try fetchAll(VoiceRecording.self).compactMap { recording in
            guard recording.audioUploadedAt == nil, !recording.audioFilename.isEmpty,
                  mediaStore.exists(recording.audioFilename),
                  let data = try? Data(contentsOf: mediaStore.url(for: recording.audioFilename)) else { return nil }
            return PendingAudio(recordingID: recording.id, filename: recording.audioFilename, data: data)
        }
    }

    func markAudioUploaded(recordingID: UUID, at date: Date) throws {
        guard let recording = try byID(VoiceRecording.self)[recordingID] else { return }
        recording.audioUploadedAt = date
        // The server has to learn about the flag, so the row must look changed.
        recording.updatedAt = date
    }

    func save() throws {
        try context.save()
    }

    // MARK: helpers

    /// Last write wins: a remote row is applied only when it is strictly newer than what is here.
    private func shouldApply(_ remote: Date, over local: Date?) -> Bool {
        guard let local else { return true }
        return remote > local
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    private func byID<T: SyncIdentifiable>(_ type: T.Type) throws -> [UUID: T] {
        Dictionary(try fetchAll(type).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Every synced model carries a `UUID` id, which is what pull merges on.
protocol SyncIdentifiable: PersistentModel {
    var id: UUID { get }
}

extension Animal: SyncIdentifiable {}
extension VoiceRecording: SyncIdentifiable {}
extension Vocalization: SyncIdentifiable {}
extension VoiceTag: SyncIdentifiable {}
```

`App/Sync/LocalStore.swift` needs `import AnimalVoiceAudio` for `Segment` and `VocalFeatures`; put it above `import Foundation`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `LocalStoreTests` eight cases are green.

- [ ] **Step 6: Commit**

```bash
git add App/Sync/RemoteStore.swift App/Sync/LocalStore.swift AppTests/LocalStoreTests.swift
git commit -m "feat(sync): RemoteStore protocol with an in-memory double, SwiftData local store

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: SyncEngine, the push and pull orchestration

**Files:**
- Create: `App/Sync/SyncEngine.swift`
- Create: `AppTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `LocalStore`, `SwiftDataLocalStore`, `RemoteStore`, `InMemoryRemoteStore`, `DeletedRecordInfo`, `PendingAudio` (Task 8); `SyncState`, `SyncTable` (Task 3); the row structs and `RemoteAudioPath` (Task 7).
- Produces: `@MainActor final class SyncEngine` with `init(local: any LocalStore, remote: any RemoteStore, now: @escaping () -> Date = Date.init)` and `func sync(state: SyncState) async throws -> SyncState`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/SyncEngineTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class SyncEngineTests: XCTestCase {
    private let userID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private var context: ModelContext!
    private var media: InMemoryMediaStore!
    private var local: SwiftDataLocalStore!
    private var remote: InMemoryRemoteStore!
    private var engine: SyncEngine!

    override func setUpWithError() throws {
        context = try TestSupport.container().mainContext
        media = InMemoryMediaStore()
        local = SwiftDataLocalStore(context: context, mediaStore: media, userID: userID)
        remote = InMemoryRemoteStore()
        engine = SyncEngine(local: local, remote: remote)
    }

    func testPushSendsLocalRowsAndMovesTheWatermark() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(animal)
        try context.save()

        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals.count, 1)
        XCTAssertEqual(remote.animals[animal.id]?.name, "Miso")
        XCTAssertEqual(remote.animals[animal.id]?.userID, userID)
        XCTAssertEqual(state.lastPushed(.animals), Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(state.lastSyncedUserID, userID.uuidString)
    }

    func testASecondSyncPushesNothingNew() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(animal)
        try context.save()

        let first = try await engine.sync(state: SyncState())
        remote.animals.removeAll()
        _ = try await engine.sync(state: first)
        XCTAssertTrue(remote.animals.isEmpty, "an unchanged row must not be pushed twice")
    }

    func testPullCreatesLocalRecordsAndMovesTheWatermark() async throws {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 2000)
        remote.animals[id] = AnimalRow(id: id, userID: userID, createdAt: when, updatedAt: when, deletedAt: nil,
                                       name: "Remote", species: "horse", colorHex: "#112233",
                                       photoFilename: nil, photoThumbnailFilename: nil, tracksOutdoorTime: true,
                                       sortOrder: 0, isArchived: false, note: nil)

        let state = try await engine.sync(state: SyncState())
        let animals = try context.fetch(FetchDescriptor<Animal>())
        XCTAssertEqual(animals.map(\.name), ["Remote"])
        XCTAssertEqual(state.lastPulled(.animals), when)
    }

    func testPushSendsTombstonesAndClearsThem() async throws {
        let gone = UUID()
        context.insert(DeletedRecord(entity: SyncTable.voiceTags.rawValue, recordID: gone,
                                     deletedAt: Date(timeIntervalSince1970: 3000)))
        try context.save()

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.tags[gone]?.deletedAt, Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 0,
                       "a pushed tombstone is no longer needed locally")
    }

    /// A remote delete wins only when it is newer than the local row, which is the same
    /// last-write-wins rule ordinary edits follow. The watermark starts at the local row's
    /// timestamp so this cycle pulls without first pushing the row back.
    func testPullAppliesARemoteTombstoneAsALocalDelete() async throws {
        let tag = VoiceTag(kind: .meaning, name: "Hungry")
        tag.updatedAt = Date(timeIntervalSince1970: 3500)
        context.insert(tag)
        try context.save()
        remote.tags[tag.id] = VoiceTagRow.tombstone(id: tag.id, userID: userID,
                                                    deletedAt: Date(timeIntervalSince1970: 4000))

        var state = SyncState()
        state.setLastPushed(.voiceTags, Date(timeIntervalSince1970: 3500))
        _ = try await engine.sync(state: state)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).count, 0)
    }

    func testLastWriteWinsBothWays() async throws {
        let tag = VoiceTag(kind: .meaning, name: "Local")
        tag.updatedAt = Date(timeIntervalSince1970: 5000)
        context.insert(tag)
        try context.save()

        // Remote is older: the local name survives the pull.
        remote.tags[tag.id] = VoiceTagRow(id: tag.id, userID: userID, createdAt: SyncState.epoch,
                                          updatedAt: Date(timeIntervalSince1970: 4000), deletedAt: nil,
                                          kindRaw: "meaning", name: "Stale", isBuiltIn: false, sortOrder: 0)
        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(tag.name, "Local")
        XCTAssertEqual(remote.tags[tag.id]?.name, "Local", "the push overwrites the older server row")

        // Remote is newer: it wins on the next pull.
        remote.tags[tag.id]?.name = "Fresh"
        remote.tags[tag.id]?.updatedAt = Date(timeIntervalSince1970: 6000)
        state = try await engine.sync(state: state)
        XCTAssertEqual(tag.name, "Fresh")
    }

    func testAudioIsUploadedOnceAndFlaggedLocally() async throws {
        let recording = VoiceRecording(audioFilename: "a1-audio.m4a", durationS: 2)
        recording.updatedAt = Date(timeIntervalSince1970: 7000)
        context.insert(recording)
        try context.save()
        try media.write(Data([1, 2, 3]), as: "a1-audio.m4a")

        let state = try await engine.sync(state: SyncState())
        let path = RemoteAudioPath.make(userID: userID, filename: "a1-audio.m4a")
        XCTAssertEqual(remote.audio[path], Data([1, 2, 3]))
        XCTAssertEqual(remote.uploadCount, 1)
        XCTAssertNotNil(recording.audioUploadedAt)
        XCTAssertNotNil(remote.recordings[recording.id]?.audioUploadedAt,
                        "the flag has to reach the server in the same push")

        _ = try await engine.sync(state: state)
        XCTAssertEqual(remote.uploadCount, 1, "an uploaded file must not be uploaded again")
    }

    func testAFailedPushLeavesTheWatermarksWhereTheyWere() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 8000)
        context.insert(animal)
        try context.save()
        remote.failNextCall = true

        do {
            _ = try await engine.sync(state: SyncState())
            XCTFail("expected the scripted failure to propagate")
        } catch InMemoryRemoteStore.Failure.scripted {
            // expected
        }

        remote.failNextCall = false
        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals.count, 1, "the retry still sends the row")
        XCTAssertEqual(state.lastPushed(.animals), Date(timeIntervalSince1970: 8000))
    }

    func testRecordingsAndVocalizationsRoundTripThroughTheServer() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "rt-audio.m4a", durationS: 1, animal: animal)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0.1, endS: 0.4), features: VoiceFixtures.features())
        vocalization.recording = recording
        vocalization.meaningTag = "Hungry"
        context.insert(vocalization)
        try context.save()

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.recordings[recording.id]?.animalID, animal.id)
        XCTAssertEqual(remote.vocalizations[vocalization.id]?.recordingID, recording.id)
        XCTAssertEqual(remote.vocalizations[vocalization.id]?.meaningTag, "Hungry")

        // A second device: a fresh local store pulls everything the first one pushed.
        let otherContext = try TestSupport.container().mainContext
        let otherLocal = SwiftDataLocalStore(context: otherContext, mediaStore: InMemoryMediaStore(), userID: userID)
        let otherEngine = SyncEngine(local: otherLocal, remote: remote)
        _ = try await otherEngine.sync(state: SyncState())

        let pulled = try otherContext.fetch(FetchDescriptor<Vocalization>())
        XCTAssertEqual(pulled.count, 1)
        XCTAssertEqual(pulled[0].meaningTag, "Hungry")
        XCTAssertEqual(pulled[0].recording?.id, recording.id)
        XCTAssertEqual(pulled[0].recording?.animal?.name, "Miso")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'SyncEngine' in scope`.

- [ ] **Step 3: Write the engine**

Create `App/Sync/SyncEngine.swift`:
```swift
import Foundation

/// Moves rows between the device and the server. Pure orchestration: it knows nothing about
/// SwiftData or about supabase-swift, only about `LocalStore` and `RemoteStore`, which is what makes
/// it testable against `InMemoryRemoteStore`.
///
/// Order matters. Audio goes first so the `audioUploadedAt` flag is part of the same row push;
/// push goes before pull so a row this device just changed is not immediately overwritten by the
/// stale copy the server still holds. A row that arrives on a pull is pushed back once on the next
/// cycle, which is a harmless idempotent upsert of identical content.
@MainActor
final class SyncEngine {
    private let local: any LocalStore
    private let remote: any RemoteStore
    private let now: () -> Date

    init(local: any LocalStore, remote: any RemoteStore, now: @escaping () -> Date = Date.init) {
        self.local = local
        self.remote = remote
        self.now = now
    }

    func sync(state: SyncState) async throws -> SyncState {
        var next = state
        try await uploadAudio()
        next = try await push(next)
        next = try await pull(next)
        next.lastSyncedUserID = local.userID.uuidString
        next.lastSyncedAt = now()
        next.lastSyncStatus = "Synced"
        return next
    }

    // MARK: push

    private func uploadAudio() async throws {
        let pending = try local.pendingAudioUploads()
        guard !pending.isEmpty else { return }
        for item in pending {
            try await remote.uploadAudio(path: RemoteAudioPath.make(userID: local.userID, filename: item.filename),
                                         data: item.data)
            try local.markAudioUploaded(recordingID: item.recordingID, at: now())
        }
        try local.save()
    }

    private func push(_ state: SyncState) async throws -> SyncState {
        var next = state
        let deletions = try local.tombstones(after: SyncState.epoch)
        var highestTombstone = SyncState.epoch

        for table in SyncTable.allCases {
            let since = next.lastPushed(table)
            let graves = deletions.filter { $0.table == table && $0.deletedAt > since }
            var highest = since

            switch table {
            case .animals:
                let rows = try local.changedAnimals(after: since)
                    + graves.map { AnimalRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertAnimals(rows)
                    highest = rows.map(\.updatedAt).max() ?? since
                }
            case .voiceRecordings:
                let rows = try local.changedRecordings(after: since)
                    + graves.map { VoiceRecordingRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertRecordings(rows)
                    highest = rows.map(\.updatedAt).max() ?? since
                }
            case .vocalizations:
                let rows = try local.changedVocalizations(after: since)
                    + graves.map { VocalizationRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertVocalizations(rows)
                    highest = rows.map(\.updatedAt).max() ?? since
                }
            case .voiceTags:
                let rows = try local.changedTags(after: since)
                    + graves.map { VoiceTagRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertTags(rows)
                    highest = rows.map(\.updatedAt).max() ?? since
                }
            }

            next.setLastPushed(table, highest)
            highestTombstone = max(highestTombstone, graves.map(\.deletedAt).max() ?? SyncState.epoch)
        }

        if highestTombstone > SyncState.epoch {
            try local.clearTombstones(upTo: highestTombstone)
            try local.save()
        }
        return next
    }

    // MARK: pull

    private func pull(_ state: SyncState) async throws -> SyncState {
        var next = state
        // Parents before children, so a child row can find its parent on the first pass.
        for table in [SyncTable.animals, .voiceRecordings, .vocalizations, .voiceTags] {
            let since = next.lastPulled(table)
            var highest = since

            switch table {
            case .animals:
                let rows = try await remote.fetchAnimals(since: since)
                try local.apply(animals: rows)
                highest = rows.map(\.updatedAt).max() ?? since
            case .voiceRecordings:
                let rows = try await remote.fetchRecordings(since: since)
                try local.apply(recordings: rows)
                highest = rows.map(\.updatedAt).max() ?? since
            case .vocalizations:
                let rows = try await remote.fetchVocalizations(since: since)
                try local.apply(vocalizations: rows)
                highest = rows.map(\.updatedAt).max() ?? since
            case .voiceTags:
                let rows = try await remote.fetchTags(since: since)
                try local.apply(tags: rows)
                highest = rows.map(\.updatedAt).max() ?? since
            }

            next.setLastPulled(table, highest)
        }
        try local.save()
        return next
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncEngineTests` nine cases are green.

Correction if `testAudioIsUploadedOnceAndFlaggedLocally` fails on `remote.recordings[...]?.audioUploadedAt`: the upload ran after the row push, so the flag missed its push. `sync(state:)` must call `uploadAudio()` before `push(_:)`.

Correction if `testLastWriteWinsBothWays` fails with `tag.name == "Stale"`: pull ran before push, so the stale server row overwrote the local one. `sync(state:)` must call `push(_:)` before `pull(_:)`.

- [ ] **Step 5: Commit**

```bash
git add App/Sync/SyncEngine.swift AppTests/SyncEngineTests.swift
git commit -m "feat(sync): SyncEngine push, pull, tombstones and last-write-wins

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: SupabaseRemoteStore, SyncService, MediaResolver, and every mutation site

**Files:**
- Create: `App/Sync/SupabaseRemoteStore.swift`
- Create: `App/Sync/SyncService.swift`
- Create: `App/Sync/MediaResolver.swift`
- Create: `AppTests/MediaResolverTests.swift`
- Modify: `App/AnimalTrackerApp.swift` (scene phase, sync configuration)
- Modify: `App/Views/Settings/SettingsView.swift` (sync rows in the Account section)
- Modify: `App/Views/Animals/AnimalFormView.swift:159-163`
- Modify: `App/Views/Animals/ManageAnimalsView.swift:23`, `:36`, `:86-88`, `:98-101`
- Modify: `App/Views/Voice/RecordView.swift` (`finish()`)
- Modify: `App/Views/Voice/TagSheet.swift` (`addTag(_:kind:selection:)`, `save()`)
- Modify: `App/Views/Voice/VoiceHistoryView.swift` (`.onDelete`)
- Modify: `App/Views/Voice/RecordingDetailView.swift` (play button, delete dialog, `reanalyze()`)
- Modify: `App/Views/Voice/VocalizationEditView.swift` (reset button, `markOverriddenIfChanged()`, `VocalizationPlayButton`)
- Modify: `App/Views/Voice/AskView.swift` (`finish()`)
- Modify: `App/Views/Voice/ManageVoiceTagsView.swift` (add, rename, delete)

**Interfaces:**
- Consumes: `SyncEngine` (Task 9), `RemoteStore`, `SwiftDataLocalStore`, `InMemoryRemoteStore` (Task 8), `SyncState`, `AuthState`, `AuthService` (Task 3), `RemoteAudioPath`, `SyncCoding` (Task 7), `Tombstone`, `MediaStore.write(_:as:)` (Task 6).
- Produces:
  - `final class SupabaseRemoteStore: RemoteStore` with `init(client: SupabaseClient)`.
  - `@MainActor final class SyncService: ObservableObject` with `static let shared`, `@Published private(set) var isSyncing: Bool`, `@Published private(set) var statusText: String`, `@Published private(set) var lastSyncedAt: Date?`, `var lastSyncDescription: String`, `func configure(container: ModelContainer, mediaStore: MediaStore)`, `func update(for state: AuthState, client: SupabaseClient?)`, `func requestSync()`, `func syncNow() async`.
  - `@MainActor final class MediaResolver: ObservableObject` with `static let shared`, `@Published private(set) var fetching: Set<UUID>`, `var remote: (any RemoteStore)?`, `var userID: UUID?`, `func ensureAudio(for recording: VoiceRecording, mediaStore: MediaStore) async -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `AppTests/MediaResolverTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class MediaResolverTests: XCTestCase {
    private let userID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    func testPresentFileNeedsNoDownload() async throws {
        let context = try TestSupport.container().mainContext
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = VoiceRecording(audioFilename: "have-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()
        try media.write(Data([1]), as: "have-audio.m4a")

        let resolver = MediaResolver()
        resolver.remote = remote
        resolver.userID = userID
        XCTAssertTrue(await resolver.ensureAudio(for: recording, mediaStore: media))
        XCTAssertEqual(remote.downloadCount, 0)
    }

    func testMissingFileIsDownloadedAndWrittenUnderTheSameName() async throws {
        let context = try TestSupport.container().mainContext
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = VoiceRecording(audioFilename: "need-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()
        remote.audio[RemoteAudioPath.make(userID: userID, filename: "need-audio.m4a")] = Data([4, 5])

        let resolver = MediaResolver()
        resolver.remote = remote
        resolver.userID = userID
        XCTAssertTrue(await resolver.ensureAudio(for: recording, mediaStore: media))
        XCTAssertEqual(remote.downloadCount, 1)
        XCTAssertTrue(media.exists("need-audio.m4a"))
        XCTAssertEqual(try Data(contentsOf: media.url(for: "need-audio.m4a")), Data([4, 5]))
        XCTAssertTrue(resolver.fetching.isEmpty)
    }

    func testAMissingRemoteObjectReportsFailureAndLeavesNoFile() async throws {
        let context = try TestSupport.container().mainContext
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = VoiceRecording(audioFilename: "nowhere-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()

        let resolver = MediaResolver()
        resolver.remote = remote
        resolver.userID = userID
        let ok = await resolver.ensureAudio(for: recording, mediaStore: media)
        XCTAssertFalse(ok)
        XCTAssertFalse(media.exists("nowhere-audio.m4a"))
        XCTAssertTrue(resolver.fetching.isEmpty)
    }

    func testOfflineResolverReportsFailureWithoutCrashing() async throws {
        let context = try TestSupport.container().mainContext
        let media = InMemoryMediaStore()
        let recording = VoiceRecording(audioFilename: "offline-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()

        let resolver = MediaResolver()
        XCTAssertFalse(await resolver.ensureAudio(for: recording, mediaStore: media))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'MediaResolver' in scope`.

- [ ] **Step 3: Write the Supabase-backed remote store**

Create `App/Sync/SupabaseRemoteStore.swift`:
```swift
import Foundation
import Supabase

/// The real backend. Every method is one PostgREST or Storage call; all the decisions live in
/// SyncEngine, which is why nothing here needs a test double of its own.
final class SupabaseRemoteStore: RemoteStore {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: upserts

    func upsertAnimals(_ rows: [AnimalRow]) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(SyncTable.animals.rawValue).upsert(rows, onConflict: "id").execute()
    }

    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(SyncTable.voiceRecordings.rawValue).upsert(rows, onConflict: "id").execute()
    }

    func upsertVocalizations(_ rows: [VocalizationRow]) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(SyncTable.vocalizations.rawValue).upsert(rows, onConflict: "id").execute()
    }

    func upsertTags(_ rows: [VoiceTagRow]) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(SyncTable.voiceTags.rawValue).upsert(rows, onConflict: "id").execute()
    }

    // MARK: fetches

    func fetchAnimals(since: Date) async throws -> [AnimalRow] {
        try await client.from(SyncTable.animals.rawValue)
            .select()
            .gt("updated_at", value: SyncCoding.formatter.string(from: since))
            .order("updated_at", ascending: true)
            .execute()
            .value
    }

    func fetchRecordings(since: Date) async throws -> [VoiceRecordingRow] {
        try await client.from(SyncTable.voiceRecordings.rawValue)
            .select()
            .gt("updated_at", value: SyncCoding.formatter.string(from: since))
            .order("updated_at", ascending: true)
            .execute()
            .value
    }

    func fetchVocalizations(since: Date) async throws -> [VocalizationRow] {
        try await client.from(SyncTable.vocalizations.rawValue)
            .select()
            .gt("updated_at", value: SyncCoding.formatter.string(from: since))
            .order("updated_at", ascending: true)
            .execute()
            .value
    }

    func fetchTags(since: Date) async throws -> [VoiceTagRow] {
        try await client.from(SyncTable.voiceTags.rawValue)
            .select()
            .gt("updated_at", value: SyncCoding.formatter.string(from: since))
            .order("updated_at", ascending: true)
            .execute()
            .value
    }

    // MARK: audio

    func uploadAudio(path: String, data: Data) async throws {
        try await client.storage
            .from(RemoteAudioPath.bucket)
            .upload(path: path, file: data,
                    options: FileOptions(cacheControl: "3600", contentType: "audio/mp4", upsert: true))
    }

    func downloadAudio(path: String) async throws -> Data {
        try await client.storage.from(RemoteAudioPath.bucket).download(path: path)
    }
}
```

If the resolved supabase-swift version rejects `.order("updated_at", ascending: true)`, drop those four `.order(...)` lines: `SyncEngine` takes `max(updatedAt)` over whatever comes back, so ordering is a convenience, not a requirement.

- [ ] **Step 4: Write the media resolver**

Create `App/Sync/MediaResolver.swift`:
```swift
import Foundation

/// Fetches a recording's audio from Storage the first time a screen needs to play it and the local
/// file is not there, which is what happens on a second device after a pull.
@MainActor
final class MediaResolver: ObservableObject {
    static let shared = MediaResolver()

    /// Recording ids currently downloading, so a view can show a spinner.
    @Published private(set) var fetching: Set<UUID> = []

    var remote: (any RemoteStore)?
    var userID: UUID?

    init() {}

    /// True when the audio file is on disk afterwards.
    @discardableResult
    func ensureAudio(for recording: VoiceRecording, mediaStore: MediaStore) async -> Bool {
        let filename = recording.audioFilename
        guard !filename.isEmpty else { return false }
        if mediaStore.exists(filename) { return true }
        guard let remote, let userID else { return false }
        let id = recording.id
        fetching.insert(id)
        defer { fetching.remove(id) }
        do {
            let data = try await remote.downloadAudio(path: RemoteAudioPath.make(userID: userID, filename: filename))
            try mediaStore.write(data, as: filename)
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 5: Write the sync service**

Create `App/Sync/SyncService.swift`:
```swift
import Foundation
import SwiftData
import Supabase

/// Drives SyncEngine from the app: on scene activation, right after sign-in, and on every mutation
/// through a two second debounce so a burst of edits becomes one sync.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var isSyncing = false
    @Published private(set) var statusText = "Not signed in"
    @Published private(set) var lastSyncedAt: Date?

    private var container: ModelContainer?
    private var mediaStore: MediaStore = FileMediaStore()
    private var remote: (any RemoteStore)?
    private var userID: UUID?
    private var debounce: Task<Void, Never>?

    init() {
        let state = SyncState.load()
        statusText = state.lastSyncStatus
        lastSyncedAt = state.lastSyncedAt
    }

    /// Called once by the app with the live container, and again whenever the container is replaced.
    func configure(container: ModelContainer, mediaStore: MediaStore) {
        self.container = container
        self.mediaStore = mediaStore
    }

    /// Called whenever the auth state changes.
    func update(for state: AuthState, client: SupabaseClient?) {
        debounce?.cancel()
        switch state {
        case .signedIn(let userID, _):
            self.userID = userID
            remote = client.map(SupabaseRemoteStore.init)
            MediaResolver.shared.remote = remote
            MediaResolver.shared.userID = userID
            if remote == nil { statusText = "Offline" }
        case .offline, .signedOut, .unknown:
            self.userID = nil
            remote = nil
            MediaResolver.shared.remote = nil
            MediaResolver.shared.userID = nil
            statusText = state == .offline ? "Offline" : "Not signed in"
            lastSyncedAt = nil
        }
    }

    func requestSync() {
        guard remote != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard !isSyncing, let container, let remote, let userID else { return }
        isSyncing = true
        statusText = "Syncing"
        defer { isSyncing = false }

        let local = SwiftDataLocalStore(context: container.mainContext, mediaStore: mediaStore, userID: userID)
        let engine = SyncEngine(local: local, remote: remote)
        var state = SyncState.load()
        do {
            state = try await engine.sync(state: state)
        } catch {
            state.lastSyncStatus = "Failed: \(error.localizedDescription)"
        }
        state.save()
        statusText = state.lastSyncStatus
        lastSyncedAt = state.lastSyncedAt
    }

    var lastSyncDescription: String {
        guard let lastSyncedAt else { return "Never" }
        return lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
```

- [ ] **Step 6: Drive the service from the app**

In `App/AnimalTrackerApp.swift`, add one property after `@State private var storeGeneration = 0`:
```swift
    @Environment(\.scenePhase) private var scenePhase
```

Replace the `WindowGroup { ... }` body with:
```swift
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .id(storeGeneration)
                .onAppear { SyncService.shared.configure(container: container, mediaStore: FileMediaStore()) }
                .onChange(of: auth.storeResetToken) { _, _ in resetStore() }
                .onChange(of: auth.state) { _, state in
                    SyncService.shared.update(for: state, client: auth.client)
                    if case .signedIn = state { Task { await SyncService.shared.syncNow() } }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { SyncService.shared.requestSync() }
                }
        }
        .modelContainer(container)
```

and add one line at the end of `resetStore()`, after `storeGeneration += 1`:
```swift
            SyncService.shared.configure(container: fresh, mediaStore: FileMediaStore())
```

- [ ] **Step 7: Show sync in Settings**

In `App/Views/Settings/SettingsView.swift`, add one property after `@EnvironmentObject private var auth: AuthService`:
```swift
    @ObservedObject private var sync = SyncService.shared
```

and add these three rows inside the `Section("Account")` from Task 4, after the closing brace of the `switch auth.state { ... }`:
```swift
                LabeledContent("Last sync", value: sync.lastSyncDescription)
                LabeledContent("Status", value: sync.statusText)
                Button("Sync now") { Task { await sync.syncNow() } }
                    .disabled(sync.isSyncing)
```

- [ ] **Step 8: Stamp updatedAt at every animal mutation site**

In `App/Views/Animals/AnimalFormView.swift`, insert one line between line 159 (the `}` that closes the photo block) and line 161 (`do {`):
```swift
        target.updatedAt = Date()
```
and change line 164 from
```swift
            if selectedAnimalId.isEmpty { selectedAnimalId = target.id.uuidString }
```
to
```swift
            if selectedAnimalId.isEmpty { selectedAnimalId = target.id.uuidString }
            SyncService.shared.requestSync()
```

In `App/Views/Animals/ManageAnimalsView.swift`:

Line 23, from
```swift
                            Button("Archive") { animal.isArchived = true; try? context.save() }.tint(.orange)
```
to
```swift
                            Button("Archive") { setArchived(animal, true) }.tint(.orange)
```

Line 36, from
```swift
                                Button("Unarchive") { animal.isArchived = false; try? context.save() }.tint(.green)
```
to
```swift
                                Button("Unarchive") { setArchived(animal, false) }.tint(.green)
```

Lines 86 to 88 inside `move(from:to:)`, from
```swift
        for (i, a) in ordered.enumerated() { a.sortOrder = i }
        for (i, a) in archived.enumerated() { a.sortOrder = ordered.count + i }
        try? context.save()
```
to
```swift
        for (i, a) in ordered.enumerated() { a.sortOrder = i; a.updatedAt = Date() }
        for (i, a) in archived.enumerated() { a.sortOrder = ordered.count + i; a.updatedAt = Date() }
        try? context.save()
        SyncService.shared.requestSync()
```

Lines 98 to 101 inside `delete(_:)`, from
```swift
            if let photo = animal.photoFilename { mediaStore.delete(photo) }
            if let thumb = animal.photoThumbnailFilename { mediaStore.delete(thumb) }
            context.delete(animal)
            try context.save()
```
to
```swift
            if let photo = animal.photoFilename { mediaStore.delete(photo) }
            if let thumb = animal.photoThumbnailFilename { mediaStore.delete(thumb) }
            Tombstone.record(.animals, id: animal.id, in: context)
            context.delete(animal)
            try context.save()
            SyncService.shared.requestSync()
```

and add this method after `delete(_:)`:
```swift
    private func setArchived(_ animal: Animal, _ archived: Bool) {
        animal.isArchived = archived
        animal.updatedAt = Date()
        try? context.save()
        SyncService.shared.requestSync()
    }
```

- [ ] **Step 9: Stamp updatedAt at every voice mutation site**

In `App/Views/Voice/RecordView.swift`, inside `finish()`, change
```swift
                let recording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(recording)
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                pendingRecording = recording
```
to
```swift
                let recording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(recording)
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                recording.updatedAt = Date()
                try? context.save()
                SyncService.shared.requestSync()
                pendingRecording = recording
```
Analysis inserts the `Vocalization` rows, and a freshly inserted model already carries `updatedAt = Date()`, so only the recording needs restamping.

In `App/Views/Voice/TagSheet.swift`, change `addTag(_:kind:selection:)` from
```swift
        if !tags.contains(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
        }
```
to
```swift
        if !tags.contains(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
            SyncService.shared.requestSync()
        }
```
and change `save()` from
```swift
    private func save() {
        recording.editedAt = Date()
        TagPropagation.apply(to: recording)
        try? context.save()
        dismiss()
    }
```
to
```swift
    private func save() {
        let now = Date()
        recording.editedAt = now
        TagPropagation.apply(to: recording)
        recording.updatedAt = now
        // TagPropagation rewrites the non-overridden sounds, so they are changed rows too.
        for vocalization in recording.sortedVocalizations { vocalization.updatedAt = now }
        try? context.save()
        SyncService.shared.requestSync()
        dismiss()
    }
```

In `App/Views/Voice/VoiceHistoryView.swift`, change the `.onDelete` block from
```swift
                .onDelete { offsets in
                    for r in offsets.map({ filtered[$0] }) {
                        mediaStore.delete(r.audioFilename)
                        context.delete(r)
                    }
                    try? context.save()
                }
```
to
```swift
                .onDelete { offsets in
                    for r in offsets.map({ filtered[$0] }) {
                        mediaStore.delete(r.audioFilename)
                        Tombstone.recordRecording(r, in: context)
                        context.delete(r)
                    }
                    try? context.save()
                    SyncService.shared.requestSync()
                }
```

In `App/Views/Voice/RecordingDetailView.swift`, change the delete dialog body from
```swift
            Button("Delete", role: .destructive) {
                player.stop()
                mediaStore.delete(recording.audioFilename)
                context.delete(recording)
                try? context.save()
                dismiss()
            }
```
to
```swift
            Button("Delete", role: .destructive) {
                player.stop()
                mediaStore.delete(recording.audioFilename)
                Tombstone.recordRecording(recording, in: context)
                context.delete(recording)
                try? context.save()
                SyncService.shared.requestSync()
                dismiss()
            }
```
change the play button body from
```swift
                    Button {
                        if isPlayingWhole {
                            player.stop()
                        } else if mediaStore.exists(recording.audioFilename) {
                            player.play(url: mediaStore.url(for: recording.audioFilename), id: recording.id)
                        }
                    } label: {
                        Label(isPlayingWhole ? "Stop" : "Play recording", systemImage: isPlayingWhole ? "stop.fill" : "play.fill")
                    }
                    .disabled(!mediaStore.exists(recording.audioFilename))
```
to
```swift
                    Button {
                        if isPlayingWhole {
                            player.stop()
                        } else {
                            Task {
                                guard await MediaResolver.shared.ensureAudio(for: recording, mediaStore: mediaStore) else { return }
                                player.play(url: mediaStore.url(for: recording.audioFilename), id: recording.id)
                            }
                        }
                    } label: {
                        Label(isPlayingWhole ? "Stop" : "Play recording", systemImage: isPlayingWhole ? "stop.fill" : "play.fill")
                    }
                    .disabled(MediaResolver.shared.fetching.contains(recording.id))
```
change the missing-file notice from
```swift
                if !mediaStore.exists(recording.audioFilename) {
                    Label("Audio file missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
```
to
```swift
                if !mediaStore.exists(recording.audioFilename) {
                    Label(MediaResolver.shared.fetching.contains(recording.id) ? "Fetching audio" : "Audio not on this phone yet",
                          systemImage: "icloud.and.arrow.down").foregroundStyle(.orange)
                }
```
and add two lines at the end of `reanalyze()`'s `Task { ... }` block, after the `await AnalysisService.analyze(...)` call:
```swift
            recording.updatedAt = Date()
            try? context.save()
            SyncService.shared.requestSync()
```

Add `@ObservedObject private var resolver = MediaResolver.shared` to `RecordingDetailView`'s properties, after `@StateObject private var player = AudioPlayer()`, so the fetching spinner text actually refreshes.

In `App/Views/Voice/VocalizationEditView.swift`, change the reset button from
```swift
                    Button("Reset to recording tags") {
                        TagPropagation.resetOverride(vocalization)
                        try? context.save()
                    }
```
to
```swift
                    Button("Reset to recording tags") {
                        TagPropagation.resetOverride(vocalization)
                        vocalization.updatedAt = Date()
                        try? context.save()
                        SyncService.shared.requestSync()
                    }
```
and change `markOverriddenIfChanged()` from
```swift
    private func markOverriddenIfChanged() {
        if TagPropagation.differsFromRecording(vocalization) { vocalization.overridden = true }
        try? context.save()
    }
```
to
```swift
    private func markOverriddenIfChanged() {
        if TagPropagation.differsFromRecording(vocalization) { vocalization.overridden = true }
        vocalization.updatedAt = Date()
        try? context.save()
        SyncService.shared.requestSync()
    }
```

In the same file, change `VocalizationPlayButton`'s body from
```swift
            if player.playingID == vocalization.id {
                player.stop()
            } else if let recording = vocalization.recording, mediaStore.exists(recording.audioFilename) {
                player.play(url: mediaStore.url(for: recording.audioFilename), id: vocalization.id,
                            startS: vocalization.startS, endS: vocalization.endS)
            }
```
to
```swift
            if player.playingID == vocalization.id {
                player.stop()
            } else if let recording = vocalization.recording {
                Task {
                    guard await MediaResolver.shared.ensureAudio(for: recording, mediaStore: mediaStore) else { return }
                    player.play(url: mediaStore.url(for: recording.audioFilename), id: vocalization.id,
                                startS: vocalization.startS, endS: vocalization.endS)
                }
            }
```
`VocalizationPlayButton` lives in `App/Views/Voice/RecordingDetailView.swift` if Plan B put it there; make the change wherever the struct actually is. Find it with `grep -rn "struct VocalizationPlayButton" App/`.

In `App/Views/Voice/AskView.swift`, inside `finish()`, add one line after `try context.save()`:
```swift
                SyncService.shared.requestSync()
```

In `App/Views/Voice/ManageVoiceTagsView.swift`, change the Add button from
```swift
                        context.insert(VoiceTag(kind: newKind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
                        try? context.save()
                        newName = ""
```
to
```swift
                        context.insert(VoiceTag(kind: newKind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
                        try? context.save()
                        SyncService.shared.requestSync()
                        newName = ""
```
change the rename field from
```swift
                    TextField("Name", text: Binding(get: { tag.name }, set: { tag.name = $0; try? context.save() }))
```
to
```swift
                    TextField("Name", text: Binding(get: { tag.name }, set: {
                        tag.name = $0
                        tag.updatedAt = Date()
                        try? context.save()
                        SyncService.shared.requestSync()
                    }))
```
and change the delete action from
```swift
                        Button("Delete", role: .destructive) { context.delete(tag); try? context.save() }
```
to
```swift
                        Button("Delete", role: .destructive) {
                            Tombstone.record(.voiceTags, id: tag.id, in: context)
                            context.delete(tag)
                            try? context.save()
                            SyncService.shared.requestSync()
                        }
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `MediaResolverTests` four cases are green and every earlier test still passes. Nothing here reaches the network: the tests build `MediaResolver()` directly with an `InMemoryRemoteStore`, and `SyncService.shared.requestSync()` returns immediately because no remote is configured in a test run.

- [ ] **Step 11: Check no mutation site was missed**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -rn "context.save()" App/Views | grep -v "requestSync" | grep -v "TestSupport"
```
Expected: every remaining line is inside a function whose next statement is `SyncService.shared.requestSync()`. Inspect each hit; a save with no `requestSync()` anywhere in the same function is a missed mutation site.

```bash
grep -rn "context.delete(" App/Views
```
Expected: every hit is preceded by a `Tombstone.record(...)` or `Tombstone.recordRecording(...)` call, except the ones inside `SwiftDataLocalStore` (which is not under `App/Views`).

- [ ] **Step 12: Commit**

```bash
git add App/Sync/SupabaseRemoteStore.swift App/Sync/SyncService.swift App/Sync/MediaResolver.swift \
        AppTests/MediaResolverTests.swift App/AnimalTrackerApp.swift App/Views
git commit -m "feat(sync): Supabase-backed remote store, sync service, and sync-aware mutation sites

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Smoke test, device checks, and the push to main

**Files:**
- Modify: none by default. Any defect found here is fixed in the file that owns it, with a test added to the matching task's test file first.

**Interfaces:**
- Consumes: everything from Tasks 1 to 10.
- Produces: a verified build on `origin/main`.

- [ ] **Step 1: Run the whole suite**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
scripts/test-packages.sh
scripts/test-app.sh
```
Expected: both report zero failures. Do not continue past a failure; fix it in the task that owns the file, test first.

- [ ] **Step 2: Simulator smoke test with the placeholder key**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" App/Config/Supabase.plist
xcrun simctl uninstall booted com.ashlab.AnimalTracker 2>/dev/null || true
scripts/run-sim.sh
```
Expected: the plist prints `REPLACE_WITH_ANON_KEY`, and `build/screenshot.png` shows the orange offline banner above the five tabs. In the simulator, add an animal, record a short clip from the Mac microphone, tag it, and confirm Settings shows "Offline" as the status and "Never" as the last sync. Nothing should attempt a network call.

- [ ] **Step 3: Simulator smoke test with the real key**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
read -rs ANON_KEY && /usr/libexec/PlistBuddy -c "Set :SupabaseAnonKey $ANON_KEY" App/Config/Supabase.plist && unset ANON_KEY
git update-index --skip-worktree App/Config/Supabase.plist
xcrun simctl uninstall booted com.ashlab.AnimalTracker
scripts/run-sim.sh
```
Expected: `build/screenshot.png` now shows the sign-in screen with the Sign in with Apple button and, below it, "Continue offline".

Then check both paths:
1. Tap "Continue offline". The five tabs appear with the offline banner. Settings shows Status "Offline" and a "Sign in" button that returns to the sign-in screen.
2. If Task 1's fallback was not needed and the simulator carries the entitlement, sign in with a real Apple ID in the simulator. Expected: the tabs appear with no banner, Settings shows the account email or user id, and Status becomes "Synced" within a few seconds.

If sign-in fails with a nonce error, apply the fallback recorded in Assumptions: remove `request.nonce = Nonce.sha256(rawNonce)` from `SignInView` and change `AuthService.signInWithApple` to `OpenIDConnectCredentials(provider: .apple, idToken: idToken)`, then repeat this step and record which path worked in the commit body.

- [ ] **Step 4: Verify the data actually landed**

Run:
```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select count(*) from public.animals;"
psql "$PGURI" -c "select id, audio_filename, audio_uploaded_at from public.voice_recordings order by updated_at desc limit 5;"
psql "$PGURI" -c "select name from storage.objects where bucket_id = 'voice-audio' order by created_at desc limit 5;"
unset PGURI
```
Expected: the animal count matches what was added in the simulator, the newest recording has a non-null `audio_uploaded_at`, and the storage object name starts with the signed-in user's lowercase uuid followed by `/`.

- [ ] **Step 5: Sign-out wipe check**

In the simulator, open Settings and tap "Sign out". Expected: the sign-in screen appears. Sign in again with the same Apple ID. Expected: the animals and recordings come back from the server within a few seconds, because the local store was destroyed and repopulated by a pull.

- [ ] **Step 6: Device checks, run by hand**

These need a real phone with the paid team profile, so they are listed rather than scripted:

1. Build to the device from Xcode with the `AnimalTracker` scheme and confirm the app installs and the Sign in with Apple sheet appears when the button is tapped.
2. Sign in with the real Apple ID. Confirm the tabs appear and Settings shows the email or user id.
3. Record a real animal sound on the phone, tag it, and confirm Settings Status reaches "Synced".
4. Re-run Step 4's psql checks and confirm the new recording and its storage object are there.
5. On the simulator (signed in as the same Apple ID), pull and confirm the phone's recording appears in Voice History, and that tapping play downloads the audio through `MediaResolver` and plays it.
6. Turn on airplane mode on the phone, add an animal, turn airplane mode off, reopen the app, and confirm the animal reaches the server.
7. Delete a recording on the phone and confirm it disappears from the simulator after a sync, and that `select deleted_at from public.voice_recordings where id = '<id>'` is non-null.

- [ ] **Step 7: Put the placeholder back before committing**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
git update-index --no-skip-worktree App/Config/Supabase.plist
git checkout -- App/Config/Supabase.plist
/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" App/Config/Supabase.plist
git diff --stat
git grep -n "eyJ" -- . ':!docs' || echo "no JWT-looking string in the tree"
```
Expected: the plist prints `REPLACE_WITH_ANON_KEY`, `git diff --stat` is empty, and the grep prints the "no JWT-looking string" line. A real key in the tree at this point is a hard stop.

- [ ] **Step 8: Merge main and push**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
git fetch origin
git merge origin/main
```
Expected: `origin/main` holds only a LICENSE, so this is a clean merge with no conflicts. If git reports "refusing to merge unrelated histories", re-run as `git merge --allow-unrelated-histories origin/main` and keep both sides.

Then run the suite one more time on the merged tree:
```bash
scripts/test-packages.sh
scripts/test-app.sh
scripts/build-app.sh
```
Expected: zero failures and `** BUILD SUCCEEDED **`.

Then push:
```bash
git push origin HEAD:main
git log --oneline origin/main -3
```
Expected: the push succeeds and `origin/main` now carries this branch's commits on top of the LICENSE commit.

- [ ] **Step 9: Commit the merge if one was created**

`git merge` of an unrelated LICENSE-only history creates a merge commit with a default message. Amend it so it carries the attribution:

```bash
git commit --amend -m "chore: merge origin/main (LICENSE) into the voice milestone branch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Skip this step if `git merge` reported "Already up to date." and created no commit. Push after amending.

---

## Self-review

**Spec coverage.** Every requirement in Addendum v7 and in the plan's scope maps to a task:

| Requirement | Task |
| --- | --- |
| supabase-swift in `project.yml` packages plus the `Supabase` product on both targets | 1 |
| `com.apple.developer.applesignin: [Default]`, `DEVELOPMENT_TEAM: A5S59B326M`, simulator signing check and the `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` fallback | 1 |
| `App/Config/Supabase.plist` with the project URL and `REPLACE_WITH_ANON_KEY`, `SupabaseConfig.load()` returning nil for the placeholder | 2 |
| `Nonce.random(length:)`, `Nonce.sha256(_:)` with a known vector | 3 |
| `AuthService` with `.unknown / .signedOut / .signedIn / .offline`, `restoreSession()`, `signInWithApple(authorization:rawNonce:)`, `signOut()` | 3 |
| `SyncState` with per-table `lastPulledAt` and `lastPushedAt`, `lastSyncStatus`, `lastSyncedUserID`, in UserDefaults | 3 |
| `SignInView` with `SignInWithAppleButton`, hashed nonce on the request, `.email` scope, DEBUG "Continue offline" | 4 |
| `RootView` gating `RootTabView` behind `.signedIn` or `.offline`, offline banner | 4 |
| Settings Account section: email or user id, Sign out | 4 |
| `PersistenceController.destroy()` and container rebuild on sign-out or a different user | 4 |
| SQL migration with four tables, RLS, the four policies, `(user_id, updated_at)` index, private `voice-audio` bucket and its storage policies | 5 |
| `supabase/config.toml`, `supabase link`, `supabase db push` with `SUPABASE_ACCESS_TOKEN`, psql fallback, no password in the repo | 5 |
| `updatedAt` on the four models, `audioUploadedAt` on `VoiceRecording`, `DeletedRecord` registered in `modelTypes` | 6 |
| Codable row structs with snake_case keys, round-trip tested | 7 |
| `RemoteStore` protocol, `SupabaseRemoteStore`, `InMemoryRemoteStore` | 8 and 10 |
| `LocalStore` protocol and `SwiftDataLocalStore` | 8 |
| `SyncEngine` push with tombstones and audio uploads, pull with tombstones and last-write-wins | 9 |
| `MediaResolver` used by `RecordingDetailView` and `VocalizationPlayButton` | 10 |
| `SyncService` on scene phase, after sign-in, and on a debounced `requestSync()`, status published for Settings | 10 |
| Mutation sites in the nine views stamping `updatedAt`, writing tombstones, and requesting a sync | 10 |
| Tests: nonce, config, row round trips, engine push/pull/tombstone/last-write-wins, migration contents, RootView gating with a scripted state, no live network | 3, 2, 7, 9, 5, 4 |
| Smoke test, device steps, push to main | 11 |

**Placeholder scan.** No "TBD", no "similar to Task N", no "add error handling". Every code step carries the full text of the file or the exact before and after of the lines being changed. The two conditional branches in the plan (Task 1's signing fallback, Task 11's nonce fallback) both carry complete replacement code rather than a description.

**Type consistency.** Checked across tasks: `SyncTable` raw values (`animals`, `voice_recordings`, `vocalizations`, `voice_tags`) are the same in Task 3's enum, Task 5's SQL, Task 8's stores and Task 10's `SupabaseRemoteStore`. `SyncState.epoch` is used as the "never synced" watermark in Tasks 3, 8 and 9. `RemoteAudioPath.make(userID:filename:)` returns a lowercase path in Task 7 and is used unchanged in Tasks 9 and 10, matching the `auth.uid()::text || '/%'` policy in Task 5. `MediaStore.write(_:as:)` is declared in Task 6 and used in Tasks 8 and 10. `Tombstone.record(_:id:in:)` and `Tombstone.recordRecording(_:in:)` are declared in Task 6 and used in Task 10. `LocalStore.apply(animals:)` and friends keep the same labels from Task 8's protocol through Task 9's engine. `AuthService.storeResetToken` is published in Task 3 and observed in Task 4. `SyncService.shared.requestSync()` has the same spelling at all fifteen mutation sites in Task 10.
