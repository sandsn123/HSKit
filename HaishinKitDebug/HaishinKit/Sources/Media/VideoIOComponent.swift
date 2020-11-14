import CoreImage
import Foundation
import AVFoundation

final class VideoIOComponent: IOComponent {
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoIOComponent.lock")
    var context: CIContext?
    // var yuvContext: CIContext = CIContext(options: [kCIContextUseSoftwareRenderer: NSNumber(value: false)])
    var toSkipCount = 0
    var blendTime: Double = 0
    var drawable: NetStreamDrawable?
    var formatDescription: CMVideoFormatDescription? {
        didSet {
            decoder.formatDescription = formatDescription
        }
    }
    lazy var encoder: H264Encoder = H264Encoder()
    lazy var decoder: H264Decoder = H264Decoder()
    lazy var queue: DisplayLinkedQueue = {
        let queue: DisplayLinkedQueue = DisplayLinkedQueue()
        queue.delegate = self
        return queue
    }()

    var effects: [VisualEffect] = []

#if os(iOS) || os(macOS)
    var fps: Float64 = AVMixer.defaultFPS {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let data = device.actualFPS(fps) else {
                return
            }

            fps = data.fps
            encoder.expectedFPS = data.fps
            logger.info("\(data)")

            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = data.duration
                device.activeVideoMaxFrameDuration = data.duration
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for fps: \(error)")
            }
        }
    }

    var position: AVCaptureDevice.Position = .back

    var videoSettings: [NSObject: AnyObject] = AVMixer.defaultVideoSettings {
        didSet {
            output.videoSettings = videoSettings as! [String: Any]
        }
    }

    var orientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard orientation != oldValue else {
                return
            }
            for connection in output.connections where connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
                if torch {
                    setTorchMode(.on)
                }
            }
            drawable?.orientation = orientation
        }
    }

    var torch: Bool = false {
        didSet {
            guard torch != oldValue else {
                return
            }
            setTorchMode(torch ? .on : .off)
        }
    }

    var continuousAutofocus: Bool = false {
        didSet {
            guard continuousAutofocus != oldValue else {
                return
            }
            let focusMode: AVCaptureDevice.FocusMode = continuousAutofocus ? .continuousAutoFocus : .autoFocus
            guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                device.isFocusModeSupported(focusMode) else {
                logger.warn("focusMode(\(focusMode.rawValue)) is not supported")
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusMode = focusMode
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for autofocus: \(error)")
            }
        }
    }

    var focusPointOfInterest: CGPoint? {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let point: CGPoint = focusPointOfInterest,
                device.isFocusPointOfInterestSupported else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for focusPointOfInterest: \(error)")
            }
        }
    }

    var exposurePointOfInterest: CGPoint? {
        didSet {
            guard
                let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                let point: CGPoint = exposurePointOfInterest,
                device.isExposurePointOfInterestSupported else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for exposurePointOfInterest: \(error)")
            }
        }
    }

    var continuousExposure: Bool = false {
        didSet {
            guard continuousExposure != oldValue else {
                return
            }
            let exposureMode: AVCaptureDevice.ExposureMode = continuousExposure ? .continuousAutoExposure : .autoExpose
            guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device,
                device.isExposureModeSupported(exposureMode) else {
                logger.warn("exposureMode(\(exposureMode.rawValue)) is not supported")
                return
            }
            do {
                try device.lockForConfiguration()
                device.exposureMode = exposureMode
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for autoexpose: \(error)")
            }
        }
    }

    private var _output: AVCaptureVideoDataOutput?
    var output: AVCaptureVideoDataOutput! {
        get {
            if _output == nil {
                _output = AVCaptureVideoDataOutput()
                _output!.alwaysDiscardsLateVideoFrames = true
                _output!.videoSettings = videoSettings as! [String: Any]
            }
            return _output!
        }
        set {
            if _output == newValue {
                return
            }
            if let output: AVCaptureVideoDataOutput = _output {
                output.setSampleBufferDelegate(nil, queue: nil)
                mixer?.session.removeOutput(output)
            }
            _output = newValue
        }
    }

    var input: AVCaptureInput? = nil {
        didSet {
            guard let mixer: AVMixer = mixer, oldValue != input else {
                return
            }
            if let oldValue: AVCaptureInput = oldValue {
                mixer.session.removeInput(oldValue)
            }
            if let input: AVCaptureInput = input, mixer.session.canAddInput(input) {
                mixer.session.addInput(input)
            }
        }
    }
#endif

    #if os(iOS)
    var screen: ScreenCaptureSession? = nil {
        didSet {
            guard oldValue != screen else {
                return
            }
            if let oldValue: ScreenCaptureSession = oldValue {
                oldValue.delegate = nil
            }
            if let screen: ScreenCaptureSession = screen {
                screen.delegate = self
            }
        }
    }
    #endif

    override init(mixer: AVMixer) {
        super.init(mixer: mixer)
        encoder.lockQueue = lockQueue
        decoder.delegate = self
        #if os(iOS)
            if let orientation: AVCaptureVideoOrientation = DeviceUtil.videoOrientation(by: UIDevice.current.orientation) {
                self.orientation = orientation
                }
        #endif
    }

