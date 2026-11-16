#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol

    /// The Mac's part of an import's extraction: decompression, and nothing that reads an
    /// archive format.
    ///
    /// The archive is input from outside maw. libarchive, behind `/usr/bin/tar`, reads every
    /// format it knows when it reads an archive, mtree among them, and an mtree entry names a file
    /// on the disk whose contents it reads, so `/usr/bin/tar` would copy the Mac's files into
    /// the new distribution. The import therefore passes the client's descriptor only through
    /// `/usr/bin/gzip -dcf`, which decompresses gzip, bzip2, xz, compress, and lzip and passes any
    /// other data through unchanged, and forwards the result only if its first block is a tar
    /// header. The guest's `bsdtar`, in the provisioning machine, is the only program that reads
    /// the archive's format (docs/security.md, "The extraction").
    enum ImportStream {
        static let decompressor = "/usr/bin/gzip"
        static let decompressorArguments = ["-d", "-c", "-f"]

        enum Outcome: Equatable {
            /// The stream was forwarded: `bytes` of it, and the decompressor's outcome.
            case streamed(bytes: UInt64, decompressor: StreamingProcess.Outcome)
            /// The decompressed stream does not start with a tar header; nothing was forwarded.
            case notATarArchive
            /// `forward` refused a chunk, as when the guest's process has ended.
            case stopped(bytes: UInt64)
        }

        /// Decompresses what `source` reads and hands it to `forward` chunk by chunk, once its
        /// first block has shown the tar magic. Blocks until the decompressor has exited; call
        /// it on a thread of its own. Takes over `source`.
        static func run(
            source: OwnedDescriptor, stopper: StreamingProcess.Stopper? = nil,
            forward: (Data) -> Bool
        ) throws -> Outcome {
            var gate = TarGate()
            var refused = false
            var stopped = false
            var bytes: UInt64 = 0
            func send(_ pieces: [Data]) -> Bool {
                for piece in pieces {
                    bytes += UInt64(piece.count)
                    if !forward(piece) {
                        stopped = true
                        return false
                    }
                }
                return true
            }
            let outcome = try StreamingProcess.run(
                decompressor, decompressorArguments, input: source, stopper: stopper
            ) { chunk in
                guard let pieces = gate.accept(chunk) else {
                    refused = true
                    return false
                }
                return send(pieces)
            }
            if refused {
                return .notATarArchive
            }
            if stopped {
                return .stopped(bytes: bytes)
            }
            guard let rest = gate.finish() else {
                // A stream that ended short because the decompressor failed, as a truncated
                // archive does, reports that failure rather than the missing header.
                // An empty one is not a tar archive.
                return outcome.status != 0 && gate.heldBytes > 0
                    ? .streamed(bytes: bytes, decompressor: outcome) : .notATarArchive
            }
            if !send(rest) {
                return .stopped(bytes: bytes)
            }
            return .streamed(bytes: bytes, decompressor: outcome)
        }
    }

    /// Holds back the start of a stream until it shows the magic of a tar header, `ustar` at
    /// offset 257 of the first block, which POSIX ustar, pax, and GNU tar archives have.
    struct TarGate {
        static let magicRange = 257..<262
        static let magic = Data("ustar".utf8)

        private var pending = Data()
        private var passed = false

        /// The bytes held back while the magic has not arrived yet.
        var heldBytes: Int { pending.count }

        /// The chunks to forward now, or `nil` if the stream is not a tar archive.
        mutating func accept(_ chunk: Data) -> [Data]? {
            if passed {
                return [chunk]
            }
            pending.append(chunk)
            guard pending.count >= Self.magicRange.upperBound else { return [] }
            guard pending[Self.magicRange] == Self.magic else { return nil }
            passed = true
            defer { pending = Data() }
            return [pending]
        }

        /// What is left at the end of the stream, or `nil` if the stream ended before it showed
        /// the magic.
        mutating func finish() -> [Data]? {
            passed ? [] : nil
        }
    }
#endif
