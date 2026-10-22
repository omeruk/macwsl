import Foundation
import MawCore
import MawDaemonKit
import Testing

@Suite struct LaunchAgentTests {
    @Test func writesTheExpectedPropertyList() throws {
        let home = MawPaths().homeDirectory.path(percentEncoded: false)
        let agent = LaunchAgent(program: "/Users/me/maw/.build/debug/mawd")
        let expected = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>dev.maw.mawd</string>
            \t<key>MachServices</key>
            \t<dict>
            \t\t<key>dev.maw.mawd</key>
            \t\t<true/>
            \t</dict>
            \t<key>ProcessType</key>
            \t<string>Interactive</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \t\t<string>/Users/me/maw/.build/debug/mawd</string>
            \t\t<string>serve</string>
            \t</array>
            \t<key>StandardErrorPath</key>
            \t<string>\(home)Library/Logs/maw/mawd.log</string>
            \t<key>StandardOutPath</key>
            \t<string>\(home)Library/Logs/maw/mawd.log</string>
            </dict>
            </plist>

            """
        #expect(String(decoding: try agent.propertyListData(), as: UTF8.self) == expected)
    }

    @Test func passesNonDefaultSettingsToServe() {
        let agent = LaunchAgent(
            label: "dev.maw.mawd.integration-test", program: "/tmp/mawd",
            logDirectory: URL(filePath: "/tmp/logs", directoryHint: .isDirectory),
            machineIdleTimeout: 3, daemonIdleTimeout: 30)
        #expect(
            agent.arguments == [
                "/tmp/mawd", "serve", "--label", "dev.maw.mawd.integration-test",
                "--log-directory", "/tmp/logs/", "--machine-idle-timeout", "3",
                "--daemon-idle-timeout", "30",
            ])
        let services = agent.propertyList["MachServices"] as? [String: Bool]
        #expect(services == ["dev.maw.mawd.integration-test": true])
        #expect(agent.propertyList["StandardErrorPath"] as? String == "/tmp/logs/mawd.log")
    }

    @Test func neitherRunsAtLoadNorStaysAlive() {
        let list = LaunchAgent(program: "/tmp/mawd").propertyList
        #expect(list["RunAtLoad"] == nil)
        #expect(list["KeepAlive"] == nil)
    }
}
