@preconcurrency import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// iOS 17+ camera scanner core. Own this model at the feature root with
/// `@StateObject`, then pass it to `DocumentCameraPreview` and controls.
/// Queue ownership is explicit: session state stays on `sessionQueue`, live
/// Vision state on `visionQueue`, image state on `processingQueue`, published
/// UI state on the main queue, and the capture gate is protected by a lock.
public final class DocumentScannerModel: NSObject, ObservableObject, @unchecked Sendable {
    public let session = AVCaptureSession()

    @Published public private(set) var authorizationState: ScannerAuthorizationState
    @Published public private(set) var phase: ScannerPhase = .idle
    @Published public private(set) var liveDetection: LiveRectangleDetection?
    @Published public private(set) var lastResult: ScannerCaptureResult?
    @Published public private(set) var lastError: ScannerCoreError?
    @Published public private(set) var isSessionRunning = false
    @Published public private(set) var analysisDiagnostics = ScannerAnalysisDiagnostics()
    @Published public private(set) var cameraCapabilities =
        ScannerCameraCapabilities(availableLenses: [.standard])
    @Published public private(set) var activeCameraLens: ScannerCameraLens = .standard

    @Published public var captureMode: ScannerCaptureMode = .singlePage {
        didSet {
            guard oldValue != captureMode else { return }
            let mode = captureMode
            visionQueue.async { [weak self] in
                self?.liveDetectionMode = mode
                self?.stabilityTracker.reset()
            }
            DispatchQueue.main.async { [weak self] in
                self?.liveBookGutterRatio = nil
                self?.liveDetection = nil
            }
        }
    }
    @Published public var autoCaptureEnabled = true
    @Published public var captureTimer: ScannerCaptureTimer = .off
    @Published public var captureQuality: ScannerCaptureQuality = .silentVideoFrame
    @Published public private(set) var liveBookGutterRatio: CGFloat?

    /// Compatibility bridge for the existing SwiftUI reference implementation.
    /// UIKit should bind to `captureQuality` so the quality tradeoff is explicit.
    public var silentCapturePreferred: Bool {
        get { captureQuality == .silentVideoFrame }
        set {
            captureQuality = newValue ? .silentVideoFrame : .highQualityPhoto
        }
    }

    /// Nil uses automatic book-gutter estimation. Non-nil values are clamped to
    /// 0.25...0.75 and applied before the left/right pages are rendered.
    @Published public var manualGutterRatio: CGFloat? {
        didSet {
            guard let manualGutterRatio else { return }
            let clamped = BookPageSplitter.clampGutter(manualGutterRatio)
            if clamped != manualGutterRatio {
                self.manualGutterRatio = clamped
            }
        }
    }

    private let sessionQueue = DispatchQueue(label: "com.clearscan.capture.session")
    private let visionQueue = DispatchQueue(
        label: "com.clearscan.capture.vision",
        qos: .userInitiated
    )
    private let processingQueue = DispatchQueue(
        label: "com.clearscan.capture.processing",
        qos: .userInitiated
    )

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let liveRectangleDetector = VisionRectangleDetector()
    private let imageProcessor = DocumentImageProcessor()
    private let silentFrameContext = CIContext(options: [.cacheIntermediates: false])
    private let analysisLogger = Logger(
        subsystem: "org.clearscan.app",
        category: "RectangleAnalysis"
    )

    private var stabilityTracker = RectangleStabilityTracker()
    private var sessionIsConfigured = false
    /// Access only on `sessionQueue`.
    private var activeVideoInput: AVCaptureDeviceInput?
    /// Session-queue source of truth mirrored to `activeCameraLens` on main.
    private var activeCameraLensState: ScannerCameraLens = .standard
    private var requestedCameraLens: ScannerCameraLens = .standard
    /// Access only on `sessionQueue`.
    private var requestedVideoRotationAngle: CGFloat = 90
    /// Access only on `visionQueue`.
    private var liveFrameOrientation: ScannerFrameOrientation = .right
    /// Access only on `visionQueue`.
    private var liveDetectionMode: ScannerCaptureMode = .singlePage
    private var lastVisionTimestamp: TimeInterval = 0
    /// Access only on `visionQueue`.
    private var receivedFrameCount = 0
    private var analyzedFrameCount = 0
    private var candidateFrameCount = 0
    private var visionErrorCount = 0
    private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var autoCaptureArmed = true
    private var unstableFramesForRearm = 0
    private var correctedBookSpread: CIImage?
    private var lastBookQuadrilateral: DocumentQuadrilateral?
    private var lastBookCapturedAt: Date?

