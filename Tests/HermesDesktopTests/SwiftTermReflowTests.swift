import AppKit
import Testing
@testable import SwiftTerm

struct SwiftTermReflowTests {
    @Test
    func narrowerReflowPreservesWrappedOutputAndClearsStaleCells() {
        let harness = TerminalHarness(cols: 12, rows: 6)
        let line = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"

        harness.terminal.feed(text: line + "\r\n")
        harness.terminal.resize(cols: 8, rows: 8)

        let lines = logicalLines(in: harness.terminal)
        #expect(lines.filter { $0 == line }.count == 1)
        #expect(!lines.contains { $0.contains("IJIJ") || $0.contains("GHIJGHIJ") })
    }

    @Test
    func narrowerReflowPreservesCurrentCursorLine() {
        let harness = TerminalHarness(cols: 10, rows: 5)
        let line = "abcdefghijklmno"

        harness.terminal.feed(text: line)
        harness.terminal.resize(cols: 8, rows: 5)

        #expect(logicalLines(in: harness.terminal).first == line)
        #expect(harness.terminal.buffer.yBase + harness.terminal.buffer.y == 1)
        #expect(harness.terminal.buffer.x == 7)
    }

    @Test
    func widerReflowPreservesCurrentCursorLine() {
        let harness = TerminalHarness(cols: 8, rows: 5)
        let line = "abcdefghijklmno"

        harness.terminal.feed(text: line)
        harness.terminal.resize(cols: 20, rows: 5)

        #expect(logicalLines(in: harness.terminal).first == line)
        #expect(harness.terminal.buffer.yBase + harness.terminal.buffer.y == 0)
        #expect(harness.terminal.buffer.x == 15)
    }

    @Test
    func repeatedReflowPreservesScrollbackAndLiveCursorLine() {
        let harness = TerminalHarness(cols: 14, rows: 6)
        let completedLines = [
            "short",
            "first-long-output-line-with-stable-content",
            "second-output-line-that-wraps-more-than-once",
            "tail"
        ]
        let currentLine = "live-cursor-line"

        for line in completedLines {
            harness.terminal.feed(text: line + "\r\n")
        }
        harness.terminal.feed(text: currentLine)

        for cols in [9, 17, 6, 24, 11, 20] {
            harness.terminal.resize(cols: cols, rows: 7)
            let lines = logicalLines(in: harness.terminal)
            for line in completedLines {
                #expect(lines.contains(line))
            }
            #expect(lines.contains(currentLine))
        }

        #expect(harness.terminal.buffer.x == currentLine.count)
    }

    @MainActor
    @Test
    func terminalViewResizeKeepsViewportPinnedWhenAlreadyAtEnd() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))

        for index in 0..<30 {
            view.feed(text: "line-\(index)\r\n")
        }
        view.scrollToTerminalEnd(notifyAccessibility: false)

        view.setFrameSize(NSSize(width: 160, height: 120))

        let buffer = view.getTerminal().buffer
        #expect(buffer.yDisp == min(buffer.yBase, max(0, buffer.lines.count - buffer.rows)))
        #expect(view.isScrolledToTerminalEnd)
    }

    @MainActor
    @Test
    func terminalViewResizeDoesNotForceBottomWhenUserScrolledUp() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))

        for index in 0..<40 {
            view.feed(text: "line-\(index)\r\n")
        }
        view.scrollToTerminalEnd(notifyAccessibility: false)
        view.scrollUp(lines: 5)

        view.setFrameSize(NSSize(width: 160, height: 120))

        #expect(!view.isScrolledToTerminalEnd)
    }

    private func logicalLines(in terminal: Terminal) -> [String] {
        let buffer = terminal.buffer
        var result: [String] = []
        var current = ""

        for row in 0..<buffer.lines.count {
            let line = terminal.translateBufferLineToString(
                buffer: buffer,
                line: row,
                start: 0,
                end: buffer.cols
            )

            if buffer.lines[row].isWrapped {
                current += line
            } else {
                if !current.isEmpty {
                    result.append(current)
                }
                current = line
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}

private final class TerminalHarness {
    let delegate: RecordingTerminalDelegate
    let terminal: Terminal

    init(cols: Int, rows: Int) {
        let delegate = RecordingTerminalDelegate()
        self.delegate = delegate
        self.terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 200)
        )
    }
}

private final class RecordingTerminalDelegate: TerminalDelegate {
    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}
}
