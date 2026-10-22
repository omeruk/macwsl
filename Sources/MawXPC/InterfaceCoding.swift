#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol
    import XPC

    /// Turns interface messages into XPC dictionaries and back.
    ///
    /// ```
    /// interfaceVersion  uint64   DaemonInterface.version; never changes shape
    /// body              data     the message as JSON
    /// descriptor        fd       optional; the guest agent connection of sessionOpened
    /// ```
    ///
    /// The version travels outside the JSON body, so that any two versions of maw can detect
    /// a mismatch even when the bodies have nothing else in common. The receiver checks it
    /// before it decodes the body.
    public enum InterfaceCoding {
        static let versionKey = "interfaceVersion"
        static let bodyKey = "body"
        static let descriptorKey = "descriptor"

        /// Which side is decoding, which decides how a version mismatch is reported.
        public enum Role: Sendable {
            case client
            case daemon
        }

        /// Encodes `body` into a new dictionary. With `descriptor`, the dictionary carries a
        /// duplicate of it; the caller still owns the original.
        public static func encode(
            _ body: some Encodable, descriptor: Int32? = nil,
            version: UInt32 = DaemonInterface.version
        ) throws(MawError) -> XPCObject {
            let dictionary = xpc_dictionary_create_empty()
            try fill(dictionary, with: body, descriptor: descriptor, version: version)
            return XPCObject(dictionary)
        }

        /// Encodes `body` into the reply to `request`, or `nil` if the request expects none.
        public static func encodeReply(
            to request: XPCObject, _ body: some Encodable, descriptor: Int32? = nil
        ) throws(MawError) -> XPCObject? {
            guard let reply = xpc_dictionary_create_reply(request.raw) else {
                return nil
            }
            try fill(reply, with: body, descriptor: descriptor, version: DaemonInterface.version)
            return XPCObject(reply)
        }

        private static func fill(
            _ dictionary: xpc_object_t, with body: some Encodable, descriptor: Int32?,
            version: UInt32
        ) throws(MawError) {
            let data: Data
            do {
                data = try JSONEncoder().encode(body)
            } catch {
                throw .daemonProtocolError(reason: "a message could not be encoded: \(error)")
            }
            xpc_dictionary_set_uint64(dictionary, versionKey, UInt64(version))
            data.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(dictionary, bodyKey, bytes.baseAddress!, bytes.count)
            }
            if let descriptor {
                xpc_dictionary_set_fd(dictionary, descriptorKey, descriptor)
            }
        }

        /// The interface version a dictionary carries, or `nil` if it carries none.
        public static func version(of message: XPCObject) -> UInt32? {
            guard message.isDictionary,
                xpc_dictionary_get_value(message.raw, versionKey) != nil
            else {
                return nil
            }
            return UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(message.raw, versionKey))
        }

        /// Checks the version and decodes the body. A different version throws
        /// `daemonVersionMismatch`, oriented by `role`.
        public static func decode<Body: Decodable>(
            _ type: Body.Type, from message: XPCObject, as role: Role
        ) throws(MawError) -> Body {
            guard let remote = version(of: message) else {
                throw .daemonProtocolError(reason: "a message has no interface version")
            }
            guard remote == DaemonInterface.version else {
                switch role {
                case .client:
                    throw .daemonVersionMismatch(client: DaemonInterface.version, daemon: remote)
                case .daemon:
                    throw .daemonVersionMismatch(client: remote, daemon: DaemonInterface.version)
                }
            }
            var length = 0
            guard let bytes = xpc_dictionary_get_data(message.raw, bodyKey, &length) else {
                throw .daemonProtocolError(reason: "a message has no body")
            }
            let data = Data(bytes: bytes, count: length)
            do {
                return try JSONDecoder().decode(Body.self, from: data)
            } catch {
                throw .daemonProtocolError(
                    reason: "a \(String(describing: Body.self)) message could not be decoded: "
                        + "\(error)")
            }
        }

        /// A duplicate of the descriptor the message carries, which the caller owns, or `nil`.
        public static func descriptor(in message: XPCObject) -> OwnedDescriptor? {
            guard message.isDictionary else { return nil }
            let descriptor = xpc_dictionary_dup_fd(message.raw, descriptorKey)
            return descriptor >= 0 ? OwnedDescriptor(descriptor) : nil
        }
    }
#endif
