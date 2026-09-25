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
