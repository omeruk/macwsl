import ArgumentParser
import MawCore

extension Maw {
    /// Turns the parsed flags into a single `Action`, or explains why the combination is invalid.
    func resolveAction() throws -> Action {
        let requests = self.requests
        if requests.count > 1 {
            throw ValidationError(
                "\(requests[0].displayName) cannot be combined with \(requests[1].displayName).")
        }
        let request = requests.first
        try validateListModifiers(for: request)
        try validateSessionOptions(for: request)

        let session = Session(
            distro: running.distribution, user: running.user, directory: running.directory)

        switch request {
        case nil:
            if let operand {
                // Unreachable through `main`: the normalizer turns a bare operand into a command.
                throw ValidationError(
                    "Unexpected argument '\(operand)'. To run a command, put it after --.")
            }
            return .shell(session)
        case .command(let command):
            try expectNoOperands(after: "a command")
            return .run(command, session)
        case .exec(let command):
            try expectNoOperands(after: CLIOption.exec.displayName)
            if command.isEmpty {
                throw ValidationError(
                    "\(CLIOption.exec.displayName) needs a command to run: "
                        + "maw -e <command> [<argument>...].")
            }
            return .exec(command, session)
        case .install:
            return try .install(installTarget())
        case .list:
            try expectNoOperands(after: CLIOption.list.displayName)
            return .list(managing.online ? .online : .installed(verbose: managing.verbose))
        case .setDefault(let name):
            try expectNoOperands(after: CLIOption.setDefault.displayName)
            return .setDefault(name)
        case .terminate(let name):
            try expectNoOperands(after: CLIOption.terminate.displayName)
            return .terminate(name)
        case .shutdown:
            try expectNoOperands(after: CLIOption.shutdown.displayName)
            return .shutdown
        case .export(let name):
            return .export(name, file: try fileOperand(for: CLIOption.export, purpose: "write"))
        case .importDistro(let name):
            return .importDistro(
                name, file: try fileOperand(for: CLIOption.import, purpose: "read"))
        case .unregister(let name):
            try expectNoOperands(after: CLIOption.unregister.displayName)
            return .unregister(name)
        case .status:
            try expectNoOperands(after: CLIOption.status.displayName)
            return .status
        case .version:
            try expectNoOperands(after: CLIOption.version.displayName)
            return .version
        }
    }

    /// Every action the user asked for, in a fixed order. More than one is an error.
    private var requests: [Request] {
        var requests: [Request] = []
        if managing.install { requests.append(.install) }
        if managing.list { requests.append(.list) }
        if let name = managing.setDefault { requests.append(.setDefault(name)) }
        if let name = managing.terminate { requests.append(.terminate(name)) }
        if managing.shutdown { requests.append(.shutdown) }
        if let name = managing.export { requests.append(.export(name)) }
        if let name = managing.import { requests.append(.importDistro(name)) }
        if let name = managing.unregister { requests.append(.unregister(name)) }
        if general.status { requests.append(.status) }
        if general.version { requests.append(.version) }
        if running.exec {
            requests.append(.exec(command))
        } else if !command.isEmpty {
            requests.append(.command(command))
        }
        return requests
    }

    private func validateListModifiers(for request: Request?) throws {
        let verbose = CLIOption.verbose.displayName
        let online = CLIOption.online.displayName
        if managing.verbose && managing.online {
            throw ValidationError("\(verbose) cannot be combined with \(online).")
        }
        guard case .list = request else {
            for (option, isSet) in [(verbose, managing.verbose), (online, managing.online)]
            where isSet {
                throw ValidationError(
                    "\(option) can only be used with \(CLIOption.list.displayName).")
            }
            return
        }
    }

    private func validateSessionOptions(for request: Request?) throws {
        guard let request else { return }
        let given: [(option: CLIOption, isSet: Bool)] = [
            (.distribution, running.distribution != nil),
            (.user, running.user != nil),
            (.cd, running.directory != nil),
        ]
        for (option, isSet) in given where isSet {
            let accepted =
                option == .distribution ? request.acceptsDistribution : request.acceptsSession
            if !accepted {
                throw ValidationError(
                    "\(request.displayName) cannot be combined with \(option.displayName).")
            }
        }
    }

    /// The distribution named after `--install` or with `-d`, or `nil` for the recommended one.
    private func installTarget() throws -> DistroName? {
        guard let operand else {
            return running.distribution
        }
        if running.distribution != nil {
            throw ValidationError(
                "Name the distribution to install either after \(CLIOption.install.displayName) "
                    + "or with \(CLIOption.distribution.displayName), not both.")
        }
        do {
            return try DistroName(operand)
        } catch {
            throw ValidationError(
                [error.errorDescription, error.recoverySuggestion].compactMap { $0 }
                    .joined(separator: " "))
        }
    }

    private func fileOperand(for option: CLIOption, purpose: String) throws -> String {
        guard let operand else {
            throw ValidationError(
                "\(option.displayName) needs a file to \(purpose): "
                    + "maw --\(option.long) <distro> <file>.")
        }
        return operand
    }

    private func expectNoOperands(after name: String) throws {
        if let operand {
            throw ValidationError("Unexpected argument '\(operand)' after \(name).")
        }
    }
}

/// An action as requested on the command line, before its operands are checked.
private enum Request {
    case install
    case list
    case setDefault(DistroName)
    case terminate(DistroName)
    case shutdown
    case export(DistroName)
    case importDistro(DistroName)
    case unregister(DistroName)
    case status
    case version
    case exec([String])
    case command([String])

    var displayName: String {
        switch self {
        case .install: CLIOption.install.displayName
        case .list: CLIOption.list.displayName
        case .setDefault: CLIOption.setDefault.displayName
        case .terminate: CLIOption.terminate.displayName
        case .shutdown: CLIOption.shutdown.displayName
        case .export: CLIOption.export.displayName
        case .importDistro: CLIOption.import.displayName
        case .unregister: CLIOption.unregister.displayName
        case .status: CLIOption.status.displayName
        case .version: CLIOption.version.displayName
        case .exec: CLIOption.exec.displayName
        case .command: "a command"
        }
    }

    /// Whether `-d` applies. `--install -d <distro>` names the distribution to install.
    var acceptsDistribution: Bool {
        switch self {
        case .install, .exec, .command: true
        default: false
        }
    }

    /// Whether `-u` and `--cd` apply.
    var acceptsSession: Bool {
        switch self {
        case .exec, .command: true
        default: false
        }
    }
}