    private let latestFrameLock = NSLock()
    private var latestVideoFrame: LatestVideoFrame?

    private let captureLock = NSLock()
    private var captureInFlight = false
    private var activeCaptureID: UUID?

    public override init() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
        case .denied:
            authorizationState = .denied
        case .restricted:
            authorizationState = .restricted
        case .notDetermined:
            authorizationState = .notDetermined
        @unknown default:
            authorizationState = .restricted
        }
        super.init()
    }

    deinit {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning {
            session.stopRunning()
        }
    }

    public static func discoverAvailableCameraLenses() -> [ScannerCameraLens] {
        ScannerCameraCapabilities(
            availableLenses: Array(discoverBackCameraDevices().keys)
        ).availableLenses
    }

    /// Selects a physical rear camera. Unsupported requests safely resolve to
    /// the standard 1× camera. When the session is running, the input is swapped
    /// inside one AVCaptureSession configuration transaction.
    public func selectCameraLens(_ lens: ScannerCameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let devices = Self.discoverBackCameraDevices()
            let capabilities = ScannerCameraCapabilities(
                availableLenses: Array(devices.keys)
            )
            guard !self.isCaptureInFlight else {
                self.publishCameraState(
                    capabilities: capabilities,
                    activeLens: self.activeCameraLensState
                )
                return
            }
            self.requestedCameraLens = lens
            let resolvedLens = capabilities.resolvedLens(requested: lens)

            guard self.sessionIsConfigured else {
                self.activeCameraLensState = resolvedLens
                self.publishCameraState(
                    capabilities: capabilities,
                    activeLens: resolvedLens
                )
                return
            }
            self.publishCameraState(
                capabilities: capabilities,
                activeLens: self.activeCameraLensState
            )
            guard resolvedLens != self.activeCameraLensState else { return }
            guard let camera = devices[resolvedLens] ?? devices[.standard] else {
                self.publishCameraState(
                    capabilities: capabilities,
                    activeLens: .standard
                )
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: camera)
                self.configureCameraDevice(camera)
                self.session.beginConfiguration()
                let previousInput = self.activeVideoInput
                if let previousInput {
                    self.session.removeInput(previousInput)
                }

                guard self.session.canAddInput(newInput) else {
                    if let previousInput, self.session.canAddInput(previousInput) {
                        self.session.addInput(previousInput)
                    }
                    self.session.commitConfiguration()
                    self.publishCameraState(
                        capabilities: capabilities,
                        activeLens: self.activeCameraLensState
                    )
                    return
                }

                self.session.addInput(newInput)
                self.activeVideoInput = newInput
                self.activeCameraLensState = resolvedLens
                self.configurePhotoDimensions(for: camera)
                self.applyRawVideoOrientation()
                self.applyPhotoRotationAngle()
                self.session.commitConfiguration()
                self.clearLatestVideoFrame()
                self.visionQueue.async { [weak self] in
                    self?.stabilityTracker.reset()
                    self?.lastVisionTimestamp = 0
                }
                self.publishCameraState(
                    capabilities: capabilities,
                    activeLens: resolvedLens
                )
            } catch {
                self.analysisLogger.error(
                    "Camera lens switch failed: \(error.localizedDescription, privacy: .public)"
                )
                self.publishCameraState(
                    capabilities: capabilities,
                    activeLens: self.activeCameraLensState
                )
            }
        }
    }

    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            publishAuthorization(.authorized)
            configureAndStart()

        case .notDetermined:
            publishAuthorization(.notDetermined)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.publishAuthorization(.authorized)
                    self.configureAndStart()
                } else {
                    self.publishAuthorization(.denied)
                    self.publishFailure(.cameraPermissionDenied)
                }
            }

        case .denied:
            publishAuthorization(.denied)
            publishFailure(.cameraPermissionDenied)

        case .restricted:
            publishAuthorization(.restricted)
            publishFailure(.cameraPermissionDenied)

        @unknown default:
            publishAuthorization(.restricted)
            publishFailure(.cameraPermissionDenied)
        }
    }

    public func stop() {
        cancelActiveCapture()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.visionQueue.async { [weak self] in
                self?.stabilityTracker.reset()
                self?.lastVisionTimestamp = 0
                self?.clearLatestVideoFrame()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isSessionRunning = false
                self?.liveDetection = nil
                self?.autoCaptureArmed = true
                self?.unstableFramesForRearm = 0
                self?.phase = .idle
            }
        }
    }

    /// Keeps Vision, still photos, and the preview overlay in the same
    /// orientation when an iPhone or iPad rotates. Live video buffers remain
    /// sensor-native; their orientation is supplied explicitly to Vision.
    public func updateVideoRotationAngle(_ angle: CGFloat) {
        guard angle.isFinite else { return }
        let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let frameOrientation = ScannerFrameOrientation(
            videoRotationAngle: normalized
        )
        visionQueue.async { [weak self] in
            self?.liveFrameOrientation = frameOrientation
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedVideoRotationAngle = normalized
            self.applyPhotoRotationAngle()
        }
    }

    /// Manually requests a photo. Repeated taps and an overlapping automatic
    /// request collapse into one in-flight capture.
    public func capture() {
        let captureID = UUID()
        guard beginCaptureIfAvailable(id: captureID) else { return }
        autoCaptureArmed = false
        unstableFramesForRearm = 0

        // Automatic capture reaches this method only after Vision reports a
        // stable rectangle. A manual shutter press must remain useful under
        // low contrast, glare, or a borderless page, so full-resolution still
        // processing gets an inset frame as its final fallback.
        let fallbackQuadrilateral =
            liveDetection?.quadrilateral ?? DocumentQuadrilateral.insetFrame()
        let timer = captureTimer

        let request = CaptureRequest(
            id: captureID,
            mode: captureMode,
            manualGutterRatio: manualGutterRatio.map(BookPageSplitter.clampGutter),
            fallbackQuadrilateral: fallbackQuadrilateral,
            quality: captureQuality
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCaptureActive(id: request.id) else { return }
            self.lastError = nil
            self.lastResult = nil
            self.phase = timer == .off
                ? .capturing
                : .countdown(remainingSeconds: timer.rawValue)
        }
        scheduleCapture(request: request, timer: timer)
    }

    /// Applies a new manual gutter ratio to the most recently corrected book
    /// spread without taking another photo or repeating perspective correction.
    public func resplitLastBook(at ratio: CGFloat) {
        guard !isCaptureInFlight else { return }
        let clampedRatio = BookPageSplitter.clampGutter(ratio)
        manualGutterRatio = clampedRatio
        DispatchQueue.main.async { [weak self] in
            self?.phase = .processing
            self?.lastError = nil
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            guard let spread = self.correctedBookSpread,
                  let quadrilateral = self.lastBookQuadrilateral,
                  let capturedAt = self.lastBookCapturedAt
            else {
                self.publishFailure(.bookSpreadUnavailable)
                return
            }

            do {
                let result = try self.imageProcessor.resplitBook(
                    correctedSpread: spread,
                    documentQuadrilateral: quadrilateral,
                    manualGutterRatio: clampedRatio,
                    capturedAt: capturedAt
                )
                DispatchQueue.main.async { [weak self] in
                    self?.lastResult = result
                    self?.phase = .completed
                }
            } catch let error as ScannerCoreError {
                self.publishFailure(error)
            } catch {
                self.publishFailure(.renderingFailed)
            }
        }
    }

    /// Clears the review result and allows a new document to become eligible
    /// for automatic capture after it moves or leaves the frame.
    public func prepareForNextCapture() {
        lastResult = nil
        lastError = nil
        autoCaptureArmed = false
        unstableFramesForRearm = 0
        if let liveDetection {
            phase = .stabilizing(progress: liveDetection.stabilityProgress)
        } else {
            phase = .searching
        }
    }

    private func configureAndStart() {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .configuring
            self?.lastError = nil
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.sessionIsConfigured {
                    try self.configureSession()
                    self.sessionIsConfigured = true
                }
                guard !self.session.isRunning else { return }
                self.session.startRunning()
                DispatchQueue.main.async { [weak self] in
                    self?.isSessionRunning = true
                    self?.phase = .searching
                }
            } catch let error as ScannerCoreError {
                self.publishFailure(error)
            } catch {
                self.publishFailure(.sessionConfigurationFailed)
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        do {
            session.sessionPreset = .photo

            let devices = Self.discoverBackCameraDevices()
            let capabilities = ScannerCameraCapabilities(
                availableLenses: Array(devices.keys)
            )
            let resolvedLens = capabilities.resolvedLens(
                requested: requestedCameraLens
            )
            guard let camera = devices[resolvedLens] ?? devices[.standard] else {
                throw ScannerCoreError.cameraUnavailable
            }
            configureCameraDevice(camera)

            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw ScannerCoreError.sessionConfigurationFailed
            }
            session.addInput(input)
            activeVideoInput = input
            activeCameraLensState = resolvedLens

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            guard session.canAddOutput(videoOutput) else {
                throw ScannerCoreError.sessionConfigurationFailed
            }
            session.addOutput(videoOutput)

            guard session.canAddOutput(photoOutput) else {
                throw ScannerCoreError.sessionConfigurationFailed
            }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            configurePhotoDimensions(for: camera)

            // Keep AVCaptureVideoDataOutput sensor-native. CVPixelBuffer has no
            // orientation metadata; captureOutput supplies the current explicit
            // CGImagePropertyOrientation to Vision and the preview maps the
            // oriented result back to capture-device coordinates.
            applyRawVideoOrientation()
            applyPhotoRotationAngle()
            session.commitConfiguration()
            publishCameraState(
                capabilities: capabilities,
                activeLens: resolvedLens
            )
        } catch {
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            activeVideoInput = nil
            activeCameraLensState = .standard
            session.commitConfiguration()
            throw error
        }
    }

    private static func discoverBackCameraDevices() -> [ScannerCameraLens: AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: .video,
            position: .back
        )
        var devices: [ScannerCameraLens: AVCaptureDevice] = [:]
        for device in discovery.devices {
            switch device.deviceType {
            case .builtInUltraWideCamera:
                devices[.ultraWide] = device
            case .builtInWideAngleCamera:
                devices[.standard] = device
            default:
                continue
            }
        }
        if devices[.standard] == nil,
           let standard = AVCaptureDevice.default(
               .builtInWideAngleCamera,
               for: .video,
               position: .back
           )
        {
            devices[.standard] = standard
        }
        return devices
    }

    /// Updates the dimensions used by high-quality still capture after a lens
    /// change. The silent path continues to use the video stream dimensions.
    private func configurePhotoDimensions(for camera: AVCaptureDevice) {
        guard let largestPhotoDimensions =
            camera.activeFormat.supportedMaxPhotoDimensions.max(
                by: { lhs, rhs in
                    Int64(lhs.width) * Int64(lhs.height)
                        < Int64(rhs.width) * Int64(rhs.height)
                }
            )
        else { return }
        photoOutput.maxPhotoDimensions = largestPhotoDimensions
    }

    private func applyRawVideoOrientation() {
        guard let videoConnection = videoOutput.connection(with: .video),
              videoConnection.isVideoRotationAngleSupported(0)
        else { return }
        videoConnection.videoRotationAngle = 0
    }

    private func applyPhotoRotationAngle() {
        guard let connection = photoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(requestedVideoRotationAngle)
        else { return }
        connection.videoRotationAngle = requestedVideoRotationAngle
    }

    private func configureCameraDevice(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            #if os(iOS)
            camera.isSubjectAreaChangeMonitoringEnabled = true
            #endif
        } catch {
            // Session setup can continue with the camera's current modes.
        }
    }

    private func scheduleCapture(
        request: CaptureRequest,
        timer: ScannerCaptureTimer
    ) {
        let countdown = timer.countdownValues
        for (index, remaining) in countdown.enumerated() where index > 0 {
            sessionQueue.asyncAfter(deadline: .now() + .seconds(index)) { [weak self] in
                guard let self, self.isCaptureActive(id: request.id) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCaptureActive(id: request.id) else { return }
                    self.phase = .countdown(remainingSeconds: remaining)
                }
            }
        }

        sessionQueue.asyncAfter(deadline: .now() + .seconds(timer.rawValue)) { [weak self] in
            guard let self, self.isCaptureActive(id: request.id) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCaptureActive(id: request.id) else { return }
                self.phase = .capturing
            }
            self.performCapture(request: request)
        }
    }

    private func performCapture(request: CaptureRequest) {
        guard isCaptureActive(id: request.id) else { return }
        guard session.isRunning else {
            if finishCapture(id: request.id) {
                publishFailure(.captureFailed("카메라 세션이 실행 중이 아닙니다."))
            }
            return
        }

        if request.quality == .silentVideoFrame {
            captureSilentVideoFrame(request: request)
        } else {
            captureHighQualityPhoto(request: request)
        }
    }

    /// Silent mode intentionally never reaches AVCapturePhotoOutput. The pixel
    /// buffer stored by the video delegate is an owned copy, so it remains valid
    /// after the camera reuses its original sample-buffer pool allocation.
    private func captureSilentVideoFrame(request: CaptureRequest) {
        guard let frame = latestVideoFrameSnapshot(),
              ProcessInfo.processInfo.systemUptime - frame.receivedAtUptime <= 0.75
        else {
            if finishCapture(id: request.id) {
                publishFailure(.captureFailed("사용할 수 있는 최신 카메라 프레임이 없습니다."))
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCaptureActive(id: request.id) else { return }
            self.phase = .processing
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCaptureActive(id: request.id) else { return }
            autoreleasepool {
                do {
                    let jpegData = try self.makeJPEGData(
                        from: frame.pixelBuffer,
                        orientation: frame.orientation
                    )
                    self.processPhoto(jpegData, request: request)
                } catch let error as ScannerCoreError {
                    if self.finishCapture(id: request.id) {
                        self.publishFailure(error)
                    }
                } catch {
                    if self.finishCapture(id: request.id) {
                        self.publishFailure(.captureFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Maximum-quality mode uses AVCapturePhotoOutput. iOS controls the system
    /// shutter sound for this path; ClearScan makes no guarantee that it is mute.
    private func captureHighQualityPhoto(request: CaptureRequest) {

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
            ])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off

        let captureID = settings.uniqueID
        let processor = PhotoCaptureProcessor { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async {
                self.photoProcessors[captureID] = nil
            }

            switch result {
            case let .failure(error):
                if self.finishCapture(id: request.id) {
                    self.publishFailure(.captureFailed(error.localizedDescription))
                }

            case let .success(data):
                guard self.isCaptureActive(id: request.id) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCaptureActive(id: request.id) else { return }
                    self.phase = .processing
                }
                self.processingQueue.async { [weak self] in
                    self?.processPhoto(data, request: request)
                }
            }
        }
        photoProcessors[captureID] = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func makeJPEGData(
        from pixelBuffer: CVPixelBuffer,
        orientation: ScannerFrameOrientation
    ) throws -> Data {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(orientation.imagePropertyOrientation)
            .translatedToOrigin()
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let renderedImage = silentFrameContext.createCGImage(image, from: extent)
        else {
            throw ScannerCoreError.renderingFailed
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScannerCoreError.renderingFailed
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.96,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, renderedImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ScannerCoreError.renderingFailed
        }
        return mutableData as Data
    }

    private func storeLatestVideoFrameCopy(
        from source: CVPixelBuffer,
        receivedAtUptime: TimeInterval,
        orientation: ScannerFrameOrientation
    ) {
        guard let copiedBuffer = copyPixelBuffer(source) else { return }
        let frame = LatestVideoFrame(
            pixelBuffer: copiedBuffer,
            receivedAtUptime: receivedAtUptime,
            orientation: orientation
        )
        latestFrameLock.lock()
        latestVideoFrame = frame
        latestFrameLock.unlock()
    }

    private func latestVideoFrameSnapshot() -> LatestVideoFrame? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return latestVideoFrame
    }

    private func clearLatestVideoFrame() {
        latestFrameLock.lock()
        latestVideoFrame = nil
        latestFrameLock.unlock()
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &destination
        ) == kCVReturnSuccess,
              let destination
        else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount > 0 {
            guard planeCount == CVPixelBufferGetPlaneCount(destination) else { return nil }
            for plane in 0 ..< planeCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                else {
                    return nil
                }
                copyRows(
                    sourceBase: sourceBase,
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    destinationBase: destinationBase,
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    rowCount: min(
                        CVPixelBufferGetHeightOfPlane(source, plane),
                        CVPixelBufferGetHeightOfPlane(destination, plane)
                    )
                )
            }
        } else {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination)
            else {
                return nil
            }
            copyRows(
                sourceBase: sourceBase,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                destinationBase: destinationBase,
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                rowCount: min(
                    CVPixelBufferGetHeight(source),
                    CVPixelBufferGetHeight(destination)
                )
            )
        }

        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func copyRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        rowCount: Int
    ) {
        let byteCount = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0 ..< rowCount {
            let sourceRow = sourceBase.advanced(by: row * sourceBytesPerRow)
            let destinationRow = destinationBase.advanced(by: row * destinationBytesPerRow)
            destinationRow.copyMemory(from: sourceRow, byteCount: byteCount)
        }
    }

    private func processPhoto(_ data: Data, request: CaptureRequest) {
        guard isCaptureActive(id: request.id) else { return }
        do {
            let processed = try imageProcessor.process(
                photoData: data,
                fallbackQuadrilateral: request.fallbackQuadrilateral,
                mode: request.mode,
                manualGutterRatio: request.manualGutterRatio
            )

            // If stop() invalidated this request while Vision/Core Image was
            // working, discard the result and leave UI state untouched.
            guard finishCapture(id: request.id) else { return }

            if request.mode == .bookTwoPage {
                correctedBookSpread = processed.correctedBookSpread
                lastBookQuadrilateral = processed.result.documentQuadrilateral
                lastBookCapturedAt = processed.result.capturedAt
            } else {
                correctedBookSpread = nil
                lastBookQuadrilateral = nil
                lastBookCapturedAt = nil
            }

            DispatchQueue.main.async { [weak self] in
                self?.lastResult = processed.result
                self?.phase = .completed
            }
        } catch let error as ScannerCoreError {
            if finishCapture(id: request.id) {
                publishFailure(error)
            }
        } catch {
            if finishCapture(id: request.id) {
                publishFailure(.captureFailed(error.localizedDescription))
            }
        }
    }

    private func applyLiveDetection(
        _ detection: LiveRectangleDetection?,
        gutterRatio: CGFloat?
    ) {
        liveBookGutterRatio =
            captureMode == .bookTwoPage
            ? gutterRatio
            : nil
        liveDetection = detection
        guard lastResult == nil else { return }
        guard !isCaptureInFlight else { return }

        guard let detection else {
            autoCaptureArmed = true
            unstableFramesForRearm = 0
            phase = .searching
            return
        }

        if detection.isStable {
            unstableFramesForRearm = 0
            phase = .ready
            if autoCaptureEnabled, autoCaptureArmed {
                autoCaptureArmed = false
                capture()
            }
        } else {
            if !autoCaptureArmed {
                unstableFramesForRearm += 1
                if unstableFramesForRearm >= 5 {
                    autoCaptureArmed = true
                    unstableFramesForRearm = 0
                }
            }
            phase = .stabilizing(progress: detection.stabilityProgress)
        }
    }

    private func beginCaptureIfAvailable(id: UUID) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard !captureInFlight else { return false }
        captureInFlight = true
        activeCaptureID = id
        return true
    }

    @discardableResult
    private func finishCapture(id: UUID) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard captureInFlight, activeCaptureID == id else { return false }
        captureInFlight = false
        activeCaptureID = nil
        return true
    }

    private func cancelActiveCapture() {
        captureLock.lock()
        captureInFlight = false
        activeCaptureID = nil
        captureLock.unlock()
    }

    private func isCaptureActive(id: UUID) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        return captureInFlight && activeCaptureID == id
    }

    private var isCaptureInFlight: Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        return captureInFlight
    }

    private func publishAuthorization(_ state: ScannerAuthorizationState) {
        DispatchQueue.main.async { [weak self] in
            self?.authorizationState = state
        }
    }

    private func publishCameraState(
        capabilities: ScannerCameraCapabilities,
        activeLens: ScannerCameraLens
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.cameraCapabilities = capabilities
            self?.activeCameraLens = activeLens
        }
    }

    /// Call only from `visionQueue`.
    private func publishAnalysisDiagnostics(
        frameWidth: Int,
        frameHeight: Int,
        orientation: ScannerFrameOrientation,
        observationCount: Int,
        errorDescription: String?
    ) {
        let diagnostics = ScannerAnalysisDiagnostics(
            receivedFrameCount: receivedFrameCount,
            analyzedFrameCount: analyzedFrameCount,
            candidateFrameCount: candidateFrameCount,
            lastObservationCount: observationCount,
            visionErrorCount: visionErrorCount,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            orientation: orientation,
            lastErrorDescription: errorDescription
        )
        DispatchQueue.main.async { [weak self] in
            self?.analysisDiagnostics = diagnostics
        }
    }

    private func publishFailure(_ error: ScannerCoreError) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = error
            self?.phase = .failed(message: error.localizedDescription)
        }
    }
}

