#if os(macOS)
    import Foundation
    import MawCore
    import Security

    /// Which programs may talk to the daemon. docs/daemon.md explains what the requirement
    /// protects against and how it tightens once phase 13 signs with a team identifier.
    public enum PeerRequirement {
        /// The code signing identifiers of maw's executables. `scripts/sign-dev.sh` signs
        /// `maw` and `mawd` with them. Phase 11b adds the terminal app, `dev.maw.app`.
        public static let identifiers = ["dev.maw.maw", "dev.maw.mawd"]

        /// The requirement the daemon sets on every peer:
        /// `identifier "dev.maw.maw" or identifier "dev.maw.mawd"`.
        public static var codeSigningRequirement: String {
            identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        }

        /// Throws `clientSignatureRejected` unless this process is signed with one of the
        /// identifiers.
        ///
        /// The daemon enforces the requirement itself, but a client it rejects sees only an
        /// interrupted connection, which it cannot tell apart from a crash. Checking first
        /// turns that into an error that names the fix.
        public static func checkCurrentProcess() throws(MawError) {
            let identifier = currentIdentifier() ?? "an unknown identifier"
            guard identifiers.contains(identifier) else {
                throw .clientSignatureRejected(identifier: identifier)
            }
        }

        /// The code signing identifier of this process, or `nil` if it has none.
        static func currentIdentifier() -> String? {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                let staticCode
            else { return nil }
            var information: CFDictionary?
            guard
                SecCodeCopySigningInformation(
                    staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                    == errSecSuccess,
                let information = information as? [String: Any]
            else { return nil }
            return information[kSecCodeInfoIdentifier as String] as? String
        }
    }
#endif
