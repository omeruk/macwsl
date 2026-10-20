import Foundation
import MacWSLCore
import MacWSLProtocol

// The guest has no unified logging. Until swift-log is wired up in phase 04, the agent writes
// its log lines to stderr, which the initramfs sends to the VM console.
let startup =
    "macwsl-agent \(MacWSLVersion.current) starting (protocol "
    + "\(ProtocolVersion.current), placeholder, exiting)\n"
FileHandle.standardError.write(Data(startup.utf8))
