import XCTest
@testable import GitManagerCore

final class RemotePathCompletionTests: XCTestCase {
    func testQuerySplitsAtLastSlash() {
        XCTAssertEqual(RemotePathCompletion.query(for: "~/co")?.directory, "~/")
        XCTAssertEqual(RemotePathCompletion.query(for: "~/co")?.prefix, "co")
        XCTAssertEqual(RemotePathCompletion.query(for: "/srv/git/")?.directory, "/srv/git/")
        XCTAssertEqual(RemotePathCompletion.query(for: "/srv/git/")?.prefix, "")
        XCTAssertEqual(RemotePathCompletion.query(for: "/")?.directory, "/")
        for path in ["", "~", "relative/dir", "~other/x", "/a\nb/", "/a\rb", "/a\0b"] {
            XCTAssertNil(RemotePathCompletion.query(for: path), path)
        }
    }
    func testParseKeepsCompleteFolderNamesSorted() {
        let output = "./b\0./A dir's\0./.hidden\0./item10\0./item9\0\0./bad\nname\0nodot\0./\0"
        XCTAssertEqual(RemotePathCompletion.parse(output), [".hidden", "A dir's", "b", "item9", "item10"])
    }
    func testMatchesIgnoreCaseAndHideDotFoldersUntilTyped() {
        let names = [".config", "Code", "code-old", "docs"]
        XCTAssertEqual(RemotePathCompletion.matches(names, prefix: ""), ["Code", "code-old", "docs"])
        XCTAssertEqual(RemotePathCompletion.matches(names, prefix: "co"), ["Code", "code-old"])
        XCTAssertEqual(RemotePathCompletion.matches(names, prefix: "."), [".config"])
        XCTAssertEqual(RemotePathCompletion.matches(names, prefix: "x"), [])
    }
    func testCompletingAppendsFolderAndSlash() throws {
        let query = try XCTUnwrap(RemotePathCompletion.query(for: "~/co"))
        XCTAssertEqual(RemotePathCompletion.completing(query, with: "code"), "~/code/")
    }
    func testListingCommandIsQuotedAndUsesRepositorySSHOptions() throws {
        let command = try RemoteDirectoryLister().command(host: "sam@host", port: 2222, directory: "~/my dir's $(touch bad)/")
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(command.arguments.dropLast()), [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/gitmanager-ssh-%C",
            "-o", "ControlPersist=300", "-p", "2222", "--", "sam@host"
        ])
        XCTAssertEqual(command.arguments.last,
            "cd ~/'my dir'\\''s $(touch bad)' && 'find' '-L' '.' '-mindepth' '1' '-maxdepth' '1' '-type' 'd' '-print0'")
        let root = try RemoteDirectoryLister().command(host: "host", port: nil, directory: "/")
        XCTAssertEqual(root.arguments.last?.hasPrefix("cd '/' && 'find' "), true)
        XCTAssertFalse(root.arguments.contains("-p"))
    }
    func testListingRejectsInvalidHostsAndPaths() async {
        XCTAssertThrowsError(try RemoteDirectoryLister().command(host: "-oProxyCommand=bad", port: nil, directory: "/"))
        XCTAssertThrowsError(try RemoteDirectoryLister().command(host: "", port: nil, directory: "/"))
        XCTAssertThrowsError(try RemoteDirectoryLister().command(host: "host", port: 0, directory: "/"))
        XCTAssertThrowsError(try RemoteDirectoryLister().command(host: "host", port: nil, directory: "relative/"))
        let folders = await RemoteDirectoryLister().folders(host: "-oProxyCommand=bad", port: nil, directory: "/")
        XCTAssertNil(folders)
    }
}
