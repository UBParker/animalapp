# Plan H open defects at the pause

Recorded 2026-10-26, when work was paused. Tasks 1 to 6 of `docs/superpowers/plans/2026-09-19-animal-tracker-H-auth-sync.md` are implemented; Tasks 1 to 4 are reviewed and fixed, Task 5's fix wave was landing at the pause, and Task 6 is written and tested offline but neither applied nor fixed.

This file exists because the full reviews live in a git-ignored execution workspace. The defects below are the ones that must not be lost. Each was found by an independent reviewer and verified by evidence rather than inspection alone.

## Blocking, Task 6 (the SQL migration)

Updated 2026-10-28. The migration has now been applied to a real local Postgres via `supabase db reset`. It parses and applies first try. Two of the criticals below are fixed in `b0c9fcd` and verified by query rather than by argument; they are kept here with their proof. The local run also found a new critical that no reviewer caught.

**Account deletion is completely broken, not merely incomplete.** Reviewed as "the audio bytes are orphaned", which understated it. On the current storage service a protective trigger on the storage table raises `42501 Direct deletion from storage tables is not allowed`. That delete is the first statement in the deletion function and the function is one transaction, so everything rolls back: the user's rows survive, the auth record survives, the account still exists. Pressing Delete Account does nothing at all and reports failure. This is now the first thing to fix, and it needs a decision between permitting the delete for that transaction or routing object removal through the Storage API from the client.

**FIXED in `b0c9fcd`. No table privileges were granted.** Proven before the fix, with the automatic grants switched off locally: `permission denied for table animals` on both select and insert. Proven after: the same query returns a row count. Two things the local run added. First, the obvious verification query is itself a trap: with the automatic grants withdrawn, the logged-in role still appears in the privileges table holding `REFERENCES, TRIGGER, TRUNCATE`, so a check asking merely whether it appears returns four healthy-looking rows while every real query fails. The check must name the four data privileges. Second, the cutover does not touch the storage table, so audio upload would have kept working and an upload-only smoke test would have reported the service healthy while every database request failed.

**FIXED in `b0c9fcd`. Built-in tag identifiers were unique across all users.** Proven before the fix: a victim's upsert of the real identifier for the built-in "Eating" tag against a squatted row fails with a row-level security violation. Proven after, with the key made per user: both accounts hold that identifier side by side. No foreign key existed between the four tables, so nothing already written broke, and getting the matching client change wrong is now a hard error rather than a silent one.


**Built-in tag ids are global and publicly computable.** `id uuid primary key` is unique across all users, and the deterministic v5 ids Plan B introduced are identical for every install. One user can insert the 19 built-in tag ids under their own account, after which every other user's push of their own built-in tags fails forever, because the upsert conflicts on a row they cannot see, update or delete. A permanent, all-users write denial, free to fix while the tables are empty. Fix: `primary key (user_id, id)` plus `on_conflict=user_id,id` on the pusher.

