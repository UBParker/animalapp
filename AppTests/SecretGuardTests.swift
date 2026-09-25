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
