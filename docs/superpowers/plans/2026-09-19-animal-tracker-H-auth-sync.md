# AnimalTracker Plan H: Sign in with Apple and Supabase sync Implementation Plan

> **Version v4** (2026-09-25). Answers Verifier C (C-D1 to C-D10) and Verifier D (D-D1 to D-D23)
> against v3, both under `.superpowers/sdd/`. Every HIGH and MEDIUM from both is fixed. Anchors are
> against the tree at `8dc20e8`; the app suite total is **247**.
>
> **Changes since v3, by defect id:** D-D1 / D-D2 / D-D23 the secret guard matches value shapes
> only and scans `docs/`; D-D6 a wipe takes `Documents/Media/` with it; D-D7 sign out confirms,
> pushes once with a bounded timeout, then names the unsynced count; D-D8 only `.revoked` signs
> out; D-D12 the guard trigger clamps `updated_at`; D-D18 one commit, one push, no amend after a
> push; D-D9 a Task 12 precondition reads the Apple provider back from the Management API; D-D15 a
> relink pass attaches a child pulled before its parent; D-D19 / C-D3 the audit greps are quoted
> and assert counts; D-D20 / C-D2 one derived test total, 247; D-D21 Step 5 names the device that
> pushed; C-D1 the `animal?.id` grep expects five; C-D4 each confirmation dialog is on its own
> view; D-D10 the keychain accessibility class is justified; D-D11 / C-D10 `SyncStatus` is
> `CaseIterable` in the Interfaces block; D-D14 the nested README fence; D-D22 account deletion is
> checked on the phone; C-D5 a test count; C-D6 the `isBusy` precondition; C-D7 `MediaResolver` is
> injected; C-D8 the tombstone cost is recorded; C-D9 a flaky directory assertion. The full table
> is in "Changes since v3" below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate AnimalTracker behind native Sign in with Apple against Supabase Auth, and sync animals, voice recordings, vocalizations, voice tags and recorded audio to a per-user Supabase project while SwiftData stays the offline working store.

**Architecture:** SwiftData remains the single source of truth the UI reads. Every synced model gains `updatedAt` and raw parent ids, every local delete writes a `DeletedRecord` tombstone, and a pure `SyncEngine` moves rows between a `LocalStore` (SwiftData) and a `RemoteStore` (PostgREST plus Storage). Conflicts resolve last-write-wins on `updatedAt`, enforced a second time server-side by a `before update` trigger. Pulls page on a server-stamped `server_updated_at` cursor. Auth is a small `@MainActor` `AuthService` over `supabase-swift` that owns one ordered transition: it decides store ownership, cancels any running sync, wipes and rebuilds the store, then publishes the new state. `RootView` maps that state onto a screen through a pure `RootGate`, so the gating logic is unit-testable without a network or a UI test.

**Tech Stack:** Swift 5 language mode, iOS 17, SwiftUI, SwiftData, XCTest, XcodeGen, AuthenticationServices, CryptoKit, supabase-swift 2.55.x (the only third-party package), Supabase Postgres with Row Level Security, Supabase Storage, the Supabase CLI.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md`, in particular "Addendum v7 (2026-09-19): Supabase backend and Sign in with Apple" and "Addendum v7.1 (2026-09-22): rulings after the three-way review of Plan H", plus `docs/superpowers/specs/2026-09-18-model-contract.md` for field names. The consolidated review findings this plan answers are in `.superpowers/sdd/planH-review-findings.md`, the two verifiers' findings against v2 are in `.superpowers/sdd/planH-v2-verification.md`, and the two against v3, which this revision answers, are in `.superpowers/sdd/planH-v3-verification-C.md` and `.superpowers/sdd/planH-v3-verification-D.md`. The supabase-swift API re-check is `.superpowers/sdd/planH-supabase-swift-api-check.md`.

## Global Constraints

- **Plan B Task 18 and the Plan B fix wave must be complete before Plan H Task 1 starts.** Task 11 Step 9 edits `App/Views/Voice/ManageVoiceTagsView.swift`, `App/Voice/RecordingDeleter.swift` and `App/Voice/VoiceTagRenamer.swift`; Task 7 Step 3 edits the `#Predicate` in `App/Voice/InsightsModel.swift`. None of those files existed at the v2 baseline `090cdc4`. Every anchor in this plan was re-derived from the tree at `8dc20e8`, after the fix wave `ecd5fbf`, `3301165`, `da34031`, `595412f`, `8dc20e8`. Check before starting:
  ```bash
  cd /Users/asheslab/Documents/work/cat-voice
  ls App/Views/Voice/ManageVoiceTagsView.swift App/Views/Voice/InsightsView.swift \
     App/Voice/InsightsModel.swift App/Voice/RecordingDeleter.swift App/Voice/VoiceTagRenamer.swift
  grep -n 'NavigationLink("Voice tags")' App/Views/Settings/SettingsView.swift
  grep -n 'static func builtInID' App/Persistence/VoiceTagSeed.swift
  grep -c 'isBusy' App/Views/Voice/RecordView.swift App/Views/Voice/AskView.swift
  scripts/test-app.sh | tail -3
  ```
  Expected: all five files exist; the Settings link and `VoiceTagSeed.builtInID` print; `grep -c` prints a non-zero count for **both** voice views (4 and 4 on the tree today), which is the point of using `-c` per file rather than a `head`-truncated listing that never reaches the second file; and the app suite reports 70 tests with 0 failures (packages: 28 audio, 28 stats). If any file is missing or `builtInID` does not exist, stop: this plan builds on that work rather than repeating it.

  **Task 1 is already committed** (`219ae15`, which took the suite from 60 to 70 by adding `SupabasePackageLinkTests` and nine `SecretGuardTests`). Execution resumes at Task 2. An implementer reading this precondition for any later task should expect 70 or more, not 60: the number only grows as tasks land.
- **Do not re-create what Plan B already shipped.** `VoiceTagSeed.builtInID(kind:name:)` (UUID v5 over the RFC 4122 DNS namespace and `"kind:name"`), `VoiceTagSeed.seedIfNeeded(context:)` matching on id *and* name, `VoiceTagSeed.run(_:)` seeding on every launch with no UserDefaults guard, `RecordingDeleter.delete(_:context:mediaStore:)` and `VoiceTagRenamer.rename(tag:to:context:)` all exist. This plan calls them; it does not rewrite them. There is no `UUID.v5` extension and no `builtInNamespace` symbol in the tree, and this plan adds neither.
- Swift 5 language mode (`SWIFT_VERSION: "5.0"` in `project.yml`), iOS deployment target 17.0.
- The only third-party package in the app is `supabase-swift`, pinned `from: "2.55.2"` (the newest release on 2026-09-23, confirmed at https://github.com/supabase/supabase-swift/releases/tag/v2.55.2). The two local packages `AnimalVoiceAudio` and `AnimalVoiceStats` stay as they are.
- Supabase project ref: `ojzmtyapkaxxliuurssc`. Project URL: `https://ojzmtyapkaxxliuurssc.supabase.co`.
- Bundle id `com.ashlab.AnimalTracker`. Apple Developer team `A5S59B326M`.
- The anon key is public and is committed in `App/Config/Supabase.plist` (spec Addendum v7.1). The database password, any secret API key or legacy service-role key, and the Supabase personal access token never enter the repo; a pre-push guard enforces that. The guard matches secret **value shapes**, never the name of an environment variable, and it scans the whole tree including `docs/`.
- Every model that syncs (`Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`) has `@Attribute(.unique) var id: UUID`, `var createdAt: Date = Date()` and `var updatedAt: Date = Date()`. All four already carry `@Attribute(.unique) var id` on the branch, and `VoiceRecording`, `Vocalization` and `VoiceTag` already carry `updatedAt` (commit `66af968`); the only model this plan adds `updatedAt` to is `Animal`. Every stored property has a default or is optional. CloudKit stays off (`cloudKitDatabase: .none`).
- Server columns are snake_case mirrors of the model fields. Every table has `id uuid primary key`, `user_id uuid not null default auth.uid() references auth.users(id) on delete cascade`, `updated_at timestamptz not null default now()`, `server_updated_at timestamptz not null default now()`, `deleted_at timestamptz`.
- Row Level Security is enabled on every table, with select, insert, update and delete policies `to authenticated` keyed on `user_id = (select auth.uid())`, and `with check` on both insert and update.
- Tests are XCTest, run with `scripts/test-app.sh`, and never touch the live network. Every remote interaction in a test goes through `InMemoryRemoteStore`. Every test that touches an on-disk SwiftData store passes its own temporary `url:`.
- TDD per task: write the failing test, run it and see it fail, implement, run it and see it pass, commit.
- Commit messages end with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Plan A is implemented (`AnimalTrackerApp`, `RootTabView`, `SettingsView`, `PersistenceController`, `Seeds`, `KeychainStore`, `MediaStore` with `\.mediaStore`, `ManageAnimalsView`, `AnimalFormView`). Plan B tasks 13 to 18 and the fix wave after them are implemented (`VoiceRecording`, `Vocalization`, `VoiceTag`, `VoiceTagSeed` with `builtInID`, `TagPropagation`, `AnalysisService`, `RecordingDeleter`, `VoiceTagRenamer`, `AudioPlayer`, `VoiceTabView`, `RecordView`, `TagSheet`, `VoiceHistoryView`, `RecordingDetailView`, `VocalizationEditView`, `VocalizationPlayButton`, `AskView`, `InsightsModel`, `InsightsView`, `ManageVoiceTagsView`).

---

## Assumptions

Every supabase-swift name below was read from the source at tag `v2.55.2`, still the newest release on 2026-09-23 (https://github.com/supabase/supabase-swift/releases/tag/v2.55.2). File and line references are to that tag, so they can be re-checked. Nothing here is inferred from a prose guide alone.

**Package and client**

- Package `https://github.com/supabase/supabase-swift`, pinned `from: "2.55.2"`, which keeps SPM inside 2.x and guarantees every symbol below.
- `SupabaseClient(supabaseURL:supabaseKey:options:)` and the convenience `SupabaseClient(supabaseURL:supabaseKey:)`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Supabase/SupabaseClient.swift
- `SupabaseClientOptions(db:auth:global:functions:realtime:storage:)`, `SupabaseClientOptions.DatabaseOptions(schema:encoder:decoder:)`, `SupabaseClientOptions.AuthOptions(storage:redirectToURL:storageKey:flowType:encoder:decoder:autoRefreshToken:emitLocalSessionAsInitialSession:accessToken:)`. `AuthOptions.storage` is typed `any AuthLocalStorage` and is the first parameter of the designated init, which is the init this plan calls. It is not universally required: an Apple-only extension supplies a second `AuthOptions.init(redirectToURL:storageKey:flowType:encoder:decoder:autoRefreshToken:emitLocalSessionAsInitialSession:accessToken:)` with no `storage:` at all. The plan passes `storage:` explicitly, so it lands on the designated init either way. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Supabase/Types.swift#L85-L105
- `AuthOptions.storageKey` is the key the session is written under. `SessionStorage.key(_:)` resolves it as `configuration.storageKey ?? defaultStorageKey`, where that internal constant is `"supabase.auth.token"`, but `configuration.storageKey` is never nil on the path this app takes: `SupabaseClient.init` computes its own project-scoped default, `let defaultStorageKey = "sb-\(host.split(separator: ".")[0])-auth-token"`, and passes `options.auth.storageKey ?? defaultStorageKey` down to `AuthClient`. So the key this app would get if it passed nothing is `sb-ojzmtyapkaxxliuurssc-auth-token`, **not** `supabase.auth.token`. This plan passes an explicit `storageKey` anyway, so the app knows the exact keychain account its session occupies and `deleteAccount()` can remove it by name rather than hoping `signOut` did; the correction changes no code, only the sentence that described the default. Sources: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Supabase/SupabaseClient.swift, https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/SessionStorage.swift and https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/Constants.swift
- `nonisolated public var currentSession: Session?` is `sessionStorage.get()` and nothing else: there is no in-memory cache in front of it, so removing the keychain item makes `currentSession` nil on the very next read. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/AuthClient.swift

**Session storage location and accessibility** (finding 22)

- `AuthLocalStorage` is a three-method protocol: `store(key:value:) throws`, `retrieve(key:) throws -> Data?`, `remove(key:) throws`. It is declared `public protocol AuthLocalStorage: Sendable`, so every conformer must be `Sendable`. `KeychainSessionStorage` satisfies that implicitly because it is a struct whose only stored property is a `let String`, and it must stay that way: adding a cache, a mutable `var` or a class dependency to it turns the implicit conformance into a compile error. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Storage/AuthLocalStorage.swift#L15-L36
- `KeychainLocalStorage(service: String? = "supabase.gotrue.swift", accessGroup: String? = nil)` has **no accessibility parameter**, and the SDK's internal `Keychain` writes `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock` (not `...ThisDeviceOnly`). Sources: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Storage/KeychainLocalStorage.swift and https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/Keychain.swift
- Because the ruling asks for `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and the SDK type cannot express it, Task 3 ships `KeychainSessionStorage: AuthLocalStorage`, roughly thirty lines over `SecItem`, pinned to service `com.ashlab.AnimalTracker.auth` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `ThisDeviceOnly` means the session is excluded from encrypted iCloud and iTunes backups, so restoring a backup onto a second phone never carries a live session: the person signs in again. That is the intended behaviour, and `ThisDeviceOnly` is the binding half of the requirement. The `AfterFirstUnlock` half is deliberate rather than a slip from the stricter `WhenUnlocked`: a sync cycle can be running while the phone is locked (a background refresh, or the screen locking mid-push), and under `WhenUnlocked` the keychain read that refreshes the access token would fail with `errSecInteractionNotAllowed` and turn an ordinary lock into a sync failure. `AfterFirstUnlock` keeps the item unreadable until the person has unlocked once after boot, which is the property that matters, and readable for the rest of the session. Verification defect D-D10 records that this differs from the brief's `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on purpose.

**Sign-out scope** (finding 22)

- `public func signOut(scope: SignOutScope = .global) async throws` and `public enum SignOutScope: String, Sendable { case global, local, others }`. This plan always passes `scope: .local`, so signing out of this phone never kills the person's session on another device. Sources: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/AuthClient.swift and https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Types.swift
- `signOut` returns early without throwing when `currentSession?.accessToken` is nil, removes the local session before the network call, and swallows 401, 403 and 404 from `/logout`. So after `delete_my_account()` has already killed the auth user, `signOut(scope: .local)` normally still clears the keychain. "Normally" is not good enough for an irreversible operation, which is why `deleteAccount()` removes the session item by key itself and then asserts `currentSession == nil`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/AuthClient.swift

**Session and sign-in**

- `public var session: Session { get async throws }` refreshes if needed and throws `AuthError.sessionMissing` when there is none; `nonisolated public var currentSession: Session?` reads storage without validating and without a network call. `restoreSession()` reads `currentSession` first for exactly that reason. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/AuthClient.swift
- `public func signInWithIdToken(credentials: OpenIDConnectCredentials) async throws -> Session`, with `OpenIDConnectCredentials(provider:idToken:accessToken:nonce:gotrueMetaSecurity:)`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Types.swift
- `Session.user` is a `User` whose `id` is a `UUID` and whose `email` is a `String?`. No `UUID(uuidString:)` wrapping is needed. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Types.swift

**PostgREST**

- `from(_ table: String)`, then `select(_ columns: String = "*", head: Bool = false, count: CountOption? = nil)` and `upsert(_ values: some Encodable, onConflict: String? = nil, returning: PostgrestReturningOptions = .representation, count: CountOption? = nil, ignoreDuplicates: Bool = false) throws`. `upsert` is throwing, so every call site is `try await`. This plan passes `returning: .minimal`, so no response body is decoded. Sources: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/PostgREST/PostgrestQueryBuilder.swift and https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/PostgREST/Types.swift
- `gte(_ column: String, value: any PostgrestFilterValue)`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/PostgREST/PostgrestFilterBuilder.swift
- `order(_ column: String, ascending: Bool = true, nullsFirst: Bool = false, referencedTable: String? = nil)`, `limit(_ count: Int, referencedTable: String? = nil)` and `range(from: Int, to: Int, referencedTable: String? = nil)` all exist and are chainable. The "drop `.order`" fallback from the previous revision is gone: `.order` is confirmed present, and the pull cursor depends on it. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/PostgREST/PostgrestTransformBuilder.swift
- `public func rpc(_ fn: String, count: CountOption? = nil) throws -> PostgrestFilterBuilder` is how `delete_my_account()` is called. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Supabase/SupabaseClient.swift

**Storage**

- `client.storage.from(_ id: String) -> StorageFileApi`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Storage/SupabaseStorage.swift
- `upload(_ path: String, data: Data, options: FileOptions = FileOptions())` takes the path **unlabelled** and the bytes as `data:`, not `file:`. `download(path: String, options: TransformOptions? = nil, query: [URLQueryItem]? = nil, cacheNonce: String? = nil) async throws -> Data`. `remove(paths: [String]) async throws -> [FileObject]`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Storage/StorageFileApi.swift
- `FileOptions(cacheControl:contentType:upsert:duplex:metadata:headers:)`; the overwrite flag is spelled `upsert`. Source: https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Storage/Types.swift

**Apple**

- `ASAuthorizationAppleIDProvider.credentialRevokedNotification` (https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/credentialrevokednotification) and `getCredentialState(forUserID:completion:)` (https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/getcredentialstate(foruserid:completion:)) are how a revoked Apple ID is noticed. The completion-based call is wrapped in `withCheckedContinuation` rather than relying on a concurrency-renamed variant.
- Supabase-side configuration is done in the dashboard by Ash, not by this plan: the Apple provider **is enabled** on project `ojzmtyapkaxxliuurssc` and `com.ashlab.AnimalTracker` is listed under Client IDs. Native sign-in needs no OAuth secret. This is no longer left as an assumption the first device sign-in discovers: Task 12 Step 0 is a precondition that reads `external_apple_enabled` back from the Management API before anything tries to sign in (verification defect D-D9). Source: https://supabase.com/docs/guides/auth/social-login/auth-apple

**Nonce fallback policy** (findings 9 and 22)

- Apple receives `sha256(rawNonce)`; Supabase receives the raw nonce and re-hashes it. The first encoding tried is lowercase hex. If Supabase answers "Nonces mismatch" (the hex versus base64url ambiguity reported at https://github.com/supabase/auth/issues/2378), `AuthService` flips a persisted `NonceEncoding` to base64url of the same digest and the person taps the button again. There is no third step: **dropping the nonce is not a build step.** It is an accepted replay risk that needs Ash's explicit written sign-off first, and it is recorded in the commit body if she gives it.

**Sync model** (finding 19)

- There is no `SyncOutbox` table. Spec Addendum v7.1 replaces it with watermarks plus tombstones. The property mapping from the superseded v7 sentence is: the outbox's *upsert* rows become `SyncState.pushedThrough[table]`, a per-table high-water mark over local `updatedAt`, so any row with `updatedAt > pushedThrough` is outstanding; the outbox's *delete* rows become `DeletedRecord(entity:recordID:deletedAt:audioFilename:pushed:)` in SwiftData, so any `DeletedRecord` with `pushed == false` is outstanding; the outbox's "survives app restarts" property is met because `SyncState` lives in `UserDefaults` and `DeletedRecord` lives in the store; the outbox's JSON payload is not needed because the row is rebuilt from the model at push time, which also means a row edited three times is pushed once.

**Pagination limit** (finding 22)

- Pulls request `limit: 500` per page and loop until a page comes back **empty**, not until a short page. A server or a test double is free to cap a page below the requested limit, so a short page is not proof of exhaustion; only an empty page is. The cost is one extra round trip per table per sync that finds changes.
- The cursor is `(server_updated_at, offset)`: rows are ordered by `server_updated_at` then `id` (a total order), filtered `gte` the cursor, and `range(from: offset, to: offset + limit - 1)` walks that ordered result. `server_updated_at` is set by a `before insert or update` trigger to `now()`, so a row that changes always moves to a *newer* timestamp and offset paging inside one cycle is stable. Across cycles the offset is not trusted; see "Pull cursor resume" below.

**Clock-skew handling** (finding 22)

- Push watermarks are clamped: `pushedThrough` never advances past the device's own `now()`, so one row accidentally dated in 2030 cannot suppress every later push. `SyncClock.clamp(_:notAfter:)` does this.
- The pull cursor is deliberately **not** clamped. `server_updated_at` is the server's clock, and clamping it to a device clock that is behind the server would stall pulls forever. The server clock is the authority for that column and the `gte` filter is evaluated against it.

**Other**

- Date wire format is ISO 8601 with fractional seconds, both ways. `SyncCoding.encoder` and `SyncCoding.decoder` are handed to the client as `DatabaseOptions(encoder:decoder:)`, so the values the tests exercise are literally the values that go on the wire. The decoder accepts a timestamp with or without fractional seconds, because Postgres omits them when they are zero.
- Foreign keys between synced tables are deliberately omitted (`animal_id`, `recording_id` are plain `uuid` columns). Sync pushes tables in an arbitrary order, so a real FK would reject a child pushed before its parent. The models carry the raw parent id as the source of truth so an unresolved SwiftData relationship never pushes a null parent.
- Tombstones are retained locally forever once written, flipped from `pushed == false` to `pushed == true` rather than deleted. A `DeletedRecord` is an id, a table name, a date, a flag and an optional filename, so a thousand deletes is a few tens of kilobytes.
- The cost of that retention is recorded here rather than optimised away (verification defect C-D8). `Tombstone.record` runs a `FetchDescriptor<DeletedRecord>` per call, so re-analysing a recording with n sounds does n fetches interleaved with n deletes, and `SwiftDataLocalStore.tombstoneIndex(for:)` fetches every tombstone for a table on each `changed*` and each `apply(*)`. Both are correct and both are O(total tombstones). At the stated scale that is fine. It is written down because the later domains in the spec (buttons, feed, poop, health, check-ins) multiply the tombstone table, and the fix when it is needed is known: a batch `Tombstone` lookup that fetches a table's tombstones once, and passing the already-built `tombstoneIndex` into `apply(*)` instead of rebuilding it.
- `PersistenceController` on the branch already has `makeContainerWithRecovery(url:) -> (container: ModelContainer, recovered: Bool)` (non-throwing, tuple), `destroy(url:)`, `storeURL`, private `sidecars(of:)` and `makeContainer(inMemory:url:)`. This plan uses those exact shapes and adds only `storeURLs` and `destroyIncludingRecoveredCopies(url:)`.

**PostgREST bulk upsert key uniformity**

- PostgREST rejects a bulk insert or upsert whose objects do not all carry the same set of keys, with `PGRST102` ("All object keys must match"). Source: https://docs.postgrest.org/en/v12/references/errors.html
- Swift's synthesized `Codable` encodes an `Optional` property with `encodeIfPresent`, so a nil is omitted rather than sent as JSON null. Left alone, that makes every real push a lottery: one batch mixes a tombstone (`deleted_at` set, `animal_id` nil) with an ordinary row (`deleted_at` nil, `animal_id` set), the two objects have different key sets, and PostgREST refuses the whole batch. `InMemoryRemoteStore` never sees JSON, so it would stay green while every request against the real server failed.
- Therefore **every row struct in Task 8 writes an explicit `encode(to:)`** that emits every column key on every row, with nil encoded as JSON null, and never emits `server_updated_at`. `encode(_:forKey:)` on an `Optional` calls `encodeNil()`, which is the JSON null; `encodeIfPresent` is not used anywhere in `SyncRows.swift`. The decoder side stays synthesized, so a pull that carries `server_updated_at` still decodes it and a column the server omits still decodes to nil.
- Because `deleted_at` is now always sent, and is sent as null on an ordinary edit, the server-side guard is what keeps a delete permanent: `sync_row_guard()` does `new.deleted_at := coalesce(old.deleted_at, new.deleted_at)`, so a null from a device that had not heard about the delete cannot clear it. The device-side equivalent is the retained tombstone. Neither side relies on a key being absent.
- `server_updated_at` is never emitted, so the column stays entirely the trigger's, and a push can never argue with it.

**Tombstones versus local edits** (ruled behaviour)

- Last-write-wins is evaluated per side, and the two sides can legitimately disagree. When a local edit is newer than a remote tombstone, the tombstone loses locally: the row stays on this phone, its audio file is kept, and no local tombstone is written. The server keeps its tombstone, because `deleted_at` is sticky there. The next push sends the edit, the guard keeps `deleted_at`, and the row is on the server as a tombstone carrying the newer `updated_at`. The next pull then brings that tombstone back with a timestamp that now wins, and the row goes locally too. The divergence is one sync cycle long and it always converges on "deleted", which is the safe direction: an undelete is a decision a person makes, not one a race makes.
- A pulled `Animal` tombstone cascades locally. `SwiftDataLocalStore.apply(animals:)` deletes that animal's recordings and their vocalizations, deletes the recordings' audio files, and writes a pulled tombstone for each of those rows. Without the cascade the recordings would survive as orphans carrying a live `animalID` that resolves to nothing, and their audio files would never be reclaimed. The cascade's tombstones are marked pushed, so they are never sent back and cannot resurrect anything; the server's own per-row tombstones arrive on this or a later pull and find the work already done.

**SwiftData inverse relationships**

- `VoiceRecording.vocalizations` declares `inverse: \Vocalization.recordingLink`, so SwiftData can write `recordingLink` directly when a vocalization is attached from the parent side, without going through the computed `recording` door that also writes `recordingID`. `changedVocalizations(after:)` therefore pushes `recordingID ?? recordingLink?.id`, so a row whose raw id was set behind the door still names its parent. `VoiceRecording.animalID` needs no such fallback: `Animal` declares no recordings relationship, so nothing can write `animalLink` except the `animal` door.

**Pull cursor resume** (verification defect B-D10)

- The stored `(server_updated_at, offset)` pair is not safe as a cross-cycle resume point on its own. If a row inside the cursor's timestamp bucket is updated between two cycles, the trigger moves it to a newer `server_updated_at`, it leaves the bucket, every later row in the bucket shifts down one place, and an offset that was right last cycle now skips a row that was never seen.
- So every cycle restarts each table at `offset = 0` against the stored cursor and dedupes by id within the bucket. Re-reading the bucket costs at most one extra page per table per cycle, and a row that is applied twice is a no-op: `apply` merges on `id` and last-write-wins refuses a remote row that is not strictly newer than the local one. The persisted offset is still written, because it is what a cycle interrupted mid-bucket reports and what Settings and the tests read, but it is never used as a starting offset.

---

## Changes since v3

**This is v4.** It answers the two independent verification passes over v3: Verifier C
(`.superpowers/sdd/planH-v3-verification-C.md`, C-D1 to C-D10, correctness of the code in the plan)
and Verifier D (`.superpowers/sdd/planH-v3-verification-D.md`, D-D1 to D-D23, security, data safety
and executability). Every HIGH and MEDIUM from both is fixed, plus the cheap LOWs. The test total
moves from a miscounted 235/236 to **247**.

| Defect | Sev | What changed |
| --- | --- | --- |
| D-D1, D-D2, D-D23 | HIGH, MEDIUM, LOW | `scripts/check-secrets.sh` and `SecretPatterns.swift` now match secret **value shapes** only: `sb_secret_…`, `sbp_` plus forty hex, a *quoted* `service_role`, a JWT whose payload encodes `service_role`, and a Postgres URL carrying a password. An environment variable name is never a match, so the README sections in Task 1 Step 9 and Task 6 Step 9 no longer break every push. The `':!docs'` exclusion is **gone**, so `docs/` is scanned like the rest of the tree; `SecretGuardTests` assembles its fixtures at runtime so this document stays clean under it. Both README steps end by re-running the guard. `SecretGuardTests` 6 cases to 9. |
| D-D6 | HIGH | `MediaStore` gains `removeAll()`, implemented on `FileMediaStore` and `InMemoryMediaStore`, and `AppStoreLifecycle.wipeStore()` calls it. A wipe no longer leaves the previous person's audio, photos and videos in `Documents/Media/`, which file sharing exposes in the Files app. `ContainerResetTests` drives a real `FileMediaStore` on a temporary root and asserts the directory is empty afterwards. |
| D-D7 | HIGH | "Sign out" is behind a confirmation. Confirming awaits one final push with a bounded timeout (`SyncCoordinating.pushBeforeSignOut(timeout:)`); if it fails or times out, a second confirmation names the number of records that will be lost before anything is wiped. The count is `UnsyncedCount.count(...)`, a pure helper with its own tests. |
| D-D8 | HIGH | `checkAppleCredentialState()` signs out **only** on `.revoked`. `.notFound`, `.transferred` and any error are logged and leave the session and the store untouched. An injectable `credentialStateProbe` makes all four outcomes testable; `AuthServiceTests` 18 cases to 22. |
| D-D12 | HIGH | `sync_row_guard()` clamps `new.updated_at := least(new.updated_at, now() + interval '5 minutes')` as its first statement, so one future-dated row cannot freeze itself server-side and then overwrite the corrected local copy. Mirrored in `InMemoryRemoteStore.merge`, asserted in `MigrationFileTests`, and driven end to end by a new `SyncEngineTests` case. No counted total in the migration tests shifts. |
| D-D18 | HIGH | Task 12's old Steps 8 and 9 are one step. The merge commit's message is fixed **before** anything is published, both test scripts and the build run on the merged tree, then there is a single `git push origin HEAD:main`. Nothing is amended after a push anywhere in the plan. |
| D-D9 | MEDIUM | Task 12 gains Step 0: a precondition that reads `external_apple_enabled` back from the Supabase Management API and expects `true`, with the token and the project ref taken only from the environment. The provider is already enabled; this stops a provider problem being mis-read as a nonce problem. |
| D-D15 | MEDIUM | `LocalStore.relinkOrphans()` runs once at the end of a pull cycle and attaches any child whose parent link is nil but whose parent id now resolves. Without it an unlinked vocalization is invisible to `sortedVocalizations`, so deleting its recording never tombstones it. New `LocalStoreTests` case: child pulled first, parent second, relationship present after the cycle. |
| D-D19, C-D3 | MEDIUM | Task 11 Step 11's four audit greps quote `--include='*.swift'` (unquoted, zsh aborts them and the pipelines still exit 0), run under `set -o pipefail`, and each ends in `test "$(...)" -eq N`. Two assert stable totals (6 and 9); two count violations, expected 0, because this task's own edits move the raw totals. |
| D-D20, C-D2 | MEDIUM | One total, stated once and derived: 60 baseline plus 187 added is **247**, in Task 12 Step 1 and in the self-review. |
| D-D21 | MEDIUM | Task 12 Step 5 says which device pushed the rows being compared and how to read the phone's container when Step 3 was skipped. An empty `ZANIMAL` is a skipped check, not a pass. |
| C-D1 | MEDIUM | Task 7 Step 3's `grep -rn "animal?.id" App/` expects **five** hits, listed one by one with what each is and why none of them changes. |
| C-D4 | MEDIUM | Every `.confirmationDialog` in Settings is attached to its own row view, never stacked on `Section("Account")`. Task 12 Step 6 asks the worker to confirm the dialogs actually present. |
| D-D10 | LOW | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is kept, with one sentence saying why: sync may run while the phone is locked, and `WhenUnlocked` would turn an ordinary lock into a sync failure. `ThisDeviceOnly` is the binding half. |
| D-D11, C-D10 | LOW | The Task 3 Interfaces line declares `SyncStatus … CaseIterable`, which `SyncStateTests` needs to compile. |
| D-D14 | LOW | Task 6 Step 9's README block uses a four-backtick outer fence, so the inner `bash` block no longer truncates it when copied. |
| D-D22 | LOW | Task 12 Step 6 item 4 checks `Documents/Media/` and `Application Support/` on the device after "Delete account", which is the check that would have caught D-D6. |
| C-D5 | LOW | `VoiceTagRenameTests` is 5 cases, not 4. |
| C-D6 | LOW | The Global Constraints `isBusy` precondition uses `grep -c` per file instead of a `head -4` that never reached the second file. |
| C-D7 | LOW | `SyncService` takes its `MediaResolver` by injection, so seven test services no longer repoint the process-wide `MediaResolver.shared` at their own doubles. |
| C-D8 | LOW | The O(total tombstones) cost of `Tombstone.record` and `tombstoneIndex(for:)` is recorded in Assumptions, with the known fix, rather than optimised now. |
| C-D9 | LOW | `ContainerResetTests` asserts no `.corrupt-` copies and that the store file is gone, instead of an empty directory a retained SQLite connection can repopulate. |

Deliberately not changed: D-D3 (`.superpowers/` untracked) is moot now that the patterns match
values rather than the word `service_role`, which is what those review files contain; D-D4, D-D5,
D-D13, D-D16 and D-D17 are LOW notes the reports themselves mark optional or fail-closed already.

Two further Assumptions corrections came from `.superpowers/sdd/planH-supabase-swift-api-check.md`
and are prose only: the storage key `SupabaseClient` would default to is `sb-<project-ref>-auth-token`,
not the internal `"supabase.auth.token"` (inert, because the plan pins one); `AuthOptions.storage`
is required only on the designated init; and `AuthLocalStorage` refines `Sendable`, so
`KeychainSessionStorage` has to stay a value type with immutable stored properties. Task 1 Step 1
also records that the placeholder key must not begin with `sb_`, because `SupabaseClient.init`
raises an XCTest issue for an unrecognised `sb_` subtype.

---

## Changes since v1 and v2

Two tables. The first maps the twenty-two findings in `.superpowers/sdd/planH-review-findings.md`, which v2 answered. The second maps the twenty-nine defects two independent verifiers raised against v2, in `.superpowers/sdd/planH-v2-verification.md`. What the reviewers judged correct is kept: the nonce implementation (64-character alphabet, SHA-256, hash to Apple and raw to Supabase), full RLS verb coverage, the private bucket, the `LocalStore`/`RemoteStore` split, secret hygiene, the supabase-swift v2.55.2 API names, the pagination arithmetic, the generation guard, and the UUID v5 derivation.

### v1 findings

| Finding | Resolved in |
| --- | --- |
| 1. Re-baseline on the real `PersistenceController`; wipe `.corrupt-*` copies; Plan B names verified against Plan B's text | Task 5 Step 3 (`storeURLs`, `destroyIncludingRecoveredCopies`, tuple `makeContainerWithRecovery`), Task 7 Steps 3 to 6 (Plan B model and seed names). Both verifiers marked this PARTIAL against v2; every anchor was re-derived from the tree at `090cdc4` for v3, and the anchors in files Plan B Task 18 creates are quoted from Plan B's own text (see Global Constraints) |
| 2. `ContainerResetTests` uses a temporary `url:` | Task 5 Step 1 |
| 3. Anon key committed; skip-worktree removed; guard greps for secret-key, personal-access-token, service-role and DB-password **value shapes**, not a bare `eyJ` | Task 1 Steps 4 to 6, Task 12 Step 7 |
| 4. Fail closed in Release with a `.misconfigured` blocking screen plus a Release-only build phase | Task 1 Step 3 (the `postCompileScripts` guard), Task 2 Step 5 (proving it fires), Task 4 Steps 3 and 4 (`.misconfigured`, `restoreSession`), Task 5 Step 5 (`RootGate.blocked`, `MisconfiguredView`) |
| 5. `storeOwnerID` persisted at session establishment, separate from watermarks; three reset conditions; `leaveOfflineMode()` discards; `signOut()` reordered | Task 3 Step 4 (`StoreOwner`, `StoreOwnerPolicy` under their own defaults key), Task 4 Step 4 (`establish`, `signOut`, `leaveOfflineMode`), Task 4 Step 1 (the test that asserted the opposite, rewritten) |
| 6. `SyncService` generation token and running task; `configure`/reset bump it; every await bails; no `SyncState` save for a stale generation; reset awaits cancellation; one ordered transition in `AuthService` | Task 4 Steps 3 and 4 (`StoreLifecycle`, `establish`), Task 10 Step 3 (`checkpoint()`), Task 11 Step 5 (`bumpGeneration`, `cancelSync`, `run`) |
| 7. `signOut(scope: .local)`, no `try?`, stay signed in on failure, assert `currentSession == nil`; pinned keychain service and accessibility | Task 3 Step 5 (`KeychainSessionStorage`), Task 4 Step 4 (`signOut`), Assumptions ("Session storage location and accessibility", "Sign-out scope") |
| 8. `restoreSession()` reads `currentSession` first; network failure keeps `.signedIn`; Apple credential revocation signs out | Task 4 Step 4 (`restoreSession`, `startWatchingAppleCredential`, `checkAppleCredentialState`), Task 11 Step 6 (checked again on scene activation), Task 12 Step 4 (device check) |
| 9. Nonce moved into `AuthService`, `beginSignIn() throws -> String`, `isWorking` on the service, `Nonce.random` throws, hex then base64url, no drop-the-nonce build step | Task 3 Step 3 (`Nonce`, `NonceEncoding`), Task 4 Step 4 (`beginSignIn`, `abortSignIn`, `isNonceMismatch`), Task 5 Step 6 (`SignInView`), Task 12 Step 3 (the sign-off rule) |
| 10. `to authenticated`, `(select auth.uid())`, `with check` on insert and update, `default auth.uid()`, `storage.foldername`, `file_size_limit`, `allowed_mime_types`, 16 + 4 policy assertions, storage ownership fallback | Task 6 Steps 3, 4 and 7 |
| 11. Server-side LWW trigger with sticky `deleted_at`, `server_updated_at` column and trigger, paged and ordered pulls, no drop-`.order` paragraph | Task 6 Step 3 (SQL), Task 8 Step 3 (`serverUpdatedAt`), Task 10 Step 3 (paging), Assumptions |
| 12. Account deletion, storage hygiene: `delete_my_account()` security definer, Settings "Delete account", `removeAudio` on a pushed recording tombstone, filename captured in `DeletedRecord` | Task 6 Step 3 (SQL plus grants), Task 4 Step 4 (`AuthService.deleteAccount`), Task 11 Step 7 (Settings button and dialog), Task 7 Step 4 (filename capture), Task 10 Step 3 (`removeAudio` after the tombstone upsert), Task 12 Step 6 (verified on the server) |
| 13. Pulled tombstones obey LWW, are retained as pushed tombstones, and `changed*` carries the existing `deleted_at` | Task 9 Step 4 (`apply`, `changed*`, `tombstoneIndex`) |
| 14. Tombstones cleared by exact id per table after that table's upsert; not filtered by the row watermark | Task 9 Step 4 (`pendingTombstones`, `markTombstonesPushed`), Task 10 Step 3 |
| 15. Raw `animalID` and `recordingID` on the models as the source of truth | Task 7 Step 3, Task 9 Step 4 |
| 16. `pendingAudioUploads()` returns metadata only; one file loaded at a time; cap 10 per cycle | Task 9 Step 4, Task 10 Step 3 |
| 17. `SyncState` saves guarded by the generation token; status sanitized to a category | Task 3 Step 4 (`SyncStatus`), Task 11 Step 5 |
| 18. Seven new engine tests (older tombstone loses, no resurrection, per-table tombstone survival, capped pagination, stale generation, missing parent, clock-skew clamp) | Task 10 Step 1, plus Task 11 Step 1 for the stale-generation save guard |
| 19. Outbox replaced by watermarks plus tombstones, with the property mapping | Assumptions, "Sync model" |
| 20. Deterministic built-in tag ids; the reset re-seeds unconditionally; reset and pull tests | Satisfied by the tree: Plan B's fix wave (`595412f`, `8dc20e8`) shipped `VoiceTagSeed.builtInID`, an id-and-name-matching `seedIfNeeded`, and a `run(_:)` with no UserDefaults guard. Task 7 Step 6 verifies that instead of rewriting it, Task 5 Step 4 just calls `Seeds.runAll`, and the one case Plan B could not cover, a pulled row merging onto the seeded row, is Task 9 Step 1 |
| 21. psql check that a pushed `updated_at` matches the device value to sub-second precision; no key on a `PlistBuddy` command line | Task 12 Step 5 (psql plus the SQLite comparison against the device store), Task 1 Step 4 (the key goes in through a heredoc, never on a command line) |
| 22. Assumptions record session storage and accessibility, sign-out scope, pagination limit, clock-skew handling and the nonce fallback policy | Assumptions |

### v2 verification defects

Verifier B (auth, ownership, engine, SQL, gating):

| Defect | Resolved in |
| --- | --- |
| B-D1 CRITICAL. PostgREST `PGRST102`: bulk upsert needs identical key sets, synthesized `Codable` omits nil optionals, and `SyncRowTests.testNilServerCursorAndNilDeletedAtAreOmittedFromAPush` locked the bug in | Task 8 Step 3 (an explicit `encode(to:)` on all four row structs, every column key, nil as JSON null, `server_updated_at` never emitted), Task 8 Step 1 (that test replaced by `testEveryRowInAMixedBatchEncodesTheSameKeySet`), Assumptions "PostgREST bulk upsert key uniformity" |
| B-D2 / A-D6 HIGH. `PredictionService.swift` also uses `$0.animal?.id == animalID` (line 31 after Plan B's fix wave, 19 at the v2 baseline) | Task 7 Step 3 (both `#Predicate` sites plus `InsightsModel.swift`, which Plan B Task 18 creates with the same predicate) |
| B-D3 HIGH. `storeIsEmpty()` failed open (`?? true`), and the attach relied on SwiftUI task ordering between two views | Task 4 Step 4 (`?? false`), Task 5 Step 5 (`RootView.task` attaches lifecycle and sync immediately before `restoreSession()`), Task 5 Step 7 (the App-level `.task` no longer touches `auth.lifecycle`), Task 4 Step 1 (`testAServiceWithNoLifecycleFailsClosedAndResetsTheStore`) |
| B-D4 / A-D2..A-D5 HIGH. Four stale view anchors: `TagSheet.addTag`, `TagSheet.save`, `RecordingDetailView` delete dialog, `RecordView.finish` | Task 11 Step 9, every block re-derived from the tree at `090cdc4`: the `if let existing ... else` form, the draft write-back at lines 116 to 120, dismiss-before-delete with the tombstone taken before the captures, and `inserted = recording` kept |
| B-D5 / A-D11 HIGH. Plan B Task 18 must land first | Global Constraints, with a `ls`/`grep` precondition check |
| B-D6 MEDIUM. `MigrationFileTests` counts inflated by comment text | Task 6 Step 1 (`migrationSQL()` drops every `--` comment line; 21 and 25 re-derived from the stripped SQL and confirmed against the file, plus `testTheHelperDropsCommentLines`) |
| B-D7 / A-D7 MEDIUM. Wrong epoch for 2026-09-19T12:00:00Z | Task 3 Step 1 (`1_789_819_200`, and `1_789_819_200.125` for the fractional case) |
| B-D8 / A-D9 MEDIUM. `AnalysisService.apply` deletes vocalizations without tombstones; the audit greps were too narrow | Task 11 Step 9 (tombstones plus `updatedAt` in `AnalysisService`), Task 11 Step 11 (greps widened to all of `App/` except `App/Sync`), Task 11 file map |
| B-D9 MEDIUM. `deleteAccount()` swallowed the sign-out failure | Task 4 Step 4 (an explicit `storageKey`, the session item removed by key, `currentSession` asserted nil before `.signedOut`) |
| B-D10 LOW. The `(server_updated_at, offset)` cursor can over-skip | Task 10 Step 3 (every cycle restarts the bucket at offset 0 and dedupes by id), Task 10 Step 1 (`testARowUpdatedBetweenCyclesDoesNotMakeThePullSkipItsNeighbour`), Assumptions "Pull cursor resume" |
| B-D11 LOW. Settings "Sign in" wiped the store for `.signedOut`, `.unknown` and `.misconfigured` | Task 5 Step 8 (those three states render text, never a wipe; only `.offline` offers the confirmed discard) |
| B-D12 LOW. SwiftData's inverse can set `recordingLink` without `recordingID` | Task 9 Step 4 (`recordingID ?? recordingLink?.id`), Assumptions "SwiftData inverse relationships" |
| B doc gap. A local edit beating a remote tombstone | Assumptions "Tombstones versus local edits" |

Verifier A (compile-level anchors, SQL, tests):

| Defect | Resolved in |
| --- | --- |
| A-D1 HIGH. Task 7 Step 3 anchored on `var id: UUID = UUID()` for three models that already have `@Attribute(.unique) id` and `updatedAt` | Task 7 Step 3, rewritten: only `Animal` gains `updatedAt`; `VoiceRecording` gains `audioUploadedAt`, `animalID`, `animalLink`; `Vocalization` gains `recordingID`, `recordingLink`; `VoiceTag` is untouched and drops out of the file list and the commit |
| A-D2 / A-D3 / A-D4 / A-D5 HIGH. The same four stale view anchors | Task 11 Step 9 (see B-D4) |
| A-D6 HIGH. `PredictionService.swift` predicate | Task 7 Step 3 (see B-D2) |
| A-D7 HIGH. Epoch constants | Task 3 Step 1 (see B-D7) |
| A-D8 HIGH. `RootGateTests.testEveryStateIsCovered` asserted 4 screens | Task 5 Step 1 (5, with the five screens named so a miscount is readable) |
| A-D9 MEDIUM-HIGH. Re-analysis tombstones; `AnalysisService.swift` missing from the Task 11 file map | Task 11 file map and Step 9 (see B-D8) |
| A-D10 MEDIUM. The `AskView` correction callback, lines 49 to 51 at the v2 baseline `090cdc4` | Task 11 Step 9 (stamps `updatedAt`, then `requestSync()`). At `8dc20e8` the same callback is lines 57 to 61, which is the anchor the step actually quotes; the number above is kept only to identify the v2 defect |
| A-D11. Plan B Task 18 gate | Global Constraints (see B-D5) |
| A-D12 LOW. Row round-trip tests compared `Date`s exactly | Task 8 Step 1 (struct-equality round trips use whole-second moments; the millisecond behaviour is asserted separately with `accuracy`) |
| A-D13 LOW. `testAnUnconfiguredServiceNeverSignsAnyoneIn` could not fail | Task 4 Step 1, replaced by `testAnUnconfiguredServiceRefusesToDeleteAnAccount`, which drives a code path and asserts the lifecycle is untouched |
| A-D14 LOW. `testASeededTagAndAPulledTagWithTheSameIdAreOneRow` exercised no pull code | Moved out of Task 7 into Task 9 Step 1 as `testAPulledBuiltInTagMergesOntoTheSeededRow`, which calls `SwiftDataLocalStore.apply(tags:)` with a `VoiceTagRow` carrying `VoiceTagSeed.builtInID(...)` |
| A-D15 LOW. `SyncService` left `status == .syncing` after a cancel | Task 11 Step 5 (`cancelSync()` resets a `.syncing` status to `.cancelled`), Task 11 Step 1 (`testCancellingASyncLeavesAReadableStatus`) |
| A-D16 LOW. The Release guard check could be preempted by provisioning | Task 2 Step 5 (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`) |
| A-D17 INFO. A pulled `Animal` tombstone orphaned its recordings | Task 9 Step 4 (`cascadeDelete`), Task 9 Step 1 (`testAPulledAnimalTombstoneTakesItsRecordingsAndAudioWithIt`), Assumptions "Tombstones versus local edits" |

---

## File map

**New, auth:**
- `App/Config/Supabase.plist`: project URL plus the committed anon key.
- `App/Config/SupabaseConfig.swift`: reads that plist, returns nil for the placeholder.
- `App/Auth/Nonce.swift`: throwing random nonce, SHA-256 as hex or base64url.
- `App/Auth/KeychainSessionStorage.swift`: `AuthLocalStorage` over `SecItem`, pinned service and accessibility.
- `App/Auth/AuthService.swift`: `AuthState`, `AuthError`, `StoreLifecycle`, `AuthService`.
- `App/Views/Auth/SignInView.swift`: Sign in with Apple button and the DEBUG offline button.
- `App/Views/Auth/RootView.swift`: `RootScreen`, `RootGate`, `RootView`, `OfflineBanner`, `MisconfiguredView`.
- `App/AnimalTracker.entitlements`: generated by XcodeGen from `project.yml`.

**New, sync:**
- `App/Models/DeletedRecord.swift`: local tombstone model plus the `Tombstone` helper.
- `App/Sync/SyncState.swift`: `SyncTable`, `ServerFunctions`, `SyncStatus`, `SyncCancelled`, `SyncClock`, `SyncState`, `StoreOwner`, `StoreOwnerPolicy` (all UserDefaults-backed where persisted).
- `App/Sync/SyncCoding.swift`: the ISO 8601 encoder and decoder the client itself uses.
- `App/Sync/SecretPatterns.swift`: the Swift twin of the pre-push secret guard.
- `App/Sync/SyncRows.swift`: `RemoteAudioPath` and the four row structs.
- `App/Sync/RemoteStore.swift`: the `RemoteStore` protocol and `InMemoryRemoteStore`.
- `App/Sync/SupabaseRemoteStore.swift`: the PostgREST and Storage implementation.
- `App/Sync/LocalStore.swift`: `LocalStore`, `DeletedRecordInfo`, `PendingAudioRef`, `SwiftDataLocalStore`.
- `App/Sync/SyncEngine.swift`: push, pull, paging, tombstones, last-write-wins, audio upload.
- `App/Sync/SyncService.swift`: main-actor driver, generation token, debounce, published status.
- `App/Sync/MediaResolver.swift`: on-demand audio download for playback.
- `App/Persistence/AppStoreLifecycle.swift`: the concrete `StoreLifecycle` the app installs on `AuthService`.

**New, server and tooling:**
- `supabase/config.toml`
- `supabase/migrations/20260919120000_voice_milestone.sql`
- `scripts/check-secrets.sh`
- `.githooks/pre-push`

**Modified:**
- `project.yml`: package, product dependency, entitlements, `DEVELOPMENT_TEAM`, plist resource, Release config guard, migration resource in the test target.
- `App/AnimalTrackerApp.swift`: auth object, replaceable container, and the one scene-phase handler. All auth wiring lives in `RootView`'s `.task`, next to the `restoreSession()` it has to precede.
- `App/Persistence/PersistenceController.swift`: `DeletedRecord` added to `modelTypes`; `storeURLs`; `destroyIncludingRecoveredCopies(url:)`.
- `App/Models/Animal.swift`: `updatedAt`. `App/Models/VoiceRecording.swift`: `updatedAt` is already there; adds `audioUploadedAt`, `animalID`, `animalLink` and the computed `animal` door. `App/Models/Vocalization.swift`: adds `recordingID`, `recordingLink` and the computed `recording` door. `App/Models/VoiceTag.swift` is **not** modified; it already has everything this plan needs.
- `App/Persistence/AnimalDeletionPolicy.swift`, `App/Voice/PredictionService.swift`, `App/Voice/InsightsModel.swift`: the three `#Predicate`s that reach `animal?.id` move to the raw `animalID`.
- `App/Voice/AnalysisService.swift`: re-analysis writes tombstones for the vocalizations it deletes, and stamps `updatedAt` on the recording it rewrites.
- `App/Voice/RecordingDeleter.swift`: writes the recording's and its sounds' tombstones before the row goes, capturing the audio filename.
- `App/Voice/VoiceTagRenamer.swift`: stamps `updatedAt` on the tag and on every recording and sound whose label it migrates.
- `App/Media/MediaStore.swift`, `App/Media/FileMediaStore.swift`: `write(_:as:)`.
- `App/Views/Settings/SettingsView.swift`: Account section with sign out, sync status and account deletion.
- `App/Views/Animals/AnimalFormView.swift`, `App/Views/Animals/ManageAnimalsView.swift`, `App/Views/Voice/RecordView.swift`, `App/Views/Voice/TagSheet.swift`, `App/Views/Voice/RecordingDetailView.swift`, `App/Views/Voice/VocalizationEditView.swift`, `App/Views/Voice/AskView.swift`, `App/Views/Voice/ManageVoiceTagsView.swift`: stamp `updatedAt`, write tombstones, request a sync. `App/Views/Voice/VoiceHistoryView.swift` needs no change: its delete already routes through `RecordingDeleter`.

**New tests:**
- `AppTests/SupabasePackageLinkTests.swift`, `AppTests/SupabaseConfigTests.swift`, `AppTests/NonceTests.swift`, `AppTests/SyncStateTests.swift`, `AppTests/KeychainSessionStorageTests.swift`, `AppTests/AuthServiceTests.swift`, `AppTests/RootGateTests.swift`, `AppTests/ContainerResetTests.swift`, `AppTests/MigrationFileTests.swift`, `AppTests/SyncFieldTests.swift`, `AppTests/SyncRowTests.swift`, `AppTests/LocalStoreTests.swift`, `AppTests/SyncEngineTests.swift`, `AppTests/SyncServiceTests.swift`, `AppTests/MediaResolverTests.swift`, `AppTests/SyncCodingTests.swift`, `AppTests/SecretGuardTests.swift`.

---

### Task 1: XcodeGen wiring, the committed anon key, and the secret guard

**Files:**
- Modify: `project.yml` (packages, settings.base, the `AnimalTracker` target's sources, entitlements, build phase and dependencies, the `AnimalTrackerTests` target's dependencies)
- Create: `App/Config/Supabase.plist`
- Create: `App/Sync/SecretPatterns.swift`
- Create: `scripts/check-secrets.sh`
- Create: `.githooks/pre-push`
- Create: `AppTests/SupabasePackageLinkTests.swift`
- Create: `AppTests/SecretGuardTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the `Supabase` module is importable from both `App/` and `AppTests/`; `SupabaseClient(supabaseURL:supabaseKey:)` is available; the app target carries `com.apple.developer.applesignin = [Default]` and `DEVELOPMENT_TEAM = A5S59B326M`; `App/Config/Supabase.plist` is copied into the app bundle as a resource; `supabase/migrations/*.sql` is copied into the test bundle as a resource; `scripts/check-secrets.sh` exits non-zero when a real secret is in the tree.

- [ ] **Step 1: Write the failing tests**

The first test proves the package is linked and the umbrella product exposes the type everything else is built on. Constructing a `SupabaseClient` does no I/O, so it makes no network call.

Keep the placeholder key spelled `"anon-key-not-real"`. `SupabaseClient.init` inspects the key and reports an XCTest issue for any key that starts with `sb_` but is not a recognised subtype, so a placeholder spelled `sb_anon_...` would fail this test for a reason that has nothing to do with linking. A key with no `sb_` prefix is never inspected.

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

The second test is the secret guard's own unit test. It exercises the patterns against strings rather than shelling out, so it runs in the simulator and cannot be skipped by a missing git.

Create `AppTests/SecretGuardTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

/// The same patterns `scripts/check-secrets.sh` greps for. Kept in Swift so a change to one side
/// without the other fails a test instead of silently weakening the guard.
///
/// Every fixture is assembled from fragments at runtime. That is not decoration: with the
/// ':!docs' hole closed (verification defect D-D2) the guard scans `docs/`, and the plan document
/// quotes this file verbatim. A literal secret-shaped string here would become a literal
/// secret-shaped string in `docs/superpowers/plans/`, which is not on the exclusion list, and the
/// guard would fail on the repo's own planning notes. Splitting each fixture keeps the assembled
/// VALUE under test while leaving no matchable text in either file.
final class SecretGuardTests: XCTestCase {
    private func matches(_ text: String) -> Bool {
        SecretPatterns.all.contains { pattern in
            text.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    private func joined(_ parts: String...) -> String { parts.joined() }

    func testCatchesASecretApiKey() {
        XCTAssertTrue(matches(joined("SUPABASE_KEY=sb", "_secret", "_abcdef0123456789")))
    }

    /// A personal access token is caught by its VALUE shape, sbp underscore plus forty hex.
    func testCatchesAPersonalAccessTokenValue() {
        XCTAssertTrue(matches(joined("sbp", "_", "0123456789abcdef0123456789abcdef0123456789")))
    }

    func testCatchesAQuotedServiceRoleValue() {
        XCTAssertTrue(matches(joined("\"role\": \"service", "_role\"")))
    }

    /// A legacy service-role key is a JWT whose payload encodes the role claim. The payload here
    /// is base64url of a Supabase payload whose role claim is the service role, that is
    /// {"iss":"supabase","ref":"ojzmtyapkaxxliuurssc","role": the service role, ...},
    /// split across the base64 needle the pattern looks for.
    func testCatchesAServiceRoleJwt() {
        let header = joined("eyJ", "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        let payload = joined("eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9qem10eWFwa2F4eGxpdXVyc3Nj",
                             "Iiwicm9sZSI6InNlcnZpY2", "Vfcm9sZSIsImlhdCI6MTc4OTgxOTIwMH0")
        XCTAssertTrue(matches("\(header).\(payload).signature"))
    }

    func testCatchesAPostgresUrlWithAPassword() {
        XCTAssertTrue(matches(joined("postgresql://postgres:", "hunter2", "@db.example.supabase.co:5432/postgres")))
    }

    /// The anon key is public and is committed on purpose (spec Addendum v7.1), so a JWT-looking
    /// string must not trip the guard. This is the real anon payload shape, role: anon.
    func testDoesNotCatchTheAnonJwt() {
        let header = joined("eyJ", "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        let payload = joined("eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9qem10eWFwa2F4eGxpdXVyc3Nj",
                             "Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4MTkyMDB9")
        XCTAssertFalse(matches("\(header).\(payload).signature"))
    }

    /// The NAME of the environment variable is not a secret. It appears in the README, in this
    /// plan and in every shell snippet that exports it, and matching it would block every push
    /// (verification defects D-D1 and D-D23).
    func testDoesNotCatchTheAccessTokenVariableName() {
        XCTAssertFalse(matches("read -rs SUPABASE_ACCESS_TOKEN && export SUPABASE_ACCESS_TOKEN"))
    }

    /// Nor is the bare phrase. service underscore role is a Postgres role name that appears
    /// unquoted in every RLS discussion, including this repo's own migration and docs.
    func testDoesNotCatchTheBareServiceRoleWord() {
        XCTAssertFalse(matches(joined("revoke all on function public.delete_my_account() from service", "_role")))
    }

    func testDoesNotCatchOrdinaryProse() {
        XCTAssertFalse(matches("The anon key is public and lives in App/Config/Supabase.plist."))
    }
}
```

Nine cases. Four are negative, and the three new negatives are the ones that matter: they pin the
rule that the guard describes secret **values**, never the name of a variable or of a Postgres role.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `no such module 'Supabase'` for `AppTests/SupabasePackageLinkTests.swift` and `cannot find 'SecretPatterns' in scope` for `AppTests/SecretGuardTests.swift`.

- [ ] **Step 3: Add the package, the product, the entitlement, the team, the resources and the Release guard**

Replace the whole of `project.yml` with this. The changes against the current file are: the `Supabase` entry under `packages`, `DEVELOPMENT_TEAM` set to the real team, the split `sources` list that copies `App/Config/Supabase.plist` as a resource, the `entitlements` block, the `postCompileScripts` Release guard, the `Supabase` product dependency on both targets, and the migration resource on the test target.

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
    from: 2.55.2
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
    postCompileScripts:
      - name: Fail a Release build with no anon key
        basedOnDependencyAnalysis: false
        script: |
          if [ "$CONFIGURATION" = "Release" ]; then
            KEY=$(/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" "$SRCROOT/App/Config/Supabase.plist" 2>/dev/null || echo "")
            case "$KEY" in
              ""|REPLACE_WITH_ANON_KEY)
                echo "error: Release build with no Supabase anon key in App/Config/Supabase.plist"
                exit 1
                ;;
            esac
          fi
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

`optional: true` on the migrations path lets `xcodegen generate` succeed before Task 6 creates that folder.

- [ ] **Step 4: Create the config plist with the real anon key**

Spec Addendum v7.1: the anon key is public and is committed. It is a JWT whose only claim is `role: anon`, and the whole security model is RLS on top of it, so publishing it costs nothing. Create the file with the placeholder first, then substitute the real value with a heredoc so the key never appears on a command line or in shell history.

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

Then substitute the real key. Ash pastes it at the prompt; `read -rs` keeps it off the screen, and the heredoc keeps it out of `ps` output and out of shell history, which is why `PlistBuddy -c "Set :SupabaseAnonKey $KEY"` is not used:

```bash
cd /Users/asheslab/Documents/work/cat-voice
printf 'Paste the Supabase anon key: '
read -rs ANON_KEY
printf '\n'
/usr/libexec/PlistBuddy "App/Config/Supabase.plist" <<EOF
Set :SupabaseAnonKey ${ANON_KEY}
Save
EOF
unset ANON_KEY
/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" App/Config/Supabase.plist | cut -c1-12
```
Expected: the last command prints the first twelve characters of a JWT, which for a Supabase anon key is `eyJhbGciOiJI`. If it prints `REPLACE_WITH` the substitution did not happen; re-run.

The key is committed. There is no `git update-index --skip-worktree` anywhere in this plan, and the previous revision's instructions to add and remove it are gone.

- [ ] **Step 5: Write the secret guard and its Swift twin**

The guard matches **secret value shapes only**. It never matches the *name* of an environment
variable: `SUPABASE_ACCESS_TOKEN` is a variable name, not a secret, it appears in the README and in
this plan as prose, and a guard that fires on it would block every push in the repo for no security
gain (verification defects D-D1 and D-D23). What it does match is the token's value shape,
`sbp_` followed by forty hex characters. Likewise `service_role` on its own is an English phrase and
a Postgres role name that appears in every RLS discussion; what is dangerous is a *quoted*
`service_role` value or a JWT whose payload carries it, and those are what the patterns describe.
Because every pattern now describes a value rather than a word, **the `:!docs` exclusion is gone**:
`docs/` is scanned like the rest of the tree, which closes the hole D-D2 named (a plan or a spec is
exactly the kind of file that gets a connection string pasted into it). Only the three files that
have to contain the patterns verbatim are excluded.

That cuts both ways, and it is worth one sentence because it is easy to trip over later: with
`docs/` in scope, prose anywhere in the repo must not write the role name **between quote
characters**, because the role name wrapped in a double or single quote is exactly the value shape
the third pattern describes. Write it bare, in backticks, or as "the service-role claim". Note that
a sentence demonstrating the bad form by quoting it fails the guard too. This plan and its test
fixtures are
written that way on purpose; after any edit to a document that discusses the guard, re-run
`scripts/check-secrets.sh` rather than assuming.

Create `scripts/check-secrets.sh`:
```bash
#!/usr/bin/env bash
# Refuses to let a real secret reach the remote. The anon key is public and is committed on
# purpose (spec Addendum v7.1), so a JWT-looking string is NOT a finding here: only a JWT whose
# payload actually encodes the service-role claim is. Environment variable NAMES are never a finding;
# only the value shapes below are.
set -uo pipefail
cd "$(dirname "$0")/.."

# The three alternatives in the JWT pattern are base64url of the service-role claim at each of the three
# byte alignments a payload can put it at, so the claim is caught wherever it sits in the payload.
PATTERNS=(
  'sb_secret_[A-Za-z0-9_-]{8,}'
  'sbp_[0-9a-f]{40}'
  "[\"']service_role[\"']"
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|cnZpY2Vfcm9s|ZXJ2aWNlX3Jv)[A-Za-z0-9_-]*\.'
  'postgres(ql)?://[^[:space:]/]+:[^[:space:]@]+@'
)

found=0
for pattern in "${PATTERNS[@]}"; do
  if git grep -nIE "$pattern" -- . ':!scripts/check-secrets.sh' ':!AppTests/SecretGuardTests.swift' ':!App/Sync/SecretPatterns.swift'; then
    echo "error: the pattern '$pattern' matched above; that looks like a real secret"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "Refusing to push. Remove the secret, rewrite the commit that introduced it, then push again."
  exit 1
fi

echo "check-secrets: clean"
```

Create `.githooks/pre-push`:
```bash
#!/usr/bin/env bash
set -euo pipefail
exec "$(git rev-parse --show-toplevel)/scripts/check-secrets.sh"
```

Make both executable and point git at the hooks directory:
```bash
cd /Users/asheslab/Documents/work/cat-voice
chmod +x scripts/check-secrets.sh .githooks/pre-push
git config core.hooksPath .githooks
git config --get core.hooksPath
```
Expected: the last command prints `.githooks`.

Create `App/Sync/SecretPatterns.swift`, the Swift twin the test uses:
```swift
import Foundation

/// The regular expressions `scripts/check-secrets.sh` greps for, so `SecretGuardTests` can prove
/// they behave. Every entry describes a secret VALUE, never the name of an environment variable
/// or a Postgres role: a guard that flags `SUPABASE_ACCESS_TOKEN` or a bare `service_role` fires
/// on this repo's own README and docs and gets turned off within a week. A plain JWT is not a
/// finding either, because the anon key is public and committed (spec Addendum v7.1); only a JWT
/// whose payload encodes the service-role claim is. The three alternatives in that pattern are
/// base64url of that claim at each of the three byte alignments a payload can put it at.
enum SecretPatterns {
    static let all: [String] = [
        "sb_secret_[A-Za-z0-9_-]{8,}",
        "sbp_[0-9a-f]{40}",
        "[\"']service_role[\"']",
        "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*(c2VydmljZV9yb2xl|cnZpY2Vfcm9s|ZXJ2aWNlX3Jv)[A-Za-z0-9_-]*\\.",
        "postgres(ql)?://[^[:space:]/]+:[^[:space:]@]+@",
    ]
}
```

The two sides must stay character-for-character equivalent apart from Swift's backslash escaping,
which is what `SecretGuardTests` exists to prove. If a pattern is added to one, add it to the other
in the same commit.

- [ ] **Step 6: Regenerate, resolve the package, and run the guard**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
xcodegen generate
xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker -resolvePackageDependencies 2>&1 | tail -5
scripts/check-secrets.sh
```
Expected: resolution succeeds and prints a `supabase-swift` version of `2.55.2` or a later `2.55.y`. Record the resolved version; Task 12 quotes it in the commit body for the final push. `scripts/check-secrets.sh` prints `check-secrets: clean`.

- [ ] **Step 7: Run the tests to verify they pass, and verify the simulator build still signs**

Run: `scripts/test-app.sh`
Expected: `Executed N tests, with 0 failures`, including `testSupabaseClientIsLinkedAndInitializesWithoutNetwork` and the nine `SecretGuardTests` cases.

Then run: `scripts/build-app.sh`
Expected: `** BUILD SUCCEEDED **`.

Then confirm the entitlement really reached the built app:
```bash
APP="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 -path '*Build/Products/Debug-iphonesimulator/AnimalTracker.app' | head -1)"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -A2 applesignin
```
Expected: the output contains `com.apple.developer.applesignin` with `Default`.

- [ ] **Step 8: Fallback if the simulator build fails to sign**

Only do this if Step 7's `scripts/build-app.sh` fails with a code-signing or provisioning-profile error (for example `No profiles for 'com.ashlab.AnimalTracker' were found`). The fallback applies the entitlements file to device builds only.

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

Re-run `xcodegen generate`, `scripts/build-app.sh` and `scripts/test-app.sh`. Expected: `** BUILD SUCCEEDED **` and all tests pass. With this fallback the simulator has no Sign in with Apple entitlement, so the simulator smoke test in Task 12 uses the DEBUG "Continue offline" path and the real Apple sign-in is exercised on the device only. Write one sentence in the commit body recording that the fallback was used.

- [ ] **Step 9: Document the key policy in the README**

Append to `README.md`. The wording deliberately carries **no token value of any shape**: it names
the kinds of secret in words, so the section can never be what trips the guard it describes
(verification defect D-D1).

```markdown
## Supabase key

`App/Config/Supabase.plist` carries the project URL and the **anon** key. The anon key is public by
design: it only says `role: anon`, and every table is protected by Row Level Security keyed on
`auth.uid()`. It is committed, and there is no local-only substitution step.

What must never enter the repo: the database password, a secret API key, a legacy service-role key,
and the Supabase personal access token the CLI uses. `scripts/check-secrets.sh` matches the value
shapes of all four and runs automatically from `.githooks/pre-push`. It matches values, not names,
so writing the name of an environment variable in a document is fine. After a fresh clone, run
`git config core.hooksPath .githooks` once.
```

Then prove the guard is clean against the tree as it will actually be pushed, rather than against
the intermediate state Step 6 saw:

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add README.md
scripts/check-secrets.sh
```
Expected: `check-secrets: clean`. If it reports a hit in `README.md`, the wording above was changed
and reintroduced a value shape; fix the wording rather than adding an exclusion.

- [ ] **Step 10: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add project.yml App/Config/Supabase.plist App/Sync/SecretPatterns.swift \
        scripts/check-secrets.sh .githooks/pre-push \
        AppTests/SupabasePackageLinkTests.swift AppTests/SecretGuardTests.swift README.md
git commit -m "build: link supabase-swift, commit the anon key, and guard against real secrets

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

If Step 8's fallback was used, add `App/AnimalTracker.entitlements` to the `git add` line.

---

### Task 2: SupabaseConfig, and the Release build that refuses to ship without a key

**Files:**
- Create: `App/Config/SupabaseConfig.swift`
- Create: `AppTests/SupabaseConfigTests.swift`
- Verify, not modified: `project.yml` (the Release guard from Task 1 fires; no edit belongs to this task)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct SupabaseConfig: Equatable { let url: URL; let anonKey: String }`, `SupabaseConfig.placeholderKey = "REPLACE_WITH_ANON_KEY"`, `SupabaseConfig.make(url:anonKey:) -> SupabaseConfig?`, `SupabaseConfig.load(bundle:) -> SupabaseConfig?`, `SupabaseConfig.appBundle: Bundle`.

- [ ] **Step 1: Write the failing test**

Create `AppTests/SupabaseConfigTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SupabaseConfigTests: XCTestCase {
    func testMakeAcceptsARealLookingKey() {
        let config = SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig")
        XCTAssertEqual(config?.url.absoluteString, "https://ojzmtyapkaxxliuurssc.supabase.co")
        XCTAssertEqual(config?.anonKey, "eyJhbGciOiJIUzI1NiJ9.payload.sig")
    }

    func testMakeRejectsThePlaceholderKey() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "REPLACE_WITH_ANON_KEY"))
    }

    func testMakeRejectsThePlaceholderKeyWithSurroundingWhitespace() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "  REPLACE_WITH_ANON_KEY\n"))
    }

    func testMakeRejectsEmptyOrMissingValues() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: ""))
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: nil))
        XCTAssertNil(SupabaseConfig.make(url: "", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertNil(SupabaseConfig.make(url: nil, anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
    }

    func testMakeRejectsAUrlThatIsNotHttps() {
        XCTAssertNil(SupabaseConfig.make(url: "not a url", anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertNil(SupabaseConfig.make(url: "http://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig"))
    }

    /// The shipped plist names the project and, after Task 1 Step 4, carries the real anon key.
    func testBundledPlistCarriesTheProjectUrlAndARealKey() throws {
        let bundle = SupabaseConfig.appBundle
        let path = try XCTUnwrap(bundle.path(forResource: "Supabase", ofType: "plist"),
                                 "App/Config/Supabase.plist is not in the app bundle")
        let dict = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
        XCTAssertEqual(dict["SupabaseURL"] as? String, "https://ojzmtyapkaxxliuurssc.supabase.co")
        let key = try XCTUnwrap(dict["SupabaseAnonKey"] as? String)
        XCTAssertNotEqual(key, SupabaseConfig.placeholderKey,
                          "the real anon key is committed; see Task 1 Step 4")
    }

    /// The whole point of load(): a build with a usable key produces a config.
    func testLoadFromTheAppBundleSucceeds() {
        XCTAssertNotNil(SupabaseConfig.load())
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `cannot find 'SupabaseConfig' in scope`.

- [ ] **Step 3: Write the implementation**

Create `App/Config/SupabaseConfig.swift`:
```swift
import Foundation

/// The Supabase project the app talks to. The anon key is public and is committed in
/// `Supabase.plist` (spec Addendum v7.1). The placeholder string still exists as a tripwire: a
/// build that somehow ships with it produces `nil` here, which DEBUG turns into offline mode and
/// Release turns into a blocking "not configured" screen.
struct SupabaseConfig: Equatable {
    /// The tripwire value. Anything equal to this is "not configured".
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, seven `SupabaseConfigTests` cases green.

Correction if `testLoadFromTheAppBundleSucceeds` fails: the plist still holds the placeholder. Go back to Task 1 Step 4 and substitute the key.

- [ ] **Step 5: Prove the Release build refuses a placeholder key**

This checks the `postCompileScripts` guard from Task 1 Step 3 actually fires, rather than assuming it does. Put the placeholder back, build Release, see it fail, then restore.

`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` matter: a `generic/platform=iOS` Release build otherwise needs a distribution profile, and a missing-profile error would fail the build *before* the compile phases run. The build would fail either way and the grep would print `0`, which reads exactly like a guard that is not wired. Turning signing off makes the guard the only thing that can fail this build.

```bash
cd /Users/asheslab/Documents/work/cat-voice
cp App/Config/Supabase.plist /tmp/Supabase.plist.real
/usr/libexec/PlistBuddy -c "Set :SupabaseAnonKey REPLACE_WITH_ANON_KEY" App/Config/Supabase.plist
xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/ReleaseGuardCheck \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | grep -c "error: Release build with no Supabase anon key"
```
Expected: the grep prints `1` or more, and the build fails. A `0` means the guard is not wired; re-check the `postCompileScripts` block.

Then prove the same build succeeds with the real key, so the guard is the thing that made it fail and not something else:
```bash
cp /tmp/Supabase.plist.real App/Config/Supabase.plist
xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/ReleaseGuardCheck \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

Then clean up and confirm the working tree is back where it started:
```bash
rm -f /tmp/Supabase.plist.real
rm -rf build/ReleaseGuardCheck
git diff --stat App/Config/Supabase.plist
```
Expected: `git diff --stat` prints nothing for that path, meaning the real key is back exactly as committed.

- [ ] **Step 6: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Config/SupabaseConfig.swift AppTests/SupabaseConfigTests.swift
git commit -m "feat(config): load the Supabase project from the bundled plist, placeholder means not configured

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Nonce with a fallback encoding, sync bookkeeping, store ownership, and pinned session storage

**Files:**
- Create: `App/Auth/Nonce.swift`
- Create: `App/Auth/KeychainSessionStorage.swift`
- Create: `App/Sync/SyncState.swift`
- Create: `App/Sync/SyncCoding.swift`
- Create: `AppTests/NonceTests.swift`
- Create: `AppTests/SyncStateTests.swift`
- Create: `AppTests/KeychainSessionStorageTests.swift`
- Create: `AppTests/SyncCodingTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum SyncCoding { static let formatter: ISO8601DateFormatter; static let formatterWithoutFraction: ISO8601DateFormatter; static func string(from: Date) -> String; static func date(from: String) -> Date?; static let encoder: JSONEncoder; static let decoder: JSONDecoder }`.
  - `enum NonceEncoding: String, CaseIterable { case hex, base64url }` with `var next: NonceEncoding?`, `static func load(defaults:) -> NonceEncoding`, `func save(defaults:)`, `static let defaultsKey`.
  - `enum Nonce { enum Failure: Error, LocalizedError { case nonPositiveLength, randomUnavailable(OSStatus) }; static let alphabet: [Character]; static func random(length: Int = 32) throws -> String; static func digest(_ input: String, encoding: NonceEncoding) -> String }`.
  - `struct KeychainSessionStorage: AuthLocalStorage` with `static let defaultService = "com.ashlab.AnimalTracker.auth"`, `init(service: String = KeychainSessionStorage.defaultService)`, `store(key:value:)`, `retrieve(key:)`, `remove(key:)`, `accessibility(forKey:) -> String?`.
  - `enum SyncTable: String, CaseIterable { case animals, voiceRecordings, vocalizations, voiceTags }`.
  - `enum ServerFunctions { static let deleteMyAccount = "delete_my_account" }`.
  - `enum SyncStatus: String, Codable, Equatable, CaseIterable` with `var text: String` and `static func category(for error: any Error) -> SyncStatus`. `CaseIterable` is part of the contract, not decoration: `SyncStateTests.testEveryStatusHasHumanText` iterates `SyncStatus.allCases` and will not compile without it (verification defects C-D10 and D-D11).
  - `enum SyncClock { static func clamp(_ date: Date, notAfter: Date) -> Date; static func highest(of dates: [Date], floor: Date, notAfter: Date) -> Date }`.
  - `struct SyncState: Codable, Equatable` with `pushedThroughAt`, `pullCursorAt`, `pullOffsetAt`, `status`, `lastSyncedAt`, `pushedThrough(_:)`, `pullCursor(_:)`, `pullOffset(_:)`, `setPushedThrough(_:_:)`, `setPullCursor(_:_:offset:)`, `forgetSyncHistory()`, `static func load(defaults:)`, `func save(defaults:)`, `static func clear(defaults:)`, `static let defaultsKey`, `static let epoch`, `static let pageLimit = 500`, `static let audioUploadsPerCycle = 10`.
  - `struct StoreOwner: Codable, Equatable` with `userID`, `claimedAt`, `static func load(defaults:)`, `func save(defaults:)`, `static func clear(defaults:)`, `static let defaultsKey`.
  - `enum StoreOwnerDecision: Equatable { case keep, claimEmpty, reset }` and `enum StoreOwnerPolicy { static func decision(ownerID: String?, newUserID: UUID, storeIsEmpty: Bool) -> StoreOwnerDecision }`.
  - `enum UnsyncedCount { static func count(updatedAtByTable: [SyncTable: [Date]], pendingTombstones: Int, state: SyncState) -> Int }`, the pure helper behind the sign-out warning (verification defect D-D7).

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

    func testRandomHasTheRequestedLengthAndOnlyAlphabetCharacters() throws {
        let value = try Nonce.random(length: 32)
        XCTAssertEqual(value.count, 32)
        XCTAssertTrue(value.allSatisfy { Nonce.alphabet.contains($0) })
    }

    func testRandomDefaultsToThirtyTwo() throws {
        XCTAssertEqual(try Nonce.random().count, 32)
    }

    func testRandomDoesNotRepeat() throws {
        let values = try (0..<50).map { _ in try Nonce.random() }
        XCTAssertEqual(Set(values).count, 50)
    }

    /// A bad length throws instead of trapping, so a caller can fail the sign-in closed
    /// rather than killing the app.
    func testRandomThrowsOnANonPositiveLength() {
        XCTAssertThrowsError(try Nonce.random(length: 0)) { error in
            guard case Nonce.Failure.nonPositiveLength = error else {
                return XCTFail("expected nonPositiveLength, got \(error)")
            }
        }
        XCTAssertThrowsError(try Nonce.random(length: -1))
    }

    /// Known SHA-256 vectors, so a change of encoding is caught. Hex is what Apple's sample code
    /// and the Supabase guide both use, and is what this app sends first.
    func testHexDigestMatchesKnownVectors() {
        XCTAssertEqual(Nonce.digest("abc", encoding: .hex),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Nonce.digest("", encoding: .hex),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// The fallback encoding, used only after Supabase answers "Nonces mismatch". Same digest
    /// bytes, base64url with no padding.
    func testBase64UrlDigestMatchesTheSameVector() {
        XCTAssertEqual(Nonce.digest("abc", encoding: .base64url),
                       "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    }

    func testBase64UrlIsUnpaddedAndUrlSafe() throws {
        let digest = Nonce.digest(try Nonce.random(), encoding: .base64url)
        XCTAssertFalse(digest.contains("="))
        XCTAssertFalse(digest.contains("+"))
        XCTAssertFalse(digest.contains("/"))
    }

    func testHexIsLowercaseAndSixtyFourCharacters() throws {
        let digest = Nonce.digest(try Nonce.random(), encoding: .hex)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// The fallback order is fixed: hex first, then base64url, then nothing. There is no
    /// third step that drops the nonce.
    func testEncodingFallbackOrderStopsAfterBase64Url() {
        XCTAssertEqual(NonceEncoding.hex.next, .base64url)
        XCTAssertNil(NonceEncoding.base64url.next)
    }

    func testEncodingRoundTripsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NonceTests-\(UUID().uuidString)"))
        XCTAssertEqual(NonceEncoding.load(defaults: defaults), .hex, "hex is the default")
        NonceEncoding.base64url.save(defaults: defaults)
        XCTAssertEqual(NonceEncoding.load(defaults: defaults), .base64url)
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
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncStateTests-\(UUID().uuidString)"))
    }

    func testServerFunctionNamesAreTheOnesTheMigrationDefines() {
        // MigrationFileTests asserts the other half: that the SQL defines exactly this name.
        XCTAssertEqual(ServerFunctions.deleteMyAccount, "delete_my_account")
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
        XCTAssertEqual(state.pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullCursor(.voiceTags), SyncState.epoch)
        XCTAssertEqual(state.pullOffset(.voiceTags), 0)
    }

    func testWatermarksAndCursorsRoundTripThroughUserDefaults() {
        var state = SyncState()
        let pushed = Date(timeIntervalSince1970: 1_750_000_500.25)
        let cursor = Date(timeIntervalSince1970: 1_750_000_900.5)
        state.setPushedThrough(.animals, pushed)
        state.setPullCursor(.vocalizations, cursor, offset: 7)
        state.status = .idle
        state.lastSyncedAt = pushed
        state.save(defaults: defaults)

        let loaded = SyncState.load(defaults: defaults)
        XCTAssertEqual(loaded.pushedThrough(.animals).timeIntervalSince1970, pushed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.pullCursor(.vocalizations).timeIntervalSince1970, cursor.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.pullOffset(.vocalizations), 7)
        XCTAssertEqual(loaded.pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(loaded.status, .idle)
    }

    func testLoadOnEmptyDefaultsReturnsAFreshState() {
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
    }

    func testForgetSyncHistoryClearsEveryWatermarkAndCursor() {
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 1_750_000_000))
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 1_750_000_000), offset: 4)
        state.status = .idle
        state.lastSyncedAt = Date()
        state.forgetSyncHistory()
        XCTAssertEqual(state.pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullOffset(.animals), 0)
        XCTAssertEqual(state.status, .never)
        XCTAssertNil(state.lastSyncedAt)
    }

    func testClearRemovesTheStoredBlobEntirely() {
        var state = SyncState()
        state.status = .idle
        state.save(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: SyncState.defaultsKey))
        SyncState.clear(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: SyncState.defaultsKey))
    }

    /// Sync bookkeeping and store ownership are two different keys, because wiping the store on a
    /// user change must not take the record of who owns the store with it.
    func testStoreOwnerIsStoredUnderItsOwnKey() {
        XCTAssertNotEqual(StoreOwner.defaultsKey, SyncState.defaultsKey)
        let owner = StoreOwner(userID: "11111111-1111-1111-1111-111111111111", claimedAt: Date(timeIntervalSince1970: 10))
        owner.save(defaults: defaults)
        var state = SyncState()
        state.forgetSyncHistory()
        state.save(defaults: defaults)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, "11111111-1111-1111-1111-111111111111")
        StoreOwner.clear(defaults: defaults)
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
    }

    func testStoreOwnerPolicyKeepsTheStoreForTheSameUser() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: a.uuidString, newUserID: a, storeIsEmpty: false), .keep)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: a.uuidString.lowercased(), newUserID: a, storeIsEmpty: true), .keep)
    }

    func testStoreOwnerPolicyResetsForADifferentUser() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: b.uuidString, newUserID: a, storeIsEmpty: false), .reset)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: b.uuidString, newUserID: a, storeIsEmpty: true), .reset)
    }

    /// Offline or pre-auth data is never adopted into an account.
    func testStoreOwnerPolicyResetsUnownedDataThatIsNotEmpty() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: nil, newUserID: a, storeIsEmpty: false), .reset)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: "", newUserID: a, storeIsEmpty: false), .reset)
    }

    /// The fresh-install case: a session survives in the keychain, the store is empty and there is
    /// no owner. Nothing to wipe, but the watermarks must start from scratch, which is what
    /// `claimEmpty` tells AuthService to do.
    func testStoreOwnerPolicyClaimsAnEmptyUnownedStore() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: nil, newUserID: a, storeIsEmpty: true), .claimEmpty)
    }

    func testClampNeverLetsAWatermarkRunAheadOfTheDeviceClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SyncClock.clamp(Date(timeIntervalSince1970: 9_999), notAfter: now), now)
        XCTAssertEqual(SyncClock.clamp(Date(timeIntervalSince1970: 500), notAfter: now),
                       Date(timeIntervalSince1970: 500))
    }

    func testHighestFallsBackToTheFloorAndClamps() {
        let now = Date(timeIntervalSince1970: 1_000)
        let floor = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SyncClock.highest(of: [], floor: floor, notAfter: now), floor)
        XCTAssertEqual(SyncClock.highest(of: [Date(timeIntervalSince1970: 50)], floor: floor, notAfter: now), floor,
                       "a value below the floor never moves the watermark backwards")
        XCTAssertEqual(SyncClock.highest(of: [Date(timeIntervalSince1970: 9_999)], floor: floor, notAfter: now), now)
    }

    /// A raw server error string can carry a token, a row id or a table name. The status the UI
    /// shows is a category, never the message.
    func testStatusTextIsACategoryAndNeverEchoesAServerString() {
        struct Leaky: Error, LocalizedError {
            var errorDescription: String? { "PGRST301: JWT eyJhbGciOiJIUzI1NiJ9.leak expired for user 1234" }
        }
        let status = SyncStatus.category(for: Leaky())
        XCTAssertEqual(status, .failedServer)
        XCTAssertFalse(status.text.contains("eyJ"))
        XCTAssertFalse(status.text.contains("PGRST"))
        XCTAssertEqual(status.text, "Sync failed. The server rejected the change.")
    }

    func testStatusCategoriesCoverNetworkAndCancellation() {
        XCTAssertEqual(SyncStatus.category(for: URLError(.notConnectedToInternet)), .failedNetwork)
        XCTAssertEqual(SyncStatus.category(for: SyncCancelled()), .cancelled)
    }

    func testEveryStatusHasHumanText() {
        for status in SyncStatus.allCases {
            XCTAssertFalse(status.text.isEmpty, "\(status) has no text")
        }
    }

    // MARK: the sign-out warning count (verification defect D-D7)

    /// The number this produces is what a destructive dialog tells the person they are about to
    /// lose, so the boundary condition matters: a row stamped exactly at the watermark was
    /// included in the last successful push and is not outstanding.
    func testUnsyncedCountUsesAStrictlyNewerComparisonPerTable() {
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 1_000))
        state.setPushedThrough(.voiceRecordings, Date(timeIntervalSince1970: 2_000))

        let count = UnsyncedCount.count(
            updatedAtByTable: [
                .animals: [Date(timeIntervalSince1970: 999),    // pushed
                           Date(timeIntervalSince1970: 1_000),  // pushed, exactly at the watermark
                           Date(timeIntervalSince1970: 1_001)], // outstanding
                .voiceRecordings: [Date(timeIntervalSince1970: 2_500)], // outstanding
                .vocalizations: [Date(timeIntervalSince1970: 1)],       // never pushed: epoch watermark
            ],
            pendingTombstones: 0,
            state: state)

        XCTAssertEqual(count, 3)
    }

    func testUnsyncedCountAddsPendingTombstonesAndIsZeroWhenEverythingIsPushed() {
        var state = SyncState()
        for table in SyncTable.allCases { state.setPushedThrough(table, Date(timeIntervalSince1970: 5_000)) }
        let rows: [SyncTable: [Date]] = [.animals: [Date(timeIntervalSince1970: 4_000)]]

        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: rows, pendingTombstones: 0, state: state), 0)
        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: rows, pendingTombstones: 2, state: state), 2,
                       "a delete that has not reached the server is outstanding work too")
        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: [:], pendingTombstones: 0, state: state), 0)
    }
}
```

Create `AppTests/KeychainSessionStorageTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

/// The Supabase SDK's own KeychainLocalStorage has no accessibility parameter and writes
/// kSecAttrAccessibleAfterFirstUnlock. This app needs ...ThisDeviceOnly so a restored device
/// backup never carries a live session, which is why the storage is ours.
final class KeychainSessionStorageTests: XCTestCase {
    private var storage: KeychainSessionStorage!
    private let key = "session-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        storage = KeychainSessionStorage(service: "com.ashlab.AnimalTracker.auth.tests")
    }

    override func tearDown() {
        try? storage.remove(key: key)
        super.tearDown()
    }

    func testStoreRetrieveRemoveRoundTrip() throws {
        XCTAssertNil(try storage.retrieve(key: key))
        try storage.store(key: key, value: Data("first".utf8))
        XCTAssertEqual(try storage.retrieve(key: key), Data("first".utf8))
        try storage.store(key: key, value: Data("second".utf8))
        XCTAssertEqual(try storage.retrieve(key: key), Data("second".utf8), "store replaces, it does not duplicate")
        try storage.remove(key: key)
        XCTAssertNil(try storage.retrieve(key: key))
    }

    func testRemovingSomethingThatIsNotThereIsNotAnError() {
        XCTAssertNoThrow(try storage.remove(key: "absent-\(UUID().uuidString)"))
    }

    func testItemIsAccessibleOnlyAfterFirstUnlockAndOnlyOnThisDevice() throws {
        try storage.store(key: key, value: Data("x".utf8))
        XCTAssertEqual(storage.accessibility(forKey: key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testTheServiceIsPinnedToTheApp() {
        XCTAssertEqual(KeychainSessionStorage.defaultService, "com.ashlab.AnimalTracker.auth")
    }
}
```

Create `AppTests/SyncCodingTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

/// These coders are not a test convenience: Task 4 hands them to the client as
/// `DatabaseOptions(encoder:decoder:)`, so what is asserted here is literally what goes on the wire.
final class SyncCodingTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_750_000_000.25)

    func testDatesEncodeAsIso8601WithFractionalSecondsInUtc() {
        let text = SyncCoding.string(from: moment)
        XCTAssertTrue(text.hasSuffix("Z"), text)
        XCTAssertTrue(text.contains(".250"), text)
    }

    func testDatesRoundTripToTheMillisecond() throws {
        let back = try XCTUnwrap(SyncCoding.date(from: SyncCoding.string(from: moment)))
        XCTAssertEqual(back.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Postgres omits the fractional part when it is zero, and renders the zone as +00:00 rather
    /// than Z, so the decoder has to take all three shapes.
    /// 1_789_819_200 is 2026-09-19T12:00:00Z. Computed, not guessed:
    /// `python3 -c "import datetime;print(int(datetime.datetime(2026,9,19,12,0,tzinfo=datetime.timezone.utc).timestamp()))"`
    func testDecoderAcceptsTimestampsWithoutFractionalSecondsAndWithAnOffsetZone() throws {
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00Z")).timeIntervalSince1970,
                       1_789_819_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00+00:00")).timeIntervalSince1970,
                       1_789_819_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00.125+00:00")).timeIntervalSince1970,
                       1_789_819_200.125, accuracy: 0.001)
    }

    func testDecoderRejectsSomethingThatIsNotADate() {
        XCTAssertNil(SyncCoding.date(from: "yesterday"))
    }

    struct Sample: Codable, Equatable {
        var when: Date
        var maybe: Date?
    }

    func testEncoderAndDecoderAgreeThroughJson() throws {
        let value = Sample(when: moment, maybe: nil)
        let data = try SyncCoding.encoder.encode(value)
        let back = try SyncCoding.decoder.decode(Sample.self, from: data)
        XCTAssertEqual(back.when.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(back.maybe)
    }

    /// Swift's synthesized Codable uses encodeIfPresent for optionals, so a nil is omitted rather
    /// than sent as JSON null. Pinned here because it is the reason none of Task 8's row structs
    /// use the synthesized encoder: PostgREST refuses a bulk upsert whose objects do not all carry
    /// the same keys (PGRST102), and omitted nils make the key set depend on the row's contents.
    /// Task 8's rows write an explicit `encode(to:)` instead; `SyncRowTests` asserts that.
    func testSynthesizedCodableOmitsNilWhichIsWhyRowsEncodeExplicitly() throws {
        let data = try SyncCoding.encoder.encode(Sample(when: moment, maybe: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.keys.contains("maybe"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `cannot find 'Nonce' in scope`, `cannot find 'SyncState' in scope`, `cannot find 'SyncCoding' in scope` and `cannot find 'KeychainSessionStorage' in scope`.

- [ ] **Step 3: Write Nonce**

Create `App/Auth/Nonce.swift`:
```swift
import CryptoKit
import Foundation
import Security

/// Which encoding of the SHA-256 digest Apple is given. Supabase's token check has a known
/// hex-versus-base64url ambiguity (https://github.com/supabase/auth/issues/2378), so the app tries
/// hex first and falls back to base64url once, remembering which one worked.
///
/// There is no third option. Dropping the nonce reopens a replay window on the identity token and
/// needs Ash's explicit written sign-off; it is not something this code can decide to do.
enum NonceEncoding: String, CaseIterable {
    case hex
    case base64url

    static let defaultsKey = "animalTracker.nonceEncoding"

    /// The next encoding to try after this one failed, or nil when the fallbacks are exhausted.
    var next: NonceEncoding? {
        switch self {
        case .hex: return .base64url
        case .base64url: return nil
        }
    }

    static func load(defaults: UserDefaults = .standard) -> NonceEncoding {
        guard let raw = defaults.string(forKey: defaultsKey), let value = NonceEncoding(rawValue: raw) else {
            return .hex
        }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: NonceEncoding.defaultsKey)
    }
}

/// Sign in with Apple nonce handling. Apple is given the SHA-256 digest of the nonce and puts that
/// digest in the identity token; Supabase is given the raw nonce and re-hashes it to check the
/// token. Both halves are pure so they can be tested without an Apple account.
enum Nonce {
    enum Failure: Error, LocalizedError {
        case nonPositiveLength
        case randomUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .nonPositiveLength:
                return "A nonce must be at least one character long."
            case .randomUnavailable(let status):
                return "The system random number generator is unavailable (status \(status))."
            }
        }
    }

    /// Exactly 64 characters, so `UInt8 % 64` is uniform (256 is a multiple of 64) and every
    /// character is URL-safe.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")

    /// Throws rather than trapping: a device that cannot produce randomness must fail the sign-in,
    /// not crash the app, and must never fall back to a predictable nonce.
    static func random(length: Int = 32) throws -> String {
        guard length > 0 else { throw Failure.nonPositiveLength }
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else { throw Failure.randomUnavailable(status) }
        var result = ""
        result.reserveCapacity(length)
        for byte in bytes { result.append(alphabet[Int(byte) % alphabet.count]) }
        return result
    }

    static func digest(_ input: String, encoding: NonceEncoding) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        switch encoding {
        case .hex:
            return hashed.map { String(format: "%02x", $0) }.joined()
        case .base64url:
            return Data(hashed).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }
}
```

- [ ] **Step 4: Write the sync bookkeeping and the ownership policy**

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

/// Postgres functions this app calls by name. One constant per name, so the Swift side and the
/// migration cannot drift apart without `MigrationFileTests` failing.
enum ServerFunctions {
    static let deleteMyAccount = "delete_my_account"
}

/// Thrown by the engine when the sync generation it started under is no longer current.
struct SyncCancelled: Error {}

/// What Settings shows. Deliberately a small closed set: a raw server message can carry a token, a
/// row id or a table name, and it would be persisted to UserDefaults and shown on screen.
enum SyncStatus: String, Codable, Equatable, CaseIterable {
    case never
    case idle
    case syncing
    case offline
    case notSignedIn
    case cancelled
    case failedNetwork
    case failedServer
    case failedLocal

    var text: String {
        switch self {
        case .never: return "Never synced"
        case .idle: return "Synced"
        case .syncing: return "Syncing"
        case .offline: return "Offline. Records stay on this phone."
        case .notSignedIn: return "Not signed in"
        case .cancelled: return "Sync stopped"
        case .failedNetwork: return "Sync failed. No connection."
        case .failedServer: return "Sync failed. The server rejected the change."
        case .failedLocal: return "Sync failed. Could not read or write on this phone."
        }
    }

    /// Maps an error to a category without ever keeping its text.
    static func category(for error: any Error) -> SyncStatus {
        if error is SyncCancelled || error is CancellationError { return .cancelled }
        if error is URLError { return .failedNetwork }
        if error is MediaStoreError { return .failedLocal }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .failedNetwork }
        if nsError.domain == NSCocoaErrorDomain { return .failedLocal }
        return .failedServer
    }
}

/// Watermark arithmetic, kept in one place so the clock-skew rule is testable.
enum SyncClock {
    /// A watermark never runs ahead of the device's own clock. One row accidentally dated years in
    /// the future would otherwise suppress every later push.
    static func clamp(_ date: Date, notAfter now: Date) -> Date { min(date, now) }

    /// The highest of `dates`, never below `floor` and never after `now`.
    static func highest(of dates: [Date], floor: Date, notAfter now: Date) -> Date {
        let candidate = dates.max() ?? floor
        return clamp(max(candidate, floor), notAfter: now)
    }
}

/// Sync bookkeeping. Small enough to live in UserDefaults as one JSON blob, and deliberately not in
/// SwiftData, because wiping the store must not wipe the record of how far sync got.
///
/// Two different kinds of watermark, on two different clocks:
/// - `pushedThroughAt` is the device's own `updatedAt` high-water mark per table. Anything newer is
///   outstanding and gets pushed.
/// - `pullCursorAt` plus `pullOffsetAt` is the server's `server_updated_at` cursor per table, with
///   the number of rows already consumed at exactly that timestamp, so a page boundary that lands
///   inside a group of rows sharing one timestamp resumes correctly.
struct SyncState: Codable, Equatable {
    static let defaultsKey = "animalTracker.syncState"
    /// The watermark for "never pulled" and "never pushed".
    static let epoch = Date(timeIntervalSince1970: 0)
    /// Rows requested per pull page.
    static let pageLimit = 500
    /// Audio files uploaded per sync cycle, so one cycle cannot hold the app on a slow link.
    static let audioUploadsPerCycle = 10

    var pushedThroughAt: [String: Date] = [:]
    var pullCursorAt: [String: Date] = [:]
    var pullOffsetAt: [String: Int] = [:]
    var status: SyncStatus = .never
    var lastSyncedAt: Date?

    func pushedThrough(_ table: SyncTable) -> Date { pushedThroughAt[table.rawValue] ?? SyncState.epoch }
    func pullCursor(_ table: SyncTable) -> Date { pullCursorAt[table.rawValue] ?? SyncState.epoch }
    func pullOffset(_ table: SyncTable) -> Int { pullOffsetAt[table.rawValue] ?? 0 }

    mutating func setPushedThrough(_ table: SyncTable, _ date: Date) {
        pushedThroughAt[table.rawValue] = date
    }

    mutating func setPullCursor(_ table: SyncTable, _ date: Date, offset: Int) {
        pullCursorAt[table.rawValue] = date
        pullOffsetAt[table.rawValue] = offset
    }

    /// Forgets how far sync got, so the next cycle pushes and pulls everything from scratch.
    /// Does not touch `StoreOwner`, which lives under its own key.
    mutating func forgetSyncHistory() {
        pushedThroughAt = [:]
        pullCursorAt = [:]
        pullOffsetAt = [:]
        status = .never
        lastSyncedAt = nil
    }

    static func load(defaults: UserDefaults = .standard) -> SyncState {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SyncState.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Who the local store belongs to. Written the moment a session is established, before any sync
/// runs, and kept under its own defaults key so clearing sync history never clears ownership and
/// vice versa.
struct StoreOwner: Codable, Equatable {
    static let defaultsKey = "animalTracker.storeOwner"

    var userID: String?
    var claimedAt: Date?

    static func load(defaults: UserDefaults = .standard) -> StoreOwner {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(StoreOwner.self, from: data) else { return StoreOwner() }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: StoreOwner.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

enum StoreOwnerDecision: Equatable {
    /// Same person as last time: keep the store and the watermarks.
    case keep
    /// Nobody owns this store and there is nothing in it: keep the empty store, start the
    /// watermarks from scratch. This is the fresh-install-with-a-keychain-session case.
    case claimEmpty
    /// Wipe the store and the watermarks before this person sees anything.
    case reset
}

/// One person's animals must never appear under another person's account on the same phone, and
/// data created offline or before sign-in is never silently adopted into an account.
enum StoreOwnerPolicy {
    static func decision(ownerID: String?, newUserID: UUID, storeIsEmpty: Bool) -> StoreOwnerDecision {
        let owner = (ownerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if owner.isEmpty {
            return storeIsEmpty ? .claimEmpty : .reset
        }
        return owner.caseInsensitiveCompare(newUserID.uuidString) == .orderedSame ? .keep : .reset
    }
}

/// How many local rows have not reached the server yet.
///
/// Sign-out wipes the store, so the person has to be told what that costs before they confirm it
/// (verification defect D-D7). "Outstanding" has exactly the meaning the push watermark gives it:
/// a row is outstanding when its `updatedAt` is strictly newer than `pushedThrough` for its table,
/// which is the same `>` the engine's own `changed*(after:)` uses, plus every tombstone still
/// waiting to be pushed.
///
/// Pure on purpose. It takes dates and a count rather than a store, so the arithmetic that decides
/// what a destructive dialog says is unit-tested without SwiftData, a container or a network.
enum UnsyncedCount {
    static func count(updatedAtByTable: [SyncTable: [Date]],
                      pendingTombstones: Int,
                      state: SyncState) -> Int {
        let rows = updatedAtByTable.reduce(0) { total, entry in
            let watermark = state.pushedThrough(entry.key)
            return total + entry.value.filter { $0 > watermark }.count
        }
        return rows + pendingTombstones
    }
}
```

- [ ] **Step 5: Write the pinned keychain storage**

Create `App/Auth/KeychainSessionStorage.swift`:
```swift
import Foundation
import Security
import Supabase

/// Where the Supabase session lives. The SDK's own `KeychainLocalStorage` takes a service name but
/// no accessibility, and its internal Keychain writes `kSecAttrAccessibleAfterFirstUnlock`
/// (https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/Keychain.swift).
/// This app wants `...ThisDeviceOnly`, which also excludes the item from encrypted backups, so a
/// device backup restored onto a second phone never carries a live session.
struct KeychainSessionStorage: AuthLocalStorage {
    static let defaultService = "com.ashlab.AnimalTracker.auth"

    let service: String

    init(service: String = KeychainSessionStorage.defaultService) {
        self.service = service
    }

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Keychain error \(status)."
            }
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func store(key: String, value: Data) throws {
        // Delete first, then add: SecItemUpdate cannot change kSecAttrAccessible on some OS
        // versions, and a replace has to be certain about the final accessibility.
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// Test seam: reads back the stored item's accessibility class, so the promise this type makes
    /// is checked rather than assumed. Not part of `AuthLocalStorage`.
    func accessibility(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }
}
```

- [ ] **Step 6: Write the wire coders**

Create `App/Sync/SyncCoding.swift`:
```swift
import Foundation

/// The JSON coding used on the wire. Task 4 passes these to `SupabaseClient` as
/// `SupabaseClientOptions.DatabaseOptions(encoder:decoder:)`, so the row structs are encoded and
/// decoded by exactly the coders the tests exercise, and `updated_at` keeps its sub-second part
/// end to end rather than depending on whatever the SDK's defaults happen to be.
enum SyncCoding {
    /// What this app writes: UTC, fractional seconds, Z suffix.
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// What Postgres sometimes writes back: no fractional part when it is exactly zero.
    static let formatterWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from text: String) -> Date? {
        formatter.date(from: text) ?? formatterWithoutFraction.date(from: text)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let parsed = date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return parsed
        }
        return decoder
    }()
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `NonceTests` eleven cases, `SyncStateTests` nineteen cases, `SyncCodingTests` six cases and `KeychainSessionStorageTests` four cases are green, and nothing in them touches the network.

Correction if `testItemIsAccessibleOnlyAfterFirstUnlockAndOnlyOnThisDevice` fails with a nil accessibility: the item was written by `SecItemUpdate` rather than `SecItemAdd`; check that `store(key:value:)` deletes before adding.

- [ ] **Step 8: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Auth/Nonce.swift App/Auth/KeychainSessionStorage.swift App/Sync/SyncState.swift \
        App/Sync/SyncCoding.swift AppTests/NonceTests.swift AppTests/SyncStateTests.swift \
        AppTests/SyncCodingTests.swift AppTests/KeychainSessionStorageTests.swift
git commit -m "feat(auth): nonce with a base64url fallback, sync watermarks, store ownership, pinned keychain storage

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: AuthService, the one place that orders sign-in, store ownership and sign-out

**Files:**
- Create: `App/Auth/AuthService.swift`
- Create: `AppTests/AuthServiceTests.swift`

**Interfaces:**
- Consumes: `SupabaseConfig` (Task 2); `Nonce`, `NonceEncoding`, `KeychainSessionStorage`, `SyncCoding`, `SyncState`, `StoreOwner`, `StoreOwnerPolicy`, `StoreOwnerDecision` (Task 3).
- Produces:
  - `enum AuthState: Equatable { case unknown, signedOut, signedIn(userID: UUID, email: String?), offline, misconfigured }`.
  - `enum AuthError: Error, LocalizedError { case notConfigured, missingIdentityToken, nonceUnavailable, nonceMismatch, signOutRefused, sessionStillPresent }`.
  - `@MainActor protocol StoreLifecycle: AnyObject { func cancelSync() async; func storeIsEmpty() -> Bool; func wipeStore() async; func configureSync(for state: AuthState, client: SupabaseClient?) }`.
  - `@MainActor final class AuthService: ObservableObject` with `init(config: SupabaseConfig? = SupabaseConfig.load(), defaults: UserDefaults = .standard, isRelease: Bool = AuthService.isReleaseBuild)`, `let client: SupabaseClient?`, `var isConfigured: Bool`, `static var isReleaseBuild: Bool`, `static let appleUserIDKey`, `static let sessionStorageKey`, `weak var lifecycle: (any StoreLifecycle)?`, `@Published private(set) var state: AuthState`, `@Published private(set) var isWorking: Bool`, `@Published var message: String?`, `func restoreSession() async`, `func beginSignIn() throws -> String`, `func abortSignIn(message: String)`, `func signInWithApple(authorization: ASAuthorization) async throws`, `func signOut() async`, `func deleteAccount() async throws`, `func leaveOfflineMode() async`, `func startWatchingAppleCredential()`, `func checkAppleCredentialState() async`, `var credentialStateProbe: (String) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?)`, `func establish(userID: UUID, email: String?) async`, `static func isNonceMismatch(_ error: any Error) -> Bool`, and under `#if DEBUG` `func continueOffline()`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/AuthServiceTests.swift`:
```swift
import AuthenticationServices
import Supabase
import XCTest
@testable import AnimalTracker

/// Records the order AuthService drives the store through. The whole point of `StoreLifecycle` is
/// that this order is one function's business, not the emergent result of two `.onChange` handlers.
@MainActor
final class FakeStoreLifecycle: StoreLifecycle {
    enum Event: Equatable {
        case cancelSync
        case wipeStore
        case configureSync(String)
    }

    var events: [Event] = []
    var isEmpty = true

    func cancelSync() async { events.append(.cancelSync) }
    func storeIsEmpty() -> Bool { isEmpty }
    func wipeStore() async {
        events.append(.wipeStore)
        isEmpty = true
    }
    func configureSync(for state: AuthState, client: SupabaseClient?) {
        events.append(.configureSync(String(describing: state)))
    }
}

@MainActor
final class AuthServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var lifecycle: FakeStoreLifecycle!
    private let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let userB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "AuthServiceTests-\(UUID().uuidString)"))
        lifecycle = FakeStoreLifecycle()
    }

    private func makeService(isRelease: Bool = false) -> AuthService {
        let auth = AuthService(config: nil, defaults: defaults, isRelease: isRelease)
        auth.lifecycle = lifecycle
        return auth
    }

    // MARK: configuration

    func testUnconfiguredServiceHasNoClient() {
        let auth = makeService()
        XCTAssertFalse(auth.isConfigured)
        XCTAssertEqual(auth.state, .unknown)
    }

    func testDebugBuildWithoutAKeyGoesOffline() async {
        let auth = makeService(isRelease: false)
        await auth.restoreSession()
        XCTAssertEqual(auth.state, .offline)
    }

    /// Fail closed: a release build with no key must never reach the tabs.
    func testReleaseBuildWithoutAKeyIsMisconfigured() async {
        let auth = makeService(isRelease: true)
        await auth.restoreSession()
        XCTAssertEqual(auth.state, .misconfigured)
    }

    // MARK: store ownership, the one ordered transition

    func testSigningInAsTheSameUserKeepsTheStore() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        lifecycle.isEmpty = false
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: "ash@example.com")

        XCTAssertEqual(lifecycle.events, [.configureSync("signedIn(userID: \(userA), email: Optional(\"ash@example.com\"))")])
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals),
                       Date(timeIntervalSince1970: 500), "the watermarks survive a same-user sign-in")
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: "ash@example.com"))
    }

    func testSigningInAsADifferentUserCancelsSyncThenWipesThenConfigures() async {
        StoreOwner(userID: userB.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        lifecycle.isEmpty = false
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore],
                       "cancel the running sync before destroying the store it is writing to")
        XCTAssertEqual(lifecycle.events.count, 3)
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
    }

    /// Data made offline or before sign-in is never adopted into an account.
    func testSigningInOverUnownedNonEmptyDataWipes() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = false

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
    }

    /// Fresh install: the keychain still holds a session, the store is empty, nobody owns it.
    /// Nothing to wipe, but the watermarks have to start from scratch.
    func testFirstLaunchAfterInstallClaimsTheEmptyStoreAndResetsWatermarks() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = true
        var state = SyncState()
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 900), offset: 3)
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
        XCTAssertEqual(SyncState.load(defaults: defaults).pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(SyncState.load(defaults: defaults).pullOffset(.animals), 0)
    }

    /// Fail closed. With no lifecycle attached there is no way to ask whether the store is empty,
    /// and "I do not know" must mean "assume it holds someone's records", so an unowned store is
    /// reset rather than adopted. The v2 code defaulted the other way.
    func testAServiceWithNoLifecycleFailsClosedAndResetsTheStore() async {
        StoreOwner.clear(defaults: defaults)
        var state = SyncState()
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 900), offset: 3)
        state.save(defaults: defaults)

        let auth = AuthService(config: nil, defaults: defaults, isRelease: false)
        XCTAssertNil(auth.lifecycle)
        await auth.establish(userID: userA, email: nil)

        // `reset` calls SyncState.clear, which removes the blob. `claimEmpty` would call
        // forgetSyncHistory and save, leaving a blob behind. That is the only observable difference
        // between the two branches when no lifecycle is attached, so it is what this asserts.
        XCTAssertNil(defaults.data(forKey: SyncState.defaultsKey),
                     "an unknown store must take the reset branch, not claimEmpty")
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
    }

    /// The same decision with a lifecycle that says the store is empty goes the other way, so the
    /// assertion above is about the missing lifecycle and not about `StoreOwnerPolicy`.
    func testAnEmptyStoreWithALifecycleStillTakesTheClaimBranch() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = true
        SyncState().save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertNotNil(defaults.data(forKey: SyncState.defaultsKey))
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    /// Ownership is recorded the moment the session is established, before anything syncs.
    func testOwnershipIsRecordedBeforeSyncIsConfigured() async {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
        XCTAssertNotNil(StoreOwner.load(defaults: defaults).claimedAt)
        guard case .configureSync = lifecycle.events.last else {
            return XCTFail("configureSync must be the last step of the transition, got \(lifecycle.events)")
        }
    }

    // MARK: sign out

    func testSignOutCancelsSyncWipesThenClearsIds() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)
        defaults.set("apple-user-id", forKey: AuthService.appleUserIDKey)

        let auth = makeService()
        await auth.signOut()

        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore])
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
        XCTAssertNil(defaults.string(forKey: AuthService.appleUserIDKey))
        XCTAssertNil(auth.message)
    }

    /// The previous revision asserted the opposite. Offline data has no owner, so leaving offline
    /// mode discards it rather than letting the next sign-in adopt it.
    func testLeavingOfflineModeDiscardsTheOfflineData() async {
        let auth = makeService()
        auth.continueOffline()
        XCTAssertEqual(auth.state, .offline)

        await auth.leaveOfflineMode()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
    }

    // MARK: nonce

    func testBeginSignInReturnsTheHashAndMarksTheServiceBusy() throws {
        let auth = makeService()
        let hash = try auth.beginSignIn()
        XCTAssertEqual(hash.count, 64, "hex digest of SHA-256")
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertTrue(auth.isWorking)
    }

    func testTwoSignInAttemptsUseDifferentNonces() throws {
        let auth = makeService()
        XCTAssertNotEqual(try auth.beginSignIn(), try auth.beginSignIn())
    }

    /// Fail closed: if the request could not be prepared, the pending nonce is dropped, so a
    /// completion that still arrives has nothing to exchange and `signInWithApple` throws
    /// `nonceUnavailable` before it ever looks at the credential.
    func testAbortingASignInDropsThePendingNonceAndLeavesTheStateAlone() {
        let auth = makeService()
        _ = try? auth.beginSignIn()
        auth.abortSignIn(message: "could not start")
        XCTAssertFalse(auth.isWorking)
        XCTAssertEqual(auth.message, "could not start")
        XCTAssertEqual(auth.state, .unknown)
    }

    /// v2 had a `testAnUnconfiguredServiceNeverSignsAnyoneIn` here that asserted exactly what
    /// `testUnconfiguredServiceHasNoClient` already asserts, so it could not fail. This one drives
    /// a code path: the destructive operation refuses without a client, and refuses *before*
    /// touching the store, so a misconfigured build cannot wipe a person's records.
    func testAnUnconfiguredServiceRefusesToDeleteAnAccount() async {
        let auth = makeService()
        do {
            try await auth.deleteAccount()
            XCTFail("expected AuthError.notConfigured")
        } catch AuthError.notConfigured {
            // expected
        } catch {
            XCTFail("expected AuthError.notConfigured, got \(error)")
        }
        XCTAssertEqual(lifecycle.events, [], "nothing may be cancelled or wiped without a client")
        XCTAssertFalse(auth.isWorking)
        XCTAssertEqual(auth.state, .unknown)
    }

    func testNonceMismatchIsRecognisedFromTheServerMessage() {
        struct Mismatch: Error, LocalizedError {
            var errorDescription: String? { "Nonces mismatch" }
        }
        XCTAssertTrue(AuthService.isNonceMismatch(Mismatch()))
        XCTAssertFalse(AuthService.isNonceMismatch(URLError(.timedOut)))
    }

    // MARK: state

    func testAuthStateEquatability() {
        XCTAssertEqual(AuthState.signedIn(userID: userA, email: "x@y.z"), .signedIn(userID: userA, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.signedIn(userID: userA, email: nil), .signedIn(userID: userA, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.offline, .signedOut)
        XCTAssertNotEqual(AuthState.misconfigured, .offline)
    }

    // MARK: Apple credential state (verification defect D-D8)

    /// Drives `checkAppleCredentialState()` with a substituted probe. The service is put into
    /// `.signedIn` through `establish`, which is the only state the check acts in, and the
    /// lifecycle's event log is cleared afterwards so the assertions see only what the check did.
    private func signedInService(
        probe: @escaping (String) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?)
    ) async -> AuthService {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        defaults.set("apple.user.id", forKey: AuthService.appleUserIDKey)
        lifecycle.events.removeAll()
        auth.credentialStateProbe = probe
        return auth
    }

    func testARevokedAppleCredentialSignsOut() async {
        let auth = await signedInService { _ in (.revoked, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore), "a real revocation is the one case that wipes")
    }

    /// `.notFound` also means "a different Apple ID is signed in on this device". Wiping on it
    /// would delete every unpushed record for a condition that is not a revocation.
    func testANotFoundAppleCredentialLeavesTheSessionAndTheStoreAlone() async {
        let auth = await signedInService { _ in (.notFound, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [], "nothing may touch the store on an ambiguous state")
    }

    func testATransferredAppleCredentialLeavesTheSessionAndTheStoreAlone() async {
        let auth = await signedInService { _ in (.transferred, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [])
    }

    /// The error path. Whatever state accompanies a non-nil error is not trustworthy, so the
    /// service must ignore both and let the next authenticated request decide.
    func testAFailedCredentialProbeLeavesTheSessionAndTheStoreAlone() async {
        struct Transient: Error {}
        let auth = await signedInService { _ in (.notFound, Transient()) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [])
    }
}
```

The four cases reuse the file's own `defaults`/`lifecycle` properties and `makeService()`; no new
fixture is introduced. `establish(userID:email:)` on a fresh suite takes the `claimEmpty` branch,
so the service ends in `.signedIn(userID: userA, email: nil)`, which is what the three negative
cases assert is still true afterwards.

`ASAuthorization` has no public initializer, and Apple only hands one back from a real authorization, so no unit test can drive `signInWithApple(authorization:)` end to end. Everything around it is testable without one: the nonce is prepared and dropped here, the ordered transition is exercised directly through `establish(userID:email:)`, and the mismatch matcher is a pure function. The exchange itself is exercised on a device in Task 12 Step 4, which is the only honest place for it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL. The compiler reports `cannot find 'AuthService' in scope` and `cannot find type 'StoreLifecycle' in scope`.

- [ ] **Step 3: Write the state and error types**

Create `App/Auth/AuthService.swift` with this first section:
```swift
import AuthenticationServices
import Foundation
import Supabase

enum AuthState: Equatable {
    /// Before the first session restore finishes.
    case unknown
    case signedOut
    case signedIn(userID: UUID, email: String?)
    /// DEBUG "Continue offline".
    case offline
    /// A build that shipped without a usable anon key. Release shows a blocking screen; the tabs
    /// are never reachable from here.
    case misconfigured
}

enum AuthError: Error, LocalizedError {
    case notConfigured
    case missingIdentityToken
    case nonceUnavailable
    case nonceMismatch
    case signOutRefused
    case sessionStillPresent

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no Supabase anon key, so it cannot sign in."
        case .missingIdentityToken:
            return "Apple did not return an identity token."
        case .nonceUnavailable:
            return "This sign-in could not be prepared securely. Tap the button again."
        case .nonceMismatch:
            return "The server did not accept the sign-in check. Tap the button again."
        case .signOutRefused:
            return "The server refused the sign-out. You are still signed in."
        case .sessionStillPresent:
            return "The session is still on this phone. Try signing out again."
        }
    }
}

/// What AuthService does to the local store, in order, at each transition. It exists so the order
/// is one function's business rather than the emergent result of two SwiftUI `.onChange` handlers
/// whose relative ordering is not defined.
@MainActor
protocol StoreLifecycle: AnyObject {
    /// Stops any running sync and waits for it to actually stop.
    func cancelSync() async
    /// True when the store holds no user records at all.
    func storeIsEmpty() -> Bool
    /// Destroys the store, opens a fresh one, re-seeds it and republishes it to the UI.
    func wipeStore() async
    /// Points sync at this state's user and client, or at nothing.
    func configureSync(for state: AuthState, client: SupabaseClient?)
}
```

- [ ] **Step 4: Write AuthService**

Append to `App/Auth/AuthService.swift`:
```swift
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .unknown
    /// True from the moment the Sign in with Apple request is prepared until the exchange finishes.
    @Published private(set) var isWorking = false
    /// The one message the sign-in screen and Settings show. Never carries a server string.
    @Published var message: String?

    static let appleUserIDKey = "animalTracker.appleUserID"

    /// The keychain account the Supabase session occupies. Passed to the SDK as
    /// `AuthOptions.storageKey`, so this app knows the exact item rather than depending on the
    /// SDK's internal `defaultStorageKey`. `deleteAccount()` removes this item by name.
    static let sessionStorageKey = "animalTracker.session"

    /// True in a build without DEBUG. Injectable so the fail-closed behaviour is testable.
    static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    let client: SupabaseClient?
    /// Set once by the app at launch. Weak: the app owns it, this service only drives it.
    weak var lifecycle: (any StoreLifecycle)?

    private let defaults: UserDefaults
    private let isRelease: Bool
    /// The same storage the client was built with, so `deleteAccount()` can remove the session
    /// item itself rather than trusting `signOut` to have done it.
    private let sessionStorage: KeychainSessionStorage
    /// Held between preparing the Apple request and the completion coming back. Cleared as soon as
    /// it is used, so one nonce can never serve two authorizations.
    private var pendingRawNonce: String?
    private var nonceEncoding: NonceEncoding
    private var revocationObserver: (any NSObjectProtocol)?

    init(config: SupabaseConfig? = SupabaseConfig.load(),
         defaults: UserDefaults = .standard,
         isRelease: Bool = AuthService.isReleaseBuild) {
        self.defaults = defaults
        self.isRelease = isRelease
        self.nonceEncoding = NonceEncoding.load(defaults: defaults)
        // A local first, then the property: `self` cannot be read until every stored property has
        // a value, and `client` is assigned below.
        let storage = KeychainSessionStorage()
        self.sessionStorage = storage
        if let config {
            client = SupabaseClient(
                supabaseURL: config.url,
                supabaseKey: config.anonKey,
                options: SupabaseClientOptions(
                    db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                    // storageKey is pinned rather than left to the SDK's internal
                    // `defaultStorageKey`, so the account deletion path can name the item it has to
                    // remove. See Assumptions, "Package and client".
                    auth: .init(storage: storage, storageKey: AuthService.sessionStorageKey)
                )
            )
        } else {
            client = nil
        }
    }

    var isConfigured: Bool { client != nil }

    // MARK: launch

    /// Restores the session the SDK persisted. `currentSession` is read first, and only a
    /// genuinely absent session means signed out: a refresh that fails because the phone is on a
    /// train must not throw the person back to the sign-in screen.
    func restoreSession() async {
        guard let client else {
            state = isRelease ? .misconfigured : .offline
            lifecycle?.configureSync(for: state, client: nil)
            return
        }
        guard let stored = client.auth.currentSession else {
            state = .signedOut
            lifecycle?.configureSync(for: state, client: client)
            return
        }
        do {
            let fresh = try await client.auth.session
            await establish(userID: fresh.user.id, email: fresh.user.email)
        } catch {
            if client.auth.currentSession == nil {
                // The SDK dropped the session: the refresh token really is dead.
                state = .signedOut
                lifecycle?.configureSync(for: state, client: client)
            } else {
                // Network or server trouble with a session still on the phone. Carry on signed in
                // and let the next request refresh lazily.
                await establish(userID: stored.user.id, email: stored.user.email)
            }
        }
        await checkAppleCredentialState()
    }

    // MARK: the one ordered transition

    /// Everything that has to happen between "there is a session" and "the UI may show records",
    /// in the only order that is safe. Internal rather than private so the ordering is testable
    /// without a network.
    func establish(userID: UUID, email: String?) async {
        let owner = StoreOwner.load(defaults: defaults)
        // `?? false` is the fail-closed default. With no lifecycle attached there is no way to ask
        // whether the store holds anything, and "unknown" has to mean "assume it holds someone's
        // records", so an unowned store is reset rather than adopted into this account. `?? true`
        // would silently hand the previous person's data to whoever signs in next.
        let decision = StoreOwnerPolicy.decision(ownerID: owner.userID,
                                                 newUserID: userID,
                                                 storeIsEmpty: lifecycle?.storeIsEmpty() ?? false)
        switch decision {
        case .keep:
            break
        case .claimEmpty:
            var syncState = SyncState.load(defaults: defaults)
            syncState.forgetSyncHistory()
            syncState.save(defaults: defaults)
        case .reset:
            await lifecycle?.cancelSync()
            await lifecycle?.wipeStore()
            SyncState.clear(defaults: defaults)
        }
        // Ownership is recorded before any sync runs, so a crash mid-sync cannot leave rows in a
        // store nobody claims.
        StoreOwner(userID: userID.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        state = .signedIn(userID: userID, email: email)
        lifecycle?.configureSync(for: state, client: client)
    }

    // MARK: sign in

    /// Prepares an authorization request. Returns the digest Apple is given; the raw nonce stays
    /// here. Throws rather than returning a predictable value, so a device that cannot produce
    /// randomness fails the sign-in instead of weakening it.
    func beginSignIn() throws -> String {
        let raw = try Nonce.random()
        pendingRawNonce = raw
        message = nil
        isWorking = true
        return Nonce.digest(raw, encoding: nonceEncoding)
    }

    /// Called when the request could not be prepared. Drops the pending nonce so a completion that
    /// still arrives cannot be exchanged.
    func abortSignIn(message: String) {
        pendingRawNonce = nil
        isWorking = false
        self.message = message
    }

    func signInWithApple(authorization: ASAuthorization) async throws {
        defer { isWorking = false }
        guard let client else { throw AuthError.notConfigured }
        guard let rawNonce = pendingRawNonce else { throw AuthError.nonceUnavailable }
        pendingRawNonce = nil
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
            // Apple's opaque user id is what credential revocation is checked against later.
            defaults.set(credential.user, forKey: AuthService.appleUserIDKey)
            // Apple hands back the email only on the very first authorization, so fall back to it.
            await establish(userID: session.user.id, email: session.user.email ?? credential.email)
        } catch {
            if AuthService.isNonceMismatch(error), let next = nonceEncoding.next {
                nonceEncoding = next
                next.save(defaults: defaults)
                throw AuthError.nonceMismatch
            }
            throw error
        }
    }

    /// The only signal Supabase gives is the message text. Matching on it is crude, but the
    /// consequence of a false positive is one retry with the other digest encoding, which is
    /// harmless, and there is no error code to match on instead.
    static func isNonceMismatch(_ error: any Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("nonce")
    }

    // MARK: sign out and deletion

    /// Local scope: signing out of this phone never kills the person's session on another device.
    /// A refused sign-out leaves the person signed in with a message rather than wiping a store
    /// whose session is still live.
    func signOut() async {
        message = nil
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                message = AuthError.signOutRefused.errorDescription
                return
            }
            guard client.auth.currentSession == nil else {
                message = AuthError.sessionStillPresent.errorDescription
                return
            }
        }
        await lifecycle?.cancelSync()
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    /// Deletes the account server-side and then leaves the phone in a fresh-install state.
    ///
    /// The sign-out is best effort, because once `delete_my_account()` has returned the auth user
    /// is gone and `/logout` answers 401 or 403. What is *not* best effort is the session item:
    /// the SDK's `signOut` returns early without throwing when it finds no access token, and
    /// swallows 401, 403 and 404, so "it did not throw" is not evidence that the keychain is
    /// clean. The item is removed by name and the result is checked, because leaving a dead
    /// session behind means the next launch restores a session for a user that no longer exists.
    func deleteAccount() async throws {
        guard let client else { throw AuthError.notConfigured }
        isWorking = true
        defer { isWorking = false }
        await lifecycle?.cancelSync()
        try await client.rpc(ServerFunctions.deleteMyAccount).execute()
        try? await client.auth.signOut(scope: .local)
        do {
            try sessionStorage.remove(key: AuthService.sessionStorageKey)
        } catch {
            // Nothing can be done about a keychain that refuses a delete, but the person must not
            // be told the account is gone from this phone when its session is not.
            message = AuthError.sessionStillPresent.errorDescription
        }
        // `currentSession` reads straight from storage with no in-memory cache, so this is a real
        // check and not a formality.
        if client.auth.currentSession != nil {
            message = AuthError.sessionStillPresent.errorDescription
        }
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    /// Leaves DEBUG offline mode. The offline data is discarded: nobody owns it, and adopting it
    /// into the next account is exactly what `StoreOwnerPolicy` refuses to do.
    func leaveOfflineMode() async {
        await lifecycle?.cancelSync()
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    #if DEBUG
    /// Simulator and review builds: reach the tabs without an Apple account.
    func continueOffline() {
        state = .offline
        lifecycle?.configureSync(for: state, client: client)
    }
    #endif

    // MARK: Apple credential revocation

    /// Called once by the app at launch. Never torn down: AuthService lives for the whole process.
    func startWatchingAppleCredential() {
        guard revocationObserver == nil else { return }
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.signOut()
            }
        }
    }

    /// Asks Apple whether the person has revoked this app's access since last launch.
    ///
    /// **Only `.revoked` signs out.** `.revoked` is an unambiguous decision the person made in iOS
    /// Settings. Nothing else is. `.notFound` is what the API also returns when the Apple ID signed
    /// in on the device is not the one this id belongs to, which covers switching Apple IDs, a
    /// restored device, and, per the API contract, the error path; `.transferred` means the app was
    /// transferred between developer accounts and the credential has to be migrated, not destroyed.
    /// A thrown or returned error means "could not determine", and the only safe response to "could
    /// not determine" is to do nothing: the next authenticated request will find out for certain,
    /// and it cannot delete anything. Acting on the ambiguous cases would buy signing out slightly
    /// sooner and would cost an irreversible local wipe (verification defect D-D8).
    func checkAppleCredentialState() async {
        guard case .signedIn = state,
              let appleUserID = defaults.string(forKey: AuthService.appleUserIDKey) else { return }
        let (credentialState, error) = await credentialStateProbe(appleUserID)
        if let error {
            // Could not determine. Leave the session and the store exactly as they are.
            message = nil
            AuthService.log("credential state undetermined for this Apple id: \(error.localizedDescription)")
            return
        }
        switch credentialState {
        case .revoked:
            await signOut()
        case .notFound, .transferred:
            AuthService.log("credential state \(credentialState.rawValue) is not a revocation; leaving the session and the store alone")
        default:
            break
        }
    }

    /// Seam for the test. Defaults to the real provider; `AuthServiceTests` substitutes a closure
    /// so the ambiguous outcomes can be driven without an Apple ID.
    var credentialStateProbe: (String) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?)
        = AuthService.realCredentialState

    private static func realCredentialState(
        forUserID userID: String
    ) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?) {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { credentialState, error in
                continuation.resume(returning: (credentialState, error))
            }
        }
    }

    /// One place for the two diagnostic lines above. Deliberately not `os_log`: nothing in this
    /// file may write an identity token, a session or an Apple user id to a log, and a single
    /// funnel makes that reviewable.
    private static func log(_ line: String) {
        #if DEBUG
        print("[auth] \(line)")
        #endif
    }
}
```

`credentialStateProbe` is a stored `var` on a `@MainActor` class, so assigning it from a test is
main-actor isolated like everything else on `AuthService`. It is not `private`, so `@testable
import` reaches it; it has a real default, so no production call site changes.

The `credentialRevokedNotification` observer in `startWatchingAppleCredential()` keeps calling
`signOut()` unchanged. That notification fires only on an actual revocation, so it carries none of
the ambiguity `.notFound` does.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `AuthServiceTests` twenty-two cases are green, and nothing in them touches the network.

Correction if `testSigningInAsTheSameUserKeepsTheStore` fails on the `configureSync` payload string: `String(describing:)` of an enum with associated values is compiler-formatted and can differ between toolchains. Replace that one assertion with a shape check:
```swift
        XCTAssertEqual(lifecycle.events.count, 1)
        guard case .configureSync = lifecycle.events[0] else { return XCTFail("expected configureSync") }
```

- [ ] **Step 6: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Auth/AuthService.swift AppTests/AuthServiceTests.swift
git commit -m "feat(auth): AuthService drives one ordered sign-in, ownership and sign-out transition

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Store lifecycle, root gating, the sign-in screen, and the Settings Account section

**Files:**
- Modify: `App/Persistence/PersistenceController.swift` (add `storeURLs(url:)` and `destroyIncludingRecoveredCopies(url:)`)
- Modify: `App/Media/MediaStore.swift` (add `removeAll() throws` to the protocol and to `InMemoryMediaStore`)
- Modify: `App/Media/FileMediaStore.swift` (implement `removeAll() throws`)
- Create: `App/Persistence/AppStoreLifecycle.swift`
- Create: `App/Views/Auth/RootView.swift`
- Create: `App/Views/Auth/SignInView.swift`
- Modify: `App/AnimalTrackerApp.swift` (whole file replaced)
- Modify: `App/Views/Settings/SettingsView.swift` (add `@EnvironmentObject` and the Account section, change the About copy at line 45)
- Create: `AppTests/RootGateTests.swift`
- Create: `AppTests/ContainerResetTests.swift`

**Interfaces:**
- Consumes: `AuthState`, `AuthService`, `StoreLifecycle`, `AuthError` (Task 4); `Nonce` (Task 3); `RootTabView`, `PersistenceController`, `Seeds`, `FileMediaStore`, `MediaStore` (Plan A); `VoiceTagSeed`, `VoiceRecording`, `Vocalization`, `VoiceTag` (Plan B Task 13).
- Produces:
  - `PersistenceController.storeURLs(url: URL? = nil) -> [URL]` and `PersistenceController.destroyIncludingRecoveredCopies(url: URL? = nil)`.
  - `MediaStore.removeAll() throws`, implemented on `FileMediaStore` (remove `root` and recreate it) and on `InMemoryMediaStore` (clear the dictionary and the temp directory). This is the bulk removal `wipeStore()` needs: the protocol previously had only per-file `delete(_:)`, so there was no API that could empty the directory even if the wipe had wanted to (verification defect D-D6).
  - `@MainActor protocol SyncCoordinating: AnyObject { func cancelSync() async; func attach(container: ModelContainer, mediaStore: MediaStore); func update(for state: AuthState, client: SupabaseClient?); func pushBeforeSignOut(timeout: TimeInterval) async -> Bool; func unsyncedRowCount() -> Int }`. The last two are what the sign-out confirmation needs (verification defect D-D7); Task 11's `SyncService` implements them.
  - `@MainActor final class AppStoreLifecycle: ObservableObject, StoreLifecycle` with `init(container: ModelContainer, recovered: Bool, mediaStore: MediaStore = FileMediaStore(), storeURL: URL? = nil)`, `@Published private(set) var container: ModelContainer`, `@Published private(set) var generation: Int`, `let recovered: Bool`, `var sync: (any SyncCoordinating)?`.
  - `enum RootScreen: Equatable { case loading, signIn, blocked, main(showsOfflineBanner: Bool) }`, `enum RootGate { static func screen(for state: AuthState) -> RootScreen }`, `struct RootView: View`, `struct OfflineBanner: View`, `struct MisconfiguredView: View`, `struct SignInView: View`.

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

    /// Fail closed. A build with no anon key must never reach `RootTabView`.
    func testMisconfiguredIsBlockedAndIsNeverTheTabs() {
        XCTAssertEqual(RootGate.screen(for: .misconfigured), .blocked)
        XCTAssertNotEqual(RootGate.screen(for: .misconfigured), .main(showsOfflineBanner: true))
        XCTAssertNotEqual(RootGate.screen(for: .misconfigured), .main(showsOfflineBanner: false))
    }

    /// The scripted walk a real session takes: launch, restore fails, sign in, sign out.
    func testScriptedStateSequence() {
        let userID = UUID()
        let script: [AuthState] = [.unknown, .signedOut, .signedIn(userID: userID, email: nil), .signedOut]
        XCTAssertEqual(script.map(RootGate.screen(for:)),
                       [.loading, .signIn, .main(showsOfflineBanner: false), .signIn])
    }

    /// Five states, five distinct screens: loading, signIn, main(false), main(true), blocked.
    /// Counting four, as v2 did, would let `.misconfigured` collapse onto one of the others and
    /// still pass, which is the one collapse that must never happen.
    func testEveryStateMapsToItsOwnScreen() {
        let all: [AuthState] = [.unknown, .signedOut, .signedIn(userID: UUID(), email: nil), .offline, .misconfigured]
        let screens = all.map(RootGate.screen(for:))
        XCTAssertEqual(screens, [.loading, .signIn, .main(showsOfflineBanner: false),
                                 .main(showsOfflineBanner: true), .blocked])
        XCTAssertEqual(Set(screens.map { String(describing: $0) }).count, 5)
    }
}
```

Create `AppTests/ContainerResetTests.swift`. Every case works on its own temporary store url, so nothing here can destroy the simulator's real store or leave the next test with a surprise:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ContainerResetTests: XCTestCase {
    /// Containers do not keep themselves alive and a ModelContext does not retain its container.
    private var retained: [ModelContainer] = []

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    private func makeDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func testStoreURLsAreTheStoreAndItsTwoSidecars() {
        let url = tempStoreURL()
        let names = PersistenceController.storeURLs(url: url).map(\.lastPathComponent)
        XCTAssertEqual(names, ["default.store", "default.store-shm", "default.store-wal"])
    }

    func testDestroyIncludingRecoveredCopiesRemovesTheCorruptCopiesToo() throws {
        let url = tempStoreURL()
        let directory = url.deletingLastPathComponent()
        try makeDirectory(for: url)
        let container = try PersistenceController.makeContainer(url: url)
        retained.append(container)
        container.mainContext.insert(Animal(name: "Pip", species: "cat"))
        try container.mainContext.save()

        // What `moveAside` leaves behind after a recovery. These are a full copy of the previous
        // person's records, so a sign-out wipe has to take them as well.
        try Data("old".utf8).write(to: directory.appending(path: "default.store.corrupt-1750000000"))
        try Data("old".utf8).write(to: directory.appending(path: "default.store-wal.corrupt-1750000000"))

        PersistenceController.destroyIncludingRecoveredCopies(url: url)

        // Assert what this method is for rather than total emptiness. The container opened above is
        // deliberately still retained (so SwiftData does not trap), and a retained SQLite
        // connection on an unlinked inode is free to recreate `default.store-wal` or `-shm` on a
        // checkpoint between the unlink and this listing. Asserting an empty directory would make
        // the case fail intermittently with a message about the wrong subject (C-D9).
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(left.allSatisfy { !$0.contains(".corrupt-") }, "recovered copies left behind: \(left)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the store itself is gone")
    }

    func testWipingRebuildsAnEmptyStoreThatStillHasTheBuiltInTags() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)
        _ = try? VoiceTagSeed.seedIfNeeded(context: opened.container.mainContext)
        opened.container.mainContext.insert(Animal(name: "Miso", species: "cat"))
        try opened.container.mainContext.save()

        // A real FileMediaStore on its own temporary root, so the media half of the wipe is
        // exercised against the filesystem rather than a dictionary (verification defect D-D6).
        let mediaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        let media = FileMediaStore(root: mediaRoot)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: source)
        let audioName = try media.saveAudio(from: source)
        XCTAssertTrue(media.exists(audioName), "the fixture is really on disk before the wipe")

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: opened.recovered,
                                          mediaStore: media, storeURL: url)
        XCTAssertFalse(lifecycle.storeIsEmpty(), "an animal makes the store non-empty")

        await lifecycle.wipeStore()
        retained.append(lifecycle.container)

        XCTAssertFalse(media.exists(audioName), "the audio file goes with the store")
        let leftInMedia = try FileManager.default.contentsOfDirectory(atPath: mediaRoot.path)
        XCTAssertEqual(leftInMedia, [], "the media directory is empty after a wipe, left: \(leftInMedia)")

        XCTAssertEqual(try lifecycle.container.mainContext.fetch(FetchDescriptor<Animal>()).count, 0)
        XCTAssertTrue(lifecycle.storeIsEmpty())
        XCTAssertEqual(lifecycle.generation, 1)
        let tags = try lifecycle.container.mainContext.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.count, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count,
                       "a wiped store is re-seeded, and re-seeded exactly once")
        XCTAssertEqual(tags.first { $0.kind == .meaning && $0.name == "Hungry" }?.id,
                       VoiceTagSeed.builtInID(kind: .meaning, name: "Hungry"),
                       "with the same ids as before the wipe, so a later pull merges rather than doubles")
    }

    /// "Empty" has to mean "no records the person made". The built-in tags are always there, so a
    /// store that only holds them is still a fresh store, and a fresh install must not be wiped.
    func testAStoreHoldingOnlyBuiltInTagsCountsAsEmpty() throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)
        _ = try? VoiceTagSeed.seedIfNeeded(context: opened.container.mainContext)

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: opened.recovered,
                                          mediaStore: InMemoryMediaStore(), storeURL: url)
        XCTAssertTrue(lifecycle.storeIsEmpty())

        opened.container.mainContext.insert(VoiceTag(kind: .meaning, name: "Ash's own tag"))
        try opened.container.mainContext.save()
        XCTAssertFalse(lifecycle.storeIsEmpty(), "a tag the person added is their data")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'RootGate' in scope`, `cannot find 'AppStoreLifecycle' in scope` and `type 'PersistenceController' has no member 'storeURLs'`.

- [ ] **Step 3: Add the two store helpers and the media bulk removal**

`App/Persistence/PersistenceController.swift` on the branch already has `storeURL`, the private `sidecars(of:)`, `makeContainer(inMemory:url:)`, `destroy(url:)` and the tuple-returning `makeContainerWithRecovery(url:)`. Leave every one of those exactly as it is. Add these two members inside `enum PersistenceController`, after `destroy(url:)`:

```swift
    /// The store file and its two sidecars. Public so a test can assert a wipe left nothing.
    static func storeURLs(url: URL? = nil) -> [URL] {
        sidecars(of: url ?? storeURL)
    }

    /// `destroy` plus every `<name>.corrupt-<timestamp>` copy `moveAside` left behind. Sign-out and
    /// a user change have to use this one: a recovered copy is a complete copy of the previous
    /// person's records sitting next to the live store.
    static func destroyIncludingRecoveredCopies(url: URL? = nil) {
        let target = url ?? storeURL
        destroy(url: target)
        let directory = target.deletingLastPathComponent()
        let base = target.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(base) && name.contains(".corrupt-") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
```

Destroying the SwiftData store is only half of a wipe. `FileMediaStore` keeps every recording,
photo, thumbnail and video under `Documents/Media/`, and `project.yml` sets `UIFileSharingEnabled`
and `LSSupportsOpeningDocumentsInPlace`, so that folder is browsable in the Files app. A wipe that
leaves it standing means the next person to sign in on the phone can play the previous person's
recordings, and "Delete account" tells someone their data is gone while it is still on the device
(verification defect D-D6). Add a bulk removal to the media layer.

In `App/Media/MediaStore.swift`, add one requirement to the protocol, after `delete(_:)`:
```swift
    /// Removes every file the store holds. Used only by the whole-store wipe that runs when
    /// ownership changes or an account is deleted; per-row deletion goes through `delete(_:)`.
    func removeAll() throws
```

and implement it on `InMemoryMediaStore`, next to `delete(_:)`:
```swift
    func removeAll() throws {
        files.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }
```

In `App/Media/FileMediaStore.swift`, implement it next to `delete(_:)`. Removing the directory and
recreating it keeps the implementation inside the store's own `root` and cannot reach anything else
in `Documents/`:
```swift
    func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: root)
        } catch CocoaError.fileNoSuchFile {
            // Already gone. Recreating below is still the right end state.
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
```

- [ ] **Step 4: Write the store lifecycle**

Create `App/Persistence/AppStoreLifecycle.swift`:
```swift
import Foundation
import SwiftData
import Supabase

/// What the store lifecycle needs from sync. Declared here rather than in `SyncService` so the
/// lifecycle can be built and tested before sync exists; Task 11's `SyncService` conforms to it and
/// the app assigns it to `AppStoreLifecycle.sync` at launch.
@MainActor
protocol SyncCoordinating: AnyObject {
    /// Stops the running sync and does not return until it has actually stopped.
    func cancelSync() async
    /// Points sync at the live container.
    func attach(container: ModelContainer, mediaStore: MediaStore)
    /// Points sync at this auth state's user and client, or at nothing.
    func update(for state: AuthState, client: SupabaseClient?)
    /// One last push before the store is destroyed. Returns true only when the cycle finished and
    /// left nothing outstanding; false on any failure, on cancellation, and on the timeout.
    /// Bounded so a dead network cannot leave the person staring at a spinner on a sign-out.
    func pushBeforeSignOut(timeout: TimeInterval) async -> Bool
    /// Rows whose `updatedAt` is newer than their table's push watermark, plus unpushed
    /// tombstones. What the second sign-out confirmation puts a number to.
    func unsyncedRowCount() -> Int
}

/// Owns the live `ModelContainer` and replaces it when the store has to be thrown away.
/// `AuthService` drives it through `StoreLifecycle`; the app observes `generation` so every
/// `@Query` re-subscribes to the new container.
@MainActor
final class AppStoreLifecycle: ObservableObject, StoreLifecycle {
    @Published private(set) var container: ModelContainer
    /// Bumped with the container, used as the tab content's `.id(...)`.
    @Published private(set) var generation = 0
    /// True when even the recovery path failed and this launch is on a temporary store.
    let recovered: Bool

    /// Set by the app once `SyncService` exists. Nil is a valid state: before Task 11 there is no
    /// sync, and a wipe still has to work.
    var sync: (any SyncCoordinating)?

    private let mediaStore: MediaStore
    private let storeURL: URL?

    init(container: ModelContainer,
         recovered: Bool,
         mediaStore: MediaStore = FileMediaStore(),
         storeURL: URL? = nil) {
        self.container = container
        self.recovered = recovered
        self.mediaStore = mediaStore
        self.storeURL = storeURL
    }

    // MARK: StoreLifecycle

    func cancelSync() async {
        await sync?.cancelSync()
    }

    /// "Empty" means no records the person made. The built-in voice tags are seeded on every
    /// launch, so a store holding only those is still a fresh store; counting them would make
    /// every fresh install look like data worth refusing to adopt.
    func storeIsEmpty() -> Bool {
        let context = container.mainContext
        let animals = (try? context.fetchCount(FetchDescriptor<Animal>())) ?? 0
        let recordings = (try? context.fetchCount(FetchDescriptor<VoiceRecording>())) ?? 0
        let vocalizations = (try? context.fetchCount(FetchDescriptor<Vocalization>())) ?? 0
        let ownTags = ((try? context.fetch(FetchDescriptor<VoiceTag>())) ?? []).filter { !$0.isBuiltIn }.count
        return animals == 0 && recordings == 0 && vocalizations == 0 && ownTags == 0
    }

    func wipeStore() async {
        // Belt and braces: AuthService already cancelled, but a wipe must never race a writer.
        await sync?.cancelSync()
        PersistenceController.destroyIncludingRecoveredCopies(url: storeURL)
        // The rows are only half the person's data. Documents/Media/ holds the audio, the photos,
        // the thumbnails and the videos, and file sharing makes that folder browsable in the Files
        // app, so leaving it behind would show the previous person's recordings to the next one and
        // would make "Delete account" a lie on the device (verification defect D-D6). `try?`: a
        // wipe that cannot reopen the store is a worse failure than one file that would not unlink,
        // and the directory is recreated by `removeAll` either way.
        try? mediaStore.removeAll()
        let opened = PersistenceController.makeContainerWithRecovery(url: storeURL)
        container = opened.container
        generation += 1
        // `Seeds.runAll` runs every entry of `Seeds.all`, including `VoiceTagSeed.run`, which
        // seeds on every call: Plan B's fix wave removed
        // the once-per-install UserDefaults guard precisely so a store recreated after a wipe still
        // gets its built-in tags. The ids are deterministic, so a later pull of the same tags merges
        // onto these rows instead of doubling them.
        Seeds.runAll(context: container.mainContext)
        sync?.attach(container: container, mediaStore: mediaStore)
    }

    func configureSync(for state: AuthState, client: SupabaseClient?) {
        sync?.update(for: state, client: client)
    }
}
```

- [ ] **Step 5: Write the root gate and its screens**

Create `App/Views/Auth/RootView.swift`:
```swift
import SwiftUI

/// What the root shows. Kept separate from the view so the gating rule is unit-testable.
enum RootScreen: Equatable {
    case loading
    case signIn
    /// A build with no usable anon key. Never the tabs.
    case blocked
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
        case .misconfigured:
            return .blocked
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: AppStoreLifecycle

    var body: some View {
        Group {
            switch RootGate.screen(for: auth.state) {
            case .loading:
                ProgressView("Loading")
            case .signIn:
                SignInView()
            case .blocked:
                MisconfiguredView()
            case .main(let showsOfflineBanner):
                VStack(spacing: 0) {
                    if store.recovered {
                        Text("The data store could not be opened. Running with a temporary store; export your data if this persists.")
                            .font(.footnote)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.yellow)
                    }
                    if showsOfflineBanner { OfflineBanner() }
                    RootTabView()
                }
                // Only the tab content carries the generation identity. Putting it on RootView
                // itself would re-run the `.task` below after every wipe.
                .id(store.generation)
            }
        }
        .task {
            // Everything the session restore depends on is wired here, in this order, one line
            // before the restore itself. v2 set `auth.lifecycle` in the App-level `.task` and
            // called `restoreSession()` here, betting that a parent's task body runs before its
            // child's. SwiftUI does not promise that, and losing the bet means `restoreSession()`
            // decides store ownership with no lifecycle: it cannot ask whether the store is empty,
            // and it cannot cancel or wipe. There is no ordering left to get wrong if the wiring
            // and the restore are statements in one function.
            auth.lifecycle = store
            auth.startWatchingAppleCredential()
            await auth.restoreSession()
        }
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

/// The fail-closed screen. A release build that shipped without an anon key shows this and nothing
/// else: no tabs, no offline mode, no way to write records that could never be backed up.
struct MisconfiguredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("This build is not configured")
                .font(.title2.bold())
            Text("AnimalTracker was built without its Supabase key, so it cannot sign in or back anything up. Install a build from the App Store or from TestFlight.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityIdentifier("misconfiguredScreen")
    }
}
```

- [ ] **Step 6: Write the sign-in screen**

Create `App/Views/Auth/SignInView.swift`. The nonce lives in `AuthService`, not in this view, and a request that cannot be prepared aborts the sign-in rather than proceeding without one:
```swift
import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

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
                request.requestedScopes = [.email]
                do {
                    // Apple gets the digest; the raw nonce stays inside AuthService.
                    request.nonce = try auth.beginSignIn()
                } catch {
                    auth.abortSignIn(message: "Could not start sign-in securely on this device. Try again.")
                }
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .disabled(auth.isWorking || !auth.isConfigured)
            if let message = auth.message {
                Text(message)
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

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            Task {
                do {
                    try await auth.signInWithApple(authorization: authorization)
                } catch {
                    auth.message = (error as? LocalizedError)?.errorDescription
                        ?? "Could not sign in. Try again."
                }
            }
        case .failure(let error):
            // A cancel is not an error worth shouting about, but the pending nonce still has to go.
            if (error as? ASAuthorizationError)?.code == .canceled {
                auth.abortSignIn(message: "")
                auth.message = nil
            } else {
                auth.abortSignIn(message: "Could not sign in. Try again.")
            }
        }
    }
}
```

`auth.message` is settable from the view because it is `@Published var`, not `private(set)`; every other published property on `AuthService` stays read-only from outside.

- [ ] **Step 7: Replace the app entry point**

Replace the whole of `App/AnimalTrackerApp.swift`:
```swift
import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    @StateObject private var store: AppStoreLifecycle
    @StateObject private var auth = AuthService()

    init() {
        // Never fatalError at launch: an unopenable store must still give the user a working app.
        let opened = PersistenceController.makeContainerWithRecovery()
        Seeds.runAll(context: opened.container.mainContext)
        _store = StateObject(wrappedValue: AppStoreLifecycle(container: opened.container,
                                                             recovered: opened.recovered))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
                .modelContainer(store.container)
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

There is deliberately no `.task` on the `WindowGroup` content any more. Every piece of auth wiring lives in `RootView`'s own `.task`, immediately before `restoreSession()`, so nothing depends on the order SwiftUI happens to run a parent's task body against a child's. Task 11 Step 6 adds the scene-phase handler and the sync attach to those same two places, and nowhere else.

- [ ] **Step 8: Add the Account section to Settings**

In `App/Views/Settings/SettingsView.swift`, add two properties after line 4 (`@Environment(\.dismiss) private var dismiss`):
```swift
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: AppStoreLifecycle
```

and add these state properties after line 9 (`@State private var keyMessage: String?`):
```swift
    @State private var showLeaveOfflineConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showUnsyncedSignOutConfirmation = false
    @State private var unsyncedCount = 0
    @State private var isSigningOut = false
```

**Every `.confirmationDialog` goes on its own view.** Two presentation modifiers of the same kind
stacked on one view is a long-standing SwiftUI limitation: the inner one is generally swallowed and
only one ever presents, and no test in this plan could see it (verification defect C-D4). So each
dialog is attached to the single row that raises it, never to the enclosing `Section`. Task 11
Step 7 adds a fourth dialog and follows the same rule.

Insert this section as the first section inside `Form { ... }`, immediately before the existing `Section("Animals")` at line 13:
```swift
            Section("Account") {
                switch auth.state {
                case .signedIn(let userID, let email):
                    LabeledContent("Signed in as", value: email ?? userID.uuidString)
                        // Dialog 2 of the sign-out flow, on its own host view so it is never
                        // stacked on the same view as dialog 1.
                        .confirmationDialog("\(unsyncedCount) record\(unsyncedCount == 1 ? "" : "s") could not be backed up",
                                            isPresented: $showUnsyncedSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button("Sign out anyway", role: .destructive) {
                                Task { await auth.signOut() }
                            }
                            Button("Stay signed in", role: .cancel) {}
                        } message: {
                            Text("Signing out deletes everything on this phone, including those \(unsyncedCount). They are not on the server, so they cannot be downloaded again.")
                        }
                    Button("Sign out", role: .destructive) { showSignOutConfirmation = true }
                        .disabled(isSigningOut)
                        // Dialog 1 of the sign-out flow.
                        .confirmationDialog("Sign out of this account?",
                                            isPresented: $showSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button("Back up and sign out") {
                                Task { await backUpThenSignOut() }
                            }
                            Button("Stay signed in", role: .cancel) {}
                        } message: {
                            Text("Signing out deletes the records on this phone. Anything already backed up is downloaded again next time you sign in.")
                        }
                case .offline:
                    Text("Offline. Records stay on this phone and are not backed up.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // The only state that offers to leave offline mode, and only behind the
                    // confirmation below, because leaving discards the offline records.
                    Button("Sign in") { showLeaveOfflineConfirmation = true }
                        .confirmationDialog("Leaving offline mode deletes the records on this phone",
                                            isPresented: $showLeaveOfflineConfirmation,
                                            titleVisibility: .visible) {
                            Button("Delete and sign in", role: .destructive) {
                                Task { await auth.leaveOfflineMode() }
                            }
                            Button("Stay offline", role: .cancel) {}
                        } message: {
                            Text("Offline records belong to no account, so they are not carried into the one you sign in to.")
                        }
                case .signedOut, .unknown:
                    // Unreachable in practice: RootGate shows the sign-in screen or the loading
                    // screen for these, never the tabs, so Settings is not on screen. Rendered as
                    // text rather than a button on purpose. v2 wired a "Sign in" button here to
                    // `leaveOfflineMode()`, which wipes the store; firing that from a state that
                    // never created offline data would destroy a signed-in person's records
                    // between a sign-out and the next screen.
                    Text("Not signed in.").font(.footnote).foregroundStyle(.secondary)
                case .misconfigured:
                    Text("This build has no Supabase key, so it cannot sign in or back anything up.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let message = auth.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
```

and add the helper below `body`, in the same `struct SettingsView`:
```swift
    /// Sign out is the one ordinary setting that destroys data, and everything created since the
    /// last successful push exists only on this phone. So: push first, and only warn if that push
    /// did not clear the backlog (verification defect D-D7).
    ///
    /// The timeout is what keeps this honest. A dead network would otherwise hang the sign-out on
    /// an engine retry, and a person who has decided to sign out will force-quit instead, which
    /// loses exactly the records this is trying to save.
    @MainActor
    private func backUpThenSignOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        let pushed = await store.sync?.pushBeforeSignOut(timeout: 20) ?? true
        let outstanding = store.sync?.unsyncedRowCount() ?? 0
        if pushed && outstanding == 0 {
            await auth.signOut()
            return
        }
        // Failed, timed out, or finished with rows still behind the watermark. Name the number and
        // make the person confirm a second time before anything is destroyed.
        unsyncedCount = outstanding
        showUnsyncedSignOutConfirmation = true
    }
```

`store.sync` is nil until Task 11 Step 6 assigns `SyncService.shared` to it. `?? true` on the push
and `?? 0` on the count make that case behave as "there is no sync, so there is nothing outstanding
and nothing to wait for", which is the correct reading of a build that has not reached Task 11 yet.

`SettingsView` is presented as a sheet from `App/AnimalSwitcher.swift:61`, and a sheet inherits the presenter's environment, so the `.environmentObject(auth)` and `.environmentObject(store)` applied in Step 7 both reach it with no extra wiring.

Also change the About copy at line 45 from

```swift
                Text("All records and media stay on this phone. Only oral check-in transcripts are sent to Anthropic, using your own key.")
```

to

```swift
                Text("Animals, voice recordings and tags sync to your Supabase account. Oral check-in transcripts are sent to Anthropic, using your own key.")
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `RootGateTests` eight cases and `ContainerResetTests` four cases are green, and every earlier test still passes.

Correction if `testWipingRebuildsAnEmptyStoreThatStillHasTheBuiltInTags` reports no tags at all: `wipeStore()` is not calling `Seeds.runAll` on the new container, or `VoiceTagSeed.run` has regained a once-per-install guard. It must seed on every call.

- [ ] **Step 10: See it on the simulator**

Run: `scripts/run-sim.sh`
Expected: `build/screenshot.png` shows the sign-in screen with the Sign in with Apple button and, below it, "Continue offline". With the real anon key committed (Task 1 Step 4) `SupabaseConfig.load()` succeeds, there is no stored session on a fresh simulator, and `RootGate` returns `.signIn`.

Correction if the screenshot shows the tabs with an orange banner: the plist still holds the placeholder, so `restoreSession()` took the DEBUG offline branch. Go back to Task 1 Step 4.

- [ ] **Step 11: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Persistence/PersistenceController.swift App/Persistence/AppStoreLifecycle.swift \
        App/Media/MediaStore.swift App/Media/FileMediaStore.swift \
        App/Views/Auth/RootView.swift App/Views/Auth/SignInView.swift App/AnimalTrackerApp.swift \
        App/Views/Settings/SettingsView.swift AppTests/RootGateTests.swift AppTests/ContainerResetTests.swift
git commit -m "feat(auth): gate the tabs behind Sign in with Apple, block a Release build with no key

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The SQL migration, server-side last-write-wins, account deletion, and a test that the migration says what it must

**Files:**
- Create: `supabase/config.toml`
- Create: `supabase/migrations/20260919120000_voice_milestone.sql`
- Create: `AppTests/MigrationFileTests.swift`
- Modify: `README.md` (how to apply the migration)

**Interfaces:**
- Consumes: nothing from earlier tasks. The table and column names here are what Task 8's row structs encode to.
- Produces: tables `public.animals`, `public.voice_recordings`, `public.vocalizations`, `public.voice_tags`, each with `server_updated_at` and a `before insert or update` guard trigger; the private storage bucket `voice-audio` with a size limit and a mime allow-list; `public.delete_my_account()`.

- [ ] **Step 1: Write the failing test**

The migration ships into the test bundle as a resource (Task 1 already added `supabase/migrations` to the test target), so the test reads the real file rather than a copy.

Create `AppTests/MigrationFileTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class MigrationFileTests: XCTestCase {
    private static let tables = ["public.animals", "public.voice_recordings",
                                 "public.vocalizations", "public.voice_tags"]

    /// Returns the migration with every `--` comment line removed, lowercased.
    ///
    /// The comments have to go before anything is counted. The file explains itself in prose that
    /// quotes the SQL it is about, so a line like "-- ... scoped to authenticated callers, and
    /// `(select auth.uid())` so the uid is evaluated once per statement" contributes one phantom
    /// "to authenticated" and one phantom "(select auth.uid())". v2 counted the raw text and got
    /// 22 and 26 where the policies actually number 21 and 25. Rewording the comment would fix
    /// today's count and break again the next time someone explains the file; stripping the
    /// comments fixes it once. Every count below is over SQL, never over prose.
    private func migrationSQL() throws -> String {
        let bundle = Bundle(for: MigrationFileTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "20260919120000_voice_milestone", withExtension: "sql"),
                                "the migration is not in the test bundle; check project.yml")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
            .lowercased()
    }

    private func count(_ needle: String, in sql: String) -> Int {
        sql.components(separatedBy: needle).count - 1
    }

    /// The helper is load-bearing for nine of the counts below, so it gets its own test rather
    /// than being trusted.
    func testTheHelperDropsCommentLines() throws {
        let sql = try migrationSQL()
        XCTAssertFalse(sql.contains("--"), "no comment line survived the strip")
        XCTAssertTrue(sql.contains("create table if not exists public.animals"), "the SQL itself survived")
        let raw = try String(contentsOf: XCTUnwrap(Bundle(for: MigrationFileTests.self)
            .url(forResource: "20260919120000_voice_milestone", withExtension: "sql")), encoding: .utf8).lowercased()
        XCTAssertGreaterThan(count("to authenticated", in: raw), count("to authenticated", in: sql),
                             "the comments really do quote the SQL; that is why they are stripped")
    }

    // MARK: tables and columns

    func testCreatesTheFourTables() throws {
        let sql = try migrationSQL()
        for table in Self.tables {
            XCTAssertTrue(sql.contains("create table if not exists \(table)"), "missing create table for \(table)")
        }
    }

    func testEveryTableIsOwnedByAUserWithCascadingDeleteAndAnOwnerDefault() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("user_id uuid not null default auth.uid() references auth.users(id) on delete cascade", in: sql), 4,
                       "user_id must default to auth.uid() so a row can never be inserted for someone else by omission")
    }

    func testEveryTableCarriesTheThreeSyncColumns() throws {
        let sql = try migrationSQL()
        // The leading spaces matter: "server_updated_at timestamptz ..." contains the other
        // string, so an unanchored count would report eight.
        XCTAssertEqual(count("    updated_at timestamptz not null default now()", in: sql), 4)
        XCTAssertEqual(count("    server_updated_at timestamptz not null default now()", in: sql), 4)
        XCTAssertEqual(count("deleted_at timestamptz,", in: sql), 4)
    }

    func testIndexesCoverBothThePushAndThePullCursor() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("(user_id, updated_at)", in: sql), 4, "push side")
        XCTAssertEqual(count("(user_id, server_updated_at, id)", in: sql), 4, "pull cursor, ordered and tie-broken by id")
    }

    // MARK: row level security

    func testEnablesRowLevelSecurityOnEveryTable() throws {
        XCTAssertEqual(count("enable row level security", in: try migrationSQL()), 4)
    }

    /// Sixteen table policies: four tables times select, insert, update, delete.
    func testEveryTableHasAPolicyForEveryVerbScopedToAuthenticated() throws {
        let sql = try migrationSQL()
        for table in Self.tables {
            for verb in ["for select", "for insert", "for update", "for delete"] {
                XCTAssertTrue(sql.contains("on \(table) \(verb) to authenticated"),
                              "missing a '\(verb) to authenticated' policy on \(table)")
            }
        }
    }

    func testThereAreExactlySixteenTableAndFourStoragePolicies() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("create policy", in: sql), 20)
        XCTAssertEqual(count("on storage.objects for", in: sql), 4)
        XCTAssertEqual(count("to authenticated", in: sql), 21,
                       "twenty policies plus the grant on delete_my_account()")
    }

    /// `(select auth.uid())` is evaluated once per statement instead of once per row, which is the
    /// difference between a fast policy and a sequential scan on a large table.
    func testPoliciesUseTheSubselectFormOfAuthUid() throws {
        let sql = try migrationSQL()
        // Five per table (select, insert, update using, update with check, delete) across four
        // tables, plus the same five across the four storage policies.
        XCTAssertEqual(count("(select auth.uid())", in: sql), 25,
                       "every using and with check clause on the sixteen table policies plus the four storage ones")
        XCTAssertFalse(sql.contains("using (user_id = auth.uid())"),
                       "the bare per-row form must not be used in a policy")
    }

    /// A `using` clause alone lets a row be written into someone else's name. Every insert and
    /// every update needs a `with check` too.
    func testInsertAndUpdatePoliciesCarryWithCheck() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("with check", in: sql), 10,
                       "four table inserts, four table updates, one storage insert, one storage update")
    }

    // MARK: server-side last write wins

    func testEveryTableHasTheGuardTrigger() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("create or replace function public.sync_row_guard()"))
        XCTAssertEqual(count("before insert or update on public.", in: sql), 4)
        XCTAssertEqual(count("execute function public.sync_row_guard()", in: sql), 4)
    }

    func testTheGuardRejectsAStaleUpdateAndKeepsDeletedAtSticky() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("if new.updated_at <= old.updated_at then"),
                      "an older or equal device timestamp must not overwrite a newer row")
        XCTAssertTrue(sql.contains("new.deleted_at := coalesce(old.deleted_at, new.deleted_at)"),
                      "a delete is permanent; a later edit must not resurrect the row")
        XCTAssertTrue(sql.contains("new.server_updated_at := now()"),
                      "the pull cursor column is the server's to set, never the device's")
        XCTAssertTrue(sql.contains("new.updated_at := least(new.updated_at, now() + interval '5 minutes')"),
                      "a future-dated device clock must not be able to freeze a row against every later edit")
    }

    // MARK: storage

    func testCreatesThePrivateAudioBucketWithLimits() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("insert into storage.buckets"))
        XCTAssertTrue(sql.contains("'voice-audio'"))
        XCTAssertTrue(sql.contains("file_size_limit"))
        XCTAssertTrue(sql.contains("'{audio/mp4}'"))
        XCTAssertFalse(sql.contains("'voice-audio', true"), "the bucket must not be public")
    }

    /// `foldername(name)[1]` compares the first path segment exactly. A `like uid || '/%'` test
    /// would also match a folder whose name merely starts with the uid.
    func testStoragePoliciesCompareTheFirstFolderSegment() throws {
        XCTAssertEqual(count("(storage.foldername(name))[1] = (select auth.uid())::text",
                             in: try migrationSQL()), 5,
                       "select, insert, update using, update with check, delete")
        XCTAssertTrue(try migrationSQL().contains("(storage.foldername(name))[1] = uid::text"),
                      "delete_my_account() runs as definer and compares against its own uid variable")
    }

    // MARK: account deletion

    func testAccountDeletionFunctionIsSecurityDefinerAndRemovesEverything() throws {
        let sql = try migrationSQL()
        XCTAssertTrue(sql.contains("create or replace function public.\(ServerFunctions.deleteMyAccount)()"),
                      "the SQL name and the Swift constant AuthService calls must be the same string")
        XCTAssertTrue(sql.contains("security definer"))
        XCTAssertTrue(sql.contains("set search_path"), "a security definer function without a pinned search_path is a privilege escalation")
        XCTAssertTrue(sql.contains("delete from storage.objects"))
        XCTAssertTrue(sql.contains("delete from auth.users where id = uid"))
        for table in Self.tables {
            XCTAssertTrue(sql.contains("delete from \(table) where user_id = uid"), "missing delete for \(table)")
        }
        XCTAssertTrue(sql.contains("revoke all on function public.delete_my_account() from public"))
        XCTAssertTrue(sql.contains("grant execute on function public.delete_my_account() to authenticated"))
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
-- SwiftData models field for field in snake_case, plus the sync columns and a private bucket for
-- the recorded audio.
--
-- Two timestamps, on two clocks, doing two different jobs:
--   updated_at        the device's clock. Last-write-wins is decided on this, on the device and
--                     again here in sync_row_guard().
--   server_updated_at the server's clock, set only by the trigger. Pulls page on this, so a row
--                     can never be missed because two devices disagree about what time it is.
--
-- animal_id and recording_id are plain uuid columns on purpose: sync pushes tables in an arbitrary
-- order, so a real foreign key would reject a child row that arrives before its parent.

create table if not exists public.animals (
    id uuid primary key,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
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
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
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
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
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
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    kind_raw text not null default 'activity',
    name text not null default '',
    is_built_in boolean not null default false,
    sort_order integer not null default 0
);

-- Push side: "what of mine changed after this device timestamp".
create index if not exists animals_user_updated_idx on public.animals (user_id, updated_at);
create index if not exists voice_recordings_user_updated_idx on public.voice_recordings (user_id, updated_at);
create index if not exists vocalizations_user_updated_idx on public.vocalizations (user_id, updated_at);
create index if not exists voice_tags_user_updated_idx on public.voice_tags (user_id, updated_at);

-- Pull cursor: the exact ordering the app pages on, id last so the order is total and offset
-- paging inside one timestamp is stable.
create index if not exists animals_user_server_idx on public.animals (user_id, server_updated_at, id);
create index if not exists voice_recordings_user_server_idx on public.voice_recordings (user_id, server_updated_at, id);
create index if not exists vocalizations_user_server_idx on public.vocalizations (user_id, server_updated_at, id);
create index if not exists voice_tags_user_server_idx on public.voice_tags (user_id, server_updated_at, id);

-- ---------------------------------------------------------------------------
-- Server-side last write wins.
--
-- The device already resolves conflicts on updated_at, but two devices pushing at once can still
-- interleave so that the older write lands second. This trigger makes the rule hold whatever
-- order the requests arrive in, and makes a delete permanent.
-- ---------------------------------------------------------------------------

create or replace function public.sync_row_guard()
returns trigger
language plpgsql
as $$
begin
    -- A device clock that is wrong must not be able to freeze a row against every later edit.
    -- Without this, one row stamped in 2030 makes every genuine later edit fail the staleness
    -- test below, so the upsert returns success, the device advances its watermark, and the edit
    -- is silently discarded; worse, the next pull brings the 2030 row back down and overwrites
    -- the corrected local copy. A small forward tolerance absorbs ordinary skew; anything beyond
    -- it is clamped to the server's clock, which is the only clock both devices agree on.
    -- Runs before the INSERT branch so it covers both paths.
    new.updated_at := least(new.updated_at, now() + interval '5 minutes');

    if tg_op = 'INSERT' then
        new.server_updated_at := now();
        return new;
    end if;

    -- A delete is permanent. A later edit from a device that had not heard about it yet must not
    -- resurrect the row.
    new.deleted_at := coalesce(old.deleted_at, new.deleted_at);

    -- Same or older device timestamp: this writer is replaying something already superseded.
    -- Return old, which leaves the row exactly as it is without raising, so a stale device sees a
    -- successful upsert and moves on rather than retrying forever.
    if new.updated_at <= old.updated_at then
        return old;
    end if;

    new.server_updated_at := now();
    return new;
end;
$$;

drop trigger if exists animals_sync_guard on public.animals;
create trigger animals_sync_guard before insert or update on public.animals
    for each row execute function public.sync_row_guard();

drop trigger if exists voice_recordings_sync_guard on public.voice_recordings;
create trigger voice_recordings_sync_guard before insert or update on public.voice_recordings
    for each row execute function public.sync_row_guard();

drop trigger if exists vocalizations_sync_guard on public.vocalizations;
create trigger vocalizations_sync_guard before insert or update on public.vocalizations
    for each row execute function public.sync_row_guard();

drop trigger if exists voice_tags_sync_guard on public.voice_tags;
create trigger voice_tags_sync_guard before insert or update on public.voice_tags
    for each row execute function public.sync_row_guard();

-- ---------------------------------------------------------------------------
-- Row Level Security. Every verb, every table, scoped to authenticated callers, and
-- `(select auth.uid())` so the uid is evaluated once per statement rather than once per row.
-- ---------------------------------------------------------------------------

alter table public.animals enable row level security;
alter table public.voice_recordings enable row level security;
alter table public.vocalizations enable row level security;
alter table public.voice_tags enable row level security;

drop policy if exists animals_select_own on public.animals;
drop policy if exists animals_insert_own on public.animals;
drop policy if exists animals_update_own on public.animals;
drop policy if exists animals_delete_own on public.animals;
create policy animals_select_own on public.animals for select to authenticated
    using (user_id = (select auth.uid()));
create policy animals_insert_own on public.animals for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy animals_update_own on public.animals for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy animals_delete_own on public.animals for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists voice_recordings_select_own on public.voice_recordings;
drop policy if exists voice_recordings_insert_own on public.voice_recordings;
drop policy if exists voice_recordings_update_own on public.voice_recordings;
drop policy if exists voice_recordings_delete_own on public.voice_recordings;
create policy voice_recordings_select_own on public.voice_recordings for select to authenticated
    using (user_id = (select auth.uid()));
create policy voice_recordings_insert_own on public.voice_recordings for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy voice_recordings_update_own on public.voice_recordings for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy voice_recordings_delete_own on public.voice_recordings for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists vocalizations_select_own on public.vocalizations;
drop policy if exists vocalizations_insert_own on public.vocalizations;
drop policy if exists vocalizations_update_own on public.vocalizations;
drop policy if exists vocalizations_delete_own on public.vocalizations;
create policy vocalizations_select_own on public.vocalizations for select to authenticated
    using (user_id = (select auth.uid()));
create policy vocalizations_insert_own on public.vocalizations for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy vocalizations_update_own on public.vocalizations for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy vocalizations_delete_own on public.vocalizations for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists voice_tags_select_own on public.voice_tags;
drop policy if exists voice_tags_insert_own on public.voice_tags;
drop policy if exists voice_tags_update_own on public.voice_tags;
drop policy if exists voice_tags_delete_own on public.voice_tags;
create policy voice_tags_select_own on public.voice_tags for select to authenticated
    using (user_id = (select auth.uid()));
create policy voice_tags_insert_own on public.voice_tags for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy voice_tags_update_own on public.voice_tags for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy voice_tags_delete_own on public.voice_tags for delete to authenticated
    using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Private bucket for the recorded audio. Objects live at "<user_id>/<audioFilename>".
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-audio', 'voice-audio', false, 52428800, '{audio/mp4}')
on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists voice_audio_select_own on storage.objects;
drop policy if exists voice_audio_insert_own on storage.objects;
drop policy if exists voice_audio_update_own on storage.objects;
drop policy if exists voice_audio_delete_own on storage.objects;
create policy voice_audio_select_own on storage.objects for select to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_insert_own on storage.objects for insert to authenticated
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_update_own on storage.objects for update to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_delete_own on storage.objects for delete to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------------------------------------------------------------------------
-- Account deletion. Security definer because a caller cannot delete their own auth.users row or
-- reach storage.objects outside their policies; search_path is pinned because a security definer
-- function with a caller-controlled search_path is a privilege escalation.
-- ---------------------------------------------------------------------------

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, storage, auth, pg_temp
as $$
declare
    uid uuid := auth.uid();
begin
    if uid is null then
        raise exception 'delete_my_account() requires an authenticated caller';
    end if;

    delete from storage.objects
     where bucket_id = 'voice-audio'
       and (storage.foldername(name))[1] = uid::text;

    delete from public.vocalizations where user_id = uid;
    delete from public.voice_recordings where user_id = uid;
    delete from public.voice_tags where user_id = uid;
    delete from public.animals where user_id = uid;

    -- The cascade on user_id would take the rows anyway; deleting them explicitly first means a
    -- failure here leaves nothing half-deleted behind an account that still exists.
    delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
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
Expected: PASS. `MigrationFileTests` fifteen cases are green.

Every count in the test was re-derived from the migration text above with the comment lines removed, not carried over from a previous revision. To re-derive them at any point:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -v '^[[:space:]]*--' supabase/migrations/20260919120000_voice_milestone.sql | tr 'A-Z' 'a-z' > /tmp/mig-nocomments.sql
for needle in 'create policy' 'to authenticated' '(select auth.uid())' 'with check' 'on storage.objects for'; do
  printf '%s\t%s\n' "$(grep -o "$needle" /tmp/mig-nocomments.sql | wc -l | tr -d ' ')" "$needle"
done
```
Expected: `20 create policy`, `21 to authenticated`, `25 (select auth.uid())`, `10 with check`, `4 on storage.objects for`.

Correction if a count assertion is off by one or two: the counts in the test are the contract, not an approximation. Recount with the command above rather than relaxing the test; an unexpected extra `create policy` is a duplicate, and a missing one is a hole in RLS. If a count is off by exactly the number of comment lines that mention the phrase, `migrationSQL()` is not stripping comments.

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

`read -rs` keeps the token off the screen and out of the shell history. `supabase link` prompts for the database password; type it, never paste it into a file.

Fallback with psql, for a machine without the Supabase CLI. The connection string holds the password, so it is typed into the shell, never written to a file:

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -v ON_ERROR_STOP=1 -f supabase/migrations/20260919120000_voice_milestone.sql
unset PGURI
```
Expected: `CREATE TABLE` four times, `CREATE INDEX` eight times, `CREATE FUNCTION` twice, `CREATE TRIGGER` four times, `ALTER TABLE` four times, `CREATE POLICY` twenty times, `INSERT 0 1` (or `INSERT 0 1` again on a re-run, because the bucket row is an upsert), `REVOKE` and `GRANT`.

- [ ] **Step 7: Fallback if the storage policies are refused for ownership**

`storage.objects` is owned by `supabase_storage_admin`, not by `postgres`, on some projects. If Step 6 fails with `must be owner of table objects`, apply just the storage block with the owning role. The rest of the migration has already succeeded at that point, so only this block is replayed:

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -v ON_ERROR_STOP=1 <<'SQL'
set role supabase_storage_admin;
drop policy if exists voice_audio_select_own on storage.objects;
drop policy if exists voice_audio_insert_own on storage.objects;
drop policy if exists voice_audio_update_own on storage.objects;
drop policy if exists voice_audio_delete_own on storage.objects;
create policy voice_audio_select_own on storage.objects for select to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_insert_own on storage.objects for insert to authenticated
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_update_own on storage.objects for update to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_delete_own on storage.objects for delete to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
reset role;
SQL
unset PGURI
```
Expected: `SET`, four `DROP POLICY`, four `CREATE POLICY`, `RESET`.

If even `set role supabase_storage_admin` is refused, paste the same block into the project's SQL editor in the Supabase dashboard, which runs as an owner. That is the one step in this plan that has no CLI equivalent, because the ownership grant itself is not something the CLI can hand out.

- [ ] **Step 8: Verify the schema landed**

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select tablename, rowsecurity from pg_tables where schemaname='public' order by tablename;"
psql "$PGURI" -c "select id, public, file_size_limit, allowed_mime_types from storage.buckets where id='voice-audio';"
psql "$PGURI" -c "select tablename, count(*) from pg_policies where schemaname='public' group by tablename order by tablename;"
psql "$PGURI" -c "select count(*) from pg_policies where schemaname='storage' and policyname like 'voice_audio%';"
psql "$PGURI" -c "select count(*) from pg_trigger where tgname like '%_sync_guard';"
psql "$PGURI" -c "select proname, prosecdef from pg_proc where proname in ('sync_row_guard','delete_my_account');"
unset PGURI
```
Expected: four rows with `rowsecurity = t`; one bucket row with `public = f`, `file_size_limit = 52428800` and `allowed_mime_types = {audio/mp4}`; four rows each with count 4; a storage policy count of 4; a trigger count of 4; and `delete_my_account` with `prosecdef = t` while `sync_row_guard` has `prosecdef = f`.

If the CLI was used instead of psql, `supabase db diff --linked` should also report no differences.

- [ ] **Step 9: Document the commands in the README**

Append the following to `README.md`. The outer fence below is **four backticks**, and it is a
delimiter for this plan only: do not copy it into the README. A three-backtick outer fence would be
terminated by the inner `bash` block's closing fence, so a worker copying "the block" would get a
truncated section and stray backticks in the file (verification defect D-D14).

The shell snippet names `SUPABASE_ACCESS_TOKEN`, which is a variable name and not a secret; after
Task 1 Step 5 the guard matches value shapes only, so this section does not trip it (verification
defect D-D23).

````markdown
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

If the `storage.objects` policies are refused with `must be owner of table objects`, replay just
that block after `set role supabase_storage_admin;` (see Plan H Task 6 Step 7).
````

Then re-run the guard against the tree as it will be pushed:

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add README.md
scripts/check-secrets.sh
```
Expected: `check-secrets: clean`.

- [ ] **Step 10: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add supabase/config.toml supabase/migrations/20260919120000_voice_milestone.sql \
        AppTests/MigrationFileTests.swift README.md
git commit -m "feat(server): voice milestone schema, server-side last-write-wins, private bucket, account deletion

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Sync fields and raw parent ids on the models, retained tombstones, deterministic tag ids

**Files:**
- Modify: `App/Models/Animal.swift` (add `updatedAt` after line 7)
- Modify: `App/Models/VoiceRecording.swift` (add `audioUploadedAt`, `animalID`, `animalLink`; `id` and `updatedAt` are already there)
- Modify: `App/Models/Vocalization.swift` (add `recordingID`, `recordingLink`; `id` and `updatedAt` are already there)
- **Not** modified: `App/Models/VoiceTag.swift`. It already has `@Attribute(.unique) var id` and `updatedAt` (commit `66af968`), and this plan needs nothing else from it.
- Create: `App/Models/DeletedRecord.swift`
- Modify: `App/Persistence/PersistenceController.swift:9-14` (`modelTypes`)
- Modify: `App/Persistence/AnimalDeletionPolicy.swift:11`, `App/Voice/PredictionService.swift:31`, `App/Voice/InsightsModel.swift:69` (all three `#Predicate { $0.animal?.id == animalID }` sites move to the raw id)
- Modify: `App/Media/MediaStore.swift`, `App/Media/FileMediaStore.swift` (`write(_:as:)`)
- Create: `AppTests/SyncFieldTests.swift`
- **Not** modified: `App/Persistence/VoiceTagSeed.swift` and `AppTests/VoiceTagSeedTests.swift`. Plan B's fix wave already gave the built-in tags stable ids through `VoiceTagSeed.builtInID(kind:name:)` and already made `run(_:)` seed on every launch with no UserDefaults guard. Finding 20 is satisfied by the tree, and Step 6 verifies that rather than rewriting it.

**Interfaces:**
- Consumes: `SyncTable` (Task 3); `Animal`, `MediaStore`, `InMemoryMediaStore`, `FileMediaStore`, `PersistenceController` (Plan A); `VoiceRecording`, `Vocalization`, `VoiceTag`, `VoiceTagSeed.builtInID`, `VoiceTagKind`, `TagPropagation` (Plan B).
- Produces:
  - `updatedAt: Date` on `Animal` (the other three already have it).
  - `audioUploadedAt: Date?` and `animalID: UUID?` on `VoiceRecording`; `recordingID: UUID?` on `Vocalization`. Both models keep `animal` / `recording` as computed doors that write the raw id with the relationship, over stored `animalLink` / `recordingLink`.
  - `@Model final class DeletedRecord` with `id`, `createdAt`, `entity`, `recordID`, `deletedAt`, `pushed`, `audioFilename`, and `init(entity:recordID:deletedAt:pushed:audioFilename:)`.
  - `enum Tombstone { static func record(_:id:deletedAt:audioFilename:in:) -> DeletedRecord; static func recordRecording(_:in:); static func recordPulled(_:id:deletedAt:in:) }`.
  - `MediaStore.write(_ data: Data, as filename: String) throws`.

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
        let container = try TestSupport.container()
        let context = container.mainContext
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

    /// The raw id is the source of truth. A row whose SwiftData relationship has not been resolved
    /// yet still knows its parent, so a push can never send a null foreign key for a parent that
    /// exists.
    func testSettingTheRelationshipAlsoWritesTheRawParentId() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2, animal: animal)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        vocalization.recording = recording
        context.insert(vocalization)
        try context.save()

        XCTAssertEqual(recording.animalID, animal.id)
        XCTAssertEqual(vocalization.recordingID, recording.id)
        XCTAssertEqual(recording.animal?.id, animal.id)
        XCTAssertEqual(vocalization.recording?.id, recording.id)
    }

    func testClearingTheRelationshipClearsTheRawParentId() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2, animal: animal)
        context.insert(recording)
        try context.save()

        recording.animal = nil
        XCTAssertNil(recording.animalID)
    }

    /// A row pulled from the server knows its parent id before the parent row arrives. The id is
    /// set on its own and the relationship is resolved later.
    func testTheRawIdCanBeSetWithoutAResolvedRelationship() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let orphanParent = UUID()
        let recording = VoiceRecording(audioFilename: "orphan-audio.m4a", durationS: 1)
        recording.animalID = orphanParent
        context.insert(recording)
        try context.save()

        XCTAssertEqual(recording.animalID, orphanParent)
        XCTAssertNil(recording.animal, "the parent has not arrived yet")
    }

    // MARK: tombstones

    func testTombstoneStoresTheEntityTheIdAndStartsUnpushed() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let gone = UUID()
        Tombstone.record(.animals, id: gone, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DeletedRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].entity, "animals")
        XCTAssertEqual(rows[0].recordID, gone)
        XCTAssertFalse(rows[0].pushed)
        XCTAssertNil(rows[0].audioFilename)
    }

    /// A pulled tombstone is retained but is already pushed, so it is never sent back and still
    /// blocks a stale edit from resurrecting the row.
    func testAPulledTombstoneIsRetainedAndAlreadyPushed() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let gone = UUID()
        Tombstone.recordPulled(.voiceTags, id: gone, deletedAt: Date(timeIntervalSince1970: 100), in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DeletedRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].pushed)
    }

    func testRecordingTombstoneCapturesTheAudioFilenameAndCoversItsVocalizations() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
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
        let recordingTombstone = try XCTUnwrap(rows.first { $0.entity == "voice_recordings" })
        XCTAssertEqual(recordingTombstone.audioFilename, "b-audio.m4a",
                       "the filename has to be captured before the local file goes, or the Storage object is orphaned")
    }

    /// Deleting the same record twice must not produce two tombstones for it.
    func testRecordingATombstoneTwiceUpdatesTheOneThatIsThere() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let gone = UUID()
        Tombstone.record(.animals, id: gone, deletedAt: Date(timeIntervalSince1970: 100), in: context)
        Tombstone.record(.animals, id: gone, deletedAt: Date(timeIntervalSince1970: 300), in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<DeletedRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].deletedAt, Date(timeIntervalSince1970: 300))
        XCTAssertFalse(rows[0].pushed, "a newer delete has to be sent again")
    }

    func testDeletedRecordIsRegisteredInTheSchema() {
        let registered = PersistenceController.modelTypes.map(ObjectIdentifier.init)
        XCTAssertTrue(registered.contains(ObjectIdentifier(DeletedRecord.self)))
        XCTAssertTrue(registered.contains(ObjectIdentifier(VoiceRecording.self)))
    }

    // Built-in tag ids are Plan B's, not this plan's: `VoiceTagSeed.builtInID` already exists and
    // `AppTests/VoiceTagSeedTests.swift` already covers its stability, the no-duplicate re-seed, the
    // renamed built-in and the hand-made tag that shares a built-in's name. Nothing here repeats
    // those. The one case Plan B could not cover, a *pulled* row carrying the same id merging onto
    // the seeded one, needs `SwiftDataLocalStore` and so lives in Task 9 Step 1 as
    // `testAPulledBuiltInTagMergesOntoTheSeededRow`.

    // MARK: media

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

- [ ] **Step 3: Add `updatedAt` to `Animal`, raw parent ids to the two children, and move every predicate off the computed relationship**

First read what is actually there, because v2 anchored on a shape these files have not had since commit `66af968`:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -n "id: UUID\|updatedAt\|var animal\|var recording\|@Relationship" App/Models/Animal.swift App/Models/VoiceRecording.swift App/Models/Vocalization.swift App/Models/VoiceTag.swift
```
Expected: all four already print `@Attribute(.unique) var id: UUID = UUID()`, and `VoiceRecording`, `Vocalization` and `VoiceTag` already print `var updatedAt: Date = Date()`. Only `Animal` is missing `updatedAt`. If that is not what prints, stop and re-derive the edits below against what is there.

In `App/Models/Animal.swift`, insert one property after line 7 (`    var createdAt: Date = Date()`), so it lands between `createdAt` and `var name: String = ""`:
```swift
    /// Bumped by every mutation site; sync pushes rows newer than the last push and resolves
    /// conflicts last-write-wins on this value.
    var updatedAt: Date = Date()
```
`id` already carries `@Attribute(.unique)`, and nothing else in this file changes.

In `App/Models/VoiceRecording.swift`, replace lines 20 and 21:
```swift
    var editedAt: Date?
    var animal: Animal?
```
with:
```swift
    var editedAt: Date?
    /// When this recording's audio file reached Storage. Nil means "still to upload".
    var audioUploadedAt: Date?
    /// The parent's id, and the source of truth for it. A row pulled before its parent still knows
    /// which animal it belongs to, so a push can never send a null animal_id for an animal that
    /// exists. Written by the `animal` door below; settable on its own when a pull resolves later.
    var animalID: UUID?
    /// Stored relationship. Nothing outside this file and `SwiftDataLocalStore.apply` touches it:
    /// `animal` is the door, so the raw id is always written with it. Same shape as Plan B's
    /// `status` over `statusRaw`.
    @Relationship var animalLink: Animal?

    var animal: Animal? {
        get { animalLink }
        set {
            animalLink = newValue
            animalID = newValue?.id
        }
    }
```

and replace line 22, the inverse keypath on the vocalizations relationship:
```swift
    @Relationship(deleteRule: .cascade, inverse: \Vocalization.recording) var vocalizations: [Vocalization]?
```
with:
```swift
    @Relationship(deleteRule: .cascade, inverse: \Vocalization.recordingLink) var vocalizations: [Vocalization]?
```
A `\Vocalization.recording` keypath would now name a computed property, which SwiftData cannot use as an inverse.

and in `init(audioFilename:durationS:recordedAt:animal:)`, replace line 28:
```swift
        self.animal = animal
```
with:
```swift
        self.animalLink = animal
        self.animalID = animal?.id
```
The computed setter cannot be used before every stored property has a value.

In `App/Models/Vocalization.swift`, replace line 25:
```swift
    var recording: VoiceRecording?
```
with:
```swift
    /// The parent recording's id, and the source of truth for it. See `VoiceRecording.animalID`.
    var recordingID: UUID?
    /// Stored relationship. SwiftData can write this one directly when the inverse on
    /// `VoiceRecording.vocalizations` attaches a sound from the parent side, which is why the push
    /// side falls back to `recordingLink?.id` when `recordingID` is nil.
    @Relationship var recordingLink: VoiceRecording?

    var recording: VoiceRecording? {
        get { recordingLink }
        set {
            recordingLink = newValue
            recordingID = newValue?.id
        }
    }
```
Nothing else in this file changes; `id` is already unique and `updatedAt` is already there.

`App/Models/VoiceTag.swift` is not touched at all.

Now the predicates. A `#Predicate` can only reach persisted properties, and `animal` is now computed, so every `#Predicate` that walks that relationship has to move to the raw id. The raw id is also the faster comparison. Find them first, so one added since this plan was written is not missed:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -rn "#Predicate" App/
```
Expected at `8dc20e8`: seven hits. Four are in `App/Voice/VoiceTagRenamer.swift` and compare `activityTag` or `meaningTag`, which are plain stored `String?`s, so they are left alone. The three that walk the relationship are the ones to change:

In `App/Persistence/AnimalDeletionPolicy.swift`, replace line 11:
```swift
            FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
```
with:
```swift
            FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animalID == animalID }))
```

In `App/Voice/PredictionService.swift`, replace line 31, inside `labeledSamples(for:context:)`:
```swift
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
```
with:
```swift
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animalID == animalID }))
```

In `App/Voice/InsightsModel.swift`, replace line 69, inside `summary(for:context:)`:
```swift
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
```
with:
```swift
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animalID == animalID }))
```

The two lines are identical, so check both files afterwards rather than assuming one edit covered them:
```bash
grep -rn "animal?.id" App/
```
Expected: **five** hits, and none of them a `#Predicate` body. The three predicate sites have just been changed by this step, so what is left is (verification defect C-D1, which promised two and would have sent a worker hunting for three phantom sites, or worse, "fixing" the two that have nothing to do with the relationship):

| Hit | What it is | Changed? |
| --- | --- | --- |
| `App/Views/Voice/TagSheet.swift:28` | `animalID = recording.animal?.id`, an ordinary read through the computed door | no |
| `App/Views/Voice/VoiceHistoryView.swift:12` | `allRecordings.filter { $0.animal?.id == animal?.id }`, a Swift closure over already-fetched models | no |
| `App/Views/Voice/AskView.swift:71` | `.onChange(of: animal?.id)` on a local `Animal?` binding | no |
| `App/Views/Voice/VoiceHistoryView.swift:64` | `.onChange(of: animal?.id)`, same | no |
| `App/Views/Voice/InsightsView.swift:64` | `.task(id: animal?.id)`, same | no |

The first two are ordinary Swift over already-fetched models, where a computed property is fine. The last three are SwiftUI identity on a local `Animal?` and are not about the relationship at all. If the count is not five, or a hit appears inside a `#Predicate`, stop and reconcile before continuing.

`id` is already `@Attribute(.unique)` on all four models, so the unique constraint that lets a pull upsert without duplicating rows costs nothing here. The schema still changes, because of the columns added above, which is why `makeContainerWithRecovery()` exists: a simulator store that cannot migrate is moved aside and a fresh one opened.

- [ ] **Step 4: Add the tombstone model**

Create `App/Models/DeletedRecord.swift`:
```swift
import Foundation
import SwiftData

/// A local record of something that was deleted, on this phone or on another one.
///
/// Tombstones are never removed, only flipped to `pushed`. Two reasons: a delete that has been
/// sent must not be sent again, and a row that has been deleted must not come back when some other
/// device pushes an edit it made before it heard about the delete. A tombstone is an id, a table
/// name, a date and a flag, so keeping every one of them costs a few tens of kilobytes.
@Model
final class DeletedRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// A `SyncTable` raw value, for example "voice_recordings".
    var entity: String = ""
    var recordID: UUID = UUID()
    var deletedAt: Date = Date()
    /// True once the server has been told, or once this tombstone came from the server.
    var pushed: Bool = false
    /// A recording's audio filename, captured before the local file is deleted, so the push can
    /// remove the Storage object too. Nil for every other table.
    var audioFilename: String?

    init(entity: String, recordID: UUID, deletedAt: Date = Date(),
         pushed: Bool = false, audioFilename: String? = nil) {
        self.entity = entity
        self.recordID = recordID
        self.deletedAt = deletedAt
        self.pushed = pushed
        self.audioFilename = audioFilename
    }
}

/// The one place that writes tombstones, so no delete site has to remember the entity string or
/// the audio filename.
enum Tombstone {
    /// Records a local delete, or refreshes an existing tombstone when the same record is deleted
    /// again with a newer timestamp.
    @discardableResult
    @MainActor
    static func record(_ table: SyncTable,
                       id: UUID,
                       deletedAt: Date = Date(),
                       audioFilename: String? = nil,
                       in context: ModelContext) -> DeletedRecord {
        if let existing = find(table, id: id, in: context) {
            if deletedAt > existing.deletedAt {
                existing.deletedAt = deletedAt
                existing.pushed = false
            }
            if let audioFilename { existing.audioFilename = audioFilename }
            return existing
        }
        let record = DeletedRecord(entity: table.rawValue, recordID: id,
                                   deletedAt: deletedAt, pushed: false, audioFilename: audioFilename)
        context.insert(record)
        return record
    }

    /// Records a delete that arrived from the server. Already pushed, because the server is where
    /// it came from, and retained so a later local edit cannot resurrect the row.
    @MainActor
    static func recordPulled(_ table: SyncTable, id: UUID, deletedAt: Date, in context: ModelContext) {
        if let existing = find(table, id: id, in: context) {
            existing.deletedAt = max(existing.deletedAt, deletedAt)
            existing.pushed = true
            return
        }
        context.insert(DeletedRecord(entity: table.rawValue, recordID: id, deletedAt: deletedAt, pushed: true))
    }

    /// A recording's vocalizations cascade locally, so the server has to be told about them too,
    /// and the audio filename has to be captured before the file on disk goes.
    @MainActor
    static func recordRecording(_ recording: VoiceRecording, in context: ModelContext) {
        let now = Date()
        for vocalization in recording.sortedVocalizations {
            record(.vocalizations, id: vocalization.id, deletedAt: now, in: context)
        }
        record(.voiceRecordings, id: recording.id, deletedAt: now,
               audioFilename: recording.audioFilename.isEmpty ? nil : recording.audioFilename,
               in: context)
    }

    @MainActor
    private static func find(_ table: SyncTable, id: UUID, in context: ModelContext) -> DeletedRecord? {
        let entity = table.rawValue
        let descriptor = FetchDescriptor<DeletedRecord>(
            predicate: #Predicate { $0.entity == entity && $0.recordID == id }
        )
        return (try? context.fetch(descriptor))?.first
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

- [ ] **Step 6: Verify the built-in tag ids are already deterministic**

Finding 20 asked for fixed built-in tag ids so a re-seed after a wipe upserts instead of duplicating. Plan B's fix wave shipped exactly that, so there is nothing to write here. What this step does is confirm it, because the store reset in Task 5 depends on it and a silent regression would only show up as duplicated tags after a sign-out.

`App/Persistence/VoiceTagSeed.swift` on the branch has:
- `static func builtInID(kind: VoiceTagKind, name: String) -> UUID`, a version 5 UUID over the RFC 4122 DNS namespace `6BA7B810-9DAD-11D1-80B4-00C04FD430C8` and the string `"\(kind.rawValue):\(name)"`, computed with `Insecure.SHA1` and stamped with the version and variant bits.
- `seedIfNeeded(context:) throws -> Int`, which skips a built-in when a row already carries its id **or** when a same-kind row already carries its name, so a renamed built-in is recognised by id and a hand-made tag sharing a built-in's name is not shadowed.
- `run(_:)`, which seeds on **every** launch. The old `hasSeededVoiceTags` UserDefaults flag is retired: `seededKey` survives only so an old install's value has a name in the source.

There is no `UUID.v5` extension and no `builtInNamespace` symbol in the tree, and this plan adds neither. `VoiceTag` also gained `init(id:kind:name:isBuiltIn:sortOrder:)`, which is what Task 9's pull path uses to build a tag with the server's id.

Check all of that rather than trusting it:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -n "builtInID\|seededKey\|UserDefaults\|namespace" App/Persistence/VoiceTagSeed.swift
grep -rn "UUID.v5\|builtInNamespace" App/ || echo "neither symbol exists, as expected"
grep -n "init(id:" App/Models/VoiceTag.swift
```
Expected: `builtInID` and the private `namespace` are present, `UserDefaults` appears nowhere in `VoiceTagSeed.swift`, `seededKey` is present but only as a retired constant, the second grep prints its fallback line, and `VoiceTag` has the id-taking initializer.

`AppTests/VoiceTagSeedTests.swift` already covers this ground with `testBuiltInIDIsStableAndDiffersPerKindAndName`, `testSeedingTwiceProducesNoDuplicates`, `testSeedDoesNotReinsertARenamedBuiltIn`, `testSeedSkipsAUserCreatedTagSharingABuiltInName` and `testRunSeedsAFreshStoreEvenWhenTheOldFlagIsSet`. Step 1's `SyncFieldTests` deliberately does not repeat any of them; the one thing left to prove is the half Plan B could not test, namely that a **pulled** row carrying `builtInID(...)` merges onto the seeded row, and that lands in Task 9 Step 1 as `testAPulledBuiltInTagMergesOntoTheSeededRow`.

- [ ] **Step 7: Let the media stores write a known filename**

In `App/Media/MediaStore.swift`, add one requirement to the `MediaStore` protocol, after `func saveAudio(from url: URL) throws -> String`:
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

- [ ] **Step 8: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncFieldTests` ten cases are green, and all 60 tests that passed before this plan started still pass, `VoiceTagSeedTests`, `PredictionServiceTests`, `InsightsModelTests` and `AnimalDeletionPolicyTests` among them.

Correction if an existing test fails with a SwiftData migration error on the simulator, delete the app's store and re-run:
```bash
xcrun simctl uninstall booted com.ashlab.AnimalTracker
scripts/test-app.sh
```

Correction if anything fails to compile with "cannot reference computed property in a predicate" or "key path cannot refer to computed property": one of the three `#Predicate` sites in Step 3 was missed, or the inverse keypath on `VoiceRecording.vocalizations` still names `\Vocalization.recording`. Re-run the `grep -rn "#Predicate" App/` from Step 3.

- [ ] **Step 9: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Models/Animal.swift App/Models/VoiceRecording.swift App/Models/Vocalization.swift \
        App/Models/DeletedRecord.swift App/Persistence/PersistenceController.swift \
        App/Persistence/AnimalDeletionPolicy.swift \
        App/Voice/PredictionService.swift App/Voice/InsightsModel.swift \
        App/Media/MediaStore.swift App/Media/FileMediaStore.swift \
        AppTests/SyncFieldTests.swift
git commit -m "feat(sync): updatedAt and raw parent ids on the models, retained tombstones, deterministic tag ids

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Codable row structs with snake_case keys, the server cursor column, and the Storage path

**Files:**
- Create: `App/Sync/SyncRows.swift`
- Create: `AppTests/SyncRowTests.swift`

**Interfaces:**
- Consumes: `SyncCoding` (Task 3). Column names come from Task 6's migration.
- Produces: `enum RemoteAudioPath { static let bucket = "voice-audio"; static func make(userID: UUID, filename: String) -> String }`; `struct AnimalRow`, `struct VoiceRecordingRow`, `struct VocalizationRow`, `struct VoiceTagRow`, each `Codable, Equatable`, each with `id`, `userID`, `createdAt`, `updatedAt`, `serverUpdatedAt: Date?`, `deletedAt: Date?` and a `static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> Self`; `protocol SyncRow` with `var id: UUID { get }`, `var updatedAt: Date { get set }`, `var serverUpdatedAt: Date? { get set }`, `var deletedAt: Date? { get set }`, conformed by all four.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/SyncRowTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SyncRowTests: XCTestCase {
    private let userID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    /// A whole second. The struct-equality round trips below compare `Date`s with `==` through
    /// `Equatable`, and a whole second survives the ISO 8601 formatter exactly. The fractional
    /// behaviour is asserted separately, with `accuracy`, using `fractional`.
    private let moment = Date(timeIntervalSince1970: 1_750_000_000)
    private let fractional = Date(timeIntervalSince1970: 1_750_000_000.25)

    /// Every column the server has for this table, in the order the migration declares them, minus
    /// `server_updated_at`, which the device never sends. The uniformity tests compare against
    /// these exact sets rather than against a subset, because the bug being guarded is a key that
    /// goes missing, and `isSuperset(of:)` cannot see that.
    private static let animalKeys: Set<String> = [
        "id", "user_id", "created_at", "updated_at", "deleted_at", "name", "species", "color_hex",
        "photo_filename", "photo_thumbnail_filename", "tracks_outdoor_time", "sort_order",
        "is_archived", "note",
    ]
    private static let recordingKeys: Set<String> = [
        "id", "user_id", "created_at", "updated_at", "deleted_at", "animal_id", "recorded_at",
        "duration_s", "audio_filename", "status_raw", "error_message", "note", "activity_tag",
        "meaning_tag", "user_confidence", "edited_at", "audio_uploaded_at",
    ]
    private static let vocalizationKeys: Set<String> = [
        "id", "user_id", "created_at", "updated_at", "deleted_at", "recording_id", "start_s",
        "end_s", "f0_mean", "f0_min", "f0_max", "f0_slope", "voiced_fraction", "rms_db",
        "spectral_centroid_hz", "mfcc", "activity_tag", "meaning_tag", "user_confidence",
        "overridden",
    ]
    private static let tagKeys: Set<String> = [
        "id", "user_id", "created_at", "updated_at", "deleted_at", "kind_raw", "name",
        "is_built_in", "sort_order",
    ]

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try SyncCoding.encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func animalRow(deletedAt: Date? = nil, serverUpdatedAt: Date? = nil,
                           photoFilename: String? = "p.jpg", note: String? = "shy") -> AnimalRow {
        AnimalRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                  serverUpdatedAt: serverUpdatedAt, deletedAt: deletedAt,
                  name: "Miso", species: "cat", colorHex: "#FF8800",
                  photoFilename: photoFilename, photoThumbnailFilename: "t.jpg",
                  tracksOutdoorTime: false, sortOrder: 3, isArchived: true, note: note)
    }

    func testAnimalRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = animalRow(deletedAt: moment)
        XCTAssertEqual(Set(try json(row).keys), Self.animalKeys)
        XCTAssertFalse(Set(try json(row).keys).contains("userID"))
        let back = try SyncCoding.decoder.decode(AnimalRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    func testVoiceRecordingRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VoiceRecordingRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                                    serverUpdatedAt: nil, deletedAt: moment,
                                    animalID: UUID(), recordedAt: moment, durationS: 1.25,
                                    audioFilename: "x-audio.m4a", statusRaw: "analyzed", errorMessage: nil,
                                    note: "loud", activityTag: "Door", meaningTag: "Hungry",
                                    userConfidence: 3, editedAt: moment, audioUploadedAt: moment)
        XCTAssertEqual(Set(try json(row).keys), Self.recordingKeys)
        let back = try SyncCoding.decoder.decode(VoiceRecordingRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    func testVocalizationRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VocalizationRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                                  serverUpdatedAt: nil, deletedAt: nil,
                                  recordingID: UUID(), startS: 0.1, endS: 0.5, f0Mean: 600, f0Min: 550,
                                  f0Max: 650, f0Slope: 100, voicedFraction: 0.9, rmsDb: -20,
                                  spectralCentroidHz: 1500, mfcc: [1, 2, 3], activityTag: nil,
                                  meaningTag: "Hungry", userConfidence: 2, overridden: true)
        XCTAssertEqual(Set(try json(row).keys), Self.vocalizationKeys)
        let back = try SyncCoding.decoder.decode(VocalizationRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
        XCTAssertEqual(back.mfcc, [1, 2, 3])
    }

    func testVoiceTagRowUsesSnakeCaseKeysAndRoundTrips() throws {
        let row = VoiceTagRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                              serverUpdatedAt: nil, deletedAt: nil,
                              kindRaw: "meaning", name: "Hungry", isBuiltIn: true, sortOrder: 2)
        XCTAssertEqual(Set(try json(row).keys), Self.tagKeys)
        let back = try SyncCoding.decoder.decode(VoiceTagRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back, row)
    }

    /// The defect this replaces. v2 asserted that a nil `server_updated_at` and a nil `deleted_at`
    /// were *omitted*, which is what the synthesized encoder does and what makes every real push
    /// fail: PostgREST rejects a bulk upsert whose objects do not all carry the same keys
    /// (PGRST102), and a batch always mixes tombstones with ordinary rows. `InMemoryRemoteStore`
    /// never sees JSON, so nothing else in this suite would notice.
    ///
    /// So: one key set per table, identical across every row in a mixed batch, `deleted_at`
    /// present as JSON null on the rows that have no tombstone, and `server_updated_at` on none of
    /// them.
    func testEveryRowInAMixedBatchEncodesTheSameKeySet() throws {
        let animals: [AnimalRow] = [
            animalRow(),
            animalRow(deletedAt: moment),
            animalRow(photoFilename: nil, note: nil),
            AnimalRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
        ]
        for row in animals {
            XCTAssertEqual(Set(try json(row).keys), Self.animalKeys)
            XCTAssertFalse(Set(try json(row).keys).contains("server_updated_at"))
        }

        let recordings: [VoiceRecordingRow] = [
            VoiceRecordingRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                              serverUpdatedAt: nil, deletedAt: nil, animalID: UUID(), recordedAt: moment,
                              durationS: 1, audioFilename: "a.m4a", statusRaw: "analyzed",
                              errorMessage: nil, note: "", activityTag: nil, meaningTag: nil,
                              userConfidence: nil, editedAt: nil, audioUploadedAt: nil),
            VoiceRecordingRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
        ]
        for row in recordings { XCTAssertEqual(Set(try json(row).keys), Self.recordingKeys) }

        let vocalizations: [VocalizationRow] = [
            VocalizationRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                            serverUpdatedAt: nil, deletedAt: nil, recordingID: UUID(), startS: 0,
                            endS: 1, f0Mean: nil, f0Min: nil, f0Max: nil, f0Slope: nil,
                            voicedFraction: 0.5, rmsDb: -30, spectralCentroidHz: 900, mfcc: [],
                            activityTag: nil, meaningTag: nil, userConfidence: nil, overridden: false),
            VocalizationRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
        ]
        for row in vocalizations { XCTAssertEqual(Set(try json(row).keys), Self.vocalizationKeys) }

        let tags: [VoiceTagRow] = [
            VoiceTagRow(id: UUID(), userID: userID, createdAt: moment, updatedAt: moment,
                        serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning", name: "Hungry",
                        isBuiltIn: true, sortOrder: 0),
            VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
        ]
        for row in tags { XCTAssertEqual(Set(try json(row).keys), Self.tagKeys) }
    }

    /// A key that is present has to be present as null, not as a missing value dressed up by
    /// `JSONSerialization`. `NSNull` is what a JSON null deserializes to.
    func testAbsentValuesAreEncodedAsJsonNullRatherThanOmitted() throws {
        let row = animalRow(photoFilename: nil, note: nil)
        let payload = try json(row)
        XCTAssertTrue(payload["deleted_at"] is NSNull)
        XCTAssertTrue(payload["photo_filename"] is NSNull)
        XCTAssertTrue(payload["note"] is NSNull)
        XCTAssertFalse(payload["updated_at"] is NSNull)

        let vocalization = VocalizationRow.tombstone(id: UUID(), userID: userID, deletedAt: moment)
        let vocalizationPayload = try json(vocalization)
        XCTAssertTrue(vocalizationPayload["recording_id"] is NSNull)
        XCTAssertTrue(vocalizationPayload["f0_mean"] is NSNull)
    }

    /// The server sends `server_updated_at` on a pull, so the decoder still has to take it. It is
    /// decoded from a payload shaped like the server's, because the device's own encoder never
    /// produces one.
    func testServerCursorDecodesWhenThePullSendsIt() throws {
        let payload = """
        {"id":"\(UUID().uuidString)","user_id":"\(userID.uuidString)",
         "created_at":"2025-06-15T15:06:40.000Z","updated_at":"2025-06-15T15:06:40.000Z",
         "server_updated_at":"2025-06-15T15:06:40.250Z","deleted_at":null,
         "name":"Miso","species":"cat","color_hex":"#FF8800",
         "photo_filename":null,"photo_thumbnail_filename":null,
         "tracks_outdoor_time":true,"sort_order":0,"is_archived":false,"note":null}
        """
        let back = try SyncCoding.decoder.decode(AnimalRow.self, from: Data(payload.utf8))
        XCTAssertEqual(try XCTUnwrap(back.serverUpdatedAt).timeIntervalSince1970,
                       fractional.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(back.deletedAt)
        XCTAssertNil(back.photoFilename)
        XCTAssertEqual(back.name, "Miso")
    }

    /// 1_750_000_000.25 is 2025-06-15T15:06:40.250Z, which is the timestamp the payload above
    /// carries. Computed, not guessed:
    /// `python3 -c "import datetime;print(datetime.datetime.fromtimestamp(1750000000.25, datetime.timezone.utc).isoformat())"`
    func testTheFixtureTimestampIsWhatTheDecoderTestClaims() throws {
        XCTAssertEqual(SyncCoding.string(from: fractional), "2025-06-15T15:06:40.250Z")
    }

    func testDatesSurviveARoundTripToTheMillisecond() throws {
        let row = VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: fractional)
        let back = try SyncCoding.decoder.decode(VoiceTagRow.self, from: SyncCoding.encoder.encode(row))
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, fractional.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(back.deletedAt).timeIntervalSince1970,
                       fractional.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDatesEncodeAsIso8601WithFractionalSeconds() throws {
        let row = VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: fractional)
        let encoded = try XCTUnwrap(try json(row)["deleted_at"] as? String)
        XCTAssertTrue(encoded.hasSuffix("Z"), encoded)
        XCTAssertTrue(encoded.contains(".250"), encoded)
    }

    func testTombstonesCarryTheIdTheUserAndTheDeletionTime() {
        let id = UUID()
        let animal = AnimalRow.tombstone(id: id, userID: userID, deletedAt: moment)
        XCTAssertEqual(animal.id, id)
        XCTAssertEqual(animal.userID, userID)
        XCTAssertEqual(animal.deletedAt, moment)
        XCTAssertEqual(animal.updatedAt, moment, "the tombstone has to win last-write-wins on updated_at")
        XCTAssertNil(animal.serverUpdatedAt)
        XCTAssertEqual(VoiceRecordingRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
        XCTAssertEqual(VocalizationRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
        XCTAssertEqual(VoiceTagRow.tombstone(id: id, userID: userID, deletedAt: moment).deletedAt, moment)
    }

    /// The engine works over the four row types through one protocol when it pages and sorts, so
    /// all four have to expose the same four fields under the same names.
    func testEveryRowTypeExposesTheSyncRowFields() {
        let rows: [any SyncRow] = [
            AnimalRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
            VoiceRecordingRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
            VocalizationRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
            VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: moment),
        ]
        for row in rows {
            XCTAssertEqual(row.updatedAt, moment)
            XCTAssertEqual(row.deletedAt, moment)
            XCTAssertNil(row.serverUpdatedAt)
        }
    }

    func testRemoteAudioPathIsTheUserFolder() {
        XCTAssertEqual(RemoteAudioPath.bucket, "voice-audio")
        XCTAssertEqual(RemoteAudioPath.make(userID: userID, filename: "abc-audio.m4a"),
                       "33333333-3333-3333-3333-333333333333/abc-audio.m4a")
    }

    /// `auth.uid()::text` is lowercase in Postgres, and the storage policy compares the object's
    /// first folder segment against it, so an uppercase UUID here would be rejected by RLS.
    func testRemoteAudioPathIsLowercase() {
        let mixed = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!
        XCTAssertEqual(RemoteAudioPath.make(userID: mixed, filename: "x-audio.m4a"),
                       "aabbccdd-1122-3344-5566-778899aabbcc/x-audio.m4a")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'AnimalRow' in scope` and `cannot find type 'SyncRow' in scope`.

- [ ] **Step 3: Write the rows**

Create `App/Sync/SyncRows.swift`:
```swift
import Foundation

/// Audio objects live at "<user id>/<audio filename>" in a private bucket, which is exactly the
/// prefix the `storage.objects` policies allow.
enum RemoteAudioPath {
    static let bucket = "voice-audio"

    static func make(userID: UUID, filename: String) -> String {
        // Lowercase: Postgres renders auth.uid()::text in lowercase and the storage policy compares
        // the object's first folder segment against that value.
        "\(userID.uuidString.lowercased())/\(filename)"
    }
}

/// What the engine needs from a row whatever table it came from: which row it is, when the device
/// last changed it, where the server's pull cursor stands, and whether it is a tombstone.
protocol SyncRow {
    var id: UUID { get }
    var updatedAt: Date { get set }
    /// Settable so `InMemoryRemoteStore` can stamp it the way the server's trigger does.
    var serverUpdatedAt: Date? { get set }
    /// Settable so `InMemoryRemoteStore` can keep it sticky the way the server's trigger does.
    var deletedAt: Date? { get set }
}

/// Why all four row types below write their own `encode(to:)` instead of taking the synthesized
/// one, in one place rather than four times:
///
/// PostgREST refuses a bulk insert or upsert whose objects do not all carry the same set of keys,
/// with `PGRST102`. Swift's synthesized encoder uses `encodeIfPresent` for optionals, so the key
/// set of an encoded row depends on which of its optionals happen to be nil. Every push batch
/// mixes tombstones (`deleted_at` set, parent id nil) with ordinary rows (`deleted_at` nil, parent
/// id set), so the synthesized encoder produces two different key sets in one array and the server
/// rejects the whole request. `InMemoryRemoteStore` holds Swift values and never encodes anything,
/// so no test in this plan would catch it: it would be a clean suite and a backend that never
/// accepted a single write.
///
/// So every row emits every column key, every time. `encode(_:forKey:)` on an `Optional` calls
/// `encodeNil()`, which is a JSON null, and `encodeIfPresent` appears nowhere in this file. The
/// one column that is never emitted is `server_updated_at`: it belongs to the server's trigger,
/// and a device that sent it would be arguing with the pull cursor.
///
/// Sending `deleted_at` as an explicit null on every ordinary edit is safe because a delete is
/// made permanent server-side by `sync_row_guard()`'s
/// `new.deleted_at := coalesce(old.deleted_at, new.deleted_at)`, and locally by the retained
/// tombstone. Neither mechanism ever depended on the key being absent.
///
/// Decoding stays synthesized. `init(from:)` uses `decodeIfPresent` for optionals, so a pull that
/// carries `server_updated_at` decodes it, an explicit null decodes to nil, and a column the
/// server leaves out decodes to nil as well.
struct AnimalRow: Codable, Equatable, SyncRow {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    /// Set by the server's trigger, read by the pull cursor, never sent by the device: `encode(to:)`
    /// below omits this one key and only this one.
    var serverUpdatedAt: Date?
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
        case serverUpdatedAt = "server_updated_at"
        case deletedAt = "deleted_at"
        case colorHex = "color_hex"
        case photoFilename = "photo_filename"
        case photoThumbnailFilename = "photo_thumbnail_filename"
        case tracksOutdoorTime = "tracks_outdoor_time"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        // server_updated_at is deliberately not encoded.
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(name, forKey: .name)
        try container.encode(species, forKey: .species)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encode(photoFilename, forKey: .photoFilename)
        try container.encode(photoThumbnailFilename, forKey: .photoThumbnailFilename)
        try container.encode(tracksOutdoorTime, forKey: .tracksOutdoorTime)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(note, forKey: .note)
    }

    /// A delete is an ordinary upsert with `deleted_at` set and `updated_at` equal to it, so it
    /// wins last-write-wins against anything older. The other columns take their defaults, so no
    /// column has to be nullable just for deletes.
    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> AnimalRow {
        AnimalRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt,
                  serverUpdatedAt: nil, deletedAt: deletedAt,
                  name: "", species: "", colorHex: "", photoFilename: nil, photoThumbnailFilename: nil,
                  tracksOutdoorTime: true, sortOrder: 0, isArchived: false, note: nil)
    }
}

struct VoiceRecordingRow: Codable, Equatable, SyncRow {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var serverUpdatedAt: Date?
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
        case serverUpdatedAt = "server_updated_at"
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(animalID, forKey: .animalID)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(durationS, forKey: .durationS)
        try container.encode(audioFilename, forKey: .audioFilename)
        try container.encode(statusRaw, forKey: .statusRaw)
        try container.encode(errorMessage, forKey: .errorMessage)
        try container.encode(note, forKey: .note)
        try container.encode(activityTag, forKey: .activityTag)
        try container.encode(meaningTag, forKey: .meaningTag)
        try container.encode(userConfidence, forKey: .userConfidence)
        try container.encode(editedAt, forKey: .editedAt)
        try container.encode(audioUploadedAt, forKey: .audioUploadedAt)
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VoiceRecordingRow {
        VoiceRecordingRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt,
                          serverUpdatedAt: nil, deletedAt: deletedAt,
                          animalID: nil, recordedAt: deletedAt, durationS: 0, audioFilename: "",
                          statusRaw: "recorded", errorMessage: nil, note: "", activityTag: nil,
                          meaningTag: nil, userConfidence: nil, editedAt: nil, audioUploadedAt: nil)
    }
}

struct VocalizationRow: Codable, Equatable, SyncRow {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var serverUpdatedAt: Date?
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
        case serverUpdatedAt = "server_updated_at"
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(recordingID, forKey: .recordingID)
        try container.encode(startS, forKey: .startS)
        try container.encode(endS, forKey: .endS)
        try container.encode(f0Mean, forKey: .f0Mean)
        try container.encode(f0Min, forKey: .f0Min)
        try container.encode(f0Max, forKey: .f0Max)
        try container.encode(f0Slope, forKey: .f0Slope)
        try container.encode(voicedFraction, forKey: .voicedFraction)
        try container.encode(rmsDb, forKey: .rmsDb)
        try container.encode(spectralCentroidHz, forKey: .spectralCentroidHz)
        try container.encode(mfcc, forKey: .mfcc)
        try container.encode(activityTag, forKey: .activityTag)
        try container.encode(meaningTag, forKey: .meaningTag)
        try container.encode(userConfidence, forKey: .userConfidence)
        try container.encode(overridden, forKey: .overridden)
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VocalizationRow {
        VocalizationRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt,
                        serverUpdatedAt: nil, deletedAt: deletedAt,
                        recordingID: nil, startS: 0, endS: 0, f0Mean: nil, f0Min: nil, f0Max: nil,
                        f0Slope: nil, voicedFraction: 0, rmsDb: -160, spectralCentroidHz: 0, mfcc: [],
                        activityTag: nil, meaningTag: nil, userConfidence: nil, overridden: false)
    }
}

struct VoiceTagRow: Codable, Equatable, SyncRow {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var updatedAt: Date
    var serverUpdatedAt: Date?
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
        case serverUpdatedAt = "server_updated_at"
        case deletedAt = "deleted_at"
        case kindRaw = "kind_raw"
        case isBuiltIn = "is_built_in"
        case sortOrder = "sort_order"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(kindRaw, forKey: .kindRaw)
        try container.encode(name, forKey: .name)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(sortOrder, forKey: .sortOrder)
    }

    static func tombstone(id: UUID, userID: UUID, deletedAt: Date) -> VoiceTagRow {
        VoiceTagRow(id: id, userID: userID, createdAt: deletedAt, updatedAt: deletedAt,
                    serverUpdatedAt: nil, deletedAt: deletedAt,
                    kindRaw: "activity", name: "", isBuiltIn: false, sortOrder: 0)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncRowTests` fourteen cases are green.

Correction if `testEveryRowInAMixedBatchEncodesTheSameKeySet` reports a missing key: one column was left out of that type's `encode(to:)`. Compare the method against the type's `CodingKeys` line by line; every case except `serverUpdatedAt` must appear exactly once.

Correction if it reports an *extra* `server_updated_at`: a `try container.encode(serverUpdatedAt, ...)` line was copied in with the rest. The device never sends that column.

- [ ] **Step 5: Check the row keys against the migration**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
grep -oE '= "[a-z0-9_]+"' App/Sync/SyncRows.swift | sed 's/= "//; s/"//' | sort -u > /tmp/row-keys.txt
grep -oE '^    [a-z0-9_]+ ' supabase/migrations/20260919120000_voice_milestone.sql | tr -d ' ' | sort -u > /tmp/sql-cols.txt
comm -23 /tmp/row-keys.txt /tmp/sql-cols.txt
grep -c "encodeIfPresent" App/Sync/SyncRows.swift || true
grep -c "container.encode(serverUpdatedAt" App/Sync/SyncRows.swift || true
```
Expected: `comm` prints nothing, meaning every snake_case coding key on the left is a real column in the migration; a name that appears here is a typo to fix before committing, not something to work around. Both greps print `0`: `encodeIfPresent` is what makes a key set depend on a row's contents, and `server_updated_at` is the server's column.

- [ ] **Step 6: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Sync/SyncRows.swift AppTests/SyncRowTests.swift
git commit -m "feat(sync): Codable row structs mirroring the server columns, plus the storage path

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: The RemoteStore protocol with a trigger-faithful in-memory double, and the SwiftData LocalStore

**Files:**
- Create: `App/Sync/RemoteStore.swift`
- Create: `App/Sync/LocalStore.swift`
- Create: `AppTests/LocalStoreTests.swift`

**Interfaces:**
- Consumes: the row structs, `SyncRow` and `RemoteAudioPath` (Task 8); `SyncTable`, `SyncState` (Task 3); `DeletedRecord`, `Tombstone`, `MediaStore.write(_:as:)`, `animalID`, `recordingID`, `VoiceTagSeed.builtInID` (Task 7); `Animal`, `VoiceRecording`, `Vocalization`, `VoiceTag`, `Segment`, `InMemoryMediaStore`, `TestSupport`, `VoiceFixtures` (Plans A and B).
- Produces:
  - `protocol RemoteStore` with `upsertAnimals/Recordings/Vocalizations/Tags`, `fetchAnimals/Recordings/Vocalizations/Tags(since:offset:limit:)`, `uploadAudio(path:data:)`, `downloadAudio(path:)`, `removeAudio(paths:)`.
  - `final class InMemoryRemoteStore: RemoteStore` with `animals/recordings/vocalizations/tags: [UUID: Row]`, `audio: [String: Data]`, `uploadCount`, `downloadCount`, `removedPaths`, `failNextCall`, `beforeCall`, `pageCap`, `serverClock`, `acceptUpdatedAtUntil`, `enum Failure: Error { case scripted, notFound }`.
  - `struct DeletedRecordInfo: Equatable { let table: SyncTable; let recordID: UUID; let deletedAt: Date; let audioFilename: String? }`.
  - `struct PendingAudioRef: Equatable { let recordingID: UUID; let filename: String }`.
  - `@MainActor protocol LocalStore: AnyObject` with `userID`, `changedAnimals/Recordings/Vocalizations/Tags(after:)`, `pendingTombstones(for:)`, `markTombstonesPushed(_:in:)`, `apply(animals:)`, `apply(recordings:)`, `apply(vocalizations:)`, `apply(tags:)`, `relinkOrphans()`, `pendingAudioUploads(limit:)`, `loadAudio(named:)`, `markAudioUploaded(recordingID:at:)`, `save()`. `relinkOrphans()` is the end-of-cycle pass that attaches a child pulled before its parent (verification defect D-D15).
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
    private var retained: [ModelContainer] = []

    private func makeStore() throws -> (SwiftDataLocalStore, ModelContext, InMemoryMediaStore) {
        let container = try TestSupport.container()
        retained.append(container)
        let context = container.mainContext
        let media = InMemoryMediaStore()
        return (SwiftDataLocalStore(context: context, mediaStore: media, userID: userID), context, media)
    }

    // MARK: push side

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
        XCTAssertNil(rows[0].serverUpdatedAt, "the server owns that column")
    }

    /// `deleted_at` is read from the tombstone table, never hard-coded to nil, so a row that is
    /// somehow both live and tombstoned pushes as the tombstone rather than as a resurrection.
    func testChangedRowsCarryAnExistingTombstoneRatherThanAHardCodedNil() throws {
        let (store, context, _) = try makeStore()
        let tag = VoiceTag(kind: .meaning, name: "Hungry")
        tag.updatedAt = Date(timeIntervalSince1970: 300)
        context.insert(tag)
        Tombstone.record(.voiceTags, id: tag.id, deletedAt: Date(timeIntervalSince1970: 400), in: context)
        try context.save()

        let rows = try store.changedTags(after: SyncState.epoch)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].deletedAt, Date(timeIntervalSince1970: 400))
    }

    /// The raw parent id is what gets pushed, so an unresolved relationship can never turn into a
    /// null foreign key on the server.
    func testChangedChildrenPushTheRawParentIdEvenWithoutAResolvedRelationship() throws {
        let (store, context, _) = try makeStore()
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2, animal: animal)
        context.insert(recording)
        let orphan = VoiceRecording(audioFilename: "o-audio.m4a", durationS: 1)
        orphan.animalID = UUID()
        context.insert(orphan)
        let vocalization = Vocalization(segment: Segment(startS: 0.1, endS: 0.4), features: VoiceFixtures.features())
        vocalization.recording = recording
        context.insert(vocalization)
        try context.save()

        let recordings = try store.changedRecordings(after: SyncState.epoch)
        XCTAssertEqual(recordings.count, 2)
        XCTAssertEqual(recordings.first { $0.id == recording.id }?.animalID, animal.id)
        XCTAssertEqual(recordings.first { $0.id == orphan.id }?.animalID, orphan.animalID)
        XCTAssertNotNil(recordings.first { $0.id == orphan.id }?.animalID,
                        "an unresolved parent must not become a null animal_id")

        let vocalizations = try store.changedVocalizations(after: SyncState.epoch)
        XCTAssertEqual(vocalizations[0].recordingID, recording.id)
        XCTAssertEqual(vocalizations[0].mfcc.count, 13)
    }

    /// `VoiceRecording.vocalizations` declares `inverse: \Vocalization.recordingLink`, so SwiftData
    /// can set `recordingLink` from the parent side without going through the computed `recording`
    /// door that also writes `recordingID`. The push falls back to the link, so a sound attached
    /// that way still names its parent instead of pushing a null `recording_id`.
    func testAVocalizationLinkedFromTheParentSideStillPushesItsParentId() throws {
        let (store, context, _) = try makeStore()
        let recording = VoiceRecording(audioFilename: "inv-audio.m4a", durationS: 1)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        context.insert(vocalization)
        // Attached from the parent, which is the path that bypasses the door.
        recording.vocalizations = [vocalization]
        try context.save()
        XCTAssertNotNil(vocalization.recordingLink, "SwiftData resolved the inverse")

        let rows = try store.changedVocalizations(after: SyncState.epoch)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recordingID, recording.id,
                       "an inverse-set link must not push a null recording_id")
    }

    // MARK: tombstones

    func testPendingTombstonesAreReportedPerTableAndClearedByIdOnly() throws {
        let (store, context, _) = try makeStore()
        let goneTag = UUID()
        let goneAnimal = UUID()
        Tombstone.record(.voiceTags, id: goneTag, deletedAt: Date(timeIntervalSince1970: 400), in: context)
        Tombstone.record(.animals, id: goneAnimal, deletedAt: Date(timeIntervalSince1970: 100), in: context)
        try context.save()

        XCTAssertEqual(try store.pendingTombstones(for: .voiceTags),
                       [DeletedRecordInfo(table: .voiceTags, recordID: goneTag,
                                          deletedAt: Date(timeIntervalSince1970: 400), audioFilename: nil)])

        try store.markTombstonesPushed([goneTag], in: .voiceTags)
        try store.save()

        XCTAssertTrue(try store.pendingTombstones(for: .voiceTags).isEmpty)
        XCTAssertEqual(try store.pendingTombstones(for: .animals).count, 1,
                       "another table's push must not clear this one")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 2,
                       "tombstones are flipped to pushed, never deleted, so a stale edit cannot resurrect the row")
    }

    /// Marking by id, not by a timestamp range. A tombstone written while the push was in flight
    /// keeps its place in the queue.
    func testATombstoneWrittenDuringAPushIsNotClearedByThatPush() throws {
        let (store, context, _) = try makeStore()
        let first = UUID()
        Tombstone.record(.animals, id: first, deletedAt: Date(timeIntervalSince1970: 100), in: context)
        try context.save()
        let sent = try store.pendingTombstones(for: .animals).map(\.recordID)

        // Arrives while the request is in flight, with an older timestamp than the one being sent.
        let late = UUID()
        Tombstone.record(.animals, id: late, deletedAt: Date(timeIntervalSince1970: 50), in: context)
        try context.save()

        try store.markTombstonesPushed(sent, in: .animals)
        try store.save()

        XCTAssertEqual(try store.pendingTombstones(for: .animals).map(\.recordID), [late])
    }

    func testARecordingTombstoneCarriesItsAudioFilename() throws {
        let (store, context, _) = try makeStore()
        let recording = VoiceRecording(audioFilename: "gone-audio.m4a", durationS: 1)
        context.insert(recording)
        try context.save()
        Tombstone.recordRecording(recording, in: context)
        context.delete(recording)
        try context.save()

        let pending = try store.pendingTombstones(for: .voiceRecordings)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].audioFilename, "gone-audio.m4a")
    }

    // MARK: pull side

    func testApplyInsertsNewRowsAndRelinksParents() throws {
        let (store, context, _) = try makeStore()
        let animalID = UUID()
        let recordingID = UUID()
        let now = Date(timeIntervalSince1970: 500)
        try store.apply(animals: [AnimalRow(id: animalID, userID: userID, createdAt: now, updatedAt: now,
                                            serverUpdatedAt: now, deletedAt: nil,
                                            name: "Remote", species: "horse", colorHex: "#112233",
                                            photoFilename: nil, photoThumbnailFilename: nil,
                                            tracksOutdoorTime: true, sortOrder: 1, isArchived: false, note: nil)])
        try store.apply(recordings: [VoiceRecordingRow(id: recordingID, userID: userID, createdAt: now,
                                                       updatedAt: now, serverUpdatedAt: now, deletedAt: nil,
                                                       animalID: animalID, recordedAt: now, durationS: 3,
                                                       audioFilename: "z-audio.m4a", statusRaw: "analyzed",
                                                       errorMessage: nil, note: "", activityTag: nil,
                                                       meaningTag: "Hungry", userConfidence: 2,
                                                       editedAt: nil, audioUploadedAt: now)])
        try store.save()

        let animals = try context.fetch(FetchDescriptor<Animal>())
        XCTAssertEqual(animals.map(\.name), ["Remote"])
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>())
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].animalID, animalID)
        XCTAssertEqual(recordings[0].animal?.id, animalID)
        XCTAssertEqual(recordings[0].meaningTag, "Hungry")
        XCTAssertEqual(recordings[0].audioUploadedAt, now)
    }

    /// A child can arrive before its parent. It keeps the raw id, so the next push still names the
    /// right parent, and the relationship is filled in when the parent turns up.
    func testAChildWhoseParentHasNotArrivedKeepsItsRawParentId() throws {
        let (store, context, _) = try makeStore()
        let animalID = UUID()
        let now = Date(timeIntervalSince1970: 500)
        try store.apply(recordings: [VoiceRecordingRow(id: UUID(), userID: userID, createdAt: now,
                                                       updatedAt: now, serverUpdatedAt: now, deletedAt: nil,
                                                       animalID: animalID, recordedAt: now, durationS: 1,
                                                       audioFilename: "e-audio.m4a", statusRaw: "recorded",
                                                       errorMessage: nil, note: "", activityTag: nil,
                                                       meaningTag: nil, userConfidence: nil,
                                                       editedAt: nil, audioUploadedAt: nil)])
        try store.save()

        let recording = try XCTUnwrap(try context.fetch(FetchDescriptor<VoiceRecording>()).first)
        XCTAssertEqual(recording.animalID, animalID)
        XCTAssertNil(recording.animal)

        // The parent arrives on a later pull and the relationship is resolved.
        try store.apply(animals: [AnimalRow(id: animalID, userID: userID, createdAt: now, updatedAt: now,
                                            serverUpdatedAt: now, deletedAt: nil, name: "Late", species: "cat",
                                            colorHex: "#000000", photoFilename: nil, photoThumbnailFilename: nil,
                                            tracksOutdoorTime: true, sortOrder: 0, isArchived: false, note: nil)])
        var later = try store.changedRecordings(after: SyncState.epoch)[0]
        later.updatedAt = Date(timeIntervalSince1970: 900)
        try store.apply(recordings: [later])
        try store.save()

        XCTAssertEqual(try XCTUnwrap(try context.fetch(FetchDescriptor<VoiceRecording>()).first).animal?.name, "Late")
    }

    func testApplyKeepsTheNewerSideOnConflict() throws {
        let (store, context, _) = try makeStore()
        let animal = Animal(name: "Local wins", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 900)
        context.insert(animal)
        try context.save()

        let older = AnimalRow(id: animal.id, userID: userID, createdAt: SyncState.epoch,
                              updatedAt: Date(timeIntervalSince1970: 800), serverUpdatedAt: nil, deletedAt: nil,
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

    /// A tombstone is an edit like any other and loses to a newer local change.
    func testAnOlderRemoteTombstoneLosesToANewerLocalEdit() throws {
        let (store, context, media) = try makeStore()
        let recording = VoiceRecording(audioFilename: "keep-audio.m4a", durationS: 1)
        recording.updatedAt = Date(timeIntervalSince1970: 5000)
        context.insert(recording)
        try context.save()
        try media.write(Data([9]), as: "keep-audio.m4a")

        try store.apply(recordings: [VoiceRecordingRow.tombstone(id: recording.id, userID: userID,
                                                                 deletedAt: Date(timeIntervalSince1970: 4000))])
        try store.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).count, 1)
        XCTAssertTrue(media.exists("keep-audio.m4a"), "a tombstone that lost must not take the audio with it")
        XCTAssertTrue(try store.pendingTombstones(for: .voiceRecordings).isEmpty)
    }

    func testANewerRemoteTombstoneDeletesLocallyAndIsRetainedAsPushed() throws {
        let (store, context, media) = try makeStore()
        let recording = VoiceRecording(audioFilename: "gone-audio.m4a", durationS: 1)
        recording.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(recording)
        try context.save()
        try media.write(Data([9]), as: "gone-audio.m4a")

        try store.apply(recordings: [VoiceRecordingRow.tombstone(id: recording.id, userID: userID,
                                                                 deletedAt: Date(timeIntervalSince1970: 2000))])
        try store.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).count, 0)
        XCTAssertFalse(media.exists("gone-audio.m4a"), "the audio file goes with the recording")
        XCTAssertTrue(try store.pendingTombstones(for: .voiceRecordings).isEmpty,
                      "a pulled tombstone is already pushed and must never be sent back")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 1,
                       "it is still retained, so a stale edit cannot resurrect the row")
    }

    /// The reason pulled tombstones are kept: another device's edit, made before it heard about
    /// the delete, must not bring the row back.
    func testAnEditOlderThanTheTombstoneDoesNotResurrectTheRow() throws {
        let (store, context, _) = try makeStore()
        let id = UUID()
        Tombstone.recordPulled(.voiceTags, id: id, deletedAt: Date(timeIntervalSince1970: 3000), in: context)
        try context.save()

        try store.apply(tags: [VoiceTagRow(id: id, userID: userID, createdAt: SyncState.epoch,
                                           updatedAt: Date(timeIntervalSince1970: 2000), serverUpdatedAt: nil,
                                           deletedAt: nil, kindRaw: "meaning", name: "Zombie",
                                           isBuiltIn: false, sortOrder: 0)])
        try store.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).count, 0)

        // An edit genuinely newer than the delete is a real undelete and is allowed through.
        try store.apply(tags: [VoiceTagRow(id: id, userID: userID, createdAt: SyncState.epoch,
                                           updatedAt: Date(timeIntervalSince1970: 4000), serverUpdatedAt: nil,
                                           deletedAt: nil, kindRaw: "meaning", name: "Back on purpose",
                                           isBuiltIn: false, sortOrder: 0)])
        try store.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).map(\.name), ["Back on purpose"])
    }

    /// A pulled animal tombstone cannot leave its recordings behind: they would carry an
    /// `animalID` pointing at nothing, show up under no animal, and hold on to their audio files
    /// forever.
    func testAPulledAnimalTombstoneTakesItsRecordingsAndAudioWithIt() throws {
        let (store, context, media) = try makeStore()
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "cascade-audio.m4a", durationS: 1, animal: animal)
        context.insert(recording)
        let vocalization = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        vocalization.recording = recording
        context.insert(vocalization)
        try context.save()
        try media.write(Data([1]), as: "cascade-audio.m4a")

        // A recording that belongs to nobody must survive: the cascade is scoped by animalID.
        let unrelated = VoiceRecording(audioFilename: "keep-audio.m4a", durationS: 1)
        context.insert(unrelated)
        try context.save()
        try media.write(Data([2]), as: "keep-audio.m4a")

        try store.apply(animals: [AnimalRow.tombstone(id: animal.id, userID: userID,
                                                      deletedAt: Date(timeIntervalSince1970: 2000))])
        try store.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Animal>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).map(\.audioFilename),
                       ["keep-audio.m4a"], "only the deleted animal's recordings go")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 0)
        XCTAssertFalse(media.exists("cascade-audio.m4a"), "the audio file goes with the recording")
        XCTAssertTrue(media.exists("keep-audio.m4a"))

        // Three tombstones: the animal, its recording, its sound. All pulled, so none is ever sent
        // back and none can be resurrected by a stale edit from another device.
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 3)
        XCTAssertTrue(try store.pendingTombstones(for: .animals).isEmpty)
        XCTAssertTrue(try store.pendingTombstones(for: .voiceRecordings).isEmpty)
        XCTAssertTrue(try store.pendingTombstones(for: .vocalizations).isEmpty)
    }

    /// Moved here from Task 7, where it fetched a row and reassigned its name to the value it
    /// already held and so could not fail. This one calls the pull path: a `VoiceTagRow` carrying
    /// the deterministic built-in id merges onto the seeded row instead of inserting a second one,
    /// which is what makes a store reset followed by a full pull come out with one "Eating".
    func testAPulledBuiltInTagMergesOntoTheSeededRow() throws {
        let (store, context, _) = try makeStore()
        _ = try VoiceTagSeed.seedIfNeeded(context: context)
        let before = try context.fetchCount(FetchDescriptor<VoiceTag>())
        let id = VoiceTagSeed.builtInID(kind: .activity, name: "Eating")
        let seeded = try XCTUnwrap(try context.fetch(FetchDescriptor<VoiceTag>()).first { $0.id == id })
        seeded.updatedAt = Date(timeIntervalSince1970: 100)
        try context.save()

        try store.apply(tags: [VoiceTagRow(id: id, userID: userID, createdAt: SyncState.epoch,
                                           updatedAt: Date(timeIntervalSince1970: 500),
                                           serverUpdatedAt: Date(timeIntervalSince1970: 500),
                                           deletedAt: nil, kindRaw: "activity", name: "Eating a meal",
                                           isBuiltIn: true, sortOrder: 0)])
        try store.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), before,
                       "the pulled row merged onto the seeded one rather than doubling it")
        XCTAssertEqual(seeded.name, "Eating a meal", "and it is the same object that changed")

        // A different id, same name, is a different tag: the merge is by id, never by name.
        try store.apply(tags: [VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                                           updatedAt: Date(timeIntervalSince1970: 600),
                                           serverUpdatedAt: Date(timeIntervalSince1970: 600),
                                           deletedAt: nil, kindRaw: "activity", name: "Eating a meal",
                                           isBuiltIn: false, sortOrder: 99)])
        try store.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), before + 1)
    }

    // MARK: relink (verification defect D-D15)

    /// The child arrives first, the parent second, and the relink pass at the end of the cycle
    /// makes the relationship. This matters more than it looks: `VoiceRecording.vocalizations` is
    /// the inverse of `recordingLink`, so an unlinked sound is invisible to `sortedVocalizations`,
    /// which is what `Tombstone.recordRecording` and `cascadeDelete` iterate. Without the relink,
    /// deleting the recording would leave that sound alive on the server forever.
    func testAChildPulledBeforeItsParentIsLinkedByTheRelinkPass() throws {
        let (store, context, _) = try makeStore()
        let animalID = UUID()
        let recordingID = UUID()
        let when = Date(timeIntervalSince1970: 2_000)

        // Child first, and one level up too: the vocalization names a recording that is not here,
        // and the recording will name an animal that is not here either.
        try store.apply(vocalizations: [
            VocalizationRow(id: UUID(), userID: userID, createdAt: when, updatedAt: when,
                            serverUpdatedAt: when, deletedAt: nil, recordingID: recordingID,
                            startS: 0, endS: 0.4, f0Mean: 500, f0Min: 480, f0Max: 520,
                            f0Slope: 10, voicedFraction: 0.8, rmsDb: -22, spectralCentroidHz: 1_200,
                            mfcc: [1, 2, 3], activityTag: nil, meaningTag: nil,
                            userConfidence: nil, overridden: false),
        ])
        try store.save()
        let vocalization = try XCTUnwrap(try context.fetch(FetchDescriptor<Vocalization>()).first)
        XCTAssertNil(vocalization.recordingLink, "the parent has not arrived yet")
        XCTAssertEqual(vocalization.recordingID, recordingID, "but the raw id is kept")

        // Parent second.
        try store.apply(recordings: [
            VoiceRecordingRow(id: recordingID, userID: userID, createdAt: when, updatedAt: when,
                              serverUpdatedAt: when, deletedAt: nil, animalID: animalID,
                              recordedAt: when, durationS: 1, audioFilename: "r-audio.m4a",
                              statusRaw: "recorded", errorMessage: nil, note: "", activityTag: nil,
                              meaningTag: nil, userConfidence: nil, editedAt: nil,
                              audioUploadedAt: nil),
        ])
        try store.apply(animals: [
            AnimalRow(id: animalID, userID: userID, createdAt: when, updatedAt: when,
                      serverUpdatedAt: when, deletedAt: nil, name: "Miso", species: "cat",
                      colorHex: "", photoFilename: nil, photoThumbnailFilename: nil,
                      tracksOutdoorTime: false, sortOrder: 0, isArchived: false, note: nil),
        ])
        try store.save()

        // What the engine does once all four tables are in.
        try store.relinkOrphans()
        try store.save()

        let recording = try XCTUnwrap(try context.fetch(FetchDescriptor<VoiceRecording>()).first)
        XCTAssertEqual(vocalization.recordingLink?.id, recordingID)
        XCTAssertEqual(recording.sortedVocalizations.count, 1,
                       "the sound has to be reachable from its recording, or a delete cannot tombstone it")
        XCTAssertEqual(recording.animal?.id, animalID, "and the level above is relinked too")
    }

    // MARK: audio

    func testPendingAudioUploadsReturnMetadataOnlyAndAreCapped() throws {
        let (store, context, media) = try makeStore()
        for index in 0..<5 {
            let recording = VoiceRecording(audioFilename: "ready\(index)-audio.m4a", durationS: 1)
            recording.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            context.insert(recording)
            try media.write(Data([UInt8(index)]), as: "ready\(index)-audio.m4a")
        }
        let missingFile = VoiceRecording(audioFilename: "absent-audio.m4a", durationS: 1)
        let alreadyUp = VoiceRecording(audioFilename: "done-audio.m4a", durationS: 1)
        alreadyUp.audioUploadedAt = Date(timeIntervalSince1970: 10)
        context.insert(missingFile)
        context.insert(alreadyUp)
        try media.write(Data([3]), as: "done-audio.m4a")
        try context.save()

        let pending = try store.pendingAudioUploads(limit: 3)
        XCTAssertEqual(pending.count, 3, "the cap is honoured")
        XCTAssertEqual(pending.map(\.filename), ["ready0-audio.m4a", "ready1-audio.m4a", "ready2-audio.m4a"],
                       "oldest first, so a backlog drains in order")
        XCTAssertFalse(pending.contains { $0.filename == "absent-audio.m4a" })
        XCTAssertFalse(pending.contains { $0.filename == "done-audio.m4a" })

        XCTAssertEqual(try store.loadAudio(named: "ready0-audio.m4a"), Data([0]))
        XCTAssertNil(try store.loadAudio(named: "absent-audio.m4a"))
    }

    func testMarkingAudioUploadedMovesUpdatedAtSoTheFlagIsPushed() throws {
        let (store, context, media) = try makeStore()
        let ready = VoiceRecording(audioFilename: "ready-audio.m4a", durationS: 1)
        context.insert(ready)
        try context.save()
        try media.write(Data([1, 2]), as: "ready-audio.m4a")

        let stamp = Date(timeIntervalSince1970: 3000)
        try store.markAudioUploaded(recordingID: ready.id, at: stamp)
        try store.save()
        XCTAssertEqual(ready.audioUploadedAt, stamp)
        XCTAssertEqual(ready.updatedAt, stamp, "the flag has to be pushed, so updatedAt moves with it")
        XCTAssertTrue(try store.pendingAudioUploads(limit: 10).isEmpty)
    }

    // MARK: the double

    func testInMemoryRemoteStoreStampsTheServerCursorLikeTheTrigger() async throws {
        let remote = InMemoryRemoteStore()
        let now = Date(timeIntervalSince1970: 600)
        let row = VoiceTagRow(id: UUID(), userID: userID, createdAt: now, updatedAt: now,
                              serverUpdatedAt: nil, deletedAt: nil,
                              kindRaw: "meaning", name: "Hungry", isBuiltIn: true, sortOrder: 0)
        try await remote.upsertTags([row])

        let stored = try XCTUnwrap(remote.tags[row.id])
        XCTAssertNotNil(stored.serverUpdatedAt, "the server sets the cursor column, not the device")
        let fetched = try await remote.fetchTags(since: SyncState.epoch, offset: 0, limit: 10)
        XCTAssertEqual(fetched.map(\.id), [row.id])
        XCTAssertTrue(try await remote.fetchTags(since: Date.distantFuture, offset: 0, limit: 10).isEmpty)
    }

    /// The double enforces the same last-write-wins and sticky-delete rules as `sync_row_guard()`,
    /// so an engine test that passes here would pass against Postgres.
    func testInMemoryRemoteStoreRefusesAStaleWriteAndKeepsDeletesSticky() async throws {
        let remote = InMemoryRemoteStore()
        let id = UUID()
        let newer = VoiceTagRow(id: id, userID: userID, createdAt: SyncState.epoch,
                                updatedAt: Date(timeIntervalSince1970: 2000), serverUpdatedAt: nil,
                                deletedAt: nil, kindRaw: "meaning", name: "Newer", isBuiltIn: false, sortOrder: 0)
        try await remote.upsertTags([newer])

        var older = newer
        older.updatedAt = Date(timeIntervalSince1970: 1000)
        older.name = "Older"
        try await remote.upsertTags([older])
        XCTAssertEqual(remote.tags[id]?.name, "Newer", "an older write must not overwrite a newer row")

        try await remote.upsertTags([VoiceTagRow.tombstone(id: id, userID: userID,
                                                           deletedAt: Date(timeIntervalSince1970: 3000))])
        var resurrect = newer
        resurrect.updatedAt = Date(timeIntervalSince1970: 4000)
        resurrect.name = "Zombie"
        try await remote.upsertTags([resurrect])
        XCTAssertNotNil(remote.tags[id]?.deletedAt, "deleted_at is sticky")
    }

    func testInMemoryRemoteStorePagesAndCanCapAPageBelowTheRequestedLimit() async throws {
        let remote = InMemoryRemoteStore()
        remote.pageCap = 3
        for index in 0..<7 {
            try await remote.upsertTags([VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                                                     updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                                                     serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                     name: "tag\(index)", isBuiltIn: false, sortOrder: index)])
        }
        let first = try await remote.fetchTags(since: SyncState.epoch, offset: 0, limit: 500)
        XCTAssertEqual(first.count, 3, "the double caps below the requested limit, like a server can")
        let second = try await remote.fetchTags(since: SyncState.epoch, offset: 3, limit: 500)
        XCTAssertEqual(second.count, 3)
        let third = try await remote.fetchTags(since: SyncState.epoch, offset: 6, limit: 500)
        XCTAssertEqual(third.count, 1)
        XCTAssertTrue(try await remote.fetchTags(since: SyncState.epoch, offset: 7, limit: 500).isEmpty)
        XCTAssertEqual(Set(first.map(\.id)).union(second.map(\.id)).union(third.map(\.id)).count, 7)
    }

    func testInMemoryRemoteStoreRecordsAudioCalls() async throws {
        let remote = InMemoryRemoteStore()
        try await remote.uploadAudio(path: "u/x.m4a", data: Data([7]))
        XCTAssertEqual(remote.uploadCount, 1)
        XCTAssertEqual(try await remote.downloadAudio(path: "u/x.m4a"), Data([7]))

        try await remote.removeAudio(paths: ["u/x.m4a"])
        XCTAssertEqual(remote.removedPaths, ["u/x.m4a"])
        XCTAssertNil(remote.audio["u/x.m4a"])

        remote.failNextCall = true
        do {
            try await remote.upsertTags([VoiceTagRow.tombstone(id: UUID(), userID: userID, deletedAt: Date())])
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
/// keeps the test double trivial; no generics across the protocol boundary, no type erasure.
///
/// `fetch` takes `offset` as well as `since` because the cursor is `(server_updated_at, offset)`:
/// a page boundary can land in the middle of a group of rows sharing one timestamp, and the offset
/// says how many of that group have already been consumed.
protocol RemoteStore {
    func upsertAnimals(_ rows: [AnimalRow]) async throws
    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws
    func upsertVocalizations(_ rows: [VocalizationRow]) async throws
    func upsertTags(_ rows: [VoiceTagRow]) async throws

    func fetchAnimals(since: Date, offset: Int, limit: Int) async throws -> [AnimalRow]
    func fetchRecordings(since: Date, offset: Int, limit: Int) async throws -> [VoiceRecordingRow]
    func fetchVocalizations(since: Date, offset: Int, limit: Int) async throws -> [VocalizationRow]
    func fetchTags(since: Date, offset: Int, limit: Int) async throws -> [VoiceTagRow]

    func uploadAudio(path: String, data: Data) async throws
    func downloadAudio(path: String) async throws -> Data
    /// Removes Storage objects for recordings that have been tombstoned.
    func removeAudio(paths: [String]) async throws
}

// Account deletion is deliberately not part of this protocol. It is a one-shot auth operation, not
// part of a sync cycle, and `AuthService` calls `client.rpc(ServerFunctions.deleteMyAccount)`
// directly so the wipe-and-sign-out ordering stays in the one place that owns transitions.

/// Test double. Holds rows in dictionaries keyed by id and reproduces, in Swift, exactly what
/// `sync_row_guard()` does in Postgres: it stamps `server_updated_at`, refuses a write whose
/// `updated_at` is not newer, and keeps `deleted_at` sticky. A sync test that passes against this
/// is testing the same rules the database enforces.
final class InMemoryRemoteStore: RemoteStore {
    enum Failure: Error { case scripted, notFound }

    var animals: [UUID: AnimalRow] = [:]
    var recordings: [UUID: VoiceRecordingRow] = [:]
    var vocalizations: [UUID: VocalizationRow] = [:]
    var tags: [UUID: VoiceTagRow] = [:]
    var audio: [String: Data] = [:]

    var uploadCount = 0
    var downloadCount = 0
    var removedPaths: [String] = []
    var failNextCall = false
    /// Runs at the start of every call, before the scripted failure is considered. A test uses it
    /// to make something happen "while the request is in flight", such as bumping the sync
    /// generation, without needing real concurrency.
    var beforeCall: (() -> Void)?

    /// The largest page this double will return, whatever limit is asked for. A real server may
    /// also cap a page, which is why the engine stops on an empty page rather than on a short one.
    var pageCap = Int.max

    /// Stands in for the server clock. Advanced a millisecond per stamped row so `server_updated_at`
    /// is strictly increasing and the paging tests are deterministic.
    var serverClock = Date(timeIntervalSince1970: 1_000_000)

    /// The ceiling `merge` clamps an incoming `updated_at` to, the twin of the trigger's
    /// `now() + interval '5 minutes'`. Deliberately a separate property from `serverClock`:
    /// `serverClock` is a synthetic monotonic stamp source that the paging tests move around at
    /// will, while this is a wall-clock bound, so tying them together would clamp every ordinary
    /// fixture. A test that wants to prove the clamp fires lowers this value.
    var acceptUpdatedAtUntil = Date().addingTimeInterval(5 * 60)

    init() {}

    private func checkFailure() throws {
        beforeCall?()
        if failNextCall {
            failNextCall = false
            throw Failure.scripted
        }
    }

    private func stamp() -> Date {
        serverClock += 0.001
        return serverClock
    }

    /// The Swift twin of `sync_row_guard()`.
    private func merge<Row: SyncRow>(_ incoming: Row, into store: inout [UUID: Row]) {
        var row = incoming
        // Same clamp the trigger applies as its first statement, and for the same reason: a device
        // clock stamped in 2030 would otherwise freeze the row against every later edit
        // (verification defect D-D12).
        row.updatedAt = min(row.updatedAt, acceptUpdatedAtUntil)
        if let old = store[incoming.id] {
            row.deletedAt = old.deletedAt ?? row.deletedAt
            if row.updatedAt <= old.updatedAt { return }
        }
        row.serverUpdatedAt = stamp()
        store[row.id] = row
    }

    private func page<Row: SyncRow>(_ store: [UUID: Row], since: Date, offset: Int, limit: Int) -> [Row] {
        let ordered = store.values
            .filter { ($0.serverUpdatedAt ?? .distantPast) >= since }
            .sorted {
                let left = $0.serverUpdatedAt ?? .distantPast
                let right = $1.serverUpdatedAt ?? .distantPast
                // Ordered by the cursor column then by id, so the order is total and offset paging
                // inside one timestamp is stable.
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
        guard offset >= 0, offset < ordered.count else { return [] }
        let size = max(0, min(limit, pageCap))
        return Array(ordered[offset..<min(offset + size, ordered.count)])
    }

    func upsertAnimals(_ rows: [AnimalRow]) async throws {
        try checkFailure()
        for row in rows { merge(row, into: &animals) }
    }

    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws {
        try checkFailure()
        for row in rows { merge(row, into: &recordings) }
    }

    func upsertVocalizations(_ rows: [VocalizationRow]) async throws {
        try checkFailure()
        for row in rows { merge(row, into: &vocalizations) }
    }

    func upsertTags(_ rows: [VoiceTagRow]) async throws {
        try checkFailure()
        for row in rows { merge(row, into: &tags) }
    }

    func fetchAnimals(since: Date, offset: Int, limit: Int) async throws -> [AnimalRow] {
        try checkFailure()
        return page(animals, since: since, offset: offset, limit: limit)
    }

    func fetchRecordings(since: Date, offset: Int, limit: Int) async throws -> [VoiceRecordingRow] {
        try checkFailure()
        return page(recordings, since: since, offset: offset, limit: limit)
    }

    func fetchVocalizations(since: Date, offset: Int, limit: Int) async throws -> [VocalizationRow] {
        try checkFailure()
        return page(vocalizations, since: since, offset: offset, limit: limit)
    }

    func fetchTags(since: Date, offset: Int, limit: Int) async throws -> [VoiceTagRow] {
        try checkFailure()
        return page(tags, since: since, offset: offset, limit: limit)
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

    func removeAudio(paths: [String]) async throws {
        try checkFailure()
        removedPaths.append(contentsOf: paths)
        for path in paths { audio[path] = nil }
    }
}
```

- [ ] **Step 4: Write the local side**

Create `App/Sync/LocalStore.swift`:
```swift
import AnimalVoiceAudio
import Foundation
import SwiftData

struct DeletedRecordInfo: Equatable {
    let table: SyncTable
    let recordID: UUID
    let deletedAt: Date
    /// Only ever set for `voice_recordings`: the Storage object that has to go with the row.
    let audioFilename: String?
}

/// What the engine needs to know about a file that is waiting to go up. Deliberately not the bytes:
/// a backlog of fifty recordings must not all be in memory at once.
struct PendingAudioRef: Equatable {
    let recordingID: UUID
    let filename: String
}

/// Everything the sync engine needs from the device. Main actor because a `ModelContext` is.
@MainActor
protocol LocalStore: AnyObject {
    var userID: UUID { get }

    func changedAnimals(after: Date) throws -> [AnimalRow]
    func changedRecordings(after: Date) throws -> [VoiceRecordingRow]
    func changedVocalizations(after: Date) throws -> [VocalizationRow]
    func changedTags(after: Date) throws -> [VoiceTagRow]

    /// Tombstones for this table that have not been sent yet.
    func pendingTombstones(for table: SyncTable) throws -> [DeletedRecordInfo]
    /// Marks exactly these ids sent, in this table only. Never a timestamp range: a tombstone
    /// written while the request was in flight has to keep its place in the queue.
    func markTombstonesPushed(_ ids: [UUID], in table: SyncTable) throws

    func apply(animals: [AnimalRow]) throws
    func apply(recordings: [VoiceRecordingRow]) throws
    func apply(vocalizations: [VocalizationRow]) throws
    func apply(tags: [VoiceTagRow]) throws

    /// Attaches any child whose raw parent id now resolves but whose SwiftData link is still nil.
    /// The engine calls it once at the end of a pull cycle, after all four tables have been
    /// applied. Nothing else revisits such a child: its own `updatedAt` does not change when the
    /// parent finally arrives, so without this pass the link is never made (verification defect
    /// D-D15).
    func relinkOrphans() throws

    /// Metadata for at most `limit` files, oldest first.
    func pendingAudioUploads(limit: Int) throws -> [PendingAudioRef]
    /// Reads one file. The engine calls this one at a time, just before each upload.
    func loadAudio(named filename: String) throws -> Data?
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
        let graves = try tombstoneIndex(for: .animals)
        return try fetchAll(Animal.self).filter { $0.updatedAt > after }.map { animal in
            AnimalRow(id: animal.id, userID: userID, createdAt: animal.createdAt, updatedAt: animal.updatedAt,
                      serverUpdatedAt: nil, deletedAt: graves[animal.id],
                      name: animal.name, species: animal.species, colorHex: animal.colorHex,
                      photoFilename: animal.photoFilename, photoThumbnailFilename: animal.photoThumbnailFilename,
                      tracksOutdoorTime: animal.tracksOutdoorTime, sortOrder: animal.sortOrder,
                      isArchived: animal.isArchived, note: animal.note)
        }
    }

    func changedRecordings(after: Date) throws -> [VoiceRecordingRow] {
        let graves = try tombstoneIndex(for: .voiceRecordings)
        return try fetchAll(VoiceRecording.self).filter { $0.updatedAt > after }.map { recording in
            VoiceRecordingRow(id: recording.id, userID: userID, createdAt: recording.createdAt,
                              updatedAt: recording.updatedAt, serverUpdatedAt: nil,
                              deletedAt: graves[recording.id],
                              // The raw id, not `animal?.id`: an unresolved relationship must never
                              // become a null animal_id for a parent that exists.
                              animalID: recording.animalID,
                              recordedAt: recording.recordedAt, durationS: recording.durationS,
                              audioFilename: recording.audioFilename, statusRaw: recording.statusRaw,
                              errorMessage: recording.errorMessage, note: recording.note,
                              activityTag: recording.activityTag, meaningTag: recording.meaningTag,
                              userConfidence: recording.userConfidence, editedAt: recording.editedAt,
                              audioUploadedAt: recording.audioUploadedAt)
        }
    }

    func changedVocalizations(after: Date) throws -> [VocalizationRow] {
        let graves = try tombstoneIndex(for: .vocalizations)
        return try fetchAll(Vocalization.self).filter { $0.updatedAt > after }.map { vocalization in
            VocalizationRow(id: vocalization.id, userID: userID, createdAt: vocalization.createdAt,
                            updatedAt: vocalization.updatedAt, serverUpdatedAt: nil,
                            deletedAt: graves[vocalization.id],
                            // `recordingLink` is the fallback, not the source of truth. SwiftData
                            // can set it on its own through the inverse declared on
                            // `VoiceRecording.vocalizations`, which does not go through the
                            // computed `recording` door and so does not write `recordingID`. The
                            // reverse cannot happen: the door always writes both. There is no
                            // matching fallback on `animalID` because `Animal` declares no
                            // recordings relationship, so nothing but the door can write
                            // `animalLink`.
                            recordingID: vocalization.recordingID ?? vocalization.recordingLink?.id,
                            startS: vocalization.startS,
                            endS: vocalization.endS, f0Mean: vocalization.f0Mean, f0Min: vocalization.f0Min,
                            f0Max: vocalization.f0Max, f0Slope: vocalization.f0Slope,
                            voicedFraction: vocalization.voicedFraction, rmsDb: vocalization.rmsDb,
                            spectralCentroidHz: vocalization.spectralCentroidHz, mfcc: vocalization.mfcc,
                            activityTag: vocalization.activityTag, meaningTag: vocalization.meaningTag,
                            userConfidence: vocalization.userConfidence, overridden: vocalization.overridden)
        }
    }

    func changedTags(after: Date) throws -> [VoiceTagRow] {
        let graves = try tombstoneIndex(for: .voiceTags)
        return try fetchAll(VoiceTag.self).filter { $0.updatedAt > after }.map { tag in
            VoiceTagRow(id: tag.id, userID: userID, createdAt: tag.createdAt, updatedAt: tag.updatedAt,
                        serverUpdatedAt: nil, deletedAt: graves[tag.id],
                        kindRaw: tag.kindRaw, name: tag.name, isBuiltIn: tag.isBuiltIn,
                        sortOrder: tag.sortOrder)
        }
    }

    // MARK: tombstones

    func pendingTombstones(for table: SyncTable) throws -> [DeletedRecordInfo] {
        try tombstones(for: table)
            .filter { !$0.pushed }
            .sorted { $0.deletedAt < $1.deletedAt }
            .map { DeletedRecordInfo(table: table, recordID: $0.recordID,
                                     deletedAt: $0.deletedAt, audioFilename: $0.audioFilename) }
    }

    func markTombstonesPushed(_ ids: [UUID], in table: SyncTable) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        for record in try tombstones(for: table) where wanted.contains(record.recordID) {
            record.pushed = true
        }
    }

    // MARK: pull side

    func apply(animals rows: [AnimalRow]) throws {
        let existing = try byID(Animal.self)
        let graves = try tombstoneIndex(for: .animals)
        for row in rows {
            let local = existing[row.id]
            if let deletedAt = row.deletedAt {
                // A tombstone is an edit like any other: it wins only when it is newer.
                guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
                if let local {
                    if let photo = local.photoFilename { mediaStore.delete(photo) }
                    if let thumb = local.photoThumbnailFilename { mediaStore.delete(thumb) }
                    try cascadeDelete(animalID: row.id, deletedAt: deletedAt)
                    context.delete(local)
                }
                Tombstone.recordPulled(.animals, id: row.id, deletedAt: deletedAt, in: context)
                continue
            }
            if let buried = graves[row.id], row.updatedAt <= buried { continue }
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
        let graves = try tombstoneIndex(for: .voiceRecordings)
        for row in rows {
            let local = existing[row.id]
            if let deletedAt = row.deletedAt {
                guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
                if let local {
                    mediaStore.delete(local.audioFilename)
                    context.delete(local)
                }
                Tombstone.recordPulled(.voiceRecordings, id: row.id, deletedAt: deletedAt, in: context)
                continue
            }
            if let buried = graves[row.id], row.updatedAt <= buried { continue }
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
            // The raw id is set whether or not the parent is here yet. If the parent is already in
            // the store the link is made now; if it is not, `relinkOrphans()` makes it at the end
            // of this cycle. Nothing here waits for a later pull: the child's own `updatedAt` does
            // not move when its parent arrives, so it would never be revisited (defect D-D15).
            recording.animalID = row.animalID
            recording.animalLink = row.animalID.flatMap { animals[$0] }
            if local == nil { context.insert(recording) }
        }
    }

    func apply(vocalizations rows: [VocalizationRow]) throws {
        let existing = try byID(Vocalization.self)
        let recordings = try byID(VoiceRecording.self)
        let graves = try tombstoneIndex(for: .vocalizations)
        for row in rows {
            let local = existing[row.id]
            if let deletedAt = row.deletedAt {
                guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
                if let local { context.delete(local) }
                Tombstone.recordPulled(.vocalizations, id: row.id, deletedAt: deletedAt, in: context)
                continue
            }
            if let buried = graves[row.id], row.updatedAt <= buried { continue }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            let vocalization = local ?? Vocalization(
                segment: Segment(startS: row.startS, endS: row.endS),
                features: VocalFeatures(durationS: row.endS - row.startS,
                                        f0Mean: row.f0Mean, f0Min: row.f0Min, f0Max: row.f0Max,
                                        f0Slope: row.f0Slope, voicedFraction: row.voicedFraction,
                                        rmsDb: row.rmsDb, spectralCentroidHz: row.spectralCentroidHz,
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
            vocalization.recordingID = row.recordingID
            vocalization.recordingLink = row.recordingID.flatMap { recordings[$0] }
            if local == nil { context.insert(vocalization) }
        }
    }

    func apply(tags rows: [VoiceTagRow]) throws {
        let existing = try byID(VoiceTag.self)
        let graves = try tombstoneIndex(for: .voiceTags)
        for row in rows {
            let local = existing[row.id]
            if let deletedAt = row.deletedAt {
                guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
                if let local { context.delete(local) }
                Tombstone.recordPulled(.voiceTags, id: row.id, deletedAt: deletedAt, in: context)
                continue
            }
            if let buried = graves[row.id], row.updatedAt <= buried { continue }
            guard shouldApply(row.updatedAt, over: local?.updatedAt) else { continue }
            // `VoiceTag` takes its id at init (Plan B's fix wave), which is what lets a pulled
            // built-in land on the id `VoiceTagSeed.builtInID` would have given it.
            let tag = local ?? VoiceTag(id: row.id, kind: .activity, name: row.name)
            tag.createdAt = row.createdAt
            tag.updatedAt = row.updatedAt
            tag.kindRaw = row.kindRaw
            tag.name = row.name
            tag.isBuiltIn = row.isBuiltIn
            tag.sortOrder = row.sortOrder
            if local == nil { context.insert(tag) }
        }
    }

    // MARK: relink

    /// Attaches any child whose raw parent id resolves but whose link is still nil.
    ///
    /// `pull` walks animals, then recordings, then vocalizations, so the common case links on one
    /// pass. It is not the only case. A parent whose `server_updated_at` puts it in a page this
    /// cycle has not reached yet, a parent already consumed in an earlier cycle at a lower cursor
    /// while the child arrives now, or a cycle cancelled between two tables all leave a child
    /// unlinked, and nothing revisits it: the child's own `updatedAt` does not move when the parent
    /// arrives (verification defect D-D15).
    ///
    /// An unlinked vocalization is the expensive one. `VoiceRecording.vocalizations` is the inverse
    /// of `recordingLink`, so an unlinked sound is invisible to `sortedVocalizations`, which means
    /// `Tombstone.recordRecording` and `cascadeDelete` never tombstone it: deleting the recording
    /// would leave a live row on the server forever and an orphan locally.
    ///
    /// Cheap: both loops skip anything already linked, and an already-linked store does no writes.
    func relinkOrphans() throws {
        let animals = try byID(Animal.self)
        for recording in try fetchAll(VoiceRecording.self)
        where recording.animalLink == nil {
            guard let parentID = recording.animalID, let parent = animals[parentID] else { continue }
            recording.animalLink = parent
        }

        let recordings = try byID(VoiceRecording.self)
        for vocalization in try fetchAll(Vocalization.self)
        where vocalization.recordingLink == nil {
            guard let parentID = vocalization.recordingID, let parent = recordings[parentID] else { continue }
            vocalization.recordingLink = parent
        }
    }

    // MARK: audio

    func pendingAudioUploads(limit: Int) throws -> [PendingAudioRef] {
        guard limit > 0 else { return [] }
        return try fetchAll(VoiceRecording.self)
            .filter { $0.audioUploadedAt == nil && !$0.audioFilename.isEmpty && mediaStore.exists($0.audioFilename) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(limit)
            .map { PendingAudioRef(recordingID: $0.id, filename: $0.audioFilename) }
    }

    func loadAudio(named filename: String) throws -> Data? {
        guard mediaStore.exists(filename) else { return nil }
        return try Data(contentsOf: mediaStore.url(for: filename))
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

    /// A pulled animal tombstone takes that animal's recordings, their sounds and their audio files
    /// with it.
    ///
    /// Locally this has to happen now rather than when the children's own tombstones arrive. The
    /// server does send one tombstone per row, but they may be in a later page or a later cycle,
    /// and until they land the recordings sit in the store carrying an `animalID` that resolves to
    /// nothing: they show up under no animal in History, their audio files are never reclaimed, and
    /// `AnimalDeletionPolicy` would count them against an animal that no longer exists.
    ///
    /// The tombstones written here are marked pulled, so they are never pushed back and cannot
    /// resurrect anything, and when the server's own tombstones for these rows do arrive they find
    /// the work already done and are a no-op.
    private func cascadeDelete(animalID: UUID, deletedAt: Date) throws {
        for recording in try fetchAll(VoiceRecording.self) where recording.animalID == animalID {
            for vocalization in recording.sortedVocalizations {
                Tombstone.recordPulled(.vocalizations, id: vocalization.id, deletedAt: deletedAt, in: context)
                context.delete(vocalization)
            }
            mediaStore.delete(recording.audioFilename)
            Tombstone.recordPulled(.voiceRecordings, id: recording.id, deletedAt: deletedAt, in: context)
            context.delete(recording)
        }
    }

    private func tombstones(for table: SyncTable) throws -> [DeletedRecord] {
        let entity = table.rawValue
        return try context.fetch(FetchDescriptor<DeletedRecord>(predicate: #Predicate { $0.entity == entity }))
    }

    /// recordID to deletedAt, for every tombstone in this table whether pushed or not. Used both to
    /// carry `deleted_at` onto a pushed row and to stop a stale edit resurrecting a deleted row.
    private func tombstoneIndex(for table: SyncTable) throws -> [UUID: Date] {
        Dictionary(try tombstones(for: table).map { ($0.recordID, $0.deletedAt) },
                   uniquingKeysWith: { first, second in max(first, second) })
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `LocalStoreTests` twenty-two cases are green.

Correction if `testAVocalizationLinkedFromTheParentSideStillPushesItsParentId` fails with a nil `recordingID`: `changedVocalizations` is reading `vocalization.recordingID` alone instead of `vocalization.recordingID ?? vocalization.recordingLink?.id`.

Correction if `testAPulledAnimalTombstoneTakesItsRecordingsAndAudioWithIt` leaves the unrelated recording deleted: `cascadeDelete` is not filtering on `recording.animalID == animalID`.

Correction if `testAnEditOlderThanTheTombstoneDoesNotResurrectTheRow` fails on the second half: the `graves[row.id]` guard used `<` rather than `<=`, or it was placed after the `shouldApply` check. The tombstone guard has to come first, because there is no local row to compare against once the row is gone.

- [ ] **Step 6: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Sync/RemoteStore.swift App/Sync/LocalStore.swift AppTests/LocalStoreTests.swift
git commit -m "feat(sync): RemoteStore protocol with a trigger-faithful double, SwiftData local store

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: SyncEngine, with paged pulls, per-table tombstone clearing and a cancellation checkpoint

**Files:**
- Create: `App/Sync/SyncEngine.swift`
- Create: `AppTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `LocalStore`, `SwiftDataLocalStore`, `RemoteStore`, `InMemoryRemoteStore`, `DeletedRecordInfo`, `PendingAudioRef` (Task 9); `SyncState`, `SyncTable`, `SyncClock`, `SyncCancelled` (Task 3); the row structs, `SyncRow` and `RemoteAudioPath` (Task 8).
- Produces: `@MainActor final class SyncEngine` with `static let maxPagesPerTable = 1000`, `init(local: any LocalStore, remote: any RemoteStore, now: @escaping () -> Date = Date.init, isCurrent: @escaping () -> Bool = { true })` and `func sync(state: SyncState) async throws -> SyncState`.

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
    private var retained: [ModelContainer] = []
    private var context: ModelContext!
    private var media: InMemoryMediaStore!
    private var local: SwiftDataLocalStore!
    private var remote: InMemoryRemoteStore!
    private var engine: SyncEngine!

    override func setUpWithError() throws {
        let container = try TestSupport.container()
        retained.append(container)
        context = container.mainContext
        media = InMemoryMediaStore()
        local = SwiftDataLocalStore(context: context, mediaStore: media, userID: userID)
        remote = InMemoryRemoteStore()
        engine = SyncEngine(local: local, remote: remote)
    }

    // MARK: push

    func testPushSendsLocalRowsAndMovesTheWatermark() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(animal)
        try context.save()

        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals.count, 1)
        XCTAssertEqual(remote.animals[animal.id]?.name, "Miso")
        XCTAssertEqual(remote.animals[animal.id]?.userID, userID)
        XCTAssertEqual(state.pushedThrough(.animals), Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(state.status, .idle)
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

    /// A row dated in the future must not drag the watermark past the device clock and suppress
    /// every later push.
    func testAFutureDatedRowDoesNotPushTheWatermarkPastNow() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2000)
        engine = SyncEngine(local: local, remote: remote, now: { fixedNow })
        let animal = Animal(name: "Time traveller", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 9_999_999)
        context.insert(animal)
        try context.save()

        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals.count, 1, "the row is still pushed")
        XCTAssertEqual(state.pushedThrough(.animals), fixedNow, "but the watermark stops at now")

        let later = Animal(name: "Ordinary", species: "dog")
        later.updatedAt = Date(timeIntervalSince1970: 2500)
        context.insert(later)
        try context.save()
        engine = SyncEngine(local: local, remote: remote, now: { Date(timeIntervalSince1970: 3000) })
        _ = try await engine.sync(state: state)
        XCTAssertEqual(remote.animals.count, 2, "an ordinary later row is not suppressed")
    }

    // MARK: tombstones

    func testPushSendsTombstonesAndMarksThemPushedById() async throws {
        let gone = UUID()
        Tombstone.record(.voiceTags, id: gone, deletedAt: Date(timeIntervalSince1970: 3000), in: context)
        try context.save()

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.tags[gone]?.deletedAt, Date(timeIntervalSince1970: 3000))
        XCTAssertTrue(try local.pendingTombstones(for: .voiceTags).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DeletedRecord>()).count, 1,
                       "it is marked pushed, not deleted")
    }

    /// Clearing is per table and by exact id. A table whose upsert never ran keeps its queue.
    func testAnUnpushedTombstoneInOneTableSurvivesAnotherTablesPush() async throws {
        let goneTag = UUID()
        let goneAnimal = UUID()
        Tombstone.record(.voiceTags, id: goneTag, deletedAt: Date(timeIntervalSince1970: 3000), in: context)
        Tombstone.record(.animals, id: goneAnimal, deletedAt: Date(timeIntervalSince1970: 3000), in: context)
        try context.save()

        // The animals upsert fails; the voice_tags one has not run yet either way.
        remote.failNextCall = true
        do {
            _ = try await engine.sync(state: SyncState())
            XCTFail("expected the scripted failure to propagate")
        } catch InMemoryRemoteStore.Failure.scripted {
            // expected
        }

        XCTAssertEqual(try local.pendingTombstones(for: .animals).count, 1)
        XCTAssertEqual(try local.pendingTombstones(for: .voiceTags).count, 1,
                       "a failure in one table must not swallow another table's queue")

        _ = try await engine.sync(state: SyncState())
        XCTAssertTrue(try local.pendingTombstones(for: .animals).isEmpty)
        XCTAssertTrue(try local.pendingTombstones(for: .voiceTags).isEmpty)
    }

    /// Deleting a recording has to take its Storage object too, which is why the filename is
    /// captured in the tombstone before the local file goes.
    func testPushingARecordingTombstoneRemovesTheStorageObject() async throws {
        let recording = VoiceRecording(audioFilename: "bye-audio.m4a", durationS: 1)
        recording.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(recording)
        try context.save()
        try media.write(Data([1]), as: "bye-audio.m4a")
        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.audio.count, 1)

        Tombstone.recordRecording(recording, in: context)
        media.delete(recording.audioFilename)
        context.delete(recording)
        try context.save()

        state = try await engine.sync(state: state)
        XCTAssertEqual(remote.removedPaths,
                       [RemoteAudioPath.make(userID: userID, filename: "bye-audio.m4a")])
        XCTAssertTrue(remote.audio.isEmpty)
        XCTAssertNotNil(remote.recordings[recording.id]?.deletedAt)
    }

    /// A tombstone is an edit: it applies only when it is newer than what is here.
    func testAnOlderRemoteTombstoneLosesToANewerLocalEdit() async throws {
        let tag = VoiceTag(kind: .meaning, name: "Kept")
        tag.updatedAt = Date(timeIntervalSince1970: 5000)
        context.insert(tag)
        try context.save()
        remote.tags[tag.id] = VoiceTagRow.tombstone(id: tag.id, userID: userID,
                                                    deletedAt: Date(timeIntervalSince1970: 4000))
        remote.tags[tag.id]?.serverUpdatedAt = Date(timeIntervalSince1970: 1_000_001)

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).map(\.name), ["Kept"])
    }

    func testANewerRemoteTombstoneDeletesLocally() async throws {
        let tag = VoiceTag(kind: .meaning, name: "Hungry")
        tag.updatedAt = Date(timeIntervalSince1970: 3500)
        context.insert(tag)
        try context.save()
        try await remote.upsertTags([VoiceTagRow.tombstone(id: tag.id, userID: userID,
                                                           deletedAt: Date(timeIntervalSince1970: 4000))])

        var state = SyncState()
        state.setPushedThrough(.voiceTags, Date(timeIntervalSince1970: 3500))
        _ = try await engine.sync(state: state)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).count, 0)
    }

    /// The reason pulled tombstones are retained: a device that had not heard about the delete
    /// pushes its old copy, and that copy must not come back.
    func testAnEditDoesNotResurrectATombstonedRow() async throws {
        let id = UUID()
        Tombstone.recordPulled(.voiceTags, id: id, deletedAt: Date(timeIntervalSince1970: 6000), in: context)
        try context.save()
        try await remote.upsertTags([VoiceTagRow(id: id, userID: userID, createdAt: SyncState.epoch,
                                                 updatedAt: Date(timeIntervalSince1970: 5000),
                                                 serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                 name: "Zombie", isBuiltIn: false, sortOrder: 0)])

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).count, 0)
    }

    // MARK: pull and paging

    func testPullCreatesLocalRecordsAndMovesTheCursor() async throws {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 2000)
        try await remote.upsertAnimals([AnimalRow(id: id, userID: userID, createdAt: when, updatedAt: when,
                                                  serverUpdatedAt: nil, deletedAt: nil,
                                                  name: "Remote", species: "horse", colorHex: "#112233",
                                                  photoFilename: nil, photoThumbnailFilename: nil,
                                                  tracksOutdoorTime: true, sortOrder: 0, isArchived: false,
                                                  note: nil)])

        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Animal>()).map(\.name), ["Remote"])
        XCTAssertEqual(state.pullCursor(.animals), remote.animals[id]?.serverUpdatedAt)
        XCTAssertEqual(state.pullOffset(.animals), 1)
    }

    /// The double caps every page at three however large a limit the engine asks for, which is what
    /// a real server does too. The loop has to keep going until a page comes back empty.
    func testPaginationPullsEveryRowAcrossACappedPage() async throws {
        remote.pageCap = 3
        for index in 0..<10 {
            try await remote.upsertTags([VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                                                     updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                                                     serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                     name: "tag\(index)", isBuiltIn: false, sortOrder: index)])
        }

        _ = try await engine.sync(state: SyncState())
        let names = try context.fetch(FetchDescriptor<VoiceTag>()).map(\.name).sorted()
        XCTAssertEqual(names.count, 10, "every row has to arrive, not just the first page")
        XCTAssertEqual(Set(names).count, 10)
    }

    /// A second pull picks up only what is new, using the stored cursor and offset.
    func testASecondPullResumesFromTheStoredCursor() async throws {
        remote.pageCap = 3
        for index in 0..<5 {
            try await remote.upsertTags([VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                                                     updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                                                     serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                     name: "first\(index)", isBuiltIn: false, sortOrder: index)])
        }
        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), 5)

        try await remote.upsertTags([VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                                                 updatedAt: Date(timeIntervalSince1970: 99),
                                                 serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                 name: "second", isBuiltIn: false, sortOrder: 0)])
        _ = try await engine.sync(state: state)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), 6)
    }

    /// Rows that all share one `server_updated_at` still page correctly, because the cursor carries
    /// an offset into that group rather than just a timestamp.
    func testRowsSharingOneServerTimestampAllArrive() async throws {
        remote.pageCap = 2
        let batch = (0..<5).map { index in
            VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                        name: "same\(index)", isBuiltIn: false, sortOrder: index)
        }
        // One upsert call, so the double stamps them all inside one batch.
        try await remote.upsertTags(batch)
        let stamp = Date(timeIntervalSince1970: 7_000_000)
        for id in batch.map(\.id) { remote.tags[id]?.serverUpdatedAt = stamp }

        _ = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), 5)
    }

    /// The over-skip the stored offset used to cause. Three rows share one `server_updated_at`, so
    /// the cursor comes to rest inside that bucket with an offset of 3. Then one of those rows is
    /// edited from another device: the trigger moves it to a newer stamp, it leaves the bucket, and
    /// the rows behind it shift down. Resuming at offset 3 would land past the end of the new
    /// window and that edit would be missed forever, because the cursor only moves forward.
    func testARowUpdatedBetweenCyclesDoesNotMakeThePullSkipItsNeighbour() async throws {
        let batch = (0..<3).map { index in
            VoiceTagRow(id: UUID(), userID: userID, createdAt: SyncState.epoch,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                        serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                        name: "bucket\(index)", isBuiltIn: false, sortOrder: index)
        }
        try await remote.upsertTags(batch)
        // One shared stamp, and the double's clock moved past it, so anything stamped later really
        // is later than the bucket.
        let bucketStamp = Date(timeIntervalSince1970: 7_000_000)
        for id in batch.map(\.id) { remote.tags[id]?.serverUpdatedAt = bucketStamp }
        remote.serverClock = bucketStamp

        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), 3)
        XCTAssertEqual(state.pullCursor(.voiceTags), bucketStamp)
        XCTAssertEqual(state.pullOffset(.voiceTags), 3)

        var moved = try XCTUnwrap(remote.tags[batch[0].id])
        moved.name = "edited elsewhere"
        moved.updatedAt = Date(timeIntervalSince1970: 9000)
        try await remote.upsertTags([moved])
        XCTAssertGreaterThan(try XCTUnwrap(remote.tags[batch[0].id]?.serverUpdatedAt), bucketStamp,
                             "the double stamps a changed row forward, like the trigger")

        state = try await engine.sync(state: state)

        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceTag>()).map(\.name).sorted(),
                       ["bucket1", "bucket2", "edited elsewhere"],
                       "the edit that left the bucket still arrives")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceTag>()), 3,
                       "and re-reading the bucket duplicates nothing")
    }

    func testLastWriteWinsBothWays() async throws {
        let tag = VoiceTag(kind: .meaning, name: "Local")
        tag.updatedAt = Date(timeIntervalSince1970: 5000)
        context.insert(tag)
        try context.save()

        // Remote is older: the local name survives the pull, and the push overwrites the server.
        try await remote.upsertTags([VoiceTagRow(id: tag.id, userID: userID, createdAt: SyncState.epoch,
                                                 updatedAt: Date(timeIntervalSince1970: 4000),
                                                 serverUpdatedAt: nil, deletedAt: nil, kindRaw: "meaning",
                                                 name: "Stale", isBuiltIn: false, sortOrder: 0)])
        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(tag.name, "Local")
        XCTAssertEqual(remote.tags[tag.id]?.name, "Local", "the push overwrites the older server row")

        // Remote is newer: it wins on the next pull.
        var newer = try XCTUnwrap(remote.tags[tag.id])
        newer.name = "Fresh"
        newer.updatedAt = Date(timeIntervalSince1970: 6000)
        try await remote.upsertTags([newer])
        state = try await engine.sync(state: state)
        XCTAssertEqual(tag.name, "Fresh")
    }

    /// A child pulled before its parent keeps the raw parent id, so the push that follows names the
    /// right animal instead of sending null.
    func testAParentMissingOnPullDoesNotPushANullForeignKey() async throws {
        let animalID = UUID()
        let when = Date(timeIntervalSince1970: 2000)
        try await remote.upsertRecordings([VoiceRecordingRow(id: UUID(), userID: userID, createdAt: when,
                                                             updatedAt: when, serverUpdatedAt: nil, deletedAt: nil,
                                                             animalID: animalID, recordedAt: when, durationS: 1,
                                                             audioFilename: "p-audio.m4a", statusRaw: "recorded",
                                                             errorMessage: nil, note: "", activityTag: nil,
                                                             meaningTag: nil, userConfidence: nil,
                                                             editedAt: nil, audioUploadedAt: nil)])

        var state = try await engine.sync(state: SyncState())
        let recording = try XCTUnwrap(try context.fetch(FetchDescriptor<VoiceRecording>()).first)
        XCTAssertNil(recording.animal, "the parent never arrived")
        XCTAssertEqual(recording.animalID, animalID)

        // Something changes locally, so the row is pushed back.
        recording.note = "edited"
        recording.updatedAt = Date(timeIntervalSince1970: 9000)
        try context.save()
        state = try await engine.sync(state: state)
        XCTAssertEqual(remote.recordings[recording.id]?.animalID, animalID,
                       "an unresolved relationship must not push a null animal_id")
    }

    /// Verification defect D-D12. A device whose clock is wrong pushes a row dated far in the
    /// future. Unclamped, that row wins against every later genuine edit forever, server-side and
    /// then locally on the next pull. The trigger clamps it to the server's clock plus a small
    /// tolerance, and `InMemoryRemoteStore.merge` is the twin of that trigger, so an ordinary edit
    /// made afterwards still wins.
    func testAFutureDatedRowIsClampedAndCannotFreezeTheRowAgainstLaterEdits() async throws {
        let deviceNow = Date()
        remote.acceptUpdatedAtUntil = deviceNow.addingTimeInterval(5 * 60)

        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = deviceNow.addingTimeInterval(400 * 24 * 3600) // a clock wrong by a year
        context.insert(animal)
        try context.save()

        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals[animal.id]?.updatedAt, deviceNow.addingTimeInterval(5 * 60),
                       "the server bounds what a device may claim updated_at to be")
        XCTAssertLessThanOrEqual(state.pushedThrough(.animals), Date(),
                                 "and SyncClock keeps the local watermark out of the future too")

        // Real time passes on the server, so its `now() + 5 minutes` ceiling moves with it. This
        // is the property that matters: the clamped value is overtakeable, an unclamped 2030 stamp
        // never would be.
        remote.acceptUpdatedAtUntil = deviceNow.addingTimeInterval(3600)

        // An ordinary edit ten minutes after the first push, from a device whose clock is now right.
        animal.name = "Miso the second"
        animal.updatedAt = deviceNow.addingTimeInterval(600)
        try context.save()
        state = try await engine.sync(state: state)

        XCTAssertEqual(remote.animals[animal.id]?.name, "Miso the second",
                       "a genuine later edit must not be silently discarded server-side")
        XCTAssertEqual(animal.name, "Miso the second", "and the pull must not overwrite it again")
    }

    // MARK: audio

    func testAudioIsUploadedOnceAndFlaggedOnBothSides() async throws {
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

    func testAtMostTenFilesGoUpPerCycle() async throws {
        for index in 0..<25 {
            let recording = VoiceRecording(audioFilename: "many\(index)-audio.m4a", durationS: 1)
            recording.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            context.insert(recording)
            try media.write(Data([UInt8(index)]), as: "many\(index)-audio.m4a")
        }
        try context.save()

        var state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.uploadCount, SyncState.audioUploadsPerCycle)
        state = try await engine.sync(state: state)
        XCTAssertEqual(remote.uploadCount, 2 * SyncState.audioUploadsPerCycle)
    }

    // MARK: failure and cancellation

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

        let state = try await engine.sync(state: SyncState())
        XCTAssertEqual(remote.animals.count, 1, "the retry still sends the row")
        XCTAssertEqual(state.pushedThrough(.animals), Date(timeIntervalSince1970: 8000))
    }

    /// The generation token: a sync that is no longer current stops at the next await and produces
    /// no state for its caller to save.
    func testAStaleGenerationStopsBeforeTouchingTheServer() async throws {
        let animal = Animal(name: "Miso", species: "cat")
        animal.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(animal)
        try context.save()

        let stale = SyncEngine(local: local, remote: remote, isCurrent: { false })
        do {
            _ = try await stale.sync(state: SyncState())
            XCTFail("expected SyncCancelled")
        } catch is SyncCancelled {
            // expected
        }
        XCTAssertTrue(remote.animals.isEmpty, "nothing reached the server")
    }

    /// Going stale part way through still stops, and still yields no state.
    func testGoingStaleMidCycleStopsTheSync() async throws {
        let tag = VoiceTag(kind: .meaning, name: "t")
        tag.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(tag)
        try context.save()

        var current = true
        // Goes stale during the first server call, the way a sign-out mid-sync would.
        remote.beforeCall = { current = false }
        let cancelling = SyncEngine(local: local, remote: remote, isCurrent: { current })
        do {
            _ = try await cancelling.sync(state: SyncState())
            XCTFail("expected SyncCancelled")
        } catch is SyncCancelled {
            // expected
        }
    }

    // MARK: end to end

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
        let otherContainer = try TestSupport.container()
        retained.append(otherContainer)
        let otherContext = otherContainer.mainContext
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
/// SwiftData or about supabase-swift, only about `LocalStore` and `RemoteStore`, which is what
/// makes it testable against `InMemoryRemoteStore`.
///
/// Order matters. Audio goes first so the `audioUploadedAt` flag is part of the same row push;
/// push goes before pull so a row this device just changed is not immediately overwritten by the
/// stale copy the server still holds. A row that arrives on a pull is pushed back once on the next
/// cycle, which the server's guard turns into a no-op because the timestamps are equal.
///
/// `isCurrent` is the generation token. It is checked at every await, so a sync that has been
/// superseded, by a sign-out or by a store wipe, stops instead of writing into a store that is
/// about to be destroyed or that now belongs to someone else.
@MainActor
final class SyncEngine {
    /// A hard stop on the paging loop. At 500 rows a page this is half a million rows per table,
    /// which is far past anything this app produces, and it means a server behaving unexpectedly
    /// cannot spin forever.
    static let maxPagesPerTable = 1000

    private let local: any LocalStore
    private let remote: any RemoteStore
    private let now: () -> Date
    private let isCurrent: () -> Bool

    init(local: any LocalStore,
         remote: any RemoteStore,
         now: @escaping () -> Date = Date.init,
         isCurrent: @escaping () -> Bool = { true }) {
        self.local = local
        self.remote = remote
        self.now = now
        self.isCurrent = isCurrent
    }

    func sync(state: SyncState) async throws -> SyncState {
        var next = state
        try checkpoint()
        try await uploadAudio()
        next = try await push(next)
        next = try await pull(next)
        try checkpoint()
        next.lastSyncedAt = now()
        next.status = .idle
        return next
    }

    /// Throws if this sync has been superseded. Called before and after every await, so a stale
    /// cycle can never save state or write into a store that is being replaced.
    private func checkpoint() throws {
        guard isCurrent() else { throw SyncCancelled() }
    }

    // MARK: audio

    private func uploadAudio() async throws {
        let pending = try local.pendingAudioUploads(limit: SyncState.audioUploadsPerCycle)
        for item in pending {
            try checkpoint()
            // One file at a time: a backlog of long recordings must not all be in memory at once.
            guard let data = try local.loadAudio(named: item.filename) else { continue }
            try await remote.uploadAudio(path: RemoteAudioPath.make(userID: local.userID, filename: item.filename),
                                         data: data)
            try checkpoint()
            try local.markAudioUploaded(recordingID: item.recordingID, at: now())
            // Saved per file, so a failure half way through keeps the flags already earned.
            try local.save()
        }
    }

    // MARK: push

    private func push(_ state: SyncState) async throws -> SyncState {
        var next = state
        let ceiling = now()

        for table in SyncTable.allCases {
            try checkpoint()
            let since = next.pushedThrough(table)
            let graves = try local.pendingTombstones(for: table)
            var stamps: [Date] = []
            var sent = false

            switch table {
            case .animals:
                let rows = try local.changedAnimals(after: since)
                    + graves.map { AnimalRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertAnimals(rows)
                    stamps = rows.map(\.updatedAt)
                    sent = true
                }

            case .voiceRecordings:
                let rows = try local.changedRecordings(after: since)
                    + graves.map { VoiceRecordingRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertRecordings(rows)
                    stamps = rows.map(\.updatedAt)
                    sent = true
                    // Only once the tombstone rows are on the server: take their audio objects too.
                    let paths = graves.compactMap(\.audioFilename)
                        .map { RemoteAudioPath.make(userID: local.userID, filename: $0) }
                    if !paths.isEmpty {
                        try checkpoint()
                        try await remote.removeAudio(paths: paths)
                    }
                }

            case .vocalizations:
                let rows = try local.changedVocalizations(after: since)
                    + graves.map { VocalizationRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertVocalizations(rows)
                    stamps = rows.map(\.updatedAt)
                    sent = true
                }

            case .voiceTags:
                let rows = try local.changedTags(after: since)
                    + graves.map { VoiceTagRow.tombstone(id: $0.recordID, userID: local.userID, deletedAt: $0.deletedAt) }
                if !rows.isEmpty {
                    try await remote.upsertTags(rows)
                    stamps = rows.map(\.updatedAt)
                    sent = true
                }
            }

            try checkpoint()
            guard sent else { continue }
            // By exact id, in this table only, and only after this table's upsert succeeded. A
            // tombstone written while the request was in flight is not in `graves` and keeps its
            // place in the queue.
            try local.markTombstonesPushed(graves.map(\.recordID), in: table)
            try local.save()
            next.setPushedThrough(table, SyncClock.highest(of: stamps, floor: since, notAfter: ceiling))
        }
        return next
    }

    // MARK: pull

    private func pull(_ state: SyncState) async throws -> SyncState {
        var next = state
        // Parents before children, so a child row can find its parent on the first pass.
        for table in [SyncTable.animals, .voiceRecordings, .vocalizations, .voiceTags] {
            var cursor = next.pullCursor(table)
            // Always 0, never `next.pullOffset(table)`.
            //
            // The stored offset is only meaningful against the exact set of rows the server had
            // when it was written. If any row in the cursor's timestamp bucket is updated between
            // two cycles, the trigger moves it to a newer `server_updated_at`, it drops out of
            // `gte(cursor)`, every row after it shifts down one place, and an offset that was
            // right last cycle now steps over a row that has never been seen. That row would be
            // missed permanently, because the cursor only ever moves forward.
            //
            // So each cycle re-reads the bucket from the beginning and skips by id what it has
            // already applied in this cycle. The cost is at most one extra page per table per
            // cycle, and re-applying a row costs nothing: `apply` merges on id and refuses a
            // remote row that is not strictly newer than the local one.
            var offset = 0
            // Ids already applied from the current `gte(cursor)` window, so a row that appears in
            // two pages because the window shifted under us is applied once and counted once.
            var seen: Set<UUID> = []
            var pages = 0

            while pages < SyncEngine.maxPagesPerTable {
                try checkpoint()
                pages += 1

                let page: PageSummary
                switch table {
                case .animals:
                    let rows = try await remote.fetchAnimals(since: cursor, offset: offset, limit: SyncState.pageLimit)
                    try checkpoint()
                    try local.apply(animals: rows.filter { !seen.contains($0.id) })
                    page = SyncEngine.summarise(rows)
                case .voiceRecordings:
                    let rows = try await remote.fetchRecordings(since: cursor, offset: offset, limit: SyncState.pageLimit)
                    try checkpoint()
                    try local.apply(recordings: rows.filter { !seen.contains($0.id) })
                    page = SyncEngine.summarise(rows)
                case .vocalizations:
                    let rows = try await remote.fetchVocalizations(since: cursor, offset: offset, limit: SyncState.pageLimit)
                    try checkpoint()
                    try local.apply(vocalizations: rows.filter { !seen.contains($0.id) })
                    page = SyncEngine.summarise(rows)
                case .voiceTags:
                    let rows = try await remote.fetchTags(since: cursor, offset: offset, limit: SyncState.pageLimit)
                    try checkpoint()
                    try local.apply(tags: rows.filter { !seen.contains($0.id) })
                    page = SyncEngine.summarise(rows)
                }

                // An empty page, not a short one, is the end. A server is free to cap a page below
                // the limit that was asked for, so a short page proves nothing.
                guard page.count > 0 else { break }

                try local.save()

                if let highest = page.highestStamp, highest > cursor {
                    // The window moves to `highest`, so everything consumed before it falls out of
                    // `gte(highest)` and both the offset and the seen set restart on the rows that
                    // carry the new cursor timestamp.
                    cursor = highest
                    seen = page.idsAtHighest
                    offset = page.idsAtHighest.count
                } else {
                    // Still inside the same window: everything on this page has been consumed.
                    seen.formUnion(page.ids)
                    offset += page.count
                }
            }

            try local.save()
            // Not clamped to the device clock: `server_updated_at` is the server's own clock, and
            // clamping it to a device that runs slow would stall every later pull. The offset is
            // persisted for Settings and for the tests; it is never read back as a start position.
            next.setPullCursor(table, cursor, offset: offset)
        }

        // All four tables are in, so any child that arrived before its parent can be attached now.
        // Parents-before-children ordering above handles the common case; this handles the ones it
        // cannot, and nothing else ever would, because a child's `updatedAt` does not move when its
        // parent arrives (verification defect D-D15). Runs after the loop, not inside it, so a
        // vocalization whose recording is pulled in the same cycle is linked whatever order the
        // pages happened to fall in.
        try checkpoint()
        try local.relinkOrphans()
        try local.save()
        return next
    }

    private struct PageSummary {
        let count: Int
        let ids: Set<UUID>
        let highestStamp: Date?
        /// The ids in this page that carry `highestStamp`.
        let idsAtHighest: Set<UUID>
    }

    private static func summarise(_ rows: [some SyncRow]) -> PageSummary {
        let ids = Set(rows.map(\.id))
        guard let highest = rows.compactMap(\.serverUpdatedAt).max() else {
            return PageSummary(count: rows.count, ids: ids, highestStamp: nil, idsAtHighest: [])
        }
        return PageSummary(count: rows.count,
                           ids: ids,
                           highestStamp: highest,
                           idsAtHighest: Set(rows.filter { $0.serverUpdatedAt == highest }.map(\.id)))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `SyncEngineTests` twenty-three cases are green.

Correction if `testARowUpdatedBetweenCyclesDoesNotMakeThePullSkipItsNeighbour` ends with only two tags: `pull` is starting the table at `next.pullOffset(table)` instead of at 0.

Correction if the same test ends with more than three tags: the `seen` set is not being carried across pages, or `apply` is inserting rather than merging on id.

Correction if `testAudioIsUploadedOnceAndFlaggedOnBothSides` fails on `remote.recordings[...]?.audioUploadedAt`: the upload ran after the row push, so the flag missed its push. `sync(state:)` must call `uploadAudio()` before `push(_:)`.

Correction if `testLastWriteWinsBothWays` fails with `tag.name == "Stale"`: pull ran before push, so the stale server row overwrote the local one. `sync(state:)` must call `push(_:)` before `pull(_:)`.

Correction if `testPaginationPullsEveryRowAcrossACappedPage` hangs or returns only three rows: the loop is breaking on a short page. It must break only on an empty one.

- [ ] **Step 5: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Sync/SyncEngine.swift AppTests/SyncEngineTests.swift
git commit -m "feat(sync): SyncEngine with paged pulls, per-table tombstone clearing and a cancellation checkpoint

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: SupabaseRemoteStore, SyncService with a generation token, MediaResolver, and every mutation site

**Files:**
- Create: `App/Sync/SupabaseRemoteStore.swift`
- Create: `App/Sync/SyncService.swift`
- Create: `App/Sync/MediaResolver.swift`
- Create: `AppTests/MediaResolverTests.swift`
- Create: `AppTests/SyncServiceTests.swift`
- Modify: `App/AnimalTrackerApp.swift` (scene phase only)
- Modify: `App/Views/Auth/RootView.swift` (attach sync to the store lifecycle, inside the existing `.task` before `restoreSession()`)
- Modify: `App/Views/Settings/SettingsView.swift` (sync rows and Delete account in the Account section)
- Modify: `App/Views/Animals/AnimalFormView.swift:159-164`
- Modify: `App/Views/Animals/ManageAnimalsView.swift:23`, `:36`, `:86-88`, `:98-101`
- Modify: `App/Voice/RecordingDeleter.swift` (the tombstone for every recording delete in the app)
- Modify: `App/Voice/VoiceTagRenamer.swift` (`updatedAt` on the tag and on every label it migrates)
- Modify: `App/Voice/AnalysisService.swift` (`apply` tombstones the sounds it replaces and stamps the recording; both failure paths stamp too)
- Modify: `App/Views/Voice/RecordView.swift` (`finish()`)
- Modify: `App/Views/Voice/TagSheet.swift` (`addTag(_:kind:selection:)`, `save()`)
- Modify: `App/Views/Voice/RecordingDetailView.swift` (play button, missing-file notice, `reanalyze()`, `VocalizationPlayButton`; the delete dialog is unchanged)
- Modify: `App/Views/Voice/VocalizationEditView.swift` (reset button, `markOverriddenIfChanged()`)
- Modify: `App/Views/Voice/AskView.swift` (the correction callback, `finish()`)
- Modify: `App/Views/Voice/ManageVoiceTagsView.swift` (add, delete; rename goes through `VoiceTagRenamer`)
- **Not** modified: `App/Views/Voice/VoiceHistoryView.swift`. Its `.onDelete` already routes through `RecordingDeleter`, which is where the tombstone now lives.

**Interfaces:**
- Consumes: `SyncEngine` (Task 10); `RemoteStore`, `SwiftDataLocalStore`, `InMemoryRemoteStore` (Task 9); `SyncState`, `SyncStatus`, `SyncCancelled`, `SyncCoding` (Task 3); `RemoteAudioPath` (Task 8); `Tombstone`, `MediaStore.write(_:as:)` (Task 7); `AuthState`, `AuthService` (Task 4); `SyncCoordinating`, `AppStoreLifecycle`, `RootView` (Task 5); `RecordingDeleter`, `VoiceTagRenamer`, `AnalysisService`, `TagPropagation`, `ManageVoiceTagsView` (Plan B and its fix wave).
- Produces:
  - `final class SupabaseRemoteStore: RemoteStore` with `init(client: SupabaseClient)`.
  - `@MainActor final class SyncService: ObservableObject, SyncCoordinating` with `static let shared`, `init(defaults: UserDefaults = .standard, resolver: MediaResolver = .shared)`, `@Published private(set) var isSyncing: Bool`, `@Published private(set) var status: SyncStatus`, `@Published private(set) var lastSyncedAt: Date?`, `var statusText: String`, `var lastSyncDescription: String`, `func attach(container:mediaStore:)`, `func update(for:client:)`, `func configure(remote:userID:)`, `func bumpGeneration()`, `func cancelSync() async`, `func requestSync()`, `func syncNow() async`, `func pushBeforeSignOut(timeout: TimeInterval) async -> Bool`, `func unsyncedRowCount() -> Int`.
  - `@MainActor final class MediaResolver: ObservableObject` with `static let shared`, `@Published private(set) var fetching: Set<UUID>`, `var remote: (any RemoteStore)?`, `var userID: UUID?`, `func ensureAudio(for recording: VoiceRecording, mediaStore: MediaStore) async -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `AppTests/MediaResolverTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class MediaResolverTests: XCTestCase {
    private let userID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private var retained: [ModelContainer] = []

    private func makeRecording(_ filename: String) throws -> VoiceRecording {
        let container = try TestSupport.container()
        retained.append(container)
        let recording = VoiceRecording(audioFilename: filename, durationS: 1)
        container.mainContext.insert(recording)
        try container.mainContext.save()
        return recording
    }

    func testPresentFileNeedsNoDownload() async throws {
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = try makeRecording("have-audio.m4a")
        try media.write(Data([1]), as: "have-audio.m4a")

        let resolver = MediaResolver()
        resolver.remote = remote
        resolver.userID = userID
        XCTAssertTrue(await resolver.ensureAudio(for: recording, mediaStore: media))
        XCTAssertEqual(remote.downloadCount, 0)
    }

    func testMissingFileIsDownloadedAndWrittenUnderTheSameName() async throws {
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = try makeRecording("need-audio.m4a")
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
        let media = InMemoryMediaStore()
        let remote = InMemoryRemoteStore()
        let recording = try makeRecording("nowhere-audio.m4a")

        let resolver = MediaResolver()
        resolver.remote = remote
        resolver.userID = userID
        XCTAssertFalse(await resolver.ensureAudio(for: recording, mediaStore: media))
        XCTAssertFalse(media.exists("nowhere-audio.m4a"))
        XCTAssertTrue(resolver.fetching.isEmpty)
    }

    func testOfflineResolverReportsFailureWithoutCrashing() async throws {
        let media = InMemoryMediaStore()
        let recording = try makeRecording("offline-audio.m4a")
        XCTAssertFalse(await MediaResolver().ensureAudio(for: recording, mediaStore: media))
    }
}
```

Create `AppTests/SyncServiceTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class SyncServiceTests: XCTestCase {
    private let userID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private var retained: [ModelContainer] = []
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncServiceTests-\(UUID().uuidString)"))
    }

    private func makeService(_ remote: InMemoryRemoteStore) throws -> SyncService {
        let container = try TestSupport.container()
        retained.append(container)
        // Its own resolver, never `MediaResolver.shared`. `configure` repoints whatever resolver
        // it was given at that call's backend, and these cases build several services; sharing the
        // global would leave it pointing at the last test's dead double for the rest of the
        // process (verification defect C-D7).
        let service = SyncService(defaults: defaults, resolver: MediaResolver())
        service.attach(container: container, mediaStore: InMemoryMediaStore())
        service.configure(remote: remote, userID: userID)
        container.mainContext.insert(Animal(name: "Miso", species: "cat"))
        try container.mainContext.save()
        return service
    }

    func testASuccessfulSyncSavesStateAndReportsIdle() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)

        await service.syncNow()

        XCTAssertEqual(service.status, .idle)
        XCTAssertNotNil(service.lastSyncedAt)
        XCTAssertEqual(remote.animals.count, 1)
        XCTAssertEqual(SyncState.load(defaults: defaults).status, .idle)
        XCTAssertNotEqual(SyncState.load(defaults: defaults).pushedThrough(.animals), SyncState.epoch)
    }

    /// The generation token. Something happens mid-request that supersedes this sync, and the cycle
    /// must write nothing: not the watermarks, not the status.
    func testAStaleGenerationSyncDoesNotSaveState() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)
        remote.beforeCall = { [weak service] in service?.bumpGeneration() }

        await service.syncNow()

        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState(),
                       "a superseded sync must not persist a watermark")
        XCTAssertNil(SyncState.load(defaults: defaults).lastSyncedAt)
    }

    func testCancelSyncBumpsTheGenerationAndLeavesNothingRunning() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)
        await service.cancelSync()
        XCTAssertFalse(service.isSyncing)
    }

    /// A cancelled cycle persists nothing, so nothing else can move the status off `.syncing`.
    /// Settings would read "Syncing" until the app was relaunched.
    func testCancellingASyncLeavesAReadableStatus() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)
        // Superseded during the first server call, the way a sign-out mid-sync supersedes it.
        remote.beforeCall = { [weak service] in service?.bumpGeneration() }

        await service.syncNow()
        await service.cancelSync()

        XCTAssertEqual(service.status, .cancelled)
        XCTAssertEqual(service.statusText, "Sync stopped")
        XCTAssertFalse(service.isSyncing)
    }

    /// And a cancel does not overwrite a real result. The status only moves when it is `.syncing`.
    func testCancellingAfterAFailureKeepsTheFailure() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)
        remote.failNextCall = true
        await service.syncNow()
        XCTAssertEqual(service.status, .failedServer)

        await service.cancelSync()
        XCTAssertEqual(service.status, .failedServer)
    }

    /// The status the UI shows is a category, never a server string.
    func testAFailedSyncReportsACategoryAndNotTheServerMessage() async throws {
        let remote = InMemoryRemoteStore()
        let service = try makeService(remote)
        remote.failNextCall = true

        await service.syncNow()

        XCTAssertEqual(service.status, .failedServer)
        XCTAssertFalse(service.statusText.contains("scripted"))
        XCTAssertEqual(SyncState.load(defaults: defaults).status, .failedServer)
    }

    func testWithoutARemoteNothingSyncsAndNothingCrashes() async throws {
        let container = try TestSupport.container()
        retained.append(container)
        let service = SyncService(defaults: defaults)
        service.attach(container: container, mediaStore: InMemoryMediaStore())
        service.configure(remote: nil, userID: nil)

        service.requestSync()
        await service.syncNow()
        XCTAssertFalse(service.isSyncing)
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
    }

    func testLastSyncDescriptionIsNeverWhenNothingHasSyncedYet() throws {
        XCTAssertEqual(SyncService(defaults: defaults).lastSyncDescription, "Never")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: FAIL with `cannot find 'MediaResolver' in scope` and `cannot find 'SyncService' in scope`.

- [ ] **Step 3: Write the Supabase-backed remote store**

Create `App/Sync/SupabaseRemoteStore.swift`:
```swift
import Foundation
import Supabase

/// The real backend. Every method is one PostgREST or Storage call; all the decisions live in
/// `SyncEngine`, which is why nothing here needs a test double of its own.
final class SupabaseRemoteStore: RemoteStore {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: upserts

    /// `returning: .minimal` because nothing here reads the response, and a full representation of
    /// five hundred rows is bytes and decoding for nothing.
    private func upsert(_ rows: [some Encodable], into table: SyncTable) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(table.rawValue)
            .upsert(rows, onConflict: "id", returning: .minimal)
            .execute()
    }

    func upsertAnimals(_ rows: [AnimalRow]) async throws { try await upsert(rows, into: .animals) }
    func upsertRecordings(_ rows: [VoiceRecordingRow]) async throws { try await upsert(rows, into: .voiceRecordings) }
    func upsertVocalizations(_ rows: [VocalizationRow]) async throws { try await upsert(rows, into: .vocalizations) }
    func upsertTags(_ rows: [VoiceTagRow]) async throws { try await upsert(rows, into: .voiceTags) }

    // MARK: fetches

    /// Ordered by the cursor column then by id, so the order is total and offset paging inside one
    /// timestamp is stable. `range(from:to:)` is the offset form of paging; it sets both the offset
    /// and the limit, so there is no separate `.limit(...)` call.
    private func fetch<Row: Decodable>(_ table: SyncTable, since: Date, offset: Int, limit: Int) async throws -> [Row] {
        guard limit > 0, offset >= 0 else { return [] }
        return try await client.from(table.rawValue)
            .select()
            .gte("server_updated_at", value: SyncCoding.string(from: since))
            .order("server_updated_at", ascending: true)
            .order("id", ascending: true)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    func fetchAnimals(since: Date, offset: Int, limit: Int) async throws -> [AnimalRow] {
        try await fetch(.animals, since: since, offset: offset, limit: limit)
    }

    func fetchRecordings(since: Date, offset: Int, limit: Int) async throws -> [VoiceRecordingRow] {
        try await fetch(.voiceRecordings, since: since, offset: offset, limit: limit)
    }

    func fetchVocalizations(since: Date, offset: Int, limit: Int) async throws -> [VocalizationRow] {
        try await fetch(.vocalizations, since: since, offset: offset, limit: limit)
    }

    func fetchTags(since: Date, offset: Int, limit: Int) async throws -> [VoiceTagRow] {
        try await fetch(.voiceTags, since: since, offset: offset, limit: limit)
    }

    // MARK: audio

    func uploadAudio(path: String, data: Data) async throws {
        _ = try await client.storage
            .from(RemoteAudioPath.bucket)
            .upload(path, data: data,
                    options: FileOptions(cacheControl: "3600", contentType: "audio/mp4", upsert: true))
    }

    func downloadAudio(path: String) async throws -> Data {
        try await client.storage.from(RemoteAudioPath.bucket).download(path: path)
    }

    func removeAudio(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await client.storage.from(RemoteAudioPath.bucket).remove(paths: paths)
    }
}
```

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

/// Drives `SyncEngine` from the app: right after sign-in, on scene activation, and on every
/// mutation through a two second debounce so a burst of edits becomes one sync.
///
/// The generation token is the whole safety story. Every reconfiguration, cancellation and store
/// wipe bumps it. A running cycle carries the value it started with, checks it at every await, and
/// refuses to persist anything once it no longer matches, so a sync can never write watermarks for
/// a user who has signed out or into a store that has been replaced.
@MainActor
final class SyncService: ObservableObject, SyncCoordinating {
    static let shared = SyncService()

    @Published private(set) var isSyncing = false
    @Published private(set) var status: SyncStatus = .notSignedIn
    @Published private(set) var lastSyncedAt: Date?

    private let defaults: UserDefaults
    private var container: ModelContainer?
    private var mediaStore: MediaStore = FileMediaStore()
    private var remote: (any RemoteStore)?
    private var userID: UUID?
    private var generation = UUID()
    private var running: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    /// Injected rather than reached for. `configure` repoints the resolver at the current backend,
    /// and `SyncServiceTests` builds seven non-shared services; with a hard-coded
    /// `MediaResolver.shared` each of those would repoint the process-wide resolver at its own
    /// double, and the last test to run would leave the global pointing at a dead one for the rest
    /// of the process (verification defect C-D7). The default keeps every production call site
    /// unchanged.
    private let resolver: MediaResolver

    init(defaults: UserDefaults = .standard, resolver: MediaResolver = .shared) {
        self.defaults = defaults
        self.resolver = resolver
        let state = SyncState.load(defaults: defaults)
        status = state.status
        lastSyncedAt = state.lastSyncedAt
    }

    var statusText: String { status.text }

    var lastSyncDescription: String {
        guard let lastSyncedAt else { return "Never" }
        return lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// Supersedes any running cycle. Everything that changes what a sync is allowed to touch calls
    /// this first.
    func bumpGeneration() {
        generation = UUID()
    }

    // MARK: SyncCoordinating

    func attach(container: ModelContainer, mediaStore: MediaStore) {
        bumpGeneration()
        self.container = container
        self.mediaStore = mediaStore
    }

    func update(for state: AuthState, client: SupabaseClient?) {
        switch state {
        case .signedIn(let userID, _):
            configure(remote: client.map(SupabaseRemoteStore.init), userID: userID)
            if remote != nil {
                Task { await self.syncNow() }
            }
        case .offline:
            configure(remote: nil, userID: nil)
            status = .offline
        case .signedOut, .unknown, .misconfigured:
            configure(remote: nil, userID: nil)
            status = .notSignedIn
        }
    }

    /// Points the service at a backend, or at nothing. Internal rather than private so a test can
    /// hand it an `InMemoryRemoteStore` without constructing a `SupabaseClient`.
    func configure(remote: (any RemoteStore)?, userID: UUID?) {
        debounce?.cancel()
        debounce = nil
        bumpGeneration()
        self.remote = remote
        self.userID = userID
        resolver.remote = remote
        resolver.userID = userID
        let stored = SyncState.load(defaults: defaults)
        if remote == nil {
            lastSyncedAt = nil
        } else {
            status = stored.status
            lastSyncedAt = stored.lastSyncedAt
        }
    }

    /// Stops the running cycle and does not return until it has actually stopped. `AuthService`
    /// awaits this before wiping the store, so no writer is left holding a context into a store
    /// that is about to be destroyed.
    func cancelSync() async {
        bumpGeneration()
        debounce?.cancel()
        debounce = nil
        let inFlight = running
        running = nil
        inFlight?.cancel()
        await inFlight?.value
        isSyncing = false
        // The cancelled cycle returns without saving anything, by design, so nothing else will
        // move the status off `.syncing` and Settings would read "Syncing" forever. Only `.syncing`
        // is overwritten: a cancel must not erase a `.failedNetwork` the last real cycle earned.
        if status == .syncing { status = .cancelled }
    }

    /// One last push before the store is destroyed (verification defect D-D7).
    ///
    /// Bounded: a `syncNow()` against a dead network retries inside the engine, and a person who
    /// has already decided to sign out will force-quit rather than watch a spinner, which loses
    /// exactly the records this exists to save. The race is resolved the safe way: the timeout
    /// only stops *waiting*, it never cancels the cycle, so a slow push that finishes a second
    /// later still lands. The caller re-reads `unsyncedRowCount()` afterwards and that is what
    /// decides whether the second confirmation appears, so a false "timed out" costs one extra
    /// dialog and never a lost row.
    func pushBeforeSignOut(timeout: TimeInterval) async -> Bool {
        guard remote != nil, container != nil, userID != nil, !isSyncing else { return false }
        // Set synchronously, before the cycle's task is even scheduled, so the loop below cannot
        // read a stale `.idle` left by the previous cycle and return instantly.
        status = .syncing
        let cycle = Task { @MainActor [weak self] in await self?.syncNow() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        // Polled rather than a race between two tasks. `await cycle.value` cannot be abandoned
        // once entered, and abandoning the wait without cancelling the cycle is the whole point:
        // a slow push that lands a second after the timeout still reaches the server, and the
        // caller re-reads `unsyncedRowCount()` afterwards, so a premature timeout costs one extra
        // dialog and never a lost row.
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if status != .syncing { break }
        }
        _ = cycle
        return status == .idle
    }

    /// Rows whose `updatedAt` is newer than their table's push watermark, plus tombstones that
    /// have not been pushed. Returns 0 when there is no store or no backend, which is the right
    /// answer for "nothing is waiting to go anywhere".
    func unsyncedRowCount() -> Int {
        guard let container, let userID else { return 0 }
        let local = SwiftDataLocalStore(context: container.mainContext, mediaStore: mediaStore, userID: userID)
        let state = SyncState.load(defaults: defaults)
        let epoch = SyncState.epoch
        // `changed*(after: epoch)` is every row the store could ever push, so filtering those by
        // the per-table watermark inside `UnsyncedCount` gives the same set the engine would send
        // on the next cycle.
        let byTable: [SyncTable: [Date]] = [
            .animals: (try? local.changedAnimals(after: epoch).map(\.updatedAt)) ?? [],
            .voiceRecordings: (try? local.changedRecordings(after: epoch).map(\.updatedAt)) ?? [],
            .vocalizations: (try? local.changedVocalizations(after: epoch).map(\.updatedAt)) ?? [],
            .voiceTags: (try? local.changedTags(after: epoch).map(\.updatedAt)) ?? [],
        ]
        let graves = SyncTable.allCases.reduce(0) { total, table in
            total + (((try? local.pendingTombstones(for: table)) ?? []).count)
        }
        return UnsyncedCount.count(updatedAtByTable: byTable, pendingTombstones: graves, state: state)
    }

    // MARK: running

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
        let startedAt = generation
        isSyncing = true
        status = .syncing
        let task = Task { @MainActor [weak self] in
            await self?.run(container: container, remote: remote, userID: userID, startedAt: startedAt)
        }
        running = task
        await task.value
        running = nil
        isSyncing = false
    }

    private func run(container: ModelContainer,
                     remote: any RemoteStore,
                     userID: UUID,
                     startedAt: UUID) async {
        let local = SwiftDataLocalStore(context: container.mainContext, mediaStore: mediaStore, userID: userID)
        let engine = SyncEngine(local: local,
                                remote: remote,
                                isCurrent: { [weak self] in self?.generation == startedAt })
        var state = SyncState.load(defaults: defaults)
        do {
            state = try await engine.sync(state: state)
        } catch {
            // A category, never the message: a raw server string can carry a token or a row id,
            // and this value is both persisted and shown on screen.
            state.status = SyncStatus.category(for: error)
        }
        // The last and most important guard. A superseded cycle persists nothing at all: its
        // watermarks describe a store or a user that is no longer current.
        guard generation == startedAt else { return }
        state.save(defaults: defaults)
        status = state.status
        lastSyncedAt = state.lastSyncedAt
    }
}
```

- [ ] **Step 6: Wire sync into the app**

Two files, and the split matters. Everything that has to happen *before* `restoreSession()` goes in `RootView`'s `.task`, next to the call it has to precede. The scene-phase handler, which depends on nothing, stays at the app level.

In `App/AnimalTrackerApp.swift`, add one property after `@StateObject private var auth = AuthService()`:
```swift
    @Environment(\.scenePhase) private var scenePhase
```

and add one modifier to the `RootView()` in the `WindowGroup`, after `.modelContainer(store.container)`:
```swift
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        SyncService.shared.requestSync()
                        Task { await auth.checkAppleCredentialState() }
                    }
                }
```

`scenePhase` is the one `.onChange` in the whole auth and sync path, and it is safe: it starts a debounced sync and asks Apple about the credential, neither of which depends on ordering against anything else. There is no `.task` here; Task 5 Step 7 deliberately left the app-level content with none.

In `App/Views/Auth/RootView.swift`, extend the `.task` from Task 5 Step 5, keeping its order, from
```swift
        .task {
            auth.lifecycle = store
            auth.startWatchingAppleCredential()
            await auth.restoreSession()
        }
```
to
```swift
        .task {
            // Bottom up: sync is attached to the store, the store is attached to auth, and only
            // then does the session restore run. `restoreSession()` can decide store ownership on
            // its first line, and that decision needs a lifecycle that can already answer
            // `storeIsEmpty()`, cancel a sync and wipe. All four statements are in one function
            // precisely so no SwiftUI ordering rule has to be assumed.
            store.sync = SyncService.shared
            SyncService.shared.attach(container: store.container, mediaStore: FileMediaStore())
            auth.lifecycle = store
            auth.startWatchingAppleCredential()
            await auth.restoreSession()
        }
```

- [ ] **Step 7: Show sync and account deletion in Settings**

In `App/Views/Settings/SettingsView.swift`, add two properties after `@EnvironmentObject private var auth: AuthService` from Task 5:
```swift
    @ObservedObject private var sync = SyncService.shared
    @State private var showDeleteAccountConfirmation = false
```

and add these rows inside the `Section("Account")` from Task 5, after the closing brace of the `switch auth.state { ... }` and before the `if let message = auth.message` block:
```swift
                LabeledContent("Last sync", value: sync.lastSyncDescription)
                LabeledContent("Status", value: sync.statusText)
                Button("Sync now") { Task { await sync.syncNow() } }
                    .buttonStyle(.borderless)
                    .disabled(sync.isSyncing)
                if case .signedIn = auth.state {
                    Button("Delete account", role: .destructive) { showDeleteAccountConfirmation = true }
                        .buttonStyle(.borderless)
                        // On the button itself, not on the Section. Task 5 Step 8 already puts
                        // three dialogs in this section and they are on three different rows;
                        // stacking two `.confirmationDialog` modifiers on one view swallows the
                        // inner one and nothing presents (verification defect C-D4).
                        .confirmationDialog("Delete your account and everything in it?",
                                            isPresented: $showDeleteAccountConfirmation,
                                            titleVisibility: .visible) {
                            Button("Delete everything", role: .destructive) {
                                Task {
                                    do {
                                        try await auth.deleteAccount()
                                    } catch {
                                        auth.message = "Could not delete the account. Try again."
                                    }
                                }
                            }
                            Button("Keep my account", role: .cancel) {}
                        } message: {
                            Text("Your animals, recordings, vocalizations, tags and audio files are deleted from the server and from this phone. This cannot be undone.")
                        }
                }
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
        let now = Date()
        for (i, a) in ordered.enumerated() { a.sortOrder = i; a.updatedAt = now }
        for (i, a) in archived.enumerated() { a.sortOrder = ordered.count + i; a.updatedAt = now }
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
            // Tombstone first: it reads the record, and after context.delete there is no record.
            Tombstone.record(.animals, id: animal.id, in: context)
            if let photo = animal.photoFilename { mediaStore.delete(photo) }
            if let thumb = animal.photoThumbnailFilename { mediaStore.delete(thumb) }
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

Every block below was re-derived from the tree at `8dc20e8`, after Plan B's fix wave. v2's blocks were written against `090cdc4` and no longer match: `RecordingDeleter` and `VoiceTagRenamer` did not exist, `ManageVoiceTagsView` had a different shape, and `RecordView`, `AskView` and `RecordingDetailView` have all changed. Read the file before each edit.

Two of these sites are not views at all. Deleting a recording now goes through `RecordingDeleter`, and renaming a tag through `VoiceTagRenamer`, so the tombstone and the `updatedAt` stamps belong there: a caller that forgets them is a bug the helper can prevent, and both helpers already have every value the sync side needs.

**`App/Voice/RecordingDeleter.swift`** is where a recording's tombstone is written, because every delete in the app goes through it. Replace the whole body of `delete(_:context:mediaStore:)`:
```swift
    @MainActor
    static func delete(_ recording: VoiceRecording, context: ModelContext, mediaStore: MediaStore) throws {
        // Captured up front: the filename is unreadable off a model once it is deleted.
        let filename = recording.audioFilename
        context.delete(recording)
        try context.save()
        mediaStore.delete(filename)
    }
```
with:
```swift
    @MainActor
    static func delete(_ recording: VoiceRecording, context: ModelContext, mediaStore: MediaStore) throws {
        // Captured up front: the filename is unreadable off a model once it is deleted.
        let filename = recording.audioFilename
        // Written before the delete, for the same reason: the tombstone reads the audio filename and
        // the vocalization ids off the record, and after `context.delete` there is no record. This is
        // the one place every recording delete in the app passes through, so it is the one place the
        // tombstone has to be written.
        Tombstone.recordRecording(recording, in: context)
        context.delete(recording)
        try context.save()
        mediaStore.delete(filename)
        SyncService.shared.requestSync()
    }
```
The tombstone is saved by the same `try context.save()` that commits the delete, so a failed save leaves neither the delete nor the tombstone, which is exactly the property the file's own comment is about.

**`App/Voice/VoiceTagRenamer.swift`** rewrites labels on rows sync has to push, so every row it touches needs its `updatedAt` moved. Replace the body of `rename(tag:to:context:)` from `tag.name = name` down to `try context.save()`:
```swift
        tag.name = name
        switch tag.kind {
        case .activity:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.activityTag == old })) {
                r.activityTag = name
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.activityTag == old })) {
                v.activityTag = name
            }
        case .meaning:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.meaningTag == old })) {
                r.meaningTag = name
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.meaningTag == old })) {
                v.meaningTag = name
            }
        }
        try context.save()
```
with:
```swift
        // One timestamp for the whole rename, so the tag and every label it migrated are one edit as
        // far as last-write-wins is concerned. Without these stamps the labels change locally and
        // never push, and a second device keeps showing the old name forever.
        let now = Date()
        tag.name = name
        tag.updatedAt = now
        switch tag.kind {
        case .activity:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.activityTag == old })) {
                r.activityTag = name
                r.updatedAt = now
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.activityTag == old })) {
                v.activityTag = name
                v.updatedAt = now
            }
        case .meaning:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.meaningTag == old })) {
                r.meaningTag = name
                r.updatedAt = now
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.meaningTag == old })) {
                v.meaningTag = name
                v.updatedAt = now
            }
        }
        try context.save()
        SyncService.shared.requestSync()
```

**`App/Voice/AnalysisService.swift`** replaces a recording's sounds, which is a delete the server has to hear about. Replace `apply(_:to:context:)` (the `guard` on line 29 stays, and stays first):
```swift
    @MainActor
    static func apply(_ result: Result, to recording: VoiceRecording, context: ModelContext) throws {
        guard recording.modelContext != nil else { return }
        for old in recording.vocalizations ?? [] { context.delete(old) }
        for event in result.events {
            let v = Vocalization(segment: event.segment, features: event.features)
            v.recording = recording
            context.insert(v)
        }
        recording.durationS = result.durationS
        recording.status = result.events.isEmpty ? .noSounds : .analyzed
        recording.errorMessage = nil
        TagPropagation.apply(to: recording)
        try context.save()
    }
```
with:
```swift
    @MainActor
    static func apply(_ result: Result, to recording: VoiceRecording, context: ModelContext) throws {
        // Still first, and still a plain return: a recording deleted while the analysis ran has
        // already had its tombstones written by RecordingDeleter, and writing anything onto it here
        // would resurrect a row the store has dropped.
        guard recording.modelContext != nil else { return }
        let now = Date()
        for old in recording.vocalizations ?? [] {
            // Re-analysis is a delete like any other. Without the tombstone the old sounds stay on
            // the server forever and come back on the next device's pull.
            Tombstone.record(.vocalizations, id: old.id, deletedAt: now, in: context)
            context.delete(old)
        }
        for event in result.events {
            let v = Vocalization(segment: event.segment, features: event.features)
            v.recording = recording
            context.insert(v)
        }
        recording.durationS = result.durationS
        recording.status = result.events.isEmpty ? .noSounds : .analyzed
        recording.errorMessage = nil
        TagPropagation.apply(to: recording)
        recording.updatedAt = now
        try context.save()
    }
```

and stamp the two failure paths in `analyze(recording:mediaStore:context:)` as well, so a recording that has just been marked `.failed` is pushed rather than sitting on the device with a stale timestamp. Replace:
```swift
        guard mediaStore.exists(filename) else {
            guard recording.modelContext != nil else { return }
            recording.status = .failed
            recording.errorMessage = AnalysisError.missingAudio(filename).localizedDescription
            try? context.save()
            return
        }
```
with:
```swift
        guard mediaStore.exists(filename) else {
            guard recording.modelContext != nil else { return }
            recording.status = .failed
            recording.errorMessage = AnalysisError.missingAudio(filename).localizedDescription
            recording.updatedAt = Date()
            try? context.save()
            return
        }
```
and replace:
```swift
            guard recording.modelContext != nil else { return }
            recording.status = .failed
            recording.errorMessage = error.localizedDescription
            try? context.save()
        }
    }
}
```
with:
```swift
            guard recording.modelContext != nil else { return }
            recording.status = .failed
            recording.errorMessage = error.localizedDescription
            recording.updatedAt = Date()
            try? context.save()
        }
    }
}
```
`AnalysisService` does not call `requestSync()` itself: its three callers do, on the line after they call it, so one analysis is one sync request rather than three.

**`App/Views/Voice/RecordView.swift`**, inside `finish()`. Note `inserted = recording` and the `guard recording.modelContext != nil` that Plan B's fix wave added; both stay. Change
```swift
                context.insert(recording)
                inserted = recording
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                // Deleted while the analysis ran: a tagging sheet bound to a deleted model traps.
                guard recording.modelContext != nil else { return }
                pendingRecording = recording
```
to
```swift
                context.insert(recording)
                inserted = recording
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                // Deleted while the analysis ran: a tagging sheet bound to a deleted model traps.
                guard recording.modelContext != nil else { return }
                SyncService.shared.requestSync()
                pendingRecording = recording
```
`AnalysisService.apply` stamps the recording's `updatedAt`, and a freshly inserted `Vocalization` already carries `updatedAt = Date()`, so the only thing missing here was the request.

**`App/Views/Voice/TagSheet.swift`**. Change `addTag(_:kind:selection:)` from
```swift
        if let existing = tags.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selection.wrappedValue = existing.name
        } else {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
            selection.wrappedValue = name
        }
```
to
```swift
        if let existing = tags.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selection.wrappedValue = existing.name
        } else {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
            selection.wrappedValue = name
            SyncService.shared.requestSync()
        }
```
The existing-tag branch selects a row without changing it, so it has nothing to push.

and change `save()`, keeping every line of the draft write-back, from
```swift
    private func save() {
        recording.animal = animals.first { $0.id == draft.animalID }
        recording.activityTag = draft.activityTag
        recording.meaningTag = draft.meaningTag
        recording.userConfidence = draft.confidence
        recording.note = draft.note
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
        recording.animal = animals.first { $0.id == draft.animalID }
        recording.activityTag = draft.activityTag
        recording.meaningTag = draft.meaningTag
        recording.userConfidence = draft.confidence
        recording.note = draft.note
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
`recording.animal = ...` goes through the computed door from Task 7, so it writes `animalID` as well; that is why the draft write-back must not be reordered or replaced.

**`App/Views/Voice/VoiceHistoryView.swift`**, the `.onDelete` block. Nothing changes: it already routes through `RecordingDeleter`, which now writes the tombstone and requests the sync.
```swift
                .onDelete { offsets in
                    for r in offsets.map({ filtered[$0] }) {
                        try? RecordingDeleter.delete(r, context: context, mediaStore: mediaStore)
                    }
                }
```
Confirm it still reads exactly that before moving on:
```bash
grep -n "RecordingDeleter.delete" App/Views/Voice/VoiceHistoryView.swift App/Views/Voice/RecordingDetailView.swift
```
Expected: one hit in each file.

**`App/Views/Voice/RecordingDetailView.swift`**. The delete dialog keeps dismiss-before-delete and keeps routing through `RecordingDeleter`, so it is not changed either:
```swift
            Button("Delete", role: .destructive) {
                player.stop()
                // Dismiss first, then delete: a body re-evaluated after the delete would read a
                // deleted model. The capture keeps what the delete needs once `recording` is gone.
                let doomed = recording
                dismiss()
                Task { @MainActor in
                    try? RecordingDeleter.delete(doomed, context: context, mediaStore: mediaStore)
                }
            }
```

Change the play button body from
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
                    .disabled(resolver.fetching.contains(recording.id))
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
                    Label(resolver.fetching.contains(recording.id) ? "Fetching audio" : "Audio not on this phone yet",
                          systemImage: "icloud.and.arrow.down").foregroundStyle(.orange)
                }
```
and change `reanalyze()`, keeping the deleted-model guard Plan B's fix wave added, from
```swift
    private func reanalyze() {
        // Deleted out from under this screen: there is no row left to re-analyze.
        guard recording.modelContext != nil else { return }
        reanalyzing = true
        var config = SegmenterConfig()
        config.relativeThresholdDb = Float(thresholdDb)
        Task {
            await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context, segmenter: config)
            reanalyzing = false
        }
    }
```
to
```swift
    private func reanalyze() {
        // Deleted out from under this screen: there is no row left to re-analyze.
        guard recording.modelContext != nil else { return }
        reanalyzing = true
        var config = SegmenterConfig()
        config.relativeThresholdDb = Float(thresholdDb)
        Task {
            await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context, segmenter: config)
            reanalyzing = false
            // AnalysisService stamped updatedAt on the recording and tombstoned the sounds it
            // replaced; this only asks for those to go out.
            SyncService.shared.requestSync()
        }
    }
```

Add `@ObservedObject private var resolver = MediaResolver.shared` to `RecordingDetailView`'s properties, after `@StateObject private var player = AudioPlayer()` on line 10, so the fetching text actually refreshes.

**`App/Views/Voice/VocalizationEditView.swift`**. Change the reset button from
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

**`VocalizationPlayButton`**, which lives at the bottom of `App/Views/Voice/RecordingDetailView.swift` (line 103 at `8dc20e8`; confirm with `grep -rn "struct VocalizationPlayButton" App/`). Change its body from
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

**`App/Views/Voice/AskView.swift`**, two places.

The correction callback, lines 57 to 61 at `8dc20e8`, is a real edit to a sound and was pushing nothing at all. Change
```swift
                                  meanings: VoiceTagNames.names(tags, kind: .meaning), player: player) { correct in
                        item.vocalization.meaningTag = correct
                        item.vocalization.overridden = true
                        try? context.save()
                    }
```
to
```swift
                                  meanings: VoiceTagNames.names(tags, kind: .meaning), player: player) { correct in
                        item.vocalization.meaningTag = correct
                        item.vocalization.overridden = true
                        item.vocalization.updatedAt = Date()
                        try? context.save()
                        SyncService.shared.requestSync()
                    }
```

and in `finish()`, change
```swift
                await AnalysisService.analyze(recording: newRecording, mediaStore: mediaStore, context: context)
                // Deleted while the analysis ran: reading a deleted model's relationships traps, and
                // there is nothing left to show results against.
                guard newRecording.modelContext != nil else {
```
to
```swift
                await AnalysisService.analyze(recording: newRecording, mediaStore: mediaStore, context: context)
                SyncService.shared.requestSync()
                // Deleted while the analysis ran: reading a deleted model's relationships traps, and
                // there is nothing left to show results against.
                guard newRecording.modelContext != nil else {
```
The request goes before the guard on purpose: the analysis already saved the recording and its sounds (or the deletion already wrote a tombstone through `RecordingDeleter`), and either outcome is something the server should hear about.

**`App/Views/Voice/ManageVoiceTagsView.swift`**, as Plan B's fix wave left it. Three edits, and only three: the rename path already goes through `VoiceTagRenamer`, which Step 9 has already taught to stamp and request.

Change the Add button from
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

and change the delete action inside `section(_:kind:)` from
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

The `TagRow` `TextField` is not touched: it writes nothing to the model. `TagRow.save()` calls `commit(name)`, which is `ManageVoiceTagsView.rename(_:to:)`, which calls `VoiceTagRenamer.rename(tag:to:context:)`, and that is where the stamping now lives. Confirm that chain rather than assuming it:
```bash
grep -n "commit(name)\|VoiceTagRenamer.rename" App/Views/Voice/ManageVoiceTagsView.swift
```
Expected: one hit for each.

- [ ] **Step 10: Run the tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS. `MediaResolverTests` four cases and `SyncServiceTests` eight cases are green, and every earlier test still passes. Nothing here reaches the network: the tests build `MediaResolver()` and `SyncService(defaults:resolver:)` directly with an `InMemoryRemoteStore` and a per-test resolver, and `SyncService.shared.requestSync()` returns immediately in a test run because no remote is configured on the shared instance. Nothing in this file touches `MediaResolver.shared`, so no test can leave the process-wide resolver pointing at a dead double (verification defect C-D7).

Plan B's own tests now run through the changed helpers and must still pass unchanged:
- `RecordingDeleterTests` (2 cases) exercises `RecordingDeleter.delete`, which now also writes a tombstone. It asserts recording and vocalization counts, not `DeletedRecord` counts, so the extra rows do not disturb it.
- `VoiceTagRenameTests` (5 cases) exercises `VoiceTagRenamer.rename`, which now also stamps `updatedAt`. `testRenamingToTheSameNameDoesNothing` still returns before the stamps, because the `guard old != name else { return }` stays above them.
- `AnalysisServiceTests` (5 cases) exercises `AnalysisService.apply`, which now tombstones the sounds it replaces. `testApplyToADeletedRecordingIsANoOp` still passes because `guard recording.modelContext != nil` stays the first line, before any tombstone is written.

If any of those three files fails, the change went in above a guard rather than below it. Put the guard back on top and re-run.

- [ ] **Step 11: Check no mutation site was missed**

The greps cover all of `App/` except `App/Sync`, not just `App/Views`. v2 looked at the views only, which is how `AnalysisService.apply` deleted every vocalization on a re-analysis without a tombstone for a whole revision, and `App/Voice/` now also holds `RecordingDeleter` and `VoiceTagRenamer`. `App/Sync` is excluded because that is the engine: it applies server state and writes pulled tombstones through `Tombstone.recordPulled`, which is a different rule.

**Two things about how these are written.** The `--include` pattern is **quoted**. The shell here is
zsh, which globs an unquoted `--include=*.swift` against the working directory, finds no `.swift`
file at the repo root, and aborts the command with `zsh: no matches found` (bash passes the literal
through, which is where the unquoted form came from). Because every command is a pipeline, the
pipeline still exits 0 and prints nothing, so three of these audits would look clean and the fourth
would print `0` while never having run (verification defects C-D3 and D-D19).

And each one **asserts a number** rather than asking a human to eyeball a list. `set -o pipefail`
makes a broken stage fail the pipeline instead of being swallowed, and `test ... -eq N` makes a
silent zero as loud as a real finding. Where the count would move as this very task edits these
files, what is counted is the number of **violations**, which is derivably zero, rather than a
total that has to be re-derived every time a view is touched.

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
set -o pipefail
```

**1. Every save outside the engine belongs to a file that also asks for a sync.** `VoiceTagSeed` and
`AnalysisService` are the two legitimate exceptions. `VoiceTagSeed` inserts built-in rows with
deterministic ids at launch, and the next real sync picks them up on its own watermark.
`AnalysisService` is forbidden by Step 9 from calling `requestSync()` at all, because each of its
three callers requests one and a single analysis should cost a single request.

```bash
for f in $(grep -rl "context.save()" App --include='*.swift' | grep -v '^App/Sync/' | grep -v 'VoiceTagSeed.swift' | grep -v 'AnalysisService.swift'); do
  grep -q 'requestSync' "$f" || echo "MISSING requestSync: $f"
done | tee /tmp/audit1.txt
test "$(grep -c . /tmp/audit1.txt)" -eq 0 && echo "audit 1 OK"
```
Expected: `audit 1 OK` and no `MISSING` line. Then read the hits once by eye, because file-level
presence is necessary and not sufficient:
```bash
grep -rn "context.save()" App --include='*.swift' | grep -v "^App/Sync/" | grep -v "requestSync"
```
A save with no `requestSync()` anywhere in the same function is a missed mutation site.

**2. Six `context.delete(` outside the engine, and no more.** A seventh means a delete was added
without a tombstone.

```bash
test "$(grep -rn 'context.delete(' App --include='*.swift' | grep -vc '^App/Sync/')" -eq 6 && echo "audit 2 OK"
grep -rn "context.delete(" App --include='*.swift' | grep -v "^App/Sync/"
```
Expected: `audit 2 OK`, and every hit is preceded by a `Tombstone.record(...)` or
`Tombstone.recordRecording(...)` call on the line or lines above it, in the same function. The six
are `RecordingDeleter.delete`, `AnalysisService.apply`, `ManageVoiceTagsView.section(_:kind:)`,
`ManageAnimalsView.delete(_:)`, `RecordView.finish` and `AskView.finish`. The last two are the only
ones with no tombstone, and correctly so: they delete a row whose `try context.save()` never
succeeded, so the server has never heard of it.

**3. Nine `mediaStore.delete` outside the engine, and no more.**

```bash
test "$(grep -rn 'mediaStore.delete' App --include='*.swift' | grep -vc '^App/Sync/')" -eq 9 && echo "audit 3 OK"
grep -rn "mediaStore.delete" App --include='*.swift' | grep -v "^App/Sync/"
```
Expected: `audit 3 OK`. Four are animal photos and thumbnails in `ManageAnimalsView` and
`AnimalFormView`, which this plan does not tombstone because the animal row carries the filename.
Every hit that deletes a *recording's* audio is inside `RecordingDeleter.delete`, after
`Tombstone.recordRecording` has captured the filename, or is one of the two failed-save cleanups
above.

**4. Every file that asks for a sync also stamps `updatedAt`.** A row that changes without
`updatedAt` moving is a row that never pushes, and no test in this plan can see it.

```bash
for f in $(grep -rl 'requestSync' App --include='*.swift' | grep -v '^App/Sync/' \
           | grep -Ev 'AnimalTrackerApp|RecordingDeleter|RecordView|ManageVoiceTagsView|RecordingDetailView'); do
  grep -q 'updatedAt = ' "$f" || echo "REQUESTS SYNC BUT NEVER STAMPS: $f"
done | tee /tmp/audit4.txt
test "$(grep -c . /tmp/audit4.txt)" -eq 0 && echo "audit 4 OK"
rm -f /tmp/audit1.txt /tmp/audit4.txt
```
Expected: `audit 4 OK`. Five files legitimately request a sync without stamping anything, and the
loop excludes them by name: `AnimalTrackerApp` (its call is the scene-phase trigger, not a
mutation), `RecordingDeleter` and `ManageVoiceTagsView` (a delete writes a tombstone, and a
tombstone carries its own timestamp), `RecordView` (the stamp is the row's own `updatedAt` default
at insert) and `RecordingDetailView` (re-analysis stamps through `AnalysisService`). Anything else
in that list is a mutation site whose stamp was forgotten. Check the exclusion list still matches
reality whenever one of those five gains a real edit path.

- [ ] **Step 12: Commit**

```bash
cd /Users/asheslab/Documents/work/cat-voice
git add App/Sync/SupabaseRemoteStore.swift App/Sync/SyncService.swift App/Sync/MediaResolver.swift \
        AppTests/MediaResolverTests.swift AppTests/SyncServiceTests.swift \
        App/AnimalTrackerApp.swift App/Views App/Voice/RecordingDeleter.swift \
        App/Voice/VoiceTagRenamer.swift App/Voice/AnalysisService.swift
git commit -m "feat(sync): Supabase-backed remote store, generation-guarded sync service, sync-aware mutation sites

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Smoke test, device checks, server verification, and the push to main

**Files:**
- Modify: none by default. Any defect found here is fixed in the file that owns it, with a test added to the matching task's test file first.

**Interfaces:**
- Consumes: everything from Tasks 1 to 11.
- Produces: a verified build on `origin/main`.

- [ ] **Step 0: Precondition, the Supabase Apple provider is on**

The Apple provider **is already enabled** on project `ojzmtyapkaxxliuurssc`. This step is not a
configuration step; it is the check that turns that fact into something the run can rely on, so the
sign-in attempts in Steps 3 and 4 cannot be mis-diagnosed. Without it, a provider that had been
switched off would surface as an opaque Supabase error at Step 4 that looks exactly like a nonce
problem, which is the one failure this plan has trained the worker to answer by flipping the nonce
encoding (verification defect D-D9).

Both values come from the environment and are never written to a file:

```bash
cd /Users/asheslab/Documents/work/cat-voice
read -rs SUPABASE_ACCESS_TOKEN && export SUPABASE_ACCESS_TOKEN
export SUPABASE_PROJECT_REF=ojzmtyapkaxxliuurssc
curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/config/auth \
  | grep -o '"external_apple_enabled":[a-z]*'
unset SUPABASE_ACCESS_TOKEN SUPABASE_PROJECT_REF
```
Expected: `"external_apple_enabled":true`.

If it prints `false`, or prints nothing, stop before Step 3: the provider is off or the token does
not carry access to that project, and no amount of nonce flipping will fix either. Re-enable the
provider and confirm `com.ashlab.AnimalTracker` is listed under its client ids before continuing.
Native sign-in needs no OAuth secret, so nothing else about the provider has to be checked.

- [ ] **Step 1: Run the whole suite**

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
scripts/test-packages.sh
scripts/test-app.sh
```
Expected: both report zero failures. The package suites are unchanged by this plan, so they still report 28 for `AnimalVoiceAudio` and 28 for `AnimalVoiceStats`. The app suite started this plan at 60 and this plan adds **187**: `SupabasePackageLinkTests` 1, `SecretGuardTests` 9, `SupabaseConfigTests` 7, `NonceTests` 11, `SyncStateTests` 19, `KeychainSessionStorageTests` 4, `SyncCodingTests` 6, `AuthServiceTests` 22, `RootGateTests` 8, `ContainerResetTests` 4, `MigrationFileTests` 15, `SyncFieldTests` 10, `SyncRowTests` 14, `LocalStoreTests` 22, `SyncEngineTests` 23, `MediaResolverTests` 4, `SyncServiceTests` 8. So **247** in total (60 + 187; v3 said 235 against its own 176, which was 60 + 176 = 236 miscounted, verification defects C-D2 and D-D20). A different number is not automatically wrong, but reconcile it before continuing: a suite that silently lost a file is the failure mode this count exists to catch. Do not continue past a failure; fix it in the task that owns the file, test first.

- [ ] **Step 2: Simulator smoke test, offline path**

The anon key is committed, so the app reaches the sign-in screen rather than offline mode. The DEBUG button is how the simulator gets past it when the entitlement is not available.

Run:
```bash
cd /Users/asheslab/Documents/work/cat-voice
/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" App/Config/Supabase.plist | cut -c1-12
xcrun simctl uninstall booted com.ashlab.AnimalTracker 2>/dev/null || true
scripts/run-sim.sh
```
Expected: the plist prints `eyJhbGciOiJI`, and `build/screenshot.png` shows the sign-in screen with the Sign in with Apple button and "Continue offline" below it.

Then, in the simulator: tap "Continue offline". Expected: the five tabs appear with the orange offline banner. Add an animal, record a short clip from the Mac microphone, tag it. Open Settings: Status reads "Offline. Records stay on this phone." and Last sync reads "Never". Nothing attempts a network call.

Then tap Settings, "Sign in". Expected: a confirmation dialog warning that the offline records will be deleted. Confirm it, and check that the sign-in screen appears and that going back offline shows an empty animal list. That is the behaviour the previous revision had backwards: offline data belongs to no account and is never carried into one.

- [ ] **Step 3: Simulator sign-in, if the entitlement is available**

Only if Task 1 Step 8's fallback was not needed. Sign in with a real Apple ID in the simulator.

Expected: the tabs appear with no banner, Settings shows the account email or user id, and Status becomes "Synced" within a few seconds.

If sign-in fails with a nonce error, the app has already flipped `NonceEncoding` to base64url and set a message asking for another tap. Tap the button again. Expected: it succeeds. Record in the Task 12 commit body which encoding worked. If the second attempt also fails, stop: the third option is dropping the nonce, and that needs Ash's written sign-off first, recorded as an accepted replay risk. Do not do it on your own judgment.

- [ ] **Step 4: Device checks, run by hand**

These need a real phone with the paid team profile, so they are listed rather than scripted:

1. Build to the device from Xcode with the `AnimalTracker` scheme and confirm the app installs and the Sign in with Apple sheet appears when the button is tapped.
2. Sign in with the real Apple ID. Confirm the tabs appear and Settings shows the email or user id.
3. Record a real animal sound on the phone, tag it, and confirm Settings Status reaches "Synced".
4. Turn on airplane mode, add an animal, turn airplane mode off, reopen the app, and confirm the animal reaches the server (Step 5 checks that).
5. Delete a recording on the phone and confirm it disappears from the simulator after a sync.
6. On the phone, open Settings and revoke the app under the Apple ID settings (Settings, your name, Sign in with Apple, AnimalTracker, Stop using Apple ID). Reopen AnimalTracker. Expected: the app signs itself out and shows the sign-in screen, because `checkAppleCredentialState()` saw `.revoked`.

- [ ] **Step 5: Verify on the server, including sub-second timestamps**

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select count(*) from public.animals where deleted_at is null;"
psql "$PGURI" -c "select id, audio_filename, audio_uploaded_at from public.voice_recordings order by server_updated_at desc limit 5;"
psql "$PGURI" -c "select name from storage.objects where bucket_id = 'voice-audio' order by created_at desc limit 5;"
psql "$PGURI" -c "select id, deleted_at from public.voice_recordings where deleted_at is not null order by server_updated_at desc limit 3;"
unset PGURI
```
Expected: the animal count matches what was added; the newest recording has a non-null `audio_uploaded_at`; the storage object name starts with the signed-in user's lowercase uuid followed by `/`; the recording deleted in Step 4 has a non-null `deleted_at`.

Then the sub-second check. `updated_at` is the device's own timestamp and must survive the wire intact, to the millisecond: if it were being rounded to the second, or quietly replaced by `now()`, last-write-wins would start resolving ties the wrong way.

```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select id, updated_at, server_updated_at, extract(epoch from updated_at) as device_epoch from public.animals order by server_updated_at desc limit 1;"
psql "$PGURI" -c "select count(*) from public.animals where updated_at = date_trunc('second', updated_at);"
psql "$PGURI" -c "select count(*) from public.animals where updated_at = server_updated_at;"
unset PGURI
```
Expected: the first query prints an `updated_at` with a fractional part and a `device_epoch` with digits after the decimal point; the second prints a count well below the row count, meaning most rows carry a non-zero fractional part rather than every row landing exactly on a second; the third prints `0`, meaning the device's value was never replaced by the server's.

Now compare that `device_epoch` against what the device actually stored. The SwiftData store is a
SQLite file, and Core Data keeps dates as seconds since 2001-01-01, so the unix epoch is the stored
value plus 978307200.

**Read the store of whichever device pushed the rows the psql query just returned.** Step 3
("Simulator sign-in") is conditional on Task 1 Step 8's entitlement fallback not having been
needed, and Step 2 ends by leaving offline mode, which wipes the simulator store. So if Step 3 was
skipped, `ZANIMAL` in the simulator is empty, the `select` below returns nothing, and this check
silently records a pass on an empty table (verification defect D-D21).

- **If Step 3 ran**, the simulator pushed the rows; point `STORE` at its container, as below.
- **If Step 3 was skipped**, the rows on the server came from the phone. Copy the phone's store
  down first and point `STORE` at the copy:
  ```bash
  xcrun devicectl device copy from --device <udid> \
    --source 'Library/Application Support/default.store' --destination /tmp/device.store
  STORE=/tmp/device.store
  ```
  (Xcode's Window, Devices and Simulators, "Download Container" produces the same file.)

The step passes only when the comparison was actually run against a non-empty `ZANIMAL` on the
device that did the pushing. An empty result is a skipped check, not a passing one.

```bash
STORE="$(xcrun simctl get_app_container booted com.ashlab.AnimalTracker data)/Library/Application Support/default.store"
sqlite3 "$STORE" ".tables"
sqlite3 "$STORE" "pragma table_info(ZANIMAL);" | grep -i updated
sqlite3 "$STORE" "select hex(ZID), printf('%.6f', ZUPDATEDAT + 978307200) from ZANIMAL order by ZUPDATEDAT desc limit 1;"
```
Expected: the last command prints a unix timestamp whose value matches the `device_epoch` from the psql query above to within 0.001 seconds. A difference of a whole second, or a value that is a round number while the server's is not, means the timestamp is being truncated somewhere between `SyncCoding.encoder` and the column.

If `.tables` shows different names, read the real ones from that output and from `pragma table_info(...)`; the mapping is Core Data's, with a `Z` prefix and uppercased property names, and it can change between SwiftData releases. The check is the comparison, not the exact column name.

- [ ] **Step 6: Sign-out, different-user and account-deletion checks**

In the simulator, signed in as the same Apple ID:

1. Settings, "Sign out". Expected: the sign-in screen appears. Sign in again with the same Apple ID. Expected: the animals and recordings come back from the server within a few seconds, because the local store was destroyed and repopulated by a pull. This is the `StoreOwnerPolicy.reset` path followed by a full pull from a cleared watermark.
2. Check nothing survived the wipe on disk:
```bash
CONTAINER="$(xcrun simctl get_app_container booted com.ashlab.AnimalTracker data)"
ls -la "$CONTAINER/Library/Application Support/" | grep -i corrupt || echo "no recovered copies left behind"
```
Expected: the "no recovered copies left behind" line. A `default.store.corrupt-...` file here would be a complete copy of the previous session's records surviving a sign-out.
3. Sign in as a second Apple ID if one is available. Expected: the first account's animals are gone, not merged.
4. Settings, "Delete account". Expected first: the confirmation dialog actually appears. That is
   worth watching for rather than assuming, because four `.confirmationDialog` modifiers now live
   in this one section and two of the same kind stacked on a single view would leave the inner one
   swallowed with no error anywhere (verification defect C-D4); each is attached to its own row for
   that reason. Confirm it. Expected: the sign-in screen appears. Then:
```bash
read -rs PGURI && export PGURI
psql "$PGURI" -c "select count(*) from public.animals;"
psql "$PGURI" -c "select count(*) from storage.objects where bucket_id = 'voice-audio';"
psql "$PGURI" -c "select count(*) from auth.users;"
unset PGURI
```
Expected: all three counts drop by that account's share, and `auth.users` no longer holds that user. Signing in again with the same Apple ID gives a brand new, empty account.

   Then check the phone, not just the server. "Delete account" telling someone their data is gone
   while their recordings are still browsable in the Files app is the gap that matters most, and
   the server-side counts above cannot see it (verification defects D-D6 and D-D22):
```bash
CONTAINER="$(xcrun simctl get_app_container booted com.ashlab.AnimalTracker data)"
ls -la "$CONTAINER/Documents/Media/" 2>/dev/null | tail -n +4 || echo "media directory is gone"
ls -la "$CONTAINER/Library/Application Support/" | grep -i 'default.store' || echo "no store left"
```
   Expected: the media listing is empty (or the directory is gone), and what remains under
   `Application Support` is a freshly created empty store and its sidecars, nothing else. A
   `*-audio.m4a`, `*-photo.jpg` or `*-video.mov` surviving here means `wipeStore()` is not calling
   `mediaStore.removeAll()`; go back to Task 5 Step 4.

5. Sign out with unsynced work. Turn on airplane mode, add an animal, then Settings, "Sign out".
   Expected: the first dialog offers "Back up and sign out"; confirming it cannot reach the server,
   so within the bounded wait a second dialog appears naming the number of records that could not
   be backed up. Cancel with "Stay signed in" and confirm the animal is still there. This is the
   D-D7 path, and it is the only place in the app where a person is told what a destructive action
   costs before it happens.

- [ ] **Step 7: Secret guard before pushing**

```bash
cd /Users/asheslab/Documents/work/cat-voice
scripts/check-secrets.sh
git status --porcelain
/usr/libexec/PlistBuddy -c "Print :SupabaseAnonKey" App/Config/Supabase.plist | cut -c1-12
```
Expected: `check-secrets: clean`, a clean working tree, and `eyJhbGciOiJI`.

There is no `git grep eyJ` step and no `git update-index` step. The anon key is public and committed by ruling; a guard that flagged it would be switched off within a week, and the guard that matters is the one for the value shapes of a secret API key, a personal access token, a service-role JWT and a Postgres URL carrying a password.

- [ ] **Step 8: Merge main, test, commit once, push once**

This is the last step, and it is deliberately one step. The previous revision pushed in Step 8 and
then amended that same commit in Step 9: `--amend` gives the commit a new hash, `origin/main`
already pointed at the old one, and the second push was therefore a non-fast-forward rejection on
the milestone push, with the branch already published carrying the message the plan itself called
wrong. The only ways out of that are a force-push to the default branch or a throwaway empty
commit, and neither belongs in a plan (verification defect D-D18).

So: **the message is fixed before anything is published, and nothing is amended after a push.**

Have two facts to hand first: the supabase-swift version that resolved in Task 1 Step 6, and which
nonce encoding worked in Step 3 or Step 4.

```bash
cd /Users/asheslab/Documents/work/cat-voice
git fetch origin
git merge origin/main
```
Expected: `origin/main` holds only a LICENSE, so this is a clean merge with no conflicts. If git
reports "refusing to merge unrelated histories", re-run as
`git merge --allow-unrelated-histories origin/main` and keep both sides.

Fix the merge commit's message **now**, while nothing is published. Skip this command if the merge
reported "Already up to date." and created no commit:
```bash
git commit --amend -m "chore: merge origin/main (LICENSE) into the voice milestone branch

supabase-swift resolved to 2.55.x. Sign in with Apple succeeded with the <hex|base64url> nonce encoding.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

Run both suites and the build on the merged tree:
```bash
scripts/test-packages.sh
scripts/test-app.sh
scripts/build-app.sh
```
Expected: zero failures and `** BUILD SUCCEEDED **`. Do not push a tree that has not been tested
after the merge.

Then push, once. The pre-push hook runs `scripts/check-secrets.sh` first:
```bash
git push origin HEAD:main
git log --oneline origin/main -3
```
Expected: the hook prints `check-secrets: clean`, the push succeeds, and `origin/main` now carries
this branch's commits on top of the LICENSE commit.

If the hook does not run, `core.hooksPath` was not set in this clone. Set it and push again; this is
a retry of a push that never happened, not a second push:
```bash
git config core.hooksPath .githooks
git push origin HEAD:main
```

Nothing is amended after this point. If the message turns out to be wrong once it is on `main`, fix
it with a follow-up commit, never with `--amend` plus a force-push to the default branch.

---

## Self-review

**Spec coverage.** Every requirement in Addendum v7 and Addendum v7.1 maps to a task:

| Requirement | Task |
| --- | --- |
| supabase-swift in `project.yml` packages plus the `Supabase` product on both targets | 1 |
| `com.apple.developer.applesignin: [Default]`, `DEVELOPMENT_TEAM: A5S59B326M`, simulator signing check and the `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` fallback | 1 |
| Anon key public and committed in `App/Config/Supabase.plist`; guard against `sb_secret_`, service-role keys, the access token and a Postgres password (v7.1 release gate) | 1, 12 |
| Release build with no anon key shows a blocking "not configured" screen, never the tabs (v7.1 release gate) | 2 (build phase), 4 (`.misconfigured`), 5 (`RootGate.blocked`, `MisconfiguredView`) |
| `SupabaseConfig.load()` returning nil for the placeholder | 2 |
| Nonce: raw to Supabase, SHA-256 to Apple, base64url on a mismatch, no drop-the-nonce build step (v7.1) | 3, 4, 5, 12 |
| Session persisted by the SDK, pinned service and `ThisDeviceOnly` accessibility | 3 |
| `SyncState` watermarks plus the `server_updated_at` pull cursor, in UserDefaults; status sanitized to a category | 3 |
| Store owner recorded at session establishment; wipe on a different user, on unowned non-empty data, and on a fresh install with a keychain session; in-flight sync cancelled before a wipe (v7.1 ownership) | 3 (policy), 4 (transition), 5 (lifecycle) |
| `AuthService` with `.unknown / .signedOut / .signedIn / .offline / .misconfigured`, `restoreSession()`, `signInWithApple(authorization:)`, `signOut()` with local scope and no swallowed errors (v7.1 ownership) | 4 |
| Apple credential revocation signs out | 4, 12 |
| `SignInView` with `SignInWithAppleButton`, hashed nonce on the request, `.email` scope, DEBUG "Continue offline" | 5 |
| `RootView` gating `RootTabView` behind `.signedIn` or `.offline`, offline banner, recovery banner | 5 |
| Settings Account section: email or user id, Sign out, sync status, Delete account | 5, 11 |
| Store destroyed and rebuilt on sign-out or a different user, including recovered `.corrupt-*` copies | 5 |
| SQL migration: four tables, RLS `to authenticated` with `(select auth.uid())` and `with check`, `user_id` default, indexes, private `voice-audio` bucket with a size limit and mime allow-list, storage policies on `foldername` | 6 |
| Server-side last-write-wins trigger with sticky `deleted_at`, `server_updated_at` maintained by the trigger (v7.1 sync mechanism) | 6 |
| `delete_my_account()` security definer removing storage objects, rows and the auth user (v7.1 storage hygiene) | 6, 11, 12 |
| `supabase/config.toml`, `supabase link`, `supabase db push` with `SUPABASE_ACCESS_TOKEN`, psql fallback, storage ownership fallback, no password in the repo | 6 |
| `updatedAt` on the four models, `audioUploadedAt` on `VoiceRecording`, raw parent ids, `DeletedRecord` registered in `modelTypes` | 7 |
| Deterministic built-in tag ids so a re-seed upserts (v7.1 storage hygiene) | 7, 5 |
| Codable row structs with snake_case keys, round-trip tested, `server_updated_at` omitted on push | 8 |
| `RemoteStore` protocol, `SupabaseRemoteStore`, `InMemoryRemoteStore` reproducing the server trigger | 9, 11 |
| `LocalStore` protocol and `SwiftDataLocalStore`, retained tombstones, no null foreign keys | 9 |
| `SyncEngine` push with tombstones and audio uploads, paged pulls on `server_updated_at`, last-write-wins both ways, cancellation checkpoint, clock-skew clamp | 10 |
| Deleting a recording removes its audio object (v7.1 storage hygiene) | 7 (filename capture), 10 (removeAudio on push), 11 |
| `MediaResolver` used by `RecordingDetailView` and `VocalizationPlayButton` | 11 |
| `SyncService` on scene phase, after sign-in, and on a debounced `requestSync()`, generation-guarded, status published for Settings | 11 |
| Mutation sites in the nine views stamping `updatedAt`, writing tombstones, and requesting a sync | 11 |
| Tests: nonce, config, coding, keychain, auth transitions, root gating, container reset, migration contents, row round trips, local store, engine push/pull/paging/tombstones/cancellation, sync service, media resolver, secret patterns, no live network | 1 to 11 |
| Smoke test, device steps, server verification, push to main | 12 |

**Placeholder scan.** No "TBD", no "similar to Task N", no "add error handling", no "write tests for the above". Every code step carries the full text of the file or the exact before and after of the lines being changed. The conditional branches all carry complete replacement code rather than a description: Task 1 Step 8's signing fallback, Task 4 Step 5's `String(describing:)` correction, Task 6 Step 7's storage-ownership fallback, and Task 12 Step 5's SQLite column-name discovery. The one deliberately open item is Task 12 Step 3's third nonce option, which is not a build step at all but a decision reserved to Ash, and the plan says so rather than pretending to a fallback.

**Anchor check.** Every "change from" block and every `file:line` reference was re-derived from the working tree at `8dc20e8`, and each was then confirmed to exist verbatim with `grep -F`. The v2 revision's anchors were written against `090cdc4` and eight of them no longer matched after Plan B's fix wave; the eight were `TagSheet.addTag`, `TagSheet.save`, the `RecordingDetailView` delete dialog, `RecordView.finish`, the three `#Predicate` sites (whose line numbers moved), and the whole of `ManageVoiceTagsView`. Files this plan touches that did not exist at `090cdc4` (`RecordingDeleter`, `VoiceTagRenamer`, `InsightsModel`, `ManageVoiceTagsView`) are gated in Global Constraints with an `ls` and `grep` precondition, so a worker who starts on an older tree is stopped rather than left to improvise. Every step that edits a file whose shape could move again also carries the `grep` that proves the shape first.

**Computed constants.** No expected value in a test is a guess:
- `1_789_819_200` for 2026-09-19T12:00:00Z and `1_750_000_000.25` for 2025-06-15T15:06:40.250Z were computed with `datetime.timestamp()` and `datetime.fromtimestamp(...).isoformat()`, and both tests carry the command that produced them. v2 carried `1_789_128_000`, which is a different day.
- The migration counts (20 `create policy`, 21 `to authenticated`, 25 `(select auth.uid())`, 10 `with check`, 4 storage policies, 5 `foldername` comparisons, 4 of each per-table item) were counted over the migration text with `--` comment lines stripped, and Task 6 Step 5 carries the shell loop that re-derives them. `migrationSQL()` strips those lines, so the counts are over SQL and never over the prose that quotes it.
- The key sets in `SyncRowTests` are written out column by column against the migration's `create table` statements, and Task 8 Step 5 diffs the coding keys against the SQL columns.
- Test-case counts per file are counted, not estimated: 1, 9, 7, 11, 19, 4, 6, 22, 8, 4, 15, 10, 14, 22, 23, 4, 8, which is **187** added to the 60 the app suite already has, so **247**. Task 12 Step 1 states the same arithmetic so a silently dropped file is visible. v3 carried two different totals for the same 176 addends, 235 in Task 12 Step 1 and 236 here; both are gone (verification defects C-D2 and D-D20), and the eleven cases v4 adds are: `SecretGuardTests` +3 (value-shape patterns, D-D1/D-D2/D-D23), `SyncStateTests` +2 (`UnsyncedCount`, D-D7), `AuthServiceTests` +4 (Apple credential state, D-D8), `LocalStoreTests` +1 (relink, D-D15), `SyncEngineTests` +1 (the `updated_at` clamp, D-D12).
- `VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count` is used wherever the built-in tag total is needed, rather than the literal 19, so adding a tag to Plan B's list never breaks a Plan H test.

**Two tests that could not fail, removed.** v2's `testAnUnconfiguredServiceNeverSignsAnyoneIn` asserted exactly what `testUnconfiguredServiceHasNoClient` asserted and is now `testAnUnconfiguredServiceRefusesToDeleteAnAccount`, which drives `deleteAccount()` and asserts the lifecycle is untouched. v2's `testASeededTagAndAPulledTagWithTheSameIdAreOneRow` reassigned a name to the value it already held; it is now Task 9's `testAPulledBuiltInTagMergesOntoTheSeededRow`, which calls `SwiftDataLocalStore.apply(tags:)` with a `VoiceTagRow` carrying `VoiceTagSeed.builtInID(...)` and then checks that a different id under the same name is a different row.

**Work this plan does not repeat.** Plan B's fix wave already shipped deterministic built-in tag ids (`VoiceTagSeed.builtInID`), a seed that runs on every launch with no UserDefaults guard, `RecordingDeleter` and `VoiceTagRenamer`. Finding 20 is therefore satisfied by the tree: Task 7 Step 6 verifies it with three greps instead of writing a `UUID.v5` extension that would collide with what is there, Task 5 Step 4 simply calls `Seeds.runAll`, and the tombstone and `updatedAt` work hooks into the two helpers rather than into each call site.

**Type consistency.** Checked across tasks:

- `SyncTable` raw values (`animals`, `voice_recordings`, `vocalizations`, `voice_tags`) are identical in Task 3's enum, Task 6's SQL, Tasks 9 and 10's stores and Task 11's `SupabaseRemoteStore`.
- `SyncState.epoch` is the "never synced" value in Tasks 3, 9, 10 and 11. `SyncState.pageLimit` (500) and `SyncState.audioUploadsPerCycle` (10) are declared in Task 3 and used only in Task 10.
- `SyncCoding` is declared in Task 3 and used in Task 4 (client options), Task 8 (row tests) and Task 11 (`gte` filter value). Declaring it in Task 3 rather than alongside the rows is deliberate: `AuthService` builds the client, and the client needs the coders.
- `SyncRow`'s four members are declared in Task 8 with `serverUpdatedAt` and `deletedAt` settable, which is what Task 9's `InMemoryRemoteStore.merge` and Task 10's `summarise` both rely on.
- `RemoteStore.fetch*(since:offset:limit:)` has the same three labels in Task 9's protocol, Task 9's double, Task 10's engine and Task 11's Supabase implementation. `removeAudio(paths:)` and `deleteAccount()` likewise.
- `LocalStore.pendingTombstones(for:)` and `markTombstonesPushed(_:in:)` keep their labels from Task 9's protocol through Task 10's engine. `pendingAudioUploads(limit:)` and `loadAudio(named:)` likewise.
- `RemoteAudioPath.make(userID:filename:)` returns a lowercase path in Task 8 and is used unchanged in Tasks 10 and 11, matching the `(storage.foldername(name))[1] = (select auth.uid())::text` policy in Task 6.
- `MediaStore.write(_:as:)` is declared in Task 7 and used in Tasks 9 and 11.
- `Tombstone.record(_:id:deletedAt:audioFilename:in:)`, `Tombstone.recordPulled(_:id:deletedAt:in:)` and `Tombstone.recordRecording(_:in:)` are declared in Task 7 and used in Tasks 9 and 11.
- `StoreLifecycle`'s four methods are declared in Task 4, implemented by `AppStoreLifecycle` in Task 5, and driven only from Task 4. `SyncCoordinating`'s five methods are declared in Task 5 and implemented by `SyncService` in Task 11; the names `cancelSync()`, `attach(container:mediaStore:)`, `update(for:client:)`, `pushBeforeSignOut(timeout:)` and `unsyncedRowCount()` match on both sides. The last two arrived with D-D7, the confirmed sign-out that pushes before it wipes.
- `AuthState` gains `.misconfigured` in Task 4 and every switch over it in Tasks 5 and 11 handles all five cases.
- `VoiceRecording.animalLink` and `Vocalization.recordingLink` are introduced in Task 7 and written directly only in Task 9's `apply`; every other site goes through the computed `animal` and `recording`, and Task 7 updates all three `#Predicate`s that can no longer reach them (`AnimalDeletionPolicy.swift:11`, `PredictionService.swift:31`, `InsightsModel.swift:69`). `changedVocalizations` reads `recordingID ?? recordingLink?.id`, because the inverse on `VoiceRecording.vocalizations` can set the link without the door.
- `SyncCancelled` is declared in Task 3, thrown in Task 10 and categorised in Task 3's `SyncStatus.category(for:)`, which Task 11 calls.
- `SyncService.shared.requestSync()` has the same spelling at every mutation site in Task 11: two in `AnimalFormView` and `ManageAnimalsView` each, one each in `RecordingDeleter`, `VoiceTagRenamer`, `RecordView`, `TagSheet.addTag`, `TagSheet.save`, `RecordingDetailView.reanalyze`, the `VocalizationEditView` reset button, `markOverriddenIfChanged`, the `AskView` correction callback, `AskView.finish`, and the `ManageVoiceTagsView` add and delete actions. `AnalysisService` deliberately does not call it: its three callers do, so one analysis is one request.
- `RecordingDeleter.delete(_:context:mediaStore:)` and `VoiceTagRenamer.rename(tag:to:context:)` keep Plan B's signatures exactly; Task 11 changes their bodies only, so `VoiceHistoryView`, `RecordingDetailView` and `ManageVoiceTagsView` call them unchanged.
- `AuthService.sessionStorageKey` is declared in Task 4, passed to `AuthOptions(storage:storageKey:)` in the same step, and removed by name in `deleteAccount()` in that same step; it appears nowhere else.
