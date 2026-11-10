// SPDX-License-Identifier: MPL-2.0
import AuthenticationServices
import Foundation
import SwiftUI

extension Data {
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Passkeys inside the app (docs/adr/0007-passkeys-in-the-app.md). iOS only lets the app use the
/// passkeys of a domain listed in its Associated Domains entitlement, set by whoever signs the build;
/// `HarinaPasskeyDomain` in Info.plist says which one. Other servers keep linking with a code.
@MainActor
enum Passkeys {
    static var domain: String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "HarinaPasskeyDomain") as? String,
              !text.isEmpty, !text.hasPrefix("$(") else { return nil }
        return text
    }

    static func available(for server: URL?) -> Bool {
        guard let domain, let host = server?.host() else { return false }
        return host == domain
    }

    /// True when the person closed the system sheet: not an error worth showing.
    static func cancelled(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    /// Signs this iPhone in with a passkey of the account (for example after reinstalling) and syncs.
    static func signIn(server: URL, controller: AuthorizationController) async throws {
        let sync = SyncService.shared
        let c = try await sync.passkeySignInChallenge(server: server)
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: c.rpID)
        let result = try await controller.performRequest(provider.createCredentialAssertionRequest(challenge: c.challenge))
        guard case let .passkeyAssertion(a) = result else { throw SyncError.unauthorized }
        let id = a.credentialID.base64URL
        let credential: [String: Any] = [
            "id": id, "rawId": id, "type": "public-key", "clientExtensionResults": [String: Any](),
            "response": [
                "clientDataJSON": a.rawClientDataJSON.base64URL,
                "authenticatorData": a.rawAuthenticatorData.base64URL,
                "signature": a.signature.base64URL,
                "userHandle": a.userID.base64URL,
            ],
        ]
        try await sync.signIn(server: server, challengeId: c.id, credential: credential, deviceName: UIDevice.current.name)
        await sync.sync()
    }

    /// Adds a passkey to the account this iPhone is linked to, so it can always be recovered.
    static func create(controller: AuthorizationController) async throws {
        let sync = SyncService.shared
        let c = try await sync.passkeyRegistrationChallenge()
        guard let userID = c.userID else { throw SyncError.server(0) }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: c.rpID)
        let request = provider.createCredentialRegistrationRequest(challenge: c.challenge, name: c.userName ?? "Harina", userID: userID)
        let result = try await controller.performRequest(request)
        guard case let .passkeyRegistration(r) = result, let attestation = r.rawAttestationObject else { throw SyncError.server(0) }
        let id = r.credentialID.base64URL
        let credential: [String: Any] = [
            "id": id, "rawId": id, "type": "public-key", "clientExtensionResults": [String: Any](),
            "response": [
                "clientDataJSON": r.rawClientDataJSON.base64URL,
                "attestationObject": attestation.base64URL,
                "transports": ["internal", "hybrid"],
            ],
        ]
        try await sync.registerPasskey(challengeId: c.id, credential: credential)
    }
}
