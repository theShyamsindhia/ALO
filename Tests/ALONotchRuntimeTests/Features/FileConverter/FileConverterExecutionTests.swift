import AppKit
import ImageIO
import XCTest
@testable import ALONotchRuntime

/// Exercises the imported encoders against isolated files, not just format lists.
@MainActor
final class FileConverterExecutionTests: XCTestCase {
    func testPNGConvertsToReadableJPEGWithoutChangingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for y in 0..<6 {
            for x in 0..<8 { bitmap.setColor(.systemBlue, atX: x, y: y) }
        }
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try original.write(to: source)
        var options = FileConverterConversionOptions()
        options.outputLocation = .sameFolder
        options.existingFileBehavior = .createUniqueName
        options.filenameSuffix = "-converted"

        let output = try await FileConverterService.shared.convert(
            item: FileConverterItem(url: source, mediaKind: .image, isDirectory: false),
            to: .jpeg, options: options
        )

        XCTAssertEqual(output.deletingLastPathComponent(), directory)
        XCTAssertNotEqual(output, source)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 6)
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "public.jpeg")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSingleFileGzipRoundTripsItsOriginalContents() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.txt")
        let original = Data("Notch converter fixture\nUnicode: café\n".utf8)
        try original.write(to: source)
        var options = FileConverterConversionOptions()
        options.outputLocation = .sameFolder
        options.filenameSuffix = "-compressed"

        let output = try await FileConverterService.shared.convert(
            item: FileConverterItem(url: source, mediaKind: .generic, isDirectory: false),
            to: .gzip, options: options
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let decoded = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALONotchConverter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
