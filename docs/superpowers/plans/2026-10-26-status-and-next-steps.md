# AnimalTracker status and next steps

Written 2026-10-26, at the pause. Branch `feature/animal-voice`. The milestone Ash set is a functional app with Sign in with Apple, animal tracking, and audio recording with frequency analysis, after which it goes to `main`.

## Where the code is

| Plan | What it covers | State |
|---|---|---|
| A | Foundation: models, persistence, animals, media, settings | Complete, reviewed |
| B | Voice: recording, segmentation, pitch and spectral analysis, tagging, predictions, insights | Complete, reviewed, one fix wave |
| H | Sign in with Apple and Supabase sync | Tasks 1 to 6 of 12 |
| C | Communication buttons | Not started |
| D | Feeding log | Not started |
| E | Poop and health check-ins | Not started |
| F | Spoken check-in through the Claude API | Not started |
| G | Export and import | Not started |

Tests: 248 in the app, 28 in the audio package, 28 in the statistics package, all passing. Two local Swift packages hold the signal processing and the statistics; the app layer is SwiftUI with SwiftData.

## Plan H in detail

Done and reviewed: package wiring and the pre-push secret guard (Task 1), config loading with a release build that refuses to ship without a key (Task 2), the nonce, keychain session storage and sync bookkeeping (Task 3), the sign-in service (Task 4), and the login gate with account settings (Task 5).

Written but not applied: the database schema, row level security, the last-write-wins trigger, the private audio bucket and account deletion (Task 6). It is verified as text by a test that reads the committed file, never by a database.

Remaining: sync fields on the models (7), the wire format (8), the remote and local stores (9), the sync engine (10), the Supabase client and the places that mutate data (11), and the smoke test and push (12).

Auth work went through three independent reviewers per task, as Ash's rules require. That found, among others, a sign-out race that wiped data and then silently signed the user back in, a store wipe that could adopt one person's data into another person's account, and a fallback encoding that could lock a user out permanently. All are fixed.

## Open defects

`docs/superpowers/reviews/2026-10-26-plan-h-open-defects.md` is the authoritative list. The two that block Task 6:

**Table permissions, with a deadline.** The migration enables row level security but never grants table privileges, which Supabase used to do automatically and stops doing for existing projects on 2026-10-30. Privileges are checked before policies, so the schema would deploy cleanly, every test would pass, and every request would then be refused.

**Built-in tag identifiers are unique across all users.** The deterministic identifiers are the same for everyone, so one account can claim all nineteen and permanently break every other account's sync against rows they cannot see. Free to fix while the tables are empty.

Seven more important defects are recorded there, including that account deletion currently leaves the audio files on the server.

## Next steps, in order

1. **Fix Task 6.** The fix list is prepared. Both criticals, the storage assumptions, the manual-apply transaction gap, and a migration test that pins behaviour rather than wording.
2. **Validate the migration locally.** `supabase start` then `supabase db reset` applies it against Docker Postgres with no credentials. Set `auto_expose_new_tables = false` so the local database reproduces the permissions defect. This is the cheapest way to turn a text-verified migration into a tested one.
3. **Apply it to the project.** Needs a Supabase personal access token for the account owning project `ojzmtyapkaxxliuurssc`. Then substitute the real anon key into `App/Config/Supabase.plist`, which also flips two deliberately inverted tests in `SupabaseConfigTests`.
4. **Tasks 7 to 11.** Task 10 must apply a remote deletion unconditionally, per the ruling that deletion beats timestamp order. Tasks 8 and 11 carry their own addendum, chiefly that the storage path must be lowercase or every upload is refused.
5. **Task 12.** Device checks that only hardware can prove: the Apple sign-in exchange, that a wrong nonce is rejected rather than merely that a correct one is accepted, a real keychain refusal, account deletion end to end, and the misconfigured screen in a release build.
6. **Push to `main`** once login, animals and recording work together.
7. **Plans C through G**, in order. F needs the Claude API skill; G needs the real model initialisers.

## Things worth remembering

Sign-out is judged complete by the keychain being empty, not by the library's own result, because the library deletes the local session before its network call. No logger is ever attached to the Supabase client: two real leaks in the pinned version are inert only because of that. The database password and access tokens never enter the repository; only the anon key is committed, and a pre-push guard enforces it.

The guard currently refuses this branch, correctly, over two old documentation commits containing invented example secrets. Verified by hand: a `hunter2` connection string and a sequential-hex key, both inside test assertions in the plan document. Pushing needs `--no-verify` once.

## 2026-11-10 local-only MVP

Plan H is parked. To get the voice features onto Ash's phone without a backend, the app now has a `LOCAL_ONLY` build mode (`docs/superpowers/plans/2026-11-10-local-only-mvp.md`). Nothing under `App/Auth`, `App/Sync` or `supabase/` changed.

What shipped, in five commits:

- `a5e3808` adds the `LOCAL_ONLY` compile condition to the app target, removes the Sign in with Apple entitlement, and skips the Release anon-key build check when `LOCAL_ONLY` is set.
- `8e6b8dc` adds `LocalRootView`, which launches straight into the tabs and never calls `restoreSession`.
- `09aba42` shows only the Voice tab.
- `29a53c2` hides the Account and Oral check-in settings and makes the About footnote mode-aware.
- `a85d8c9` constructs `AuthService` with no Supabase config in local-only mode, so there is no client and no token refresh even if a real key is put in the plist. It also corrects the About text: records stay on the phone and are not synced, but the phone's own iCloud or computer backup includes them.

Tests: 266 in the app, up from 254 before this plan (not the 248 the plan stated), plus 28 audio and 28 statistics, all passing. The simulator launches into the first-run Add Animal sheet with no sign-in screen and no offline banner.

Two review-focus items are held by code structure rather than by unit tests: the local root never runs `restoreSession`, so a leftover pending teardown cannot wipe the store, and the yellow "temporary store" banner still shows when the store failed to open. `LocalRootView` has no `AuthService` dependency at all. Three independent reviews confirmed both.

Device install is blocked on signing only. The Release device build failed with "No Accounts: Add a new account in Accounts settings" and "No profiles for 'com.ashlab.AnimalTracker' were found". An unsigned Release build succeeds. Ash has to sign in to Xcode with her Apple ID (team `A5S59B326M`) before the install.

The blocker on going back to sync: local-only records have no owner, and the current sign-in path wipes ownerless data. Removing `LOCAL_ONLY` needs a tested adoption path into the first account on that phone, or Plan G export and an export by Ash first. Details in the open-defects file.
