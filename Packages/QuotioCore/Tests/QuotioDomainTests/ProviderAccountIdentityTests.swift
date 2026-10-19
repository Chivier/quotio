import QuotioDomain
import XCTest

final class ProviderAccountIdentityTests: XCTestCase {
    /// Vectors computed with the previous build's `MonitorIdentity.fingerprint`
    /// (first 8 hex digits of SHA-256). Keys it persisted must stay identical.
    func testCodexCanonicalKeyMatchesKeysWrittenByThePreviousBuild() {
        XCTAssertEqual(
            CodexAccountKey.canonical(email: "someone@mail.com", accountID: "account-1", fallback: "Codex"),
            "someone@mail.com • 07e99801"
        )
        XCTAssertEqual(
            CodexAccountKey.canonical(email: " someone@mail.com ", accountID: " workspace-team ", fallback: "Codex"),
            "someone@mail.com • d782057d"
        )
        XCTAssertEqual(CodexAccountKey.fingerprint("workspace-personal"), "eed01d5b")
    }

    func testCodexCanonicalKeyPrefersAUniqueLegacyAliasAndFallsBackWithoutIdentity() {
        XCTAssertEqual(
            CodexAccountKey.canonical(
                email: "someone@mail.com",
                accountID: "account-1",
                aliases: ["account-1": "someone@mail.com-plus"],
                fallback: "Codex"
            ),
            "someone@mail.com-plus"
        )
        XCTAssertEqual(
            CodexAccountKey.canonical(email: nil, accountID: "account-1", fallback: "Codex"),
            "Codex • 07e99801"
        )
        XCTAssertEqual(CodexAccountKey.canonical(email: "a@b.c", accountID: " ", fallback: "Codex"), "a@b.c")
    }

    func testTwoWorkspacesOnOneEmailGetDistinctKeys() {
        let personal = CodexAccountKey.canonical(email: "a@b.c", accountID: "workspace-personal", fallback: "")
        let team = CodexAccountKey.canonical(email: "a@b.c", accountID: "workspace-team", fallback: "")
        XCTAssertNotEqual(personal, team)
    }

    func testOnlyEmailOnlyMetadataMayIdentifyAFingerprintedRequest() {
        XCTAssertTrue(CodexAccountKey.mayIdentifyStoredAccount(
            "a@b.c • 07e99801", metadataKey: "a@b.c", displayName: "a@b.c"
        ))
        XCTAssertFalse(CodexAccountKey.mayIdentifyStoredAccount(
            "A@B.C", metadataKey: "a@b.c • 07e99801", displayName: "a@b.c"
        ))
        XCTAssertFalse(CodexAccountKey.mayIdentifyStoredAccount(
            "a@b.c • d782057d", metadataKey: "a@b.c • 07e99801", displayName: "a@b.c"
        ))
        XCTAssertTrue(CodexAccountKey.mayIdentifyStoredAccount(
            "a@b.c • 07e99801", metadataKey: "a@b.c • 07e99801", displayName: "a@b.c"
        ))
        XCTAssertFalse(CodexAccountKey.mayIdentifyStoredAccount(
            "a@b.c • not-hex!", metadataKey: "a@b.c", displayName: "a@b.c"
        ))
    }

    func testKiroCanonicalKeyPrefersProfileThenEmailThenFilename() {
        XCTAssertEqual(
            KiroAccountIdentity.canonicalKey(
                email: "dev@example.com",
                profileARN: "arn:aws:codewhisperer:us-east-1:1:profile/A",
                filename: "kiro-a.json"
            ),
            "arn:aws:codewhisperer:us-east-1:1:profile/A"
        )
        XCTAssertEqual(
            KiroAccountIdentity.canonicalKey(email: "dev@example.com", profileARN: " ", filename: "kiro-a.json"),
            "dev@example.com"
        )
        XCTAssertEqual(
            KiroAccountIdentity.canonicalKey(email: nil, profileARN: nil, filename: "kiro-google-1.json"),
            "kiro-google-1"
        )
    }

    func testKiroSyntheticLoginProviderKeysSurviveOnlyAsAliases() {
        XCTAssertEqual(
            KiroAccountIdentity.legacyKeys(
                email: nil,
                profileARN: nil,
                filename: "kiro-google-1.json",
                loginProvider: "Google",
                isNativeCredential: false
            ),
            ["Kiro (Google)"]
        )
        XCTAssertEqual(
            KiroAccountIdentity.legacyKeys(
                email: "dev@example.com",
                profileARN: "arn:profile",
                filename: "kiro-auth-token.json",
                loginProvider: "Google",
                isNativeCredential: true
            ),
            ["dev@example.com", "kiro-auth-token"]
        )
        XCTAssertEqual(
            KiroAccountIdentity.legacyKeys(
                email: nil,
                profileARN: nil,
                filename: "kiro-auth-token.json",
                loginProvider: nil,
                isNativeCredential: true
            ),
            ["Kiro"]
        )
    }
}
