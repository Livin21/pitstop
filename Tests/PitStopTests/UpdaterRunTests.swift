import XCTest
@testable import PitStop

final class UpdaterRunTests: XCTestCase {
    func testRunDrainsLargeStderrWithoutDeadlock() {
        let exp = expectation(description: "run returns")
        DispatchQueue.global().async {
            // 256 KB to stderr fills the pipe; a sequential stdout-then-stderr
            // drain deadlocks (child blocks in write, parent in read).
            try? Updater.run("/bin/zsh", ["-c", "head -c 262144 /dev/zero | tr '\\0' e 1>&2"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }
}