**Superseded, see above. No table privileges are granted, and Supabase stops granting them automatically on 2026-10-30.** The migration enables row level security and writes sixteen policies but never grants a table privilege. Supabase previously granted those automatically on new tables and is removing that behaviour, applying the change to existing projects on 2026-10-30 ([supabase discussion #45329](https://github.com/orgs/supabase/discussions/45329)). Privileges are checked before policies, so without the grants every request fails with `42501 permission denied`. The failure mode is the dangerous kind: the schema pushes cleanly, all tests pass, every planned verification query passes, and the sync path is dead on its first request. Fix: `grant select, insert, update, delete` on all four tables to `authenticated`. Note that account deletion runs as its owner and would keep working, so a user could delete an account they were never able to sync to.

**Superseded, see above, now known to be worse. Account deletion leaves the audio files behind.** Supabase's documentation states that deleting storage objects by SQL orphans the stored bytes and that deletion must go through the Storage API ([delete objects](https://supabase.com/docs/guides/storage/management/delete-objects)). The migration deletes the metadata rows, so the promise to remove a user's storage is not met. Fix: remove the prefix through the client or an edge function before the database call, keeping the SQL delete as a backstop.

**The documented manual fallback can half-apply the security boundary.** The command-line tool applies the whole migration in one transaction, verified from its source, so that path is safe. The README's `psql` fallback omits `--single-transaction`, so it commits per statement and can stop after the tables are created but before row level security is switched on, leaving four readable tables. The recovery note for a storage-permission failure is also wrong for the tool path, where a failure rolls the entire file back rather than leaving earlier blocks applied.

**The migration test pins wording, not behaviour.** It catches no syntax error, no name error and no privilege problem, and a permissive policy added as an extra clause leaves every count unchanged. For the four storage policies, swapping a delete policy for a second read policy holds all counts steady and would ship a bucket nobody can delete from. The fix needs no credentials: a local Postgres via `supabase start` and `supabase db reset` would actually apply the file, and configuring it to not auto-expose new tables reproduces the grant defect above.

**A deletion that arrives late is discarded, and the recording comes back.** The sticky-deletion assignment sits above the staleness gate, and the gate discards the incoming row wholesale, so deletion is sticky only once it has landed. Delete on one device offline, edit on another, and the edit wins: the deleting device is told its push succeeded, forgets the deletion, and restores the row on its next pull. The audio file was already removed, so the restored record points at nothing. Ruling: sticky deletion wins over timestamp order, because a deletion the user performed must not be undone by an edit they made earlier. Needs both a server change and a client rule that a remote tombstone always applies.

**The future-clock clamp targets the wrong instant.** Clamping to `now() + 5 minutes` hands a far-future device the newest timestamp any writer can hold, so for five minutes after each of its writes, honest devices' edits are silently discarded and then overwritten on the next pull. The freeze is bounded rather than removed, and renewed by every write. Clamp to `now()` instead.

**Rows can still be skipped permanently.** The server cursor is stamped at transaction start but becomes visible at commit, so stamps can appear out of order, and a row below a cursor the client has already passed is excluded by every later pull. Fix with a client-side safety lag on the persisted cursor; re-applying a row is already free.

**Row level security on the storage table is assumed, never asserted.** The migration enables it on the four application tables only. If it is off for storage objects, all four storage policies are inert and any authenticated user can read any other user's audio. Must be a blocking check before the schema is trusted.

**Pre-existing storage policies are never enumerated.** Policies combine with OR, so one leftover permissive policy defeats the private bucket, and the current verification filter would not see it.

**The bucket's allowed mime type does not match what the client sends.** The bucket allows `audio/mp4`; the client library derives `audio/x-m4a` from the file extension. Every upload would be rejected. Harmless to security, but it blocks the milestone at first contact.

## State at the pause

Tasks 1 to 5 are implemented, reviewed and fixed, at commit `e0c08e2`, with 248 app tests, 28 audio and 28 statistics tests passing. Task 6's migration is committed at `7062c00`, verified only as text, never applied, and carries every defect listed above.

## Resolved during execution, kept here because the mechanisms recur

- Fixed in `575b376`. An unreadable store-ownership record used to trigger a full wipe, so adding one field in a later release would have made users signing into their own account lose every recording not yet uploaded. Now "no record" and "record I cannot read" are distinguished, and the latter never wipes.
- Fixed in `e0c08e2`. The local wipe did not verify that the database file was gone, and reopened whatever remained. A surviving main file with deleted companions reopens intact, after which the new account is recorded as its owner, adopting the previous user's data. Ruling: an unverified wipe is a hard failure that keeps its retry marker and publishes nothing.
- Fixed in `90e3518`. Signing out verified the keychain was empty, but the library's background token refresh could rewrite it afterwards, leaving a wiped store with a live session that signed the user back in at next launch.
- Fixed in `c15e829`. The pre-push secret guard scanned the working tree rather than the commits being pushed, and reported clean on any git error.

## Standing decisions

- Sign-out is reported complete on the basis of the keychain being empty, not on the library's own result, because the library deletes the local session before its network call. This deliberately amends the spec's wording in favour of its intent.
- No logger is ever configured on the Supabase client. Two real leaks in the pinned version are inert only because of that: the refresh token enters a logger task-local, and the request interceptor would log the identity token and the raw nonce.
- `force row level security` stays absent. It buys nothing against non-owners and would silently break account deletion's table deletes.
