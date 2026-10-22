#if os(macOS)
    import XPC

    /// An XPC object that may cross tasks and threads.
    ///
    /// libxpc objects are reference counted and safe to read from any thread. Every object this
    /// module creates is filled in completely before it is shared and never changed afterwards,
    /// which is what makes the unchecked conformance sound.
    public struct XPCObject: @unchecked Sendable {
        public let raw: xpc_object_t

        public init(_ raw: xpc_object_t) {
            self.raw = raw
        }

        /// Whether the object is an XPC dictionary, as every message is.
        public var isDictionary: Bool {
            xpc_get_type(raw) == XPC_TYPE_DICTIONARY
        }
    }
#endif
