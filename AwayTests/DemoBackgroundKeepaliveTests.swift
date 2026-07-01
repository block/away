import AVFoundation
import XCTest
@testable import Away

final class DemoBackgroundKeepaliveTests: XCTestCase {
    func testContinuedProcessingTaskIdentifierUsesPermittedWildcardPrefix() {
        XCTAssertEqual(
            ContinuedProcessingTaskIdentifiers.task,
            "xyz.block.away.continued-processing.listening"
        )
        XCTAssertTrue(
            ContinuedProcessingTaskIdentifiers.task.hasPrefix("xyz.block.away.continued-processing.")
        )
        XCTAssertNotEqual(
            ContinuedProcessingTaskIdentifiers.task,
            ContinuedProcessingTaskIdentifiers.permittedWildcard
        )
    }

    func testInfoPlistPermitsContinuedProcessingWildcardIdentifier() throws {
        let identifiers = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )

        XCTAssertTrue(identifiers.contains(ContinuedProcessingTaskIdentifiers.permittedWildcard))
    }

    func testSilentAudioRendererZerosProvidedBuffers() {
        var samples = [Float](repeating: 1, count: 8)

        samples.withUnsafeMutableBytes { rawBuffer in
            let audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(rawBuffer.count),
                mData: rawBuffer.baseAddress
            )
            var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

            let status = withUnsafeMutablePointer(to: &audioBufferList) {
                SilentAudioRenderer.renderSilence($0)
            }

            XCTAssertEqual(status, noErr)
        }

        XCTAssertEqual(samples, [Float](repeating: 0, count: 8))
    }
}