extension DocumentScannerModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        receivedFrameCount += 1
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp - lastVisionTimestamp >= 0.11 else { return }
        lastVisionTimestamp = timestamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        let orientation = liveFrameOrientation
        storeLatestVideoFrameCopy(
            from: pixelBuffer,
            receivedAtUptime: ProcessInfo.processInfo.systemUptime,
            orientation: orientation
        )

        do {
            let analysis = try liveRectangleDetector.analyze(
                pixelBuffer: pixelBuffer,
                orientation: orientation.imagePropertyOrientation,
                mode: liveDetectionMode
            )
            analyzedFrameCount += 1
            if analysis.candidate != nil {
                candidateFrameCount += 1
            }
            let detection = stabilityTracker.update(
                candidate: analysis.candidate,
                timestamp: timestamp
            )
            publishAnalysisDiagnostics(
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                orientation: orientation,
                observationCount: analysis.observationCount,
                errorDescription: nil
            )
            DispatchQueue.main.async { [weak self] in
                self?.applyLiveDetection(
                    detection,
                    gutterRatio: analysis.suggestedBookGutterRatio
                )
            }
        } catch {
            analyzedFrameCount += 1
            visionErrorCount += 1
            let description = error.localizedDescription
            analysisLogger.error(
                "Vision rectangle analysis failed: \(description, privacy: .public)"
            )
            let detection = stabilityTracker.update(candidate: nil, timestamp: timestamp)
            publishAnalysisDiagnostics(
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                orientation: orientation,
                observationCount: 0,
                errorDescription: description
            )
            DispatchQueue.main.async { [weak self] in
                self?.applyLiveDetection(detection, gutterRatio: nil)
            }
        }
    }
}

private struct CaptureRequest: Sendable {
    let id: UUID
    let mode: ScannerCaptureMode
    let manualGutterRatio: CGFloat?
    let fallbackQuadrilateral: DocumentQuadrilateral?
    let quality: ScannerCaptureQuality
}

private struct LatestVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let receivedAtUptime: TimeInterval
    let orientation: ScannerFrameOrientation
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let completionLock = NSLock()
    private var completed = false
    private var processedResult: Result<Data, Error>?

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            storeProcessedResult(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            storeProcessedResult(.failure(ScannerCoreError.imageDecodingFailed))
            return
        }
        storeProcessedResult(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        completionLock.lock()
        let result = processedResult ?? .failure(ScannerCoreError.imageDecodingFailed)
        completionLock.unlock()
        finish(result)
    }

    private func storeProcessedResult(_ result: Result<Data, Error>) {
        completionLock.lock()
        processedResult = result
        completionLock.unlock()
    }

    private func finish(_ result: Result<Data, Error>) {
        completionLock.lock()
        guard !completed else {
            completionLock.unlock()
            return
        }
        completed = true
        completionLock.unlock()
        completion(result)
    }
}
