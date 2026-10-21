import Foundation

/// Errors reading or writing `settings.json`. Each message names the file and the problem; the
/// app shows it in a banner and keeps the last valid settings.
public enum SettingsError: Error, Hashable, Sendable {
    /// The file is not valid JSON, or a value has the wrong type. `detail` locates the problem.
    case invalid(detail: String)
    /// The file was written by a newer version of maw, in a format this build cannot read.
    case newerVersion(found: Int, supported: Int)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
}

extension SettingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail):
            "settings.json is invalid: \(detail)"
        case .newerVersion(let found, let supported):
            "settings.json has format version \(found), but this version of maw reads up to "
                + "version \(supported)"
        case .readFailed(let path, let reason):
            "\(path) could not be read: \(reason)"
        case .writeFailed(let path, let reason):
            "\(path) could not be written: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalid, .readFailed:
            "Fix the file and save it; maw reloads it automatically. Until then it uses the last "
                + "valid settings."
        case .newerVersion:
            "Update maw, or remove the file to start from the default settings."
        case .writeFailed:
            "Check the permissions of ~/Library/Application Support/maw."
        }
    }
}

/// Upgrades settings files from older format versions.
///
/// Each migration takes the file from version `n` to `n + 1`, as JSON, before the typed
/// decoding. Version 1 is the first format, so there are no migrations yet; the next format
/// change adds `2: { ... }` to `steps`.
public struct SettingsMigration: Sendable {
    public typealias Step = @Sendable (inout JSONValue) -> Void

    public var steps: [Int: Step]
    public var currentVersion: Int

    public init(steps: [Int: Step] = [:], currentVersion: Int = Settings.currentVersion) {
        self.steps = steps
        self.currentVersion = currentVersion
    }

    public static let standard = SettingsMigration()

    /// Brings `json` to `currentVersion` and sets its `version` key. A file without a version is
    /// treated as version 1.
    public func migrate(_ json: inout JSONValue) throws(SettingsError) {
        var version: Int
        switch json["version"] {
        case nil, .null?:
            version = 1
        case .number(let number)?:
            guard number.rounded() == number, number >= 1 else {
                throw .invalid(detail: "version: expected a whole number of at least 1")
            }
            version = Int(number)
        default:
            throw .invalid(detail: "version: expected a number")
        }
        guard version <= currentVersion else {
            throw .newerVersion(found: version, supported: currentVersion)
        }
        while version < currentVersion {
            steps[version + 1]?(&json)
            version += 1
        }
        json["version"] = .number(Double(currentVersion))
    }
}

/// Reads and writes the settings file format.
public enum SettingsCoding {
    /// Decodes a settings file, migrating it first.
    public static func decode(_ data: Data, migration: SettingsMigration = .standard)
        throws(SettingsError) -> Settings
    {
        let decoder = JSONDecoder()
        var json: JSONValue
        do {
            json = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw .invalid(detail: describe(error))
        }
        guard case .object = json else {
            throw .invalid(detail: "the file must contain a JSON object")
        }
        try migration.migrate(&json)
        do {
            let migrated = try JSONEncoder().encode(json)
            return try decoder.decode(Settings.self, from: migrated)
        } catch {
            throw .invalid(detail: describe(error))
        }
    }

    /// Encodes settings with sorted keys and indentation, so that the file is easy to edit and
    /// its diffs are stable.
    public static func encode(_ settings: Settings) throws(SettingsError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(settings)
            data.append(0x0A)
            return data
        } catch {
            throw .invalid(detail: describe(error))
        }
    }

    /// A one-line description of a decoding error: the key path and what was wrong, or the JSON
    /// syntax error with its line and column.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ codingPath: [any CodingKey]) -> String {
            var text = ""
            for key in codingPath {
                if let index = key.intValue {
                    text += "[\(index)]"
                } else {
                    text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return text
        }
        func located(_ context: DecodingError.Context, _ message: String) -> String {
            let location = path(context.codingPath)
            return location.isEmpty ? message : "\(location): \(message)"
        }
        switch error {
        case .typeMismatch(let type, let context):
            return located(context, "expected \(typeName(type))")
        case .valueNotFound(let type, let context):
            return located(context, "expected \(typeName(type)), found null")
        case .keyNotFound(let key, let context):
            return located(context, "missing key \"\(key.stringValue)\"")
        case .dataCorrupted(let context):
            if let underlying = context.underlyingError as NSError?,
                let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String
            {
                return located(context, detail)
            }
            return located(context, context.debugDescription)
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Double.Type, is Int.Type: "a number"
        case is Bool.Type: "true or false"
        case is [Any].Type: "an array"
        default: "a \(String(describing: type))"
        }
    }
}
