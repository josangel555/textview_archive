import XCTest
@testable import ViewerCore

/// Teeth for the ffmpeg discovery (TSK-528): override-wins → PATH → common
/// locations → nil, with injected environment/candidate list so the order is
/// deterministic regardless of whether the host actually has ffmpeg.
final class FFmpegLocatorTests: XCTestCase {

    private var scratch: [URL] = []
    override func tearDownWithError() throws {
        for u in scratch { try? FileManager.default.removeItem(at: u) }
        scratch.removeAll()
    }

    /// Create a real executable (or plain) file under a fresh temp dir; return its path.
    private func makeFile(_ name: String, executable: Bool) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-ffloc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.path
    }

    func test_override_winsWhenExecutable() throws {
        let exe = try makeFile("myffmpeg", executable: true)
        let got = FFmpegLocator.resolve(override: exe,
                                        environment: ["PATH": "/nonexistent"],
                                        commonPaths: [])
        XCTAssertEqual(got?.path, exe)
    }

    func test_override_ignoredWhenNotExecutable_fallsThroughToPath() throws {
        let notExe = try makeFile("notffmpeg", executable: false)
        let onPath = try makeFile("ffmpeg", executable: true)
        let pathDir = (onPath as NSString).deletingLastPathComponent
        let got = FFmpegLocator.resolve(override: notExe,
                                        environment: ["PATH": pathDir],
                                        commonPaths: [])
        XCTAssertEqual(got?.path, onPath)
    }

    func test_pathSearch_findsFfmpegOnPath() throws {
        let onPath = try makeFile("ffmpeg", executable: true)
        let pathDir = (onPath as NSString).deletingLastPathComponent
        let got = FFmpegLocator.resolve(override: nil,
                                        environment: ["PATH": "/nope:\(pathDir)"],
                                        commonPaths: [])
        XCTAssertEqual(got?.path, onPath)
    }

    func test_commonPathsFallback_whenNotOnPath() throws {
        let common = try makeFile("ffmpeg", executable: true)
        let got = FFmpegLocator.resolve(override: nil,
                                        environment: ["PATH": "/nonexistent"],
                                        commonPaths: ["/also/nope", common])
        XCTAssertEqual(got?.path, common)
    }

    func test_notFound_returnsNil_disablesFeature() {
        let got = FFmpegLocator.resolve(override: nil,
                                        environment: ["PATH": "/nonexistent"],
                                        commonPaths: ["/definitely/not/here/ffmpeg"])
        XCTAssertNil(got)
    }

    func test_emptyOverride_isIgnored() throws {
        let onPath = try makeFile("ffmpeg", executable: true)
        let pathDir = (onPath as NSString).deletingLastPathComponent
        let got = FFmpegLocator.resolve(override: "",
                                        environment: ["PATH": pathDir],
                                        commonPaths: [])
        XCTAssertEqual(got?.path, onPath)
    }
}
