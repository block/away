import AVFoundation
import CoreLocation
import Foundation

@MainActor
final class DemoBackgroundKeepaliveService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startLocationKeepalive()
        startSilentAudioKeepalive()
        ContinuedProcessingDemoService.shared.submitListeningRequest()
    }

    func stop() {
        isRunning = false
        ContinuedProcessingDemoService.shared.cancelListeningRequest()
        locationManager.stopUpdatingLocation()
        audioEngine.stop()
        if let sourceNode {
            audioEngine.detach(sourceNode)
        }
        sourceNode = nil
    }

    private func startLocationKeepalive() {
        locationManager.requestAlwaysAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.startUpdatingLocation()
    }

    private func startSilentAudioKeepalive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    memset(data, 0, Int(frameCount) * MemoryLayout<Float>.size)
                }
                return noErr
            }
            self.sourceNode = sourceNode
            audioEngine.attach(sourceNode)
            audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
            try audioEngine.start()
        } catch {
            // Demo-only keepalive; failing to start audio should not affect ACP.
        }
    }
}
