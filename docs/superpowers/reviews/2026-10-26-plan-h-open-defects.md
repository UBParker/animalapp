# Plan H open defects at the pause

Recorded 2026-10-26, when work was paused. Tasks 1 to 6 of `docs/superpowers/plans/2026-09-19-animal-tracker-H-auth-sync.md` are implemented; Tasks 1 to 4 are reviewed and fixed, Task 5's fix wave was landing at the pause, and Task 6 is written and tested offline but neither applied nor fixed.

This file exists because the full reviews live in a git-ignored execution workspace. The defects below are the ones that must not be lost. Each was found by an independent reviewer and verified by evidence rather than inspection alone.

## Blocking, Task 6 (the SQL migration, committed but never applied)

**Built-in tag ids are global and publicly computable.** `id uuid primary key` is unique across all users, and the deterministic v5 ids Plan B introduced are identical for every install. One user can insert the 19 built-in tag ids under their own account, after which every other user's push of their own built-in tags fails forever, because the upsert conflicts on a row they cannot see, update or delete. A permanent, all-users write denial, free to fix while the tables are empty. Fix: `primary key (user_id, id)` plus `on_conflict=user_id,id` on the pusher.

**A deletion that arrives late is discarded, and the recording comes back.** The sticky-deletion assignment sits above the staleness gate, and the gate discards the incoming row wholesale, so deletion is sticky only once it has landed. Delete on one device offline, edit on another, and the edit wins: the deleting device is told its push succeeded, forgets the deletion, and restores the row on its next pull. The audio file was already removed, so the restored record points at nothing. Ruling: sticky deletion wins over timestamp order, because a deletion the user performed must not be undone by an edit they made earlier. Needs both a server change and a client rule that a remote tombstone always applies.

**The future-clock clamp targets the wrong instant.** Clamping to `now() + 5 minutes` hands a far-future device the newest timestamp any writer can hold, so for five minutes after each of its writes, honest devices' edits are silently discarded and then overwritten on the next pull. The freeze is bounded rather than removed, and renewed by every write. Clamp to `now()` instead.

**Rows can still be skipped permanently.** The server cursor is stamped at transaction start but becomes visible at commit, so stamps can appear out of order, and a row below a cursor the client has already passed is excluded by every later pull. Fix with a client-side safety lag on the persisted cursor; re-applying a row is already free.

**Row level security on the storage table is assumed, never asserted.** The migration enables it on the four application tables only. If it is off for storage objects, all four storage policies are inert and any authenticated user can read any other user's audio. Must be a blocking check before the schema is trusted.

**Pre-existing storage policies are never enumerated.** Policies combine with OR, so one leftover permissive policy defeats the private bucket, and the current verification filter would not see it.

**The bucket's allowed mime type does not match what the client sends.** The bucket allows `audio/mp4`; the client library derives `audio/x-m4a` from the file extension. Every upload would be rejected. Harmless to security, but it blocks the milestone at first contact.

## Resolved during execution, kept here because the mechanisms recur

- An unreadable store-ownership record used to trigger a full wipe, so adding one field in a later release would have made users signing into their own account lose every recording not yet uploaded. Now "no record" and "record I cannot read" are distinguished, and the latter never wipes.
- The local wipe did not verify that the database file was gone, and reopened whatever remained. A surviving main file with deleted companions reopens intact, after which the new account is recorded as its owner, adopting the previous user's data. Ruling: an unverified wipe is a hard failure that keeps its retry marker and publishes nothing.
- Signing out verified the keychain was empty, but the library's background token refresh could rewrite it afterwards, leaving a wiped store with a live session that signed the user back in at next launch.
- The pre-push secret guard scanned the working tree rather than the commits being pushed, and reported clean on any git error.

## Standing decisions

- Sign-out is reported complete on the basis of the keychain being empty, not on the library's own result, because the library deletes the local session before its network call. This deliberately amends the spec's wording in favour of its intent.
- No logger is ever configured on the Supabase client. Two real leaks in the pinned version are inert only because of that: the refresh token enters a logger task-local, and the request interceptor would log the identity token and the raw nonce.
- `force row level security` stays absent. It buys nothing against non-owners and would silently break account deletion's table deletes.
