@preconcurrency import AVFoundation
import CoreGraphics
import Darwin
@preconcurrency import Dispatch
import Foundation
import MPVKitSampleBufferCore
import QuartzCore
#if os(macOS)
import AppKit
#endif

private let mpvkitMoltenVKHasImportedTextureResidencyFix: Bool = {
    #if MPVKIT_MOLTENVK_IMPORTED_TEXTURE_RESIDENCY_FIX
    true
    #else
    false
    #endif
}()

public enum MPVGPUPlayerRendererState: Equatable, Sendable {
    case idle
    case starting
    case loading
    case ready
    case playing
    case paused
    case pictureInPicture
    case stopping
    case stopped
    case failed(String)
}

public enum MPVGPUPlayerPresentationMode: String, Equatable, Sendable {
    case inlineGPU
    case pictureInPictureSampleBuffer
}

/// Selects the VideoToolbox decoder order used when rebuilding a hardware session after system
/// suspension. This only controls `hwdec`; strict hosts must separately configure
/// `hwdec-software-fallback=no` when software decoding is forbidden.
public enum MPVGPUPlayerHardwareDecoderRecoveryStrategy: Equatable, Sendable {
    /// Reapply the host's configured order, normally direct VideoToolbox followed by its copy path.
    case configuredOrder
    /// Use VideoToolbox's copy path only after the configured-order retry produced no decoded frame.
    case copyOnly
}

/// Describes whether MPVKit could begin a causally fenced VideoToolbox reconstruction.
public enum MPVGPUPlayerHardwareDecoderRecoverySubmission: Equatable, Sendable {
    /// The old video track was fully deselected and the selected track was accepted again.
    /// A matching recovery-output callback is still required as decoded-frame proof.
    case accepted(epoch: UInt64)
    /// Loading or PiP currently owns the video track. The host may retry after it settles.
    case transitionBusy
    /// No selected video track or configured VideoToolbox path is available.
    case unavailable
    /// mpv rejected a track/property command. Repeating it without a state change is not useful.
    case commandFailed
    /// The host cancelled the reconstruction before it could publish a proof epoch.
    case cancelled
}

/// Result of a non-destructive foreground health check. The healthy case requires both a fresh
/// VideoToolbox property read and a current inline CAMetalLayer presentation; it never changes the
/// selected video track or decoder.
public enum MPVGPUPlayerForegroundVideoValidation: Equatable, Sendable {
    case healthy(decoder: String)
    case playbackDeferred(decoder: String)
    case decoderUnavailable(current: String)
    case inlinePresentationTimedOut(decoder: String)
    case timelineUnhealthy(decoder: String)
    case transitionBusy
    case unavailable
}

/// Selects how MPVKit should produce frames for AVKit's sample-buffer PiP surface.
///
/// `singleSessionGPU` is deliberately strict: it never opens the media a second time. If the
/// linked Libmpv does not expose MPVKit's native offscreen sink, preparation fails rather than
/// silently changing resource/network semantics. `automatic` may use the compatibility bridge.
public enum MPVPictureInPictureBackendPreference: String, Equatable, Sendable {
    case automatic
    case singleSessionGPU
    case compatibilityDualSession
}

/// The backend actually selected for the current load.
public enum MPVPictureInPictureBackend: String, Equatable, Sendable {
    case singleSessionGPUDirectIOSurface
    case singleSessionGPUAsynchronousMetalBlit
    case compatibilityDualSession
}

/// Generation-scoped PiP preparation state. A new media load always creates a new generation,
/// making late frames and timeouts from the replaced item harmless.
public enum MPVPictureInPictureState: Equatable, Sendable {
    case idle
    case preparing(generation: UInt64)
    case ready(generation: UInt64)
    case active(generation: UInt64)
    case restoring(generation: UInt64)
    case failed(generation: UInt64, reason: String)
}

public enum MPVGPUPlayerRendererError: Error, LocalizedError, Equatable, Sendable {
    case teardownInProgress
    case rendererNotRunning
    case mediaNotLoaded
    case pictureInPictureUnavailable(String)
    case pictureInPicturePreparationSuperseded
    case pictureInPicturePreparationTimedOut

    public var errorDescription: String? {
        switch self {
        case .teardownInProgress:
            return "MPVGPUPlayerRenderer teardown is still in progress."
        case .rendererNotRunning:
            return "Picture in Picture preparation requires a running MPVGPUPlayerRenderer."
        case .mediaNotLoaded:
            return "Picture in Picture preparation requires a loaded media URL."
        case .pictureInPictureUnavailable(let reason):
            return "The requested Picture in Picture backend is unavailable: \(reason)"
        case .pictureInPicturePreparationSuperseded:
            return "Picture in Picture preparation was superseded by a newer load."
        case .pictureInPicturePreparationTimedOut:
            return "Picture in Picture did not produce a valid frame before the preparation timeout."
        }
    }
}

public struct MPVGPUPlayerRendererOptions: Equatable, Sendable {
    public var maximumPiPFrameSize: CGSize
    public var preferredPiPFramesPerSecond: Int
    public var inlineProfile: String
    public var hardwareDecoding: String
    public var enablesTargetColorspaceHint: Bool
    public var pausesInlineRendererDuringPictureInPicture: Bool
    public var pictureInPictureBackendPreference: MPVPictureInPictureBackendPreference
    /// Kept at three by default so the native sink and compatibility bridge share a bounded
    /// ownership contract. The current compatibility renderer enforces its own matching pool cap.
    public var maximumInFlightPictureInPictureFrames: Int
    public var pictureInPicturePreparationTimeout: TimeInterval
    /// A value <= 0 selects the platform default (4K on iOS/tvOS, 5K on macOS).
    public var maximumInlineDrawablePixelCount: Int
    /// A value <= 0 selects 1/60 second on iPhone/tvOS and 1/30 second on iPad/macOS.
    public var inlineResizeDebounceInterval: TimeInterval
    public var additionalMPVOptions: [String: String]

    public init(
        maximumPiPFrameSize: CGSize = CGSize(width: 1280, height: 720),
        preferredPiPFramesPerSecond: Int = 24,
        inlineProfile: String = "fast",
        hardwareDecoding: String = "videotoolbox",
        enablesTargetColorspaceHint: Bool = false,
        pausesInlineRendererDuringPictureInPicture: Bool = true,
        pictureInPictureBackendPreference: MPVPictureInPictureBackendPreference = .automatic,
        maximumInFlightPictureInPictureFrames: Int = 3,
        pictureInPicturePreparationTimeout: TimeInterval = 1,
        maximumInlineDrawablePixelCount: Int = 0,
        inlineResizeDebounceInterval: TimeInterval = 0,
        additionalMPVOptions: [String: String] = [:]
    ) {
        self.maximumPiPFrameSize = maximumPiPFrameSize
        self.preferredPiPFramesPerSecond = preferredPiPFramesPerSecond
        self.inlineProfile = inlineProfile
        self.hardwareDecoding = hardwareDecoding
        self.enablesTargetColorspaceHint = enablesTargetColorspaceHint
        self.pausesInlineRendererDuringPictureInPicture = pausesInlineRendererDuringPictureInPicture
        self.pictureInPictureBackendPreference = pictureInPictureBackendPreference
        self.maximumInFlightPictureInPictureFrames = min(3, max(1, maximumInFlightPictureInPictureFrames))
        self.pictureInPicturePreparationTimeout = max(0.1, pictureInPicturePreparationTimeout)
        self.maximumInlineDrawablePixelCount = maximumInlineDrawablePixelCount
        self.inlineResizeDebounceInterval = inlineResizeDebounceInterval
        self.additionalMPVOptions = additionalMPVOptions
    }
}

public struct MPVGPUPlayerRenderPass: Equatable, Sendable {
    public let description: String
    public let sampleCount: Int
    public let lastNanoseconds: Int64
}

public struct MPVGPUPlayerRendererDiagnostics: Equatable, Sendable {
    public let state: MPVGPUPlayerRendererState
    public let presentationMode: MPVGPUPlayerPresentationMode
    public let currentTime: Double
    public let duration: Double
    public let isPaused: Bool
    public let inlineVideoOutput: String
    public let inlineGPUAPI: String
    public let inlineGPUContext: String
    public let pictureInPictureDiagnostics: MPVMetalSampleBufferRendererDiagnostics?
    public let backendDescription: String
    public let pictureInPictureState: MPVPictureInPictureState
    public let pictureInPictureBackendPreference: MPVPictureInPictureBackendPreference
    public let selectedPictureInPictureBackend: MPVPictureInPictureBackend?
    public let pictureInPictureFallbackReason: String?
    public let activeMPVInstanceCount: Int
    public let pictureInPicturePreparationGeneration: UInt64
    public let pictureInPicturePreparationLatency: TimeInterval
    public let inlineResizeRequestCount: Int
    public let inlineResizeApplicationCount: Int
    public let inlineResizeCoalescedCount: Int
    public let pictureInPictureResizeRequestCount: Int
    public let pictureInPictureResizeApplicationCount: Int
    public let pictureInPictureResizeCoalescedCount: Int
    public let maximumInlineDrawablePixelCount: Int
    public let schedulerCoalescedRequestCount: Int
    public let backpressureDropCount: Int
    public let poolExhaustionDropCount: Int
    public let staleGenerationDropCount: Int
    public let inFlightGPUFrameCount: Int
    /// Frames successfully enqueued into AVKit for the selected PiP backend and preparation.
    public let pictureInPictureEnqueuedFrameCount: Int
    public let lastGPULatencyMilliseconds: Double
    public let timelineEpoch: UInt64
    public let timelineRate: Double
    /// AudioUnit invalid-buffer recoveries observed since this renderer instance started.
    public let audioRecoveryCount: Int
    /// Best available decoded/container frame-rate estimate; 0 when mpv has not resolved one yet.
    public let estimatedFramesPerSecond: Double
    /// Video frames mpv dropped because the video output could not keep up (`frame-drop-count`).
    public let droppedVideoFrameCount: Int
    /// mpv's estimated late-presentation count (`vo-delayed-frame-count`). Display-sync only:
    /// stays 0 under `video-sync=audio`, which is what this player configures.
    public let delayedVideoFrameCount: Int
    /// Active video codec name (`video-codec`); empty when no video is loaded.
    public let videoCodec: String
    /// True only when the decoded video frame carries Dolby Vision metadata/RPU; nil until inspected.
    public let videoHasDolbyVisionRPU: Bool?
    /// Decoded video frame width/height in pixels (`video-params/w`/`h`); 0 when no video.
    public let videoWidth: Int
    public let videoHeight: Int
    /// Transfer characteristics / gamma (`video-params/gamma`, e.g. "pq", "hlg", "bt.1886").
    public let videoTransferFunction: String
    /// Color primaries (`video-params/primaries`, e.g. "bt.2020", "bt.709").
    public let videoColorPrimaries: String
    /// Reference signal peak (`video-params/sig-peak`); > 1.0 indicates HDR.
    public let videoSignalPeak: Double
    /// Decoded pixel format (`video-params/pixelformat`, e.g. "yuv420p10", "p010"). High-bit-depth
    /// content contains "10"/"12"/"16".
    public let videoPixelFormat: String
    /// Active hardware decoder (`hwdec-current`, e.g. "videotoolbox" or "no").
    public let hardwareDecoder: String
}

private final class MPVUncheckedSendableReference<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public final class MPVGPUPlayerMetalLayer: CAMetalLayer, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        #if os(macOS) && arch(x86_64)
        if let source = layer as? MPVGPUPlayerMetalLayer {
            intelDrawablePixelLimit = source.intelDrawablePixelLimit
        }
        #endif
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width.isFinite,
                  newValue.height.isFinite,
                  newValue.width > 1,
                  newValue.height > 1 else { return }
            #if os(macOS) && arch(x86_64)
            intelGeometryLock.lock()
            defer { intelGeometryLock.unlock() }
            guard let bounded = intelBoundedDrawableSize(newValue) else { return }
            super.drawableSize = bounded
            #else
            super.drawableSize = newValue
            #endif
        }
    }

    #if os(macOS) && arch(x86_64)
    private let intelGeometryLock = NSRecursiveLock()
    private var intelIsUpdatingGeometry = false
    private var intelConfiguredPixelLimit = 8_294_400

    var intelDrawablePixelLimit: Int {
        get {
            intelGeometryLock.lock()
            defer { intelGeometryLock.unlock() }
            return intelConfiguredPixelLimit
        }
        set {
            withIntelGeometryUpdate {
                self.intelConfiguredPixelLimit = MPVDrawablePixelLimit.resolved(
                    configured: newValue, platformMaximum: 8_294_400
                )
                if let scale = self.intelBoundedScale(bounds: super.bounds.size, requested: super.contentsScale) {
                    super.contentsScale = scale
                }
            }
        }
    }

    public override var bounds: CGRect {
        get { super.bounds }
        set {
            guard newValue.width.isFinite, newValue.height.isFinite,
                  newValue.width >= 0, newValue.height >= 0 else { return }
            withIntelGeometryUpdate {
                if newValue.width > 1, newValue.height > 1 {
                    guard let scale = self.intelBoundedScale(bounds: newValue.size, requested: super.contentsScale) else { return }
                    super.contentsScale = min(super.contentsScale, scale)
                }
                super.bounds = newValue
            }
        }
    }

    public override var frame: CGRect {
        get { super.frame }
        set {
            guard newValue.width.isFinite, newValue.height.isFinite,
                  newValue.width >= 0, newValue.height >= 0 else { return }
            withIntelGeometryUpdate {
                if newValue.width > 1, newValue.height > 1 {
                    guard let scale = self.intelBoundedScale(bounds: newValue.size, requested: super.contentsScale) else { return }
                    super.contentsScale = min(super.contentsScale, scale)
                }
                super.frame = newValue
            }
        }
    }

    public override var contentsScale: CGFloat {
        get { super.contentsScale }
        set {
            guard newValue.isFinite, newValue > 0 else { return }
            withIntelGeometryUpdate {
                if super.bounds.width > 1, super.bounds.height > 1 {
                    guard let scale = self.intelBoundedScale(bounds: super.bounds.size, requested: newValue) else { return }
                    super.contentsScale = scale
                } else {
                    super.contentsScale = newValue
                }
            }
        }
    }

    private func withIntelGeometryUpdate(_ update: () -> Void) {
        intelGeometryLock.lock()
        defer { intelGeometryLock.unlock() }
        guard !intelIsUpdatingGeometry else { update(); return }
        intelIsUpdatingGeometry = true
        defer { intelIsUpdatingGeometry = false }
        let previousDrawable = super.drawableSize
        update()
        if let bounded = intelBoundedDrawableSize(super.drawableSize)
            ?? intelBoundedDrawableSize(previousDrawable) {
            super.drawableSize = bounded
        }
    }

    private func intelBoundedScale(bounds: CGSize, requested: CGFloat) -> CGFloat? {
        let requestedSize = CGSize(width: bounds.width * requested, height: bounds.height * requested)
        if requested.isFinite, requested > 0,
           requestedSize.width.isFinite, requestedSize.height.isFinite,
           requestedSize.width > 1, requestedSize.height > 1,
           requestedSize.width <= intelMaximumTextureDimension,
           requestedSize.height <= intelMaximumTextureDimension,
           requestedSize.width * requestedSize.height <= CGFloat(intelConfiguredPixelLimit) {
            return requested
        }
        guard let maximum = intelBoundedDrawableSize(requestedSize) else { return nil }
        return MPVInlineDrawableLayout.resolved(
            bounds: bounds,
            presentationScale: requested,
            maximumDrawableSize: maximum
        )?.contentsScale
    }

    private var intelMaximumTextureDimension: CGFloat {
        if let device, device.supportsFamily(.mac1) || device.supportsFamily(.mac2) || device.supportsFamily(.apple3) {
            return 16_384
        }
        return 8_192
    }

    private func intelBoundedDrawableSize(_ requested: CGSize) -> CGSize? {
        MPVIntelMacRenderPolicy.drawableSize(
            requested: requested,
            maximumDimension: intelMaximumTextureDimension,
            maximumPixelCount: intelConfiguredPixelLimit
        )
    }
    #endif

    #if !os(tvOS)
    @available(iOS 16.0, macOS 10.15, macCatalyst 16.0, visionOS 1.0, *)
    public override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                let layer = MPVUncheckedSendableReference(self)
                DispatchQueue.main.async {
                    layer.value.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
    #endif
}

#if os(iOS) || os(tvOS) || (os(macOS) && (arch(arm64) || arch(x86_64)))
import Libmpv
import Metal
import CoreMedia
import CoreVideo
import IOSurface
#if !os(macOS)
import UIKit
#endif

private enum MPVGPUPlayerEvent: Sendable {
    case startFile(playlistEntryID: Int64)
    case fileLoaded(playlistEntryID: Int64?)
    case videoReconfigure(playlistEntryID: Int64?)
    case seek(playlistEntryID: Int64?)
    case playbackRestart(playlistEntryID: Int64?)
    case endFile(playlistEntryID: Int64, reachedEOF: Bool, error: String?)
    case propertyChange(String, value: MPVGPUObservedPropertyValue, playlistEntryID: Int64?)
    case logError(String, playlistEntryID: Int64?)
    case inlineHitchDiagnostic(String, playlistEntryID: Int64?)
    case videoTimelineDiscontinuity(playlistEntryID: Int64?)
    case asyncReply(requestID: UInt64, error: Int32)
    case shutdown
}

private enum MPVGPUInlineDiagnosticStream: Hashable {
    case audio
    case video
    case other
}

private enum MPVGPUInlineGPUErrorStage: Hashable {
    case hwdecTextureInit
    case hwdecFrameMapNull
    case hwdecSurfaceMap
    case frameUpload
    case libplaceboQueueUpdate
    case inlineRender
    case pipIOSurfaceRender
    case swapchainSubmit
    case other
}

private enum MPVGPUInlineDiagnosticCategory: Hashable {
    case inlineHitch
    case audioUnderrun
    case decodeError
    case decodedAudioGap
    case decodedVideoGap
    case demuxReadError
    case demuxWait(MPVGPUInlineDiagnosticStream)
    case frameWindow
    case gpuError(MPVGPUInlineGPUErrorStage)
    case packetGap(MPVGPUInlineDiagnosticStream)
    case voDrop
    case videoTimestampReset
    case other
}

private func mpvGPUInlineDiagnosticStream(_ message: String) -> MPVGPUInlineDiagnosticStream {
    if message.contains("stream=audio") {
        return .audio
    }
    if message.contains("stream=video") {
        return .video
    }
    return .other
}

private func mpvGPUInlineGPUErrorStage(_ message: String) -> MPVGPUInlineGPUErrorStage {
    if message.contains("stage=hwdec-texture-init") { return .hwdecTextureInit }
    if message.contains("stage=hwdec-frame-map-null") { return .hwdecFrameMapNull }
    if message.contains("stage=hwdec-surface-map") { return .hwdecSurfaceMap }
    if message.contains("stage=frame-upload") { return .frameUpload }
    if message.contains("stage=libplacebo-queue-update") { return .libplaceboQueueUpdate }
    if message.contains("stage=inline-render") { return .inlineRender }
    if message.contains("stage=pip-iosurface-render") { return .pipIOSurfaceRender }
    if message.contains("stage=swapchain-submit") { return .swapchainSubmit }
    return .other
}

private func mpvGPUInlineDiagnosticCategory(_ message: String) -> MPVGPUInlineDiagnosticCategory? {
    guard let markerStart = message.range(of: "[MPVKit")?.lowerBound else { return nil }
    let markerLimit = message.index(
        markerStart,
        offsetBy: 40,
        limitedBy: message.endIndex
    ) ?? message.endIndex
    guard let markerEnd = message[markerStart..<markerLimit].firstIndex(of: "]") else {
        return .other
    }
    switch message[markerStart...markerEnd] {
    case "[MPVKitInlineHitch]": return .inlineHitch
    case "[MPVKitAudioUnderrun]": return .audioUnderrun
    case "[MPVKitDecodeError]": return .decodeError
    case "[MPVKitDecodedAudioGap]": return .decodedAudioGap
    case "[MPVKitDecodedVideoGap]": return .decodedVideoGap
    case "[MPVKitDemuxReadError]": return .demuxReadError
    case "[MPVKitDemuxWait]": return .demuxWait(mpvGPUInlineDiagnosticStream(message))
    case "[MPVKitFrameWindow]": return .frameWindow
    case "[MPVKitGPUError]": return .gpuError(mpvGPUInlineGPUErrorStage(message))
    case "[MPVKitPacketGap]": return .packetGap(mpvGPUInlineDiagnosticStream(message))
    case "[MPVKitVODrop]": return .voDrop
    case "[MPVKitVideoTimestampReset]": return .videoTimestampReset
    default: return .other
    }
}

/// Deep-copied observed-property payload. libmpv owns `mpv_event_property.data` only until the
/// next event wait, so values must be copied before the event pump crosses to the main actor.
private enum MPVGPUObservedPropertyValue: Sendable {
    case unavailable
    case string(String)
    case flag(Bool)
    case int64(Int64)
    case double(Double)
}

private func copyMPVGPUObservedPropertyValue(
    _ property: mpv_event_property
) -> MPVGPUObservedPropertyValue {
    guard let data = property.data else { return .unavailable }
    switch property.format {
    case MPV_FORMAT_STRING:
        guard let value = data
            .assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            .pointee else { return .unavailable }
        return .string(String(cString: value))
    case MPV_FORMAT_FLAG:
        return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
    case MPV_FORMAT_INT64:
        return .int64(data.assumingMemoryBound(to: Int64.self).pointee)
    case MPV_FORMAT_DOUBLE:
        return .double(data.assumingMemoryBound(to: Double.self).pointee)
    default:
        return .unavailable
    }
}

private enum MPVGPUPlayerDeferredLoadAction {
    case videoTrack(String)
    case audioTrack(Int)
    case subtitleStyle(MPVMetalSampleBufferSubtitleStyle)
    case videoFilterChain(String)
}

/// Owns the single blocking libmpv event loop independently from the renderer. The pump remains
/// retained until its serial queue has exited and the handle has been destroyed, so teardown never
/// waits on the main actor and no C callback can dereference a deallocated Swift renderer.
private final class MPVGPUPlayerEventPump: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "mpvkit.gpu-player.events", qos: .userInitiated)
    private let lock = NSLock()
    private let eventHandler: @Sendable (MPVGPUPlayerEvent) -> Void
    private var active = true
    private var stopRequested = false
    private var didFinish = false
    private var stopCompletions: [@MainActor @Sendable () -> Void] = []
    /// Accessed only by `queue`; copied onto each event before crossing to the main actor.
    private var activePlaylistEntryID: Int64?
    private var lastForwardedInlineDiagnosticUptimeNanosecondsByCategory: [MPVGPUInlineDiagnosticCategory: UInt64] = [:]

    init(handle: OpaquePointer, eventHandler: @escaping @Sendable (MPVGPUPlayerEvent) -> Void) {
        self.handle = handle
        self.eventHandler = eventHandler
    }

    func install() {
        queue.async { [self] in runEventLoop() }
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        if didFinish {
            lock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        stopCompletions.append(completion)
        guard !stopRequested else {
            lock.unlock()
            return
        }
        stopRequested = true
        active = false
        lock.unlock()

        // `mpv_wakeup` is the only cross-thread operation needed to release the blocking wait.
        mpv_wakeup(handle)
    }

    private func runEventLoop() {
        while isActive {
            guard let eventPointer = mpv_wait_event(handle, -1) else { continue }
            guard isActive else { break }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE { continue }
            if let value = copyEvent(event) {
                eventHandler(value)
            }
        }

        mpv_terminate_destroy(handle)
        lock.lock()
        didFinish = true
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: false)
        lock.unlock()
        DispatchQueue.main.async {
            completions.forEach { $0() }
        }
    }

    private var isActive: Bool {
        lock.lock()
        let value = active
        lock.unlock()
        return value
    }

    private func copyEvent(_ event: mpv_event) -> MPVGPUPlayerEvent? {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            guard let data = event.data else { return nil }
            let startFile = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee
            lastForwardedInlineDiagnosticUptimeNanosecondsByCategory.removeAll(keepingCapacity: true)
            activePlaylistEntryID = startFile.playlist_entry_id
            return .startFile(playlistEntryID: startFile.playlist_entry_id)
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded(playlistEntryID: activePlaylistEntryID)
        case MPV_EVENT_VIDEO_RECONFIG:
            return .videoReconfigure(playlistEntryID: activePlaylistEntryID)
        case MPV_EVENT_SEEK:
            return .seek(playlistEntryID: activePlaylistEntryID)
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart(playlistEntryID: activePlaylistEntryID)
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return nil }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let playlistEntryID = endFile.playlist_entry_id
            if activePlaylistEntryID == playlistEntryID {
                activePlaylistEntryID = nil
            }
            let error = endFile.reason == MPV_END_FILE_REASON_ERROR
                ? String(cString: mpv_error_string(endFile.error))
                : nil
            return .endFile(playlistEntryID: playlistEntryID, reachedEOF: endFile.reason == MPV_END_FILE_REASON_EOF, error: error)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let name = property.name else { return nil }
            return .propertyChange(
                String(cString: name),
                value: copyMPVGPUObservedPropertyValue(property),
                playlistEntryID: activePlaylistEntryID
            )
        case MPV_EVENT_LOG_MESSAGE:
            guard let log = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) else { return nil }
            let text = log.pointee.text.map { String(cString: $0) } ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            #if os(macOS) && arch(x86_64)
            if let message = MPVIntelMacRenderPolicy.deviceLossMessage(
                prefix: log.pointee.prefix.map { String(cString: $0) } ?? "",
                level: log.pointee.level.map { String(cString: $0) } ?? "",
                message: trimmed
            ) {
                return .logError(message, playlistEntryID: activePlaylistEntryID)
            }
            #endif
            guard let category = mpvGPUInlineDiagnosticCategory(trimmed) else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastForwardedInlineDiagnosticUptimeNanosecondsByCategory[category],
               now >= last,
               now - last < 5_000_000_000 {
                return category == .decodeError || category == .videoTimestampReset
                    ? .videoTimelineDiscontinuity(playlistEntryID: activePlaylistEntryID) : nil
            }
            lastForwardedInlineDiagnosticUptimeNanosecondsByCategory[category] = now
            return .inlineHitchDiagnostic(
                trimmed,
                playlistEntryID: activePlaylistEntryID
            )
        case MPV_EVENT_COMMAND_REPLY, MPV_EVENT_GET_PROPERTY_REPLY:
            return .asyncReply(requestID: event.reply_userdata, error: event.error)
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }
}

struct MPVSingleSessionPictureInPictureDiagnostics {
    let schedulerCoalescedRequestCount: Int
    let backpressureDropCount: Int
    let poolExhaustionDropCount: Int
    let staleGenerationDropCount: Int
    let inFlightGPUFrameCount: Int
    let enqueuedFrameCount: Int
    let lastGPULatencyMilliseconds: Double
    let timelineEpoch: UInt64
    let timelineRate: Double
}

/// Internal ABI seam for the optional native offscreen gpu-next sink. Locally rebuilt Libmpv
/// artifacts resolve it dynamically; release artifacts without the symbols continue to select the
/// compatibility bridge without a link-time dependency.
@MainActor
protocol MPVSingleSessionPictureInPictureSink: AnyObject {
    var backend: MPVPictureInPictureBackend { get }
    var diagnostics: MPVSingleSessionPictureInPictureDiagnostics { get }
    var onFrameEnqueued: ((UInt64) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func prepare(generation: UInt64, renderSize: CGSize) async throws
    func begin() throws
    func end(restoringInlinePlayback: Bool) async -> Bool
    func updateRenderSize(_ size: CGSize)
    func updateTimeline(position: Double, rate: Double, discontinuity: Bool)
    func stop()
    func waitUntilStopped() async
}

@MainActor
enum MPVSingleSessionPictureInPictureSinkRegistry {
    typealias Factory = (_ handle: OpaquePointer, _ displayLayer: AVSampleBufferDisplayLayer, _ capacity: Int, _ preferredFPS: Int, _ sourceFPS: Double) -> MPVSingleSessionPictureInPictureSink?
    static var factory: Factory? = { handle, displayLayer, capacity, preferredFPS, sourceFPS in
        MPVApplePictureInPictureSink.make(
            handle: handle,
            displayLayer: displayLayer,
            requestedCapacity: capacity,
            preferredFramesPerSecond: preferredFPS,
            sourceFramesPerSecond: sourceFPS
        )
    }
}

private enum MPVApplePictureInPictureSinkError: Error, LocalizedError {
    case unavailable(String)
    case nativeCall(String, Int32)
    case pixelBufferPool(Int32)
    case sampleBuffer(OSStatus)
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .nativeCall(let operation, let status):
            return "native Apple PiP \(operation) failed with status \(status)"
        case .pixelBufferPool(let status):
            return "PiP IOSurface pool failed with status \(status)"
        case .sampleBuffer(let status):
            return "PiP sample-buffer creation failed with status \(status)"
        case .stopped:
            return "native Apple PiP preparation was stopped"
        }
    }
}

private struct MPVApplePictureInPictureFrameValue: Sendable {
    let status: UInt32
    let width: UInt32
    let height: UInt32
    let pixelFormat: UInt32
    let backend: UInt32
    let token: UInt64
    let generation: UInt64
    let pts: Double
    let duration: Double
}

private final class MPVApplePictureInPictureCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private let handler: @MainActor @Sendable (MPVApplePictureInPictureFrameValue) -> Void

    init(handler: @escaping @MainActor @Sendable (MPVApplePictureInPictureFrameValue) -> Void) {
        self.handler = handler
    }

    func receive(_ rawFrame: UnsafeRawPointer?) {
        guard let rawFrame else { return }
        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else { return }
        let size = rawFrame.load(fromByteOffset: 0, as: UInt32.self)
        guard size >= 56 else { return }
        let frame = MPVApplePictureInPictureFrameValue(
            status: rawFrame.load(fromByteOffset: 4, as: UInt32.self),
            width: rawFrame.load(fromByteOffset: 8, as: UInt32.self),
            height: rawFrame.load(fromByteOffset: 12, as: UInt32.self),
            pixelFormat: rawFrame.load(fromByteOffset: 16, as: UInt32.self),
            backend: rawFrame.load(fromByteOffset: 20, as: UInt32.self),
            token: rawFrame.load(fromByteOffset: 24, as: UInt64.self),
            generation: rawFrame.load(fromByteOffset: 32, as: UInt64.self),
            pts: rawFrame.load(fromByteOffset: 40, as: Double.self),
            duration: rawFrame.load(fromByteOffset: 48, as: Double.self)
        )
        DispatchQueue.main.async { [handler] in handler(frame) }
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }
}

private let mpvApplePictureInPictureFrameCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?
) -> Void = { context, frame in
    guard let context else { return }
    Unmanaged<MPVApplePictureInPictureCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(frame)
}

/// Keeps generation-scoped callback contexts behind opaque integer tokens. Native code never
/// dereferences the token, so unregistering before an already-claimed callback is delivered is
/// safe: the late callback simply finds no context instead of touching released Swift memory.
private enum MPVApplePictureInPictureCallbackRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextToken: UInt = 1
    nonisolated(unsafe) private static var contexts: [UInt: MPVApplePictureInPictureCallbackContext] = [:]

    static func register(_ context: MPVApplePictureInPictureCallbackContext) -> UnsafeMutableRawPointer {
        lock.lock()
        let token = nextToken
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        contexts[token] = context
        lock.unlock()
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func unregister(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        contexts.removeValue(forKey: UInt(bitPattern: pointer))
        lock.unlock()
    }

    static func receive(_ pointer: UnsafeMutableRawPointer?, frame: UnsafeRawPointer?) {
        guard let pointer else { return }
        lock.lock()
        let context = contexts[UInt(bitPattern: pointer)]
        lock.unlock()
        context?.receive(frame)
    }
}

private let mpvAppleInlineRestoreFrameCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?
) -> Void = { context, frame in
    MPVApplePictureInPictureCallbackRegistry.receive(context, frame: frame)
}

// These C providers resolve strong native APIs over inert weak fallbacks. Unlike a dlsym-only
// lookup, the linker-visible references survive Xcode's App Store `strip -D` export step. Older
// published Libmpv artifacts report API version zero and use the compatibility bridge.
@_silgen_name("mpvkit_apple_pip_api_version_symbol")
private func mpvkitApplePiPAPIVersionSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_pip_get_capabilities_symbol")
private func mpvkitApplePiPGetCapabilitiesSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_pip_set_callback_symbol")
private func mpvkitApplePiPSetCallbackSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_pip_set_mode_symbol")
private func mpvkitApplePiPSetModeSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_pip_submit_target_symbol")
private func mpvkitApplePiPSubmitTargetSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_pip_disable_and_drain_symbol")
private func mpvkitApplePiPDisableAndDrainSymbol() -> UnsafeMutableRawPointer?
@_silgen_name("mpvkit_apple_audiounit_recovery_count_symbol")
private func mpvkitAppleAudioUnitRecoveryCountSymbol() -> UnsafeMutableRawPointer?

