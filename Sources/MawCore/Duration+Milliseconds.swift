extension Duration {
    /// The duration in whole milliseconds, rounded toward zero.
    public var milliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
