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