private final class MPVApplePictureInPictureAPI: @unchecked Sendable {
    typealias APIVersion = @convention(c) () -> UInt32
    typealias GetCapabilities = @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
    typealias SetCallback = @convention(c) (
        OpaquePointer,
        (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void)?,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias SetMode = @convention(c) (OpaquePointer, UInt32, UInt64) -> Int32
    typealias SubmitTarget = @convention(c) (OpaquePointer, UnsafeRawPointer) -> Int32
    typealias DisableAndDrain = @convention(c) (OpaquePointer) -> Int32

    let apiVersion: APIVersion
    let getCapabilities: GetCapabilities
    let setCallback: SetCallback
    let setMode: SetMode
    let submitTarget: SubmitTarget
    let disableAndDrain: DisableAndDrain

    static func load() -> MPVApplePictureInPictureAPI? {
        func symbol<T>(_ pointer: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
            guard let pointer else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let apiVersion = symbol(mpvkitApplePiPAPIVersionSymbol(), as: APIVersion.self),
              let getCapabilities = symbol(
                mpvkitApplePiPGetCapabilitiesSymbol(),
                as: GetCapabilities.self
              ),
              let setCallback = symbol(mpvkitApplePiPSetCallbackSymbol(), as: SetCallback.self),
              let setMode = symbol(mpvkitApplePiPSetModeSymbol(), as: SetMode.self),
              let submitTarget = symbol(
                mpvkitApplePiPSubmitTargetSymbol(),
                as: SubmitTarget.self
              ),
              let disableAndDrain = symbol(
                mpvkitApplePiPDisableAndDrainSymbol(),
                as: DisableAndDrain.self
              ) else {
            return nil
        }
        return MPVApplePictureInPictureAPI(
            apiVersion: apiVersion,
            getCapabilities: getCapabilities,
            setCallback: setCallback,
            setMode: setMode,
            submitTarget: submitTarget,
            disableAndDrain: disableAndDrain
        )
    }

    init(
        apiVersion: APIVersion,
        getCapabilities: GetCapabilities,
        setCallback: SetCallback,
        setMode: SetMode,
        submitTarget: SubmitTarget,
        disableAndDrain: DisableAndDrain
    ) {
        self.apiVersion = apiVersion
        self.getCapabilities = getCapabilities
        self.setCallback = setCallback
        self.setMode = setMode
        self.submitTarget = submitTarget
        self.disableAndDrain = disableAndDrain
    }
}

private enum MPVAppleAudioRecoveryCounter {
    typealias Read = @convention(c) () -> UInt64

    static let read: Read? = {
        guard let symbol = mpvkitAppleAudioUnitRecoveryCountSymbol() else {
            return nil
        }
        return unsafeBitCast(symbol, to: Read.self)
    }()

    static var current: UInt64 { read?() ?? 0 }
}

private let mpvApplePictureInPictureSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

private func mpvApplyApplePictureInPictureSDRAttachments(to pixelBuffer: CVPixelBuffer) {
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_sRGB,
        .shouldPropagate
    )
    if let colorSpace = mpvApplePictureInPictureSRGBColorSpace {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCGColorSpaceKey,
            colorSpace,
            .shouldPropagate
        )
    }
}

/// Weakly binds the optional native ABI so the source package remains compatible with the
/// currently published Libmpv binary. A locally rebuilt artifact exposes these symbols and gets a
/// real one-handle gpu-next -> IOSurface path; an older binary simply returns nil from `make`.
@MainActor
private final class MPVApplePictureInPictureSink: MPVSingleSessionPictureInPictureSink {
    private static let apiVersion: UInt32 = 1
    private static let bgraPixelFormat: UInt32 = 0x4247_5241
    private static let directIOSurfaceCapability: UInt64 = 1 << 0
    private static let asynchronousMetalBlitCapability: UInt64 = 1 << 4
    static let inlineRestoreNotificationCapability: UInt64 = 1 << 5
    static let inlineFreshFrameNotificationCapability: UInt64 = 1 << 6
    private static let requiredCapabilities: UInt64 = (1 << 1) | (1 << 2) | (1 << 3)
    private static let modeInline: UInt32 = 0
    private static let modeWarmup: UInt32 = 1
    private static let modeOffscreen: UInt32 = 2
    private static let modeRestore: UInt32 = 3
    static let modeInlineFreshFrame: UInt32 = 4
    private static let frameReady: UInt32 = 0
    private static let frameStale: UInt32 = 1
    private static let frameCanceled: UInt32 = 2
    private static let frameRenderFailed: UInt32 = 3

    private(set) var backend: MPVPictureInPictureBackend
    var onFrameEnqueued: ((UInt64) -> Void)?
    var onError: ((String) -> Void)?

    var diagnostics: MPVSingleSessionPictureInPictureDiagnostics {
        MPVSingleSessionPictureInPictureDiagnostics(
            schedulerCoalescedRequestCount: schedulerCoalescedRequestCount,
            backpressureDropCount: backpressureDropCount,
            poolExhaustionDropCount: poolExhaustionDropCount,
            staleGenerationDropCount: staleGenerationDropCount,
            inFlightGPUFrameCount: inFlightBuffers.count,
            enqueuedFrameCount: enqueuedFrameCount,
            lastGPULatencyMilliseconds: lastGPULatencyMilliseconds,
            timelineEpoch: timelineEpoch,
            timelineRate: timelineRate
        )
    }

    private let handle: OpaquePointer
    private let displayLayer: AVSampleBufferDisplayLayer
    private let api: MPVApplePictureInPictureAPI
    private let capacity: Int
    private let targetSubmissionInterval: TimeInterval
    private let nativeControlQueue = DispatchQueue(
        label: "mpvkit.gpu-player.native-pip-control",
        qos: .userInitiated
    )
    private var activeGeneration: UInt64?
    private var nativeGeneration: UInt64 = 0
    private var currentMode = modeInline
    private var currentRenderSize = CGSize.zero
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferAuxAttributes: CFDictionary?
    private var pixelBufferFormatDescription: CMVideoFormatDescription?
    private var callbackContext: MPVApplePictureInPictureCallbackContext?
    private struct InFlightTarget {
        let pixelBuffer: CVPixelBuffer
        let submittedAt: CFTimeInterval
    }
    private var inFlightBuffers: [UInt64: InFlightTarget] = [:]
    private var pendingFrames: [UInt64: (CVPixelBuffer, MPVApplePictureInPictureFrameValue)] = [:]
    private var nextToken: UInt64 = 1
    private var preparationContinuation: CheckedContinuation<Void, Error>?
    private var preparationCompleted = false
    private var restoreContinuation: CheckedContinuation<Bool, Never>?
    private var restoreWaitGeneration: UInt64?
    private var restoreResolvedResult: (generation: UInt64, restored: Bool)?
    private var restoreTimeoutTask: Task<Void, Never>?
    private var readinessCallbackArmed = false
    private var timelineRate: Double = 0
    private var timelineNeedsAnchor = true
    private var lastTimebaseDriftCheckTime: CFTimeInterval = 0
    private var lastAppliedTimebaseRate: Double?
    private var timelineEpoch: UInt64 = 0
    private var lastEnqueuedPTS: Double?
    private var lastEnqueuedTimelineEpoch: UInt64 = 0
    private var schedulerCoalescedRequestCount = 0
    private var backpressureDropCount = 0
    private var poolExhaustionDropCount = 0
    private var staleGenerationDropCount = 0
    private var enqueuedFrameCount = 0
    private var lastGPULatencyMilliseconds: Double = 0
    private var isStopInProgress = false
    private var stopOperationGeneration: UInt64 = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingResizeSize: CGSize?
    private var resizeTask: Task<Void, Never>?
    private var isEndingPictureInPicture = false
    private var nativeReconfigurationInProgress = false
    private var targetPreparationInProgress = false
    private var sampleConstructionInProgress = false
    private var flushInProgress = false
    private var flushRequested = false
    private var flushOperationToken: UInt64 = 0
    private var displayRecoveryGate = MPVDisplayLayerRecoveryGate()
    private var displayRecoveryFlushRequested = false
    private var displayRecoveryFlushToken: UInt64?
    private var displayRecoveryFlushGeneration: UInt64?
    private var displayRecoveryProbeGeneration: UInt64?
    private var nextTargetSubmissionTime: CFTimeInterval = 0
    private var targetRefillTimer: DispatchSourceTimer?
    private var targetRefillTimerScheduled = false
    private var targetRefillTimerGeneration: UInt64 = 0
    private var forceNextTargetSubmission = false
    private var poolAllocationRetryGate = MPVLatestDemandRetryGate()
    private var displayReadinessDemand = MPVLatestReadinessDemand()
    private var activePhysicalDisplayFlushCount = 0
    private var nativeStopDrainCompleted = true

    static func make(
        handle: OpaquePointer,
        displayLayer: AVSampleBufferDisplayLayer,
        requestedCapacity: Int,
        preferredFramesPerSecond: Int,
        sourceFramesPerSecond: Double
    ) -> MPVApplePictureInPictureSink? {
        guard let api = MPVApplePictureInPictureAPI.load(),
              api.apiVersion() == apiVersion else { return nil }

        let rawCaps = UnsafeMutableRawPointer.allocate(byteCount: 184, alignment: 8)
        defer { rawCaps.deallocate() }
        rawCaps.initializeMemory(as: UInt8.self, repeating: 0, count: 184)
        rawCaps.storeBytes(of: UInt32(184), as: UInt32.self)
        guard api.getCapabilities(handle, rawCaps) == 0 else { return nil }
        let returnedVersion = rawCaps.load(fromByteOffset: 4, as: UInt32.self)
        let flags = rawCaps.load(fromByteOffset: 8, as: UInt64.self)
        let pixelFormat = rawCaps.load(fromByteOffset: 16, as: UInt32.self)
        let maximumQueued = rawCaps.load(fromByteOffset: 20, as: UInt32.self)
        let supportsDirectIOSurface = flags & directIOSurfaceCapability != 0
        let supportsAsynchronousMetalBlit = flags & asynchronousMetalBlitCapability != 0
        let metalArgumentBuffersEnabled: Bool
        if let value = getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS") {
            metalArgumentBuffersEnabled = String(cString: value) != "0"
        } else {
            // MoltenVK 1.4.1 defaults this setting to enabled.
            metalArgumentBuffersEnabled = true
        }
        let supportsSafeAsynchronousMetalBlit = supportsAsynchronousMetalBlit
            && MPVMoltenVKDevicePolicy.allowsAsynchronousMetalTextureImport(
                metalArgumentBuffersEnabled: metalArgumentBuffersEnabled,
                hasImportedMetalTextureResidencyFix:
                    mpvkitMoltenVKHasImportedTextureResidencyFix
            )
        guard returnedVersion == apiVersion,
              flags & requiredCapabilities == requiredCapabilities,
              supportsDirectIOSurface || supportsSafeAsynchronousMetalBlit,
              pixelFormat == bgraPixelFormat else { return nil }
        let nativeCapacity = maximumQueued > 0 ? Int(maximumQueued) : requestedCapacity
        return MPVApplePictureInPictureSink(
            handle: handle,
            displayLayer: displayLayer,
            api: api,
            capacity: max(1, min(requestedCapacity, nativeCapacity)),
            preferredFramesPerSecond: preferredFramesPerSecond,
            sourceFramesPerSecond: sourceFramesPerSecond,
            backend: supportsDirectIOSurface
                ? .singleSessionGPUDirectIOSurface
                : .singleSessionGPUAsynchronousMetalBlit
        )
    }

    private init(
        handle: OpaquePointer,
        displayLayer: AVSampleBufferDisplayLayer,
        api: MPVApplePictureInPictureAPI,
        capacity: Int,
        preferredFramesPerSecond: Int,
        sourceFramesPerSecond: Double,
        backend: MPVPictureInPictureBackend
    ) {
        self.handle = handle
        self.displayLayer = displayLayer
        self.api = api
        self.capacity = capacity
        let configuredFPS = Double(max(1, preferredFramesPerSecond))
        let effectiveFPS = sourceFramesPerSecond.isFinite && sourceFramesPerSecond > 0
            ? min(configuredFPS, sourceFramesPerSecond)
            : configuredFPS
        self.targetSubmissionInterval = 1 / effectiveFPS
        self.backend = backend
        displayLayer.videoGravity = .resizeAspect
        #if os(macOS)
        displayLayer.backgroundColor = NSColor.black.cgColor
        #else
        displayLayer.backgroundColor = UIColor.black.cgColor
        #endif
        displayLayer.isOpaque = true
    }

    func prepare(generation: UInt64, renderSize: CGSize) async throws {
        if isStopInProgress {
            await waitUntilStopped()
        }
        guard activeGeneration == nil else {
            throw MPVApplePictureInPictureSinkError.nativeCall("prepare", -5)
        }
        activeGeneration = generation
        isEndingPictureInPicture = false
        advanceNativeGeneration()
        timelineEpoch &+= 1
        currentMode = Self.modeWarmup
        currentRenderSize = renderSize
        preparationCompleted = false
        enqueuedFrameCount = 0
        timelineNeedsAnchor = true
        lastTimebaseDriftCheckTime = 0
        lastAppliedTimebaseRate = nil
        lastEnqueuedPTS = nil
        displayReadinessDemand.reset()
        let operationGeneration = stopOperationGeneration
        let resources: PixelBufferPoolResources
        do {
            resources = try await makePoolResources(size: renderSize)
        } catch {
            guard stopOperationGeneration == operationGeneration,
                  activeGeneration == generation,
                  !isStopInProgress else {
                throw MPVApplePictureInPictureSinkError.stopped
            }
            throw error
        }
        guard stopOperationGeneration == operationGeneration,
              activeGeneration == generation,
              !isStopInProgress else {
            throw MPVApplePictureInPictureSinkError.stopped
        }
        pixelBufferPool = resources.pool
        pixelBufferAuxAttributes = resources.auxiliaryAttributes
        pixelBufferFormatDescription = resources.formatDescription
        poolAllocationRetryGate.replaceDemand()
        forceNextTargetSubmission = true
        try installCallback()
        requestTimelineFlush()
        let status = api.setMode(handle, currentMode, nativeGeneration)
        guard status == 0 else {
            stop()
            await waitUntilStopped()
            throw MPVApplePictureInPictureSinkError.nativeCall("set warmup mode", status)
        }
        refillTargetsIfPossible()
        try await withCheckedThrowingContinuation { continuation in
            if preparationCompleted {
                continuation.resume()
            } else if activeGeneration != generation {
                continuation.resume(throwing: MPVApplePictureInPictureSinkError.stopped)
            } else {
                preparationContinuation = continuation
            }
        }
    }

    func begin() throws {
        guard activeGeneration != nil, !isEndingPictureInPicture else {
            throw MPVApplePictureInPictureSinkError.stopped
        }
        if !nativeReconfigurationInProgress {
            let status = api.setMode(handle, Self.modeOffscreen, nativeGeneration)
            guard status == 0 else {
                throw MPVApplePictureInPictureSinkError.nativeCall("set offscreen mode", status)
            }
        }
        currentMode = Self.modeOffscreen
        refillTargetsIfPossible()
    }

    func end(restoringInlinePlayback: Bool) async -> Bool {
        guard let generation = activeGeneration, !isEndingPictureInPicture else {
            return !restoringInlinePlayback
        }
        let operationGeneration = stopOperationGeneration
        isEndingPictureInPicture = true
        pendingResizeSize = nil
        await resizeTask?.value
        guard activeGeneration == generation,
              stopOperationGeneration == operationGeneration,
              !isStopInProgress else { return !restoringInlinePlayback }
        currentMode = restoringInlinePlayback ? Self.modeRestore : Self.modeInline
        advanceNativeGeneration()
        let restoreGeneration = nativeGeneration
        var restored = !restoringInlinePlayback
        if restoringInlinePlayback {
            armRestoreHandshake(generation: restoreGeneration)
        }
        let status = api.setMode(handle, currentMode, restoreGeneration)
        if restoringInlinePlayback {
            if status == 0 {
                timelineEpoch &+= 1
                forceNextTargetSubmission = true
                requestTimelineFlush()
                refillTargetsIfPossible()
                restored = await waitForRestoreFrame(generation: restoreGeneration)
            } else {
                cancelRestoreHandshake()
                onError?(MPVApplePictureInPictureSinkError.nativeCall(
                    "enter restore mode",
                    status
                ).localizedDescription)
            }
        }
        stop()
        await waitUntilStopped()
        return restored
    }

    func updateRenderSize(_ size: CGSize) {
        guard activeGeneration != nil,
              !isEndingPictureInPicture,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 1,
              size.height > 1,
              abs(size.width - currentRenderSize.width) >= 2
                || abs(size.height - currentRenderSize.height) >= 2 else { return }
        pendingResizeSize = size
        if resizeTask != nil {
            schedulerCoalescedRequestCount += 1
            return
        }
        resizeTask = Task { [weak self] in
            await self?.processPendingResize()
        }
    }

    func updateTimeline(position: Double, rate: Double, discontinuity: Bool) {
        timelineRate = rate.isFinite ? max(0, rate) : 0
        if discontinuity {
            timelineEpoch &+= 1
            timelineNeedsAnchor = true
            advanceNativeGeneration()
            forceNextTargetSubmission = true
            poolAllocationRetryGate.replaceDemand()
            if !pendingFrames.isEmpty {
                staleGenerationDropCount += pendingFrames.count
                pendingFrames.removeAll(keepingCapacity: false)
            }
            if activeGeneration != nil,
               !nativeReconfigurationInProgress,
               callbackContext != nil {
                let status = api.setMode(handle, currentMode, nativeGeneration)
                if status != 0 {
                    onError?(MPVApplePictureInPictureSinkError.nativeCall(
                        "advance discontinuity generation",
                        status
                    ).localizedDescription)
                    return
                }
            }
            requestTimelineFlush()
        }
        if let timebase = displayLayer.controlTimebase {
            if discontinuity, position.isFinite {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 60_000))
            }
            applyTimebaseRateIfNeeded(timebase, rate: timelineRate)
        }
        // Timeline/property updates are the demand signal used to retry a pool allocation after
        // AVKit releases a sample. There is intentionally no polling refill timer.
        refillTargetsIfPossible()
    }

    func stop() {
        if isStopInProgress { return }
        guard activeGeneration != nil
                || callbackContext != nil
                || pixelBufferPool != nil
                || nativeReconfigurationInProgress
                || activePhysicalDisplayFlushCount > 0 else {
            preparationContinuation?.resume(throwing: MPVApplePictureInPictureSinkError.stopped)
            preparationContinuation = nil
            preparationCompleted = false
            return
        }
        isStopInProgress = true
        stopOperationGeneration &+= 1
        let stopGeneration = stopOperationGeneration
        activeGeneration = nil
        currentMode = Self.modeInline
        pendingResizeSize = nil
        resizeTask?.cancel()
        resizeTask = nil
        cancelPendingTargetRefill()
        targetRefillTimer?.cancel()
        targetRefillTimer = nil
        nextTargetSubmissionTime = 0
        forceNextTargetSubmission = false
        poolAllocationRetryGate.cancel()
        flushOperationToken &+= 1
        flushInProgress = false
        flushRequested = false
        displayRecoveryGate.cancel()
        displayRecoveryFlushRequested = false
        displayRecoveryFlushToken = nil
        displayRecoveryFlushGeneration = nil
        displayRecoveryProbeGeneration = nil
        stopRequestingDisplayData()
        let retired = detachNativeWork(retiringPool: pixelBufferPool)
        pixelBufferPool = nil
        pixelBufferAuxAttributes = nil
        pixelBufferFormatDescription = nil
        timelineNeedsAnchor = true
        lastTimebaseDriftCheckTime = 0
        lastAppliedTimebaseRate = nil
        lastEnqueuedPTS = nil
        displayLayer.controlTimebase = nil
        preparationContinuation?.resume(throwing: MPVApplePictureInPictureSinkError.stopped)
        preparationContinuation = nil
        preparationCompleted = false
        cancelRestoreHandshake()
        nativeStopDrainCompleted = false
        enqueueNativeDrain(retired: retired) { [weak self] in
            guard let self,
                  self.isStopInProgress,
                  self.stopOperationGeneration == stopGeneration else { return }
            self.nativeStopDrainCompleted = true
            self.finishStoppingIfPossible(generation: stopGeneration)
        }
    }

    func waitUntilStopped() async {
        guard isStopInProgress else { return }
        await withCheckedContinuation { continuation in
            if isStopInProgress {
                stopWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func finishStoppingIfPossible(generation: UInt64) {
        guard isStopInProgress,
              stopOperationGeneration == generation,
              nativeStopDrainCompleted,
              activePhysicalDisplayFlushCount == 0 else { return }
        isStopInProgress = false
        nativeReconfigurationInProgress = false
        targetPreparationInProgress = false
        sampleConstructionInProgress = false
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func waitForRestoreFrame(generation: UInt64) async -> Bool {
        guard restoreWaitGeneration == generation else { return false }
        if let result = restoreResolvedResult, result.generation == generation {
            clearRestoreHandshake()
            return result.restored
        }
        return await withCheckedContinuation { continuation in
            guard restoreWaitGeneration == generation else {
                continuation.resume(returning: false)
                return
            }
            if let result = restoreResolvedResult, result.generation == generation {
                clearRestoreHandshake()
                continuation.resume(returning: result.restored)
                return
            }
            restoreContinuation = continuation
            restoreTimeoutTask?.cancel()
            restoreTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.completeRestoreHandshake(generation: generation, restored: false)
            }
        }
    }

    private func completeRestoreHandshake(generation: UInt64?, restored: Bool) {
        guard let generation, restoreWaitGeneration == generation else { return }
        guard let continuation = restoreContinuation else {
            restoreResolvedResult = (generation, restored)
            return
        }
        clearRestoreHandshake()
        continuation.resume(returning: restored)
    }

    private func armRestoreHandshake(generation: UInt64) {
        cancelRestoreHandshake()
        restoreWaitGeneration = generation
    }

    private func cancelRestoreHandshake() {
        let continuation = restoreContinuation
        clearRestoreHandshake()
        continuation?.resume(returning: false)
    }

    private func clearRestoreHandshake() {
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        restoreContinuation = nil
        restoreWaitGeneration = nil
        restoreResolvedResult = nil
    }

    private final class RetiredNativeWork: @unchecked Sendable {
        let context: MPVApplePictureInPictureCallbackContext?
        let buffers: [CVPixelBuffer]
        let pool: CVPixelBufferPool?

        init(
            context: MPVApplePictureInPictureCallbackContext?,
            buffers: [CVPixelBuffer],
            pool: CVPixelBufferPool?
        ) {
            self.context = context
            self.buffers = buffers
            self.pool = pool
        }
    }

    private func detachNativeWork(retiringPool: CVPixelBufferPool?) -> RetiredNativeWork {
        callbackContext?.deactivate()
        let retired = RetiredNativeWork(
            context: callbackContext,
            buffers: inFlightBuffers.values.map(\.pixelBuffer) + pendingFrames.values.map(\.0),
            pool: retiringPool
        )
        callbackContext = nil
        inFlightBuffers.removeAll(keepingCapacity: false)
        pendingFrames.removeAll(keepingCapacity: false)
        readinessCallbackArmed = false
        displayReadinessDemand.reset()
        return retired
    }

    private func enqueueNativeDrain(
        retired: RetiredNativeWork,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let api = self.api
        let handleAddress = UInt(bitPattern: self.handle)
        nativeControlQueue.async {
            guard let handle = OpaquePointer(bitPattern: handleAddress) else {
                DispatchQueue.main.async { completion() }
                return
            }
            _ = api.disableAndDrain(handle)
            // Keep callback userdata, pool and buffers alive through the native fence drain.
            _ = retired.context
            _ = retired.buffers
            _ = retired.pool
            DispatchQueue.main.async { completion() }
        }
    }

    private func processPendingResize() async {
        guard let generation = activeGeneration,
              let requestedSize = pendingResizeSize else {
            resizeTask = nil
            return
        }
        let operationGeneration = stopOperationGeneration
        pendingResizeSize = nil
        let retiringPool = pixelBufferPool
        do {
            // Allocate the replacement generation immediately. The old pool remains retained by
            // `retired` until gpu-next has completed every old fence and callback.
            let resources = try await makePoolResources(size: requestedSize)
            guard !Task.isCancelled,
                  stopOperationGeneration == operationGeneration,
                  activeGeneration == generation,
                  !isStopInProgress else {
                return
            }
            pixelBufferPool = resources.pool
            pixelBufferAuxAttributes = resources.auxiliaryAttributes
            pixelBufferFormatDescription = resources.formatDescription
            poolAllocationRetryGate.replaceDemand()
            advanceNativeGeneration()
            timelineEpoch &+= 1
            currentRenderSize = requestedSize
        } catch {
            guard stopOperationGeneration == operationGeneration,
                  activeGeneration == generation,
                  !isStopInProgress else { return }
            resizeTask = nil
            onError?(error.localizedDescription)
            return
        }

        stopRequestingDisplayData()
        nativeReconfigurationInProgress = true
        let retired = detachNativeWork(retiringPool: retiringPool)
        await withCheckedContinuation { continuation in
            enqueueNativeDrain(retired: retired) {
                continuation.resume()
            }
        }

        guard !Task.isCancelled,
              stopOperationGeneration == operationGeneration,
              activeGeneration == generation,
              !isStopInProgress else { return }

        // Collapse every size received while the fence drain was running into one pool generation.
        if let newestSize = pendingResizeSize {
            pendingResizeSize = nil
            do {
                let resources = try await makePoolResources(size: newestSize)
                guard !Task.isCancelled,
                      stopOperationGeneration == operationGeneration,
                      activeGeneration == generation,
                      !isStopInProgress else {
                    return
                }
                pixelBufferPool = resources.pool
                pixelBufferAuxAttributes = resources.auxiliaryAttributes
                pixelBufferFormatDescription = resources.formatDescription
                poolAllocationRetryGate.replaceDemand()
                currentRenderSize = newestSize
            } catch {
                guard stopOperationGeneration == operationGeneration,
                      activeGeneration == generation,
                      !isStopInProgress else { return }
                nativeReconfigurationInProgress = false
                resizeTask = nil
                onError?(error.localizedDescription)
                return
            }
        }

        do {
            try installCallback()
            let status = api.setMode(handle, currentMode, nativeGeneration)
            guard status == 0 else {
                throw MPVApplePictureInPictureSinkError.nativeCall(
                    "restore mode after resize",
                    status
                )
            }
            nativeReconfigurationInProgress = false
            resizeTask = nil
            forceNextTargetSubmission = true
            requestTimelineFlush()
            refillTargetsIfPossible()
            if pendingResizeSize != nil {
                resizeTask = Task { [weak self] in
                    await self?.processPendingResize()
                }
            }
        } catch {
            nativeReconfigurationInProgress = false
            resizeTask = nil
            onError?(error.localizedDescription)
        }
    }

    @discardableResult
    private func advanceNativeGeneration() -> UInt64 {
        nativeGeneration &+= 1
        displayRecoveryGate.beginGeneration(nativeGeneration)
        displayRecoveryFlushRequested = false
        displayRecoveryProbeGeneration = nil
        return nativeGeneration
    }

    private func requestTimelineFlush(recoversDisplayRenderer: Bool = false) {
        guard activeGeneration != nil else { return }
        timelineNeedsAnchor = true
        if recoversDisplayRenderer {
            displayRecoveryFlushRequested = true
        }
        if flushInProgress {
            flushRequested = true
            return
        }
        flushInProgress = true
        flushOperationToken &+= 1
        let token = flushOperationToken
        if displayRecoveryFlushRequested {
            displayRecoveryFlushRequested = false
            displayRecoveryFlushToken = token
            displayRecoveryFlushGeneration = nativeGeneration
        }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            activePhysicalDisplayFlushCount += 1
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishPhysicalTimelineFlush(token: token)
                }
            }
        } else {
            displayLayer.flush()
            completeTimelineFlush(token: token)
        }
    }

    private func finishPhysicalTimelineFlush(token: UInt64) {
        activePhysicalDisplayFlushCount = max(0, activePhysicalDisplayFlushCount - 1)
        completeTimelineFlush(token: token)
        if isStopInProgress {
            finishStoppingIfPossible(generation: stopOperationGeneration)
        }
    }

    private func completeTimelineFlush(token: UInt64) {
        guard token == flushOperationToken, activeGeneration != nil else { return }
        if let failure = completeDisplayRendererRecoveryIfNeeded(token: token) {
            flushRequested = false
            flushInProgress = false
            if !pendingFrames.isEmpty {
                staleGenerationDropCount += pendingFrames.count
                pendingFrames.removeAll(keepingCapacity: false)
            }
            handleRenderFailure(failure)
            return
        }
        if flushRequested {
            flushRequested = false
            flushInProgress = false
            requestTimelineFlush()
            return
        }
        flushInProgress = false
        guard displayRendererReadyForMoreMediaData else {
            requestFreshTargetWhenDisplayBecomesReady()
            return
        }
        if consumeFreshDisplayReadinessDemandIfNeeded() {
            refillTargetsIfPossible()
            return
        }
        if let newest = pendingFrames.values.max(by: { $0.1.pts < $1.1.pts }) {
            pendingFrames.removeAll(keepingCapacity: false)
            enqueue(pixelBuffer: newest.0, frame: newest.1)
        }
        refillTargetsIfPossible()
    }

    private func installCallback() throws {
        let context = MPVApplePictureInPictureCallbackContext { [weak self] frame in
            self?.handle(frame)
        }
        callbackContext = context
        let status = api.setCallback(
            handle,
            mpvApplePictureInPictureFrameCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        guard status == 0 else {
            callbackContext = nil
            throw MPVApplePictureInPictureSinkError.nativeCall("set callback", status)
        }
    }

    private final class PixelBufferPoolResources: @unchecked Sendable {
        let pool: CVPixelBufferPool
        let auxiliaryAttributes: CFDictionary
        let formatDescription: CMVideoFormatDescription

        init(
            pool: CVPixelBufferPool,
            auxiliaryAttributes: CFDictionary,
            formatDescription: CMVideoFormatDescription
        ) {
            self.pool = pool
            self.auxiliaryAttributes = auxiliaryAttributes
            self.formatDescription = formatDescription
        }
    }

    private func makePoolResources(size: CGSize) async throws -> PixelBufferPoolResources {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 1,
              size.height > 1 else {
            throw MPVApplePictureInPictureSinkError.unavailable("invalid PiP pool dimensions")
        }
        let maximumDimension = Double(Self.maximumTextureDimension2D(
            for: MTLCreateSystemDefaultDevice()
        ))
        var width = min(maximumDimension, floor(size.width))
        var height = min(maximumDimension, floor(size.height))
        #if os(macOS)
        let pixelLimit = 14_745_600.0
        #else
        let pixelLimit = 8_294_400.0
        #endif
        let pixels = width * height
        if pixels > pixelLimit {
            let scale = sqrt(pixelLimit / pixels)
            width = floor(width * scale)
            height = floor(height * scale)
        }
        let pixelWidth = max(2, Int(width))
        let pixelHeight = max(2, Int(height))
        let capacity = self.capacity
        return try await withCheckedThrowingContinuation { continuation in
            nativeControlQueue.async {
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: pixelWidth,
                    kCVPixelBufferHeightKey: pixelHeight,
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
                ]
                let poolAttributes: [CFString: Any] = [
                    kCVPixelBufferPoolMinimumBufferCountKey: capacity
                ]
                var pool: CVPixelBufferPool?
                let status = CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    poolAttributes as CFDictionary,
                    attributes as CFDictionary,
                    &pool
                )
                guard status == kCVReturnSuccess, let pool else {
                    continuation.resume(
                        throwing: MPVApplePictureInPictureSinkError.pixelBufferPool(status)
                    )
                    return
                }
                let auxiliaryAttributes = [
                    kCVPixelBufferPoolAllocationThresholdKey: capacity
                ] as CFDictionary
                // Every buffer in this pool has identical dimensions, pixel format, and color
                // attachments. Build the compatible format description once per pool generation
                // rather than repeating CoreMedia setup for every PiP frame.
                var seedBuffer: CVPixelBuffer?
                let seedStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault,
                    pool,
                    auxiliaryAttributes,
                    &seedBuffer
                )
                guard seedStatus == kCVReturnSuccess, let seedBuffer else {
                    continuation.resume(
                        throwing: MPVApplePictureInPictureSinkError.pixelBufferPool(seedStatus)
                    )
                    return
                }
                mpvApplyApplePictureInPictureSDRAttachments(to: seedBuffer)
                var formatDescription: CMVideoFormatDescription?
                let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: seedBuffer,
                    formatDescriptionOut: &formatDescription
                )
                guard descriptionStatus == noErr, let formatDescription else {
                    continuation.resume(
                        throwing: MPVApplePictureInPictureSinkError.sampleBuffer(descriptionStatus)
                    )
                    return
                }
                continuation.resume(returning: PixelBufferPoolResources(
                    pool: pool,
                    auxiliaryAttributes: auxiliaryAttributes,
                    formatDescription: formatDescription
                ))
            }
        }
    }

    private static func maximumTextureDimension2D(for device: MTLDevice?) -> CGFloat {
        guard let device else { return 8_192 }
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac1) {
            return 16_384
        }
        return 8_192
    }

    private var targetDemandMode: MPVNativePiPTargetMode {
        switch currentMode {
        case Self.modeWarmup:
            return .warmup
        case Self.modeOffscreen:
            return .offscreen
        case Self.modeRestore:
            return .restore
        default:
            return .inline
        }
    }

    private var shouldSubmitAnotherTarget: Bool {
        MPVNativePiPTargetDemand.shouldSubmit(
            mode: targetDemandMode,
            forced: forceNextTargetSubmission,
            preparationCompleted: preparationCompleted,
            timelineRate: timelineRate,
            restoreFramePending: restoreWaitGeneration == nativeGeneration
        )
    }

    private func cancelPendingTargetRefill() {
        guard targetRefillTimerScheduled else { return }
        targetRefillTimerScheduled = false
        targetRefillTimer?.schedule(deadline: .distantFuture)
    }

    private func scheduleTargetRefill(after delay: TimeInterval, generation: UInt64) {
        let timer: DispatchSourceTimer
        if let targetRefillTimer {
            timer = targetRefillTimer
        } else {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.targetRefillTimerScheduled else { return }
                    self.targetRefillTimerScheduled = false
                    guard self.nativeGeneration == self.targetRefillTimerGeneration,
                          self.activeGeneration != nil else { return }
                    self.refillTargetsIfPossible()
                }
            }
            source.schedule(deadline: .distantFuture)
            source.resume()
            targetRefillTimer = source
            timer = source
        }
        targetRefillTimerGeneration = generation
        targetRefillTimerScheduled = true
        timer.schedule(deadline: .now() + max(0, delay), leeway: .milliseconds(1))
    }

    private func refillTargetsIfPossible() {
        guard activeGeneration != nil,
              !nativeReconfigurationInProgress,
              !flushInProgress else { return }
        guard shouldSubmitAnotherTarget else {
            // A completed warmup frame and a paused/buffering offscreen timeline are idle. Cancel
            // the FPS cap timer immediately so neither state can self-sustain GPU work.
            cancelPendingTargetRefill()
            return
        }
        if recoverDisplayRendererIfNeeded() { return }
        guard displayRendererReadyForMoreMediaData else {
            backpressureDropCount += 1
            requestFreshTargetWhenDisplayBecomesReady()
            return
        }
        _ = consumeFreshDisplayReadinessDemandIfNeeded()
        // Pool capacity bounds AVKit/sample ownership; gpu-next itself receives only one target at
        // a time so duplicate demands can never become parallel renders or conversions.
        guard inFlightBuffers.isEmpty,
              pendingFrames.isEmpty,
              !targetPreparationInProgress,
              !sampleConstructionInProgress else {
            schedulerCoalescedRequestCount += 1
            return
        }
        let now = CACurrentMediaTime()
        if !forceNextTargetSubmission, now < nextTargetSubmissionTime {
            schedulerCoalescedRequestCount += 1
            if !targetRefillTimerScheduled {
                scheduleTargetRefill(
                    after: nextTargetSubmissionTime - now,
                    generation: nativeGeneration
                )
            }
            return
        }
        cancelPendingTargetRefill()
        forceNextTargetSubmission = false
        nextTargetSubmissionTime = now + targetSubmissionInterval
        submitOneTarget()
    }

    private final class AllocatedTarget: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer?
        let status: CVReturn

        init(pixelBuffer: CVPixelBuffer?, status: CVReturn) {
            self.pixelBuffer = pixelBuffer
            self.status = status
        }
    }

    private final class TargetAllocationResources: @unchecked Sendable {
        let pool: CVPixelBufferPool
        let auxiliaryAttributes: CFDictionary

        init(pool: CVPixelBufferPool, auxiliaryAttributes: CFDictionary) {
            self.pool = pool
            self.auxiliaryAttributes = auxiliaryAttributes
        }
    }

    private func submitOneTarget() {
        guard activeGeneration != nil,
              !recoverDisplayRendererIfNeeded(),
              let pool = pixelBufferPool,
              let auxiliaryAttributes = pixelBufferAuxAttributes else { return }
        let token = nextToken
        poolAllocationRetryGate.beginDemand()
        nextToken &+= 1
        let generation = nativeGeneration
        let allocationResources = TargetAllocationResources(
            pool: pool,
            auxiliaryAttributes: auxiliaryAttributes
        )
        let finishAllocation: @MainActor @Sendable (AllocatedTarget) -> Void = { [weak self] result in
            self?.finishTargetAllocation(result, token: token, generation: generation)
        }
        targetPreparationInProgress = true
        nativeControlQueue.async {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                allocationResources.pool,
                allocationResources.auxiliaryAttributes,
                &pixelBuffer
            )
            if let pixelBuffer {
                // Shared-GPU PiP is SDR full-range BGRA8. Explicit tags prevent AVKit from
                // inheriting HDR/unknown metadata during display migration.
                mpvApplyApplePictureInPictureSDRAttachments(to: pixelBuffer)
            }
            let result = AllocatedTarget(pixelBuffer: pixelBuffer, status: status)
            DispatchQueue.main.async { finishAllocation(result) }
        }
    }

    private func finishTargetAllocation(
        _ target: AllocatedTarget,
        token: UInt64,
        generation: UInt64
    ) {
        targetPreparationInProgress = false
        guard activeGeneration != nil,
              generation == nativeGeneration,
              !nativeReconfigurationInProgress,
              callbackContext != nil else {
            staleGenerationDropCount += 1
            return
        }
        if recoverDisplayRendererIfNeeded() { return }
        guard target.status == kCVReturnSuccess, let pixelBuffer = target.pixelBuffer else {
            if target.status == kCVReturnWouldExceedAllocationThreshold {
                poolExhaustionDropCount += 1
                if poolAllocationRetryGate.consumeRetry() {
                    forceNextTargetSubmission = true
                    requestTimelineFlush()
                }
            } else {
                poolAllocationRetryGate.cancel()
                handleRenderFailure("PiP pixel-buffer allocation failed with status \(target.status)")
            }
            return
        }
        poolAllocationRetryGate.complete()
        guard !flushInProgress, displayRendererReadyForMoreMediaData else {
            backpressureDropCount += 1
            if !flushInProgress { armDisplayReadinessCallback() }
            return
        }
        inFlightBuffers[token] = InFlightTarget(
            pixelBuffer: pixelBuffer,
            submittedAt: CACurrentMediaTime()
        )
        let api = self.api
        let handleAddress = UInt(bitPattern: self.handle)
        let pixelFormat = Self.bgraPixelFormat
        let allocatedTarget = target
        let finishSubmission: @MainActor @Sendable (Int32) -> Void = { [weak self] status in
            self?.handleTargetSubmission(status: status, token: token, generation: generation)
        }
        nativeControlQueue.async {
            guard let pixelBuffer = allocatedTarget.pixelBuffer else { return }
            guard let handle = OpaquePointer(bitPattern: handleAddress),
                  let unmanagedSurface = CVPixelBufferGetIOSurface(pixelBuffer) else {
                DispatchQueue.main.async { finishSubmission(-7) }
                return
            }
            let surface = unmanagedSurface.takeUnretainedValue()
            let status = withUnsafeTemporaryAllocation(byteCount: 40, alignment: 8) { target in
                guard let rawTarget = target.baseAddress else { return Int32(-7) }
                rawTarget.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
                rawTarget.storeBytes(of: UInt32(40), toByteOffset: 0, as: UInt32.self)
                rawTarget.storeBytes(
                    of: UInt32(CVPixelBufferGetWidth(pixelBuffer)),
                    toByteOffset: 4,
                    as: UInt32.self
                )
                rawTarget.storeBytes(
                    of: UInt32(CVPixelBufferGetHeight(pixelBuffer)),
                    toByteOffset: 8,
                    as: UInt32.self
                )
                rawTarget.storeBytes(of: pixelFormat, toByteOffset: 12, as: UInt32.self)
                rawTarget.storeBytes(
                    of: Unmanaged.passUnretained(surface).toOpaque(),
                    toByteOffset: 16,
                    as: UnsafeMutableRawPointer.self
                )
                rawTarget.storeBytes(of: token, toByteOffset: 24, as: UInt64.self)
                rawTarget.storeBytes(of: generation, toByteOffset: 32, as: UInt64.self)
                return api.submitTarget(handle, UnsafeRawPointer(rawTarget))
            }
            // A successful submission is completed by the native frame callback. Hopping to the
            // main actor just to execute a success no-op costs one dispatch per PiP frame.
            if status != 0 {
                DispatchQueue.main.async { finishSubmission(status) }
            }
        }
    }

    private func handleTargetSubmission(status: Int32, token: UInt64, generation: UInt64) {
        guard status != 0 else { return }
        inFlightBuffers.removeValue(forKey: token)
        guard generation == nativeGeneration, activeGeneration != nil else {
            staleGenerationDropCount += 1
            return
        }
        if status == -5 || status == 5 {
            schedulerCoalescedRequestCount += 1
        } else {
            handleRenderFailure(
                MPVApplePictureInPictureSinkError.nativeCall("submit IOSurface target", status)
                    .localizedDescription
            )
        }
    }

    private func handle(_ frame: MPVApplePictureInPictureFrameValue) {
        guard activeGeneration != nil else {
            staleGenerationDropCount += 1
            return
        }
        switch MPVNativePiPCallbackDisposition.classify(
            token: frame.token,
            generation: frame.generation,
            currentGeneration: nativeGeneration,
            status: frame.status,
            readyStatus: Self.frameReady
        ) {
        case .inlineRestored:
            completeRestoreHandshake(generation: frame.generation, restored: true)
            return
        case .stale:
            staleGenerationDropCount += 1
            return
        case .surfaceFrame:
            break
        }
        guard let target = inFlightBuffers.removeValue(forKey: frame.token) else {
            staleGenerationDropCount += 1
            return
        }
        let pixelBuffer = target.pixelBuffer
        lastGPULatencyMilliseconds = max(
            0,
            (CACurrentMediaTime() - target.submittedAt) * 1_000
        )
        guard frame.generation == nativeGeneration else {
            staleGenerationDropCount += 1
            refillTargetsIfPossible()
            return
        }
        switch frame.status {
        case Self.frameReady:
            if frame.backend == 1 {
                backend = .singleSessionGPUDirectIOSurface
            } else if frame.backend == 2 {
                backend = .singleSessionGPUAsynchronousMetalBlit
            }
            guard frame.pixelFormat == Self.bgraPixelFormat,
                  frame.pts.isFinite,
                  Int(frame.width) == CVPixelBufferGetWidth(pixelBuffer),
                  Int(frame.height) == CVPixelBufferGetHeight(pixelBuffer) else {
                handleRenderFailure("native PiP returned invalid frame metadata")
                return
            }
            if recoverDisplayRendererIfNeeded(pixelBuffer: pixelBuffer, frame: frame) {
                return
            }
            if !flushInProgress && displayRendererReadyForMoreMediaData {
                enqueue(pixelBuffer: pixelBuffer, frame: frame)
            } else if flushInProgress {
                retainLatestPendingFrame(pixelBuffer: pixelBuffer, frame: frame)
            } else {
                backpressureDropCount += 1
                requestFreshTargetWhenDisplayBecomesReady()
            }
        case Self.frameStale, Self.frameCanceled:
            staleGenerationDropCount += 1
        case Self.frameRenderFailed:
            handleRenderFailure("native gpu-next PiP render failed")
        default:
            handleRenderFailure("native PiP returned unknown frame status \(frame.status)")
        }
        refillTargetsIfPossible()
    }

    private final class SampleConstructionWork: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let frame: MPVApplePictureInPictureFrameValue
        let formatDescription: CMVideoFormatDescription

        init(
            pixelBuffer: CVPixelBuffer,
            frame: MPVApplePictureInPictureFrameValue,
            formatDescription: CMVideoFormatDescription
        ) {
            self.pixelBuffer = pixelBuffer
            self.frame = frame
            self.formatDescription = formatDescription
        }
    }

    private final class PreparedSample: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer?
        let presentationTime: CMTime
        let status: OSStatus

        init(sampleBuffer: CMSampleBuffer?, presentationTime: CMTime, status: OSStatus) {
            self.sampleBuffer = sampleBuffer
            self.presentationTime = presentationTime
            self.status = status
        }
    }

    private func enqueue(pixelBuffer: CVPixelBuffer, frame: MPVApplePictureInPictureFrameValue) {
        if recoverDisplayRendererIfNeeded(pixelBuffer: pixelBuffer, frame: frame) {
            return
        }
        guard let formatDescription = pixelBufferFormatDescription else {
            handleRenderFailure("PiP pixel-buffer format description is unavailable")
            return
        }
        guard !sampleConstructionInProgress else {
            backpressureDropCount += pendingFrames.count
            pendingFrames.removeAll(keepingCapacity: false)
            pendingFrames[frame.token] = (pixelBuffer, frame)
            return
        }
        sampleConstructionInProgress = true
        let work = SampleConstructionWork(
            pixelBuffer: pixelBuffer,
            frame: frame,
            formatDescription: formatDescription
        )
        let finishConstruction: @MainActor @Sendable (PreparedSample) -> Void = { [weak self] result in
            self?.finishSampleConstruction(result, work: work)
        }
        nativeControlQueue.async {
            let pts = CMTime(seconds: work.frame.pts, preferredTimescale: 60_000)
            let duration = work.frame.duration.isFinite && work.frame.duration > 0
                ? CMTime(seconds: work.frame.duration, preferredTimescale: 60_000)
                : .invalid
            var timing = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: work.pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: work.formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            let result = PreparedSample(
                sampleBuffer: sampleBuffer,
                presentationTime: pts,
                status: status
            )
            DispatchQueue.main.async { finishConstruction(result) }
        }
    }

    private func finishSampleConstruction(_ result: PreparedSample, work: SampleConstructionWork) {
        sampleConstructionInProgress = false
        guard activeGeneration != nil, work.frame.generation == nativeGeneration else {
            staleGenerationDropCount += 1
            refillTargetsIfPossible()
            return
        }
        if recoverDisplayRendererIfNeeded(pixelBuffer: work.pixelBuffer, frame: work.frame) {
            return
        }
        guard result.status == noErr, let sampleBuffer = result.sampleBuffer else {
            handleRenderFailure(
                MPVApplePictureInPictureSinkError.sampleBuffer(result.status).localizedDescription
            )
            return
        }
        if flushInProgress {
            retainLatestPendingFrame(pixelBuffer: work.pixelBuffer, frame: work.frame)
            return
        }
        guard displayRendererReadyForMoreMediaData else {
            backpressureDropCount += 1
            requestFreshTargetWhenDisplayBecomesReady()
            return
        }
        if let lastEnqueuedPTS,
           lastEnqueuedTimelineEpoch == timelineEpoch,
           abs(lastEnqueuedPTS - work.frame.pts) < 0.000_001 {
            schedulerCoalescedRequestCount += 1
            refillTargetsIfPossible()
            return
        }
        updateTimebase(for: result.presentationTime)
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            displayLayer.enqueue(sampleBuffer)
        }
        if displayRendererIsFailed {
            _ = recoverDisplayRendererIfNeeded()
            return
        }
        if displayRecoveryProbeGeneration == nativeGeneration {
            displayRecoveryGate.finishRenderingProbeSubmission(generation: nativeGeneration)
            displayRecoveryProbeGeneration = nil
        }
        if displayRenderingStatus == .rendering {
            displayRecoveryGate.markRenderingSucceeded(generation: nativeGeneration)
        }
        lastEnqueuedPTS = work.frame.pts
        lastEnqueuedTimelineEpoch = timelineEpoch
        enqueuedFrameCount += 1
        if !preparationCompleted {
            preparationCompleted = true
            preparationContinuation?.resume()
            preparationContinuation = nil
        }
        if let generation = activeGeneration {
            onFrameEnqueued?(generation)
        }
        if !flushInProgress,
           displayRendererReadyForMoreMediaData,
           let newest = pendingFrames.values.max(by: { $0.1.pts < $1.1.pts }) {
            pendingFrames.removeAll(keepingCapacity: false)
            enqueue(pixelBuffer: newest.0, frame: newest.1)
        } else {
            refillTargetsIfPossible()
        }
    }

    private func updateTimebase(for pts: CMTime) {
        if displayLayer.controlTimebase == nil {
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            ) == noErr {
                displayLayer.controlTimebase = timebase
                timelineNeedsAnchor = true
                lastTimebaseDriftCheckTime = 0
                lastAppliedTimebaseRate = nil
            }
        }
        guard let timebase = displayLayer.controlTimebase else { return }
        let now = CACurrentMediaTime()
        if timelineNeedsAnchor || now - lastTimebaseDriftCheckTime >= 0.25 {
            let current = CMTimebaseGetTime(timebase)
            let drift = abs(CMTimeGetSeconds(current) - CMTimeGetSeconds(pts))
            lastTimebaseDriftCheckTime = now
            if timelineNeedsAnchor || !drift.isFinite || drift > 1 {
                CMTimebaseSetTime(timebase, time: pts)
                timelineNeedsAnchor = false
            }
        }
        applyTimebaseRateIfNeeded(timebase, rate: timelineRate)
    }

    private func applyTimebaseRateIfNeeded(_ timebase: CMTimebase, rate: Double) {
        guard lastAppliedTimebaseRate != rate else { return }
        CMTimebaseSetRate(timebase, rate: rate)
        lastAppliedTimebaseRate = rate
    }

    private func armDisplayReadinessCallback() {
        guard !readinessCallbackArmed, activeGeneration != nil else { return }
        readinessCallbackArmed = true
        let callback: @Sendable () -> Void = { [weak self] in
            // AVFoundation executes this block on the queue supplied below.
            MainActor.assumeIsolated {
                self?.displayRendererBecameReady()
            }
        }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main, using: callback)
        } else {
            displayLayer.requestMediaDataWhenReady(on: .main, using: callback)
        }
    }

    private func displayRendererBecameReady() {
        if recoverDisplayRendererIfNeeded() { return }
        guard displayRendererReadyForMoreMediaData else { return }
        stopRequestingDisplayData()
        readinessCallbackArmed = false
        guard !flushInProgress else { return }
        if consumeFreshDisplayReadinessDemandIfNeeded() {
            refillTargetsIfPossible()
            return
        }
        if let newest = pendingFrames.values.max(by: { $0.1.pts < $1.1.pts }) {
            pendingFrames.removeAll(keepingCapacity: false)
            enqueue(pixelBuffer: newest.0, frame: newest.1)
        }
        refillTargetsIfPossible()
    }

    private func stopRequestingDisplayData() {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        } else {
            displayLayer.stopRequestingMediaData()
        }
    }

    private var displayRendererReadyForMoreMediaData: Bool {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
        }
        return displayLayer.isReadyForMoreMediaData
    }

    private var displayRenderingStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.status
        }
        return displayLayer.status
    }

    private var displayRendererIsFailed: Bool {
        displayRenderingStatus == .failed
    }

    private var displayRendererFailureDescription: String {
        let error: NSError?
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            error = displayLayer.sampleBufferRenderer.error.map { $0 as NSError }
        } else {
            error = displayLayer.error.map { $0 as NSError }
        }
        let detail = error.map { "\($0.domain)#\($0.code)" } ?? "unknown error"
        return "PiP sample-buffer renderer remained failed after recovery flush (\(detail))"
    }

    private func retainLatestPendingFrame(
        pixelBuffer: CVPixelBuffer,
        frame: MPVApplePictureInPictureFrameValue
    ) {
        if !pendingFrames.isEmpty {
            backpressureDropCount += pendingFrames.count
        }
        pendingFrames.removeAll(keepingCapacity: false)
        pendingFrames[frame.token] = (pixelBuffer, frame)
    }

    private func requestFreshTargetWhenDisplayBecomesReady() {
        _ = displayReadinessDemand.request()
        discardPendingFramesForFreshReadinessDemand()
        armDisplayReadinessCallback()
    }

    @discardableResult
    private func consumeFreshDisplayReadinessDemandIfNeeded() -> Bool {
        guard displayReadinessDemand.consume() else { return false }
        if readinessCallbackArmed {
            stopRequestingDisplayData()
            readinessCallbackArmed = false
        }
        discardPendingFramesForFreshReadinessDemand()
        forceNextTargetSubmission = true
        return true
    }

    private func discardPendingFramesForFreshReadinessDemand() {
        guard !pendingFrames.isEmpty else { return }
        backpressureDropCount += pendingFrames.count
        pendingFrames.removeAll(keepingCapacity: false)
    }

    /// Returns true while the display renderer is failed or its one recovery flush is pending.
    /// The caller must not allocate, render, construct, or enqueue another frame in that case.
    private func recoverDisplayRendererIfNeeded(
        pixelBuffer: CVPixelBuffer? = nil,
        frame: MPVApplePictureInPictureFrameValue? = nil
    ) -> Bool {
        guard activeGeneration != nil else { return false }
        let generation = nativeGeneration
        if displayRenderingStatus == .rendering,
           displayRecoveryGate.markRenderingSucceeded(generation: generation) {
            displayRecoveryProbeGeneration = nil
            forceNextTargetSubmission = true
        }
        if displayRendererIsFailed {
            if let pixelBuffer, let frame {
                retainLatestPendingFrame(pixelBuffer: pixelBuffer, frame: frame)
            }
            switch displayRecoveryGate.observeFailure(generation: generation) {
            case .recover:
                stopRequestingDisplayData()
                readinessCallbackArmed = false
                cancelPendingTargetRefill()
                timelineEpoch &+= 1
                timelineNeedsAnchor = true
                lastEnqueuedPTS = nil
                forceNextTargetSubmission = true
                requestTimelineFlush(recoversDisplayRenderer: true)
            case .report:
                if !pendingFrames.isEmpty {
                    staleGenerationDropCount += pendingFrames.count
                    pendingFrames.removeAll(keepingCapacity: false)
                }
                handleRenderFailure(displayRendererFailureDescription)
            case .wait, .terminal, .stale:
                break
            }
            return true
        }

        if displayRecoveryProbeGeneration == generation {
            return false
        }
        if displayRecoveryGate.beginRenderingProbe(generation: generation) {
            displayRecoveryProbeGeneration = generation
            return false
        }
        if displayRecoveryGate.blocksRendering(generation: generation) {
            if let pixelBuffer, let frame {
                retainLatestPendingFrame(pixelBuffer: pixelBuffer, frame: frame)
            }
            return true
        }
        return false
    }

    /// Completes only the recovery attempt associated with this physical flush. An old completion
    /// cannot reset or report against a replacement native generation.
    private func completeDisplayRendererRecoveryIfNeeded(token: UInt64) -> String? {
        guard displayRecoveryFlushToken == token,
              let generation = displayRecoveryFlushGeneration else { return nil }
        displayRecoveryFlushToken = nil
        displayRecoveryFlushGeneration = nil
        switch displayRecoveryGate.complete(
            generation: generation,
            rendererRemainsFailed: displayRendererIsFailed
        ) {
        case .awaitingRendering:
            timelineNeedsAnchor = true
            forceNextTargetSubmission = true
            return nil
        case .failed:
            return displayRendererFailureDescription
        case .stale:
            return nil
        }
    }

    private func handleRenderFailure(_ message: String) {
        if !preparationCompleted {
            preparationContinuation?.resume(
                throwing: MPVApplePictureInPictureSinkError.unavailable(message)
            )
            preparationContinuation = nil
        }
        onError?(message)
    }
}

