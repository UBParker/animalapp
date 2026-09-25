import XCTest
@testable import AnimalTracker

/// The same patterns `scripts/check-secrets.sh` greps for. Kept in Swift so a change to one side
/// without the other fails a test instead of silently weakening the guard. That promise is what
/// `testShellAndSwiftPatternListsMatch` actually enforces: it reads the shell script off disk,
/// parses its `PATTERNS=( ... )` array and asserts set equality with `SecretPatterns.all`.
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

    /// A second service-role key, claims in a different order so the role lands at a different
    /// byte alignment inside the payload. It hits the third of the three base64 needles.
    func testCatchesAServiceRoleJwtAtAnotherAlignment() {
        let header = joined("eyJ", "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        let payload = joined("eyJhdWQiOiJhdXRoZW50aWNhdGVkIiwiaXNzIjoic3VwYWJhc2UiLCJyZWYiOiJvanptdHlhcGtheHhsaXV1cnNzYyIsInJvbGUiOiJzZXJ2",
                             "aWNlX3JvbGUiLCJpYXQiOjE3ODk4MTkyMDAsImV4cCI6MTk0NzU4NTYwMH0")
        XCTAssertTrue(matches("\(header).\(payload).signature"))
    }

    /// The same anon key with more claims and a different ordering. The real anon key will be
    /// committed to App/Config/Supabase.plist, so a pattern that matched any JWT would block
    /// every future push.
    func testDoesNotCatchAnAnonJwtWithMoreClaims() {
        let header = joined("eyJ", "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        let payload = joined("eyJhdWQiOiJhdXRoZW50aWNhdGVkIiwiaXNzIjoic3VwYWJhc2UiLCJyZWYi",
                             "OiJvanptdHlhcGtheHhsaXV1cnNzYyIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNzg5ODE5MjAwLCJleHAiOjE5NDc1ODU2MDB9")
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

    /// A quoted role name is still a role name, not a credential. Task 6 writes SQL into this
    /// repo and quoting an identifier there is ordinary. The credential is the JWT, which
    /// `testCatchesAServiceRoleJwt` covers on its own.
    func testDoesNotCatchAQuotedServiceRoleInSql() {
        XCTAssertFalse(matches(joined("grant select on table public.animals to \"service", "_role\";")))
    }

    /// Same for the JSON spelling of the role, which is what a decoded JWT or a client option
    /// block looks like when it is pasted into a document.
    func testDoesNotCatchAServiceRoleInJson() {
        XCTAssertFalse(matches(joined("{ auth: { role: 'service", "_role' } }")))
    }

    /// Documenting the command with the password held in an environment variable is the correct
    /// way to write it, and it carries no secret. The password segment excludes $, { and }.
    func testDoesNotCatchAnInterpolatedPostgresUrl() {
        let dollar = "$"
        XCTAssertFalse(matches("supabase db push --db-url postgresql://postgres:\(dollar)DB_PASSWORD@db.x.supabase.co:5432/postgres"))
    }

    func testDoesNotCatchABracedInterpolatedPostgresUrl() {
        let dollar = "$"
        XCTAssertFalse(matches("psql \"postgresql://postgres:\(dollar){PGPASSWORD}@host:5432/postgres\""))
    }

    func testDoesNotCatchOrdinaryProse() {
        XCTAssertFalse(matches("The anon key is public and lives in App/Config/Supabase.plist."))
    }

    // MARK: - The shell script and the Swift twin are one list

    /// Both file headers promise that editing one pattern list without the other fails a test.
    /// Nothing enforced that, so this does: parse the shell array and compare it as a set.
    func testShellAndSwiftPatternListsMatch() throws {
        let shell = try Self.shellPatterns()
        XCTAssertFalse(shell.isEmpty, "parsed no patterns out of scripts/check-secrets.sh")
        XCTAssertEqual(shell.count, Set(shell).count, "scripts/check-secrets.sh lists a duplicate pattern")
        XCTAssertEqual(SecretPatterns.all.count, Set(SecretPatterns.all).count, "SecretPatterns.all lists a duplicate")
        XCTAssertEqual(Set(shell), Set(SecretPatterns.all),
                       "scripts/check-secrets.sh and SecretPatterns.swift disagree. Only in the script: "
                       + "\(Set(shell).subtracting(SecretPatterns.all).sorted()). Only in Swift: "
                       + "\(Set(SecretPatterns.all).subtracting(shell).sorted())")
    }

    /// `#filePath` is a compile-time absolute path on the machine that built the tests, and the
    /// simulator shares that file system, so the script is readable from the test run.
    static func scriptURL(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)            // AppTests/SecretGuardTests.swift
            .deletingLastPathComponent()      // AppTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("scripts/check-secrets.sh")
    }

    /// Parses `PATTERNS=( ... )` out of the shell script, one single- or double-quoted entry per
    /// line, and unescapes the double-quoted form so both sides hold the same regex text.
    static func shellPatterns() throws -> [String] {
        let url = scriptURL()
        let text = try String(contentsOf: url, encoding: .utf8)
        var patterns: [String] = []
        var inside = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line == "PATTERNS=(" { inside = true }
                continue
            }
            if line.hasPrefix(")") { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            var entry = line
            if entry.hasSuffix(",") { entry.removeLast() }
            guard let quote = entry.first, quote == "'" || quote == "\"", entry.count >= 2,
                  entry.last == quote else {
                XCTFail("unquoted entry in the PATTERNS array: \(line)")
                continue
            }
            entry.removeFirst()
            entry.removeLast()
            if quote == "\"" {
                entry = entry.replacingOccurrences(of: "\\\"", with: "\"")
                entry = entry.replacingOccurrences(of: "\\\\", with: "\\")
            }
            patterns.append(entry)
        }
        return patterns
    }
}
