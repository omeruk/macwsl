import Foundation
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// The download's progress line on a terminal of 80, 60, and 40 columns.
@Suite struct InstallProgressWidthTests {
    let text = InstallProgressText(
        name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS")
    static let progress = DownloadProgress(
        receivedBytes: 134_200_000, totalBytes: 388_300_496, bytesPerSecond: 5_400_000,
        resumedFromBytes: 18_600_000)
    static var done: DownloadProgress {
        var done = progress
        done.receivedBytes = done.totalBytes
        return done
    }

    @Test(arguments: [
        (80, "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left"),
        (60, "Downloading 134.2 MB of 388.3 MB, 47 s left"),
        (40, "Downloading 34%, 47 s left"),
    ])
    func fitsTheDownloadsLine(columns: Int, expected: String) {
        let line = text.downloadingLine(
            Self.progress, columns: InstallProgressView.usable(columns))
        #expect(line == expected)
        #expect(line.count < columns)
    }

    @Test(arguments: [
        (80, "Downloading Ubuntu 24.04 LTS     388.3 MB in 1 min 9 s, resumed at 18.6 MB"),
        (60, "Downloading 388.3 MB in 1 min 9 s, resumed at 18.6 MB"),
        (40, "Downloading 388.3 MB in 1 min 9 s"),
    ])
    func fitsTheDownloadsLastLine(columns: Int, expected: String) {
        let line = text.downloadedLine(
            Self.done, milliseconds: 69_000, columns: InstallProgressView.usable(columns))
        #expect(line == expected)
        #expect(line.count < columns)
    }

    @Test func keepsTheWholeLineWhenItFits() {
        var fresh = Self.progress
        fresh.resumedFromBytes = 0
        #expect(
            text.downloadingLine(fresh, columns: 120)
                == "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left")
        #expect(
            text.downloadingLine(Self.progress, columns: nil)
                == text.padded(.download) + InstallProgressText.downloading(Self.progress))
    }

    @Test func showsNoRateOrTimeLeftBeforeTheRateIsKnown() {
        var first = Self.progress
        first.bytesPerSecond = 0
        #expect(
            text.downloadingLine(first, columns: 79)
                == "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB (resumed at 18.6 MB)")
    }

    @Test func truncatesAsALastResort() {
        #expect(text.downloadingLine(Self.progress, columns: 9) == "Downloadi")
        #expect(text.downloadingLine(nil, columns: 20) == "Downloading")
    }
}

/// What the progress view writes to a terminal and elsewhere.
@Suite struct InstallProgressViewTests {
    let text = InstallProgressText(
        name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS")
    let columns = OSAllocatedUnfairLock(initialState: 80)
    let written = OSAllocatedUnfairLock(initialState: [String]())

    func view(isTerminal: Bool) -> InstallProgressView {
        let columns = self.columns
        let written = self.written
        return InstallProgressView(
            text: text, isTerminal: isTerminal, columns: { columns.withLock { $0 } },
            output: { string in written.withLock { $0.append(string) } })
    }

    func takeWritten() -> [String] {
        written.withLock { output in
            defer { output = [] }
            return output
        }
    }

    @Test func redrawsTheLineInPlaceAfterTheWindowNarrows() {
        let view = view(isTerminal: true)
        view.show(.started(.download))
        view.show(.download(InstallProgressWidthTests.progress))
        #expect(
            takeWritten() == [
                "\r\u{1B}[JDownloading Ubuntu 24.04 LTS     ",
                "\r\u{1B}[JDownloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, "
                    + "47 s left",
            ])

        // At 40 columns, the terminal wraps the 74 characters drawn onto two rows: the redraw
        // moves up one row before it erases.
        columns.withLock { $0 = 40 }
        view.resized()
        #expect(takeWritten() == ["\r\u{1B}[1A\u{1B}[JDownloading 34%, 47 s left"])

        columns.withLock { $0 = 60 }
        view.show(.download(InstallProgressWidthTests.progress))
        #expect(takeWritten() == ["\r\u{1B}[JDownloading 134.2 MB of 388.3 MB, 47 s left"])

        view.show(.download(InstallProgressWidthTests.done))
        view.show(.finished(.download, milliseconds: 69_000))
        #expect(
            takeWritten().suffix(2) == [
                "\r\u{1B}[JDownloading 388.3 MB in 1 min 9 s, resumed at 18.6 MB", "\n",
            ])
        // Nothing is redrawn once the step has finished.
        view.resized()
        #expect(takeWritten().isEmpty)
    }

    @Test func writesOnlyEachStepsLastLineElsewhere() {
        let view = view(isTerminal: false)
        view.show(.started(.download))
        view.show(.download(InstallProgressWidthTests.progress))
        view.resized()
        view.show(.download(InstallProgressWidthTests.done))
        view.show(.finished(.download, milliseconds: 69_000))
        view.show(.started(.verify))
        view.show(.finished(.verify, milliseconds: 300))
        #expect(
            takeWritten().joined()
                == "Downloading Ubuntu 24.04 LTS     388.3 MB in 1 min 9 s (5.4 MB/s), "
                + "resumed at 18.6 MB\nVerifying the image              0.3 s\n")
    }
}