private struct MPVPictureInPictureRestoreIdentity: Equatable {
    let operationID: UInt64
    let preparationGeneration: UInt64
    let restoringInlinePlayback: Bool
    let backend: MPVPictureInPictureBackend?
    let sinkIdentity: ObjectIdentifier?
}

private struct MPVPictureInPictureRestoreWaiter {
    let operationID: UInt64
    let continuation: CheckedContinuation<Bool, Never>
}

private enum MPVPictureInPictureRestoreStart {
    case completed(Bool)
    case pending(MPVPictureInPictureRestoreIdentity)
}

@MainActor
public final class MPVGPUPlayerRenderer {
    /// Explains why the inline Vulkan/MoltenVK renderer should not be selected on this device.
    /// The sample-buffer renderer remains available on older Apple GPUs and is a safer default
    /// there than asking gpu-next/libplacebo to build a modern Vulkan swapchain.
    public static var inlineGPUUnavailableReason: String? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "Metal is unavailable"
        }
#if targetEnvironment(simulator)
        _ = device
        return nil
#else
        #if os(iOS)
        if MPVMoltenVKDevicePolicy.shouldAvoidInlineGPUOnIPad(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            supportsApple5: device.supportsFamily(.apple5),
            supportsApple6: device.supportsFamily(.apple6)
        ) {
            return "MoltenVK 1.4 is disabled on A12-class iPads due to an upstream GPU device-loss regression"
        }
        #endif
        #if os(macOS) && arch(x86_64)
        guard MPVIntelMacRenderPolicy.supportsInlineGPU(
            supportsMac1: device.supportsFamily(.mac1),
            supportsMac2: device.supportsFamily(.mac2)
        ) else {
            return "the GPU does not support the Mac Metal family"
        }
        #else
        guard device.supportsFamily(.apple4) else {
            return "the GPU predates Apple family 4"
        }
        #endif
        return nil
