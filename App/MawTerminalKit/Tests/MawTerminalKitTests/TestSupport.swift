import Foundation
import Testing

// `#expect` cannot contain a mutating call, such as `#expect(tree.close(a))`, so these take the
// call's result as an argument and report failures at the caller's line.

func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}

func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}

/// The canonical path, as `pwd -P` and `proc_pidinfo` report it. Unlike
/// `URL.resolvingSymlinksInPath()`, this keeps `/private` in `/private/tmp`.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
