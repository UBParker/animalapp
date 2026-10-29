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

    /// Just the body of `sync_row_guard()`, so a rule about the trigger cannot be satisfied by
    /// text somewhere else in the file. `delete_my_account()` also raises and also deletes, and a
    /// whole-file `contains` would happily read its words as the trigger's.
    private func syncRowGuardBody() throws -> String {
        let sql = try migrationSQL()
        let head = try XCTUnwrap(sql.range(of: "create or replace function public.sync_row_guard()"),
                                 "the guard function is not in the file")
        let rest = sql[head.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "$$;"), "the guard function body is not terminated")
        return String(rest[..<end.lowerBound])
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

    func testTheOnlyIndexesAreThePullCursorOnes() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("(user_id, server_updated_at, id)", in: sql), 4, "pull cursor, ordered and tie-broken by id")
        XCTAssertEqual(count("(user_id, updated_at)", in: sql), 0,
                       "the push-side indexes served no query in this design: the server is never asked for rows by device timestamp")
        XCTAssertEqual(count("create index", in: sql), 4,
                       "four pull-cursor indexes and nothing else; (user_id, id) comes free with the primary key")
    }

    /// `id uuid primary key` is unique across every user, and the nineteen built-in tag ids are a
    /// fixed function of kind and name, so any install can compute them. One account inserting
    /// those nineteen ids under its own user_id makes every other account's tag push fail forever
    /// on `on conflict (id) do update`, against a row it cannot see, fix or delete.
    func testThePrimaryKeyIsPerUserSoATagIdCannotBeSquatted() throws {
        let sql = try migrationSQL()
        XCTAssertEqual(count("primary key (user_id, id)", in: sql), 4,
                       "the key must be per user, so two accounts can hold the same built-in tag id")
        XCTAssertEqual(count("id uuid primary key", in: sql), 0,
                       "a globally unique id is a cross-user denial of service on a publicly computable value")
        XCTAssertEqual(count("    id uuid not null,", in: sql), 4)
    }

    // MARK: privileges

    /// Privileges and row level security are independent, and privileges are checked first, so a
    /// missing grant refuses the request before a single policy is consulted. This used to be free
    /// because Supabase ran `alter default privileges` on every new table; that is being removed,
    /// and it reaches existing projects on 2026-10-30.
    /// https://github.com/orgs/supabase/discussions/45329
    func testEveryTableGrantsTheFourVerbsToAuthenticated() throws {
        let sql = try migrationSQL()
        for table in Self.tables {
            XCTAssertTrue(sql.contains("grant select, insert, update, delete on \(table) to authenticated"),
                          "no table privileges granted on \(table); every request would return 42501")
        }
        XCTAssertEqual(count("grant select, insert, update, delete on public.", in: sql), 4)
        XCTAssertFalse(sql.contains("to anon"), "anon is never a caller here; the app signs in before it syncs")
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
        XCTAssertEqual(count("to authenticated", in: sql), 25,
                       "twenty policies, four table grants, and the grant on delete_my_account()")
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
        // A count catches a clause that is REMOVED. It never catches one that is widened, because
        // `or true` leaves every occurrence in place.
        XCTAssertFalse(sql.contains("or true"), "a disjunctive true defeats every policy it is added to")
        XCTAssertFalse(sql.contains("using (true)"), "no policy may be unconditional")
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

    /// A `for each statement` trigger contains both of the needles the test above counts, and
    /// `new` does not exist in one, so every write would fail at runtime with the suite still green.
    func testTheGuardTriggerFiresOncePerRow() throws {
        XCTAssertEqual(count("for each row execute function public.sync_row_guard()", in: try migrationSQL()), 4,
                       "a statement-level trigger has no `new` and would fail on every write")
    }

    /// `return old` is the whole reason a superseded push gets a 2xx instead of an error. Swapping
    /// in `raise exception` changes no count anywhere and turns every stale retry into a failed sync.
    func testTheStaleBranchReturnsOldRatherThanRaising() throws {
        let body = try syncRowGuardBody()
        let gate = try XCTUnwrap(body.range(of: "if new.updated_at <= old.updated_at then"),
                                 "the staleness gate is gone")
        let afterGate = body[gate.upperBound...]
        let endIf = try XCTUnwrap(afterGate.range(of: "end if;"), "the staleness gate is not closed")
        XCTAssertEqual(afterGate[..<endIf.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                       "return old;",
                       "the stale branch must return the stored row untouched, not raise and not return null")
        XCTAssertFalse(body.contains("raise"), "the guard never raises; a stale device must see success and move on")
    }

    /// Pins today's order so a silent reorder is caught. It is also the ordering that makes an
    /// arriving delete lose to a newer stored row, which is finding 1 of the fix wave: when that
    /// is fixed the gate moves above the sticky assignment and this assertion inverts with it.
    func testTheStickyDeleteAssignmentSitsAboveTheStalenessGate() throws {
        let body = try syncRowGuardBody()
        let sticky = try XCTUnwrap(body.range(of: "new.deleted_at := coalesce(old.deleted_at, new.deleted_at)"),
                                   "the sticky delete assignment is gone")
        let gate = try XCTUnwrap(body.range(of: "if new.updated_at <= old.updated_at then"),
                                 "the staleness gate is gone")
        XCTAssertLessThan(sticky.lowerBound, gate.lowerBound,
                          "sticky above the gate: the two are order-dependent and neither needle alone says which runs first")
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

    /// The sixteen table policies are pinned verb by verb; the four storage ones were pinned only
    /// by a count, so swapping `for delete` for a second `for select` held every count steady and
    /// shipped a bucket no user can ever delete from.
    func testEveryStorageVerbHasItsOwnPolicy() throws {
        let sql = try migrationSQL()
        for verb in ["for select", "for insert", "for update", "for delete"] {
            XCTAssertTrue(sql.contains("on storage.objects \(verb) to authenticated"),
                          "missing a '\(verb) to authenticated' policy on storage.objects")
        }
    }

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
        XCTAssertEqual(count("set search_path", in: sql), 2,
                       "both functions pin it: the definer because it must, the trigger because it is free")
        XCTAssertTrue(sql.contains("grant execute on function public.delete_my_account() to authenticated"))
    }
}