#if os(iOS) || os(macOS)
    func attachCamera(_ camera: AVCaptureDevice?) throws {
        guard let mixer: AVMixer = mixer else {
            return
        }

        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
            if torch {
                setTorchMode(.on)
            }
        }

        output = nil
        guard let camera: AVCaptureDevice = camera else {
            input = nil
            return
        }
        #if os(iOS)
        screen = nil
        #endif

        input = try AVCaptureDeviceInput(device: camera)
        mixer.session.addOutput(output)
        for connection in output.connections where connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
        output.setSampleBufferDelegate(self, queue: lockQueue)

        fps *= 1
        position = camera.position
        drawable?.position = camera.position
    }

    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard let device: AVCaptureDevice = (input as? AVCaptureDeviceInput)?.device, device.isTorchModeSupported(torchMode) else {
            logger.warn("torchMode(\(torchMode)) is not supported")
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchMode
            device.unlockForConfiguration()
        } catch let error as NSError {
            logger.error("while setting torch: \(error)")
        }
    }
    func dispose() {
        if Thread.isMainThread {
            self.drawable?.attachStream(nil)
        } else {
          DispatchQueue.main.sync {
              self.drawable?.attachStream(nil)
          }
        }

        input = nil
        output = nil
    }
#else
    func dispose() {
        if Thread.isMainThread {
            self.drawable?.attachStream(nil)
        } else {
          DispatchQueue.main.sync {
              self.drawable?.attachStream(nil)
          }
        }
    }
#endif

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        // CVPixelBufferLockBaseAddress(buffer, .readOnly)
        // defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        if !effects.isEmpty {
            // #if os(macOS)
                // green edge hack for OSX
                // buffer = CVPixelBuffer.create(image)!
            // #endif

            let image: CIImage = effect(buffer)

            // drawable?.draw(image: image)
            // if toSkipCount > 0 {
            //     toSkipCount -= 1
            //     drawable?.draw(image: image)
            //     return
            // }

            // let t = Date().timeIntervalSince1970
            context?.render(image, to: buffer)
            // yuvContext.render(image, to: buffer)
            // let d = Date().timeIntervalSince1970 - t
            // blendTime = (blendTime * 3 + d) / 4
            drawable?.draw(image: CIImage(cvPixelBuffer: buffer))
            // if d > 0.1 {
            //     print("BlendTime: \(d): \(blendTime)")
            //     toSkipCount = Int(d / 0.033)
            //     if toSkipCount < 30 {
            //         toSkipCount = 30
            //     }
            //     print("skip1 \(toSkipCount)")
            //     blendTime = 0.02
            //     return
            // } else if blendTime > 0.033 {
            //     print("BlendTime: \(d): \(blendTime)")
            //     toSkipCount = Int(blendTime / 0.033)
            //     print("skip3 \(toSkipCount)")
            //     blendTime = 0.02
            //     return
            // }

            encoder.encodeImageBuffer(
                buffer,
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                duration: sampleBuffer.duration
            )
            mixer?.recorder.appendSampleBuffer(sampleBuffer, mediaType: .video)
        } else {
            drawable?.draw(image: CIImage(cvPixelBuffer: buffer))

            encoder.encodeImageBuffer(
                buffer,
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                duration: sampleBuffer.duration
            )

            mixer?.recorder.appendSampleBuffer(sampleBuffer, mediaType: .video)
        }
    }

    func appendSampleBufferWithoutDraw(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        encoder.encodeImageBuffer(
            buffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration
        )

        mixer?.recorder.appendSampleBuffer(sampleBuffer, mediaType: .video)
    }

    func drawImage(_ image: CIImage) {
        drawable?.draw(image: image)
    }

    func createPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        let format = kCVPixelFormatType_32BGRA;
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &newPixelBuffer)

        return newPixelBuffer!
    }

    func createSampleBuffer(_ sampleBuffer: CMSampleBuffer, _ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let imageBuffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMTime.invalid
        )

        var videoFormatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &videoFormatDescription
        )

        var newSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoFormatDescription!,
            sampleTiming: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )

        return newSampleBuffer
    }

    func effect(_ buffer: CVImageBuffer) -> CIImage {
        var image: CIImage = CIImage(cvPixelBuffer: buffer)
        for effect in effects {
            image = effect.execute(image)
        }
        return image
    }

    func registerEffect(_ effect: VisualEffect, index: Int) -> Bool {
        objc_sync_enter(effects)
        defer {
            objc_sync_exit(effects)
        }
        if effects.contains(effect) {
            return false
        }
        if index < 0 {
            effects.append(effect)
        } else {
            effects.insert(effect, at: index)
        }
        return true
    }

    func registerEffect(_ effect: VisualEffect) -> Bool {
        return registerEffect(effect, index: -1)
    }

    func unregisterEffect(_ effect: VisualEffect) -> Bool {
        objc_sync_enter(effects)
        defer {
            objc_sync_exit(effects)
        }
        if let i: Int = effects.firstIndex(of: effect) {
            effects.remove(at: i)
            return true
        }
        return false
    }
}

extension VideoIOComponent: AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendSampleBuffer(sampleBuffer)
    }
}

extension VideoIOComponent: VideoDecoderDelegate {
    // MARK: VideoDecoderDelegate
    func sampleOutput(video sampleBuffer: CMSampleBuffer) {
        queue.enqueue(sampleBuffer)
    }
}

extension VideoIOComponent: DisplayLinkedQueueDelegate {
    // MARK: DisplayLinkedQueue
    func queue(_ buffer: CMSampleBuffer) {
        mixer?.audioIO.playback.startQueueIfNeed()
        drawable?.draw(image: CIImage(cvPixelBuffer: buffer.imageBuffer!))
    }
}
