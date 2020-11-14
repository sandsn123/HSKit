//
//  ViewController.swift
//  HaishinKitDebug
//

import UIKit
import AVFoundation
import AudioToolbox
import VideoToolbox

class ViewController: UIViewController {
    let rtmpUrl = "rtmp://192.168.2.13/live"
    let streamName = "stream"

    var rtmpConnection: RTMPConnection!
    var rtmpStream: RTMPStream!
    var videoView: HKView!

    override func viewDidLoad() {
        super.viewDidLoad()

        setupAudioSession()

        videoView = HKView(frame: view.bounds)
        videoView.videoGravity = AVLayerVideoGravity.resizeAspectFill
        view.addSubview(videoView)

        goLive()
    }

    func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // https://stackoverflow.com/questions/51010390/avaudiosession-setcategory-swift-4-2-ios-12-play-sound-on-silent
            if #available(iOS 10.0, *) {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                session.perform(NSSelectorFromString("setCategory:withOptions:error:"), with: AVAudioSession.Category.playAndRecord, with: [
                    AVAudioSession.CategoryOptions.allowBluetooth,
                    AVAudioSession.CategoryOptions.defaultToSpeaker]
                )
                try session.setMode(.default)
            }
            try session.setActive(true)
        } catch {
            print(error)
        }
    }

    func goLive() {
        rtmpConnection = RTMPConnection()
        rtmpStream = RTMPStream(connection: rtmpConnection)

        rtmpStream.captureSettings = [
            "fps": 30, // FPS
            "sessionPreset": AVCaptureSession.Preset.hd1280x720.rawValue, // input video width/height
            "continuousAutofocus": false, // use camera autofocus mode
            "continuousExposure": false, //  use camera exposure mode
        ]
        rtmpStream.audioSettings = [
            "muted": false,
            "bitrate": 128 * 1024,
//            "sampleRate": 44100,
        ]
        rtmpStream.videoSettings = [
            "width": 1280, // video output width
            "height": 720, // video output height
            "bitrate": 1000 * 1024, // video output bitrate
//            "dataRateLimits": [1000 * 1024 / 8, 1],
            "profileLevel": kVTProfileLevel_H264_High_4_1,
            "maxKeyFrameIntervalDuration": 2,
        ]

        rtmpStream.attachAudio(AVCaptureDevice.default(for: AVMediaType.audio)) { error in
             print(error)
        }
        rtmpStream.attachCamera(DeviceUtil.device(withPosition: .front)) { error in
             print(error)
        }
        videoView.attachStream(rtmpStream)

        rtmpConnection.addEventListener(Event.RTMP_STATUS, selector: #selector(onRtmpStatus(_: )), observer: self)
        rtmpConnection.addEventListener(Event.IO_ERROR, selector: #selector(onRtmpIoError(_: )), observer: self)

        rtmpConnection.connect(rtmpUrl)
    }

    @objc func onRtmpIoError(_ notification: Notification) {
        let e: Event = Event.from(notification)
        print("RtmpIoError: \(e)")
    }

    @objc func onRtmpStatus(_ notification: Notification) {
        let e: Event = Event.from(notification)
        if let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String {
            guard let connectionCode = RTMPConnection.Code(rawValue: code) else {
                print("RtmpStatus: \(code)")
                return
            }
            print("RtmpStatus: \(connectionCode.rawValue)")

            DispatchQueue.main.async {
                if connectionCode == .connectSuccess {
                    self.rtmpStream.publish(self.streamName)
                }
            }
        }
    }

}