#endif
    }

    public static var isSupported: Bool {
        inlineGPUUnavailableReason == nil
    }

    public static var supportsPictureInPicture: Bool {
        #if os(macOS) && arch(x86_64)
        return false
        #else
        return true
        #endif
    }

    public static let singleSessionPictureInPictureUnavailableReason =
        "native gpu-next IOSurface sink symbols or a safe direct/asynchronous runtime path are unavailable"

    public let inlineLayer: CAMetalLayer
    public let pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer
    /// The primary mpv handle remains the clock/audio authority in every backend.
    public var currentTime: Double { cachedPosition }
    public var duration: Double { cachedDuration }
    public private(set) var pictureInPictureState: MPVPictureInPictureState = .idle
    public private(set) var selectedPictureInPictureBackend: MPVPictureInPictureBackend?
    public var onStateChange: ((MPVGPUPlayerRendererState) -> Void)?
    public var onPictureInPictureStateChange: ((MPVPictureInPictureState) -> Void)?
    /// Requests that the host-owned AVPictureInPictureController end PiP after both native and
    /// compatibility rendering have failed for the current load.
    public var onPictureInPictureStopRequested: ((String) -> Void)?
    public var onPlaybackEndForGeneration: ((UInt64) -> Void)?
    public var onError: ((String) -> Void)?
    public var onInlineHitchDiagnostic: ((String) -> Void)?
    public var onDiagnostics: ((MPVGPUPlayerRendererDiagnostics) -> Void)?
    /// Fired on the main thread when decoded video parameters may have changed.
    public var onVideoReconfigure: (() -> Void)?
    /// Generation-aware counterpart for hosts that replace loads rapidly and must reject late
    /// FILE_LOADED / VIDEO_RECONFIG events from an older item.
    public var onVideoReconfigureForGeneration: ((UInt64) -> Void)?
    /// Fired only for mpv's generation-matched `MPV_EVENT_VIDEO_RECONFIG`, after the selected
    /// decoder has configured new video output. Unlike `onVideoReconfigureForGeneration`, this
    /// excludes FILE_LOADED and colorspace property notifications and is safe as recovery proof.
    public var onVideoOutputReconfigureForGeneration: ((UInt64) -> Void)?
    /// Fired only after the recovery epoch observes both new configured video output and a fresh
    /// `hwdec-current` value engaged in VideoToolbox. The epoch is returned by the corresponding
    /// recovery submission, preventing an event or cached value from before suspension from
    /// proving recovery; the two mpv signals may arrive in either order.
    public var onHardwareDecoderRecoveryOutput: ((_ generation: UInt64, _ epoch: UInt64) -> Void)?
    /// Reports a causally complete post-epoch VIDEO_RECONFIG + `hwdec-current` observation even
    /// when the decoder is not VideoToolbox. Hosts use the negative observation only after their
    /// bounded proof window, allowing a hardware copy-path retry without accepting stale state.
    public var onHardwareDecoderRecoveryObservation: ((_ generation: UInt64, _ epoch: UInt64, _ decoder: String?) -> Void)?

    private var options: MPVGPUPlayerRendererOptions
    /// The compatibility renderer owns Metal queues, a texture cache, render queues, and a memory
    /// pressure source. Most clients use the native single-session sink, so do not create those
    /// resources until compatibility PiP is actually selected.
    nonisolated(unsafe) private var pictureInPictureRendererStorage: MPVMetalSampleBufferRenderer?
    private var pictureInPictureRenderer: MPVMetalSampleBufferRenderer {
        if let renderer = pictureInPictureRendererStorage { return renderer }
        let renderer = MPVMetalSampleBufferRenderer(
            displayLayer: pictureInPictureDisplayLayer,
            options: compatibilityRendererOptions
        )
        pictureInPictureRendererStorage = renderer
        configurePictureInPictureCallbacks(for: renderer)
        return renderer
    }
    private var videoFilterChain = ""
    private var audioFilterChain: String?
    /// Main-actor owned during life; `deinit` exclusively transfers it into the async drain task.
    nonisolated(unsafe) private var singleSessionPictureInPictureSink: MPVSingleSessionPictureInPictureSink?
    private var eventPump: MPVGPUPlayerEventPump?
    private var playbackEndGate = MPVPlaybackEndGate()
    private var loadIdentityTracker = MPVLoadIdentityTracker()
    private var currentPrimaryLoadIdentity: MPVLoadIdentityTracker.Identity?
    private var hasSubmittedCurrentPrimaryLoad = false
    private var isAwaitingPrimaryFileLoaded = false
    private var nativePictureInPictureProbeGate = MPVNativePiPProbeGate()
    private var pendingNativePictureInPictureProbePrimeCount: Int?
    private var deferredPrimaryLoadActions = MPVGenerationDeferredActions<MPVGPUPlayerDeferredLoadAction>()
    private var mpv: OpaquePointer?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var isCompatibilitySubtitleSessionLoaded = false
    private lazy var externalSubtitles = MPVExternalSubtitleQueue(
        submit: { [weak self] args in
            guard let self else {
                let reply = MPVAsyncCommandReply()
                reply.complete(-1)
                return reply
            }
            return self.submitPrimaryAsyncCommand(args)
        },
        trackIDs: { [weak self] in self?.subtitleTracks().map(\.id) ?? [] },
        selectedTrackID: { [weak self] in self?.currentSubtitleTrackID() ?? -1 },
        applySelection: { [weak self] id in self?.applySubtitleTrack(id) },
        didChange: { [weak self] in
            self?.requestPausedSingleSessionVisualRefresh()
            self?.emitDiagnostics()
        },
        preparation: MPVExternalSubtitlePreparation()
    )
    private var subtitleStyle: MPVMetalSampleBufferSubtitleStyle?
    private var compatibilityVideoSelection = MPVCompatibilityVideoSelectionState()
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var cachedSpeed: Double = 1
    private var cachedEstimatedFramesPerSecond: Double = 0
    private var cachedDroppedVideoFrameCount: Int64 = 0
    private var cachedDelayedVideoFrameCount: Int64 = 0
    private var cachedSeeking = false
    private var cachedContainerFramesPerSecond: Double = 0
    private var cachedVideoCodec = ""
    private var cachedVideoHasDolbyVisionRPU: Bool?
    private var cachedVideoWidth: Int64 = 0
    private var cachedVideoHeight: Int64 = 0
    private var cachedVideoTransferFunction = ""
    private var cachedVideoColorPrimaries = ""
    private var cachedVideoSignalPeak: Double = 0
    private var cachedVideoPixelFormat = ""
    private var cachedHardwareDecoder = ""
    private var videoColorMetadataRefreshWorkItem: DispatchWorkItem?
    private var audioRecoveryBaseline: UInt64 = 0
    private var isPaused = true
    private var isBuffering = false
    private var isRunning = false
    private var isStopping = false
    private var engineGeneration: UInt64 = 0
    private var nextHardwareDecoderRecoveryEpoch: UInt64 = 0
    private var activeHardwareDecoderRecoveryEpoch: UInt64?
    private var activeHardwareDecoderRecoveryGeneration: UInt64?
    private var hardwareDecoderRecoveryProof = MPVHardwareDecoderRecoveryProof()
    private var nextHardwareDecoderRecoveryTransitionID: UInt64 = 0
    private var activeHardwareDecoderRecoveryTransitionID: UInt64?
    private var hardwareDecoderRecoveryInvalidationGeneration: UInt64 = 0
    private var hardwareDecoderRecoveryVideoSelectionIntentGeneration: UInt64 = 0
    private var hardwareDecoderRecoveryTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var hardwareDecoderRecoveryTimeline: (epoch: UInt64, anchor: Double, invalidationGeneration: UInt64)?
    private var hardwareDecoderRecoverySynchronization: (
        epoch: UInt64,
        loadIdentity: MPVLoadIdentityTracker.Identity,
        invalidationGeneration: UInt64,
        selectedVideoTrackID: Int,
        sawSeek: Bool,
        continuation: CheckedContinuation<Bool, Never>
    )?
    private var hardwareDecoderRecoverySynchronizationTimeoutTask: Task<Void, Never>?
    private var foregroundVideoTimelineDiscontinuityGeneration: UInt64 = 0
    private var nextForegroundVideoValidationID: UInt64 = 0
    private var activeForegroundVideoValidationID: UInt64?
    private var activeForegroundVideoValidationGeneration: UInt64?
    private var foregroundVideoValidationAPI: MPVApplePictureInPictureAPI?
    /// Registry access is lock-protected; deinit can only unregister an opaque token.
    nonisolated(unsafe) private var foregroundVideoValidationContext: UnsafeMutableRawPointer?
    private var foregroundVideoValidationTimeoutTask: Task<Void, Never>?
    private var foregroundVideoValidationContinuation: CheckedContinuation<Bool, Never>?
    private var nextAsyncRequestID: UInt64 = 0
    private var pendingAsyncReplies: [UInt64: MPVAsyncCommandReply] = [:]
    private var isPictureInPicturePrepared = false
    private var isPictureInPictureActive = false
    private var pictureInPicturePreparationGeneration: UInt64 = 0
    private var pictureInPicturePreparationStartedAt: CFTimeInterval?
    private var pictureInPicturePreparationLatency: TimeInterval = 0
    private var pictureInPictureFallbackReason: String?
    private var didAttemptSingleSessionBackend = false
    private var didAttemptCompatibilityFailover = false
    private var nativePictureInPictureDiagnosticsThrottle = MPVDiagnosticsEmissionThrottle(
        minimumInterval: 0.5
    )
    private var pendingSingleSessionShutdown: Task<Void, Never>?
    private var singleSessionShutdownGeneration: UInt64 = 0
    private var pendingPrimaryLoadSubmission: Task<Void, Never>?
    private var isPrimaryLoadSubmissionPending = false
    private var pendingSeekAfterPrimaryLoadSubmission: Double?
    private var pictureInPictureRenderSize: CGSize = .zero
    private var pendingPictureInPictureRenderSize: CGSize?
    /// Main-queue owned during life; deinit only cancels the final outstanding item.
    nonisolated(unsafe) private var pictureInPictureResizeWorkItem: DispatchWorkItem?
    private var pictureInPicturePreparationTimeoutTask: Task<Void, Never>?
    private var pictureInPicturePreparationWaiters: [UInt64: [CheckedContinuation<Void, Error>]] = [:]

    private var isPictureInPictureTrackOwnershipIdle: Bool {
        switch pictureInPictureState {
        case .idle, .failed:
            return true
        case .preparing, .ready, .active, .restoring:
            return false
        }
    }
    private var pictureInPictureTimelineUpdateSequence: UInt64 = 0
    private var completedPictureInPictureTimelineUpdateSequence: UInt64 = 0
    private var pictureInPictureTimelineUpdateWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var pendingPictureInPictureBegin = false
    private var pendingCompatibilityStopAfterInlinePresentation = false
    private var compatibilityInlineRestoreAPI: MPVApplePictureInPictureAPI?
    /// Registry access is lock-protected and deinit is the only non-main-actor reader.
    nonisolated(unsafe) private var compatibilityInlineRestoreContext: UnsafeMutableRawPointer?
    private var compatibilityInlineRestoreNativeGeneration: UInt64?
    private var compatibilityInlineRestoreFailureTask: Task<Void, Never>?
    private var nextPictureInPictureRestoreOperationID: UInt64 = 0
    private var activePictureInPictureRestore: MPVPictureInPictureRestoreIdentity?
    private var lastPictureInPictureRestoreResult: (
        identity: MPVPictureInPictureRestoreIdentity,
        restored: Bool
    )?
    private var pictureInPictureRestoreWaiters: [MPVPictureInPictureRestoreWaiter] = []
    private var compatibilityRendererRequiresStopWait = false
    private var compatibilityStopGeneration: UInt64 = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventPumpStopCompleted = true
    private var sampleRendererStopCompleted = true
    private var pendingInlineDrawableSize: CGSize?
    /// Main-queue owned during life; deinit only cancels the final outstanding item.
    nonisolated(unsafe) private var inlineResizeWorkItem: DispatchWorkItem?
    #if os(macOS)
    private weak var appKitView: NSView?
    #endif
    private var inlineResizeRequestCount = 0
    private var inlineResizeApplicationCount = 0
    private var inlineResizeCoalescedCount = 0
    private var pictureInPictureResizeRequestCount = 0
    private var pictureInPictureResizeApplicationCount = 0
    private var pictureInPictureResizeCoalescedCount = 0
    private var state: MPVGPUPlayerRendererState = .idle

    public convenience init(options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()) {
        self.init(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
    }

    public init(
        inlineLayer: CAMetalLayer,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        self.inlineLayer = inlineLayer
        self.pictureInPictureDisplayLayer = pictureInPictureDisplayLayer
        self.options = options
        configureInlineLayer()
    }

    #if os(macOS)
    /// AppKit adapter for Apple Silicon Macs. The host retains scene/window policy and forwards
    /// later bounds changes through `updateInlineLayerLayout`.
    public convenience init(
        view: NSView,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        view.wantsLayer = true
        let metalLayer: CAMetalLayer
        if let existing = view.layer as? CAMetalLayer {
            metalLayer = existing
        } else {
            metalLayer = MPVGPUPlayerMetalLayer()
            view.layer = metalLayer
        }
        self.init(
            inlineLayer: metalLayer,
            pictureInPictureDisplayLayer: pictureInPictureDisplayLayer,
            options: options
        )
        appKitView = view
        updateInlineLayerLayout(
            bounds: view.bounds,
            contentsScale: view.window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1
        )
    }
    #endif

    deinit {
        if let context = compatibilityInlineRestoreContext {
            MPVApplePictureInPictureCallbackRegistry.unregister(context)
        }
        if let context = foregroundVideoValidationContext {
            MPVApplePictureInPictureCallbackRegistry.unregister(context)
        }
        foregroundVideoValidationTimeoutTask?.cancel()
        hardwareDecoderRecoverySynchronizationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask?.cancel()
        inlineResizeWorkItem?.cancel()
        pictureInPictureResizeWorkItem?.cancel()
        let sink = singleSessionPictureInPictureSink
        let earlierShutdown = pendingSingleSessionShutdown
        let pump = eventPump
        let compatibilityRenderer = pictureInPictureRendererStorage
        let asyncReplies = Array(pendingAsyncReplies.values)
        let synchronizationContinuation = hardwareDecoderRecoverySynchronization?.continuation
        Task { @MainActor in
            synchronizationContinuation?.resume(returning: false)
            for reply in asyncReplies { reply.complete(-1) }
            sink?.stop()
            await earlierShutdown?.value
            if let sink { await sink.waitUntilStopped() }
            pump?.stop {}
            compatibilityRenderer?.stop()
        }
    }

    public func updateInlineLayerLayout(bounds: CGRect, contentsScale: CGFloat? = nil) {
        performOnMain {
            guard bounds.origin.x.isFinite,
                  bounds.origin.y.isFinite,
                  bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width >= 0,
                  bounds.height >= 0 else { return }
            let resolvedScale = contentsScale ?? self.presentationScale
            guard resolvedScale.isFinite, resolvedScale > 0 else { return }

            self.inlineResizeRequestCount += 1
            #if os(macOS) && arch(x86_64)
            self.applyIntelInlineLayerLayout(bounds: bounds, presentationScale: resolvedScale)
            #else
            #if os(tvOS)
            let layout = self.resolvedInlineDrawableLayout(
                bounds: bounds.size,
                presentationScale: resolvedScale
            )
            #endif
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            #if os(macOS)
            let hostOwnsLayerGeometry = (self.inlineLayer.delegate as? NSView)?.layer
                === self.inlineLayer
            #else
            let hostOwnsLayerGeometry = (self.inlineLayer.delegate as? UIView)?.layer
                === self.inlineLayer
            #endif
            // A UIView/NSView owns the frame of its backing layer. Writing that frame from the
            // view's layout callback re-enters platform layout (and can recurse until the main
            // thread stack overflows). Standalone hosted sublayers still need explicit sizing.
            if !hostOwnsLayerGeometry {
                self.inlineLayer.frame = bounds
            }
            #if os(tvOS)
            if let layout {
                self.inlineLayer.contentsScale = layout.contentsScale
            }
            #else
            self.inlineLayer.contentsScale = resolvedScale
            #endif
            CATransaction.commit()

            // A zero-sized detached scene keeps its last valid drawable, avoiding a destructive
            // swapchain resize during Stage Manager/scene transitions.
            #if os(tvOS)
            guard let drawableSize = layout?.drawableSize else { return }
            #else
            let requestedSize = CGSize(
                width: bounds.width * resolvedScale,
                height: bounds.height * resolvedScale
            )
            guard let drawableSize = self.validatedInlineDrawableSize(requestedSize) else { return }
            #endif
            self.pendingInlineDrawableSize = drawableSize
            if self.inlineResizeWorkItem != nil {
                self.inlineResizeCoalescedCount += 1
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.applyPendingInlineDrawableSize()
            }
            self.inlineResizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.resolvedInlineResizeDebounceInterval,
                execute: workItem
            )
            #endif
        }
    }

    public func updateOptions(_ newOptions: MPVGPUPlayerRendererOptions) {
        performOnMain {
            guard self.options != newOptions else { return }
            let previousOptions = self.options
            self.options = newOptions
            self.updateCompatibilityRendererOptions()
            if previousOptions.enablesTargetColorspaceHint != newOptions.enablesTargetColorspaceHint {
                self.setStringProperty("target-colorspace-hint", newOptions.enablesTargetColorspaceHint ? "yes" : "no")
            }
            if self.isPictureInPictureActive,
               self.selectedPictureInPictureBackend == .compatibilityDualSession,
               previousOptions.pausesInlineRendererDuringPictureInPicture
                    != newOptions.pausesInlineRendererDuringPictureInPicture {
                if newOptions.pausesInlineRendererDuringPictureInPicture {
                    self.suppressPrimaryVideoForCompatibility()
                } else {
                    self.restorePrimaryVideoAfterCompatibilityIfNeeded()
                }
            }
            self.configureInlineLayer()
            self.emitDiagnostics()
        }
    }

    /// Applies AVKit's requested PiP render size without allowing an unbounded decode surface.
    /// A new size is generation-safe because the sample renderer owns and retires its pixel pools.
    public func updatePictureInPictureRenderSize(_ size: CGSize) {
        performOnMain {
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 1,
                  size.height > 1 else { return }
            self.pictureInPictureResizeRequestCount += 1
            let resolvedSize = self.validatedPictureInPictureRenderSize(size)
            let comparisonSize = self.pendingPictureInPictureRenderSize
                ?? self.pictureInPictureRenderSize
            if !MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: comparisonSize,
                proposed: resolvedSize
            ) {
                self.pictureInPictureResizeCoalescedCount += 1
                return
            }
            self.pendingPictureInPictureRenderSize = resolvedSize
            if self.pictureInPictureResizeWorkItem != nil {
                self.pictureInPictureResizeCoalescedCount += 1
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.applyPendingPictureInPictureRenderSize()
            }
            self.pictureInPictureResizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.resolvedInlineResizeDebounceInterval,
                execute: workItem
            )
        }
    }

    /// Reads the live mpv property instead of the diagnostics cache. Foreground validation uses
    /// this only at a lifecycle boundary, so it adds no steady-state polling cost.
    public func refreshCurrentHardwareDecoder() -> String {
        let decoder = getStringProperty("hwdec-current") ?? ""
        cachedHardwareDecoder = decoder
        return decoder
    }

    /// Proves that the current decoder and inline CAMetalLayer survived a background transition
    /// without changing `vid`, `hwdec`, playback position, or the audio clock. A forced redraw can
    /// present mpv's retained pre-suspension frame, so playing content is accepted only after a
    /// later token-zero presentation is fenced to a higher native VO frame ID. Paused or buffering
    /// playback keeps the validation latch for `play()` rather than manufacturing decoder activity.
    public func validateForegroundVideoAfterSystemResume(
        timeout: TimeInterval = 0.75,
        allowsSoftwareDecoding: Bool = false
    ) async -> MPVGPUPlayerForegroundVideoValidation {
        guard isRunning,
              !isStopping,
              currentURL != nil,
              let handle = mpv,
              let expectedLoadIdentity = currentPrimaryLoadIdentity else {
            return .unavailable
        }
        // The native ABI has one callback slot per mpv handle. A retiring PiP sink clears that
        // slot only after disable-and-drain, so wait before installing the inline validation
        // callback or the old sink can erase it underneath us.
        if let shutdown = pendingSingleSessionShutdown {
            let shutdownGeneration = singleSessionShutdownGeneration
            await shutdown.value
            if singleSessionShutdownGeneration == shutdownGeneration {
                pendingSingleSessionShutdown = nil
            }
        }
        guard !Task.isCancelled,
              isRunning,
              !isStopping,
              currentURL != nil,
              mpv == handle,
              currentPrimaryLoadIdentity == expectedLoadIdentity,
              pendingSingleSessionShutdown == nil else {
            return .unavailable
        }
        guard !isAwaitingPrimaryFileLoaded,
              !isPrimaryLoadSubmissionPending,
              activeHardwareDecoderRecoveryEpoch == nil,
              activeHardwareDecoderRecoveryTransitionID == nil,
              activeForegroundVideoValidationID == nil,
              !isPictureInPicturePrepared,
              !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              activePictureInPictureRestore == nil,
              inlineLayer.drawableSize.width > 1,
              inlineLayer.drawableSize.height > 1 else {
            return .transitionBusy
        }

        let decoder = refreshCurrentHardwareDecoder()
        let expectedVideoTrackID = currentVideoTrackID()
        let expectedAudioTrackID = currentAudioTrackID()
        let expectedInvalidationGeneration = hardwareDecoderRecoveryInvalidationGeneration
        let expectedDiscontinuityGeneration = foregroundVideoTimelineDiscontinuityGeneration
        guard MPVForegroundVideoValidationPolicy.canValidate(
            decoder: decoder,
            allowsSoftwareDecoding: allowsSoftwareDecoding,
            hasSelectedVideo: expectedVideoTrackID >= 0
        ) else {
            return .decoderUnavailable(current: decoder)
        }
        guard !isPaused, !isBuffering else {
            return .playbackDeferred(decoder: decoder)
        }
        guard let api = MPVApplePictureInPictureAPI.load(), api.apiVersion() == 1 else {
            return .unavailable
        }

        let rawCapabilities = UnsafeMutableRawPointer.allocate(byteCount: 184, alignment: 8)
        defer { rawCapabilities.deallocate() }
        rawCapabilities.initializeMemory(as: UInt8.self, repeating: 0, count: 184)
        rawCapabilities.storeBytes(of: UInt32(184), as: UInt32.self)
        guard api.getCapabilities(handle, rawCapabilities) == 0 else {
            return .unavailable
        }
        let capabilities = rawCapabilities.load(fromByteOffset: 8, as: UInt64.self)
        guard capabilities
                & MPVApplePictureInPictureSink.inlineFreshFrameNotificationCapability != 0 else {
            // The legacy token-zero callback can redraw a retained frame. It is intentionally not
            // accepted as decoder proof; hosts fall through to their bounded hardware-only path.
            return .unavailable
        }

        nextForegroundVideoValidationID &+= 1
        if nextForegroundVideoValidationID == 0 { nextForegroundVideoValidationID = 1 }
        let validationID = nextForegroundVideoValidationID
        let nativeGeneration = validationID
        let sourceFPS = cachedEstimatedFramesPerSecond > 0
            ? cachedEstimatedFramesPerSecond
            : cachedContainerFramesPerSecond
        let queuedFrameWindow = sourceFPS.isFinite && sourceFPS > 0 ? 12 / sourceFPS : 1
        let boundedTimeout = min(2, max(0.1, max(timeout, queuedFrameWindow)))

        let presented = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                activeForegroundVideoValidationID = validationID
                activeForegroundVideoValidationGeneration = nativeGeneration
                foregroundVideoValidationAPI = api
                foregroundVideoValidationContinuation = continuation

                let context = MPVApplePictureInPictureCallbackContext { [weak self] frame in
                    guard let self,
                          self.activeForegroundVideoValidationID == validationID,
                          self.activeForegroundVideoValidationGeneration == nativeGeneration,
                          frame.status == 0,
                          frame.token == 0,
                          frame.generation == nativeGeneration else { return }
                    self.finishForegroundVideoValidation(id: validationID, presented: true)
                }
                let contextPointer = MPVApplePictureInPictureCallbackRegistry.register(context)
                foregroundVideoValidationContext = contextPointer

                let callbackStatus = api.setCallback(
                    handle,
                    mpvAppleInlineRestoreFrameCallback,
                    contextPointer
                )
                let modeStatus = callbackStatus == 0
                    ? api.setMode(
                        handle,
                        MPVApplePictureInPictureSink.modeInlineFreshFrame,
                        nativeGeneration
                    )
                    : callbackStatus
                guard callbackStatus == 0, modeStatus == 0 else {
                    finishForegroundVideoValidation(id: validationID, presented: false)
                    return
                }

                foregroundVideoValidationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(boundedTimeout * 1_000_000_000)
                    )
                    guard !Task.isCancelled else { return }
                    self?.finishForegroundVideoValidation(id: validationID, presented: false)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finishForegroundVideoValidation(id: validationID, presented: false)
            }
        }

        guard !Task.isCancelled,
              isRunning,
              !isStopping,
              currentPrimaryLoadIdentity == expectedLoadIdentity,
              hardwareDecoderRecoveryInvalidationGeneration == expectedInvalidationGeneration else {
            return .unavailable
        }
        let confirmedDecoder = refreshCurrentHardwareDecoder()
        guard presented else {
            if isPaused || isBuffering {
                return .playbackDeferred(decoder: confirmedDecoder)
            }
            return .inlinePresentationTimedOut(decoder: confirmedDecoder)
        }
        let hasSameSelectedVideo = expectedVideoTrackID >= 0
            && currentVideoTrackID() == expectedVideoTrackID
        guard MPVForegroundVideoValidationPolicy.isHealthy(
            decoder: confirmedDecoder,
            allowsSoftwareDecoding: allowsSoftwareDecoding,
            hasSelectedVideo: hasSameSelectedVideo,
            presentedFreshFrame: presented
        ) else {
            return .decoderUnavailable(current: confirmedDecoder)
        }
        let speed = getSpeed()
        let observationDuration = min(1, max(0.15, queuedFrameWindow / max(0.1, speed)))
        let tolerance = sourceFPS.isFinite && sourceFPS > 0 ? max(0.25, 2 / sourceFPS) : 0.25
        let timelineHealthy = await validateForegroundPlaybackTimeline(
            loadIdentity: expectedLoadIdentity,
            invalidationGeneration: expectedInvalidationGeneration,
            discontinuityGeneration: expectedDiscontinuityGeneration,
            videoTrackID: expectedVideoTrackID,
            audioTrackID: expectedAudioTrackID,
            minimumObservationDuration: observationDuration,
            synchronizationTolerance: tolerance,
            timeout: max(boundedTimeout, observationDuration + 0.15)
        )
        guard !Task.isCancelled,
              isRunning, !isStopping,
              currentPrimaryLoadIdentity == expectedLoadIdentity,
              hardwareDecoderRecoveryInvalidationGeneration == expectedInvalidationGeneration else {
            return .unavailable
        }
        if isPaused || isBuffering || getFlagProperty("pause") == true
            || getFlagProperty("paused-for-cache") == true {
            return .playbackDeferred(decoder: refreshCurrentHardwareDecoder())
        }
        guard timelineHealthy else {
            return .timelineUnhealthy(decoder: refreshCurrentHardwareDecoder())
        }
        let stableDecoder = refreshCurrentHardwareDecoder()
        guard MPVForegroundVideoValidationPolicy.isHealthy(
            decoder: stableDecoder,
            allowsSoftwareDecoding: allowsSoftwareDecoding,
            hasSelectedVideo: currentVideoTrackID() == expectedVideoTrackID,
            presentedFreshFrame: presented
        ) else { return .decoderUnavailable(current: stableDecoder) }
        return .healthy(decoder: stableDecoder)
    }

    private func validateForegroundPlaybackTimeline(
        loadIdentity: MPVLoadIdentityTracker.Identity,
        invalidationGeneration: UInt64,
        discontinuityGeneration: UInt64,
        videoTrackID: Int,
        audioTrackID: Int,
        minimumObservationDuration: TimeInterval,
        synchronizationTolerance: Double,
        timeout: TimeInterval
    ) async -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        let isCurrent = { [self] in
            !Task.isCancelled && isRunning && !isStopping && currentURL != nil
                && currentPrimaryLoadIdentity == loadIdentity
                && hardwareDecoderRecoveryInvalidationGeneration == invalidationGeneration
                && foregroundVideoTimelineDiscontinuityGeneration == discontinuityGeneration
                && !isAwaitingPrimaryFileLoaded && !isPrimaryLoadSubmissionPending
                && activeHardwareDecoderRecoveryEpoch == nil
                && activeHardwareDecoderRecoveryTransitionID == nil
                && !isPictureInPicturePrepared && !isPictureInPictureActive
                && isPictureInPictureTrackOwnershipIdle
                && pendingSingleSessionShutdown == nil && activePictureInPictureRestore == nil
                && !isPaused && !isBuffering && !cachedSeeking
                && getFlagProperty("pause") == false
                && getFlagProperty("paused-for-cache") != true
                && getFlagProperty("seeking") != true
                && currentVideoTrackID() == videoTrackID
                && currentAudioTrackID() == audioTrackID
        }
        var validation = MPVForegroundTimelineValidation(
            minimumDuration: minimumObservationDuration,
            synchronizationTolerance: synchronizationTolerance
        )
        let uptime = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
        let deadline = uptime() + min(2, timeout)
        while uptime() <= deadline {
            guard isCurrent() else { return false }
            let result = validation.observe(
                uptime: uptime(),
                videoPosition: getDoubleProperty("time-pos"),
                audioPosition: getDoubleProperty("audio-pts"),
                audioVideoDifference: getDoubleProperty("avsync"),
                audioDelay: getDoubleProperty("audio-delay"),
                hasSelectedAudio: audioTrackID >= 0
            )
            switch result {
            case .unhealthy: return false
            case .healthy:
                guard await fencePrimaryVideoSelectionAsync() >= 0, isCurrent() else { return false }
                return validation.observe(
                    uptime: uptime(),
                    videoPosition: getDoubleProperty("time-pos"),
                    audioPosition: getDoubleProperty("audio-pts"),
                    audioVideoDifference: getDoubleProperty("avsync"),
                    audioDelay: getDoubleProperty("audio-delay"),
                    hasSelectedAudio: audioTrackID >= 0
                ) == .healthy
            case .pending: break
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch { return false }
        }
        return false
    }

    private func finishForegroundVideoValidation(id: UInt64, presented: Bool) {
        guard activeForegroundVideoValidationID == id else { return }
        foregroundVideoValidationTimeoutTask?.cancel()
        foregroundVideoValidationTimeoutTask = nil
        if let api = foregroundVideoValidationAPI, let handle = mpv {
            _ = api.setCallback(handle, nil, nil)
        }
        if let context = foregroundVideoValidationContext {
            MPVApplePictureInPictureCallbackRegistry.unregister(context)
        }
        foregroundVideoValidationContext = nil
        foregroundVideoValidationAPI = nil
        activeForegroundVideoValidationID = nil
        activeForegroundVideoValidationGeneration = nil
        let continuation = foregroundVideoValidationContinuation
        foregroundVideoValidationContinuation = nil
        continuation?.resume(returning: presented)
    }

    private func cancelForegroundVideoValidation() {
        guard let id = activeForegroundVideoValidationID else { return }
        finishForegroundVideoValidation(id: id, presented: false)
    }

    /// Recreates the selected video track after the process returns from suspension. VideoToolbox
    /// can invalidate a decoder session while an app is backgrounded even though `hwdec-current`
    /// still briefly reports the old backend. MPVKit first waits for mpv to confirm that the old
    /// track was fully deselected, reapplies the requested VideoToolbox order, and then reselects
    /// the same track without replacing the media or subtitle state.
    ///
    /// A successful submission is not itself decoded-frame proof. Match its epoch against
    /// `onHardwareDecoderRecoveryOutput`; that callback now joins a post-epoch VIDEO_RECONFIG with
    /// a post-epoch VideoToolbox `hwdec-current` value. This method never adds a software decoder
    /// and therefore preserves a host's `hwdec-software-fallback=no` policy.
    @discardableResult
    public func recreateHardwareDecoderAfterSystemResume(
        strategy: MPVGPUPlayerHardwareDecoderRecoveryStrategy = .configuredOrder
    ) async -> MPVGPUPlayerHardwareDecoderRecoverySubmission {
        cancelForegroundVideoValidation()
        let coreStrategy: MPVVideoToolboxDecodePolicy.RecoveryStrategy
        switch strategy {
        case .configuredOrder:
            coreStrategy = .configuredOrder
        case .copyOnly:
            coreStrategy = .copyOnly
        }
        guard let recoverySetting = MPVVideoToolboxDecodePolicy.recoverySetting(
            configuredDecoders: options.hardwareDecoding,
            strategy: coreStrategy
        ) else { return .unavailable }
        guard isRunning, !isStopping, currentURL != nil else { return .unavailable }
        guard activeHardwareDecoderRecoveryEpoch == nil,
              activeHardwareDecoderRecoveryTransitionID == nil else { return .transitionBusy }
        // A retiring native PiP sink still owns the mpv callback/target while disable-and-drain
        // completes. Let the caller's bounded lifecycle retry run after that ownership is idle
        // instead of changing `vid` underneath the retiring sink.
        guard pendingSingleSessionShutdown == nil else { return .transitionBusy }
        guard !isAwaitingPrimaryFileLoaded,
              !isPictureInPicturePrepared,
              !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              activePictureInPictureRestore == nil else { return .transitionBusy }
        let selectedVideoTrack = currentVideoTrackID()
        guard selectedVideoTrack >= 0 else {
            return .unavailable
        }

        guard let expectedLoadIdentity = currentPrimaryLoadIdentity else { return .unavailable }
        let expectedInvalidationGeneration = hardwareDecoderRecoveryInvalidationGeneration
        let expectedVideoSelectionIntentGeneration = hardwareDecoderRecoveryVideoSelectionIntentGeneration
        guard isPaused, !cachedSeeking, getFlagProperty("seeking") != true,
              getFlagProperty("pause") == true,
              let timelineAnchor = hardwareDecoderRecoveryTimelineAnchor() else { return .transitionBusy }
        let selection = String(selectedVideoTrack)

        nextHardwareDecoderRecoveryTransitionID &+= 1
        let transitionID = nextHardwareDecoderRecoveryTransitionID
        activeHardwareDecoderRecoveryTransitionID = transitionID
        defer {
            finishHardwareDecoderRecoveryTransition(transitionID)
        }
        let restoreSelectionIfCurrent = { [self] in
            guard isRunning,
                  !isStopping,
                  currentURL != nil,
                  currentPrimaryLoadIdentity == expectedLoadIdentity,
                  hardwareDecoderRecoveryVideoSelectionIntentGeneration == expectedVideoSelectionIntentGeneration else { return }
            _ = setHardwareDecoderRecoveryVideoSelection(selection)
        }
        guard !Task.isCancelled else { return .cancelled }

        let deselectionStatus = await commandPrimaryAsync(["set", "vid", "no"])
        guard activeHardwareDecoderRecoveryTransitionID == transitionID else {
            return .cancelled
        }
        guard hardwareDecoderRecoveryInvalidationGeneration == expectedInvalidationGeneration else {
            if deselectionStatus >= 0 { restoreSelectionIfCurrent() }
            return .cancelled
        }
        if Task.isCancelled {
            if deselectionStatus >= 0 { restoreSelectionIfCurrent() }
            return .cancelled
        }
        guard deselectionStatus >= 0 else {
            return .commandFailed
        }
        guard isRunning,
              !isStopping,
              currentURL != nil,
              currentPrimaryLoadIdentity == expectedLoadIdentity else {
            restoreSelectionIfCurrent()
            return .transitionBusy
        }
        guard !isAwaitingPrimaryFileLoaded,
              !isPictureInPicturePrepared,
              !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              activeHardwareDecoderRecoveryEpoch == nil,
              activePictureInPictureRestore == nil else {
            restoreSelectionIfCurrent()
            return .transitionBusy
        }

        // The deselection reply proves the command completed; this second ordered request drains
        // the same client event stream while no decoder exists. Only then activate an epoch and
        // synchronously reselect, so a queued pre-suspension VIDEO_RECONFIG cannot be tagged as
        // output from the new decoder and a replacement load cannot overtake the reselect.
        let fenceStatus = await fencePrimaryVideoSelectionAsync()
        guard activeHardwareDecoderRecoveryTransitionID == transitionID else {
            return .cancelled
        }
        guard hardwareDecoderRecoveryInvalidationGeneration == expectedInvalidationGeneration else {
            restoreSelectionIfCurrent()
            return .cancelled
        }
        if Task.isCancelled {
            restoreSelectionIfCurrent()
            return .cancelled
        }
        guard fenceStatus >= 0 else {
            restoreSelectionIfCurrent()
            return .commandFailed
        }
        guard isRunning,
              !isStopping,
              currentURL != nil,
              currentPrimaryLoadIdentity == expectedLoadIdentity else {
            restoreSelectionIfCurrent()
            return .transitionBusy
        }
        guard !isAwaitingPrimaryFileLoaded,
              !isPictureInPicturePrepared,
              !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              activeHardwareDecoderRecoveryEpoch == nil,
              activePictureInPictureRestore == nil else {
            restoreSelectionIfCurrent()
            return .transitionBusy
        }

        nextHardwareDecoderRecoveryEpoch &+= 1
        let epoch = nextHardwareDecoderRecoveryEpoch
        // A pre-suspension diagnostics value cannot participate in proof for this epoch. The
        // callback below is released only after both a fresh VIDEO_RECONFIG and a fresh engaged
        // `hwdec-current` notification arrive, in either order.
        cachedHardwareDecoder = ""
        hardwareDecoderRecoveryProof.reset()
        activeHardwareDecoderRecoveryEpoch = epoch
        activeHardwareDecoderRecoveryGeneration = expectedLoadIdentity.clientGeneration
        hardwareDecoderRecoveryTimeline = (epoch, timelineAnchor, expectedInvalidationGeneration)
        guard commandPrimary(["set", "hwdec", recoverySetting]) >= 0 else {
            _ = setHardwareDecoderRecoveryVideoSelection(selection)
            _ = finishHardwareDecoderRecoveryAttempt(epoch: epoch)
            return .commandFailed
        }
        guard setHardwareDecoderRecoveryVideoSelection(selection) >= 0 else {
            _ = setHardwareDecoderRecoveryVideoSelection(selection)
            _ = finishHardwareDecoderRecoveryAttempt(epoch: epoch)
            return .commandFailed
        }
        return .accepted(epoch: epoch)
    }

    private func hardwareDecoderRecoveryTimelineAnchor() -> Double? {
        let duration = getDoubleProperty("duration")
        let candidates = currentAudioTrackID() >= 0
            ? [getDoubleProperty("audio-pts"), getDoubleProperty("time-pos")]
            : [getDoubleProperty("time-pos")]
        for case let candidate? in candidates {
            guard candidate.isFinite, candidate >= 0 else { continue }
            if let duration, duration.isFinite, duration > 0, candidate >= duration { continue }
            return candidate
        }
        return nil
    }

    public func synchronizeHardwareDecoderRecoveryAfterSystemResume(
        epoch: UInt64,
        timeout: TimeInterval = 4
    ) async -> Bool {
        let selectedVideoTrackID = currentVideoTrackID()
        guard !Task.isCancelled,
              timeout.isFinite, timeout > 0,
              selectedVideoTrackID >= 0,
              isRunning, !isStopping, isPaused,
              currentURL != nil,
              activeHardwareDecoderRecoveryTransitionID == nil,
              activeHardwareDecoderRecoveryEpoch == epoch,
              hardwareDecoderRecoverySynchronization == nil,
              let timeline = hardwareDecoderRecoveryTimeline,
              timeline.epoch == epoch,
              timeline.invalidationGeneration == hardwareDecoderRecoveryInvalidationGeneration,
              let loadIdentity = currentPrimaryLoadIdentity,
              activeHardwareDecoderRecoveryGeneration == loadIdentity.clientGeneration,
              !isAwaitingPrimaryFileLoaded,
              !isPrimaryLoadSubmissionPending,
              !isPictureInPicturePrepared, !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              pendingSingleSessionShutdown == nil,
              activePictureInPictureRestore == nil,
              !cachedSeeking, getFlagProperty("seeking") != true,
              getFlagProperty("pause") == true,
              getFlagProperty("seekable") == true else { return false }
        var synchronizationAnchor = timeline.anchor
        if currentAudioTrackID() >= 0,
           let audioPosition = getDoubleProperty("audio-pts"),
           audioPosition.isFinite, audioPosition >= 0 {
            let duration = getDoubleProperty("duration")
            if let duration, duration.isFinite, duration > 0 {
                if audioPosition < duration { synchronizationAnchor = audioPosition }
            } else {
                synchronizationAnchor = audioPosition
            }
        }
        let fenceStatus = await fencePrimaryVideoSelectionAsync()
        guard fenceStatus >= 0, !Task.isCancelled,
              isRunning, !isStopping, isPaused,
              currentPrimaryLoadIdentity == loadIdentity,
              activeHardwareDecoderRecoveryEpoch == epoch,
              hardwareDecoderRecoverySynchronization == nil,
              hardwareDecoderRecoveryInvalidationGeneration == timeline.invalidationGeneration,
              !isAwaitingPrimaryFileLoaded, !isPrimaryLoadSubmissionPending,
              !isPictureInPicturePrepared, !isPictureInPictureActive,
              isPictureInPictureTrackOwnershipIdle,
              pendingSingleSessionShutdown == nil, activePictureInPictureRestore == nil,
              getFlagProperty("pause") == true,
              getFlagProperty("seeking") != true,
              currentVideoTrackID() == selectedVideoTrackID else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                hardwareDecoderRecoverySynchronization = (
                    epoch, loadIdentity, timeline.invalidationGeneration, selectedVideoTrackID, false, continuation
                )
                hardwareDecoderRecoverySynchronizationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(min(15, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finishHardwareDecoderRecoverySynchronization(epoch: epoch, succeeded: false)
                }
                guard commandPrimary(["seek", "\(synchronizationAnchor)", "absolute+exact"]) >= 0 else {
                    finishHardwareDecoderRecoverySynchronization(epoch: epoch, succeeded: false)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishHardwareDecoderRecoverySynchronization(epoch: epoch, succeeded: false)
            }
        }
    }

    private func finishHardwareDecoderRecoverySynchronization(epoch: UInt64, succeeded: Bool) {
        guard let synchronization = hardwareDecoderRecoverySynchronization,
              synchronization.epoch == epoch else { return }
        hardwareDecoderRecoverySynchronization = nil
        hardwareDecoderRecoverySynchronizationTimeoutTask?.cancel()
        hardwareDecoderRecoverySynchronizationTimeoutTask = nil
        let isCurrent = isRunning && !isStopping && isPaused
            && currentPrimaryLoadIdentity == synchronization.loadIdentity
            && activeHardwareDecoderRecoveryEpoch == epoch
            && hardwareDecoderRecoveryInvalidationGeneration == synchronization.invalidationGeneration
            && !isAwaitingPrimaryFileLoaded && !isPrimaryLoadSubmissionPending
            && !isPictureInPicturePrepared && !isPictureInPictureActive
            && isPictureInPictureTrackOwnershipIdle
            && pendingSingleSessionShutdown == nil && activePictureInPictureRestore == nil
            && getFlagProperty("pause") == true
            && currentVideoTrackID() == synchronization.selectedVideoTrackID
        synchronization.continuation.resume(returning: succeeded && isCurrent)
    }

    private func invalidateHardwareDecoderRecoveryPlaybackIntent() {
        hardwareDecoderRecoveryInvalidationGeneration &+= 1
        if let synchronization = hardwareDecoderRecoverySynchronization {
            finishHardwareDecoderRecoverySynchronization(epoch: synchronization.epoch, succeeded: false)
        }
    }

    @discardableResult
    private func setHardwareDecoderRecoveryVideoSelection(_ selection: String) -> Int32 {
        let status = commandPrimary(["set", "vid", selection])
        if status >= 0 {
            // The temporary `vid=no` property event may be delivered after the synchronous
            // reselect. Keep the compatibility state anchored to the host's intended track; its
            // ordinary property observer will resolve the current primary selection afterward.
            _ = compatibilityVideoSelection.select(selection)
        }
        return status
    }

    private func finishHardwareDecoderRecoveryTransition(_ transitionID: UInt64) {
        guard activeHardwareDecoderRecoveryTransitionID == transitionID else { return }
        activeHardwareDecoderRecoveryTransitionID = nil
        let waiters = hardwareDecoderRecoveryTransitionWaiters
        hardwareDecoderRecoveryTransitionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForHardwareDecoderRecoveryTransition() async {
        while activeHardwareDecoderRecoveryTransitionID != nil, !Task.isCancelled {
            await withCheckedContinuation { continuation in
                guard activeHardwareDecoderRecoveryTransitionID != nil else {
                    continuation.resume()
                    return
                }
                hardwareDecoderRecoveryTransitionWaiters.append(continuation)
            }
        }
    }

    /// Ends an accepted recovery attempt without changing the decoder that now owns the current
    /// track. In mpv, changing `hwdec` reinitializes an active decoder, so a proven copy-path
    /// recovery must remain installed until the next decoder-free load or recovery boundary.
    @discardableResult
    public func finishHardwareDecoderRecoveryAttempt(epoch: UInt64) -> Bool {
        guard activeHardwareDecoderRecoveryEpoch == epoch else { return false }
        finishHardwareDecoderRecoverySynchronization(epoch: epoch, succeeded: false)
        hardwareDecoderRecoveryTimeline = nil
        activeHardwareDecoderRecoveryEpoch = nil
        activeHardwareDecoderRecoveryGeneration = nil
        hardwareDecoderRecoveryProof.reset()
        return true
    }

    /// Gives an imminent PiP transition priority over foreground decoder reconstruction. An
    /// in-flight async deselect observes the invalidation after its next reply and restores the
    /// selected track; an already accepted epoch releases ownership without changing its decoder.
    public func yieldHardwareDecoderRecoveryToPictureInPicture() {
        hardwareDecoderRecoveryInvalidationGeneration &+= 1
        if let epoch = activeHardwareDecoderRecoveryEpoch {
            _ = finishHardwareDecoderRecoveryAttempt(epoch: epoch)
        }
    }

    public func start() throws {
        guard !isRunning else { return }
        guard !isStopping else { throw MPVGPUPlayerRendererError.teardownInProgress }
        guard Self.isSupported else {
            let reason = Self.inlineGPUUnavailableReason ?? "Metal is unavailable"
            updateState(.failed(reason))
            throw MPVMetalSampleBufferRendererError.metalUnavailable
        }

        if let device = MTLCreateSystemDefaultDevice() {
            Self.configureMoltenVKEnvironment(for: device)
        }

        isStopping = false
        audioFilterChain = nil
        updateState(.starting)

        guard let handle = mpv_create() else {
            updateState(.failed("mpv_create failed"))
            throw MPVMetalSampleBufferRendererError.mpvCreationFailed
        }
        mpv = handle

        setOption("terminal", "no", handle: handle)
        // `terminal=no` does not make enabled verbose logging free: mpv still formats accepted
        // messages and serializes them through its root log mutex. Keep normal playback at errors
        // only; hosts that need a trace can override `msg-level` and `terminal` through
        // additionalMPVOptions.
        setOption("msg-level", "all=error")
        setOption("idle", "yes", handle: handle)
        setOption("keep-open", "yes", handle: handle)
        setOption("wid", value: layerWindowID(), handle: handle)
        setOption("vo", "gpu-next", handle: handle)
        setOption("gpu-api", "vulkan", handle: handle)
        setOption("gpu-context", "moltenvk", handle: handle)
        setOption("hwdec", options.hardwareDecoding, handle: handle)
        setOption("profile", options.inlineProfile, handle: handle)
        setOption("vd-lavc-dr", "yes", handle: handle)
        setOption("video-sync", "audio", handle: handle)
        setOption("framedrop", "vo", handle: handle)
        setOption("interpolation", "no", handle: handle)
        #if os(macOS)
        setOption("ao", "avfoundation,coreaudio", handle: handle)
        #else
        setOption("ao", "avfoundation,audiounit", handle: handle)
        #endif
        setOption("apple-compressed-audio", "yes", handle: handle)
        setOption("audio-spdif", "eac3", handle: handle)
        setOption("target-colorspace-hint", options.enablesTargetColorspaceHint ? "yes" : "no", handle: handle)
        setOption("subs-match-os-language", "yes", handle: handle)
        setOption("sub-auto", "fuzzy", handle: handle)
        setOption("subs-fallback", "yes", handle: handle)
        setOption("sub-ass-override", "yes", handle: handle)
        setOption("sub-use-margins", "yes", handle: handle)
        for (name, value) in options.additionalMPVOptions.sorted(by: { $0.key < $1.key }) {
            setOption(name, value, handle: handle)
        }

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            mpv_destroy(handle)
            mpv = nil
            let message = "mpv_initialize failed status=\(initStatus)"
            updateState(.failed(message))
            throw MPVMetalSampleBufferRendererError.mpvInitializationFailed(initStatus)
        }

        _ = mpv_request_log_messages(handle, "warn")
        observeProperties(handle: handle)
        engineGeneration &+= 1
        let eventEngineGeneration = engineGeneration
        let pump = MPVGPUPlayerEventPump(handle: handle) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handle(event, engineGeneration: eventEngineGeneration)
            }
        }
        eventPump = pump
        pump.install()
        audioRecoveryBaseline = MPVAppleAudioRecoveryCounter.current
        isRunning = true
        updateState(.ready)
        emitDiagnostics()
    }

    public func stop() {
        if isStopping { return }
        _ = externalSubtitles.beginGeneration()
        isCompatibilitySubtitleSessionLoaded = false
        cancelForegroundVideoValidation()
        guard isRunning || mpv != nil || eventPump != nil else {
            if state != .stopped { updateState(.stopped) }
            resumeStopWaiters()
            return
        }
        isStopping = true
        engineGeneration &+= 1
        invalidateHardwareDecoderRecoveryPlaybackIntent()
        hardwareDecoderRecoveryTimeline = nil
        activeHardwareDecoderRecoveryEpoch = nil
        activeHardwareDecoderRecoveryGeneration = nil
        hardwareDecoderRecoveryProof.reset()
        resumePendingAsyncReplies(with: -1)
        pendingPrimaryLoadSubmission?.cancel()
        pendingPrimaryLoadSubmission = nil
        isPrimaryLoadSubmissionPending = false
        pendingSeekAfterPrimaryLoadSubmission = nil
        updateState(.stopping)
        resetLoadGenerations()
        inlineResizeWorkItem?.cancel()
        inlineResizeWorkItem = nil
        pendingInlineDrawableSize = nil
        pictureInPictureResizeWorkItem?.cancel()
        pictureInPictureResizeWorkItem = nil
        pendingPictureInPictureRenderSize = nil
        cancelPictureInPictureRestore()
        cancelPictureInPicturePreparation(with: MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded)
        if let sink = singleSessionPictureInPictureSink {
            retireSingleSessionSink(sink)
        }
        singleSessionPictureInPictureSink = nil

        let compatibilityRenderer = pictureInPictureRendererStorage
        compatibilityRenderer?.stop()
        isPictureInPicturePrepared = false
        isPictureInPictureActive = false
        pendingPictureInPictureBegin = false
        updatePictureInPictureState(.idle)

        let pump = eventPump
        eventPump = nil
        mpv = nil
        audioFilterChain = nil
        eventPumpStopCompleted = pump == nil
        sampleRendererStopCompleted = compatibilityRenderer == nil
        let nativeShutdown = pendingSingleSessionShutdown
        Task { [weak self, pump] in
            await nativeShutdown?.value
            guard let pump else {
                self?.eventPumpStopCompleted = true
                self?.finishStopIfPossible()
                return
            }
            pump.stop { [weak self] in
                self?.eventPumpStopCompleted = true
                self?.finishStopIfPossible()
            }
        }

        if let compatibilityRenderer {
            Task { [weak self, compatibilityRenderer] in
                await compatibilityRenderer.waitUntilStopped()
                guard let self else { return }
                self.sampleRendererStopCompleted = true
                self.finishStopIfPossible()
            }
        }
        finishStopIfPossible()
    }

    /// Waits for both libmpv handles to finish their asynchronous queue drains. Calling this when
    /// the renderer is idle or already stopped returns immediately.
    public func waitUntilStopped() async {
        if !isStopping { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    public func load(_ url: URL, headers: [String: String]? = nil) {
        load(url, headers: headers, generation: 0)
    }

    /// Loads an item with a caller-owned identity token. MPV's process-unique playlist entry ID
    /// scopes START_FILE, FILE_LOADED, property, and VIDEO_RECONFIG events to the submitted load,
    /// so an event left over from a replaced item cannot make a newer host load ready.
    public func load(_ url: URL, headers: [String: String]? = nil, generation: UInt64) {
        performOnMain {
            guard !self.isStopping else {
                self.reportError(MPVGPUPlayerRendererError.teardownInProgress.localizedDescription)
                return
            }
            self.cancelForegroundVideoValidation()
            let subtitleBarrier = self.externalSubtitles.beginGeneration()
            self.isCompatibilitySubtitleSessionLoaded = false
            let mustWaitForHardwareDecoderRecovery =
                self.activeHardwareDecoderRecoveryTransitionID != nil
            self.hardwareDecoderRecoveryInvalidationGeneration &+= 1
            self.pendingPrimaryLoadSubmission?.cancel()
            self.pendingPrimaryLoadSubmission = nil
            self.isPrimaryLoadSubmissionPending = false
            self.pendingSeekAfterPrimaryLoadSubmission = nil
            self.currentURL = url
            self.currentHeaders = headers
            if let epoch = self.activeHardwareDecoderRecoveryEpoch {
                _ = self.finishHardwareDecoderRecoveryAttempt(epoch: epoch)
            }
            self.cancelPictureInPictureRestore()
            self.pictureInPicturePreparationGeneration &+= 1
            let preparationGeneration = self.pictureInPicturePreparationGeneration
            self.cancelPictureInPicturePreparation(
                with: MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
            )
            self.pictureInPictureResizeWorkItem?.cancel()
            self.pictureInPictureResizeWorkItem = nil
            self.pendingPictureInPictureRenderSize = nil
            self.restorePrimaryVideoAfterCompatibilityIfNeeded()
            _ = self.compatibilityVideoSelection.beginLoad()
            if self.selectedPictureInPictureBackend == .compatibilityDualSession,
               self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                self.pictureInPictureRenderer.pause()
                self.pictureInPictureRenderer.stop()
                self.observeCompatibilityRendererStop()
            }
            if let sink = self.singleSessionPictureInPictureSink {
                self.retireSingleSessionSink(sink)
            }
            self.singleSessionPictureInPictureSink = nil
            self.isPictureInPicturePrepared = false
            self.isPictureInPictureActive = false
            self.pendingPictureInPictureBegin = false
            self.selectedPictureInPictureBackend = nil
            self.pictureInPictureFallbackReason = nil
            self.didAttemptSingleSessionBackend = false
            self.didAttemptCompatibilityFailover = false
            self.pictureInPicturePreparationLatency = 0
            self.updatePictureInPictureState(.idle)
            self.cachedPosition = 0
            self.cachedDuration = 0
            self.resetCachedVideoProperties()
            self.isBuffering = false
            self.setInlineExtendedDynamicRange(false)
            guard self.mpv != nil else { return }
            if let previousIdentity = self.currentPrimaryLoadIdentity,
               !self.hasSubmittedCurrentPrimaryLoad {
                self.loadIdentityTracker.cancel(previousIdentity)
            }
            let loadIdentity = self.loadIdentityTracker.reserve(clientGeneration: generation)
            self.currentPrimaryLoadIdentity = loadIdentity
            self.hasSubmittedCurrentPrimaryLoad = false
            self.isAwaitingPrimaryFileLoaded = true
            self.nativePictureInPictureProbeGate.beginLoad(sequence: loadIdentity.sequence)
            self.pendingNativePictureInPictureProbePrimeCount = nil
            self.deferredPrimaryLoadActions.beginGeneration(loadIdentity.sequence)
            if let subtitleStyle = self.subtitleStyle {
                _ = self.deferredPrimaryLoadActions.append(
                    .subtitleStyle(subtitleStyle),
                    generation: loadIdentity.sequence
                )
            }
            if !self.videoFilterChain.isEmpty {
                _ = self.deferredPrimaryLoadActions.append(
                    .videoFilterChain(self.videoFilterChain),
                    generation: loadIdentity.sequence
                )
            }
            self.updateState(.loading)
            let shutdown = self.pendingSingleSessionShutdown
            if mustWaitForHardwareDecoderRecovery || shutdown != nil || subtitleBarrier != nil {
                self.isPrimaryLoadSubmissionPending = true
                let engineGeneration = self.engineGeneration
                let submission = Task { @MainActor [weak self] in
                    if let subtitleBarrier {
                        _ = await subtitleBarrier.value()
                    }
                    if mustWaitForHardwareDecoderRecovery {
                        await self?.waitForHardwareDecoderRecoveryTransition()
                    }
                    if let shutdown {
                        await shutdown.value
                    }
                    guard let self,
                          !Task.isCancelled,
                          !self.isStopping,
                          self.engineGeneration == engineGeneration,
                          self.pictureInPicturePreparationGeneration == preparationGeneration,
                          self.currentPrimaryLoadIdentity == loadIdentity else {
                        return
                    }
                    self.pendingPrimaryLoadSubmission = nil
                    self.isPrimaryLoadSubmissionPending = false
                    self.submitPrimaryLoad(url, headers: headers, identity: loadIdentity)
                }
                self.pendingPrimaryLoadSubmission = submission
            } else {
                self.isPrimaryLoadSubmissionPending = false
                self.pendingPrimaryLoadSubmission = nil
                self.submitPrimaryLoad(url, headers: headers, identity: loadIdentity)
            }
        }
    }

    private func submitPrimaryLoad(
        _ url: URL,
        headers: [String: String]?,
        identity: MPVLoadIdentityTracker.Identity
    ) {
        guard currentPrimaryLoadIdentity == identity else { return }
        guard loadIdentityTracker.submit(identity) else { return }
        hasSubmittedCurrentPrimaryLoad = true
        updateHTTPHeaders(headers)
        let target = url.isFileURL ? url.path : url.absoluteString
        let replacedPlaylistEntryID = currentPlaylistEntryID()
        let perFileOptions = [
            "hwdec=\(fixedLengthOptionValue(options.hardwareDecoding))",
            "vid=\(fixedLengthOptionValue(compatibilityVideoSelection.desiredSelection))"
        ].joined(separator: ",")
        let status = command(["loadfile", target, "replace", "-1", perFileOptions])
        if status < 0 {
            loadIdentityTracker.cancel(identity)
            isAwaitingPrimaryFileLoaded = false
            nativePictureInPictureProbeGate.reset()
            pendingNativePictureInPictureProbePrimeCount = nil
            deferredPrimaryLoadActions.cancel()
            if currentPrimaryLoadIdentity == identity {
                currentPrimaryLoadIdentity = nil
            }
            reportError("gpu-next loadfile failed status=\(status)")
        } else {
            if let playlistEntryID = currentPlaylistEntryID(),
               playlistEntryID != replacedPlaylistEntryID {
                loadIdentityTracker.bind(playlistEntryID: playlistEntryID, to: identity)
            }
        }
    }

    private func fixedLengthOptionValue(_ value: String) -> String {
        "%\(value.utf8.count)%\(value)"
    }

    private func retireSingleSessionSink(
        _ sink: MPVSingleSessionPictureInPictureSink,
        cancelsActiveRestore: Bool = true
    ) {
        if cancelsActiveRestore,
           activePictureInPictureRestore?.sinkIdentity == ObjectIdentifier(sink) {
            cancelPictureInPictureRestore()
        }
        sink.onFrameEnqueued = nil
        sink.onError = nil
        sink.stop()
        singleSessionShutdownGeneration &+= 1
        let generation = singleSessionShutdownGeneration
        let earlierShutdown = pendingSingleSessionShutdown
        let shutdown = Task {
            await earlierShutdown?.value
            await sink.waitUntilStopped()
        }
        pendingSingleSessionShutdown = shutdown
        Task { [weak self] in
            await shutdown.value
            guard let self, self.singleSessionShutdownGeneration == generation else { return }
            self.pendingSingleSessionShutdown = nil
        }
    }

    public func play(preservingHardwareDecoderRecovery: Bool = false) {
        performOnMain {
            if !preservingHardwareDecoderRecovery {
                self.invalidateHardwareDecoderRecoveryPlaybackIntent()
            }
            self.isPaused = false
            guard !self.isPrimaryLoadSubmissionPending,
                  !self.isAwaitingPrimaryFileLoaded else {
                self.updateState(.loading)
                return
            }
            self.setFlagProperty("pause", false)
            if self.isBuffering {
                self.updateState(.loading)
            } else if self.isPictureInPictureActive {
                if self.selectedPictureInPictureBackend == .compatibilityDualSession {
                    self.synchronizeCompatibilityPlaybackState(shouldRealign: false)
                }
                self.updateState(.pictureInPicture)
            } else {
                self.updateState(.playing)
            }
            self.updateSingleSessionTimeline(discontinuity: false)
            self.markPictureInPictureTimelineUpdate(requiresFrame: false)
        }
    }

    public func pause(preservingHardwareDecoderRecovery: Bool = false) {
        performOnMain {
            if !preservingHardwareDecoderRecovery {
                self.invalidateHardwareDecoderRecoveryPlaybackIntent()
            }
            self.isPaused = true
            guard !self.isPrimaryLoadSubmissionPending,
                  !self.isAwaitingPrimaryFileLoaded else {
                self.updateState(.loading)
                return
            }
            self.setFlagProperty("pause", true)
            if self.isBuffering {
                self.updateState(.loading)
            } else if self.isPictureInPictureActive {
                if self.selectedPictureInPictureBackend == .compatibilityDualSession {
                    self.synchronizeCompatibilityPlaybackState(shouldRealign: false)
                }
                self.updateState(.pictureInPicture)
            } else {
                self.updateState(.paused)
            }
            self.updateSingleSessionTimeline(discontinuity: false)
            self.markPictureInPictureTimelineUpdate(requiresFrame: false)
        }
    }

    public func seek(to seconds: Double) {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        performOnMain {
            self.cachedPosition = clamped
            self.markPictureInPictureTimelineUpdate(requiresFrame: true)
            guard !self.isPrimaryLoadSubmissionPending,
                  !self.isAwaitingPrimaryFileLoaded else {
                self.pendingSeekAfterPrimaryLoadSubmission = clamped
                return
            }
            self.discardPrematureEOFCacheIfNeeded(beforeSeekingTo: clamped)
            _ = self.command(["seek", "\(clamped)", "absolute+exact"])
            if self.selectedPictureInPictureBackend == .compatibilityDualSession,
               self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                self.pictureInPictureRenderer.seek(to: clamped)
            }
            self.updateSingleSessionTimeline(discontinuity: true)
        }
    }

    private func discardPrematureEOFCacheIfNeeded(beforeSeekingTo target: Double) {
        guard mpvShouldDiscardPrematureEOFCache(
            handle: mpv, mediaURL: currentURL, target: target, duration: cachedDuration
        ) else { return }
        let status = command(["drop-buffers"])
        onInlineHitchDiagnostic?("[MPVKitSeekRecovery] discarded premature EOF cache target=\(target) status=\(status)")
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setSpeed(_ speed: Double) {
        let clamped = speed.isFinite ? max(0.1, speed) : 1
        performOnMain {
            self.cachedSpeed = clamped
            self.setStringProperty("speed", "\(clamped)")
            if self.selectedPictureInPictureBackend == .compatibilityDualSession,
               self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                self.pictureInPictureRenderer.setSpeed(clamped)
            }
            self.updateSingleSessionTimeline(discontinuity: false)
            self.markPictureInPictureTimelineUpdate(requiresFrame: false)
        }
    }

    public func getSpeed() -> Double {
        cachedSpeed
    }

    /// Waits until the most recent PiP seek/clock command visible at invocation has been installed.
    /// Rate-only changes complete after the timebase update; seeks and size epochs complete on the
    /// next current-generation frame. Ending/replacing PiP releases waiters without crossing loads.
    public func waitForPictureInPictureTimelineUpdate() async {
        let sequence = pictureInPictureTimelineUpdateSequence
        guard isPictureInPicturePrepared,
              completedPictureInPictureTimelineUpdateSequence < sequence else { return }
        await withCheckedContinuation { continuation in
            if !isPictureInPicturePrepared
                || completedPictureInPictureTimelineUpdateSequence >= sequence {
                continuation.resume()
            } else {
                pictureInPictureTimelineUpdateWaiters.append((sequence, continuation))
            }
        }
    }

    /// Prepares the selected PiP backend and returns only after a valid, current-generation frame
    /// has reached the AVSampleBufferDisplayLayer.
    public func preparePictureInPicture() async throws {
        guard Self.supportsPictureInPicture else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "MPV picture in picture is unavailable on Intel Macs"
            )
        }
        cancelForegroundVideoValidation()
        guard !isStopping else { throw MPVGPUPlayerRendererError.teardownInProgress }
        guard isRunning else { throw MPVGPUPlayerRendererError.rendererNotRunning }
        guard currentURL != nil else { throw MPVGPUPlayerRendererError.mediaNotLoaded }
        #if os(iOS)
        guard #available(iOS 15.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("iOS 15 or newer is required")
        }
        #elseif os(tvOS)
        guard #available(tvOS 15.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("tvOS 15 or newer is required")
        }
        #elseif os(macOS)
        guard #available(macOS 12.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("macOS 12 or newer is required")
        }
        #endif

        let generation = pictureInPicturePreparationGeneration
        if let shutdown = pendingSingleSessionShutdown {
            let shutdownGeneration = singleSessionShutdownGeneration
            await shutdown.value
            if singleSessionShutdownGeneration == shutdownGeneration {
                pendingSingleSessionShutdown = nil
            }
            guard !Task.isCancelled,
                  !isStopping,
                  isRunning,
                  currentURL != nil,
                  generation == pictureInPicturePreparationGeneration,
                  pendingSingleSessionShutdown == nil else {
                throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
            }
        }
        if activeHardwareDecoderRecoveryTransitionID != nil {
            await waitForHardwareDecoderRecoveryTransition()
            guard !Task.isCancelled,
                  !isStopping,
                  isRunning,
                  currentURL != nil,
                  generation == pictureInPicturePreparationGeneration else {
                throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
            }
        }
        guard activeHardwareDecoderRecoveryTransitionID == nil,
              activeHardwareDecoderRecoveryEpoch == nil else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "video decoder recovery is changing track ownership"
            )
        }
        if let submission = pendingPrimaryLoadSubmission {
            await submission.value
            guard generation == pictureInPicturePreparationGeneration,
                  !isPrimaryLoadSubmissionPending else {
                throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
            }
        }
        if case .restoring(_) = pictureInPictureState {
            throw MPVGPUPlayerRendererError.teardownInProgress
        }
        if case .ready(let readyGeneration) = pictureInPictureState, readyGeneration == generation { return }
        if case .active(let activeGeneration) = pictureInPictureState, activeGeneration == generation { return }

        if compatibilityRendererRequiresStopWait {
            await pictureInPictureRenderer.waitUntilStopped()
            guard generation == pictureInPicturePreparationGeneration else {
                throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
            }
            compatibilityRendererRequiresStopWait = false
        }

        if case .preparing(let preparingGeneration) = pictureInPictureState,
           preparingGeneration == generation {
            try await waitForPictureInPicturePreparation(generation: generation)
            return
        }

        do {
            try startPictureInPicturePreparation(generation: generation, legacyPrimeCount: 2)
        } catch {
            failIfPictureInPicturePreparationIsPending(generation: generation, error: error)
            throw error
        }
        try await waitForPictureInPicturePreparation(generation: generation)
    }

    /// Compatibility entry point. A true return means preparation was accepted, not that a frame
    /// is already ready; new hosts should await `preparePictureInPicture()`.
    @available(*, deprecated, message: "Use preparePictureInPicture() async throws")
    public func prepareForPictureInPictureStart(primeFrameCount: Int = 8) -> Bool {
        guard Self.supportsPictureInPicture,
              !isStopping,
              isRunning,
              currentURL != nil,
              activeHardwareDecoderRecoveryTransitionID == nil,
              activeHardwareDecoderRecoveryEpoch == nil,
              !compatibilityRendererRequiresStopWait,
              !isPrimaryLoadSubmissionPending else { return false }
        if case .restoring(_) = pictureInPictureState { return false }
        let generation = pictureInPicturePreparationGeneration
        switch pictureInPictureState {
        case .ready(let value) where value == generation:
            requestCompatibilityPrime(reason: "gpu-player-pip-prepare", count: primeFrameCount)
            return true
        case .active(let value) where value == generation:
            requestCompatibilityPrime(reason: "gpu-player-pip-prepare", count: primeFrameCount)
            return true
        case .preparing(let value) where value == generation:
            requestCompatibilityPrime(reason: "gpu-player-pip-prepare", count: primeFrameCount)
            return true
        default:
            do {
                try startPictureInPicturePreparation(
                    generation: generation,
                    legacyPrimeCount: min(2, max(1, primeFrameCount))
                )
                return true
            } catch {
                failIfPictureInPicturePreparationIsPending(generation: generation, error: error)
                reportError("PiP prepare failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    public func beginPictureInPicture() {
        guard Self.supportsPictureInPicture else { return }
        cancelForegroundVideoValidation()
        guard !isPrimaryLoadSubmissionPending else { return }
        let generation = pictureInPicturePreparationGeneration
        switch pictureInPictureState {
        case .ready(let value) where value == generation:
            activatePictureInPicture(generation: generation)
        case .preparing(let value) where value == generation:
            pendingPictureInPictureBegin = true
        case .active(let value) where value == generation:
            return
        case .restoring:
            return
        default:
            pendingPictureInPictureBegin = true
            guard !compatibilityRendererRequiresStopWait else {
                pendingPictureInPictureBegin = false
                return
            }
            do {
                try startPictureInPicturePreparation(generation: generation, legacyPrimeCount: 2)
            } catch {
                pendingPictureInPictureBegin = false
                failIfPictureInPicturePreparationIsPending(generation: generation, error: error)
                reportError("PiP prepare failed: \(error.localizedDescription)")
            }
        }
    }

    public func endPictureInPicture(restoringInlinePlayback: Bool = true) {
        Task { [weak self] in
            _ = await self?.endPictureInPictureAndWait(
                restoringInlinePlayback: restoringInlinePlayback
            )
        }
    }

    /// Ends the current PiP cycle and reports whether inline presentation was actually proven.
    /// Native and compatibility backends return true only for their current-generation token-zero
    /// presentation callback. Timeout, replacement, stop, or backend retirement returns false.
    @discardableResult
    public func endPictureInPictureAndWait(
        restoringInlinePlayback: Bool = true
    ) async -> Bool {
        switch beginPictureInPictureRestore(
            restoringInlinePlayback: restoringInlinePlayback
        ) {
        case .completed(let restored):
            return restored
        case .pending(let identity):
            let restored = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let result = lastPictureInPictureRestoreResult,
                       result.identity == identity {
                        continuation.resume(returning: result.restored)
                    } else if activePictureInPictureRestore == identity {
                        pictureInPictureRestoreWaiters.append(MPVPictureInPictureRestoreWaiter(
                            operationID: identity.operationID,
                            continuation: continuation
                        ))
                    } else {
                        continuation.resume(returning: false)
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelPictureInPictureRestoreForTaskCancellation(identity)
                }
            }
            return !Task.isCancelled && restored
        }
    }

    private func beginPictureInPictureRestore(
        restoringInlinePlayback: Bool
    ) -> MPVPictureInPictureRestoreStart {
        if let active = activePictureInPictureRestore {
            let currentSinkIdentity = singleSessionPictureInPictureSink.map(ObjectIdentifier.init)
            if active.preparationGeneration == pictureInPicturePreparationGeneration,
               active.restoringInlinePlayback == restoringInlinePlayback,
               active.backend == selectedPictureInPictureBackend,
               active.sinkIdentity == currentSinkIdentity {
                return .pending(active)
            }
            return .completed(false)
        }

        let generation = pictureInPicturePreparationGeneration
        pendingPictureInPictureBegin = false
        cancelPictureInPicturePreparation(with: MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded)

        if pictureInPictureState == .idle,
           !isPictureInPicturePrepared,
           !isPictureInPictureActive,
           let result = lastPictureInPictureRestoreResult,
           result.identity.preparationGeneration == generation,
           result.identity.restoringInlinePlayback == restoringInlinePlayback,
           result.identity.backend == selectedPictureInPictureBackend,
           result.identity.sinkIdentity
                == singleSessionPictureInPictureSink.map(ObjectIdentifier.init) {
            return .completed(result.restored)
        }
        guard isPictureInPicturePrepared || isPictureInPictureActive else {
            updatePictureInPictureState(.idle)
            return .completed(!restoringInlinePlayback)
        }

        nextPictureInPictureRestoreOperationID &+= 1
        let identity = MPVPictureInPictureRestoreIdentity(
            operationID: nextPictureInPictureRestoreOperationID,
            preparationGeneration: generation,
            restoringInlinePlayback: restoringInlinePlayback,
            backend: selectedPictureInPictureBackend,
            sinkIdentity: singleSessionPictureInPictureSink.map(ObjectIdentifier.init)
        )
        activePictureInPictureRestore = identity
        lastPictureInPictureRestoreResult = nil

        // Preserve the current state, including a pause issued by AVKit while PiP was active.
        let shouldResume = !isPaused
        isPictureInPictureActive = false
        updatePictureInPictureState(.restoring(generation: generation))

        if selectedPictureInPictureBackend == .compatibilityDualSession {
            pictureInPictureRenderer.pause()
            pendingCompatibilityStopAfterInlinePresentation = true
            if restoringInlinePlayback {
                observeCompatibilityInlinePresentation(
                    generation: generation,
                    restoreIdentity: identity
                )
                restorePrimaryVideoAfterCompatibilityIfNeeded()
            } else {
                restorePrimaryVideoAfterCompatibilityIfNeeded()
                finishCompatibilityRestore(
                    generation: generation,
                    restoreIdentity: identity,
                    restored: true
                )
            }
        } else if let sink = singleSessionPictureInPictureSink {
            Task { [weak self, sink] in
                let restored = await sink.end(
                    restoringInlinePlayback: restoringInlinePlayback
                )
                self?.finishSingleSessionRestore(
                    generation: generation,
                    restoreIdentity: identity,
                    restored: restored
                )
            }
        } else {
            finishSingleSessionRestore(
                generation: generation,
                restoreIdentity: identity,
                restored: !restoringInlinePlayback
            )
        }

        if restoringInlinePlayback {
            setFlagProperty("pause", !shouldResume)
            isPaused = !shouldResume
            updateState(isBuffering ? .loading : (shouldResume ? .playing : .paused))
        } else {
            setFlagProperty("pause", true)
            isPaused = true
            updateState(.paused)
        }
        emitDiagnostics()
        return .pending(identity)
    }

    private func completePictureInPictureRestore(
        _ identity: MPVPictureInPictureRestoreIdentity,
        restored: Bool
    ) {
        guard activePictureInPictureRestore == identity else { return }
        activePictureInPictureRestore = nil
        lastPictureInPictureRestoreResult = (identity, restored)
        for waiter in pictureInPictureRestoreWaiters {
            if waiter.operationID == identity.operationID {
                waiter.continuation.resume(returning: restored)
            } else {
                waiter.continuation.resume(returning: false)
            }
        }
        pictureInPictureRestoreWaiters.removeAll(keepingCapacity: false)
    }

    private func cancelPictureInPictureRestore() {
        guard let identity = activePictureInPictureRestore else {
            for waiter in pictureInPictureRestoreWaiters {
                waiter.continuation.resume(returning: false)
            }
            pictureInPictureRestoreWaiters.removeAll(keepingCapacity: false)
            lastPictureInPictureRestoreResult = nil
            return
        }
        completePictureInPictureRestore(identity, restored: false)
    }

    /// Task cancellation represents a newer lifecycle owner (most commonly foreground returning
    /// to background). Retire the in-flight native sink instead of allowing its old inline restore
    /// to keep the renderer in `.restoring` and block the newer PiP cycle.
    private func cancelPictureInPictureRestoreForTaskCancellation(
        _ identity: MPVPictureInPictureRestoreIdentity
    ) {
        guard activePictureInPictureRestore == identity else { return }
        pendingPictureInPictureBegin = false

        if identity.backend == .compatibilityDualSession {
            pendingCompatibilityStopAfterInlinePresentation = false
            cancelCompatibilityInlinePresentationProbe()
            pictureInPictureRenderer.stop()
            observeCompatibilityRendererStop()
        } else if let sink = singleSessionPictureInPictureSink,
                  ObjectIdentifier(sink) == identity.sinkIdentity {
            singleSessionPictureInPictureSink = nil
            selectedPictureInPictureBackend = nil
            didAttemptSingleSessionBackend = false
            retireSingleSessionSink(sink, cancelsActiveRestore: false)
        }

        isPictureInPicturePrepared = false
        isPictureInPictureActive = false
        updatePictureInPictureState(.idle)
        emitDiagnostics()
        completePictureInPictureRestore(identity, restored: false)
    }

    @discardableResult
    public func command(_ args: [String]) -> Int32 {
        if let operation = args.first?.lowercased(),
           ["seek", "revert-seek", "frame-step", "frame-back-step"].contains(operation)
            || (["set", "set_property", "cycle"].contains(operation)
                && args.count > 1 && args[1].lowercased() == "pause") {
            invalidateHardwareDecoderRecoveryPlaybackIntent()
        }
        if let selection = explicitVideoTrackSelection(in: args) {
            return setDesiredVideoTrackSelection(selection)
        }
        let targetsVideoTrack = commandTargetsVideoTrack(args)
        if targetsVideoTrack {
            hardwareDecoderRecoveryVideoSelectionIntentGeneration &+= 1
            invalidateHardwareDecoderRecoveryPlaybackIntent()
        } else if args.count >= 2,
                  ["set", "set_property", "add", "multiply", "cycle", "cycle-values"]
                    .contains(args[0].lowercased()),
                  args[1].lowercased() == "aid" {
            invalidateHardwareDecoderRecoveryPlaybackIntent()
        }
        if targetsVideoTrack, compatibilityVideoSelection.isInlineSuppressed {
            guard selectedPictureInPictureBackend == .compatibilityDualSession,
                  isPictureInPicturePrepared || isPictureInPictureActive else { return -1 }
            let status = pictureInPictureRenderer.command(args)
            if status >= 0 {
                _ = compatibilityVideoSelection.select(
                    pictureInPictureRenderer.currentVideoTrackSelection()
                )
            }
            return status
        }
        let status = commandPrimary(args)
        if status >= 0, targetsVideoTrack {
            compatibilityVideoSelection.observePrimarySelection(getStringProperty("vid"))
        }
        if status >= 0, isSafeCompatibilityVisualCommand(args) {
            if selectedPictureInPictureBackend == .compatibilityDualSession,
               isPictureInPicturePrepared || isPictureInPictureActive {
                _ = pictureInPictureRenderer.command(args)
            } else {
                requestPausedSingleSessionVisualRefresh()
            }
        }
        return status
    }

    private func explicitVideoTrackSelection(in args: [String]) -> String? {
        guard args.count >= 3,
              ["set", "set_property"].contains(args[0].lowercased()),
              args[1].lowercased() == "vid" else { return nil }
        return args[2]
    }

    private func commandTargetsVideoTrack(_ args: [String]) -> Bool {
        guard args.count >= 2,
              ["set", "set_property", "add", "multiply", "cycle", "cycle-values"]
                .contains(args[0].lowercased()) else { return false }
        return args[1].lowercased() == "vid"
    }

    private func commandPrimary(_ args: [String]) -> Int32 {
        guard let handle = mpv, !args.isEmpty else { return -1 }
        return command(handle: handle, args: args)
    }

    private func commandPrimaryAsync(_ args: [String]) async -> Int32 {
        guard !Task.isCancelled else { return -1 }
        let reply = submitPrimaryAsyncCommand(args)
        return await withTaskCancellationHandler {
            await reply.value()
        } onCancel: {
            Task { @MainActor in reply.abort() }
        }
    }

    private func fencePrimaryVideoSelectionAsync() async -> Int32 {
        guard !Task.isCancelled, let handle = mpv, !isStopping else { return -1 }
        nextAsyncRequestID &+= 1
        let requestID = nextAsyncRequestID
        let reply = MPVAsyncCommandReply()
        pendingAsyncReplies[requestID] = reply
        let status = "vid".withCString {
            mpv_get_property_async(handle, requestID, $0, MPV_FORMAT_STRING)
        }
        if status < 0 {
            pendingAsyncReplies.removeValue(forKey: requestID)?.complete(status)
        }
        return await reply.value()
    }

    private func submitPrimaryAsyncCommand(_ args: [String]) -> MPVAsyncCommandReply {
        guard let handle = mpv, !isStopping, !args.isEmpty else {
            let reply = MPVAsyncCommandReply()
            reply.complete(-1)
            return reply
        }
        nextAsyncRequestID &+= 1
        let requestID = nextAsyncRequestID
        let generation = engineGeneration
        let reply = MPVAsyncCommandReply { [weak self] in
            guard let self,
                  self.engineGeneration == generation,
                  self.pendingAsyncReplies[requestID] != nil,
                  let activeHandle = self.mpv else { return }
            mpv_abort_async_command(activeHandle, requestID)
        }
        pendingAsyncReplies[requestID] = reply
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        let status = mpv_command_async(handle, requestID, &cargs)
        for pointer in cargs where pointer != nil {
            free(UnsafeMutablePointer(mutating: pointer))
        }
        if status < 0 {
            pendingAsyncReplies.removeValue(forKey: requestID)?.complete(status)
        }
        return reply
    }

    private func resumePendingAsyncReplies(with status: Int32) {
        let replies = Array(pendingAsyncReplies.values)
        pendingAsyncReplies.removeAll(keepingCapacity: false)
        for reply in replies {
            reply.complete(status)
        }
    }

    private func isSafeCompatibilityVisualCommand(_ args: [String]) -> Bool {
        guard let operation = args.first?.lowercased() else { return false }
        if ["vf", "sub-add", "sub-remove", "sub-reload", "sub-seek", "sub-step"].contains(operation) {
            return true
        }
        guard ["set", "set_property", "add", "multiply", "cycle", "cycle-values"]
            .contains(operation), args.count >= 2 else {
            return false
        }
        let property = args[1].lowercased()
        return property.hasPrefix("sub-")
            || property.hasPrefix("secondary-sub-")
            || property.hasPrefix("osd-")
            || property == "sid"
            || property == "secondary-sid"
            || property == "vf"
            || property == "deinterlace"
            || property.hasPrefix("video-aspect")
            || property.hasPrefix("video-align")
            || property.hasPrefix("video-pan")
            || property.hasPrefix("video-zoom")
            || property.hasPrefix("video-rotate")
            || property == "vid"
            || property == "speed"
    }

    /// Primes additional frames into the PiP sample-buffer renderer without re-preparing it.
    /// No-op until PiP has been prepared. Used to accumulate buffered frames before the
    /// AVPictureInPictureController hand-off, matching the sample-buffer path's multi-prime warmup.
    @available(*, deprecated, message: "Use preparePictureInPicture() async throws")
    public func primePictureInPictureFrames(reason: String, count: Int = 6) {
        performOnMain {
            self.requestCompatibilityPrime(reason: reason, count: count)
        }
    }

    private func requestCompatibilityPrime(reason: String, count: Int) {
        guard selectedPictureInPictureBackend == .compatibilityDualSession,
              isPictureInPicturePrepared || isPictureInPictureActive else { return }
        pictureInPictureRenderer.primeCompatibilityFrames(
            reason: reason,
            count: min(2, max(1, count))
        )
    }

    /// Sets the mpv audio-filter chain (`af`) on the inline renderer and keeps it so the PiP
    /// renderer. The compatibility PiP instance is video-only; audio and its filters remain owned
    /// by the primary handle. Pass an empty string to clear all filters.
    public func setAudioFilterChain(_ chain: String) {
        performOnMain {
            guard self.audioFilterChain != chain else { return }
            guard self.setStringProperty("af", chain) >= 0 else { return }
            self.audioFilterChain = chain
        }
    }

    /// Sets the video-filter chain on both visual outputs while the compatibility bridge is in
    /// use. The primary handle remains authoritative; the mirrored chain only keeps PiP pixels
    /// visually consistent.
    public func setVideoFilterChain(_ chain: String) {
        performOnMain {
            self.videoFilterChain = chain
            guard !self.deferPrimaryLoadActionIfNeeded(.videoFilterChain(chain)) else { return }
            self.applyVideoFilterChain(chain)
        }
    }

    public func audioTracks() -> [MPVMetalSampleBufferTrack] {
        fetchTrackList().filter { $0.type == "audio" }
    }

    public func videoTracks() -> [MPVMetalSampleBufferTrack] {
        fetchTrackList().filter { $0.type == "video" }
    }

    public func subtitleTracks() -> [MPVMetalSampleBufferTrack] {
        fetchTrackList().filter { $0.type == "sub" }
    }

    public func currentAudioTrackID() -> Int {
        fetchTrackList().first { $0.type == "audio" && $0.selected }?.id ?? -1
    }

    public func currentVideoTrackID() -> Int {
        if compatibilityVideoSelection.isInlineSuppressed {
            return Int(compatibilityVideoSelection.desiredSelection) ?? -1
        }
        return fetchTrackList().first { $0.type == "video" && $0.selected }?.id ?? -1
    }

    public func currentSubtitleTrackID() -> Int {
        fetchTrackList().first { $0.type == "sub" && $0.selected }?.id ?? -1
    }

    public func setAudioTrack(id: Int) {
        invalidateHardwareDecoderRecoveryPlaybackIntent()
        guard !deferPrimaryLoadActionIfNeeded(.audioTrack(id)) else { return }
        applyAudioTrack(id)
    }

    public func setVideoTrack(id: Int) {
        _ = setDesiredVideoTrackSelection(id < 0 ? "no" : "\(id)")
    }

    public func selectAutomaticVideoTrack() {
        _ = setDesiredVideoTrackSelection("auto")
    }

    public func setSubtitleTrack(id: Int) {
        externalSubtitles.select(externalSubtitles.selection(forTrackID: id))
        if isCompatibilitySubtitleSessionLoaded {
            pictureInPictureRenderer.restoreSubtitleSelectionIntent(externalSubtitles.selectionIntent)
        }
    }

    public func disableSubtitles() {
        setSubtitleTrack(id: -1)
    }

    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true,
                                      headersByURL: [String: [String: String]]? = nil) {
        let requests = externalSubtitleRequests(urls: urls, headersByURL: headersByURL)
        let batch = MPVExternalSubtitleQueue.Batch(urls: urls, names: names, selectFirst: selectFirst, requests: requests)
        externalSubtitles.enqueue(batch)
        if isCompatibilitySubtitleSessionLoaded {
            pictureInPictureRenderer.enqueueExternalSubtitles(externalSubtitles.batches.last ?? batch)
        }
    }

    public func prefetchExternalSubtitles(urls: [String], headersByURL: [String: [String: String]]? = nil,
                                          allowsCellularAccess: Bool = false) {
        externalSubtitles.prefetch(externalSubtitleRequests(urls: Array(urls.prefix(4)), headersByURL: headersByURL)
            .map { .init(request: $0, allowsCellularAccess: allowsCellularAccess) })
    }

    public func currentExternalSubtitleURL() -> String? {
        externalSubtitles.currentExternalSubtitleURL()
    }

    private func externalSubtitleRequests(urls: [String], headersByURL: [String: [String: String]]?)
        -> [MPVExternalSubtitleRequest] {
        let unsupported = ["cookies-file", "http-proxy", "tls-ca-file", "tls-cert-file", "tls-key-file", "stream-lavf-o"]
            .contains { !(getStringProperty($0) ?? "").isEmpty }
            || getStringProperty("cookies") == "yes"
        let userAgent = getStringProperty("user-agent")
        let referrer = getStringProperty("referrer")
        return urls.map {
            .make(url: $0, headersByURL: headersByURL, mediaURL: currentURL,
                  mediaHeaders: currentHeaders, userAgent: userAgent, referrer: referrer,
                  permitsPreparation: !unsupported)
        }
    }

    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) {
        subtitleStyle = style
        guard !deferPrimaryLoadActionIfNeeded(.subtitleStyle(style)) else { return }
        applySubtitleStyleImmediately(style)
    }

    private func deferPrimaryLoadActionIfNeeded(_ action: MPVGPUPlayerDeferredLoadAction) -> Bool {
        guard isAwaitingPrimaryFileLoaded, let identity = currentPrimaryLoadIdentity else {
            return false
        }
        return deferredPrimaryLoadActions.append(action, generation: identity.sequence)
    }

    private func applyDeferredPrimaryLoadActions(identity: MPVLoadIdentityTracker.Identity) {
        for action in deferredPrimaryLoadActions.drain(generation: identity.sequence) {
            switch action {
            case .videoTrack(let selection):
                _ = applyVideoTrackSelection(selection)
            case .audioTrack(let id):
                applyAudioTrack(id)
            case .subtitleStyle(let style):
                applySubtitleStyleImmediately(style)
            case .videoFilterChain(let chain):
                applyVideoFilterChain(chain)
            }
        }
    }

    @discardableResult
    private func setDesiredVideoTrackSelection(_ selection: String) -> Int32 {
        hardwareDecoderRecoveryVideoSelectionIntentGeneration &+= 1
        invalidateHardwareDecoderRecoveryPlaybackIntent()
        _ = compatibilityVideoSelection.select(selection)
        let normalized = compatibilityVideoSelection.desiredSelection
        if deferPrimaryLoadActionIfNeeded(.videoTrack(normalized)) { return 0 }
        return applyVideoTrackSelection(normalized)
    }

    @discardableResult
    private func applyVideoTrackSelection(_ selection: String) -> Int32 {
        let primarySelection = compatibilityVideoSelection.select(selection)
        let status = primarySelection.map { commandPrimary(["set", "vid", $0]) } ?? 0
        guard status >= 0 else { return status }
        if selectedPictureInPictureBackend == .compatibilityDualSession,
           isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.setVideoTrackSelection(
                compatibilityVideoSelection.desiredSelection
            )
        }
        requestPausedSingleSessionVisualRefresh()
        return status
    }

    private func suppressPrimaryVideoForCompatibility() {
        let suppressedSelection = compatibilityVideoSelection.suppressInline(
            observedPrimarySelection: getStringProperty("vid")
        )
        // Install the exact resolved track on the already-ready fallback before disabling the
        // primary. A host track change from this point forward updates only the fallback/desired
        // value until restoration.
        pictureInPictureRenderer.setVideoTrackSelection(
            compatibilityVideoSelection.desiredSelection
        )
        setStringProperty("vid", suppressedSelection)
    }

    private func restorePrimaryVideoAfterCompatibilityIfNeeded() {
        guard let selection = compatibilityVideoSelection.restoreInline() else { return }
        setStringProperty("vid", selection)
    }

    private func applyAudioTrack(_ id: Int) {
        setStringProperty("aid", id < 0 ? "no" : "\(id)")
    }

    private func applySubtitleTrack(_ id: Int) {
        setStringProperty("sid", id < 0 ? "no" : "\(id)")
        requestPausedSingleSessionVisualRefresh()
    }

    private func applySubtitleStyleImmediately(_ style: MPVMetalSampleBufferSubtitleStyle) {
        let fontSize = style.fontSize.isFinite ? max(1, Int(style.fontSize)) : 36
        let strokeWidth = style.strokeWidth.isFinite ? max(0, style.strokeWidth) : 0
        let delay = style.delaySeconds.isFinite ? max(-60, min(style.delaySeconds, 60)) : 0
        setStringProperty("sub-delay", "\(delay)")
        setStringProperty("sub-visibility", style.isVisible ? "yes" : "no")
        setStringProperty("sub-font-size", "\(fontSize)")
        setStringProperty("sub-border-size", "\(strokeWidth)")
        setStringProperty("sub-color", mpvColorString(style.foregroundColor))
        setStringProperty("sub-border-color", mpvColorString(style.strokeColor))
        if let position = style.position, position.isFinite {
            setStringProperty("sub-pos", "\(max(0, min(position, 100)))")
        }
        if let margin = style.verticalMargin, margin.isFinite {
            let pixels = Int(max(0, min(margin, 720)).rounded())
            setStringProperty("sub-margin-y", "\(pixels)")
            setStringProperty("sub-ass-style-overrides", margin < 34 ? "MarginV=\(pixels)" : "")
        }
        if let assOverride = style.assOverride,
           ["no", "yes", "scale", "force", "strip"].contains(assOverride) {
            setStringProperty("sub-ass-override", assOverride)
        }
        if let captionBackground = style.captionBackground {
            setStringProperty("sub-border-style", captionBackground ? "background-box" : "outline-and-shadow")
            setStringProperty("sub-back-color", captionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0")
            setStringProperty("sub-shadow-offset", "0")
        }
        if selectedPictureInPictureBackend == .compatibilityDualSession,
           isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.applySubtitleStyle(style)
        }
        requestPausedSingleSessionVisualRefresh()
    }

    private func applyVideoFilterChain(_ chain: String) {
        setStringProperty("vf", chain)
        if selectedPictureInPictureBackend == .compatibilityDualSession,
           isPictureInPicturePrepared || isPictureInPictureActive {
            _ = pictureInPictureRenderer.command(["set", "vf", chain])
        }
        requestPausedSingleSessionVisualRefresh()
    }

    public func diagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        let compatibilityIsRunning = compatibilityRendererRequiresStopWait
            || (selectedPictureInPictureBackend == .compatibilityDualSession
                && (isPictureInPicturePrepared || isPictureInPictureActive))
        let compatibilityDiagnostics = compatibilityIsRunning
            ? pictureInPictureRenderer.diagnosticsSnapshot()
            : nil
        let nativeDiagnostics = selectedPictureInPictureBackend != .compatibilityDualSession
            ? singleSessionPictureInPictureSink?.diagnostics
            : nil
        let preparationLatency = pictureInPicturePreparationStartedAt.map {
            max(pictureInPicturePreparationLatency, CACurrentMediaTime() - $0)
        } ?? pictureInPicturePreparationLatency
        let audioRecoveryValue = MPVAppleAudioRecoveryCounter.current
        let audioRecoveryDelta = audioRecoveryValue >= audioRecoveryBaseline
            ? audioRecoveryValue - audioRecoveryBaseline
            : 0
        return MPVGPUPlayerRendererDiagnostics(
            state: state,
            presentationMode: isPictureInPictureActive ? .pictureInPictureSampleBuffer : .inlineGPU,
            currentTime: currentTime,
            duration: duration,
            isPaused: isPaused,
            inlineVideoOutput: "gpu-next",
            inlineGPUAPI: "vulkan",
            inlineGPUContext: "moltenvk",
            pictureInPictureDiagnostics: compatibilityDiagnostics,
            backendDescription: backendDescription,
            pictureInPictureState: pictureInPictureState,
            pictureInPictureBackendPreference: options.pictureInPictureBackendPreference,
            selectedPictureInPictureBackend: selectedPictureInPictureBackend,
            pictureInPictureFallbackReason: pictureInPictureFallbackReason,
            activeMPVInstanceCount: (isRunning ? 1 : 0) + (compatibilityIsRunning ? 1 : 0),
            pictureInPicturePreparationGeneration: pictureInPicturePreparationGeneration,
            pictureInPicturePreparationLatency: preparationLatency,
            inlineResizeRequestCount: inlineResizeRequestCount,
            inlineResizeApplicationCount: inlineResizeApplicationCount,
            inlineResizeCoalescedCount: inlineResizeCoalescedCount,
            pictureInPictureResizeRequestCount: pictureInPictureResizeRequestCount,
            pictureInPictureResizeApplicationCount: pictureInPictureResizeApplicationCount,
            pictureInPictureResizeCoalescedCount: pictureInPictureResizeCoalescedCount,
            maximumInlineDrawablePixelCount: resolvedMaximumInlineDrawablePixelCount,
            schedulerCoalescedRequestCount: nativeDiagnostics?.schedulerCoalescedRequestCount
                ?? compatibilityDiagnostics?.coalescedRenderRequestCount
                ?? 0,
            backpressureDropCount: nativeDiagnostics?.backpressureDropCount
                ?? compatibilityDiagnostics?.backpressureDropCount
                ?? 0,
            poolExhaustionDropCount: nativeDiagnostics?.poolExhaustionDropCount
                ?? compatibilityDiagnostics?.poolExhaustionDropCount
                ?? 0,
            staleGenerationDropCount: nativeDiagnostics?.staleGenerationDropCount
                ?? compatibilityDiagnostics?.staleGenerationDropCount
                ?? 0,
            inFlightGPUFrameCount: nativeDiagnostics?.inFlightGPUFrameCount
                ?? compatibilityDiagnostics?.inFlightGPUFrameCount
                ?? 0,
            pictureInPictureEnqueuedFrameCount: nativeDiagnostics?.enqueuedFrameCount
                ?? compatibilityDiagnostics?.frameCount
                ?? 0,
            lastGPULatencyMilliseconds: nativeDiagnostics?.lastGPULatencyMilliseconds
                ?? compatibilityDiagnostics?.lastGPULatencyMilliseconds
                ?? 0,
            timelineEpoch: nativeDiagnostics?.timelineEpoch
                ?? compatibilityDiagnostics?.timelineEpoch
                ?? 0,
            timelineRate: nativeDiagnostics?.timelineRate
                ?? compatibilityDiagnostics?.timelineRate
                ?? 0,
            audioRecoveryCount: Int(min(audioRecoveryDelta, UInt64(Int.max))),
            estimatedFramesPerSecond: cachedEstimatedFramesPerSecond > 0
                ? cachedEstimatedFramesPerSecond
                : cachedContainerFramesPerSecond,
            droppedVideoFrameCount: Int(clamping: cachedDroppedVideoFrameCount),
            delayedVideoFrameCount: Int(clamping: cachedDelayedVideoFrameCount),
            videoCodec: cachedVideoCodec,
            videoHasDolbyVisionRPU: cachedVideoHasDolbyVisionRPU,
            videoWidth: Int(cachedVideoWidth),
            videoHeight: Int(cachedVideoHeight),
            videoTransferFunction: cachedVideoTransferFunction,
            videoColorPrimaries: cachedVideoColorPrimaries,
            videoSignalPeak: cachedVideoSignalPeak,
            videoPixelFormat: cachedVideoPixelFormat,
            hardwareDecoder: cachedHardwareDecoder
        )
    }

    public func frameDeliveryDiagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        refreshCachedFrameDeliveryDiagnostics()
        return diagnosticsSnapshot()
    }

    public func inlineRenderPasses(includeRedraw: Bool = false) -> [MPVGPUPlayerRenderPass] {
        guard let handle = mpv, isRunning, !isStopping else { return [] }
        var node = mpv_node()
        let status = "vo-passes".withCString {
            mpv_get_property(handle, $0, MPV_FORMAT_NODE, &node)
        }
        guard status >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_MAP,
              let root = node.u.list,
              let rootKeys = root.pointee.keys,
              let rootValues = root.pointee.values else { return [] }
        var passNodes: [mpv_node] = []
        for index in 0..<min(16, max(0, Int(root.pointee.num))) {
            guard let key = rootKeys[index] else { continue }
            let stage = String(cString: key)
            guard stage == "fresh" || (includeRedraw && stage == "redraw") else { continue }
            let stageNode = rootValues[index]
            guard stageNode.format == MPV_FORMAT_NODE_ARRAY,
                  let list = stageNode.u.list,
                  let values = list.pointee.values else { continue }
            for passIndex in 0..<min(128 - passNodes.count, max(0, Int(list.pointee.num))) {
                passNodes.append(values[passIndex])
            }
        }
        var passes: [MPVGPUPlayerRenderPass] = []
        for item in passNodes {
            guard item.format == MPV_FORMAT_NODE_MAP,
                  let map = item.u.list,
                  let keys = map.pointee.keys,
                  let entries = map.pointee.values else { continue }
            var description = ""
            var sampleCount = 0
            var lastNanoseconds: Int64 = 0
            for entryIndex in 0..<min(16, max(0, Int(map.pointee.num))) {
                guard let keyPointer = keys[entryIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = entries[entryIndex]
                switch key {
                case "desc":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string {
                        description = String(String(cString: string).prefix(512))
                    }
                case "count":
                    if value.format == MPV_FORMAT_INT64 {
                        sampleCount = max(0, Int(clamping: value.u.int64))
                    }
                case "last":
                    if value.format == MPV_FORMAT_INT64 {
                        lastNanoseconds = max(0, value.u.int64)
                    }
                default:
                    break
                }
            }
            guard !description.isEmpty else { continue }
            passes.append(MPVGPUPlayerRenderPass(
                description: description,
                sampleCount: sampleCount,
                lastNanoseconds: lastNanoseconds
            ))
        }
        return passes
    }

    public func playbackDiagnosticSnapshot() -> String {
        refreshCachedFrameDeliveryDiagnostics()
        func decimal(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "na" }
            return String(format: "%.3f", value)
        }

        let audioPTS = getDoubleProperty("audio-pts")
        let avSync = getDoubleProperty("avsync")
        let decoderDrops = getInt64Property("decoder-frame-drop-count") ?? 0
        let mistimedFrames = getInt64Property("mistimed-frame-count") ?? 0
        let cacheDuration = getDoubleProperty("demuxer-cache-duration")
        let cacheEnd = getDoubleProperty("demuxer-cache-time")
        let cacheState = getInt64Property("cache-buffering-state") ?? 0
        let cacheSpeed = getInt64Property("cache-speed") ?? 0
        let cacheIdle = getFlagProperty("demuxer-cache-idle") ?? false
        let coreIdle = getFlagProperty("core-idle") ?? false
        let speed = String(format: "%.2f", cachedSpeed)
        let codec = cachedVideoCodec.isEmpty ? "na" : cachedVideoCodec
        let hardwareDecoder = cachedHardwareDecoder.isEmpty ? "na" : cachedHardwareDecoder
        return "position=\(decimal(cachedPosition)) audioPTS=\(decimal(audioPTS)) avsync=\(decimal(avSync)) speed=\(speed) decoderDrops=\(decoderDrops) voDrops=\(cachedDroppedVideoFrameCount) delayed=\(cachedDelayedVideoFrameCount) mistimed=\(mistimedFrames) paused=\(isPaused) cachePaused=\(isBuffering) seeking=\(cachedSeeking) coreIdle=\(coreIdle) cacheIdle=\(cacheIdle) cacheDuration=\(decimal(cacheDuration)) cacheEnd=\(decimal(cacheEnd)) cacheState=\(cacheState) cacheBytesPerSecond=\(cacheSpeed) state=\(String(describing: state)) codec=\(codec) hwdec=\(hardwareDecoder)"
    }

    private func configureInlineLayer() {
        inlineLayer.framebufferOnly = true
        #if os(macOS)
        inlineLayer.backgroundColor = NSColor.black.cgColor
        #if arch(x86_64)
        applyIntelInlineLayerLayout(bounds: inlineLayer.bounds, presentationScale: presentationScale)
        #else
        inlineLayer.contentsScale = presentationScale
        #endif
        #else
        inlineLayer.backgroundColor = UIColor.black.cgColor
        #if os(tvOS)
        if let layout = resolvedInlineDrawableLayout(
            bounds: inlineLayer.bounds.size,
            presentationScale: presentationScale
        ) {
            inlineLayer.contentsScale = layout.contentsScale
            pendingInlineDrawableSize = layout.drawableSize
            inlineResizeWorkItem?.cancel()
            applyPendingInlineDrawableSize()
        }
        #else
        inlineLayer.contentsScale = presentationScale
        #endif
        #endif
        setInlineExtendedDynamicRange(shouldEnableInlineExtendedDynamicRange)
    }

    private static func configureMoltenVKEnvironment(for device: MTLDevice) {
        // Unmarked MoltenVK 1.4.1 predates the imported-MTLTexture residency fix. The native direct
        // backend can fall back to that path after capability selection, so every device disables
        // argument buffers in that configuration. A provenance-marked local rebuild contains the
        // fix; only Apple-5 GPUs retain their independent workaround there.
        let shouldDisableArgumentBuffers = MPVMoltenVKDevicePolicy
            .shouldDisableMetalArgumentBuffers(
                supportsApple5: device.supportsFamily(.apple5),
                supportsApple6: device.supportsFamily(.apple6),
                hasImportedMetalTextureResidencyFix:
                    mpvkitMoltenVKHasImportedTextureResidencyFix
            )
        if shouldDisableArgumentBuffers {
            // This is a crash-prevention constraint for the bundled runtime, not a tuning default.
            _ = setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 1)
        }

        _ = setenv("PL_VK_DEFER_SUBMITS", "0", 1)
    }

    private var shouldEnableInlineExtendedDynamicRange: Bool {
        guard options.enablesTargetColorspaceHint else { return false }
        let transfer = cachedVideoTransferFunction.lowercased()
        return cachedVideoSignalPeak > 1
            || transfer.contains("pq")
            || transfer.contains("hlg")
    }

    private func setInlineExtendedDynamicRange(_ enabled: Bool) {
        #if os(macOS)
        if #available(macOS 10.15, *) {
            inlineLayer.wantsExtendedDynamicRangeContent = enabled
        }
        #elseif os(iOS)
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            inlineLayer.wantsExtendedDynamicRangeContent = enabled
        }
        #endif
    }

    /// Resolve scale from the screen currently hosting the layer. The main-screen fallback keeps
    /// configuration deterministic before the layer is attached to a view hierarchy.
    private var presentationScale: CGFloat {
        #if os(macOS)
        return appKitView?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        #else
        inlineLayer.delegate.flatMap { ($0 as? UIView)?.window?.screen.nativeScale }
            ?? UIScreen.main.nativeScale
        #endif
    }

    private func configurePictureInPictureCallbacks(
        for renderer: MPVMetalSampleBufferRenderer
    ) {
        renderer.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.selectedPictureInPictureBackend == .compatibilityDualSession,
                   case .active(let generation) = self.pictureInPictureState {
                    self.restorePrimaryVideoAfterCompatibilityIfNeeded()
                    self.pictureInPictureRenderer.stop()
                    self.observeCompatibilityRendererStop()
                    self.finishActivePictureInPictureFailure(
                        "PiP compatibility bridge failed: \(message)",
                        generation: generation
                    )
                } else {
                    self.reportError("PiP bridge: \(message)")
                }
            }
        }
        renderer.onDiagnostics = { [weak self] _ in
            Task { @MainActor [weak self] in self?.emitDiagnostics() }
        }
        renderer.onStateChange = { [weak self] _ in
            Task { @MainActor [weak self] in self?.emitDiagnostics() }
        }
    }

    private func startPictureInPictureRendererIfNeeded() throws {
        try pictureInPictureRenderer.start()
        _ = pictureInPictureRenderer.command(["set", "mute", "yes"])
        _ = pictureInPictureRenderer.command(["set", "aid", "no"])
    }

    private func loadPictureInPictureRenderer(
        seekTo position: Double,
        startsPaused: Bool,
        preservingDisplayedImage: Bool = false
    ) {
        guard let currentURL else { return }
        pictureInPictureRenderer.load(
            currentURL,
            headers: currentHeaders,
            preservingDisplayedImage: preservingDisplayedImage
        )
        _ = pictureInPictureRenderer.command(["set", "mute", "yes"])
        _ = pictureInPictureRenderer.command(["set", "aid", "no"])
        pictureInPictureRenderer.setVideoTrackSelection(compatibilityVideoSelection.desiredSelection)
        pictureInPictureRenderer.setSpeed(getSpeed())
        if position.isFinite, position > 0 {
            pictureInPictureRenderer.seek(to: position)
        }
        isCompatibilitySubtitleSessionLoaded = true
        for batch in externalSubtitles.batches {
            pictureInPictureRenderer.enqueueExternalSubtitles(batch)
        }
        pictureInPictureRenderer.restoreSubtitleSelectionIntent(externalSubtitles.selectionIntent)
        if let subtitleStyle {
            pictureInPictureRenderer.applySubtitleStyle(subtitleStyle)
        }
        if !videoFilterChain.isEmpty {
            _ = pictureInPictureRenderer.command(["set", "vf", videoFilterChain])
        }
        startsPaused ? pictureInPictureRenderer.pause() : pictureInPictureRenderer.play()
    }

    private func startPictureInPicturePreparation(generation: UInt64, legacyPrimeCount: Int) throws {
        guard !isStopping else { throw MPVGPUPlayerRendererError.teardownInProgress }
        guard isRunning else { throw MPVGPUPlayerRendererError.rendererNotRunning }
        guard currentURL != nil else { throw MPVGPUPlayerRendererError.mediaNotLoaded }
        guard activeHardwareDecoderRecoveryTransitionID == nil,
              activeHardwareDecoderRecoveryEpoch == nil else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "video decoder recovery is changing track ownership"
            )
        }
        guard pendingSingleSessionShutdown == nil else {
            throw MPVGPUPlayerRendererError.teardownInProgress
        }
        #if os(iOS)
        guard #available(iOS 15.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("iOS 15 or newer is required")
        }
        #elseif os(tvOS)
        guard #available(tvOS 15.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("tvOS 15 or newer is required")
        }
        #elseif os(macOS)
        guard #available(macOS 12.0, *) else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("macOS 12 or newer is required")
        }
        #endif
        guard generation == pictureInPicturePreparationGeneration else {
            throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
        }

        // A completed restore is retained only so AVKit's later restoration callback can join
        // that same cycle. Beginning any new preparation makes the old result ineligible even
        // when the media load and selected backend have not changed.
        lastPictureInPictureRestoreResult = nil
        pictureInPicturePreparationStartedAt = CACurrentMediaTime()
        pictureInPicturePreparationLatency = 0
        updatePictureInPictureState(.preparing(generation: generation))
        // The deadline starts when the host asks to prepare, not after mpv eventually creates its
        // video output. Waiting for FILE_LOADED / VIDEO_RECONFIG therefore consumes the same
        // bounded preparation budget as native setup and the first frame.
        schedulePictureInPicturePreparationTimeout(generation: generation)

        // Backend selection is latched for the load. In particular, `.automatic` never probes,
        // fails, and then oscillates back to the native path on a later PiP cycle.
        if selectedPictureInPictureBackend == .compatibilityDualSession {
            try startCompatibilityPreparation(generation: generation, primeCount: legacyPrimeCount)
            emitDiagnostics()
            return
        }

        if let selectedPictureInPictureBackend,
           selectedPictureInPictureBackend != .compatibilityDualSession {
            if let sink = singleSessionPictureInPictureSink {
                startSingleSessionPreparation(sink, generation: generation)
                emitDiagnostics()
                return
            }
            // A native failure is latched for this load. Never probe it again and oscillate.
            if options.pictureInPictureBackendPreference == .automatic {
                pictureInPictureFallbackReason = pictureInPictureFallbackReason
                    ?? "the previously selected single-session backend was retired"
                didAttemptCompatibilityFailover = true
                try startCompatibilityPreparation(generation: generation, primeCount: legacyPrimeCount)
                emitDiagnostics()
                return
            }
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "the single-session backend was retired for this load"
            )
        }

        switch options.pictureInPictureBackendPreference {
        case .singleSessionGPU:
            try requestNativePictureInPictureProbeWhenReady(
                generation: generation,
                primeCount: legacyPrimeCount
            )
        case .automatic:
            guard !didAttemptSingleSessionBackend else {
                pictureInPictureFallbackReason = pictureInPictureFallbackReason
                    ?? "single-session GPU was already attempted for this load"
                try startCompatibilityPreparation(generation: generation, primeCount: legacyPrimeCount)
                emitDiagnostics()
                return
            }
            try requestNativePictureInPictureProbeWhenReady(
                generation: generation,
                primeCount: legacyPrimeCount
            )
        case .compatibilityDualSession:
            try startCompatibilityPreparation(generation: generation, primeCount: legacyPrimeCount)
        }
        emitDiagnostics()
    }

    private func requestNativePictureInPictureProbeWhenReady(
        generation: UInt64,
        primeCount: Int
    ) throws {
        guard !didAttemptSingleSessionBackend else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "single-session GPU was already attempted for this load"
            )
        }
        guard let identity = currentPrimaryLoadIdentity else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                "there is no current media load"
            )
        }
        pendingNativePictureInPictureProbePrimeCount = min(2, max(1, primeCount))
        if let readyGeneration = nativePictureInPictureProbeGate.requestProbe(
            loadSequence: identity.sequence,
            preparationGeneration: generation
        ) {
            try performNativePictureInPictureProbe(generation: readyGeneration)
        }
    }

    private func resumeNativePictureInPictureProbeIfReady(_ generation: UInt64?) {
        guard let generation else { return }
        do {
            try performNativePictureInPictureProbe(generation: generation)
        } catch {
            failIfPictureInPicturePreparationIsPending(generation: generation, error: error)
        }
    }

    private func performNativePictureInPictureProbe(generation: UInt64) throws {
        guard generation == pictureInPicturePreparationGeneration,
              case .preparing(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation,
              pendingNativePictureInPictureProbePrimeCount != nil else {
            throw MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded
        }
        let primeCount = pendingNativePictureInPictureProbePrimeCount ?? 2
        pendingNativePictureInPictureProbePrimeCount = nil
        didAttemptSingleSessionBackend = true

        let nativeSink = makeSingleSessionPictureInPictureSink()
        switch options.pictureInPictureBackendPreference {
        case .singleSessionGPU:
            guard let nativeSink else {
                throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                    Self.singleSessionPictureInPictureUnavailableReason
                )
            }
            startSingleSessionPreparation(nativeSink, generation: generation)
        case .automatic:
            if let nativeSink {
                startSingleSessionPreparation(nativeSink, generation: generation)
            } else {
                pictureInPictureFallbackReason = Self.singleSessionPictureInPictureUnavailableReason
                try startCompatibilityPreparation(
                    generation: generation,
                    primeCount: primeCount
                )
            }
        case .compatibilityDualSession:
            try startCompatibilityPreparation(generation: generation, primeCount: primeCount)
        }
        emitDiagnostics()
    }

    private func makeSingleSessionPictureInPictureSink() -> MPVSingleSessionPictureInPictureSink? {
        mpv.flatMap {
            MPVSingleSessionPictureInPictureSinkRegistry.factory?(
                $0,
                pictureInPictureDisplayLayer,
                options.maximumInFlightPictureInPictureFrames,
                options.preferredPiPFramesPerSecond,
                cachedEstimatedFramesPerSecond > 0
                    ? cachedEstimatedFramesPerSecond
                    : cachedContainerFramesPerSecond
            )
        }
    }

    private func startSingleSessionPreparation(
        _ sink: MPVSingleSessionPictureInPictureSink,
        generation: UInt64
    ) {
        nativePictureInPictureDiagnosticsThrottle.reset()
        singleSessionPictureInPictureSink = sink
        selectedPictureInPictureBackend = sink.backend
        isPictureInPicturePrepared = true
        let renderSize = resolvedPictureInPictureRenderSize
        let sinkIdentity = ObjectIdentifier(sink)
        sink.onFrameEnqueued = { [weak self] frameGeneration in
            guard let self,
                  frameGeneration == generation,
                  self.pictureInPicturePreparationGeneration == generation,
                  self.singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else {
                return
            }
            self.completePictureInPictureTimelineUpdates(
                through: self.pictureInPictureTimelineUpdateSequence
            )
            let backendChanged = self.selectedPictureInPictureBackend != sink.backend
            self.selectedPictureInPictureBackend = sink.backend
            if self.nativePictureInPictureDiagnosticsThrottle.shouldEmit(
                at: CACurrentMediaTime(),
                materialChange: backendChanged
            ) {
                self.emitDiagnostics()
            }
        }
        sink.onError = { [weak self] message in
            guard let self,
                  self.singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else {
                return
            }
            self.handleSingleSessionFailure(
                message,
                generation: generation,
                sinkIdentity: sinkIdentity
            )
        }
        sink.updateTimeline(
            position: cachedPosition,
            rate: authoritativePictureInPictureRate,
            discontinuity: true
        )
        Task { [weak self, sink] in
            do {
                try await sink.prepare(generation: generation, renderSize: renderSize)
                guard let self,
                      self.selectedPictureInPictureBackend != .compatibilityDualSession,
                      self.singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else {
                    return
                }
                self.completePictureInPicturePreparation(generation: generation)
            } catch {
                guard let self,
                      self.selectedPictureInPictureBackend != .compatibilityDualSession,
                      self.singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else {
                    return
                }
                self.handleSingleSessionPreparationFailure(
                    error,
                    generation: generation,
                    sinkIdentity: sinkIdentity
                )
            }
        }
    }

    private func startCompatibilityPreparation(
        generation: UInt64,
        primeCount: Int,
        preservingDisplayedImage: Bool = false
    ) throws {
        guard !compatibilityRendererRequiresStopWait else {
            throw MPVGPUPlayerRendererError.teardownInProgress
        }
        selectedPictureInPictureBackend = .compatibilityDualSession
        pictureInPictureRenderer.onFrame = { [weak self] _ in
            // MPVMetalSampleBufferRenderer publishes frames from its main-actor enqueue seam, but
            // keep the public callback type source-compatible for clients that store an ordinary
            // closure rather than exposing a new global-actor function type.
            MainActor.assumeIsolated {
                self?.handleCompatibilityFrameEnqueued(generation: generation)
            }
        }
        try startPictureInPictureRendererIfNeeded()
        loadPictureInPictureRenderer(
            seekTo: cachedPosition,
            startsPaused: true,
            preservingDisplayedImage: preservingDisplayedImage
        )
        isPictureInPicturePrepared = true
        pictureInPictureRenderer.primeCompatibilityFrames(
            reason: "gpu-player-pip-prepare",
            count: min(2, max(1, primeCount))
        )
    }

    private func handleSingleSessionPreparationFailure(
        _ error: Error,
        generation: UInt64,
        sinkIdentity: ObjectIdentifier
    ) {
        let isCurrentPreEntryState: Bool
        switch pictureInPictureState {
        case .preparing(let value), .ready(let value):
            isCurrentPreEntryState = value == generation
        default:
            isCurrentPreEntryState = false
        }
        guard generation == pictureInPicturePreparationGeneration,
              isCurrentPreEntryState,
              selectedPictureInPictureBackend != .compatibilityDualSession,
              singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else { return }
        pictureInPicturePreparationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask = nil
        if let sink = singleSessionPictureInPictureSink {
            retireSingleSessionSink(sink)
        }
        singleSessionPictureInPictureSink = nil
        isPictureInPicturePrepared = false
        updatePictureInPictureState(.preparing(generation: generation))
        if options.pictureInPictureBackendPreference == .automatic {
            didAttemptCompatibilityFailover = true
            pictureInPictureFallbackReason = error.localizedDescription
            startCompatibilityAfterSingleSessionRetirement(
                generation: generation,
                reportMessage: nil
            )
        } else {
            failPictureInPicturePreparation(generation: generation, error: error)
        }
    }

    private func handleSingleSessionFailure(
        _ message: String,
        generation: UInt64,
        sinkIdentity: ObjectIdentifier
    ) {
        guard generation == pictureInPicturePreparationGeneration,
              singleSessionPictureInPictureSink.map(ObjectIdentifier.init) == sinkIdentity else { return }
        switch pictureInPictureState {
        case .active(let value) where value == generation:
            handleSingleSessionRuntimeFailure(message, generation: generation)
        case .preparing(let value) where value == generation,
             .ready(let value) where value == generation:
            handleSingleSessionPreparationFailure(
                MPVGPUPlayerRendererError.pictureInPictureUnavailable(message),
                generation: generation,
                sinkIdentity: sinkIdentity
            )
        default:
            break
        }
    }

    private func startCompatibilityAfterSingleSessionRetirement(
        generation: UInt64,
        reportMessage: String?,
        preservingDisplayedImage: Bool = false
    ) {
        let shutdown = pendingSingleSessionShutdown
        Task { [weak self] in
            await shutdown?.value
            guard let self,
                  !self.isStopping,
                  self.pictureInPicturePreparationGeneration == generation,
                  case .preparing(let activeGeneration) = self.pictureInPictureState,
                  activeGeneration == generation,
                  self.singleSessionPictureInPictureSink == nil else { return }
            do {
                try self.startCompatibilityPreparation(
                    generation: generation,
                    primeCount: 2,
                    preservingDisplayedImage: preservingDisplayedImage
                )
                self.schedulePictureInPicturePreparationTimeout(generation: generation)
                if let reportMessage {
                    self.reportError(reportMessage)
                }
            } catch {
                self.failPictureInPicturePreparation(generation: generation, error: error)
            }
        }
    }

    private func handleSingleSessionRuntimeFailure(_ message: String, generation: UInt64) {
        guard generation == pictureInPicturePreparationGeneration,
              case .active(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation,
              let sink = singleSessionPictureInPictureSink else { return }

        pictureInPictureFallbackReason = message
        retireSingleSessionSink(sink)
        singleSessionPictureInPictureSink = nil
        restorePrimaryVideoAfterCompatibilityIfNeeded()

        if options.pictureInPictureBackendPreference == .automatic,
           !didAttemptCompatibilityFailover {
            didAttemptCompatibilityFailover = true
            isPictureInPicturePrepared = false
            pendingPictureInPictureBegin = true
            pictureInPicturePreparationStartedAt = CACurrentMediaTime()
            updatePictureInPictureState(.preparing(generation: generation))
            startCompatibilityAfterSingleSessionRetirement(
                generation: generation,
                reportMessage: "single-session PiP failed; attempting compatibility bridge: \(message)",
                preservingDisplayedImage: true
            )
            return
        }

        finishActivePictureInPictureFailure(message, generation: generation)
    }

    private func finishActivePictureInPictureFailure(_ message: String, generation: UInt64) {
        pictureInPicturePreparationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask = nil
        restorePrimaryVideoAfterCompatibilityIfNeeded()
        isPictureInPicturePrepared = false
        isPictureInPictureActive = false
        pendingPictureInPictureBegin = false
        completePictureInPictureTimelineUpdates(through: pictureInPictureTimelineUpdateSequence)
        updatePictureInPictureState(.failed(generation: generation, reason: message))
        updateState(isBuffering ? .loading : (isPaused ? .paused : .playing))
        reportError(message)
        onPictureInPictureStopRequested?(message)
    }

    private func waitForPictureInPicturePreparation(generation: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            switch pictureInPictureState {
            case .ready(let value) where value == generation:
                continuation.resume()
            case .active(let value) where value == generation:
                continuation.resume()
            case .preparing(let value) where value == generation:
                pictureInPicturePreparationWaiters[generation, default: []].append(continuation)
            case .failed(let value, let reason) where value == generation:
                continuation.resume(throwing: MPVGPUPlayerRendererError.pictureInPictureUnavailable(reason))
            default:
                continuation.resume(throwing: MPVGPUPlayerRendererError.pictureInPicturePreparationSuperseded)
            }
        }
    }

    private func schedulePictureInPicturePreparationTimeout(generation: UInt64) {
        pictureInPicturePreparationTimeoutTask?.cancel()
        let timeout = options.pictureInPicturePreparationTimeout
        pictureInPicturePreparationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handlePictureInPicturePreparationTimeout(generation: generation)
        }
    }

    private func handlePictureInPicturePreparationTimeout(generation: UInt64) {
        guard generation == pictureInPicturePreparationGeneration,
              case .preparing(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation else { return }
        let nativeProbeWasWaiting = cancelPendingNativePictureInPictureProbe(
            generation: generation
        )
        if nativeProbeWasWaiting {
            // The one native attempt for this load has expired even though mpv never exposed a
            // matching video output on which the capability call could safely run.
            didAttemptSingleSessionBackend = true
        }
        if selectedPictureInPictureBackend != .compatibilityDualSession,
           options.pictureInPictureBackendPreference == .automatic {
            pictureInPicturePreparationTimeoutTask?.cancel()
            pictureInPicturePreparationTimeoutTask = nil
            if let sink = singleSessionPictureInPictureSink {
                retireSingleSessionSink(sink)
            }
            singleSessionPictureInPictureSink = nil
            isPictureInPicturePrepared = false
            didAttemptCompatibilityFailover = true
            pictureInPictureFallbackReason = nativeProbeWasWaiting
                ? "single-session GPU video output did not become ready before preparation timed out"
                : "single-session GPU preparation timed out"
            startCompatibilityAfterSingleSessionRetirement(
                generation: generation,
                reportMessage: nil
            )
            return
        }
        failPictureInPicturePreparation(
            generation: generation,
            error: MPVGPUPlayerRendererError.pictureInPicturePreparationTimedOut
        )
    }

    private func handleCompatibilityFrameEnqueued(generation: UInt64) {
        guard generation == pictureInPicturePreparationGeneration,
              selectedPictureInPictureBackend == .compatibilityDualSession else { return }
        completePictureInPictureTimelineUpdates(
            through: pictureInPictureTimelineUpdateSequence
        )
        guard case .preparing(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation else { return }
        completePictureInPicturePreparation(generation: generation)
    }

    private func completePictureInPicturePreparation(generation: UInt64) {
        guard generation == pictureInPicturePreparationGeneration,
              case .preparing(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation else { return }
        cancelPendingNativePictureInPictureProbe(generation: generation)
        pictureInPicturePreparationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask = nil
        if let started = pictureInPicturePreparationStartedAt {
            pictureInPicturePreparationLatency = CACurrentMediaTime() - started
        }
        pictureInPicturePreparationStartedAt = nil
        completePictureInPictureTimelineUpdates(
            through: pictureInPictureTimelineUpdateSequence
        )
        updatePictureInPictureState(.ready(generation: generation))
        let waiters = pictureInPicturePreparationWaiters.removeValue(forKey: generation) ?? []
        waiters.forEach { $0.resume() }
        if pendingPictureInPictureBegin {
            pendingPictureInPictureBegin = false
            activatePictureInPicture(generation: generation)
        }
    }

    private func failPictureInPicturePreparation(generation: UInt64, error: Error) {
        guard generation == pictureInPicturePreparationGeneration else { return }
        let wasActive = isPictureInPictureActive
        cancelPendingNativePictureInPictureProbe(generation: generation)
        pictureInPicturePreparationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask = nil
        if let started = pictureInPicturePreparationStartedAt {
            pictureInPicturePreparationLatency = CACurrentMediaTime() - started
        }
        pictureInPicturePreparationStartedAt = nil
        if selectedPictureInPictureBackend == .compatibilityDualSession,
           isPictureInPicturePrepared {
            pictureInPictureRenderer.stop()
            observeCompatibilityRendererStop()
        } else if let sink = singleSessionPictureInPictureSink {
            retireSingleSessionSink(sink)
            singleSessionPictureInPictureSink = nil
        }
        isPictureInPicturePrepared = false
        if wasActive { isPictureInPictureActive = false }
        restorePrimaryVideoAfterCompatibilityIfNeeded()
        pendingPictureInPictureBegin = false
        let reason = error.localizedDescription
        updatePictureInPictureState(.failed(generation: generation, reason: reason))
        let waiters = pictureInPicturePreparationWaiters.removeValue(forKey: generation) ?? []
        waiters.forEach { $0.resume(throwing: error) }
        reportError(reason)
        if wasActive {
            updateState(isBuffering ? .loading : (isPaused ? .paused : .playing))
            onPictureInPictureStopRequested?(reason)
        }
    }

    private func failIfPictureInPicturePreparationIsPending(generation: UInt64, error: Error) {
        guard case .preparing(let activeGeneration) = pictureInPictureState,
              activeGeneration == generation else { return }
        failPictureInPicturePreparation(generation: generation, error: error)
    }

    private func cancelPictureInPicturePreparation(with error: Error) {
        cancelPendingNativePictureInPictureProbe(generation: pictureInPicturePreparationGeneration)
        pictureInPicturePreparationTimeoutTask?.cancel()
        pictureInPicturePreparationTimeoutTask = nil
        pictureInPicturePreparationStartedAt = nil
        pendingCompatibilityStopAfterInlinePresentation = false
        cancelCompatibilityInlinePresentationProbe()
        let waiters = pictureInPicturePreparationWaiters.values.flatMap { $0 }
        pictureInPicturePreparationWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(throwing: error) }
        completePictureInPictureTimelineUpdates(
            through: pictureInPictureTimelineUpdateSequence
        )
    }

    @discardableResult
    private func cancelPendingNativePictureInPictureProbe(generation: UInt64) -> Bool {
        nativePictureInPictureProbeGate.cancelPreparation(generation: generation)
        guard pendingNativePictureInPictureProbePrimeCount != nil else { return false }
        pendingNativePictureInPictureProbePrimeCount = nil
        return true
    }

    private func markPictureInPictureTimelineUpdate(requiresFrame: Bool) {
        pictureInPictureTimelineUpdateSequence &+= 1
        let sequence = pictureInPictureTimelineUpdateSequence
        if !isPictureInPicturePrepared {
            completePictureInPictureTimelineUpdates(
                through: sequence
            )
        } else if !requiresFrame {
            if selectedPictureInPictureBackend == .compatibilityDualSession {
                let generation = pictureInPicturePreparationGeneration
                Task { [weak self, pictureInPictureRenderer] in
                    _ = await pictureInPictureRenderer.waitForTimelineUpdate()
                    guard let self,
                          self.pictureInPicturePreparationGeneration == generation,
                          self.selectedPictureInPictureBackend == .compatibilityDualSession else {
                        return
                    }
                    self.completePictureInPictureTimelineUpdates(through: sequence)
                }
            } else {
                completePictureInPictureTimelineUpdates(through: sequence)
            }
        }
    }

    private var authoritativePictureInPictureRate: Double {
        isPaused || isBuffering ? 0 : getSpeed()
    }

    private func synchronizeCompatibilityPlaybackState(
        shouldRealign: Bool,
        allowsPlayback: Bool? = nil
    ) {
        let decision = MPVCompatibilityPlaybackDecision.resolve(
            isPaused: isPaused,
            isBuffering: isBuffering,
            primaryPosition: cachedPosition,
            secondaryPosition: pictureInPictureRenderer.currentTime,
            shouldRealign: shouldRealign,
            allowsPlayback: allowsPlayback ?? isPictureInPictureActive
        )
        if let seekPosition = decision.seekPosition {
            pictureInPictureRenderer.seek(to: seekPosition)
        }
        pictureInPictureRenderer.setSpeed(getSpeed())
        if decision.shouldPause {
            pictureInPictureRenderer.pause()
        } else {
            pictureInPictureRenderer.play()
        }
    }

    private func updateSingleSessionTimeline(discontinuity: Bool) {
        guard selectedPictureInPictureBackend != .compatibilityDualSession else { return }
        singleSessionPictureInPictureSink?.updateTimeline(
            position: cachedPosition,
            rate: authoritativePictureInPictureRate,
            discontinuity: discontinuity
        )
    }

    private func requestPausedSingleSessionVisualRefresh() {
        guard isPaused,
              isPictureInPicturePrepared || isPictureInPictureActive,
              selectedPictureInPictureBackend != .compatibilityDualSession else { return }
        markPictureInPictureTimelineUpdate(requiresFrame: true)
        updateSingleSessionTimeline(discontinuity: true)
    }

    private func completePictureInPictureTimelineUpdates(through sequence: UInt64) {
        completedPictureInPictureTimelineUpdateSequence = max(
            completedPictureInPictureTimelineUpdateSequence,
            sequence
        )
        var remaining: [(UInt64, CheckedContinuation<Void, Never>)] = []
        for waiter in pictureInPictureTimelineUpdateWaiters {
            if waiter.0 <= completedPictureInPictureTimelineUpdateSequence {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pictureInPictureTimelineUpdateWaiters = remaining
    }

    private func activatePictureInPicture(generation: UInt64) {
        guard generation == pictureInPicturePreparationGeneration,
              case .ready(let readyGeneration) = pictureInPictureState,
              readyGeneration == generation else { return }
        do {
            if selectedPictureInPictureBackend == .compatibilityDualSession {
                synchronizeCompatibilityPlaybackState(
                    shouldRealign: true,
                    allowsPlayback: true
                )
                if options.pausesInlineRendererDuringPictureInPicture {
                    // Keep the primary handle running for audio/clock authority; only disable its
                    // video output after the compatibility renderer has a valid frame.
                    suppressPrimaryVideoForCompatibility()
                }
            } else {
                guard let sink = singleSessionPictureInPictureSink else {
                    throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
                        "the selected single-session sink was retired"
                    )
                }
                sink.updateTimeline(
                    position: cachedPosition,
                    rate: authoritativePictureInPictureRate,
                    discontinuity: false
                )
                try sink.begin()
            }
        } catch {
            failPictureInPicturePreparation(generation: generation, error: error)
            return
        }
        isPictureInPictureActive = true
        updatePictureInPictureState(.active(generation: generation))
        // Preserve a cache stall that was already active when the sink handoff completed. The
        // authoritative PiP timeline is rate zero in this state, and publishing `.pictureInPicture`
        // would make clients tell AVKit that the frozen timeline is playing.
        updateState(isBuffering ? .loading : .pictureInPicture)
        emitDiagnostics()
    }

    private func observeCompatibilityInlinePresentation(
        generation: UInt64,
        restoreIdentity: MPVPictureInPictureRestoreIdentity
    ) {
        cancelCompatibilityInlinePresentationProbe()
        guard let handle = mpv,
              let api = MPVApplePictureInPictureAPI.load(),
              api.apiVersion() == 1 else {
            markCompatibilityInlinePresentationUnconfirmed(
                "native inline-presentation probe is unavailable; compatibility renderer will stop after a bounded last-frame grace period",
                generation: generation,
                restoreIdentity: restoreIdentity
            )
            return
        }

        let rawCaps = UnsafeMutableRawPointer.allocate(byteCount: 184, alignment: 8)
        defer { rawCaps.deallocate() }
        rawCaps.initializeMemory(as: UInt8.self, repeating: 0, count: 184)
        rawCaps.storeBytes(of: UInt32(184), as: UInt32.self)
        guard api.getCapabilities(handle, rawCaps) == 0,
              rawCaps.load(fromByteOffset: 8, as: UInt64.self)
                & MPVApplePictureInPictureSink.inlineRestoreNotificationCapability != 0 else {
            markCompatibilityInlinePresentationUnconfirmed(
                "linked Libmpv cannot confirm inline presentation; compatibility renderer will stop after a bounded last-frame grace period",
                generation: generation,
                restoreIdentity: restoreIdentity
            )
            return
        }

        let nativeGeneration = generation == 0 ? 1 : generation
        let context = MPVApplePictureInPictureCallbackContext { [weak self] frame in
            guard let self,
                  frame.status == 0,
                  frame.token == 0,
                  frame.generation == nativeGeneration,
                  generation == self.pictureInPicturePreparationGeneration,
                  self.activePictureInPictureRestore == restoreIdentity,
                  self.pendingCompatibilityStopAfterInlinePresentation else { return }
            self.finishCompatibilityRestore(
                generation: generation,
                restoreIdentity: restoreIdentity,
                restored: true
            )
        }
        let contextPointer = MPVApplePictureInPictureCallbackRegistry.register(context)
        compatibilityInlineRestoreAPI = api
        compatibilityInlineRestoreContext = contextPointer
        compatibilityInlineRestoreNativeGeneration = nativeGeneration

        let callbackStatus = api.setCallback(
            handle,
            mpvAppleInlineRestoreFrameCallback,
            contextPointer
        )
        let modeStatus = callbackStatus == 0
            ? api.setMode(handle, 0, nativeGeneration)
            : callbackStatus
        guard callbackStatus == 0, modeStatus == 0 else {
            cancelCompatibilityInlinePresentationProbe()
            markCompatibilityInlinePresentationUnconfirmed(
                "native inline-presentation probe failed with status \(modeStatus); compatibility renderer will stop after a bounded last-frame grace period",
                generation: generation,
                restoreIdentity: restoreIdentity
            )
            return
        }
        let timeout = max(1, options.pictureInPicturePreparationTimeout)
        compatibilityInlineRestoreFailureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  generation == self.pictureInPicturePreparationGeneration,
                  self.activePictureInPictureRestore == restoreIdentity,
                  self.pendingCompatibilityStopAfterInlinePresentation else { return }
            self.markCompatibilityInlinePresentationUnconfirmed(
                "inline presentation was not confirmed before the restore timeout; compatibility renderer will stop after a bounded last-frame grace period",
                generation: generation,
                restoreIdentity: restoreIdentity
            )
        }
    }

    private func cancelCompatibilityInlinePresentationProbe() {
        compatibilityInlineRestoreFailureTask?.cancel()
        compatibilityInlineRestoreFailureTask = nil
        if let context = compatibilityInlineRestoreContext {
            MPVApplePictureInPictureCallbackRegistry.unregister(context)
        }
        if let handle = mpv, let api = compatibilityInlineRestoreAPI {
            _ = api.setCallback(handle, nil, nil)
        }
        compatibilityInlineRestoreContext = nil
        compatibilityInlineRestoreAPI = nil
        compatibilityInlineRestoreNativeGeneration = nil
    }

    private func markCompatibilityInlinePresentationUnconfirmed(
        _ reason: String,
        generation: UInt64,
        restoreIdentity: MPVPictureInPictureRestoreIdentity
    ) {
        guard generation == pictureInPicturePreparationGeneration,
              activePictureInPictureRestore == restoreIdentity,
              pendingCompatibilityStopAfterInlinePresentation else { return }
        pictureInPictureFallbackReason = reason
        updatePictureInPictureState(.failed(generation: generation, reason: reason))
        reportError(reason)
        emitDiagnostics()

        // Older/release Libmpv artifacts may not export the inline-restoration notification.
        // Keeping the second handle indefinitely leaks decoder/network work. Preserve AVKit's
        // final sample very briefly, then release the compatibility session even without proof
        // that the primary swapchain has presented. Generation checks make replacement loads and
        // teardown cancel this fallback cleanly.
        compatibilityInlineRestoreFailureTask?.cancel()
        compatibilityInlineRestoreFailureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self,
                  generation == self.pictureInPicturePreparationGeneration,
                  self.activePictureInPictureRestore == restoreIdentity,
                  self.pendingCompatibilityStopAfterInlinePresentation else { return }
            self.finishCompatibilityRestore(
                generation: generation,
                restoreIdentity: restoreIdentity,
                restored: false
            )
        }
    }

    private func finishCompatibilityRestore(
        generation: UInt64,
        restoreIdentity: MPVPictureInPictureRestoreIdentity,
        restored: Bool
    ) {
        guard generation == pictureInPicturePreparationGeneration,
              activePictureInPictureRestore == restoreIdentity,
              pendingCompatibilityStopAfterInlinePresentation else { return }
        pendingCompatibilityStopAfterInlinePresentation = false
        cancelCompatibilityInlinePresentationProbe()
        pictureInPictureRenderer.stop()
        observeCompatibilityRendererStop()
        isPictureInPicturePrepared = false
        updatePictureInPictureState(.idle)
        emitDiagnostics()
        completePictureInPictureRestore(restoreIdentity, restored: restored)
    }

    private func finishSingleSessionRestore(
        generation: UInt64,
        restoreIdentity: MPVPictureInPictureRestoreIdentity,
        restored: Bool
    ) {
        guard generation == pictureInPicturePreparationGeneration,
              activePictureInPictureRestore == restoreIdentity,
              restoreIdentity.sinkIdentity
                == singleSessionPictureInPictureSink.map(ObjectIdentifier.init) else { return }
        // Keep the successfully probed sink object latched to this mpv handle for the load. Its
        // native mode is stopped/drained by `end`, and the next PiP cycle reuses it without probing
        // or changing backend.
        isPictureInPicturePrepared = false
        updatePictureInPictureState(.idle)
        emitDiagnostics()
        completePictureInPictureRestore(restoreIdentity, restored: restored)
    }

    private func observeCompatibilityRendererStop() {
        isCompatibilitySubtitleSessionLoaded = false
        compatibilityRendererRequiresStopWait = true
        compatibilityStopGeneration &+= 1
        let stopGeneration = compatibilityStopGeneration
        Task { [weak self, pictureInPictureRenderer] in
            await pictureInPictureRenderer.waitUntilStopped()
            guard let self,
                  !self.isStopping,
                  self.compatibilityStopGeneration == stopGeneration else { return }
            self.compatibilityRendererRequiresStopWait = false
            self.emitDiagnostics()
        }
    }

    private func updatePictureInPictureState(_ newState: MPVPictureInPictureState) {
        guard pictureInPictureState != newState else { return }
        pictureInPictureState = newState
        onPictureInPictureStateChange?(newState)
        emitDiagnostics()
    }

    private var resolvedPictureInPictureRenderSize: CGSize {
        if pictureInPictureRenderSize.width.isFinite,
           pictureInPictureRenderSize.height.isFinite,
           pictureInPictureRenderSize.width > 1,
           pictureInPictureRenderSize.height > 1 {
            return validatedPictureInPictureRenderSize(pictureInPictureRenderSize)
        }
        let configured = options.maximumPiPFrameSize
        if configured.width.isFinite,
           configured.height.isFinite,
           configured.width > 1,
           configured.height > 1 {
            return validatedPictureInPictureRenderSize(configured)
        }
        return CGSize(width: 1280, height: 720)
    }

    private func validatedPictureInPictureRenderSize(_ requested: CGSize) -> CGSize {
        let fallback = CGSize(width: 1280, height: 720)
        guard requested.width.isFinite,
              requested.height.isFinite,
              requested.width > 1,
              requested.height > 1 else { return fallback }
        let configured = options.maximumPiPFrameSize
        let maximum = configured.width.isFinite
            && configured.height.isFinite
            && configured.width > 1
            && configured.height > 1
            ? configured
            : fallback
        let device = MTLCreateSystemDefaultDevice()
        let textureLimit = Self.maximumTextureDimension2D(for: device)
        let pixelLimit: Double
        #if os(macOS)
        pixelLimit = 14_745_600
        #else
        pixelLimit = 8_294_400
        #endif
        return MPVPictureInPictureRenderSizePolicy.resolved(
            requested: requested,
            maximum: maximum,
            fallback: fallback,
            textureDimensionLimit: textureLimit,
            pixelLimit: pixelLimit
        )
    }

    private var compatibilityRendererOptions: MPVMetalSampleBufferRendererOptions {
        let softwareFallbackValue = options.additionalMPVOptions["hwdec-software-fallback"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowsSoftwareDecoderFallback = !["no", "false", "0"]
            .contains(softwareFallbackValue ?? "yes")
        return MPVMetalSampleBufferRendererOptions(
            maximumFrameSize: resolvedPictureInPictureRenderSize,
            preferredFramesPerSecond: options.preferredPiPFramesPerSecond,
            preferredPiPFramesPerSecond: options.preferredPiPFramesPerSecond,
            createsMetalCompatibilityProbe: false,
            prefersMetalPresentation: false,
            prefersHDRPresentation: false,
            prefersHighBitDepthRendering: false,
            allowsSoftwareDecoderFallback: allowsSoftwareDecoderFallback,
            maximumInFlightFrameCount: options.maximumInFlightPictureInPictureFrames
        )
    }

    private func updateCompatibilityRendererOptions() {
        pictureInPictureRendererStorage?.updateOptions(compatibilityRendererOptions)
    }

    private var resolvedMaximumInlineDrawablePixelCount: Int {
        #if os(macOS) && arch(x86_64)
        let platformMaximum = 8_294_400
        #elseif os(macOS)
        let platformMaximum = 14_745_600
        #else
        let platformMaximum = 8_294_400
        #endif
        return MPVDrawablePixelLimit.resolved(
            configured: options.maximumInlineDrawablePixelCount,
            platformMaximum: platformMaximum
        )
    }

    private var resolvedInlineResizeDebounceInterval: TimeInterval {
        if options.inlineResizeDebounceInterval > 0 {
            return options.inlineResizeDebounceInterval
        }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 1.0 / 30.0 : 1.0 / 60.0
        #elseif os(macOS)
        return 1.0 / 30.0
        #else
        return 1.0 / 60.0
        #endif
    }

    #if os(tvOS)
    private func resolvedInlineDrawableLayout(
        bounds: CGSize,
        presentationScale: CGFloat
    ) -> MPVInlineDrawableLayout? {
        let requested = CGSize(
            width: bounds.width * presentationScale,
            height: bounds.height * presentationScale
        )
        guard let maximum = validatedInlineDrawableSize(requested) else { return nil }
        return MPVInlineDrawableLayout.resolved(
            bounds: bounds,
            presentationScale: presentationScale,
            maximumDrawableSize: maximum
        )
    }
    #endif

    private func validatedInlineDrawableSize(_ requestedSize: CGSize) -> CGSize? {
        guard requestedSize.width.isFinite,
              requestedSize.height.isFinite,
              requestedSize.width > 1,
              requestedSize.height > 1 else { return nil }
        #if os(macOS) && arch(x86_64)
        let device = inlineLayer.device ?? MTLCreateSystemDefaultDevice()
        return MPVIntelMacRenderPolicy.drawableSize(
            requested: requestedSize,
            maximumDimension: Self.maximumTextureDimension2D(for: device),
            maximumPixelCount: resolvedMaximumInlineDrawablePixelCount
        )
        #else
        let device = MTLCreateSystemDefaultDevice()
        let maximumDimension = Self.maximumTextureDimension2D(for: device)
        var width = min(requestedSize.width, maximumDimension)
        var height = min(requestedSize.height, maximumDimension)
        let pixels = Double(width) * Double(height)
        let pixelCap = Double(resolvedMaximumInlineDrawablePixelCount)
        if pixels > pixelCap {
            let scale = sqrt(pixelCap / pixels)
            width *= scale
            height *= scale
        }
        return CGSize(width: max(2, floor(width)), height: max(2, floor(height)))
        #endif
    }

    /// Metal does not expose a `maxTextureDimension2D` property in the public Apple SDK.
    /// The documented GPU-family limit is therefore the closest supported runtime query.
    private static func maximumTextureDimension2D(for device: MTLDevice?) -> CGFloat {
        guard let device else { return 8_192 }
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac1) {
            return 16_384
        }
        return 8_192
    }

    #if os(macOS) && arch(x86_64)
    private func applyIntelInlineLayerLayout(bounds: CGRect, presentationScale: CGFloat) {
        (inlineLayer as? MPVGPUPlayerMetalLayer)?.intelDrawablePixelLimit = resolvedMaximumInlineDrawablePixelCount
        guard let maximum = validatedInlineDrawableSize(CGSize(
            width: bounds.width * presentationScale,
            height: bounds.height * presentationScale
        )), let layout = MPVInlineDrawableLayout.resolved(
            bounds: bounds.size,
            presentationScale: presentationScale,
            maximumDrawableSize: maximum
        ) else { return }
        let previous = inlineLayer.drawableSize
        inlineResizeWorkItem?.cancel()
        inlineResizeWorkItem = nil
        pendingInlineDrawableSize = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hostOwnsLayerGeometry = (inlineLayer.delegate as? NSView)?.layer === inlineLayer
        if !hostOwnsLayerGeometry {
            inlineLayer.contentsScale = min(inlineLayer.contentsScale, layout.contentsScale)
            inlineLayer.frame = bounds
        }
        inlineLayer.contentsScale = layout.contentsScale
        inlineLayer.drawableSize = layout.drawableSize
        CATransaction.commit()
        if previous != inlineLayer.drawableSize {
            inlineResizeApplicationCount += 1
        }
        emitDiagnostics()
    }
    #endif

    private func applyPendingInlineDrawableSize() {
        inlineResizeWorkItem = nil
        guard let size = pendingInlineDrawableSize else { return }
        pendingInlineDrawableSize = nil
        let current = inlineLayer.drawableSize
        guard abs(current.width - size.width) >= 2 || abs(current.height - size.height) >= 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inlineLayer.drawableSize = size
        CATransaction.commit()
        inlineResizeApplicationCount += 1
        emitDiagnostics()
    }

    private func applyPendingPictureInPictureRenderSize() {
        pictureInPictureResizeWorkItem = nil
        guard let size = pendingPictureInPictureRenderSize else { return }
        pendingPictureInPictureRenderSize = nil
        guard MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
            current: pictureInPictureRenderSize,
            proposed: size
        ) else { return }
        pictureInPictureRenderSize = size
        pictureInPictureResizeApplicationCount += 1
        markPictureInPictureTimelineUpdate(requiresFrame: true)
        updateCompatibilityRendererOptions()
        singleSessionPictureInPictureSink?.updateRenderSize(size)
        emitDiagnostics()
    }

    private var backendDescription: String {
        let presentation: String
        switch selectedPictureInPictureBackend {
        case .singleSessionGPUDirectIOSurface:
            presentation = "single-session gpu-next PiP rendering directly into IOSurface buffers"
        case .singleSessionGPUAsynchronousMetalBlit:
            presentation = "single-session gpu-next PiP with an asynchronous Metal IOSurface blit"
        case .compatibilityDualSession:
            presentation = "video-only MPVMetalSampleBufferRenderer compatibility bridge; primary mpv owns audio and clock"
        case nil:
            presentation = "mpv gpu-next renderer backed by MoltenVK CAMetalLayer"
        }
        let argumentBuffers = getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS")
            .map { String(cString: $0) } ?? "default"
        let liveResourceCheck = getenv("MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES")
            .map { String(cString: $0) } ?? "default"
        return "\(presentation); MVK argumentBuffers=\(argumentBuffers) liveResourceCheck=\(liveResourceCheck)"
    }

    private func finishStopIfPossible() {
        guard isStopping, eventPumpStopCompleted, sampleRendererStopCompleted else { return }
        isRunning = false
        isStopping = false
        isPaused = true
        isBuffering = false
        pendingPrimaryLoadSubmission = nil
        isPrimaryLoadSubmissionPending = false
        currentURL = nil
        currentHeaders = nil
        cachedPosition = 0
        cachedDuration = 0
        resetCachedVideoProperties()
        _ = compatibilityVideoSelection.beginLoad()
        selectedPictureInPictureBackend = nil
        pictureInPictureFallbackReason = nil
        setInlineExtendedDynamicRange(false)
        updateState(.stopped)
        resumeStopWaiters()
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func resetCachedVideoProperties() {
        videoColorMetadataRefreshWorkItem?.cancel()
        videoColorMetadataRefreshWorkItem = nil
        cachedEstimatedFramesPerSecond = 0
        cachedContainerFramesPerSecond = 0
        cachedDroppedVideoFrameCount = 0
        cachedDelayedVideoFrameCount = 0
        cachedSeeking = false
        cachedVideoCodec = ""
        cachedVideoHasDolbyVisionRPU = nil
        cachedVideoWidth = 0
        cachedVideoHeight = 0
        cachedVideoTransferFunction = ""
        cachedVideoColorPrimaries = ""
        cachedVideoSignalPeak = 0
        cachedVideoPixelFormat = ""
        cachedHardwareDecoder = ""
    }

    /// Resolve the independent color properties as one snapshot at rare file/reconfigure
    /// boundaries. This keeps the first HDR decision coherent without restoring per-frame gets.
    private func refreshCachedVideoColorMetadataCoherently() {
        videoColorMetadataRefreshWorkItem?.cancel()
        videoColorMetadataRefreshWorkItem = nil
        cachedVideoTransferFunction = getStringProperty("video-params/gamma") ?? ""
        cachedVideoColorPrimaries = getStringProperty("video-params/primaries") ?? ""
        cachedVideoSignalPeak = getDoubleProperty("video-params/sig-peak") ?? 0
        setInlineExtendedDynamicRange(shouldEnableInlineExtendedDynamicRange)
    }

    private func refreshCachedVideoMetadataCoherently() {
        refreshCachedVideoColorMetadataCoherently()
        refreshCachedFrameDeliveryDiagnostics()
        cachedVideoWidth = getInt64Property("video-params/w") ?? 0
        cachedVideoHeight = getInt64Property("video-params/h") ?? 0
        cachedVideoPixelFormat = getStringProperty("video-params/pixelformat") ?? ""
        if getFlagProperty("video-params/dolby-vision") == true {
            cachedVideoHasDolbyVisionRPU = true
        } else if cachedVideoHasDolbyVisionRPU != true {
            cachedVideoHasDolbyVisionRPU = getFlagProperty("video-params/dolby-vision")
        }
    }

    private func refreshCachedFrameDeliveryDiagnostics() {
        cachedEstimatedFramesPerSecond = getDoubleProperty("estimated-vf-fps") ?? 0
        cachedDroppedVideoFrameCount = getInt64Property("frame-drop-count") ?? 0
        cachedDelayedVideoFrameCount = getInt64Property("vo-delayed-frame-count") ?? 0
    }

    private func scheduleCachedVideoColorMetadataRefresh(generation: UInt64) {
        videoColorMetadataRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isStopping,
                      self.currentPrimaryLoadIdentity?.clientGeneration == generation else { return }
                self.videoColorMetadataRefreshWorkItem = nil
                self.setInlineExtendedDynamicRange(self.shouldEnableInlineExtendedDynamicRange)
                self.emitDiagnostics()
                self.notifyVideoReconfigure(generation: generation)
            }
        }
        videoColorMetadataRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: workItem)
    }

    private func layerWindowID() -> Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(inlineLayer).toOpaque()))
    }

    private func observeProperties(handle: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("seeking", MPV_FORMAT_FLAG),
            ("speed", MPV_FORMAT_DOUBLE),
            ("container-fps", MPV_FORMAT_DOUBLE),
            ("track-list", MPV_FORMAT_NONE),
            ("vid", MPV_FORMAT_STRING),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE),
            ("video-codec", MPV_FORMAT_STRING),
            ("video-params/dolby-vision", MPV_FORMAT_FLAG),
            ("hwdec-current", MPV_FORMAT_STRING)
        ]
        for (name, format) in properties {
            _ = name.withCString { mpv_observe_property(handle, 0, $0, format) }
        }
    }

    private func handle(_ event: MPVGPUPlayerEvent, engineGeneration: UInt64) {
        guard !isStopping, self.engineGeneration == engineGeneration else { return }
        switch event {
        case .startFile(let playlistEntryID):
            guard let identity = loadIdentityTracker.didStart(playlistEntryID: playlistEntryID),
                  loadIdentityTracker.isLatest(identity),
                  identity == currentPrimaryLoadIdentity else { return }
            updateState(.loading)
        case .fileLoaded(let playlistEntryID):
            guard let identity = currentLoadIdentity(for: playlistEntryID) else { return }
            let pendingNativeProbeGeneration = nativePictureInPictureProbeGate.markFileLoaded(
                loadSequence: identity.sequence
            )
            isAwaitingPrimaryFileLoaded = false
            refreshCachedVideoMetadataCoherently()
            setFlagProperty("pause", isPaused)
            if let pendingSeekAfterPrimaryLoadSubmission {
                self.pendingSeekAfterPrimaryLoadSubmission = nil
                _ = command(["seek", "\(pendingSeekAfterPrimaryLoadSubmission)", "absolute+exact"])
            }
            applyDeferredPrimaryLoadActions(identity: identity)
            externalSubtitles.setReady()
            updateState(isBuffering ? .loading : (isPaused ? .paused : .playing))
            emitDiagnostics()
            notifyVideoReconfigure(generation: identity.clientGeneration)
            resumeNativePictureInPictureProbeIfReady(pendingNativeProbeGeneration)
        case .videoReconfigure(let playlistEntryID):
            guard let identity = currentLoadIdentity(for: playlistEntryID) else { return }
            let pendingNativeProbeGeneration = nativePictureInPictureProbeGate
                .markVideoReconfigured(loadSequence: identity.sequence)
            refreshCachedVideoMetadataCoherently()
            notifyVideoReconfigure(generation: identity.clientGeneration)
            onVideoOutputReconfigureForGeneration?(identity.clientGeneration)
            if let epoch = activeHardwareDecoderRecoveryEpoch,
               activeHardwareDecoderRecoveryGeneration == identity.clientGeneration {
                let provedVideoToolbox = hardwareDecoderRecoveryProof.observeVideoReconfiguration()
                if case .decoder(let decoder)? = hardwareDecoderRecoveryProof.completedDecoderObservation {
                    onHardwareDecoderRecoveryObservation?(identity.clientGeneration, epoch, decoder)
                }
                if provedVideoToolbox {
                    onHardwareDecoderRecoveryOutput?(identity.clientGeneration, epoch)
                }
            }
            resumeNativePictureInPictureProbeIfReady(pendingNativeProbeGeneration)
        case .seek(let playlistEntryID):
            guard let synchronization = hardwareDecoderRecoverySynchronization,
                  currentLoadIdentity(for: playlistEntryID) == synchronization.loadIdentity else { return }
            hardwareDecoderRecoverySynchronization?.sawSeek = true
        case .playbackRestart(let playlistEntryID):
            guard let synchronization = hardwareDecoderRecoverySynchronization,
                  synchronization.sawSeek,
                  currentLoadIdentity(for: playlistEntryID) == synchronization.loadIdentity else { return }
            finishHardwareDecoderRecoverySynchronization(epoch: synchronization.epoch, succeeded: true)
        case .endFile(let playlistEntryID, let reachedEOF, let error):
            let identity = loadIdentityTracker.didEnd(playlistEntryID: playlistEntryID)
            if reachedEOF { notifyPlaybackEnd(identity: identity) }
            if let error, let identity, loadIdentityTracker.isLatest(identity) {
                onError?("playback ended with error: \(error)")
            }
        case .propertyChange(let name, let value, let playlistEntryID):
            let generation: UInt64
            if let playlistEntryID {
                guard let identity = currentLoadIdentity(for: playlistEntryID) else { return }
                generation = identity.clientGeneration
            } else {
                guard MPVLoadPropertyFence.shouldAccept(
                    property: name,
                    hasPlaylistEntryID: false,
                    awaitingFileLoaded: isAwaitingPrimaryFileLoaded
                ) else { return }
                generation = loadIdentityTracker.latestIdentity?.clientGeneration ?? 0
            }
            if name == "eof-reached", case .flag(let reachedEOF) = value, let playlistEntryID {
                let identity = currentLoadIdentity(for: playlistEntryID)
                if reachedEOF {
                    notifyPlaybackEnd(identity: identity)
                } else {
                    playbackEndGate.playbackResumed(identity: identity, latestIdentity: loadIdentityTracker.latestIdentity)
                }
            }
            refreshProperty(named: name, value: value, generation: generation)
        case .logError(let message, let playlistEntryID):
            if let playlistEntryID {
                guard currentLoadIdentity(for: playlistEntryID) != nil else { return }
            } else if isAwaitingPrimaryFileLoaded {
                return
            }
            onError?(message)
        case .inlineHitchDiagnostic(let message, let playlistEntryID):
            if let playlistEntryID {
                guard currentLoadIdentity(for: playlistEntryID) != nil else { return }
            } else if isAwaitingPrimaryFileLoaded {
                return
            }
            let category = mpvGPUInlineDiagnosticCategory(message)
            if category == .decodeError || category == .videoTimestampReset {
                foregroundVideoTimelineDiscontinuityGeneration &+= 1
            }
            onInlineHitchDiagnostic?(message)
        case .videoTimelineDiscontinuity(let playlistEntryID):
            if let playlistEntryID {
                guard currentLoadIdentity(for: playlistEntryID) != nil else { return }
            } else if isAwaitingPrimaryFileLoaded {
                return
            }
            foregroundVideoTimelineDiscontinuityGeneration &+= 1
        case .asyncReply(let requestID, let error):
            pendingAsyncReplies.removeValue(forKey: requestID)?.complete(error)
        case .shutdown:
            stop()
        }
    }

    private func currentLoadIdentity(for playlistEntryID: Int64?) -> MPVLoadIdentityTracker.Identity? {
        guard let playlistEntryID,
              let identity = loadIdentityTracker.identity(forPlaylistEntryID: playlistEntryID),
              loadIdentityTracker.isLatest(identity),
              identity == currentPrimaryLoadIdentity else { return nil }
        return identity
    }

    private func notifyPlaybackEnd(identity: MPVLoadIdentityTracker.Identity?) {
        guard !isStopping,
              identity == currentPrimaryLoadIdentity,
              playbackEndGate.claim(
                identity: identity,
                latestIdentity: loadIdentityTracker.latestIdentity,
                reachedEOF: true,
                isReady: !isAwaitingPrimaryFileLoaded,
                playlistEntryCount: getInt64Property("playlist-count")
              ), let identity else { return }
        onPlaybackEndForGeneration?(identity.clientGeneration)
    }

    private func refreshProperty(
        named name: String,
        value: MPVGPUObservedPropertyValue,
        generation: UInt64
    ) {
        switch name {
        case "duration":
            if case .double(let duration) = value {
                cachedDuration = duration
            }
        case "time-pos":
            if case .double(let position) = value {
                cachedPosition = position
            }
            updateSingleSessionTimeline(discontinuity: false)
        case "pause":
            if case .flag(let paused) = value {
                isPaused = paused
            }
            updateSingleSessionTimeline(discontinuity: false)
            if selectedPictureInPictureBackend == .compatibilityDualSession,
               isPictureInPicturePrepared || isPictureInPictureActive {
                synchronizeCompatibilityPlaybackState(shouldRealign: false)
            }
            if !isPictureInPictureActive, !isAwaitingPrimaryFileLoaded {
                updateState(isBuffering ? .loading : (isPaused ? .paused : .playing))
            }
        case "paused-for-cache":
            let wasBuffering = isBuffering
            if case .flag(let buffering) = value {
                isBuffering = buffering
            }
            updateSingleSessionTimeline(discontinuity: false)
            if selectedPictureInPictureBackend == .compatibilityDualSession,
               isPictureInPicturePrepared || isPictureInPictureActive {
                synchronizeCompatibilityPlaybackState(
                    shouldRealign: wasBuffering && !isBuffering
                )
            }
            if isBuffering {
                updateState(.loading)
            } else if isPictureInPictureActive {
                // Buffering temporarily drives the authoritative PiP timeline rate to zero. Once
                // cache pause clears, publish the active state again so the bridge/AVKit no longer
                // reports a sticky loading pause while frames have resumed.
                updateState(.pictureInPicture)
            } else if !isPictureInPictureActive, !isAwaitingPrimaryFileLoaded {
                updateState(isPaused ? .paused : .playing)
            }
        case "speed":
            if case .double(let speed) = value, speed.isFinite {
                cachedSpeed = speed
            }
            if selectedPictureInPictureBackend == .compatibilityDualSession,
               isPictureInPicturePrepared || isPictureInPictureActive {
                pictureInPictureRenderer.setSpeed(cachedSpeed)
            }
            updateSingleSessionTimeline(discontinuity: false)
        case "seeking":
            if case .flag(let seeking) = value {
                cachedSeeking = seeking
            }
            if case .flag(false) = value,
               selectedPictureInPictureBackend == .compatibilityDualSession,
               isPictureInPicturePrepared || isPictureInPictureActive,
               abs(pictureInPictureRenderer.currentTime - cachedPosition) > 0.25 {
                pictureInPictureRenderer.seek(to: cachedPosition)
            }
        case "vid":
            if case .string(let selection) = value {
                compatibilityVideoSelection.observePrimarySelection(selection)
            } else if case .unavailable = value {
                compatibilityVideoSelection.observePrimarySelection(nil)
            }
            emitDiagnostics()
        case "track-list", "sid", "aid":
            emitDiagnostics()
        case "estimated-vf-fps":
            if case .double(let fps) = value {
                cachedEstimatedFramesPerSecond = fps
            } else if case .unavailable = value {
                cachedEstimatedFramesPerSecond = 0
            }
        case "frame-drop-count":
            if case .int64(let count) = value {
                cachedDroppedVideoFrameCount = count
            } else if case .unavailable = value {
                cachedDroppedVideoFrameCount = 0
            }
        case "vo-delayed-frame-count":
            if case .int64(let count) = value {
                cachedDelayedVideoFrameCount = count
            } else if case .unavailable = value {
                cachedDelayedVideoFrameCount = 0
            }
        case "container-fps":
            if case .double(let fps) = value {
                cachedContainerFramesPerSecond = fps
            } else if case .unavailable = value {
                cachedContainerFramesPerSecond = 0
            }
        case "video-codec":
            if case .string(let codec) = value {
                cachedVideoCodec = codec
            } else if case .unavailable = value {
                cachedVideoCodec = ""
            }
        case "video-params/w":
            if case .int64(let width) = value {
                cachedVideoWidth = width
            } else if case .unavailable = value {
                cachedVideoWidth = 0
            }
        case "video-params/h":
            if case .int64(let height) = value {
                cachedVideoHeight = height
            } else if case .unavailable = value {
                cachedVideoHeight = 0
            }
        case "video-params/pixelformat":
            if case .string(let pixelFormat) = value {
                cachedVideoPixelFormat = pixelFormat
            } else if case .unavailable = value {
                cachedVideoPixelFormat = ""
            }
        case "video-params/dolby-vision":
            if case .flag(let detected) = value {
                // Latch a positive RPU observation for this file. Some Dolby Vision
                // streams carry sparse RPU side data, so a later frame without it
                // must not erase an earlier bitstream-confirmed detection.
                if detected {
                    cachedVideoHasDolbyVisionRPU = true
                } else if cachedVideoHasDolbyVisionRPU != true {
                    cachedVideoHasDolbyVisionRPU = false
                }
                emitDiagnostics()
            } else if case .unavailable = value, cachedVideoHasDolbyVisionRPU != true {
                cachedVideoHasDolbyVisionRPU = nil
                emitDiagnostics()
            }
        case "hwdec-current":
            // `hwdec-current` becomes a VideoToolbox value only after decoded output is available,
            // making this the foreground-recovery proof rather than a configuration guess.
            if case .string(let decoder) = value {
                cachedHardwareDecoder = decoder
            } else if case .unavailable = value {
                cachedHardwareDecoder = ""
            }
            emitDiagnostics()
            if let epoch = activeHardwareDecoderRecoveryEpoch,
               activeHardwareDecoderRecoveryGeneration == generation {
                let provedVideoToolbox = hardwareDecoderRecoveryProof.observeHardwareDecoder(
                    cachedHardwareDecoder
                )
                if case .decoder(let decoder)? = hardwareDecoderRecoveryProof.completedDecoderObservation {
                    onHardwareDecoderRecoveryObservation?(generation, epoch, decoder)
                }
                if provedVideoToolbox {
                    onHardwareDecoderRecoveryOutput?(generation, epoch)
                }
            }
        case "video-params/gamma", "video-params/primaries", "video-params/sig-peak":
            var didChange = false
            switch (name, value) {
            case ("video-params/gamma", .string(let transfer)):
                didChange = cachedVideoTransferFunction != transfer
                cachedVideoTransferFunction = transfer
            case ("video-params/primaries", .string(let primaries)):
                didChange = cachedVideoColorPrimaries != primaries
                cachedVideoColorPrimaries = primaries
            case ("video-params/sig-peak", .double(let signalPeak)):
                didChange = cachedVideoSignalPeak != signalPeak
                cachedVideoSignalPeak = signalPeak
            case ("video-params/gamma", .unavailable):
                didChange = !cachedVideoTransferFunction.isEmpty
                cachedVideoTransferFunction = ""
            case ("video-params/primaries", .unavailable):
                didChange = !cachedVideoColorPrimaries.isEmpty
                cachedVideoColorPrimaries = ""
            case ("video-params/sig-peak", .unavailable):
                didChange = cachedVideoSignalPeak != 0
                cachedVideoSignalPeak = 0
            default:
                break
            }
            if didChange {
                scheduleCachedVideoColorMetadataRefresh(generation: generation)
            }
        default:
            break
        }
    }

    private func resetLoadGenerations() {
        loadIdentityTracker.reset()
        currentPrimaryLoadIdentity = nil
        hasSubmittedCurrentPrimaryLoad = false
        isAwaitingPrimaryFileLoaded = false
        nativePictureInPictureProbeGate.reset()
        pendingNativePictureInPictureProbePrimeCount = nil
        deferredPrimaryLoadActions.cancel()
        pendingSeekAfterPrimaryLoadSubmission = nil
    }

    private func notifyVideoReconfigure(generation: UInt64) {
        onVideoReconfigure?()
        onVideoReconfigureForGeneration?(generation)
    }

    private func updateHTTPHeaders(_ headers: [String: String]?) {
        guard let headers, !headers.isEmpty else {
            clearProperty("http-header-fields")
            return
        }
        let headerValue = headers
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        if headerValue.isEmpty {
            clearProperty("http-header-fields")
        } else {
            setStringProperty("http-header-fields", headerValue)
        }
    }

    private func fetchTrackList() -> [MPVMetalSampleBufferTrack] {
        guard let handle = mpv else { return [] }
        var node = mpv_node()
        let status = "track-list".withCString { pointer in
            mpv_get_property(handle, pointer, MPV_FORMAT_NODE, &node)
        }
        guard status >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }

        var tracks: [MPVMetalSampleBufferTrack] = []
        for index in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }
            var id = -1
            var type = ""
            var title = ""
            var lang = ""
            var codec = ""
            var audioChannelLayout = ""
            var audioChannelCount = 0
            var selected = false
            var external = false
            var defaultTrack = false
            var forced = false
            for entryIndex in 0..<Int(map.pointee.num) {
                guard let keyPointer = map.pointee.keys[entryIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = map.pointee.values[entryIndex]
                switch key {
                case "id":
                    if value.format == MPV_FORMAT_INT64 { id = Int(value.u.int64) }
                case "type":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { type = String(cString: string) }
                case "title":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { title = String(cString: string) }
                case "lang":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { lang = String(cString: string) }
                case "codec":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { codec = String(cString: string) }
                case "demux-channels":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { audioChannelLayout = String(cString: string) }
                case "demux-channel-count":
                    if value.format == MPV_FORMAT_INT64 { audioChannelCount = Int(clamping: value.u.int64) }
                case "external":
                    if value.format == MPV_FORMAT_FLAG { external = value.u.flag != 0 }
                case "default":
                    if value.format == MPV_FORMAT_FLAG { defaultTrack = value.u.flag != 0 }
                case "forced":
                    if value.format == MPV_FORMAT_FLAG { forced = value.u.flag != 0 }
                case "selected":
                    if value.format == MPV_FORMAT_FLAG { selected = value.u.flag != 0 }
                default:
                    break
                }
            }
            guard id >= 0, !type.isEmpty else { continue }
            tracks.append(MPVMetalSampleBufferTrack(
                id: id,
                type: type,
                title: title.isEmpty ? "Track \(id)" : title,
                sourceTitle: title,
                language: lang,
                isExternal: external,
                isDefault: defaultTrack,
                isForced: forced,
                codec: codec,
                audioChannelLayout: audioChannelLayout,
                audioChannelCount: audioChannelCount,
                selected: selected
            ))
        }
        return tracks
    }

    @discardableResult
    private func command(handle: OpaquePointer, args: [String]) -> Int32 {
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        return mpv_command(handle, &cargs)
    }

    private func setOption(_ name: String, _ value: String, handle: OpaquePointer? = nil) {
        guard let handle = handle ?? mpv else { return }
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func setOption(_ name: String, value: Int64, handle: OpaquePointer? = nil) {
        guard let handle = handle ?? mpv else { return }
        var data = value
        _ = name.withCString { mpv_set_option(handle, $0, MPV_FORMAT_INT64, &data) }
    }

    @discardableResult
    private func setStringProperty(_ name: String, _ value: String) -> Int32 {
        guard let handle = mpv else { return -1 }
        return name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func clearProperty(_ name: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_NONE, nil) }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var data: Int32 = value ? 1 : 0
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &data) }
    }

    private func getInt64Property(_ name: String) -> Int64? {
        guard let handle = mpv else { return nil }
        var data = Int64()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &data) }
        return status >= 0 ? data : nil
    }

    private func getFlagProperty(_ name: String) -> Bool? {
        guard let handle = mpv else { return nil }
        var data = Int32()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &data) }
        return status >= 0 ? data != 0 : nil
    }

    private func currentPlaylistEntryID() -> Int64? {
        if let position = getInt64Property("playlist-pos"), position >= 0,
           let playlistEntryID = getInt64Property("playlist/\(position)/id") {
            return playlistEntryID
        }
        return getInt64Property("playlist/0/id")
    }

    /// Reads a string-valued mpv property (e.g. `video-params/gamma`). The libmpv client API is
    /// thread-safe, so this is safe to call from the main thread (diagnostics/overlay) while the
    /// event loop runs on `eventQueue`. Returns nil when the property is unavailable.
    private func getStringProperty(_ name: String) -> String? {
        guard let handle = mpv else { return nil }
        guard let raw = name.withCString({ mpv_get_property_string(handle, $0) }) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle = mpv else { return nil }
        var value = Double()
        let status = name.withCString {
            mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &value)
        }
        return status >= 0 ? value : nil
    }

    private func mpvColorString(_ color: CGColor) -> String {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return "#FFFFFFFF" }
        let converted = color.converted(
            to: colorSpace,
            intent: .defaultIntent,
            options: nil
        ) ?? color
        let components = converted.components ?? [1, 1, 1, 1]
        let red = components.indices.contains(0) ? components[0] : 1
        let green = components.indices.contains(1) ? components[1] : red
        let blue = components.indices.contains(2) ? components[2] : red
        let alpha = components.indices.contains(3) ? components[3] : 1
        return String(
            format: "#%02X%02X%02X%02X",
            Int(max(0, min(1, alpha)) * 255),
            Int(max(0, min(1, red)) * 255),
            Int(max(0, min(1, green)) * 255),
            Int(max(0, min(1, blue)) * 255)
        )
    }

    private func updateState(_ newState: MPVGPUPlayerRendererState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
        emitDiagnostics()
    }

    private func reportError(_ message: String) {
        onError?(message)
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func emitDiagnostics() {
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func performOnMain(_ block: () -> Void) { block() }
}

#else

@MainActor
public final class MPVGPUPlayerRenderer {
    public static let isSupported = false
    public static let supportsPictureInPicture = false
    public static let inlineGPUUnavailableReason: String? = "the native macOS renderer requires Apple Silicon"
    public static let singleSessionPictureInPictureUnavailableReason =
        "native gpu-next IOSurface sink symbols or required runtime capabilities are unavailable"
    public let inlineLayer: CAMetalLayer
    public let pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer
    public var currentTime: Double { 0 }
    public var duration: Double { 0 }
    public private(set) var pictureInPictureState: MPVPictureInPictureState = .idle
    public private(set) var selectedPictureInPictureBackend: MPVPictureInPictureBackend?
    public var onStateChange: ((MPVGPUPlayerRendererState) -> Void)?
    public var onPictureInPictureStateChange: ((MPVPictureInPictureState) -> Void)?
    public var onPictureInPictureStopRequested: ((String) -> Void)?
    public var onPlaybackEndForGeneration: ((UInt64) -> Void)?
    public var onError: ((String) -> Void)?
    public var onInlineHitchDiagnostic: ((String) -> Void)?
    public var onDiagnostics: ((MPVGPUPlayerRendererDiagnostics) -> Void)?
    public var onVideoReconfigure: (() -> Void)?
    public var onVideoReconfigureForGeneration: ((UInt64) -> Void)?
    public var onVideoOutputReconfigureForGeneration: ((UInt64) -> Void)?
    public var onHardwareDecoderRecoveryOutput: ((_ generation: UInt64, _ epoch: UInt64) -> Void)?
    public var onHardwareDecoderRecoveryObservation: ((_ generation: UInt64, _ epoch: UInt64, _ decoder: String?) -> Void)?

    public convenience init(options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()) {
        self.init(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
    }

    public init(
        inlineLayer: CAMetalLayer,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        self.inlineLayer = inlineLayer
        self.pictureInPictureDisplayLayer = pictureInPictureDisplayLayer
        _ = options
    }

    #if os(macOS)
    public convenience init(
        view: NSView,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        view.wantsLayer = true
        let metalLayer = (view.layer as? CAMetalLayer) ?? MPVGPUPlayerMetalLayer()
        view.layer = metalLayer
        self.init(
            inlineLayer: metalLayer,
            pictureInPictureDisplayLayer: pictureInPictureDisplayLayer,
            options: options
        )
    }
    #endif

    public func updateInlineLayerLayout(bounds: CGRect, contentsScale: CGFloat? = nil) { _ = bounds; _ = contentsScale }
    public func updatePictureInPictureRenderSize(_ size: CGSize) { _ = size }
    public func updateOptions(_ newOptions: MPVGPUPlayerRendererOptions) { _ = newOptions }
    public func inlineRenderPasses(includeRedraw: Bool = false) -> [MPVGPUPlayerRenderPass] { _ = includeRedraw; return [] }
    public func refreshCurrentHardwareDecoder() -> String { "" }
    public func validateForegroundVideoAfterSystemResume(
        timeout: TimeInterval = 0.75,
        allowsSoftwareDecoding: Bool = false
    ) async -> MPVGPUPlayerForegroundVideoValidation {
        _ = timeout
        _ = allowsSoftwareDecoding
        return .unavailable
    }
    @discardableResult
    public func recreateHardwareDecoderAfterSystemResume(
        strategy: MPVGPUPlayerHardwareDecoderRecoveryStrategy = .configuredOrder
    ) async -> MPVGPUPlayerHardwareDecoderRecoverySubmission {
        _ = strategy
        return .unavailable
    }
    public func synchronizeHardwareDecoderRecoveryAfterSystemResume(
        epoch: UInt64,
        timeout: TimeInterval = 4
    ) async -> Bool { _ = epoch; _ = timeout; return false }
    @discardableResult
    public func finishHardwareDecoderRecoveryAttempt(epoch: UInt64) -> Bool { _ = epoch; return false }
    public func yieldHardwareDecoderRecoveryToPictureInPicture() {}
    public func start() throws { throw MPVMetalSampleBufferRendererError.unsupportedPlatform }
    public func stop() {}
    public func waitUntilStopped() async {}
    public func load(_ url: URL, headers: [String: String]? = nil) { _ = url; _ = headers }
    public func load(_ url: URL, headers: [String: String]? = nil, generation: UInt64) {
        _ = url
        _ = headers
        _ = generation
    }
    public func play(preservingHardwareDecoderRecovery: Bool = false) { _ = preservingHardwareDecoderRecovery }
    public func pause(preservingHardwareDecoderRecovery: Bool = false) { _ = preservingHardwareDecoderRecovery }
    public func seek(to seconds: Double) { _ = seconds }
    public func seek(by seconds: Double) { _ = seconds }
    public func setSpeed(_ speed: Double) { _ = speed }
    public func getSpeed() -> Double { 1 }
    public func waitForPictureInPictureTimelineUpdate() async {}
    public func preparePictureInPicture() async throws {
        throw MPVGPUPlayerRendererError.pictureInPictureUnavailable(
            "the native macOS renderer requires Apple Silicon"
        )
    }
    @available(*, deprecated, message: "Use preparePictureInPicture() async throws")
    public func prepareForPictureInPictureStart(primeFrameCount: Int = 8) -> Bool { _ = primeFrameCount; return false }
    public func beginPictureInPicture() {}
    public func endPictureInPicture(restoringInlinePlayback: Bool = true) { _ = restoringInlinePlayback }
    public func endPictureInPictureAndWait(
        restoringInlinePlayback: Bool = true
    ) async -> Bool {
        _ = restoringInlinePlayback
        return false
    }
    @discardableResult public func command(_ args: [String]) -> Int32 { _ = args; return -1 }
    @available(*, deprecated, message: "Use preparePictureInPicture() async throws")
    public func primePictureInPictureFrames(reason: String, count: Int = 6) { _ = reason; _ = count }
    public func setAudioFilterChain(_ chain: String) { _ = chain }
    public func setVideoFilterChain(_ chain: String) { _ = chain }
    public func videoTracks() -> [MPVMetalSampleBufferTrack] { [] }
    public func audioTracks() -> [MPVMetalSampleBufferTrack] { [] }
    public func subtitleTracks() -> [MPVMetalSampleBufferTrack] { [] }
    public func currentVideoTrackID() -> Int { -1 }
    public func currentAudioTrackID() -> Int { -1 }
    public func currentSubtitleTrackID() -> Int { -1 }
    public func setVideoTrack(id: Int) { _ = id }
    public func selectAutomaticVideoTrack() {}
    public func setAudioTrack(id: Int) { _ = id }
    public func setSubtitleTrack(id: Int) { _ = id }
    public func disableSubtitles() {}
    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true,
                                      headersByURL: [String: [String: String]]? = nil) {
        _ = urls
        _ = names
        _ = selectFirst
        _ = headersByURL
    }
    public func prefetchExternalSubtitles(urls: [String], headersByURL: [String: [String: String]]? = nil,
                                          allowsCellularAccess: Bool = false) {
        _ = urls
        _ = headersByURL
        _ = allowsCellularAccess
    }
    public func currentExternalSubtitleURL() -> String? { nil }

    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) { _ = style }
    public func diagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        MPVGPUPlayerRendererDiagnostics(
            state: .failed("unsupported platform"),
            presentationMode: .inlineGPU,
            currentTime: 0,
            duration: 0,
            isPaused: true,
            inlineVideoOutput: "unsupported",
            inlineGPUAPI: "unsupported",
            inlineGPUContext: "unsupported",
            pictureInPictureDiagnostics: nil,
            backendDescription: "unsupported",
            pictureInPictureState: pictureInPictureState,
            pictureInPictureBackendPreference: .automatic,
            selectedPictureInPictureBackend: nil,
            pictureInPictureFallbackReason: "the native macOS renderer requires Apple Silicon",
            activeMPVInstanceCount: 0,
            pictureInPicturePreparationGeneration: 0,
            pictureInPicturePreparationLatency: 0,
            inlineResizeRequestCount: 0,
            inlineResizeApplicationCount: 0,
            inlineResizeCoalescedCount: 0,
            pictureInPictureResizeRequestCount: 0,
            pictureInPictureResizeApplicationCount: 0,
            pictureInPictureResizeCoalescedCount: 0,
            maximumInlineDrawablePixelCount: 14_745_600,
            schedulerCoalescedRequestCount: 0,
            backpressureDropCount: 0,
            poolExhaustionDropCount: 0,
            staleGenerationDropCount: 0,
            inFlightGPUFrameCount: 0,
            pictureInPictureEnqueuedFrameCount: 0,
            lastGPULatencyMilliseconds: 0,
            timelineEpoch: 0,
            timelineRate: 0,
            audioRecoveryCount: 0,
            estimatedFramesPerSecond: 0,
            droppedVideoFrameCount: 0,
            delayedVideoFrameCount: 0,
            videoCodec: "",
            videoHasDolbyVisionRPU: nil,
            videoWidth: 0,
            videoHeight: 0,
            videoTransferFunction: "",
            videoColorPrimaries: "",
            videoSignalPeak: 0,
            videoPixelFormat: "",
            hardwareDecoder: ""
        )
    }
    public func frameDeliveryDiagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        diagnosticsSnapshot()
    }
    public func playbackDiagnosticSnapshot() -> String {
        "unsupported-platform"
    }
}

#endif
