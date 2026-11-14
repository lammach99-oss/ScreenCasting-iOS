import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

// MARK: - Connection State Machine

/// Full lifecycle state for the secure NWConnection to the Windows host.
public enum ConnectionState: Equatable {
    case idle
    case listening
    case connecting
    case awaitingHostIdentity
    case awaitingPIN
    case authFailed(reason: String)
    case streaming
    case disconnected(reason: String)
}

// MARK: - Auth Packet (mirrors C# AuthPacketHeader)
// Layout: [uint32 magic (0x41555448)] [uint32 pinCode] — 8 bytes, little-endian

private enum AuthProtocol {
    static let magic: UInt32 = 0x41555448   // "AUTH" in ASCII
    static let successResponse = "AUTH_SUCCESS"
    static let failedResponse = "AUTH_FAILED"
    static let packetSize = 8               // 2 × UInt32
}

private enum USBListenerError: LocalizedError {
    case invalidPort
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "USB listener port 42042 is invalid."
        case .identityUnavailable:
            return "The device-local USB TLS identity could not be loaded or created."
        }
    }
}
// [split: WireCommands.swift]
// [split: TrustedHostSettings.swift]

private enum TrustedDeviceIdentity {
    private static let defaultsKey = "trustedDeviceId.v1"

    static func loadOrCreate() -> Data {
        if let stored = UserDefaults.standard.data(forKey: defaultsKey),
           stored.count == 16 { return stored }
        var uuid = UUID().uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return data
    }
}
// [split: DisplayConfiguration.swift]

private enum DisplayPreferenceStore {
    private static let widthKey = "ScreenCasting.display.preferredWidth"
    private static let heightKey = "ScreenCasting.display.preferredHeight"
    private static let refreshKey = "ScreenCasting.display.preferredRefreshHz"
    private static let orientationKey = "ScreenCasting.display.orientationMode"

    static func load() -> DisplayPreference {
        let defaults = UserDefaults.standard
        let width = (defaults.object(forKey: widthKey) as? NSNumber)?.uint32Value
        let height = (defaults.object(forKey: heightKey) as? NSNumber)?.uint32Value
        let refreshHz = (defaults.object(forKey: refreshKey) as? NSNumber)?.uint32Value
        let orientationMode = defaults.string(forKey: orientationKey)
            .flatMap(DisplayOrientationMode.init(rawValue:)) ?? .automatic
        guard let width, let height, let refreshHz,
              width > 0, height > 0, refreshHz > 0 else {
            return DisplayPreference.defaultValue
        }
        return DisplayPreference(
            width: DisplayPreference.nativeLandscapeWidth,
            height: DisplayPreference.nativeLandscapeHeight,
            refreshHz: DisplayPreference.nativeRefreshHz,
            orientationMode: orientationMode)
    }

    static func save(_ preference: DisplayPreference) {
        let defaults = UserDefaults.standard
        defaults.set(preference.width, forKey: widthKey)
        defaults.set(preference.height, forKey: heightKey)
        defaults.set(preference.refreshHz, forKey: refreshKey)
        defaults.set(preference.orientationMode.rawValue, forKey: orientationKey)
    }
}
// [split: WireStreamParser.swift]

private final class ConnectionGenerationClock {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() -> UInt64 {
        lock.lock()
        value &+= 1
        let result = value
        lock.unlock()
        return result
    }
}

/// Thread-safe projection of the shared main-actor input owner's permission, not a readiness gate.
private final class RemoteMonitorControlAuthority {
    struct Snapshot: Equatable {
        var generation: UInt64 = 0
        var context: RemoteInputContextCommand?
        var enabled = false
        var available = false
        var revision: UInt64 = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func update(generation: UInt64, context: RemoteInputContextCommand?, enabled: Bool, available: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard value.generation != generation || value.context != context || value.enabled != enabled || value.available != available else { return }
        value.generation = generation; value.context = context; value.enabled = enabled; value.available = available; value.revision &+= 1
    }
}

// MARK: - Touch Input Wire Protocol
// Mirrors C# TouchInputPacket / TouchEventType exactly.
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic      0x5449  ('T','I')
//   [2]    UInt8   EventType  TouchEventType raw value
//   [3]    UInt8   Pressure   0–255  (mapped from 0.0–1.0)
//   [4-5]  UInt16  X          logical pixel column  (or 0–65535 normalised)
//   [6-7]  UInt16  Y          logical pixel row     (or 0–65535 normalised)

private enum TouchWireProtocol {
    static let magic: UInt16 = 0x5449   // 'T','I'
    static let packetSize    = 8
}

/// Touch event kinds — mirrors C# `TouchEventType` enum byte-for-byte.
public enum TouchEventType: UInt8 {
    case move  = 0
    case down  = 1
    case up    = 2
    case force = 3
}

enum InputDelivery: Equatable {
    case reliable
    case unreliableLatest
}

enum InputDeliveryPolicy {
    static func forEvent(_ eventType: TouchEventType) -> InputDelivery {
        eventType == .move ? .unreliableLatest : .reliable
    }
}

// MARK: - Telemetry Wire Protocol
// Telemetry (iPad → PC, 2×/sec)
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic      0x5445  ('T','E')
//   [2-3]  UInt16  Reserved   0
//   [4-5]  UInt16  NetworkLatencyMs
//   [6-7]  UInt16  DecodeLatencyMs

private enum TelemetryWireProtocol {
    static let magic: UInt16 = 0x5445   // 'T','E'
    static let packetSize    = 8
}

// MARK: - Bitrate Control Wire Protocol
// Bitrate Control (bidirectional sync)
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic           0x4243  ('B','C')
//   [2]    UInt8   IsAdaptive      0=manual, 1=adaptive
//   [3]    UInt8   Reserved        0
//   [4-5]  UInt16  TargetBitrateMbps
//   [6-7]  UInt16  Reserved        0

private enum BitrateWireProtocol {
    static let magic: UInt16 = 0x4243   // 'B','C'
    static let packetSize    = 8
}

// MARK: - Audio Wire Protocol
// Audio streaming: PC → iPad (variable-length)
// Layout: 4-byte header + N-byte PCM payload, little-endian:
//   [0-1]  UInt16  Magic        0x4155  ('A','U')
//   [2-3]  UInt16  PayloadSize  byte count of PCM data  (max 65535)
//   [4..N] byte[]  Raw PCM      16-bit / 48 kHz / Stereo / interleaved

private enum AudioWireProtocol {
    static let magic: UInt16 = 0x4155   // 'A','U'
    static let headerSize    = 4        // magic(2) + payloadSize(2)
}

// MARK: - NetworkManager

/// High-performance, TLS-secured outbound NWConnection to the ScreenCasting Windows host.
/// Implements:
///   1. TLS with custom self-signed certificate trust bypass (LAN-safe).
///   2. PIN authentication handshake phase before video payload begins.
///   3. Observable ConnectionState for SwiftUI bindings.
public class NetworkManager: ObservableObject {
    private static let lastKnownHostKey = "lastKnownScreenCastingHost.v1"
    private enum ActiveTransportKind: Equatable {
        case wifi
        case usb
    }

    // MARK: Published State
    @Published public var connectionState: ConnectionState = .idle
    /// Automatic reconnect try number while one is running; 0 otherwise.
    @Published public private(set) var autoReconnectAttempt = 0
    public private(set) var bytesReceived: UInt64 = 0
    @Published public private(set) var hostFingerprint: String?
    @Published public private(set) var hostIdentityCode: String?
    @Published public private(set) var usbServerFingerprint: String?
    /// Connected to the remote control service (whole PC) rather than the casting display.
    @Published public private(set) var isRemoteControlSession = false

    // The Host is the authority for selectable modes. These values only mirror
    // authenticated control responses for the connected settings surface.
    @Published private(set) var cursorOwnershipState: CursorOwnershipState?
    @Published private(set) var displayCapabilities: DisplayCapabilities?
    @Published private(set) var displayPreference = DisplayPreference.defaultValue
    @Published private(set) var effectiveDisplayState: DisplayReady?
    @Published private(set) var displayConfigurationFailureMessage: String?
    @Published private(set) var isDisplayConfigurationPending = false

    // MARK: Published stream settings
    /// Retained for compatibility with the existing telemetry surface. The
    /// persistent client settings contract is manual-only.
    @Published public var isAdaptiveBitrate: Bool   = false
    @Published public private(set) var desiredBitrateMbps: Double = 20
    @Published public private(set) var desiredAudioEnabled: Bool = true
    @Published public private(set) var desiredAdaptiveBitrateEnabled: Bool = false
    @Published public private(set) var effectiveBitrateMbps: Double = 20
    @Published public private(set) var effectiveAudioEnabled: Bool = true
    @Published public private(set) var settingsApplyStatus: String = ""
    @Published public private(set) var settingsGeneration: UInt64 = 0
    private var nextSettingsRequestID: UInt32 = 1
    private var clientSettingsState = ClientSettingsStateModel(
        desired: .normalized(bitrateMbps: 20, audioEnabled: true))
    private var settingsReconciliationGate = ClientSettingsReconciliationGate()
    private var settingsSyncPolicy = ClientSettingsSyncPolicy()

    // Convenience computed properties so existing views don't break
    public var isConnected:  Bool { connectionState == .streaming }
    public var isListening:  Bool { connectionState == .listening }

    // MARK: Private
    private var connection: NWConnection? {
        didSet { if oldValue !== connection { refreshAutoAcceptPolicyOnQueue() } }
    }
    private var transportState: ConnectionState = .idle
    private var verifiedHostFingerprint: String?
    private var verifiedHostIdentityCode: String?
    private var hostIdentityConfirmationRequired = false
    private var hostIdentityConfirmed = false
    private var trustedCredential: TrustedHostCredential?
    private let trustedCredentialStore = TrustedHostCredentialStore()
    private let trustedHostFingerprintStore = TrustedHostFingerprintStore()
    private let trustedDeviceID = TrustedDeviceIdentity.loadOrCreate()
    private var isForegroundActive = true
    private var reconnectEnabled = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var wifiBackgroundDisconnectWorkItem: DispatchWorkItem?
    private var wifiLifecycleTransitionGeneration: UInt64?
    private struct WifiWaitingOwner {
        let generation: UInt64
        let connectionID: ObjectIdentifier

        func owns(_ connection: NWConnection, generation: UInt64) -> Bool {
            self.generation == generation &&
                connectionID == ObjectIdentifier(connection)
        }
    }
    private var wifiWaitingOwner: WifiWaitingOwner?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var usbListener: NWListener?
    private var usbListenerExplicitlyStarted = false {
        didSet { if oldValue != usbListenerExplicitlyStarted { refreshAutoAcceptPolicyOnQueue() } }
    }
    private var usbScdpConnection: NWConnection?
    private var activeDirectTouchCommand: DirectTouchContactCommand?
    @Published private(set) var transferSnapshot = DataTransferManager.Snapshot()
    private var dataTransfers: DataTransferManager?
    private let retainedTransferRoot: URL
    private let receivedFilesQueue = DispatchQueue(label: "ScreenCasting.ReceivedFiles.IO", qos: .utility)
    private var receivedStorage: ReceivedFileLibrary? // receivedFilesQueue only.
    private var pendingStorageClear: (id: UUID, token: ReceivedFileLibrary.Confirmation, fingerprint: Data, storageRevision: UInt64)?
    private let receivedActionClock = ConnectionGenerationClock() // Separate lock-backed storage/UI epoch, not a transport clock.
    private var receivedUIRevision: UInt64 = 0 // Main queue only.
    private var pendingReceivedClearID: UUID? // networkQueue only.
    private var receivedRefreshInFlight = false, receivedRefreshRequested = false
    private var receivedTransferEvent = ""
    struct ReceivedFilesViewState {
        var files: [URL] = [], eligibleNames: Set<String> = [], fileBytes: [URL: UInt64] = [:]
        var retainedCount = 0, eligibleCount = 0
        var retainedBytes: UInt64 = 0, eligibleBytes: UInt64 = 0
        var busy = false, loaded = false
        var storageWarning: String?
        var legacyCount: Int { max(0, retainedCount - eligibleCount) }
        var legacyBytes: UInt64 { retainedBytes >= eligibleBytes ? retainedBytes - eligibleBytes : 0 }
        init() {}
        init(_ data: ReceivedFileLibrary.Inventory) {
            files=data.files;eligibleNames=data.eligibleNames;fileBytes=data.fileBytes
            retainedCount=data.retainedCount;eligibleCount=data.eligibleCount
            retainedBytes=data.retainedBytes;eligibleBytes=data.eligibleBytes;busy=data.busy;loaded=true
        }
    }
    struct ReceivedClearPrompt: Identifiable {
        let id: UUID, count: Int, bytes: UInt64, legacyCount: Int, legacyBytes: UInt64
    }
    @Published private(set) var receivedFilesViewState = ReceivedFilesViewState()
    @Published private(set) var receivedClearPrompt: ReceivedClearPrompt?
    @Published private(set) var receivedClearMessage: String?
    private var retainedFileLibrary: ReceivedFileLibrary? // Strong across retired transport generations; networkQueue owned.
    private var transferReceivePending = 0
    private struct TransferReceiveSuffix {
        let data: Data
        let receivedAt: TimeInterval
        let generation: UInt64
        let connection: NWConnection
        let isComplete: Bool
    }
    private var transferReceiveSuffix: TransferReceiveSuffix?
    private var wireReceiveOutstanding: (generation: UInt64, connection: ObjectIdentifier)?
    private let connectionGenerationClock = ConnectionGenerationClock()
    private var connectionGeneration: UInt64 {
        connectionGenerationClock.current
    }
    var remoteKeyboardGeneration: UInt64 { connectionGenerationClock.current }
    private var remoteInputConnection = false
    private var remoteFeatures = RemoteFeatureNegotiation(requestedFeatures: 7)
    private var remoteMonitors = RemoteMonitorState()
    private let remoteMonitorControl = RemoteMonitorControlAuthority()
    private var remoteMonitorAdmission: (requestId: UInt64, inputRevision: UInt64, controlRevision: UInt64)?
    private let remoteMonitorPublicationClock = ConnectionGenerationClock()
    @Published public private(set) var remoteMonitorState = RemoteMonitorState()
    private var remoteFeaturesPingNonce: UInt64?
    @Published public private(set) var remoteInputFeatures: UInt64 = 0
    @Published public private(set) var remoteInputReady = false
    @Published public private(set) var remoteInputContext: RemoteInputContextCommand?
    @Published public private(set) var remoteInputRevision: UInt64 = 0

    private var listenerGeneration: UInt64 = 0
    private struct PendingUsbCandidate {
        let id: UInt64
        let candidate: NWConnection
        let candidateID: ObjectIdentifier
        let listenerGeneration: UInt64
        let incumbent: NWConnection
        let incumbentGeneration: UInt64
        let deadline: TimeInterval
        var livenessNonce: UInt64?
    }
    private var pendingUsbCandidate: PendingUsbCandidate?
    private var usbCandidateDeadlineWork: DispatchWorkItem?
    private var nextUsbCandidateID: UInt64 = 1
    private static let usbCandidateArbitrationTimeout: TimeInterval = 0.75
    #if targetEnvironment(simulator)
    var manualUsbCandidateDeadlineForTesting = false
    var usbCandidateInstalledForTesting: ((NWConnection) -> Void)?
    /// Called from the production listener handler; tests must not swap that handler after start.
    var usbListenerStateObservedForTesting: ((NWListener, NWListener.State) -> Void)?
    #endif
    private let mirrorControl = MirrorClientControl()
    @Published public private(set) var captureTargetState = CaptureTargetState()
    private var captureTargets = CaptureTargetState()
    private var captureTargetVideo = CaptureTargetVideoBuffer()
    private var captureTargetCatalogueAt: TimeInterval = 0
    private var captureTargetMirrorRevisionAtTap: UInt64 = 0
    private var captureTargetDecodeStarted = false
    private var captureTargetLastVideoSequence: UInt32?
    private var captureTargetH264ParameterSets: [Data]?
    private var captureTargetRecoveryToken: UUID?
    private var captureTargetRecoveryWork: [DispatchWorkItem] = []
    private struct CaptureTargetDecoderOwner: Equatable {
        let session: UUID
        let generation: UInt64, transaction: UInt64, owner: UInt64, epoch: UInt64, source: UInt64, decoder: UInt64
        let kind: CaptureTargetKind
        let mirrorEpoch: UInt64
    }
    // Protected by mirrorDecoderLock, including reads from the completed Metal callback.
    private var captureTargetDecoderOwner: CaptureTargetDecoderOwner?
    // Installed and invoked only by the main-thread presentation surface.
    var captureTargetRetireInput: (() -> Void)?
    #if targetEnvironment(simulator)
    var captureTargetScheduleForTesting: ((TimeInterval, @escaping () -> Void) -> Void)?
    var captureTargetDecodeForTesting: ((Data, UInt32, UInt64) -> Void)?
    #endif
    @Published public private(set) var mirrorControlState: MirrorControlState?
    @Published public private(set) var mirrorMonitorCatalogue: MirrorMonitorCatalogue?
    @Published public private(set) var mirrorMonitorSwitchPending=false
    @Published public private(set) var mirrorScreenPickerSupported=false
    private var currentMirrorCatalogue: MirrorMonitorCatalogue?
    private var mirrorCatalogueSource: (epoch:UInt64,source:UInt64)?
    private var lastMirrorCatalogueRevision:UInt64=0
    private var mirrorSwitchPending=false
    private var mirrorSwitchAttempt: UUID?
    private var mirrorSwitchDeadlineToken:UUID?
    private var mirrorSwitchAdvertised=false
    private struct MirrorTerminalSend {
        let attempt:UUID, nonce:UInt64, generation:UInt64, connection:NWConnection, payload:Data
        let catalogueReceivedAt:TimeInterval
        var written=false
    }
    private var mirrorTerminalSend:MirrorTerminalSend?
    private var nextMirrorTerminalNonce:UInt64=0
    private var mirrorCatalogueReceivedAt:TimeInterval=0
    @Published public private(set) var mirrorInputRevision: UInt64 = 0
    private struct MirrorDecoderOwner: Equatable {
        let connection: UInt64, decoder: UInt64, epoch: UInt64, source: UInt64
    }
    private let mirrorDecoderLock = NSLock()
    private var mirrorDecoderOwner: MirrorDecoderOwner?
    private var nextMirrorDecoder: UInt64 = 0x8000_0000_0000_0000
    private let networkQueueKey = DispatchSpecificKey<Bool>()
    private let networkQueue = DispatchQueue(label: "com.iPadCasting.network", qos: .userInteractive)
    private lazy var controlChannelWriter = ControlChannelWriter(
        queue: networkQueue,
        sender: { [weak self] data, diagnostic, completion in
            guard let self else {
                completion(.posix(.ECANCELED))
                return
            }
            if !self.remoteInputPacketIsCurrent(data) || !self.captureTargetPacketIsCurrent(data) {
                completion(nil)
                return
            }
            #if targetEnvironment(simulator)
            if let controlSendForAudioTesting = self.controlSendForAudioTesting {
                controlSendForAudioTesting(data, completion)
                return
            }
            #endif
            let connection = self.activeControlConnection
            if let diagnostic {
                self.recordUsbTouchSendDiagnostic(
                    "[USB_TOUCH_SEND_ATTEMPT]",
                    diagnostic: diagnostic,
                    payloadLength: data.count,
                    error: nil)
            }
            guard let connection else {
                if let diagnostic {
                    self.recordUsbTouchSendDiagnostic(
                        "[USB_TOUCH_SEND_FAILURE]",
                        diagnostic: diagnostic,
                        payloadLength: data.count,
                        error: "no_active_control_connection")
                }
                completion(.posix(.ENOTCONN))
                return
            }
            connection.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    if let diagnostic, let self {
                        self.recordUsbTouchSendDiagnostic(
                            error == nil
                                ? "[USB_TOUCH_SEND_SUCCESS]"
                                : "[USB_TOUCH_SEND_FAILURE]",
                            diagnostic: diagnostic,
                            payloadLength: data.count,
                            error: error.map { String(describing: $0) })
                    }
                    completion(error)
                })
        })
    private lazy var wireParser = WireParserQueueDomain(
        generation: connectionGeneration,
        queue: networkQueue)
    private var wireReceiveActiveGeneration: UInt64?
    #if targetEnvironment(simulator)
    private var testingSimulatedWifiSession = false
    private var testingInitialReceiveStarts = 0
    private var testingWriterBegins = 0
    private var testingClientHelloCount = 0
    private var testingPingAttempts = 0
    #endif
    private var wireAuthenticatedGeneration: UInt64? {
        didSet { if oldValue != wireAuthenticatedGeneration {
            refreshAutoAcceptPolicyOnQueue()
            mirrorControl.beginSession(wireAuthenticatedGeneration ?? 0)
            captureTargets.begin(generation: wireAuthenticatedGeneration ?? 0)
            captureTargetVideo.reset();captureTargetCatalogueAt=0;captureTargetDecodeStarted=false
            captureTargetH264ParameterSets=nil
            cancelCaptureTargetRecoveryOnQueue()
            mirrorDecoderLock.lock();captureTargetDecoderOwner=nil;mirrorDecoderLock.unlock()
            currentMirrorCatalogue=nil;mirrorCatalogueSource=nil;lastMirrorCatalogueRevision=0
            mirrorSwitchAdvertised=false;mirrorSwitchPending=false
            mirrorSwitchAttempt=nil;mirrorSwitchDeadlineToken=nil
            mirrorTerminalSend=nil;mirrorCatalogueReceivedAt=0
            mirrorDecoderLock.lock(); mirrorDecoderOwner = nil; mirrorDecoderLock.unlock()
            publishMirrorStateOnQueue()
        } }
    }
    private var committedTransportGeneration: UInt64? {
        didSet { if oldValue != committedTransportGeneration { refreshAutoAcceptPolicyOnQueue() } }
    }
    private var audioDiagnosticGeneration: UInt64?
    private var audioDiagnosticPublishedAt: TimeInterval = 0
    private var pendingTransportOffer: TransportOffer?
    private var activeVideoCodec: VideoDecoderCodec = .hevc
    private var wifiCommitGate = WifiCommitGate()
    private var usbSplitCommitGate = UsbSplitCommitGate()
    private var advertisedClientCapabilities: ClientCapabilities?
    private var negotiationFallbackToken: UInt64 = 0
    private lazy var wifiMediaReceiver = WifiMediaReceiver(
        networkQueue: networkQueue,
        decoder: { [weak self] data, sequence, isIDR, receivedAt in
            guard let self,
                  self.committedTransportGeneration == self.connectionGeneration,
                  self.committedRealtimeMode == RealtimeTransportMode.wifiRTP else { return }
            if self.captureTargetOwnsPresentation {
                self.recordVideoPayloadReceived(data.count, sequence: sequence)
                _=self.consumeCaptureTargetVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                    lengthPrefixed: true, receivedAt: receivedAt)
                return
            }
            guard self.mirrorControl.permitsVideoSequence(sequence) else { return }
            self.recordVideoPayloadReceived(data.count, sequence: sequence)
            self.decoder.processInputData(
                data,
                sequence: sequence,
                isIDR: isIDR,
                isLengthPrefixed: true,
                receivedAt: receivedAt)
        },
        audioConsumer: { data, sequence, timestamp, generation in
            AudioManager.shared.playOpusData(
                data,
                sequence: sequence,
                timestamp: timestamp,
                generation: generation)
        },
        onProbeAuthenticated: { [weak self] generation, sessionID in
            self?.handleWifiProbeAuthenticated(
                generation: generation,
                sessionID: sessionID)
        },
        onCommittedFailure: { [weak self] generation, error in
            self?.handleWifiCommittedFailure(
                generation: generation,
                error: error)
        },
        framePacketObserver: {
            [weak self] generation, sequence, marker, isIDR, bytes, arrivalTime in
            guard let self else { return }
            self.transportTelemetry.recordWifiPacket(
                sequence: sequence,
                marker: marker,
                isIDR: isIDR,
                bytes: bytes,
                arrivalTime: arrivalTime,
                generation: generation)
        },
        timedOutcomeObserver: {
            [weak self] generation, outcome, observedAt in
            guard let self else { return }
            self.transportTelemetry.recordWifiReassembly(
                outcome: outcome,
                observedAt: observedAt,
                generation: generation)
        },
        securityDropObserver: { [weak self] counters in
            self?.transportTelemetry.recordWifiSecurityDrops(counters)
        },
        rttObserver: { [weak self] durationMs in
            self?.transportTelemetry.recordRtt(durationMs: durationMs)
        },
        telemetryProvider: { [weak self] in
            guard let self else { return .zero }
            self.publishHudSnapshotIfDue()
            self.publishAudioDiagnosticsIfDue()
            let feedback = self.transportTelemetry.makeFeedback()
            return WifiFeedbackTelemetry(
                lastDecoded: feedback.1,
                lastPresented: feedback.0,
                jitterMs: 0,
                rttP95Ms: feedback.2,
                queueAgeP95Ms: feedback.4,
                decodeP95Ms: feedback.3)
        })
    private var usbLaneConnections: [UsbLaneKind: NWConnection] = [:]
    private lazy var usbLaneServer = UsbLaneServer(
        networkQueue: networkQueue,
        parametersProvider: { [weak self] in
            guard let self else { throw USBListenerError.identityUnavailable }
            return try self.buildUSBListenerParameters()
        },
        onBound: { [weak self] token, _, connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.adoptUsbLane(token, connection: connection)
        },
        onFailure: { [weak self] error in
            self?.handleStreamError(
                "USB media lane failed: \(error.localizedDescription)")
        })

    // Telemetry timer: fires 2× per second while streaming.
    private var telemetryTimer: DispatchSourceTimer?
    private var performanceFeedbackTimer: DispatchSourceTimer?
    private var performanceFeedbackSequence: UInt32 = 0
    private var adaptiveTelemetryTimer: DispatchSourceTimer?
    private var committedRealtimeMode: UInt8? {
        didSet { if oldValue != committedRealtimeMode {
            _ = realtimeModeClock.advance()
            if oldValue != nil, committedRealtimeMode != nil, captureTargets.enabled {
                captureTargets.retireRoute()
                retireCaptureTargetDecoderOnQueue()
                mirrorControl.setCaptureTargetInputBlocked(true)
                refreshCaptureTargetsOnQueue();publishMirrorStateOnQueue()
            }
        } }
    }
    // Lock-protected epoch of committedRealtimeMode so main-thread closures never read the queue-owned value.
    private let realtimeModeClock = ConnectionGenerationClock()
    private var committedTransportAudioAvailable = false
    private var committedRealtimeSessionID: SessionID?
    private var wifiLegacyFallbackGeneration: UInt64?
    private var wifiLegacyFallbackRequestGeneration: UInt64?
    private let transportTelemetry = TransportTelemetry()
    private var videoPayloadCounter = VideoPayloadCounter()
    private var videoRxSampler = VideoPayloadRateSampler()
    private var clientDebugLoggingEnabled = false
    private var lastHudSnapshotPublishedAt: TimeInterval = 0
    private var lastClientPingSentAt: TimeInterval = 0
    private var nextClientPingNonce: UInt64 = 1
    private enum ClientPingPurpose { case telemetry, usbLegacyPcmFreshFence, usbCandidateLiveness }
    private struct PendingClientPing {
        let sentAt: TimeInterval
        let purpose: ClientPingPurpose
        let generation: UInt64
        let connectionID: ObjectIdentifier
    }
    private var pendingClientPings: [UInt64: PendingClientPing] = [:]
    private var usbLegacyPcmFreshFenceNonce: UInt64?
    private var usbLegacyPcmFreshFenceGeneration: UInt64?
    private var legacyUsbPlaybackEnabledGeneration: UInt64?
    private var activeDisplayCapabilities: DisplayCapabilities?
    private var desiredPipelineMode: PipelineMode = .office
    private var committedPipelineMode = CommittedPipelineModeState()
    private var activeDisplayPreference = DisplayPreference.defaultValue
    private var displayRequestGate = DisplayRequestGate()
    private var pendingDisplayPreference: DisplayPreference?
    private var latestDisplayPreference: DisplayPreference?
    private var observedInterfaceOrientation: ClientDisplayOrientation?
    private var orientationDebounceWorkItem: DispatchWorkItem?
    private static let usbTouchMoveDiagnosticInterval: TimeInterval = 0.25
    private var usbTouchDiagnosticSequence: UInt64 = 0
    private var lastUsbTouchMoveDiagnosticAt: TimeInterval = 0
    private static let wifiBackgroundDisconnectGrace =
        WifiLifecyclePolicy.backgroundGrace
    private var pendingUsbForegroundDecoderRearmGeneration: UInt64?

    #if targetEnvironment(simulator)
    private var testingVideoFeedbackCount = 0
    var videoFeedbackCountForTesting: Int { testingVideoFeedbackCount }
    #endif

    public init(userDefaults: UserDefaults = .standard, receivedFilesDirectory: URL? = nil) {
        retainedTransferRoot = receivedFilesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenCasting Transfers")
        networkQueue.setSpecific(key: networkQueueKey, value: true)
        clientDebugLoggingEnabled = ClientDebugLoggingPreference.load(
            defaults: userDefaults)
        let desired = ClientStreamSettingsStore.load(defaults: userDefaults)
        clientSettingsState = ClientSettingsStateModel(desired: desired)
        desiredBitrateMbps = desired.bitrateMbps
        desiredAudioEnabled = desired.audioEnabled
        desiredAdaptiveBitrateEnabled = desired.adaptiveBitrateEnabled
        reconnectEnabled = RecentWifiResumeStore.consumeIfValid()
        print(
            "[IPAD][APP_LIFECYCLE] state=relaunch_resume " +
            "intent=\(reconnectEnabled ? "accepted" : "expired_or_absent")")
        let savedDisplayPreference = DisplayPreferenceStore.load()
        displayPreference = savedDisplayPreference
        activeDisplayPreference = savedDisplayPreference
        decoder.diagnosticSink = { [weak self] line in
            self?.recordDiagnosticLine(line)
        }
        decoder.onDecodeLatency = {
            [weak self] sequence, generation, decodeStartedAt, latencyMs in
            self?.transportTelemetry.recordDecodeCallback(
                sequence: sequence,
                generation: generation,
                decodeStartedAt: decodeStartedAt,
                durationMs: latencyMs)
        }
        decoder.onDecodeCompleted = {
            [weak self] sequence, generation, succeeded in
            guard let self else { return }
            self.networkQueue.async {
                let networkGeneration: UInt64
                if let owner = self.currentCaptureTargetDecoderOwner, owner.decoder == generation { networkGeneration = owner.generation }
                else if let owner = self.currentMirrorDecoderOwner, owner.decoder == generation { networkGeneration = owner.connection }
                else if generation & 0x8000_0000_0000_0000 == 0 { networkGeneration = generation }
                else { return }
                self.wifiMediaReceiver.decoderDidComplete(
                    sequence: sequence,
                    generation: networkGeneration,
                    succeeded: succeeded)
            }
        }
        decoder.onFrameDropped = { [weak self] sequence, generation in
            self?.transportTelemetry.recordDropped(
                sequence: sequence,
                generation: generation)
        }
        decoder.onMailboxAge = { [weak self] sequence, ageMs in
            self?.transportTelemetry.recordMailboxAge(sequence: sequence, ageMs: ageMs)
        }
        decoder.onRecoveryNeeded = { [weak self] in
            guard let self else { return }
            self.networkQueue.async {
                guard self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
                if self.captureTargets.applied != nil {
                    self.recoverCaptureTargetDecodeRootOnQueue()
                } else if self.committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                    self.wifiMediaReceiver.requestImmediateRecoveryFeedback(
                        generation: self.connectionGeneration)
                } else {
                    self.sendVideoFeedback()
                }
            }
        }
        refreshReceivedFiles()
    }

    // MARK: - Public API

    public func setDesiredPipelineMode(_ mode: PipelineMode) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.desiredPipelineMode = mode
            self.committedPipelineMode.request(mode)
            guard self.wireAuthenticatedGeneration ==
                    self.connectionGeneration else { return }
            self.sendDesiredPipelineMode(reason: "user_preference")
        }
    }

    /// Connect to the Windows host over TLS using an NWEndpoint directly (e.g. from Bonjour discovery).
    /// - Parameter endpoint: The resolved NWEndpoint (service endpoint or hostPort)
    public func connect(to endpoint: NWEndpoint) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            if let target = WifiReconnectTargetPolicy.target(from: endpoint) {
                WifiReconnectTargetStore.save(target)
            }
            self.publishAutoReconnectAttempt(0)
            self.connectOnQueue(to: endpoint)
        }
    }

    /// The last Wi-Fi PC (saved target, or the legacy typed host) can be reconnected to.
    public var hasReconnectTarget: Bool {
        WifiReconnectTargetSelection.preferred(
            structured: WifiReconnectTargetStore.load(),
            legacyHost: UserDefaults.standard.string(forKey: Self.lastKnownHostKey))?.endpoint != nil
    }

    /// One-tap Reconnect on the connect screen: the same endpoint automatic reconnects use.
    public func reconnectLastPC() {
        networkQueue.async { [weak self] in
            guard let self, let endpoint = self.loadWifiReconnectEndpoint() else { return }
            self.publishAutoReconnectAttempt(0)
            self.connectOnQueue(to: endpoint)
        }
    }

    private func publishAutoReconnectAttempt(_ attempt: Int) {
        DispatchQueue.main.async { self.autoReconnectAttempt = attempt }
    }

    private func connectOnQueue(to endpoint: NWEndpoint) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        reconnectEnabled = true
        guard transportState == .idle || isDisconnectedOnQueue else { return }

        wifiLifecycleTransitionGeneration = nil
        wifiWaitingOwner = nil
        _ = connectionGenerationClock.advance()
        resetAutoAcceptOnQueue()
        advanceReceivedRevisionOnQueue()
        resetDirectTouchSessionOnQueue()
        #if targetEnvironment(simulator)
        testingSimulatedWifiSession = false
        #endif
        // Settings generations are scoped to the Host credential/session.
        // After Forget Host (or a fresh pairing), the Host may legitimately
        // start again at generation zero; retaining the old value would cause
        // the client to discard the authoritative state and send stale writes.
        clientSettingsState.resetHostGeneration()
        settingsReconciliationGate.reset()
        settingsSyncPolicy.reset()
        let isRemoteControl = RemoteSessionPolicy.isRemoteControl(endpoint: endpoint)
        remoteInputConnection = isRemoteControl
        resetRemoteInputOnQueue()

        DispatchQueue.main.async {
            self.isRemoteControlSession = isRemoteControl
            self.settingsGeneration = 0
            self.settingsApplyStatus = ""
            self.hostIdentityCode = nil
        }
        verifiedHostFingerprint = nil
        verifiedHostIdentityCode = nil
        hostIdentityConfirmationRequired = false
        hostIdentityConfirmed = false
        reconnectWorkItem?.cancel()
        resetDisplaySession()
        let parameters = buildTLSParameters(for: endpoint)
        let newConnection = NWConnection(to: endpoint, using: parameters)
        connection = newConnection

        setupStateHandler(for: newConnection)
        setState(.connecting)
        print("[IPAD][TCP_CONNECT] endpoint=\(endpoint)")
        connectionTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.transportState == .connecting else { return }
            print("[IPAD][TIMEOUT] stage=TCP/TLS timeout=8s")
            self.connection?.cancel()
            self.setState(.disconnected(reason: "Timed out connecting to Windows host."))
        }
        connectionTimeoutWorkItem = timeout
        networkQueue.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection?.start(queue: networkQueue)
    }

    /// Port of the remote control service (ScreenCastingRemoteHost) — same protocol, the PC's real screen.
    public static let remoteControlPort: UInt16 = 27020

    /// Connect to the Windows host over TLS using host String IP & port.
    /// - Parameters:
    ///   - host: Host IP or mDNS hostname (e.g. "192.168.1.10" or "LÂM-DESKTOP.local")
    ///   - port: TCP port the Windows NetworkManager listens on (default 27015)
    public func connect(to host: String, port: UInt16 = 27015) {
        UserDefaults.standard.set(host, forKey: Self.lastKnownHostKey)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connect(to: endpoint)
    }

    public func applicationDidBecomeActive() {
        setMirrorInputForeground(true)
        networkQueue.async { [weak self] in
            guard let self else { return }
            let diagnosticForegroundBefore = self.isForegroundActive
            self.recordAppAudioLifecycleDiagnostic(event: "did_become_active", phase: "received", foregroundBefore: diagnosticForegroundBefore)
            defer { self.recordAppAudioLifecycleDiagnostic(event: "did_become_active", phase: "applied", foregroundBefore: diagnosticForegroundBefore) }
            let wasForegroundActive = self.isForegroundActive
            self.isForegroundActive = true
            if !wasForegroundActive,
               self.connection != nil,
               self.transportState == .streaming,
               self.wireAuthenticatedGeneration == self.connectionGeneration,
               self.committedTransportGeneration == self.connectionGeneration {
                self.transportTelemetry.beginFreshFrameRate(
                    generation: self.connectionGeneration, at: self.performanceFeedbackTime())
            }
            let inactiveGeneration = self.wifiLifecycleTransitionGeneration
            self.wifiLifecycleTransitionGeneration = nil
            if inactiveGeneration == self.connectionGeneration,
               self.wifiBackgroundDisconnectWorkItem == nil,
               self.isCurrentCommittedWifiRtpStreamingSessionOnQueue(),
               let currentConnection = self.connection,
               !self.isWifiConnectionReadyOnQueue(
                   currentConnection, generation: self.connectionGeneration) {
                self.recordWifiLifecycleDiagnostic(
                    "generation=\(self.connectionGeneration) event=foreground " +
                    "action=terminal_fallback reason=inactive_without_grace")
                self.handleStreamError(
                    "Wi-Fi connection remained unavailable after inactive transition.")
                return
            }
            if self.isCurrentCommittedWifiRtpStreamingSessionOnQueue(),
               self.wifiBackgroundDisconnectWorkItem != nil,
               let currentConnection = self.connection,
               !self.isWifiConnectionReadyOnQueue(
                   currentConnection, generation: self.connectionGeneration) {
                self.recordWifiLifecycleDiagnostic(
                    "generation=\(self.connectionGeneration) event=foreground " +
                    "nw_state=waiting action=defer_same_session_resume")
                return
            }
            self.wifiBackgroundDisconnectWorkItem?.cancel()
            self.wifiBackgroundDisconnectWorkItem = nil
            RecentWifiResumeStore.clear()

            if let generation = self.consumeUsbForegroundDecoderRearmIfEligibleOnQueue() {
                self.recordUsbLifecycleDiagnostic(
                    "[USB_MEDIA_RECOVERY] generation=\(generation) " +
                    "action=decoder_invalidate_begin")
                self.decoder.invalidate(waitForCompletion: false)
                guard self.isCurrentCommittedUsbStreamingSessionOnQueue(
                    generation: generation) else {
                    self.recordUsbLifecycleDiagnostic(
                        "[USB_MEDIA_RECOVERY] scheduled_generation=\(generation) " +
                        "current_generation=\(self.connectionGeneration) action=skip_stale")
                    return
                }
                self.armLegacyUsbPcmFreshFence(generation: generation)
                self.beginOwnedDecoderSession(networkGeneration: generation)
                self.sendVideoFeedback()
                self.recordUsbLifecycleDiagnostic(
                    "[USB_MEDIA_RECOVERY] generation=\(generation) " +
                    "action=decoder_rearmed recovery_requested=true")
                return
            }

            if !wasForegroundActive,
               self.usbLegacyPcmFreshFenceGeneration == self.connectionGeneration,
               self.isCurrentCommittedUsbStreamingSessionOnQueue() {
                self.armLegacyUsbPcmFreshFence(generation: self.connectionGeneration)
            }

            if !wasForegroundActive,
               self.isCurrentCommittedWifiRtpStreamingSessionOnQueue(),
               let currentConnection = self.connection {
                if self.resumeCommittedWifiSessionOnQueue(
                    connection: currentConnection,
                    generation: self.connectionGeneration) {
                    return
                }
            }

            if !self.usbListenerExplicitlyStarted,
               self.connection != nil,
               self.transportState == .streaming,
               self.wireAuthenticatedGeneration == self.connectionGeneration {
                if self.committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                    self.wifiMediaReceiver.requestImmediateRecoveryFeedback(
                        generation: self.connectionGeneration)
                }
                self.sendClientPingIfDue()
                print(
                    "[IPAD][APP_LIFECYCLE] state=active transport=wifi " +
                    "action=resume_preserved generation=\(self.connectionGeneration)")
                return
            }

            print("[IPAD][APP_LIFECYCLE] state=active")
            if self.connection == nil || self.isDisconnectedOnQueue {
                print("[IPAD][APP_LIFECYCLE] state=active transport=wifi action=reconnect")
                self.scheduleAutoReconnect(reset: true)
            }
        }
    }

    public func applicationWillResignActive() {
        setMirrorInputForeground(false)
        networkQueue.async { [weak self] in
            guard let self else { return }
            let diagnosticForegroundBefore = self.isForegroundActive
            self.recordAppAudioLifecycleDiagnostic(event: "will_resign_active", phase: "received", foregroundBefore: diagnosticForegroundBefore)
            defer { self.recordAppAudioLifecycleDiagnostic(event: "will_resign_active", phase: "applied", foregroundBefore: diagnosticForegroundBefore) }
            self.cancelActiveDirectTouchOnQueue()
            self.isForegroundActive = false
            // Foreground eligibility is closed first; discard its old sample window.
            self.transportTelemetry.beginFreshFrameRate(
                generation: self.connectionGeneration, at: self.performanceFeedbackTime())
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            if self.isCurrentCommittedWifiRtpStreamingSessionOnQueue() {
                self.wifiLifecycleTransitionGeneration = self.connectionGeneration
                self.recordWifiLifecycleDiagnostic(
                    "generation=\(self.connectionGeneration) event=inactive " +
                    "action=arm_transition_preservation")
            } else {
                self.wifiLifecycleTransitionGeneration = nil
            }
            print("[IPAD][APP_LIFECYCLE] state=inactive action=preserve_session")
        }
    }

    public func applicationDidEnterBackground() {
        setMirrorInputForeground(false)
        networkQueue.async { [weak self] in
            guard let self else { return }
            let diagnosticForegroundBefore = self.isForegroundActive
            self.recordAppAudioLifecycleDiagnostic(event: "did_enter_background", phase: "received", foregroundBefore: diagnosticForegroundBefore)
            defer { self.recordAppAudioLifecycleDiagnostic(event: "did_enter_background", phase: "applied", foregroundBefore: diagnosticForegroundBefore) }
            self.isForegroundActive = false
            // Foreground eligibility is closed first; discard its old sample window.
            self.transportTelemetry.beginFreshFrameRate(
                generation: self.connectionGeneration, at: self.performanceFeedbackTime())
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.wifiBackgroundDisconnectWorkItem?.cancel()
            self.wifiBackgroundDisconnectWorkItem = nil

            guard !self.usbListenerExplicitlyStarted else {
                self.wifiLifecycleTransitionGeneration = nil
                if self.isCurrentCommittedUsbStreamingSessionOnQueue() {
                    if self.legacyUsbPlaybackEnabledGeneration == self.connectionGeneration {
                        self.cancelLegacyUsbPcmFreshFence()
                        self.usbLegacyPcmFreshFenceGeneration = self.connectionGeneration
                        AudioManager.shared.suspendLegacySessionForLifecycle(
                            generation: self.connectionGeneration,
                            newBackgroundCycle: self.pendingUsbForegroundDecoderRearmGeneration != self.connectionGeneration)
                    }
                    self.pendingUsbForegroundDecoderRearmGeneration =
                        self.connectionGeneration
                    print(
                        "[IPAD][APP_LIFECYCLE] state=background transport=usb " +
                        "action=preserve_session " +
                        "decoder_rearm_generation=\(self.connectionGeneration)")
                } else {
                    print(
                        "[IPAD][APP_LIFECYCLE] state=background transport=usb " +
                        "action=preserve_session")
                }
                return
            }

            guard let currentConnection = self.connection else {
                self.wifiLifecycleTransitionGeneration = nil
                print("[IPAD][APP_LIFECYCLE] state=background transport=wifi connection=none")
                return
            }

            let generation = self.connectionGeneration
            self.markRecentWifiResumeIntentIfEligible()
            let work = DispatchWorkItem { [weak self, weak currentConnection] in
                guard let self,
                      let currentConnection,
                      WifiLifecyclePolicy.shouldTearDownAfterGrace(
                        isForegroundActive: self.isForegroundActive,
                        isUSB: self.usbListenerExplicitlyStarted,
                        scheduledGeneration: generation,
                        currentGeneration: self.connectionGeneration,
                        hasSameConnection: self.connection === currentConnection,
                        isWaiting: !self.isWifiConnectionReadyOnQueue(
                            currentConnection, generation: generation)) else {
                    return
                }
                self.recordWifiLifecycleDiagnostic(
                    "generation=\(generation) event=grace_expired " +
                    "foreground=\(self.isForegroundActive) " +
                    "waiting=\(self.wifiWaitingOwner?.owns(currentConnection, generation: generation) == true) " +
                    "action=terminal_fallback")
                self.handleStreamError(
                    "Application remained backgrounded; reconnecting on resume.")
            }
            self.wifiBackgroundDisconnectWorkItem = work
            self.networkQueue.asyncAfter(
                deadline: .now() + Self.wifiBackgroundDisconnectGrace,
                execute: work)
            if self.wifiLifecycleTransitionGeneration == generation {
                self.wifiLifecycleTransitionGeneration = nil
                self.recordWifiLifecycleDiagnostic(
                    "generation=\(generation) event=background " +
                    "action=handoff_to_grace")
            }
            print(
                "[IPAD][APP_LIFECYCLE] state=background transport=wifi " +
                "action=graceful_preserve grace_s=\(Self.wifiBackgroundDisconnectGrace)")
        }
    }

    public func connectDiscoveredHostIfNeeded(_ endpoint: NWEndpoint) {
        networkQueue.async { [weak self] in
            guard let self,
                  self.isForegroundActive,
                  self.reconnectEnabled,
                  !self.usbListenerExplicitlyStarted,
                  self.activeTransportKind != .usb,
                  self.transportState == .idle || self.isDisconnectedOnQueue else { return }
            self.connectOnQueue(to: endpoint)
        }
    }

    /// Confirms the displayed Wi-Fi Host identity after the user compares it
    /// with the identity code shown by the Windows Host.
    public func confirmHostIdentity() {
        networkQueue.async { [weak self] in
            guard let self,
                  self.hostIdentityConfirmationRequired,
                  self.verifiedHostFingerprint != nil,
                  self.verifiedHostIdentityCode != nil,
                  self.transportState == .awaitingHostIdentity else { return }
            self.hostIdentityConfirmed = true
            self.hostIdentityConfirmationRequired = false
            self.sendTrustedClientHello(generation: self.connectionGeneration)
        }
    }

    /// Sends the 4-digit PIN to the server as an 8-byte AuthPacketHeader.
    /// Should only be called when state == .awaitingPIN.
    public func sendAuthPIN(_ pin: String) {
        networkQueue.async { [weak self] in
            guard let self,
                  (self.transportState == .awaitingPIN || self.isAuthFailedOnQueue),
                  self.activeTransportKind == .usb || self.hostIdentityConfirmed,
                  let pinValue = UInt32(pin), pin.count == 4 else { return }
            var packet = Data(count: AuthProtocol.packetSize)
            packet.withUnsafeMutableBytes { buf in
                buf.storeBytes(of: AuthProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
                buf.storeBytes(of: pinValue.littleEndian, toByteOffset: 4, as: UInt32.self)
            }
            let generation = self.connectionGeneration
            self.enqueueControlData(packet) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.setState(.disconnected(reason: "PIN send failed: \(error)"))
                } else if generation == self.connectionGeneration {
                    self.receiveAuthResponse(generation: generation)
                }
            }
        }
    }

    /// Sends raw data back to the host.
    /// ⚠️ Legacy method — prefer `sendTouchEvent(type:x:y:pressure:)` for typed packets.
    public func sendData(_ data: Data) {
        networkQueue.async { [weak self] in
            guard let self, self.transportState == .streaming else { return }
            self.enqueueControlData(data) { error in
                if let error {
                    print("[NetworkManager] sendData error: \(error)")
                }
            }
        }
    }

    // MARK: - Public API: Touch Input Sender

    /// Sends one 8-byte Touch Input packet to the C# host over the active TLS stream.
    ///
    /// ## Concurrency Safety
    /// `NWConnection.send` is internally serialised onto its private dispatch queue
    /// (`networkQueue`). Calling this from ANY thread — including the 240Hz Pencil
    /// callback or a SwiftUI gesture handler — is safe and does **not** block.
    /// The incremental SCST receive loop runs on the same
    /// `NWConnection` but TCP full-duplex means TX and RX are independent at the OS level.
    ///
    /// ## Wire Format (8 bytes, little-endian)
    /// ```
    /// ┌────────┬──────────┬──────────┬──────┬──────┐
    /// │ Magic  │ EventType│ Pressure │  X   │  Y   │
    /// │ UInt16 │  UInt8   │  UInt8   │UInt16│UInt16│
    /// │ 0x5449 │  0–3     │  0–255   │      │      │
    /// └────────┴──────────┴──────────┴──────┴──────┘
    /// ```
    /// - Parameters:
    ///   - type:     Touch event kind (`.move`, `.down`, `.up`, `.force`).
    ///   - x:        Horizontal position in logical pixels (0–65535 for normalised use).
    ///   - y:        Vertical position in logical pixels (0–65535 for normalised use).
    ///   - pressure: Normalised pressure mapped to 0–255 byte range.
    public func sendTouchEvent(type: TouchEventType, x: UInt16, y: UInt16, pressure: UInt8) {
        guard mirrorControl.allowsLegacyVirtualInput else { return }
        let requestedGeneration = connectionGenerationClock.current
        // Build the 8-byte packet inline — stack allocation, no heap alloc.
        var packet = Data(count: TouchWireProtocol.packetSize)
        packet.withUnsafeMutableBytes { buf in
            // Bytes 0-1: Magic 0x5449 LE
            buf.storeBytes(of: TouchWireProtocol.magic.littleEndian,
                           toByteOffset: 0, as: UInt16.self)
            // Byte 2: EventType
            buf.storeBytes(of: type.rawValue,
                           toByteOffset: 2, as: UInt8.self)
            // Byte 3: Pressure (0–255)
            buf.storeBytes(of: pressure,
                           toByteOffset: 3, as: UInt8.self)
            // Bytes 4-5: X LE
            buf.storeBytes(of: x.littleEndian,
                           toByteOffset: 4, as: UInt16.self)
            // Bytes 6-7: Y LE
            buf.storeBytes(of: y.littleEndian,
                           toByteOffset: 6, as: UInt16.self)
        }

        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration, self.mirrorControl.allowsLegacyVirtualInput else { return }
            let generation = requestedGeneration
            let isUsb = self.activeTransportKind == .usb
            let diagnostic = isUsb
                ? self.nextUsbTouchDiagnostic(type: type)
                : nil
            let isCommittedGeneration =
                self.committedTransportGeneration == generation
            let dropReason: String?
            if self.transportState != .streaming {
                dropReason = "transport_state_\(self.transportState)"
            } else if !isCommittedGeneration {
                dropReason = "generation_not_committed"
            } else if self.displayRequestGate.isInputSuppressed {
                dropReason = "input_suppressed"
            } else {
                dropReason = nil
            }
            if let diagnostic, diagnostic.shouldLog {
                self.recordUsbTouchGuardDiagnostic(
                    diagnostic: diagnostic.context,
                    generation: generation,
                    payloadLength: packet.count,
                    result: dropReason == nil ? "pass" : "drop",
                    reason: dropReason ?? "none")
            }
            guard dropReason == nil else { return }
            let delivery = InputDeliveryPolicy.forEvent(type)
            if self.committedRealtimeMode == RealtimeTransportMode.wifiRTP,
               delivery == .unreliableLatest {
                self.wifiMediaReceiver.enqueueInput(
                    packet,
                    generation: generation)
                return
            }
            let completion: (NWError?) -> Void = { error in
                if let error {
                    print("[NetworkManager] Touch send error: \(error)")
                }
            }
            if delivery == .unreliableLatest {
                self.controlChannelWriter.enqueueMovement(
                    packet,
                    diagnostic: diagnostic?.shouldLog == true
                        ? diagnostic?.context : nil,
                    completion: completion)
            } else if !self.controlChannelWriter.enqueue(
                packet,
                diagnostic: diagnostic?.shouldLog == true
                    ? diagnostic?.context : nil,
                completion: completion) {
                self.handleStreamError(
                    "Control queue reached its 64-message bound.")
            }
        }
    }

    /// Convenience overload that maps **normalised float coordinates** (0.0–1.0)
    /// into the full UInt16 space (0–65535), making the packet resolution-independent.
    ///
    /// Use this from SwiftUI `DragGesture` or any view where you only have
    /// view-relative fractional coordinates rather than absolute pixel values.
    ///
    /// - Parameters:
    ///   - type:         Touch event kind.
    ///   - normX:        Horizontal position in [0.0, 1.0]. Clamped automatically.
    ///   - normY:        Vertical position in [0.0, 1.0]. Clamped automatically.
    ///   - pressure01:   Normalised pressure in [0.0, 1.0]. Clamped automatically.
    public func sendTouchEventNormalized(
        type:       TouchEventType,
        normX:      Float,
        normY:      Float,
        pressure01: Float = 1.0
    ) {
        // Map [0.0, 1.0] → [0, 65535] with clamping to prevent UInt16 overflow.
        let x        = UInt16(clamping: Int((normX.clamped(0, 1) * 65535).rounded()))
        let y        = UInt16(clamping: Int((normY.clamped(0, 1) * 65535).rounded()))
        let pressure = UInt8 (clamping: Int((pressure01.clamped(0, 1) * 255).rounded()))
        sendTouchEvent(type: type, x: x, y: y, pressure: pressure)
    }

    public func sendTextCommit(_ text: String) {
        guard mirrorControl.allowsLegacyVirtualInput else { return }
        let requestedGeneration = connectionGenerationClock.current
        let requestedInputToken = remoteInputContext?.token
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration, self.mirrorControl.allowsLegacyVirtualInput else { return }
            let generation = requestedGeneration
            guard self.transportState == .streaming,
                  self.committedTransportGeneration == generation,
                  TextCommitDeliveryPolicy.maySend(inputSuppressed: self.displayRequestGate.isInputSuppressed) else { return }
            for command in TextCommitCommand.chunks(text) {
                if self.remoteInputConnection, self.remoteFeatures.accepted & 1 != 0 {
                    guard let token = requestedInputToken,
                          self.remoteFeatures.maySend(feature: 1, token: token),
                          let payload = RemoteCommittedTextCommand(token: token, text: command.text).encode() else { return }
                    self.sendWireMessage(type: .remoteCommittedText, payload: payload, sequence: 0)
                } else {
                    guard let payload = command.encode() else { return }
                    self.sendWireMessage(type: .textCommit, payload: payload, sequence: 0, movement: false)
                }
            }
        }
    }

    /// Ctrl+Alt+Del, Lock or Restart on the PC (remote control sessions only). Restart must be confirmed by the user first.
    public func sendRemoteCommand(_ command: RemoteHostCommand, confirmed: Bool = false) {
        guard isRemoteControlSession else { return }
        let requestedGeneration = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration,
                  self.transportState == .streaming,
                  self.committedTransportGeneration == requestedGeneration else { return }
            self.sendWireMessage(type: .remoteCommand, payload: command.encode(confirmed: confirmed), sequence: 0)
        }
    }

    public func sendKeyboardInput(_ command: KeyboardInputCommand) {
        guard mirrorControl.allowsLegacyVirtualInput else { return }
        let requestedGeneration = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration, self.mirrorControl.allowsLegacyVirtualInput else { return }
            let generation = requestedGeneration
            guard self.transportState == .streaming,
                  self.committedTransportGeneration == generation,
                  command.virtualKey != 0,
                  KeyboardInputDeliveryPolicy.maySend(
                    action: command.action,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else { return }
            guard !self.remoteInputConnection || self.remoteFeatures.accepted & 1 == 0 else { return }
            self.sendWireMessage(
                type: .keyboardInput,
                payload: command.encode(),
                sequence: 0,
                movement: false)
        }
    }

    private func beginRemoteFeaturesOnQueue(generation: UInt64) {
        guard remoteInputConnection, remoteFeatures.begin(now: ProcessInfo.processInfo.systemUptime) else { return }
        remoteFeaturesPingNonce = sendClientPing(force: true, purpose: .telemetry, remoteFeaturesProbe: true)
        networkQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.remoteFeatures.expire(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func publishRemoteInputOnQueue(contextChanged: Bool = true) {
        let generation = connectionGeneration, context = remoteFeatures.context, features = remoteFeatures.accepted
        let ready = remoteFeatures.inputReady
        remoteMonitors.receiveContext(context, session: remoteMonitors.session)
        publishRemoteMonitorsOnQueue()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.remoteInputContext = context; self.remoteInputFeatures = features; self.remoteInputReady = ready
            if contextChanged { self.remoteInputRevision &+= 1 }
        }
    }
    private func resetRemoteInputOnQueue() {
        remoteFeatures = RemoteFeatureNegotiation(requestedFeatures: 7); remoteFeaturesPingNonce = nil
        remoteMonitors.begin(session: UUID(), acceptedFeatures: 0)
        remoteMonitorControl.update(generation: 0, context: nil, enabled: false)
        remoteMonitorAdmission = nil
        publishRemoteInputOnQueue()
    }

    private func publishRemoteMonitorsOnQueue() {
        let snapshot = remoteMonitors
        let publication = remoteMonitorPublicationClock.advance()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteMonitorPublicationClock.current == publication else { return }
            self.remoteMonitorState = snapshot
        }
    }
    private func requestRemoteCatalogueOnQueue() {
        guard remoteInputConnection, remoteFeatures.accepted & 7 == 7,
              wireAuthenticatedGeneration == connectionGeneration,
              let request = remoteMonitors.catalogueRequest(session: remoteMonitors.session) else { return }
        sendWireMessage(type: .remoteMonitorCatalogueRequest, payload: request.encode(), sequence: 0)
    }
    public func refreshRemoteScreens() {
        let generation = connectionGenerationClock.current, session = remoteMonitorState.session
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation, self.remoteMonitors.session == session else { return }
            self.requestRemoteCatalogueOnQueue()
        }
    }
    @MainActor func updateRemoteMonitorControl(configuration: RemoteSessionInputConfiguration?, enabled: Bool, available: Bool) {
        remoteMonitorControl.update(generation: configuration?.generation ?? 0, context: configuration?.context,
            enabled: enabled, available: available)
    }
    private func remoteMonitorControlEnabled(_ control: RemoteMonitorControlAuthority.Snapshot) -> Bool {
        guard control.generation == connectionGeneration else { return false }
        if remoteMonitors.isSourceRecovery { return control.available }
        return control.enabled && control.context == remoteFeatures.context
    }
    private func mayWriteRemoteMonitorSelection(_ request: RemoteMonitorSelectCommand) -> Bool {
        let control = remoteMonitorControl.snapshot
        guard let admission = remoteMonitorAdmission, admission.requestId == request.requestId,
              admission.inputRevision == remoteFeatures.revision, admission.controlRevision == control.revision,
              wireAuthenticatedGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              transportState == .streaming, !displayRequestGate.isInputSuppressed else { return false }
        let inputReady = remoteFeatures.context.map { remoteFeatures.maySend(feature: 3, token: $0.token) } ?? false
        return remoteMonitors.mayWriteSelection(request, session: remoteMonitors.session,
            inputReady: inputReady, controlEnabled: remoteMonitorControlEnabled(control))
    }
    public func requestRemoteMonitor(_ id: UInt64, catalogue: RemoteMonitorCatalogueCommand) {
        let generation = connectionGenerationClock.current, session = remoteMonitorState.session
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation, self.remoteMonitors.session == session,
                  self.remoteInputConnection, self.remoteFeatures.accepted & 7 == 7,
                  self.wireAuthenticatedGeneration == generation, self.committedTransportGeneration == generation,
                  self.transportState == .streaming, let connection = self.activeControlConnection else { return }
            let control = self.remoteMonitorControl.snapshot
            guard !self.displayRequestGate.isInputSuppressed,
                  let request = self.remoteMonitors.select(targetId: id, catalogue: catalogue, session: session,
                    inputReady: self.remoteFeatures.inputReady, controlEnabled: self.remoteMonitorControlEnabled(control)),
                  let payload = request.encode() else {
                self.publishRemoteMonitorsOnQueue()
                if self.remoteMonitors.needsCatalogueRefresh { self.requestRemoteCatalogueOnQueue() }
                return
            }
            self.remoteMonitorAdmission = (request.requestId, self.remoteFeatures.revision, control.revision)
            self.publishRemoteMonitorsOnQueue()
            // The service publishes paused/new contexts; the existing context/IDR rule owns input.
            self.sendWireMessage(type: .remoteMonitorSelectRequest, payload: payload, sequence: 0) { [weak self] error in
                guard let self, error != nil, self.connectionGeneration == generation,
                      self.activeControlConnection === connection, self.remoteMonitors.session == session else { return }
                self.remoteMonitors.selectionFailed(requestId: request.requestId, session: session)
                self.publishRemoteMonitorsOnQueue()
                self.requestRemoteCatalogueOnQueue()
            }
            self.networkQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.connectionGeneration == generation, self.activeControlConnection === connection,
                      self.remoteMonitors.session == session,
                      self.remoteMonitors.pending?.request.requestId == request.requestId else { return }
                self.remoteMonitors.selectionFailed(requestId: request.requestId, session: session)
                self.publishRemoteMonitorsOnQueue()
                self.requestRemoteCatalogueOnQueue()
            }
        }
    }

    private func remoteInputPacketIsCurrent(_ data: Data) -> Bool {
        guard data.count >= 16, let type = WireMessageType(rawValue: data[5]) else { return true }
        if !remoteInputConnection { return !(61...71).contains(type.rawValue) }
        let payload = Data(data.dropFirst(16))
        switch type {
        case .remoteMonitorCatalogueRequest:
            return remoteMonitors.enabled && remoteFeatures.accepted & 7 == 7 && RemoteMonitorCatalogueRequest.decode(payload) != nil
        case .remoteMonitorSelectRequest:
            guard remoteMonitors.enabled, remoteFeatures.accepted & 7 == 7,
                  let request = RemoteMonitorSelectCommand.decode(payload) else { return false }
            guard mayWriteRemoteMonitorSelection(request) else {
                // A context or shared-control retirement also retires a queued selection.
                remoteMonitors.selectionFailed(requestId: request.requestId, session: remoteMonitors.session)
                publishRemoteMonitorsOnQueue()
                return false
            }
            return true
        case .remoteScanKey:
            guard let key = RemoteScanKeyCommand.decode(payload) else { return false }
            return remoteFeatures.maySend(feature: 1, token: key.token)
        case .remotePointer:
            guard let pointer = RemotePointerCommand.decode(payload) else { return false }
            return remoteFeatures.maySend(feature: 2, token: pointer.token)
        case .remoteCommittedText:
            guard let text = RemoteCommittedTextCommand.decode(payload) else { return false }
            return remoteFeatures.maySend(feature: 1, token: text.token)
        case .keyboardInput, .textCommit: return remoteFeatures.accepted & 1 == 0
        case .pointerInput: return remoteFeatures.accepted & 2 == 0
        default: return true
        }
    }

    public func sendRemoteScanKey(_ command: RemoteScanKeyCommand, expectedGeneration: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.remoteInputConnection, self.connectionGeneration == expectedGeneration,
                  self.transportState == .streaming, self.committedTransportGeneration == expectedGeneration,
                  (command.action == 1 || !self.displayRequestGate.isInputSuppressed),
                  self.remoteFeatures.maySend(feature: 1, token: command.token), let payload = command.encode() else { return }
            self.sendWireMessage(type: .remoteScanKey, payload: payload, sequence: 0)
        }
    }
    public func sendRemotePointer(_ command: RemotePointerCommand, expectedGeneration: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.remoteInputConnection, self.connectionGeneration == expectedGeneration,
                  self.transportState == .streaming, self.committedTransportGeneration == expectedGeneration,
                  (command.kind == 2 && command.a == 1 || !self.displayRequestGate.isInputSuppressed),
                  self.remoteFeatures.maySend(feature: 2, token: command.token), let payload = command.encode() else { return }
            // Preserve relative deltas, wheels and move-before-button ordering.
            self.sendWireMessage(type: .remotePointer, payload: payload, sequence: 0)
        }
    }
    public func sendRemoteInputReset(_ command: RemoteInputResetCommand, expectedGeneration: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.remoteInputConnection, self.connectionGeneration == expectedGeneration,
                  self.wireAuthenticatedGeneration == expectedGeneration, self.remoteFeatures.accepted != 0,
                  self.remoteFeatures.context?.token == command.token, let payload = command.encode() else { return }
            self.remoteFeatures.invalidateInput(); self.publishRemoteInputOnQueue()
            self.sendWireMessage(type: .remoteInputReset, payload: payload, sequence: 0)
        }
    }

    private func resetDirectTouchSessionOnQueue() {
        activeDirectTouchCommand = nil
        let generation = connectionGenerationClock.current
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.cursorOwnershipState = nil
        }
    }

    private func cancelActiveDirectTouchOnQueue() {
        guard let command = activeDirectTouchCommand else { return }
        activeDirectTouchCommand = nil
        guard transportState == .streaming, committedTransportGeneration == connectionGeneration else { return }
        let cancel = DirectTouchContactCommand(phase: .cancel, pressure: command.pressure,
            contactID: command.contactID, x: command.x, y: command.y)
        sendWireMessage(type: .directTouchContact, payload: cancel.encode(), sequence: 0)
    }

    public func sendDirectTouchContact(_ command: DirectTouchContactCommand) {
        guard mirrorControl.allowsLegacyVirtualInput else { return }
        let requestedGeneration = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration, self.mirrorControl.allowsLegacyVirtualInput,
                  self.transportState == .streaming,
                  self.committedTransportGeneration == requestedGeneration,
                  command.contactID != 0,
                  DirectTouchDeliveryPolicy.maySend(phase: command.phase,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else { return }
            if command.phase == .down {
                guard self.activeDirectTouchCommand == nil else { return }
                self.activeDirectTouchCommand = command
            } else {
                guard self.activeDirectTouchCommand?.contactID == command.contactID else { return }
                self.activeDirectTouchCommand = command.phase == .up || command.phase == .cancel ? nil : command
            }
            self.sendWireMessage(type: .directTouchContact, payload: command.encode(), sequence: 0,
                movement: command.phase == .update)
        }
    }

    public func sendPointerInput(_ command: PointerInputCommand) {
        guard mirrorControl.allowsLegacyVirtualInput else { return }
        let requestedGeneration = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration, self.mirrorControl.allowsLegacyVirtualInput else { return }
            let generation = requestedGeneration
            guard self.transportState == .streaming,
                  self.committedTransportGeneration == generation,
                  PointerInputDeliveryPolicy.maySend(
                    action: command.action,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else {
                return
            }
            guard !self.remoteInputConnection || self.remoteFeatures.accepted & 2 == 0 else { return }
            self.sendWireMessage(
                type: .pointerInput,
                payload: command.encode(),
                sequence: 0,
                movement: command.action == .move)
        }
    }

    public func setClientDebugLoggingEnabled(_ enabled: Bool) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.clientDebugLoggingEnabled = enabled
            if enabled {
                guard self.transportState == .streaming else { return }
                self.startPersistentTelemetryLoggingIfEnabled()
            } else {
                self.transportTelemetry.stopLogging()
            }
        }
    }

    public func deleteClientDebugLogs(
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        transportTelemetry.deleteStoredLogs { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func startPersistentTelemetryLoggingIfEnabled(
        directoryURL: URL? = nil,
        completion: ((URL?) -> Void)? = nil
    ) {
        guard clientDebugLoggingEnabled else {
            completion?(nil)
            return
        }
        _ = transportTelemetry.startLogging(
            directoryURL: directoryURL,
            completion: completion)
    }

    // MARK: - Public API: Bitrate Control Sender

    /// Sends a legacy 8-byte frame-stage packet to the host.
    /// - Parameters:
    ///   - frameReceiveDurationMs: Header-and-payload receive duration, not RTT.
    ///   - decodeLatencyMs:  Last-frame VideoToolbox decode latency in milliseconds.
    public func sendLegacyFrameStagePacket(frameReceiveDurationMs: UInt16, decodeLatencyMs: UInt16) {
        networkQueue.async { [weak self] in
            guard let self, self.transportState == .streaming else { return }
            var pkt = Data(count: TelemetryWireProtocol.packetSize)
            pkt.withUnsafeMutableBytes { buf in
                buf.storeBytes(of: TelemetryWireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt16.self)
                buf.storeBytes(of: UInt16(0), toByteOffset: 2, as: UInt16.self)
                buf.storeBytes(of: frameReceiveDurationMs.littleEndian, toByteOffset: 4, as: UInt16.self)
                buf.storeBytes(of: decodeLatencyMs.littleEndian, toByteOffset: 6, as: UInt16.self)
            }
            self.enqueueControlData(pkt, telemetry: true)
        }
    }

    public func setDesiredStreamSettings(
        bitrateMbps: Double,
        audioEnabled: Bool,
        adaptiveBitrateEnabled: Bool
    ) {
        let desired = ClientStreamSettingsPreference.normalized(
            bitrateMbps: bitrateMbps,
            audioEnabled: audioEnabled,
            adaptiveBitrateEnabled: adaptiveBitrateEnabled)
        ClientStreamSettingsStore.save(desired)
        DispatchQueue.main.async {
            self.desiredBitrateMbps = desired.bitrateMbps
            self.desiredAudioEnabled = desired.audioEnabled
            self.desiredAdaptiveBitrateEnabled = desired.adaptiveBitrateEnabled
        }
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.clientSettingsState.setDesired(desired)
            print(
                "[IPAD][SETTINGS_DESIRED] bitrate_mbps=\(Int(desired.bitrateMbps)) " +
                "audio=\(desired.audioEnabled) adaptive=\(desired.adaptiveBitrateEnabled) source=user")
            _ = self.sendDesiredSettingsIfPossible(reason: "user_change")
        }
    }

    public func sendSettingsUpdate(bitrateMbps: Double, audioEnabled: Bool) {
        setDesiredStreamSettings(
            bitrateMbps: bitrateMbps,
            audioEnabled: audioEnabled,
            adaptiveBitrateEnabled: ClientStreamSettingsStore.load().adaptiveBitrateEnabled)
    }

    @discardableResult
    private func sendDesiredSettingsIfPossible(
        reason: String
    ) -> DesiredSettingsSendResult {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard transportState == .streaming,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration else {
            let result = DesiredSettingsSendResult.waitingForHost
            DispatchQueue.main.async {
                self.settingsApplyStatus = DesiredSettingsSendPolicy.status(for: result)
            }
            print("[IPAD][SETTINGS_SEND] result=waiting_for_host reason=\(reason)")
            return result
        }
        let desired = clientSettingsState.desired
        let requestID = nextSettingsRequestID
        nextSettingsRequestID &+= 1
        let generation = clientSettingsState.generation
        var payload = Data(count: 24)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt8(1), toByteOffset: 0, as: UInt8.self)
            bytes.storeBytes(
                of: desired.audioEnabled ? UInt8(1) : UInt8(0),
                toByteOffset: 1,
                as: UInt8.self)
            bytes.storeBytes(of: UInt8(0), toByteOffset: 2, as: UInt8.self)
            bytes.storeBytes(
                of: desired.adaptiveBitrateEnabled ? UInt8(1) : UInt8(0),
                toByteOffset: 3,
                as: UInt8.self)
            bytes.storeBytes(
                of: requestID.littleEndian,
                toByteOffset: 4,
                as: UInt32.self)
            bytes.storeBytes(
                of: generation.littleEndian,
                toByteOffset: 8,
                as: UInt64.self)
            bytes.storeBytes(
                of: UInt32(desired.bitrateMbps * 1_000_000).littleEndian,
                toByteOffset: 16,
                as: UInt32.self)
        }
        let result = DesiredSettingsSendResult.sent(requestID: requestID)
        DispatchQueue.main.async {
            self.settingsApplyStatus = DesiredSettingsSendPolicy.status(for: result)
        }
        print(
            "[IPAD][SETTINGS_UPDATE] request=\(requestID) " +
            "expected_generation=\(generation) " +
            "bitrate_bps=\(UInt32(desired.bitrateMbps * 1_000_000)) " +
            "audio=\(desired.audioEnabled) adaptive=\(desired.adaptiveBitrateEnabled) reason=\(reason)")
        sendWireMessage(
            type: .settingsUpdate,
            payload: payload,
            sequence: requestID)
        return result
    }

    private func requestCurrentUsbSettingsIfNeeded(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeTransportKind == .usb,
              generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation,
              settingsSyncPolicy.shouldRequestUsbSettings(
                committedGeneration: generation) else { return }
        let requestID = nextSettingsRequestID
        nextSettingsRequestID &+= 1
        print(
            "[IPAD][SETTINGS_SYNC_REQUEST] transport=usb " +
            "generation=\(generation) request=\(requestID)")
        sendWireMessage(
            type: .settingsGet,
            payload: Data(count: 24),
            sequence: requestID)
    }

    public func forgetTrustedHost() {
        networkQueue.async { [weak self] in
            guard let self,
                  self.transportState == .streaming,
                  let credential = self.trustedCredential,
                  credential.deviceID.count == 16 else { return }
            var payload = Data([1])
            payload.append(credential.deviceID)
            DispatchQueue.main.async { self.settingsApplyStatus = "Forgetting…" }
            self.sendWireMessage(type: .forgetDevice, payload: payload, sequence: 0)
        }
    }

    /// Gracefully tears down the connection and resets to .idle.
    public func stop() {
        // Serialize explicit Stop with accept, receive and state callbacks.
        if DispatchQueue.getSpecific(key: networkQueueKey) == nil {
            networkQueue.async { [weak self] in self?.stopOnQueue() }
            return
        }
        stopOnQueue()
    }

    private func stopOnQueue() {
        resetRemoteInputOnQueue()
        remoteInputConnection = false
        cancelUsbCandidateArbitration(reason: "explicit_stop")
        dispatchPrecondition(condition: .onQueue(networkQueue))
        cancelLegacyUsbPcmFreshFence()
        legacyUsbPlaybackEnabledGeneration = nil
        pendingClientPings.removeAll(keepingCapacity: true)
        let wasUSB = usbListenerExplicitlyStarted
        usbListenerExplicitlyStarted = false
        reconnectEnabled = false
        publishAutoReconnectAttempt(0)
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        wifiBackgroundDisconnectWorkItem?.cancel()
        wifiBackgroundDisconnectWorkItem = nil
        wifiLifecycleTransitionGeneration = nil
        wifiWaitingOwner = nil
        pendingUsbForegroundDecoderRearmGeneration = nil
        #if targetEnvironment(simulator)
        testingSimulatedWifiSession = false
        #endif
        RecentWifiResumeStore.clear()
        let stoppedGeneration = connectionGenerationClock.advance()
        resetAutoAcceptOnQueue()
        advanceReceivedRevisionOnQueue()
        resetDirectTouchSessionOnQueue()
        listenerGeneration &+= 1
        decoder.invalidate()
        AudioManager.shared.reset()
        connection?.cancel()
        connection = nil
        usbListener?.cancel()
        usbListener = nil
        usbScdpConnection?.cancel()
        usbScdpConnection = nil
        usbLaneServer.abort()
        usbLaneConnections.values.forEach { $0.cancel() }
        usbLaneConnections.removeAll()
        wireReceiveActiveGeneration = nil
        wireReceiveOutstanding = nil
        transferReceiveSuffix = nil
        wireAuthenticatedGeneration = nil
        committedTransportGeneration = nil
        committedRealtimeMode = nil
        committedTransportAudioAvailable = false
        committedRealtimeSessionID = nil
        // Mirror teardownCurrentSession: Stop must also retire the Wi-Fi media path.
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        wifiLegacyFallbackGeneration = nil
        wifiLegacyFallbackRequestGeneration = nil
        wifiMediaReceiver.cancel()
        advertisedClientCapabilities = nil
        settingsSyncPolicy.reset()
        resetDisplaySession()
        clearPendingTransportOffer()
        wireParser.reset(generation: stoppedGeneration)
        dataTransfers?.retire(); dataTransfers = nil; transferReceivePending = 0
        controlChannelWriter.abandonConnection()
        stopTelemetryTimer()
        if wasUSB {
            recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=cancelled reason=explicit_stop")
        }
        setState(.idle)
    }

    func applyDisplayPreference(
        _ preference: DisplayPreference,
        interfaceOrientation: ClientDisplayOrientation
    ) {
        networkQueue.async { [weak self] in
            self?.requestDisplayConfiguration(
                preference: preference,
                interfaceOrientation: interfaceOrientation)
        }
    }

    func applyDisplayPreference(_ preference: DisplayPreference) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard let orientation = self.observedInterfaceOrientation else { return }
            self.requestDisplayConfiguration(
                preference: preference,
                interfaceOrientation: orientation)
        }
    }

    func updateInterfaceOrientation(_ orientation: ClientDisplayOrientation) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.observedInterfaceOrientation = orientation
            guard self.activeDisplayCapabilities != nil,
                  self.activeDisplayPreference.orientationMode == .automatic else {
                return
            }
            self.orientationDebounceWorkItem?.cancel()
            let generation = self.connectionGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      generation == self.connectionGeneration,
                      self.observedInterfaceOrientation == orientation,
                      self.activeDisplayPreference.orientationMode == .automatic else {
                    return
                }
                self.requestDisplayConfiguration(
                    preference: self.activeDisplayPreference,
                    interfaceOrientation: orientation)
            }
            self.orientationDebounceWorkItem = workItem
            self.networkQueue.asyncAfter(
                deadline: .now() + .milliseconds(250),
                execute: workItem)
        }
    }

    /// Stops the USB listener/session before deleting the imported Keychain
    /// identity. The bundled identity is imported again on the next explicit
    /// listener start; the Windows host must also explicitly reset its pin.
    public func resetUSBPairing() {
        stop()
        USBServerIdentityStore.delete()
        DispatchQueue.main.async { self.usbServerFingerprint = nil }
    }

    /// Starts the fixed-port TCP endpoint used to carry SCDP through iproxy.
    public func startListening(port: UInt16 = 42042) {
        networkQueue.async { [weak self] in
            self?.startListeningOnQueue(port: port)
        }
    }

    private func startListeningOnQueue(port: UInt16) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        // Repeated Start must not create a gap in an already owned listener.
        guard !usbListenerExplicitlyStarted || usbListener == nil else { return }
        stop()
        usbListenerExplicitlyStarted = true
        DispatchQueue.main.async {
            self.isRemoteControlSession = false
            self.bytesReceived = 0
            self.lastFrameReceiveDurationMs = 0
            self.lastDecodeLatencyMs = 0
            self.hudTelemetry = TransportHudSnapshot(frameReceiveMs: 0, decodeMs: 0)
        }
        listenerGeneration &+= 1
        let generation = listenerGeneration

        do {
            let listener: NWListener
            if port == 0 {
                listener = try NWListener(using: .tcp)
            } else {
                guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                    throw USBListenerError.invalidPort
                }
                listener = try NWListener(
                    using: .tcp,
                    on: listenerPort)
            }
            usbListener = listener

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener,
                      self.usbListenerExplicitlyStarted,
                      self.usbListener === listener,
                      generation == self.listenerGeneration else { return }
                #if targetEnvironment(simulator)
                self.usbListenerStateObservedForTesting?(listener, state)
                #endif
                switch state {
                case .ready:
                    let activePort = listener.port?.rawValue ?? port
                    print("[IPAD][USB_SCDP_LISTENING] port=\(activePort)")
                    self.recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=ready port=\(activePort)")
                    if self.usbScdpConnection == nil { self.setState(.listening) }
                case .failed(let error):
                    self.stop()
                    self.recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=failed port=\(port) reason=\(error)")
                    self.setState(.disconnected(
                        reason: "USB listener failed: \(error.localizedDescription)"))
                case .cancelled:
                    self.stop()
                    self.recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=cancelled port=\(port) reason=listener_cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self, weak listener] newConnection in
                guard let self, let listener,
                      self.usbListenerExplicitlyStarted,
                      self.usbListener === listener,
                      generation == self.listenerGeneration else {
                    newConnection.cancel()
                    return
                }
                if self.pendingUsbCandidate != nil {
                    self.recordUsbLifecycleDiagnostic("[USB_CANDIDATE_ARBITRATION] action=reject_extra_pending candidate=\(ObjectIdentifier(newConnection))")
                    newConnection.cancel()
                    return
                }
                let currentConnectionId = self.usbScdpConnection.map {
                    String(describing: ObjectIdentifier($0))
                } ?? "none"
                let currentState = self.usbScdpConnection.map {
                    String(describing: $0.state)
                } ?? "none"
                self.recordUsbLifecycleDiagnostic(
                    "[USB_CANDIDATE_EVALUATION] " +
                    "candidateConnectionId=\(ObjectIdentifier(newConnection)) " +
                    "currentConnectionId=\(currentConnectionId) " +
                    "currentState=\(currentState) " +
                    "transportState=\(self.transportState) " +
                    "listenerGeneration=\(generation) " +
                    "connectionGeneration=\(self.connectionGeneration) " +
                    "wireAuthenticatedGeneration=\(self.wireAuthenticatedGeneration.map { String($0) } ?? "none") " +
                    "committedGeneration=\(self.committedTransportGeneration.map { String($0) } ?? "none")")
                if self.usbScdpConnection != nil, let current = self.usbScdpConnection {
                    let isCommitted = (self.committedTransportGeneration == self.connectionGeneration)
                    let isHealthy = isCommitted && (current.state == .ready || current.state == .setup)
                    let isConnecting = (self.transportState == .connecting && self.committedTransportGeneration == nil && (current.state == .setup || current.state == .preparing || current.state == .ready))
                    if isHealthy || isConnecting {
                        self.holdUsbCandidate(newConnection, incumbent: current)
                        return
                    }
                    self.teardownUsbSession(
                        connection: current,
                        generation: self.connectionGeneration,
                        reason: "replacement_candidate_accepted")
                }
                self.installUsbCandidate(newConnection)
            }
            listener.start(queue: networkQueue)
        } catch {
            usbListenerExplicitlyStarted = false
            usbListener = nil
            setState(.disconnected(
                reason: "Unable to start USB listener: \(error.localizedDescription)"))
        }
    }

    private func installUsbCandidate(_ candidate: NWConnection) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        _ = connectionGenerationClock.advance()
        resetAutoAcceptOnQueue()
        advanceReceivedRevisionOnQueue()
        resetDirectTouchSessionOnQueue()
        clientSettingsState.resetHostGeneration()
        settingsReconciliationGate.reset()
        usbScdpConnection = candidate
        connection = candidate
        recordUsbLifecycleDiagnostic("[USB_RECOVERY_CANDIDATE] attempt=\(connectionGeneration) generation=\(connectionGeneration) state=start")
        recordUsbLifecycleDiagnostic("[USB_SESSION_ACCEPT] generation=\(connectionGeneration) connectionId=\(ObjectIdentifier(candidate))")
        setupStateHandler(for: candidate)
        setState(.connecting)
        #if targetEnvironment(simulator)
        usbCandidateInstalledForTesting?(candidate)
        #endif
        candidate.start(queue: networkQueue)
    }

    private func ownsUsbCandidate(_ pending: PendingUsbCandidate) -> Bool {
        usbListenerExplicitlyStarted && usbListener != nil &&
        listenerGeneration == pending.listenerGeneration &&
        connectionGeneration == pending.incumbentGeneration &&
        usbScdpConnection === pending.incumbent && connection === pending.incumbent &&
        ObjectIdentifier(pending.candidate) == pending.candidateID
    }

    private func holdUsbCandidate(_ candidate: NWConnection, incumbent: NWConnection) {
        let id = nextUsbCandidateID
        nextUsbCandidateID &+= 1
        pendingUsbCandidate = PendingUsbCandidate(id: id, candidate: candidate,
            candidateID: ObjectIdentifier(candidate), listenerGeneration: listenerGeneration,
            incumbent: incumbent, incumbentGeneration: connectionGeneration,
            deadline: ProcessInfo.processInfo.systemUptime + Self.usbCandidateArbitrationTimeout)
        let work = DispatchWorkItem { [weak self] in self?.expireUsbCandidate(id: id) }
        usbCandidateDeadlineWork = work
        recordUsbLifecycleDiagnostic("[USB_CANDIDATE_ARBITRATION] arbitration=\(id) action=hold generation=\(connectionGeneration) committed=\(committedTransportGeneration == connectionGeneration) candidate=\(ObjectIdentifier(candidate))")
        #if targetEnvironment(simulator)
        if !manualUsbCandidateDeadlineForTesting {
            networkQueue.asyncAfter(deadline: .now() + Self.usbCandidateArbitrationTimeout, execute: work)
        }
        #else
        networkQueue.asyncAfter(deadline: .now() + Self.usbCandidateArbitrationTimeout, execute: work)
        #endif
        challengeUsbCandidateIfCommitted()
    }

    private func challengeUsbCandidateIfCommitted() {
        guard var pending = pendingUsbCandidate, ownsUsbCandidate(pending),
              pending.livenessNonce == nil,
              committedTransportGeneration == pending.incumbentGeneration,
              wireAuthenticatedGeneration == pending.incumbentGeneration else { return }
        pending.livenessNonce = sendClientPing(force: true, purpose: .usbCandidateLiveness)
        pendingUsbCandidate = pending
        recordUsbLifecycleDiagnostic("[USB_CANDIDATE_ARBITRATION] arbitration=\(pending.id) action=challenge nonce=\(pending.livenessNonce.map { String($0) } ?? "none")")
    }

    @discardableResult
    private func takeUsbCandidate() -> PendingUsbCandidate? {
        let pending = pendingUsbCandidate
        pendingUsbCandidate = nil
        usbCandidateDeadlineWork?.cancel()
        usbCandidateDeadlineWork = nil
        if let nonce = pending?.livenessNonce { pendingClientPings.removeValue(forKey: nonce) }
        return pending
    }

    private func cancelUsbCandidateArbitration(reason: String) {
        guard let pending = takeUsbCandidate() else { return }
        pending.candidate.cancel()
        recordUsbLifecycleDiagnostic("[USB_CANDIDATE_ARBITRATION] arbitration=\(pending.id) action=reject_candidate reason=\(reason)")
    }

    private func expireUsbCandidate(id: UInt64) {
        guard let pending = pendingUsbCandidate, pending.id == id, ownsUsbCandidate(pending) else { return }
        teardownUsbSession(connection: pending.incumbent, generation: pending.incumbentGeneration,
                           reason: "candidate_arbitration_deadline")
    }

    private func nextUsbTouchDiagnostic(
        type: TouchEventType
    ) -> (context: ControlChannelWriter.DiagnosticContext, shouldLog: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        usbTouchDiagnosticSequence &+= 1
        let context = ControlChannelWriter.DiagnosticContext(
            sequence: usbTouchDiagnosticSequence,
            event: String(describing: type).capitalized)
        guard type == .move else { return (context, true) }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUsbTouchMoveDiagnosticAt >=
                Self.usbTouchMoveDiagnosticInterval else {
            return (context, false)
        }
        lastUsbTouchMoveDiagnosticAt = now
        return (context, true)
    }

    private func recordUsbTouchGuardDiagnostic(
        diagnostic: ControlChannelWriter.DiagnosticContext,
        generation: UInt64,
        payloadLength: Int,
        result: String,
        reason: String
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let identity = activeControlConnection.map {
            String(describing: ObjectIdentifier($0))
        } ?? "none"
        recordDiagnosticLine(
            "[USB_TOUCH_SEND_GUARD] event=\(diagnostic.event) " +
            "diagnosticSequence=\(diagnostic.sequence) activeTransportKind=usb " +
            "usbConnectionPresent=\(usbScdpConnection != nil) " +
            "connectionIdentity=\(identity) clientGeneration=\(generation) " +
            "committedGeneration=\(committedTransportGeneration.map { String($0) } ?? "none") " +
            "inputSuppressed=\(displayRequestGate.isInputSuppressed) " +
            "payloadLength=\(payloadLength) result=\(result) reason=\(reason)")
    }

    private func recordUsbTouchSendDiagnostic(
        _ marker: String,
        diagnostic: ControlChannelWriter.DiagnosticContext,
        payloadLength: Int,
        error: String?
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let identity = activeControlConnection.map {
            String(describing: ObjectIdentifier($0))
        } ?? "none"
        recordDiagnosticLine(
            "\(marker) event=\(diagnostic.event) " +
            "diagnosticSequence=\(diagnostic.sequence) activeTransportKind=usb " +
            "usbConnectionPresent=\(usbScdpConnection != nil) " +
            "connectionIdentity=\(identity) clientGeneration=\(connectionGeneration) " +
            "committedGeneration=\(committedTransportGeneration.map { String($0) } ?? "none") " +
            "inputSuppressed=\(displayRequestGate.isInputSuppressed) " +
            "payloadLength=\(payloadLength) error=\(error ?? "none")")
    }

    // MARK: - Private: TLS Configuration

    /// Builds the Wi-Fi client TLS parameters.
    ///
    /// Wi-Fi uses the Windows host's self-signed, session-scoped certificate.
    /// USB identity is authenticated separately by the Windows DPAPI-backed
    /// selected-device pin and must never share this callback.
    private func buildTLSParameters(for endpoint: NWEndpoint) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, securityTrust, completionHandler in
                guard let self else {
                    completionHandler(false)
                    return
                }
                let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
                guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
                    completionHandler(false)
                    return
                }

                let certificateData = SecCertificateCopyData(certificate) as Data
                let fingerprint = SHA256.hash(data: certificateData)
                    .map { String(format: "%02X", $0) }
                    .joined(separator: ":")
                let decision = WifiHostIdentityPolicy.decide(
                    presentedFingerprint: fingerprint,
                    pinnedFingerprint: self.trustedHostFingerprintStore.load())
                guard let identityCode = WifiHostIdentityPolicy.identityCode(
                    for: fingerprint) else {
                    completionHandler(false)
                    return
                }
                self.verifiedHostFingerprint = fingerprint
                self.verifiedHostIdentityCode = identityCode
                DispatchQueue.main.async {
                    self.hostFingerprint = fingerprint
                    self.hostIdentityCode = identityCode
                }
                switch decision {
                case .trusted:
                    self.hostIdentityConfirmationRequired = false
                    self.hostIdentityConfirmed = true
                    print("[IPAD][TLS_VERIFY] identity=known code=\(identityCode) accepted=true")
                    completionHandler(true)
                case .requiresFirstPairingConfirmation:
                    self.hostIdentityConfirmationRequired = true
                    self.hostIdentityConfirmed = false
                    print("[IPAD][TLS_VERIFY] identity=unknown code=\(identityCode) awaiting_confirmation")
                    completionHandler(true)
                case .rejected:
                    self.hostIdentityConfirmationRequired = false
                    self.hostIdentityConfirmed = false
                    print("[IPAD][TLS_VERIFY] identity=mismatch code=\(identityCode) accepted=false")
                    completionHandler(false)
                }
            },
            networkQueue
        )

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func buildUSBListenerParameters() throws -> NWParameters {
        guard let identity = USBServerIdentityStore.loadOrCreate(),
              let protocolIdentity = sec_identity_create(identity) else {
            throw USBListenerError.identityUnavailable
        }

        let fingerprint = Self.fingerprint(of: identity)
        DispatchQueue.main.async {
            self.usbServerFingerprint = fingerprint
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12)
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            protocolIdentity)

        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func fingerprint(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    // MARK: - Private: Connection Lifecycle

    private var isDisconnectedOnQueue: Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if case .disconnected = transportState { return true }
        return false
    }

    private var isAuthFailedOnQueue: Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if case .authFailed = transportState { return true }
        return false
    }

    private func setupStateHandler(for connection: NWConnection) {
        let generation = connectionGeneration
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            let ownsCurrentGeneration =
                generation == self.connectionGeneration &&
                self.connection === connection &&
                (self.usbListener == nil ||
                    self.usbScdpConnection === connection)
            if !ownsCurrentGeneration {
                if case .failed = state {
                    self.recordUsbLifecycleDiagnostic(
                        "[USB_TERMINAL_CALLBACK] action=ignored_stale " +
                        "state=failed callbackGeneration=\(generation) " +
                        "currentGeneration=\(self.connectionGeneration) " +
                        "callbackConnectionId=\(ObjectIdentifier(connection)) " +
                        "activeConnectionId=\(self.connection.map { String(describing: ObjectIdentifier($0)) } ?? "none")")
                } else if case .cancelled = state {
                    self.recordUsbLifecycleDiagnostic(
                        "[USB_TERMINAL_CALLBACK] action=ignored_stale " +
                        "state=cancelled callbackGeneration=\(generation) " +
                        "currentGeneration=\(self.connectionGeneration) " +
                        "callbackConnectionId=\(ObjectIdentifier(connection)) " +
                        "activeConnectionId=\(self.connection.map { String(describing: ObjectIdentifier($0)) } ?? "none")")
                }
            }
            guard generation == self.connectionGeneration,
                  self.connection === connection else { return }
            if self.usbListener != nil,
               self.usbScdpConnection !== connection { return }
            switch state {
            case .setup:
                print("[IPAD][NW_STATE] setup")
            case .preparing:
                print("[IPAD][NW_STATE] preparing")
            case .waiting(let error):
                print("[IPAD][NW_STATE] waiting error=\(error)")
                if self.shouldPreserveTransientWifiControlError(
                    error, generation: generation, connection: connection) {
                    if case .ready = connection.state {
                        self.recordWifiLifecycleDiagnostic(
                            "generation=\(generation) event=waiting " +
                            "action=ignore_stale_ready_callback")
                        return
                    }
                    self.wifiWaitingOwner = WifiWaitingOwner(
                        generation: generation,
                        connectionID: ObjectIdentifier(connection))
                    self.recordWifiLifecycleDiagnostic(
                        "generation=\(generation) event=waiting " +
                        "action=preserve_same_session " +
                        "grace_active=\(self.wifiBackgroundDisconnectWorkItem != nil)")
                    return
                }
                self.handleStreamError(
                    "Waiting for Windows host: \(error.localizedDescription)")
            case .ready:
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] ready TLS_VERIFY_COMPLETE accepted")
                if self.isCurrentCommittedWifiRtpStreamingSessionOnQueue(
                    generation: generation) {
                    let wasWaiting = self.wifiWaitingOwner?.owns(
                        connection, generation: generation) == true
                    if wasWaiting {
                        self.wifiWaitingOwner = nil
                    }
                    if self.isForegroundActive,
                       (wasWaiting || self.wifiBackgroundDisconnectWorkItem != nil) {
                        _ = self.resumeCommittedWifiSessionOnQueue(
                            connection: connection, generation: generation)
                    }
                    return
                }
                let telemetryKind: StreamingTransportKind =
                    self.activeTransportKind == .usb ? .usbTypeC : .wifi
                self.transportTelemetry.setSessionContext(TransportTelemetryContext(
                    transportKind: telemetryKind,
                    transportBackend: self.activeTransportKind == .usb
                        ? "localhost_scdp"
                        : "network_framework",
                    connectionGeneration: generation))
                #if targetEnvironment(simulator)
                self.testingWriterBegins += 1
                #endif
                self.controlChannelWriter.begin(generation: generation)
                if self.activeTransportKind == .wifi {
                    self.startWireReceiveLoop(generation: generation)
                    if self.hostIdentityConfirmationRequired {
                        print("[IPAD][PAIRING_GATED] reason=host_identity_confirmation")
                        self.setState(.awaitingHostIdentity)
                    } else {
                        self.sendTrustedClientHello(generation: generation)
                    }
                } else {
                    self.startWireReceiveLoop(generation: generation)
                    self.recordUsbLifecycleDiagnostic(
                        "[USB_SCDP_PROVISIONAL] generation=\(generation)")
                }

            case .failed(let error):
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] failed error=\(error)")
                if self.usbListenerExplicitlyStarted {
                    self.teardownUsbSession(
                        connection: connection, generation: generation,
                        reason: "failed: \(error)")
                    return
                }
                self.teardownCurrentSession()
                if self.usbListener != nil {
                    self.setState(.listening)
                } else {
                    self.setState(.disconnected(reason: error.localizedDescription))
                    self.scheduleAutoReconnect(reset: false)
                }

            case .cancelled:
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] cancelled")
                if self.usbListenerExplicitlyStarted {
                    self.teardownUsbSession(
                        connection: connection, generation: generation,
                        reason: "cancelled")
                    return
                }
                let wasIdle = self.transportState == .idle
                self.teardownCurrentSession()
                if self.usbListener != nil {
                    self.setState(.listening)
                } else if !wasIdle {
                    self.setState(.disconnected(reason: "Connection cancelled."))
                    self.scheduleAutoReconnect(reset: false)
                }

            default:
                break
            }
        }
    }

    // MARK: - Private: Auth Handshake

    private func sendTrustedClientHello(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        #if targetEnvironment(simulator)
        testingClientHelloCount += 1
        #endif
        guard generation == connectionGeneration,
              let fingerprint = verifiedHostFingerprint else {
            handleStreamError("TLS host identity was unavailable after verification.")
            return
        }
        let stored = trustedCredentialStore.load(fingerprint: fingerprint)
        trustedCredential = stored
        let deviceID = stored?.deviceID ?? trustedDeviceID
        let sessionID = stored?.sessionID ?? Data(repeating: 0, count: 16)
        let name = Data(UIDevice.current.name.utf8.prefix(64))
        guard deviceID.count == 16, sessionID.count == 16, !name.isEmpty else {
            handleStreamError("Trusted device identity is malformed.")
            return
        }
        var payload = Data([1])
        payload.append(deviceID)
        payload.append(sessionID)
        payload.append(UInt8(name.count))
        payload.append(name)
        print(stored == nil
            ? "[IPAD][PAIRING_REQUIRED] credential=absent"
            : "[IPAD][TRUSTED_CREDENTIAL_FOUND] credential=present")
        sendWireMessage(type: .clientHello, payload: payload, sequence: 0)
    }

    private func markRecentWifiResumeIntentIfEligible() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard reconnectEnabled,
              !usbListenerExplicitlyStarted,
              connection != nil,
              transportState == .streaming else {
            RecentWifiResumeStore.clear()
            return
        }
        RecentWifiResumeStore.mark()
    }

    private func loadWifiReconnectEndpoint() -> NWEndpoint? {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let legacyHost = UserDefaults.standard.string(forKey: Self.lastKnownHostKey)
        let target = WifiReconnectTargetSelection.preferred(
            structured: WifiReconnectTargetStore.load(),
            legacyHost: legacyHost)
        guard let target, let endpoint = target.endpoint else { return nil }
        if WifiReconnectTargetStore.load() == nil,
           target.kind == .hostPort {
            WifiReconnectTargetStore.save(target)
        }
        return endpoint
    }

    private func scheduleAutoReconnect(reset: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard isForegroundActive,
              reconnectEnabled,
              let endpoint = loadWifiReconnectEndpoint() else {
            publishAutoReconnectAttempt(0) // Nothing is scheduled, so the screen must not say "Reconnecting".
            return
        }
        if reset { reconnectAttempt = 0 }
        reconnectWorkItem?.cancel()
        let delay = TrustedReconnectPolicy.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        publishAutoReconnectAttempt(reconnectAttempt)
        print("[IPAD][AUTO_RECONNECT_ATTEMPT] attempt=\(reconnectAttempt) delay=\(delay)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isForegroundActive, self.reconnectEnabled else { return }
            guard self.connection == nil else { return }
            print("[IPAD][AUTO_RECONNECT_BEGIN] endpoint=persisted_target")
            self.connectOnQueue(to: endpoint)
        }
        reconnectWorkItem = work
        networkQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func answerTrustedChallenge(_ payload: Data, generation: UInt64) {
        guard payload.count == 112,
              let fingerprint = verifiedHostFingerprint,
              let credential = trustedCredential,
              credential.fingerprint == fingerprint,
              credential.deviceID == payload.subdata(in: 16..<32),
              credential.hostID == payload.subdata(in: 32..<48),
              credential.secret.count == 32 else {
            setState(.authFailed(reason: "Trusted Host credential is missing or does not match."))
            return
        }
        var context = Data()
        context.append(payload.subdata(in: 48..<80))
        context.append(payload.subdata(in: 80..<112))
        context.append(payload.subdata(in: 0..<16))
        context.append(payload.subdata(in: 16..<32))
        context.append(payload.subdata(in: 32..<48))
        context.append(WireProtocol.version)
        let key = SymmetricKey(data: credential.secret)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: context, using: key))
        var response = payload.subdata(in: 0..<16)
        response.append(proof)
        print("[IPAD][TRUSTED_AUTH_BEGIN] generation=\(generation)")
        sendWireMessage(type: .trustedDeviceProof, payload: response, sequence: 0)
    }

    private func storePairingCredential(_ payload: Data) {
        guard payload.count == 80,
              let fingerprint = verifiedHostFingerprint else { return }
        let credential = TrustedHostCredential(
            fingerprint: fingerprint,
            hostID: payload.subdata(in: 0..<16),
            deviceID: payload.subdata(in: 16..<32),
            secret: payload.subdata(in: 48..<80),
            sessionID: payload.subdata(in: 32..<48))
        guard trustedCredentialStore.save(credential) else {
            handleStreamError("Unable to save the trusted Host credential in Keychain.")
            return
        }
        trustedCredential = credential
        guard trustedHostFingerprintStore.save(fingerprint) else {
            trustedCredentialStore.delete(fingerprint: fingerprint)
            handleStreamError("Unable to save the trusted Host identity in Keychain.")
            return
        }
        print("[IPAD][PAIRING_SUCCESS] credential=keychain")
    }

    private func updateResumedSession(_ payload: Data) {
        guard payload.count == 17, var credential = trustedCredential else { return }
        credential.sessionID = payload.subdata(in: 1..<17)
        if trustedCredentialStore.save(credential) {
            trustedCredential = credential
            print(payload[0] == 1
                ? "[IPAD][SESSION_RESUMED] result=resumed"
                : "[IPAD][SESSION_NOT_FOUND] result=new_session")
        }
    }

    func receiveSettingsState(
        _ payload: Data,
        outcome: ClientSettingsApplyOutcome
    ) {
        guard let state = TrustedSettingsState.decode(payload),
              state.generation >= clientSettingsState.generation else { return }
        let previousAudioEnabled = clientSettingsState.effective.audioEnabled
        let bitrateMbps = Double(state.bitrateBps) / 1_000_000
        let effective = ClientStreamSettingsPreference.normalized(
            bitrateMbps: bitrateMbps,
            audioEnabled: state.audioEnabled,
            adaptiveBitrateEnabled: state.adaptiveBitrateEnabled)
        clientSettingsState.receiveHostState(
            effective,
            generation: state.generation)
        if previousAudioEnabled != state.audioEnabled,
           let committedGeneration = committedTransportGeneration,
           let committedMode = committedRealtimeMode {
            reconcileRealtimeAudioPlayback(
                generation: committedGeneration,
                mode: committedMode,
                audioEnabled: state.audioEnabled)
        }
        let resolvedOutcome: ClientSettingsApplyOutcome
        if case .rejected = outcome {
            resolvedOutcome = .rejected(state.rejectionReason)
        } else {
            resolvedOutcome = outcome
        }
        let decision = settingsReconciliationGate.decision(
            hostGeneration: state.generation,
            desired: clientSettingsState.desired,
            effective: effective,
            outcome: resolvedOutcome)
        if case .rejected(.runtimeApplyFailed) = resolvedOutcome {
            let desired = clientSettingsState.desired
            print(
                "[IPAD][SETTINGS_RUNTIME_RECOVERY_ARMED] " +
                "generation=\(state.generation) " +
                "desired_bitrate=\(UInt32(desired.bitrateMbps * 1_000_000)) " +
                "desired_audio=\(desired.audioEnabled)")
        }
        let isInSync = clientSettingsState.desired == effective
        let rejected: Bool
        if case .rejected = resolvedOutcome { rejected = true } else { rejected = false }
        let status: String
        if isInSync {
            status = "Applied"
        } else if rejected && decision == .suppressHardRejection {
            status = "Rejected by Host"
        } else {
            status = "Waiting for Host"
        }
        DispatchQueue.main.async {
            self.settingsGeneration = state.generation
            // Settings carries the saved manual fallback. Existing .bitrate
            // packets remain authoritative for the live target while Auto runs.
            if !state.adaptiveBitrateEnabled || !self.isAdaptiveBitrate {
                self.effectiveBitrateMbps = bitrateMbps
            }
            self.effectiveAudioEnabled = state.audioEnabled
            self.isAdaptiveBitrate = state.adaptiveBitrateEnabled
            self.transportTelemetry.recordBitrateMbps(self.effectiveBitrateMbps)
            self.settingsApplyStatus = status
        }
        print("[IPAD][SETTINGS_RESULT] generation=\(state.generation) bitrate_bps=\(state.bitrateBps) audio=\(state.audioEnabled) adaptive=\(state.adaptiveBitrateEnabled) rejected=\(rejected) reason=\(state.rejectionReason)")
        if decision == .send {
            let isRuntimeRecovery = resolvedOutcome == .state &&
                settingsReconciliationGate.runtimeReadyRetryGeneration ==
                    state.generation
            let reason: String
            if isRuntimeRecovery {
                reason = "runtime_ready_recovery"
            } else if state.rejectionReason == .staleGeneration {
                reason = "stale_generation_retry"
            } else {
                reason = "host_mismatch"
            }
            if isRuntimeRecovery {
                print(
                    "[IPAD][SETTINGS_RUNTIME_RECOVERY] " +
                    "generation=\(state.generation) action=retry")
            }
            _ = sendDesiredSettingsIfPossible(reason: reason)
        } else if rejected && !isInSync {
            print(
                "[IPAD][SETTINGS_RECONCILE_SUPPRESS] reason=\(state.rejectionReason) " +
                "generation=\(state.generation) decision=\(decision)")
        } else if resolvedOutcome == .state &&
                    settingsReconciliationGate.runtimeReadyRetryGeneration != nil &&
                    !isInSync {
            print(
                "[IPAD][SETTINGS_RUNTIME_RECOVERY] " +
                "generation=\(state.generation) " +
                "action=suppress_already_retried")
        }
    }

    /// Reads exactly the minimum response bytes for AUTH_SUCCESS or AUTH_FAILED.
    private func receiveAuthResponse(generation: UInt64) {
        startWireReceiveLoop(generation: generation)
    }

    // MARK: - Private: Video Stream Receive Loop (2-Phase Framed Protocol)

    // Decoder instance — lazy-created on first streaming connection.
    // Exposed so ContentView can wire onFrameDecoded → MetalVideoView.
    public private(set) lazy var decoder = DecoderManager()

    /// Kicks off the framed 120Hz receive loop immediately after AUTH_SUCCESS.
    private func startVideoReceiveLoop(generation: UInt64) {
        startTelemetryTimer()
    }

    private func retireUsbAudioLane(_ connection: NWConnection, generation: UInt64, reason: String) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              committedTransportGeneration == generation,
              committedRealtimeMode == RealtimeTransportMode.usbSplitTLS,
              usbLaneConnections[.audio] === connection else { return }
        usbLaneConnections.removeValue(forKey: .audio)
        connection.cancel()
        committedTransportAudioAvailable = false
        reconcileRealtimeAudioPlayback(generation: generation,
            mode: RealtimeTransportMode.usbSplitTLS,
            audioEnabled: clientSettingsState.effective.audioEnabled)
        recordDiagnosticLine("[USB_AUDIO_RUNTIME] generation=\(generation) available=0 reason=\(reason)")
    }

    private func adoptUsbLane(_ token: UsbLaneBindToken, connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard usbLaneServer.owns(token, connection: connection),
              token.connectionGeneration == connectionGeneration,
              pendingTransportOffer?.sessionID == token.sessionID,
              pendingTransportOffer?.mode == RealtimeTransportMode.usbSplitTLS else {
            connection.cancel()
            return
        }
        let lane = token.lane
        usbLaneConnections[lane]?.cancel()
        usbLaneConnections[lane] = connection
        startUsbLaneReceiveLoop(connection, lane: lane, generation: token.connectionGeneration)
    }

    private func startUsbLaneReceiveLoop(
        _ connection: NWConnection,
        lane: UsbLaneKind, generation: UInt64)
    {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let parser = WireStreamParser(generation: generation)
        var terminated = false

        func receiveNext() {
            guard !terminated else { return }
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: parser.suggestedReceiveLength)
            { [weak self] data, _, isComplete, error in
                guard !terminated, let self,
                      generation == self.connectionGeneration,
                      self.usbLaneConnections[lane] === connection else { return }
                func terminate(_ reason: String) {
                    guard !terminated else { return }
                    terminated = true
                    if lane == .audio,
                       self.committedTransportGeneration == generation,
                       self.committedRealtimeMode == RealtimeTransportMode.usbSplitTLS {
                        self.retireUsbAudioLane(connection, generation: generation, reason: reason)
                    } else {
                        connection.cancel()
                        self.handleStreamError("USB media lane terminal: \(reason)")
                    }
                }
                if error != nil { terminate("receive_error"); return }
                if let data, !data.isEmpty {
                    parser.consume(
                        data, generation: generation,
                        receivedAt: CACurrentMediaTime())
                    { event in
                        guard !terminated,
                              generation == self.connectionGeneration,
                              self.usbLaneConnections[lane] === connection else { return }
                        switch event {
                        case .failure:
                            terminate("wire_parser_failure")
                        case .discardedFixedControl:
                            // Only video/audio messages are legal on bound data lanes.
                            terminate("discarded_fixed_control_on_data_lane")
                        case .message(let message):
                            let expected: WireMessageType = lane == .video ? .video : .audio
                            guard message.header.type == expected else {
                                terminate("unexpected_type"); return
                            }
                            self.handleWireMessage(message, generation: generation)
                        }
                    }
                }
                guard !terminated,
                      generation == self.connectionGeneration,
                      self.usbLaneConnections[lane] === connection else { return }
                if isComplete { terminate("eof"); return }
                receiveNext()
            }
        }
        receiveNext()
    }

    // MARK: Telemetry Timer (2 Hz)

    private func startTelemetryTimer() {
        stopTelemetryTimer()
        pendingClientPings = pendingClientPings.filter { $0.value.purpose != .telemetry }
        lastClientPingSentAt = 0
        videoPayloadCounter.begin(generation: connectionGeneration)
        videoRxSampler.reset()
        lastHudSnapshotPublishedAt = 0
        transportTelemetry.beginRuntimeSession()
        if committedPipelineMode.active != nil {
            transportTelemetry.beginFreshFrameRate(generation: connectionGeneration)
        }
        let generation = connectionGeneration
        let performanceTimer = DispatchSource.makeTimerSource(queue: networkQueue)
        performanceTimer.schedule(deadline: .now() + 1, repeating: 1)
        performanceTimer.setEventHandler { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.sendPerformanceFeedback()
        }
        performanceTimer.resume()
        performanceFeedbackTimer = performanceTimer
        startPersistentTelemetryLoggingIfEnabled()
        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
            return
        }
        startLegacyTelemetryTimers()
    }

    private func startLegacyTelemetryTimers() {
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)   // 2× per second
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
            self.sendVideoFeedback()
        }
        timer.resume()
        telemetryTimer = timer

        // Keep the legacy half-second cadence, and add the latency controller's
        // 200 ms feedback cadence without changing the v1 payload schema.
        let adaptiveTimer = DispatchSource.makeTimerSource(queue: networkQueue)
        adaptiveTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        adaptiveTimer.setEventHandler { [weak self] in
            guard let self,
                  self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
            self.sendVideoFeedback()
        }
        adaptiveTimer.resume()
        adaptiveTelemetryTimer = adaptiveTimer
    }

    private func stopTelemetryTimer() {
        videoPayloadCounter.reset()
        videoRxSampler.reset()
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  self.committedTransportGeneration == nil else { return }
            self.hudTelemetry = TransportHudSnapshot(
                frameReceiveMs: self.hudTelemetry.frameReceiveMs,
                decodeMs: self.hudTelemetry.decodeMs)
        }

        telemetryTimer?.cancel()
        performanceFeedbackTimer?.cancel()
        performanceFeedbackTimer = nil
        telemetryTimer = nil
        adaptiveTelemetryTimer?.cancel()
        adaptiveTelemetryTimer = nil
        pendingClientPings = pendingClientPings.filter { $0.value.purpose != .telemetry }
        transportTelemetry.stopLogging()
    }

    private func publishAudioDiagnosticsIfDue() {
        let generation = connectionGeneration
        guard wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard audioDiagnosticGeneration != generation || now - audioDiagnosticPublishedAt >= 1 else { return }
        audioDiagnosticGeneration = generation
        audioDiagnosticPublishedAt = now
        let opus = committedRealtimeMode == RealtimeTransportMode.wifiRTP ||
            committedRealtimeMode == RealtimeTransportMode.usbSplitTLS
        let profile = usbListenerExplicitlyStarted ? "usb" : "wifi"
        let rejects = "parse_reject=\(wifiMediaReceiver.audioParseRejects) crypto_reject=\(wifiMediaReceiver.audioCryptoRejects)"
        AudioManager.shared.publishDiagnostics(generation: generation, profile: profile,
            opus: opus, receiveRejects: rejects) { [weak self] line in
                self?.networkQueue.async { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                          self.committedTransportGeneration == generation else { return }
                    self.recordDiagnosticLine(line)
                }
            }
    }

    private func sendVideoFeedback() {
        guard wireAuthenticatedGeneration == connectionGeneration else { return }
        publishAudioDiagnosticsIfDue()
        #if targetEnvironment(simulator)
        testingVideoFeedbackCount += 1
        #endif
        sendClientPingIfDue()
        let feedback = transportTelemetry.makeFeedback()
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: feedback.0.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: feedback.1.littleEndian, toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: feedback.2.littleEndian, toByteOffset: 8, as: UInt16.self)
            bytes.storeBytes(of: feedback.3.littleEndian, toByteOffset: 10, as: UInt16.self)
            bytes.storeBytes(of: feedback.4.littleEndian, toByteOffset: 12, as: UInt16.self)
            bytes.storeBytes(of: feedback.5.littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        let stages = transportTelemetry.frameStageP95Ms()
        let feedbackFlags = transportTelemetry.feedbackValidityFlags()
        sendWireMessage(
            type: .videoFeedback,
            payload: payload,
            sequence: feedback.0,
            flags: feedbackFlags)
        // The legacy 8-byte stage packet remains valid for older hosts and carries
        // receive p95, which intentionally has no slot in v1 VideoFeedback.
        sendLegacyFrameStagePacket(
            frameReceiveDurationMs: stages.receive,
            decodeLatencyMs: stages.decode)
        publishHudSnapshotIfDue()
    }

    // The simulator seam supplies a deterministic clock; device timing is unchanged.
    private func performanceFeedbackTime() -> TimeInterval {
        #if targetEnvironment(simulator)
        if let testingPerformanceFeedbackNow { return testingPerformanceFeedbackNow }
        #endif
        return CACurrentMediaTime()
    }

    private func sendPerformanceFeedback() {
        guard isForegroundActive,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration,
              let mode = committedPipelineMode.active,
              mode == desiredPipelineMode,
              let sample = transportTelemetry.freshFrameRateSample(generation: connectionGeneration, at: performanceFeedbackTime()),
              sample.sampleWindowMs <= 2500,
              committedPipelineMode.readyForFeedback(at: performanceFeedbackTime()) else { return }
        func encoded(_ fps: Double) -> UInt16 {
            UInt16(clamping: Int(min(2400, max(0, fps * 10)).rounded()))
        }
        performanceFeedbackSequence &+= 1
        let feedback = ClientPerformanceFeedback(mode: mode, flags: sample.valid ? 3 : 0,
            generation: connectionGeneration, targetFps: mode.targetFps,
            decodedFpsX10: encoded(sample.decodedFps), freshPresentedFpsX10: encoded(sample.freshPresentedFps),
            windowMs: sample.sampleWindowMs, droppedFrames: sample.droppedFrames)
        sendWireMessage(type: .clientPerformanceFeedback, payload: feedback.encode(), sequence: performanceFeedbackSequence)
        recordDiagnosticLine("[IPAD][FPS_FEEDBACK] generation=\(connectionGeneration) mode=\(mode) target_fps=\(mode.targetFps) decode_fps=\(sample.decodedFps) fresh_present_fps=\(sample.freshPresentedFps) window_ms=\(sample.sampleWindowMs)")
    }

    /// Measures a true local RTT for the CSV without comparing clocks. The
    /// Windows host echoes this exact 16-byte payload as a Pong.
    private func sendClientPingIfDue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        #if targetEnvironment(simulator)
        testingPingAttempts += 1
        #endif
        sendClientPing(force: false, purpose: .telemetry)
    }

    @discardableResult
    private func sendClientPing(force: Bool, purpose: ClientPingPurpose, remoteFeaturesProbe: Bool = false) -> UInt64? {
        guard let owner = activeControlConnection else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastClientPingSentAt >= 1 else { return nil }
        lastClientPingSentAt = now

        let nonce = nextClientPingNonce
        nextClientPingNonce &+= 1
        if pendingClientPings.count >= 16,
           let oldest = pendingClientPings.filter({ $0.value.purpose == .telemetry })
            .min(by: { $0.value.sentAt < $1.value.sentAt })?.key {
            pendingClientPings.removeValue(forKey: oldest)
        }
        pendingClientPings[nonce] = PendingClientPing(
            sentAt: now, purpose: purpose, generation: connectionGeneration,
            connectionID: ObjectIdentifier(owner))
        if purpose == .usbLegacyPcmFreshFence { usbLegacyPcmFreshFenceNonce = nonce }

        let sentNanoseconds = UInt64(max(0, now) * 1_000_000_000.0)
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(
                of: sentNanoseconds.littleEndian,
                toByteOffset: 0,
                as: UInt64.self)
            bytes.storeBytes(
                of: nonce.littleEndian,
                toByteOffset: 8,
                as: UInt64.self)
        }
        sendWireMessage(
            type: .ping,
            payload: payload,
            sequence: UInt32(truncatingIfNeeded: nonce),
            flags: remoteFeaturesProbe ? RemoteFeatureNegotiation.supportedFlag : 0)
        return nonce
    }

    private func cancelLegacyUsbPcmFreshFence() {
        if let nonce = usbLegacyPcmFreshFenceNonce {
            pendingClientPings.removeValue(forKey: nonce)
        }
        usbLegacyPcmFreshFenceNonce = nil
        usbLegacyPcmFreshFenceGeneration = nil
    }

    private func armLegacyUsbPcmFreshFence(generation: UInt64) {
        guard generation == connectionGeneration,
              legacyUsbPlaybackEnabledGeneration == generation,
              committedRealtimeMode == RealtimeTransportMode.legacyTLS,
              committedTransportGeneration == generation,
              wireAuthenticatedGeneration == generation,
              activeTransportKind == .usb,
              let owner = usbScdpConnection, connection === owner else { return }
        cancelLegacyUsbPcmFreshFence()
        usbLegacyPcmFreshFenceGeneration = generation
        AudioManager.shared.suspendLegacySessionForLifecycle(generation: generation)
        guard isForegroundActive else { return }
        sendClientPing(force: true, purpose: .usbLegacyPcmFreshFence)
        recordUsbLifecycleDiagnostic(
            "[USB_PCM_RESUME_FENCE] generation=\(generation) action=armed nonce=\(usbLegacyPcmFreshFenceNonce.map { String($0) } ?? "none")")
    }

    private func recordVideoPayloadReceived(_ byteCount: Int, sequence: UInt32) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let generation = connectionGeneration
        guard committedTransportGeneration == generation,
              wireAuthenticatedGeneration == generation else { return }
        videoPayloadCounter.record(byteCount: byteCount, sequence: sequence, generation: generation)
    }
    private func publishHudSnapshotIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHudSnapshotPublishedAt >= 0.5 else { return }
        lastHudSnapshotPublishedAt = now
        let stages = transportTelemetry.hudSnapshot()
        publishHudSnapshot(TransportHudSnapshot(frameReceiveMs: stages.frameReceiveMs,
            decodeMs: stages.decodeMs,
            videoRxMbps: videoRxSampler.sample(totalBytes: videoPayloadCounter.totalBytes, at: now)))
    }
    private func publishHudSnapshot(_ snapshot: TransportHudSnapshot) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let generation = connectionGeneration
        let modeEpoch = realtimeModeClock.current
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.connectionGeneration == generation,
                  self.realtimeModeClock.current == modeEpoch else { return }
            self.hudTelemetry = snapshot
            self.lastFrameReceiveDurationMs = snapshot.frameReceiveMs
            self.lastDecodeLatencyMs = snapshot.decodeMs
        }
    }


    private func receivedLibraryOnWorker() throws -> ReceivedFileLibrary {
        dispatchPrecondition(condition: .onQueue(receivedFilesQueue))
        if let receivedStorage { return receivedStorage }
        let library = try ReceivedFileLibrary(directory: retainedTransferRoot)
        receivedStorage = library
        networkQueue.async { [weak self] in self?.retainedFileLibrary = library }
        return library
    }
    private func publishReceivedUI(revision: UInt64, _ update: @escaping (NetworkManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, revision >= self.receivedUIRevision else { return }
            self.receivedUIRevision = revision; update(self)
        }
    }
    private func advanceReceivedRevisionOnQueue() {
        let revision = receivedActionClock.advance()
        pendingReceivedClearID = nil
        publishReceivedUI(revision: revision) { $0.receivedClearPrompt = nil }
        refreshReceivedFilesOnQueue()
    }
    func refreshReceivedFiles() { networkQueue.async { [weak self] in self?.refreshReceivedFilesOnQueue() } }
    private func refreshReceivedFilesOnQueue() {
        if receivedRefreshInFlight { receivedRefreshRequested = true; return }
        receivedRefreshInFlight = true
        let revision = receivedActionClock.current
        receivedFilesQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.receivedLibraryOnWorker().snapshot() }
            self.networkQueue.async {
                self.receivedRefreshInFlight = false
                if revision == self.receivedActionClock.current {
                    self.publishReceivedUI(revision: revision) { owner in
                        switch result {
                        case .success(let data): owner.receivedFilesViewState = ReceivedFilesViewState(data)
                        case .failure:
                            owner.receivedFilesViewState.loaded = false
                            owner.receivedFilesViewState.storageWarning = "Stored files cannot be inspected safely. Try again."
                        }
                    }
                } else { self.receivedRefreshRequested = true }
                if self.receivedRefreshRequested { self.receivedRefreshRequested = false; self.refreshReceivedFilesOnQueue() }
            }
        }
    }
    private func receivedMessage(_ text: String, revision: UInt64) {
        publishReceivedUI(revision: revision) { $0.receivedClearMessage = text }
    }
    func requestClearReceivedFiles() {
        networkQueue.async { [weak self] in
            guard let self, self.pendingReceivedClearID == nil else { return }
            let id = UUID(), revision = self.receivedActionClock.current, session = self.connectionGeneration
            self.pendingReceivedClearID = id
            self.receivedFilesQueue.async {
                do {
                    let library = try self.receivedLibraryOnWorker(), inventory = try library.snapshot()
                    guard !inventory.busy else { throw CocoaError(.fileLocking) }
                    guard inventory.retainedCount > 0 else {
                        self.networkQueue.async {
                            if self.pendingReceivedClearID == id { self.pendingReceivedClearID = nil }
                            self.receivedMessage("No received files are available to delete.", revision: revision)
                        }; return
                    }
                    let token = try library.confirmClear(), current = try library.snapshot()
                    guard current.fingerprint == inventory.fingerprint, current.revision == inventory.revision,
                          self.receivedActionClock.current == revision else { throw CocoaError(.fileReadUnknown) }
                    self.pendingStorageClear = (id, token, inventory.fingerprint, inventory.revision)
                    let prompt = ReceivedClearPrompt(id: id, count: token.count, bytes: token.bytes,
                                                     legacyCount: inventory.retainedCount - inventory.eligibleCount,
                                                     legacyBytes: inventory.retainedBytes - inventory.eligibleBytes)
                    self.networkQueue.async {
                        guard self.pendingReceivedClearID == id, self.receivedActionClock.current == revision,
                              self.connectionGeneration == session else { return }
                        self.publishReceivedUI(revision: revision) { $0.receivedClearMessage = nil; $0.receivedClearPrompt = prompt }
                    }
                } catch {
                    self.networkQueue.async {
                        if self.pendingReceivedClearID == id { self.pendingReceivedClearID = nil }
                        self.receivedMessage("Cannot clear while a transfer or Save to Files is active, or storage is unavailable.", revision: revision)
                    }
                }
            }
        }
    }
    func cancelClearReceivedFiles(id: UUID) {
        networkQueue.async { [weak self] in
            guard let self, self.pendingReceivedClearID == id else { return }
            self.pendingReceivedClearID = nil
            self.publishReceivedUI(revision: self.receivedActionClock.current) { $0.receivedClearPrompt = nil }
            self.receivedFilesQueue.async { if self.pendingStorageClear?.id == id { self.pendingStorageClear = nil } }
        }
    }
    func confirmClearReceivedFiles(id: UUID) {
        networkQueue.async { [weak self] in
            guard let self, self.pendingReceivedClearID == id else { return }
            self.pendingReceivedClearID = nil // Consume before dispatch: double taps cannot enqueue a second delete.
            let revision = self.receivedActionClock.current, generation = self.connectionGeneration
            self.publishReceivedUI(revision: revision) { $0.receivedClearPrompt = nil }
            self.receivedFilesQueue.async {
                var result: ReceivedFileLibrary.ClearResult?, inventory: ReceivedFileLibrary.Inventory?
                var message = "Received files changed. Review and confirm again."
                do {
                    guard let pending = self.pendingStorageClear, pending.id == id else { throw CocoaError(.fileReadUnknown) }
                    self.pendingStorageClear = nil
                    let library = try self.receivedLibraryOnWorker(), current = try library.snapshot()
                    guard self.receivedActionClock.current == revision,
                          current.fingerprint == pending.fingerprint, current.revision == pending.storageRevision else { throw CocoaError(.fileReadUnknown) }
                    guard !current.busy else { throw CocoaError(.fileLocking) }
                    result = try library.clear(pending.token, expectedFingerprint: pending.fingerprint,
                                               expectedRevision: pending.storageRevision, authorize: {
                        self.receivedActionClock.current == revision && self.connectionGenerationClock.current == generation
                    })
                    inventory = try library.snapshot()
                    message = TransferPresentation.clearResult(result!, legacyCount: inventory!.retainedCount - inventory!.eligibleCount)
                } catch { /* A fresh snapshot below reports surviving bytes; no inferred reclamation. */ }
                self.networkQueue.async {
                    if self.receivedActionClock.current == revision {
                        self.receivedMessage(message, revision: revision)
                        if let data = inventory {
                            self.publishReceivedUI(revision: revision) { owner in
                                owner.receivedFilesViewState = ReceivedFilesViewState(data)
                                if (result?.deletedCount ?? 0) > 0, !owner.transferSnapshot.outgoing,
                                   owner.transferSnapshot.phase == .completed {
                                    owner.transferSnapshot.count = 0 // Preserve failure/stage/direction diagnostics.
                                    owner.transferSnapshot.received = data.files
                                    owner.transferSnapshot.retainedCount = data.retainedCount
                                    owner.transferSnapshot.retainedBytes = data.retainedBytes
                                }
                            }
                        }
                    }
                    self.advanceReceivedRevisionOnQueue()
                }
            }
        }
    }
    func requestReceivedFileExport(_ url: URL, completion: @escaping (UUID?) -> Void) {
        networkQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            self.advanceReceivedRevisionOnQueue()
            self.receivedFilesQueue.async {
                let token = try? self.receivedLibraryOnWorker().beginExport(url)
                self.networkQueue.async {
                    if token == nil { self.receivedMessage("Cannot export while a transfer is active or this file is unavailable.", revision: self.receivedActionClock.current) }
                    self.advanceReceivedRevisionOnQueue()
                    DispatchQueue.main.async { completion(token) }
                }
            }
        }
    }
    func releaseReceivedFileExport(_ token: UUID) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.receivedFilesQueue.async {
                self.receivedStorage?.endExport(token) // App-storage lease survives network teardown; foreign token is inert.
                self.networkQueue.async { self.advanceReceivedRevisionOnQueue() }
            }
        }
    }

    private struct AutoAcceptScope: Equatable {
        let generation: UInt64
        let usb: Bool
        let connectionID: ObjectIdentifier
    }
    private var autoAcceptScope: AutoAcceptScope?
    private var autoAcceptObservedScope: AutoAcceptScope?
    private let autoAcceptSessionClock = ConnectionGenerationClock()
    private var autoAcceptPolicyRevision: UInt64 = 0
    private var autoAcceptUIRevision: UInt64 = 0 // Main queue only.
    @Published private(set) var autoAcceptIncomingFiles = false
    @Published private(set) var canEnableAutoAccept = false
    private func currentAutoAcceptScopeOnQueue() -> AutoAcceptScope? {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard let connection, wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration else { return nil }
        if case .authFailed = transportState { return nil }
        return AutoAcceptScope(generation: connectionGeneration, usb: activeTransportKind == .usb,
                               connectionID: ObjectIdentifier(connection))
    }
    private func publishAutoAcceptOnQueue() {
        autoAcceptPolicyRevision &+= 1
        let revision = autoAcceptPolicyRevision
        let scope = currentAutoAcceptScopeOnQueue()
        let enabled = scope != nil && autoAcceptScope == scope
        let available = scope != nil
        DispatchQueue.main.async { [weak self] in
            guard let self, revision >= self.autoAcceptUIRevision else { return }
            self.autoAcceptUIRevision = revision
            self.autoAcceptIncomingFiles = enabled; self.canEnableAutoAccept = available
        }
    }
    private func resetAutoAcceptOnQueue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        autoAcceptScope = nil; autoAcceptObservedScope = nil
        _ = autoAcceptSessionClock.advance()
        dataTransfers?.setAutoAccept(false, localGeneration: connectionGeneration)
        publishAutoAcceptOnQueue()
    }
    private func refreshAutoAcceptPolicyOnQueue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let scope = currentAutoAcceptScopeOnQueue()
        let changed = scope != autoAcceptObservedScope
        if changed {
            autoAcceptObservedScope = scope; autoAcceptScope = nil
            _ = autoAcceptSessionClock.advance()
        }
        dataTransfers?.setAutoAccept(scope != nil && autoAcceptScope == scope,
                                    localGeneration: connectionGeneration)
        // Packet admission rechecks scope without publishing UI work per chunk.
        if changed { publishAutoAcceptOnQueue() }
    }
    func setAutoAcceptIncomingFiles(_ requested: Bool) {
        // Lock-backed clocks fence commands queued before retirement/handover.
        let generation = connectionGenerationClock.current
        let epoch = autoAcceptSessionClock.current
        networkQueue.async { [weak self] in
            guard let self else { return }
            let scope = self.currentAutoAcceptScopeOnQueue()
            let allowed = requested && generation == self.connectionGeneration &&
                epoch == self.autoAcceptSessionClock.current && scope != nil
            self.autoAcceptScope = allowed ? scope : nil
            self.dataTransfers?.setAutoAccept(allowed, localGeneration: self.connectionGeneration)
            self.publishAutoAcceptOnQueue()
        }
    }

    func sendTransferFiles(_ urls: [URL]) { networkQueue.async { [weak self] in self?.dataTransfers?.sendFiles(urls) } }
    func decideTransfer(_ accepted: Bool) { networkQueue.async { [weak self] in self?.dataTransfers?.decide(accepted) } }
    func cancelTransfer() { networkQueue.async { [weak self] in self?.controlChannelWriter.cancelBulk(); self?.dataTransfers?.cancel() } }
    private func beginDataTransfer(generation: UInt64) {
        guard generation == connectionGeneration, dataTransfers == nil else { return }
        let manager = DataTransferManager(generation: generation, directory: retainedTransferRoot,
                                          transport: activeTransportKind == .usb ? "USB-C" : "Wi-Fi",
                                          receivedLibrary: retainedFileLibrary,
                                          onLibraryReady: { [weak self] library in
            // Authority opens on the transfer IO worker, not the latency-sensitive network queue.
            self?.networkQueue.async { [weak self] in self?.retainedFileLibrary = library }
        }) { [weak self] packet, completion in
            guard let self else { completion(false); return }
            self.networkQueue.async {
                guard generation == self.connectionGeneration, self.wireAuthenticatedGeneration == generation,
                      self.committedTransportGeneration == generation, let kind = WireMessageType(rawValue: packet.kind.rawValue),
                      let payload = try? TransferProtocol.encode(packet) else { completion(false); return }
                self.sendWireMessage(type: kind, payload: payload, sequence: 0, bulk: true) { completion($0 == nil) }
            }
        }
        let transferTransport = activeTransportKind == .usb ? "USBC" : "WiFi"
        manager.diagnostic = { [weak self] line in
            self?.recordDiagnosticLine(line + " transport=\(transferTransport)")
        }
        manager.changed = { [weak self, weak manager] snapshot in
            guard let self else { return }
            self.networkQueue.async {
                guard let manager, self.dataTransfers === manager,
                      self.connectionGeneration == generation else { return }
                let event = "\(generation)|\(snapshot.phase.rawValue)|\(snapshot.published)|\(snapshot.count)|\(snapshot.outgoing)"
                if self.receivedTransferEvent != event {
                    self.receivedTransferEvent = event; self.advanceReceivedRevisionOnQueue()
                }
                DispatchQueue.main.async {
                    guard self.connectionGenerationClock.current == generation else { return }
                    self.transferSnapshot = snapshot
                }
            }
        }
        dataTransfers = manager
        refreshAutoAcceptPolicyOnQueue()
    }
    private func sendWireMessage(
        type: WireMessageType,
        payload: Data,
        sequence: UInt32,
        flags: UInt16 = 0,
        movement: Bool = false,
        bulk: Bool = false,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        guard payload.count <= WireProtocol.maxPayloadSize else { return }
        let sendGeneration = connectionGeneration
        let sendConnection = connection
        let sendTransport = activeTransportKind
        var message = Data(count: WireProtocol.headerSize)
        message.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: WireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: WireProtocol.version, toByteOffset: 4, as: UInt8.self)
            bytes.storeBytes(of: type.rawValue, toByteOffset: 5, as: UInt8.self)
            bytes.storeBytes(of: flags.littleEndian, toByteOffset: 6, as: UInt16.self)
            bytes.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: 8, as: UInt32.self)
            bytes.storeBytes(of: sequence.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        message.append(payload)
        enqueueControlData(
            message,
            telemetry: type == .videoFeedback && flags != CaptureTargetProtocol.recoveryFlag,
            movement: movement,
            bulk: bulk,
            completion: { [weak self] error in
                // Queued bulk cancellation is terminal for its transfer owner,
                // not a transport send failure. Preserve the authenticated session.
                if bulk, case .posix(.ECANCELED)? = error {
                    completion(error)
                    return
                }
                if let error {
                    self?.handleControlSendError(
                        error, generation: sendGeneration,
                        connection: sendConnection,
                        transport: sendTransport)
                }
                completion(error)
            })
    }

    private func handleControlSendError(
        _ error: NWError,
        generation: UInt64,
        connection sentConnection: NWConnection?,
        transport: ActiveTransportKind
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if transport == .wifi {
            guard generation == connectionGeneration,
                  connection === sentConnection else { return }
            if let sentConnection,
               shouldPreserveTransientWifiControlError(
                   error, generation: generation, connection: sentConnection) {
                recordWifiLifecycleDiagnostic(
                    "generation=\(generation) event=control_send_error " +
                    "action=preserve_transient")
                return
            }
        }
        handleStreamError("Control send error: \(error)")
    }

    private func enqueueControlData(
        _ data: Data,
        telemetry: Bool = false,
        movement: Bool = false,
        bulk: Bool = false,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        let generation = connectionGeneration
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            if bulk {
                if !self.controlChannelWriter.enqueueBulk(data, completion: completion) { completion(.posix(.ENOBUFS)) }
            } else if telemetry {
                self.controlChannelWriter.enqueueTelemetry(data, completion: completion)
            } else if movement {
                self.controlChannelWriter.enqueueMovement(data, completion: completion)
            } else if !self.controlChannelWriter.enqueue(data, completion: completion) {
                self.handleStreamError("Control queue reached its 64-message bound.")
            }
        }
    }

    // MARK: Incremental SCST Receive Loop

    private func startWireReceiveLoop(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration, connection != nil else { return }
        guard wireReceiveActiveGeneration != generation else { return }
        #if targetEnvironment(simulator)
        testingInitialReceiveStarts += 1
        #endif
        wireReceiveActiveGeneration = generation
        wireAuthenticatedGeneration = nil
        committedTransportGeneration = nil
        committedTransportAudioAvailable = false
        advertisedClientCapabilities = nil
        clearPendingTransportOffer()
        wireParser.reset(generation: generation)
        receiveWireChunk(generation: generation)
    }

    private var transferReceiveHasCapacity: Bool {
        transferReceivePending < DataTransferManager.maxPendingPackets
    }

    private func receiveWireChunk(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireReceiveActiveGeneration == generation,
              let connection else { return }

        if let outstanding = wireReceiveOutstanding,
           outstanding.generation == generation,
           outstanding.connection == ObjectIdentifier(connection) { return }
        if let suffix = transferReceiveSuffix {
            guard suffix.generation == generation, suffix.connection === connection else {
                transferReceiveSuffix = nil
                return
            }
            guard transferReceiveHasCapacity else { return }
            transferReceiveSuffix = nil
            consumeWireReceive(suffix.data, generation: generation, connection: connection,
                               receivedAt: suffix.receivedAt, isComplete: suffix.isComplete)
            return
        }
        guard transferReceiveHasCapacity else { return }
        wireReceiveOutstanding = (generation, ObjectIdentifier(connection))

        let maximumLength = wireParser.suggestedReceiveLength
        let completion: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, isComplete, error in
            guard let self,
                  generation == self.connectionGeneration,
                  self.connection === connection,
                  self.wireReceiveActiveGeneration == generation else { return }
            self.wireReceiveOutstanding = nil
            if let error {
                self.handleWireReceiveError(
                    error, generation: generation, connection: connection)
                return
            }

            self.consumeWireReceive(data ?? Data(), generation: generation, connection: connection,
                                    receivedAt: CACurrentMediaTime(), isComplete: isComplete)
        }
        #if targetEnvironment(simulator)
        if let transferReceiveForTesting {
            transferReceiveForTesting(maximumLength, completion)
            return
        }
        #endif
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength, completion: completion)
    }

    private func consumeWireReceive(_ data: Data, generation: UInt64, connection: NWConnection,
                                    receivedAt: TimeInterval, isComplete: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard data.count <= WireProtocol.receiveChunkSize else {
            handleStreamError("Receive buffer exceeded its bound.")
            return
        }
        let consumed = wireParser.consume(data, generation: generation, receivedAt: receivedAt,
            shouldContinue: { self.transferReceiveHasCapacity }) { event in
                self.handleWireParserEvent(event, generation: generation)
            }
        guard generation == connectionGeneration, self.connection === connection,
              wireReceiveActiveGeneration == generation else { return }
        if consumed < data.count {
            // One bounded socket buffer owns the FIFO suffix; no new read may bypass it.
            transferReceiveSuffix = TransferReceiveSuffix(data: Data(data.dropFirst(consumed)),
                receivedAt: receivedAt, generation: generation, connection: connection, isComplete: isComplete)
            return
        }
        if isComplete {
            handleStreamError("Server closed the stream.")
            return
        }
        if transferReceiveHasCapacity { receiveWireChunk(generation: generation) }
    }

    private func handleWireReceiveError(
        _ error: NWError,
        generation: UInt64,
        connection receivedConnection: NWConnection
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              connection === receivedConnection,
              wireReceiveActiveGeneration == generation else { return }
        if shouldPreserveTransientWifiControlError(
            error, generation: generation, connection: receivedConnection) {
            wireReceiveActiveGeneration = nil
            recordWifiLifecycleDiagnostic(
                "generation=\(generation) event=control_receive_error " +
                "action=preserve_transient_receive_stopped")
            return
        }
        handleStreamError("SCST receive error: \(error.localizedDescription)")
    }

    private func handleWireParserEvent(_ event: WireParserEvent, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        switch event {
        case .failure(.invalidHeader):
            handleStreamError("Invalid wire-protocol header.")
        case .failure(.oversizedPayload):
            handleStreamError("Wire payload exceeds the 8 MiB limit.")
        case .discardedFixedControl(let header):
            print("[NetworkManager] Discarded malformed \(header.type) payload.")
        case .message(let message):
            handleWireMessage(message, generation: generation)
        }
    }

    private func handleWireMessage(_ message: WireMessage, generation: UInt64) {
        let header = message.header
        let payload = message.payload

        guard wireAuthenticatedGeneration == generation else {
            if activeTransportKind == .usb {
                guard generation == connectionGeneration,
                      wireReceiveActiveGeneration == generation,
                      connection != nil,
                      usbScdpConnection != nil,
                      connection === usbScdpConnection else { return }
                guard header.type == .ping, payload.count == 16 else {
                    handleStreamError(
                        "Expected a 16-byte SCDP Ping before USB session commit.")
                    return
                }
                sendWireMessage(
                    type: .pong,
                    payload: payload,
                    sequence: header.sequence
                ) { [weak self] error in
                    guard let self,
                          error == nil,
                          generation == self.connectionGeneration,
                          self.wireReceiveActiveGeneration == generation,
                          self.connection != nil,
                          self.usbScdpConnection != nil,
                          self.connection === self.usbScdpConnection,
                          self.wireAuthenticatedGeneration == nil else { return }
                    self.wireAuthenticatedGeneration = generation
                    self.commitLegacyTransport(generation: generation)
                    print("[IPAD][USB_SCDP_READY] generation=\(generation)")
                    self.recordUsbLifecycleDiagnostic(
                        "[USB_SCDP_READY] generation=\(generation)")
                }
                return
            }
            if header.type == .pairingRequired {
                print("[IPAD][PAIRING_REQUIRED] host=unknown")
                setState(.awaitingPIN)
                return
            }
            if header.type == .trustedDeviceChallenge {
                answerTrustedChallenge(payload, generation: generation)
                return
            }
            guard header.type == .authResult, !payload.isEmpty else {
                handleStreamError("Expected a framed authentication response.")
                return
            }
            let accepted = payload[0] != 0
            let reason = String(data: payload.dropFirst(), encoding: .utf8) ?? ""
            if accepted {
                reconnectAttempt = 0
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                print("[IPAD][AUTO_RECONNECT_SUCCESS] generation=\(generation)")
                wireAuthenticatedGeneration = generation
                committedTransportGeneration = nil
                beginRemoteFeaturesOnQueue(generation: generation)
                committedTransportAudioAvailable = false
                committedRealtimeSessionID = nil
                wifiLegacyFallbackRequestGeneration = nil
                clearPendingTransportOffer()
                wifiCommitGate.reset()
                let supportsNegotiation =
                    (header.flags &
                     WireProtocol.realtimeNegotiationSupportedFlag) != 0
                if supportsNegotiation {
                    sendClientCapabilities(for: activeTransportKind)
                } else {
                    commitLegacyTransport(generation: generation)
                }
            } else {
                setState(.authFailed(
                    reason: reason.isEmpty ? "Incorrect PIN. Please try again." : reason))
            }
            return
        }

        switch header.type {
        case .transferOffer, .transferResponse, .transferChunk, .transferFileEnd, .transferFileAck, .transferCancel, .transferEnd, .transferAck:
            guard wireAuthenticatedGeneration == generation, committedTransportGeneration == generation,
                  let kind = TransferKind(rawValue: header.type.rawValue) else { return }
            do {
                let packet = try TransferProtocol.decode(kind,payload)
                if let manager = dataTransfers {
                    refreshAutoAcceptPolicyOnQueue()
                    if kind == .cancel && manager.owns(packet) { controlChannelWriter.cancelBulk() }
                    transferReceivePending += 1
                    let post: (TransferPacket, @escaping () -> Void) -> Bool
                    #if targetEnvironment(simulator)
                    post = transferPostForTesting ?? { manager.post($0, completion: $1) }
                    #else
                    post = { manager.post($0, completion: $1) }
                    #endif
                    if !post(packet, { [weak self] in
                        guard let self else {return}
                        self.networkQueue.async {
                            guard generation == self.connectionGeneration, self.dataTransfers === manager else {return}
                            self.transferReceivePending = max(0,self.transferReceivePending-1)
                            if self.transferReceiveHasCapacity { self.receiveWireChunk(generation:generation) }
                        }
                    }) { transferReceivePending -= 1 }
                }
            }
            catch { dataTransfers?.cancel(failed: true) }
            return
        case .pairingSuccess:
            storePairingCredential(payload)

        case .trustedAuthResult:
            guard !payload.isEmpty, payload[0] != 0 else {
                setState(.authFailed(reason: "Trusted device authentication failed."))
                return
            }
            print("[IPAD][TRUSTED_AUTH_SUCCESS] generation=\(generation)")

        case .sessionResumeResult:
            updateResumedSession(payload)

        case .settingsState:
            receiveSettingsState(payload, outcome: .state)

        case .settingsApplied:
            receiveSettingsState(payload, outcome: .applied)

        case .settingsRejected:
            receiveSettingsState(
                payload,
                outcome: .rejected(.none))

        case .forgetDeviceResult:
            guard payload.count == 2, payload[0] == 1 else { return }
            if payload[1] == 1, let fingerprint = verifiedHostFingerprint {
                trustedCredentialStore.delete(fingerprint: fingerprint)
                trustedHostFingerprintStore.delete()
                trustedCredential = nil
                UserDefaults.standard.removeObject(forKey: Self.lastKnownHostKey)
                reconnectEnabled = false
                print("[IPAD][TRUSTED_HOST_FORGOTTEN] credential=deleted")
                stop()
                RecentWifiResumeStore.clear()
                WifiReconnectTargetStore.clear()
            } else {
                DispatchQueue.main.async {
                    self.settingsApplyStatus = "Forget failed"
                }
            }

        case .displayCapabilities:
            guard let capabilities = DisplayCapabilities.decode(payload) else {
                handleStreamError("Malformed display capabilities.")
                return
            }
            if let hello = mirrorControl.helloIfAdvertised(session: generation, flags: header.flags) {
                mirrorSwitchAdvertised=header.flags & 0x2000 != 0
                sendWireMessage(type: .mirrorHello, payload: hello, sequence: 0)
            }
            if !remoteInputConnection, committedTransportGeneration == generation,
               let hello = captureTargets.advertise(flags: header.flags, generation: generation) {
                mirrorControl.enableTypedSources(session: generation)
                sendWireMessage(type: .sourceHello, payload: hello, sequence: 0)
                scheduleCaptureTargetListWaitOnQueue()
                publishMirrorStateOnQueue()
            }
            receiveDisplayCapabilities(capabilities)

        case .displayReady:
            guard let ready = DisplayReady.decode(payload) else {
                handleStreamError("Malformed display readiness response.")
                return
            }
            receiveDisplayReady(ready)

        case .displayConfigurationFailed:
            guard let failure = DisplayConfigurationFailed.decode(payload) else {
                handleStreamError("Malformed display configuration failure.")
                return
            }
            receiveDisplayConfigurationFailure(failure)

        case .presentationActivity:
            return

        case .pipelineMode:
            guard wireAuthenticatedGeneration == generation,
                  committedTransportGeneration == generation,
                  let mode = PipelineMode.decode(payload),
                  committedPipelineMode.acknowledge(mode) else { return }
            if captureTargetOwnsPresentation { abandonCaptureTargetPresentationOnQueue() }
            transportTelemetry.beginFreshFrameRate(generation: generation)
            return

        case .clientPerformanceFeedback:
            return

        case .cursorOwnership:
            guard generation == connectionGeneration,
                  committedTransportGeneration == generation,
                  transportState == .streaming,
                  let command = CursorOwnershipCommand.decode(payload) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGenerationClock.current == generation else { return }
                self.cursorOwnershipState = command.state
            }
            return

        case .mirrorState:
            guard committedTransportGeneration == generation, header.flags == 0 else { return }
            do {
                let oldState = mirrorControl.currentState
                if let transition = try mirrorControl.receiveState(session: generation, data: payload) {
                    if oldState?.epoch != transition.state.epoch && !captureTargetOwnsPresentation {
                        currentMirrorCatalogue=nil;mirrorCatalogueSource=nil
                        decoder.invalidate(waitForCompletion: false)
                        beginOwnedDecoderSession(networkGeneration: generation)
                    }
                    // The first anchor is reported after its completed write. That IDR may
                    // already have been discarded while metadata was pending; request a fresh
                    // dependency root using the existing recovery owner, not a media retry lane.
                    if !captureTargetOwnsPresentation, oldState?.firstFrame == nil, transition.state.firstFrame != nil {
                        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                            wifiMediaReceiver.requestImmediateRecoveryFeedback(generation: generation)
                        } else if let recovery=mirrorControl.presentationRecoveryRequest() {
                            sendWireMessage(type:.mirrorAction,payload:recovery,sequence:0)
                        }
                    }
                    if let ack = transition.acknowledgement { sendWireMessage(type: .mirrorAction, payload: ack, sequence: 0) }
                    advanceMirrorTerminalSwitchOnQueue()
                    if captureTargets.pending == nil, let owner=currentCaptureTargetDecoderOwner, !captureTargetModeMatches(owner: owner) {
                        abandonCaptureTargetPresentationOnQueue()
                    } else { advanceCaptureTargetVideoOnQueue() }
                    publishMirrorStateOnQueue()
                }
            } catch { handleStreamError("Invalid physical-source control state.") }
            return
        case .sourceCatalogue:
            guard !remoteInputConnection, committedTransportGeneration == generation, captureTargets.enabled,
                  header.flags == 0 else { return }
            do {
                let value=try CaptureTargetCatalogue.decode(payload)
                if captureTargets.receiveCatalogue(value, session: captureTargets.session) {
                    captureTargetCatalogueAt=ProcessInfo.processInfo.systemUptime
                    if let applied=captureTargets.applied, value.epoch != applied.epoch || value.state != 1 {
                        abandonCaptureTargetPresentationOnQueue()
                    }
                    publishMirrorStateOnQueue()
                }
            } catch { handleStreamError("Invalid capture source catalogue.") }
            return
        case .sourceSwitchResult:
            guard !remoteInputConnection, committedTransportGeneration == generation, captureTargets.enabled,
                  header.flags == 0 else { return }
            do {
                let value=try CaptureTargetResult.decode(payload)
                let wasAccepted=captureTargets.pending?.accepted == true
                guard captureTargets.receiveResult(value, session: captureTargets.session) else { return }
                if value.status == .accepted {
                    if !wasAccepted { retireCaptureTargetDecoderOnQueue() }
                } else if value.status == .applied, captureTargets.applied != nil {
                    if let applied=captureTargets.applied,
                       captureTargets.catalogue?.epoch != applied.epoch || captureTargets.catalogue?.state != 1 {
                        abandonCaptureTargetPresentationOnQueue()
                    } else { advanceCaptureTargetVideoOnQueue();startCaptureTargetRecoveryOnQueue() }
                } else { retireCaptureTargetDecoderOnQueue() }
                if captureTargets.needsCatalogueRefresh { refreshCaptureTargetsOnQueue() }
                publishMirrorStateOnQueue()
            } catch { handleStreamError("Invalid capture source switch result.") }
            return
        case .sourceHello, .sourceSwitchRequest:
            handleStreamError("Invalid capture source control direction.")
            return
        case .mirrorCatalogue:
            guard committedTransportGeneration==generation,mirrorSwitchAdvertised,header.flags==0 else {return}
            do {
                let catalogue=try MirrorMonitorCatalogue.decode(payload)
                guard catalogue.revision>lastMirrorCatalogueRevision,
                      let source=mirrorControl.currentState,source.geometry != nil else {return}
                lastMirrorCatalogueRevision=catalogue.revision
                mirrorCatalogueReceivedAt=ProcessInfo.processInfo.systemUptime
                currentMirrorCatalogue=catalogue
                mirrorCatalogueSource=(source.epoch,source.source)
                publishMirrorStateOnQueue()
            } catch {handleStreamError("Invalid physical monitor list.")}
            return
        case .mirrorAction:
            guard committedTransportGeneration==generation,header.flags==0,
                  mirrorControl.supportsTerminalSwitch else {
                handleStreamError("Invalid physical-source control direction.");return
            }
            guard mirrorTerminalSend != nil else {return}
            do {
                try mirrorControl.receiveTerminalAcknowledgement(session:generation,data:payload)
                advanceMirrorTerminalSwitchOnQueue()
            } catch {
                // An unmatched terminal response is never switch or input authority.
                mirrorControl.cancelTerminalSwitch();mirrorTerminalSend=nil
            }
            publishMirrorStateOnQueue();return
        case .mirrorHello, .mirrorInput, .mirrorSwitchRequest:
            handleStreamError("Invalid physical-source control direction.")
            return
        case .directTouchContact, .pointerInput, .keyboardInput, .textCommit:
            return

        case .video:
            guard committedTransportGeneration == generation else { return }
            if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                // A legacy payload cannot authorize its own transition. The
                // exact host commit must arrive first on authenticated TLS.
                return
            }
            if !captureTargetOwnsPresentation {
                guard mirrorControl.permitsVideoSequence(header.sequence) else { return }
            }
            let receivedAt = CACurrentMediaTime()
            if remoteInputConnection, header.flags & WireProtocol.videoFlagIDR != 0, !remoteFeatures.inputReady {
                remoteFeatures.keyframeArrived()
                publishRemoteInputOnQueue(contextChanged: false)
            }
            let receiveDurationMs = max(0, (receivedAt - message.firstByteAt) * 1_000.0)
            recordVideoPayloadReceived(payload.count, sequence: header.sequence)
            bytesReceived &+= UInt64(payload.count)
            transportTelemetry.recordPayloadReceived(
                sequence: header.sequence,
                receiveDurationMs: receiveDurationMs,
                receivedAt: receivedAt,
                payloadBytes: payload.count,
                isIDR: (header.flags & WireProtocol.videoFlagIDR) != 0,
                generation: generation,
                transportKind: activeTransportKind == .usb
                    ? StreamingTransportKind.usbTypeC.rawValue
                    : StreamingTransportKind.wifi.rawValue)
            if consumeCaptureTargetVideoOnQueue(payload, sequence: header.sequence,
                isIDR: header.flags & WireProtocol.videoFlagIDR != 0,
                lengthPrefixed: header.flags & WireProtocol.videoFlagLengthPrefixed != 0,
                receivedAt: receivedAt) { return }
            decoder.processInputData(
                payload,
                sequence: header.sequence,
                isIDR: (header.flags & WireProtocol.videoFlagIDR) != 0,
                isLengthPrefixed:
                    (header.flags & WireProtocol.videoFlagLengthPrefixed) != 0,
                receivedAt: receivedAt)

        case .videoConfiguration:
            guard committedTransportGeneration == generation,
                  let configuration = VideoConfigurationV1.decode(payload),
                  configuration.generation == generation else {
                handleStreamError("Malformed or stale video configuration.")
                return
            }
            if captureTargets.applied != nil { abandonCaptureTargetPresentationOnQueue() }
            let accepted: Bool
            let errorCode: UInt16
            if configuration.codec == .h264,
               configuration.parameterSets.count == 2,
               configuration.width.isMultiple(of: 2),
               configuration.height.isMultiple(of: 2) {
                accepted = decoder.configureH264(
                    sps: configuration.parameterSets[0],
                    pps: configuration.parameterSets[1])
                errorCode = accepted ? 0 : 2
            } else {
                accepted = false
                errorCode = 1
            }
            if accepted {
                activeVideoCodec = configuration.codec
                captureTargetH264ParameterSets=configuration.parameterSets
            }
            let ack = VideoConfigurationAckV1(
                generation: configuration.generation,
                accepted: accepted,
                errorCode: errorCode,
                codec: configuration.codec,
                width: accepted ? configuration.width : 0,
                height: accepted ? configuration.height : 0)
            sendWireMessage(
                type: .videoConfigurationAck,
                payload: ack.encode(),
                sequence: header.sequence)

        case .ping:
            sendWireMessage(type: .pong, payload: payload, sequence: header.sequence)

        case .pong:
            guard payload.count == 16 else { return }
            let nonce = payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
            }
            if remoteInputConnection, remoteFeaturesPingNonce == nonce {
                remoteFeaturesPingNonce = nil
                if let request = remoteFeatures.pong(flags: header.flags, now: ProcessInfo.processInfo.systemUptime) {
                    sendWireMessage(type: .remoteFeaturesRequest, payload: request, sequence: 0)
                }
            }
            if let pending = pendingClientPings[nonce],
               pending.generation == generation,
               generation == connectionGeneration,
               let owner = activeControlConnection,
               pending.connectionID == ObjectIdentifier(owner) {
                pendingClientPings.removeValue(forKey: nonce)
                let rttMs = max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - pending.sentAt) * 1_000.0)
                transportTelemetry.recordRtt(durationMs: rttMs)
                if pending.purpose == .usbCandidateLiveness,
                   let candidate = pendingUsbCandidate, ownsUsbCandidate(candidate),
                   candidate.livenessNonce == nonce {
                    cancelUsbCandidateArbitration(reason: "incumbent_liveness_pong")
                }
                if pending.purpose == .usbLegacyPcmFreshFence,
                   usbLegacyPcmFreshFenceNonce == nonce,
                   legacyUsbPlaybackEnabledGeneration == generation,
                   isForegroundActive,
                   isCurrentCommittedUsbStreamingSessionOnQueue(generation: generation),
                   committedRealtimeMode == RealtimeTransportMode.legacyTLS {
                    usbLegacyPcmFreshFenceNonce = nil
                    usbLegacyPcmFreshFenceGeneration = nil
                    AudioManager.shared.resumeLegacySessionAfterFreshFence(generation: generation)
                    recordUsbLifecycleDiagnostic(
                        "[USB_PCM_RESUME_FENCE] generation=\(generation) action=released nonce=\(nonce)")
                }
            }

        case .videoFeedback:
            return

        case .audio:
            guard committedTransportGeneration == generation else { return }
            switch ScstAudioPolicy.classify(
                mode: committedRealtimeMode,
                flags: header.flags,
                payloadLength: payload.count
            ) {
            case .opus:
                let audioSequence = UInt16(truncatingIfNeeded: header.sequence)
                let audioTimestamp = header.sequence &* 480
                AudioManager.shared.playOpusData(
                    payload,
                    sequence: audioSequence,
                    timestamp: audioTimestamp,
                    generation: generation)
            case .legacyPCM:
                if activeTransportKind == .usb,
                   isForegroundActive,
                   usbLegacyPcmFreshFenceGeneration == generation {
                    AudioManager.shared.recordLegacyResumeFenceDrop(generation: generation)
                    return
                }
                AudioManager.shared.playPCMData(payload, generation: generation)
            case .reject:
                return
            }

        case .bitrate:
            guard committedTransportGeneration == generation else { return }
            guard payload.count == 8 else {
                handleStreamError("Malformed bitrate payload.")
                return
            }
            let adaptive = payload[0] != 0
            let target = payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            }
            transportTelemetry.recordBitrateMbps(Double(target))
            DispatchQueue.main.async {
                self.isAdaptiveBitrate = adaptive
                self.effectiveBitrateMbps = Double(target)
            }

        case .protocolError:
            let reason = String(data: payload, encoding: .utf8) ?? "Protocol error."
            handleStreamError(reason)

        case .authResult:
            handleStreamError("Unexpected authentication response during streaming.")

        case .transportOffer:
            guard committedTransportGeneration != generation else { return }
            guard var offer = TransportOffer.decode(payload) else {
                handleStreamError("Malformed transport offer.")
                return
            }
            clearPendingTransportOffer(
                invalidateNegotiationTimer: pendingTransportOffer != nil)
            let modeAccepted =
                offer.mode == RealtimeTransportMode.legacyTLS ||
                (offer.mode == RealtimeTransportMode.wifiRTP &&
                 activeTransportKind == .wifi) ||
                (offer.mode == RealtimeTransportMode.usbSplitTLS &&
                 activeTransportKind == .usb)
            var accepted =
                modeAccepted &&
                advertisedClientCapabilities.map {
                    ($0.videoCodecs & offer.videoCodec) != 0 &&
                    RealtimeAudioNegotiationPolicy.isOfferCompatible(
                        mode: offer.mode,
                        audioCodec: offer.audioCodec,
                        advertisedModes: $0.modes,
                        advertisedCodecs: $0.audioCodecs)
                } ?? false
            if accepted && offer.mode == RealtimeTransportMode.wifiRTP {
                accepted = wifiMediaReceiver.configure(
                    offer: offer,
                    generation: generation)
            }
            let status: UInt8 = accepted
                ? TransportReadyStatus.ready
                : TransportReadyStatus.rejected
            if accepted {
                pendingTransportOffer = offer
                if offer.mode == RealtimeTransportMode.wifiRTP {
                    wifiCommitGate.begin(sessionID: offer.sessionID)
                }
                if offer.mode == RealtimeTransportMode.usbSplitTLS {
                    negotiationFallbackToken &+= 1
                    usbSplitCommitGate.begin(sessionID: offer.sessionID)
                    usbLaneServer.start(
                        sessionID: offer.sessionID,
                        secret: offer.usbBindingSecret,
                        connectionGeneration: generation)
                }
            } else {
                offer.zeroSecrets()
            }
            let ready = TransportReady(
                version: 1,
                mode: offer.mode,
                status: status,
                sessionID: offer.sessionID,
                audioCodec: accepted
                    ? offer.audioCodec
                    : AudioCodecCapabilities.none)
            guard let readyPayload = ready.encode() else {
                handleStreamError("Unable to encode transport readiness.")
                return
            }
            sendWireMessage(
                type: .transportReady,
                payload: readyPayload,
                sequence: header.sequence)
            if !accepted &&
                offer.mode == RealtimeTransportMode.wifiRTP {
                commitLegacyTransport(generation: generation)
            }
            if accepted &&
                offer.mode == RealtimeTransportMode.usbSplitTLS {
                scheduleUsbSplitOfferTimeout(
                    generation: generation,
                    sessionID: offer.sessionID)
            }

        case .transportCommit:
            if committedTransportGeneration == generation {
                guard committedRealtimeMode == RealtimeTransportMode.wifiRTP,
                      wifiLegacyFallbackGeneration != generation,
                      let commit = TransportCommit.decode(payload),
                      commit.mode == RealtimeTransportMode.legacyTLS,
                      commit.audioCodec == AudioCodecCapabilities.pcm,
                      commit.sessionID == committedRealtimeSessionID else {
                    handleStreamError(
                        "Invalid committed Wi-Fi fallback transition.")
                    return
                }
                _ = fallbackCommittedWifiToLegacy(generation: generation)
                return
            }
            guard let offer = pendingTransportOffer,
                  let commit = TransportCommit.decode(payload),
                  commit.sessionID == offer.sessionID else {
                handleStreamError("Invalid transport commit.")
                return
            }
            if offer.mode == RealtimeTransportMode.usbSplitTLS {
                committedRealtimeSessionID = offer.sessionID
                let decision = usbSplitCommitGate.resolve(
                    commit,
                    videoLaneBound: usbLaneConnections[.video] != nil,
                    audioLaneBound: usbLaneConnections[.audio] != nil)
                switch decision {
                case .split:
                    if commit.audioCodec == AudioCodecCapabilities.none {
                        usbLaneConnections[.audio]?.cancel()
                        usbLaneConnections.removeValue(forKey: .audio)
                    }
                    usbLaneServer.finalize()
                    clearPendingTransportOffer(abortUsbSplit: false)
                    commitRealtimeTransport(
                        generation: generation,
                        mode: RealtimeTransportMode.usbSplitTLS,
                        audioEnabled:
                            commit.audioCodec ==
                                AudioCodecCapabilities.opus)
                case .legacyFallback:
                    usbLaneServer.abort()
                    usbLaneConnections.values.forEach { $0.cancel() }
                    usbLaneConnections.removeAll()
                    clearPendingTransportOffer(abortUsbSplit: false)
                    commitLegacyTransport(generation: generation)
                case .reject:
                    handleStreamError("Invalid transport commit.")
                }
            } else {
                committedRealtimeSessionID = offer.sessionID
                guard commit.mode == offer.mode,
                      commit.audioCodec == offer.audioCodec else {
                    if offer.mode == RealtimeTransportMode.wifiRTP,
                       commit.mode == RealtimeTransportMode.legacyTLS,
                       commit.audioCodec == AudioCodecCapabilities.pcm,
                       wifiCommitGate.commitLegacyFallback(
                            sessionID: offer.sessionID) {
                        wifiMediaReceiver.clearOffer()
                        clearPendingTransportOffer(abortWifi: false)
                        commitLegacyTransport(generation: generation)
                        return
                    }
                    handleStreamError("Invalid transport commit.")
                    return
                }
                if offer.mode == RealtimeTransportMode.wifiRTP {
                    guard wifiCommitGate.commit(
                        sessionID: offer.sessionID) else {
                        handleStreamError(
                            "Wi-Fi transport commit arrived before probe " +
                            "authentication or after its deadline.")
                        return
                    }
                    wifiMediaReceiver.activate(generation: generation)
                    clearPendingTransportOffer(abortWifi: false)
                } else {
                    clearPendingTransportOffer()
                    if offer.mode == RealtimeTransportMode.legacyTLS {
                        commitLegacyTransport(generation: generation)
                        return
                    }
                }
                commitRealtimeTransport(
                    generation: generation,
                    mode: offer.mode,
                    audioEnabled:
                        offer.audioCodec != AudioCodecCapabilities.none)
            }

        case .remoteFeaturesResult:
            guard remoteInputConnection, remoteFeatures.result(flags: header.flags, payload: payload) else {
                handleStreamError("Invalid remote feature result."); return
            }
            remoteMonitors.begin(session: UUID(), acceptedFeatures: remoteFeatures.accepted)
            remoteMonitorAdmission = nil
            publishRemoteInputOnQueue()
            requestRemoteCatalogueOnQueue()
        case .remoteInputContext:
            guard remoteInputConnection, remoteFeatures.receiveContext(flags: header.flags, payload: payload) else {
                handleStreamError("Invalid remote input context."); return
            }
            publishRemoteInputOnQueue()
        case .remoteMonitorCatalogue:
            guard remoteInputConnection, remoteMonitors.enabled, remoteFeatures.accepted & 7 == 7,
                  header.flags == 0, let catalogue = RemoteMonitorCatalogueCommand.decode(payload) else {
                handleStreamError("Invalid remote monitor catalogue."); return
            }
            remoteMonitors.receiveCatalogue(catalogue, session: remoteMonitors.session)
            publishRemoteMonitorsOnQueue()
        case .remoteMonitorSelectResult:
            guard remoteInputConnection, remoteMonitors.enabled, remoteFeatures.accepted & 7 == 7,
                  header.flags == 0, let result = RemoteMonitorSelectResultCommand.decode(payload) else {
                handleStreamError("Invalid remote monitor selection result."); return
            }
            if remoteMonitors.receiveResult(result, session: remoteMonitors.session) {
                publishRemoteMonitorsOnQueue()
                if remoteMonitors.needsCatalogueRefresh { requestRemoteCatalogueOnQueue() }
            }
        case .remoteMonitorCatalogueRequest, .remoteMonitorSelectRequest:
            handleStreamError("Unexpected client-direction remote monitor command.")
        case .remoteFeaturesRequest, .remoteScanKey, .remotePointer, .remoteInputReset, .remoteCommittedText:
            handleStreamError("Unexpected client-direction remote input.")
        case .remoteCommandResult, .sessionInfo:
            return   // remote host replies; the toolbar does not show them yet
        case .remoteCommand, .sessionInfoRequest:
            handleStreamError("Unexpected client-direction remote command.")
        case .clientCapabilities, .transportReady, .usbLaneBind,
             .usbLaneBindResult, .videoConfigurationAck,
             .displayConfigurationRequest, .clientHello,
             .pairingRequired, .trustedDeviceChallenge,
             .trustedDeviceProof, .settingsGet, .settingsUpdate,
             .forgetDevice:
            handleStreamError("Unexpected client-direction negotiation message.")
        }
    }

    private var activeTransportKind: ActiveTransportKind {
        usbListenerExplicitlyStarted ? .usb : .wifi
    }

    private func isCurrentCommittedUsbStreamingSessionOnQueue(
        generation: UInt64? = nil
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeTransportKind == .usb,
              usbListenerExplicitlyStarted,
              transportState == .streaming,
              let usbConnection = usbScdpConnection,
              connection === usbConnection,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration else {
            return false
        }
        if let generation {
            return generation == connectionGeneration
        }
        return true
    }

    private func isCurrentCommittedWifiRtpStreamingSessionOnQueue(
        generation: UInt64? = nil
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeTransportKind == .wifi,
              !usbListenerExplicitlyStarted,
              connection != nil,
              transportState == .streaming,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration,
              committedRealtimeMode == RealtimeTransportMode.wifiRTP else {
            return false
        }
        if let generation {
            return generation == connectionGeneration
        }
        return true
    }

    private func recordWifiLifecycleDiagnostic(_ details: String) {
        let line = "[IPAD][WIFI_LIFECYCLE] " + details
        print(line)
        recordDiagnosticLine(line)
    }

    private func shouldPreserveTransientWifiControlError(
        _ error: NWError,
        generation: UInt64,
        connection expectedConnection: NWConnection
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        return WifiNetworkErrorPolicy.disposition(for: error) == .transient &&
            (wifiBackgroundDisconnectWorkItem != nil ||
                wifiLifecycleTransitionGeneration == generation) &&
            connection === expectedConnection &&
            isCurrentCommittedWifiRtpStreamingSessionOnQueue(
                generation: generation)
    }

    private func isWifiConnectionReadyOnQueue(
        _ expectedConnection: NWConnection,
        generation: UInt64
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard connection === expectedConnection,
              generation == connectionGeneration else { return false }
        let actualReady: Bool
        if case .ready = expectedConnection.state {
            actualReady = true
        } else {
            actualReady = false
        }
        let waitingOwned = wifiWaitingOwner?.owns(
            expectedConnection, generation: generation) == true
        #if targetEnvironment(simulator)
        return WifiConnectionReadinessPolicy.isReady(
            actualReady: actualReady,
            waitingOwned: waitingOwned,
            simulatedReady: testingSimulatedWifiSession)
        #else
        return WifiConnectionReadinessPolicy.isReady(
            actualReady: actualReady,
            waitingOwned: waitingOwned)
        #endif
    }

    private func resumeCommittedWireReceiveLoopIfNeeded(
        connection expectedConnection: NWConnection,
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard wifiWaitingOwner?.owns(
                  expectedConnection, generation: generation) != true,
              connection === expectedConnection,
              isCurrentCommittedWifiRtpStreamingSessionOnQueue(
                generation: generation),
              wireReceiveActiveGeneration != generation else { return }
        wireReceiveActiveGeneration = generation
        #if targetEnvironment(simulator)
        if testingSimulatedWifiSession { return }
        #endif
        receiveWireChunk(generation: generation)
    }

    @discardableResult
    private func resumeCommittedWifiSessionOnQueue(
        connection expectedConnection: NWConnection,
        generation: UInt64
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard isForegroundActive,
              connection === expectedConnection,
              isWifiConnectionReadyOnQueue(
                  expectedConnection, generation: generation),
              isCurrentCommittedWifiRtpStreamingSessionOnQueue(
                generation: generation) else { return false }
        wifiBackgroundDisconnectWorkItem?.cancel()
        wifiBackgroundDisconnectWorkItem = nil
        resumeCommittedWireReceiveLoopIfNeeded(
            connection: expectedConnection, generation: generation)
        if wifiMediaReceiver.isPreservedSessionRecoveryPending(
            generation: generation) {
            sendClientPingIfDue()
            recordWifiLifecycleDiagnostic(
                "generation=\(generation) event=ready " +
                "action=coalesce_existing_recovery client_hello_sent=false")
            return true
        }
        let begin = "[WIFI_MEDIA_RECOVERY] generation=\(generation) " +
            "action=decoder_invalidate_begin"
        print(begin)
        recordDiagnosticLine(begin)
        decoder.invalidate(waitForCompletion: false)
        guard connection === expectedConnection,
              isCurrentCommittedWifiRtpStreamingSessionOnQueue(
                generation: generation) else {
            let stale = "[WIFI_MEDIA_RECOVERY] scheduled_generation=\(generation) " +
                "current_generation=\(connectionGeneration) action=skip_stale"
            print(stale)
            recordDiagnosticLine(stale)
            return false
        }
        beginOwnedDecoderSession(networkGeneration: generation)
        wifiMediaReceiver.reanchorForPreservedSessionRecovery(generation: generation)
        AudioManager.shared.resumeCurrentRealtimeSession(generation: generation, profile: .wifi)
        sendClientPingIfDue()
        let complete = "[WIFI_MEDIA_RECOVERY] generation=\(generation) " +
            "action=decoder_rearmed recovery_requested=true"
        print(complete)
        recordDiagnosticLine(complete)
        recordWifiLifecycleDiagnostic(
            "generation=\(generation) event=ready " +
            "action=resume_committed_same_session client_hello_sent=false")
        return true
    }

    private func consumeUsbForegroundDecoderRearmIfEligibleOnQueue()
        -> UInt64? {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard let scheduledGeneration = pendingUsbForegroundDecoderRearmGeneration
        else { return nil }
        pendingUsbForegroundDecoderRearmGeneration = nil
        guard isCurrentCommittedUsbStreamingSessionOnQueue(
            generation: scheduledGeneration) else {
            recordUsbLifecycleDiagnostic(
                "[USB_MEDIA_RECOVERY] scheduled_generation=\(scheduledGeneration) " +
                "current_generation=\(connectionGeneration) action=skip_stale")
            return nil
        }
        return scheduledGeneration
    }

    private var activeControlConnection: NWConnection? {
        activeTransportKind == .usb ? usbScdpConnection : connection
    }

    private func sendClientCapabilities(for kind: ActiveTransportKind) {
        if case .usb = kind {
            publishClientCapabilities(
                modes: RealtimeTransportMode.legacyTLS,
                udpPort: 0)
            return
        }
        let baseModes = RealtimeTransportMode.legacyTLS
        wifiMediaReceiver.start(
            generation: connectionGeneration
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let port):
                self.publishClientCapabilities(
                    modes: baseModes | RealtimeTransportMode.wifiRTP,
                    udpPort: port)
            case .failure:
                self.publishClientCapabilities(modes: baseModes, udpPort: 0)
            }
        }
    }

    private func publishClientCapabilities(modes: UInt8, udpPort: UInt16) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let capabilities = ClientCapabilities(
            version: 2,
            modes: modes,
            videoCodecs: VideoCodecCapabilities.hevc | VideoCodecCapabilities.h264,
            audioCodecs:
                RealtimeAudioNegotiationPolicy.advertisedCodecs(
                    modes: modes),
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: udpPort)
        advertisedClientCapabilities = capabilities
        sendWireMessage(
            type: .clientCapabilities,
            payload: capabilities.encode(),
            sequence: 0)
        scheduleLegacyFallback(generation: connectionGeneration)
    }

    private func receiveDisplayCapabilities(_ capabilities: DisplayCapabilities) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        activeDisplayCapabilities = capabilities
        let reconciledPreference = activeDisplayPreference.reconciled(
            with: capabilities)
        DispatchQueue.main.async { [weak self] in
            self?.displayCapabilities = capabilities
            self?.displayConfigurationFailureMessage = nil
        }
        guard let orientation = observedInterfaceOrientation else { return }
        sendDesiredPipelineMode(reason: "initial_display_configuration")
        requestDisplayConfiguration(
            preference: reconciledPreference,
            interfaceOrientation: orientation)
    }

    private func sendDesiredPipelineMode(reason: String) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard wireAuthenticatedGeneration == connectionGeneration else { return }
        if captureTargets.pending != nil || captureTargets.applied != nil { abandonCaptureTargetPresentationOnQueue() }
        committedPipelineMode.request(desiredPipelineMode)
        sendWireMessage(
            type: .pipelineMode,
            payload: desiredPipelineMode.encode(),
            sequence: 0)
        recordDiagnosticLine(
            "[IPAD][PIPELINE_MODE] mode=\(desiredPipelineMode) reason=\(reason)")
    }

    private func requestDisplayConfiguration(
        preference: DisplayPreference,
        interfaceOrientation: ClientDisplayOrientation
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard wireAuthenticatedGeneration == connectionGeneration,
              let capabilities = activeDisplayCapabilities else {
            return
        }

        let reconciledPreference = preference.reconciled(with: capabilities)
        latestDisplayPreference = reconciledPreference
        let proposed = reconciledPreference.makeRequest(
            interfaceOrientation: interfaceOrientation,
            requestId: 0)
        guard let request = displayRequestGate.begin(proposed) else { return }
        if captureTargets.pending != nil || captureTargets.applied != nil { abandonCaptureTargetPresentationOnQueue() }
        if activeTransportKind == .usb {
            recordUsbLifecycleDiagnostic(
                "[USB_RECONNECT_DISPLAY] generation=\(connectionGeneration) desiredOrientation=\(request.orientation)")
        }
        pendingDisplayPreference = reconciledPreference
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayConfigurationPending = true
            self?.displayConfigurationFailureMessage = nil
        }
        sendWireMessage(
            type: .displayConfigurationRequest,
            payload: request.encode(),
            sequence: request.requestId)
    }

    private func receiveDisplayReady(_ ready: DisplayReady) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard displayRequestGate.pending?.requestId == ready.requestId else {
            return
        }
        if captureTargetOwnsPresentation { abandonCaptureTargetPresentationOnQueue() }
        let nextRequest = displayRequestGate.accept(ready)
        if let nextRequest,
           let latestPreference = latestDisplayPreference {
            pendingDisplayPreference = latestPreference
            sendWireMessage(
                type: .displayConfigurationRequest,
                payload: nextRequest.encode(),
                sequence: nextRequest.requestId)
            return
        }
        guard displayRequestGate.effective != nil,
              let appliedPreference = pendingDisplayPreference else {
            return
        }
        decoder.configureRefreshRate(ready.refreshHz)
        pendingDisplayPreference = nil
        latestDisplayPreference = nil
        activeDisplayPreference = appliedPreference
        DisplayPreferenceStore.save(appliedPreference)
        DispatchQueue.main.async { [weak self] in
            self?.displayPreference = appliedPreference
            self?.effectiveDisplayState = ready
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage = nil
        }
    }

    private func receiveDisplayConfigurationFailure(
        _ failure: DisplayConfigurationFailed
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard displayRequestGate.pending?.requestId == failure.requestId else {
            return
        }
        let nextRequest = displayRequestGate.reject(failure)
        if let nextRequest,
           let latestPreference = latestDisplayPreference {
            pendingDisplayPreference = latestPreference
            sendWireMessage(
                type: .displayConfigurationRequest,
                payload: nextRequest.encode(),
                sequence: nextRequest.requestId)
            return
        }
        guard displayRequestGate.pending == nil else { return }
        pendingDisplayPreference = nil
        latestDisplayPreference = nil
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage =
                "Could not apply this display mode."
        }
    }

    private func resetDisplaySession() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        committedPipelineMode.reset()
        orientationDebounceWorkItem?.cancel()
        orientationDebounceWorkItem = nil
        activeDisplayCapabilities = nil
        pendingDisplayPreference = nil
        latestDisplayPreference = nil
        displayRequestGate.reset()
        DispatchQueue.main.async { [weak self] in
            self?.displayCapabilities = nil
            self?.effectiveDisplayState = nil
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage = nil
        }
    }

    private func commitLegacyTransport(generation: UInt64) {
        wifiCommitGate.abort()
        wifiMediaReceiver.cancel()
        commitRealtimeTransport(
            generation: generation,
            mode: RealtimeTransportMode.legacyTLS)
    }

    private func commitRealtimeTransport(generation: UInt64, mode: UInt8) {
        commitRealtimeTransport(
            generation: generation,
            mode: mode,
            audioEnabled: true)
    }

    private func commitRealtimeTransport(
        generation: UInt64,
        mode: UInt8,
        audioEnabled: Bool
    ) {
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration != generation else { return }
        committedTransportGeneration = generation
        committedRealtimeMode = mode
        beginDataTransfer(generation: generation)
        committedTransportAudioAvailable = audioEnabled
        wifiLegacyFallbackGeneration = nil
        wifiLegacyFallbackRequestGeneration = nil
        beginOwnedDecoderSession(networkGeneration: generation)
        reconcileRealtimeAudioPlayback(
            generation: generation,
            mode: mode,
            audioEnabled: audioEnabled)
        setState(.streaming)
        startVideoReceiveLoop(generation: generation)
        if activeTransportKind == .usb {
            requestCurrentUsbSettingsIfNeeded(generation: generation)
            recordUsbLifecycleDiagnostic(
                "[USB_RECOVERY_CANDIDATE] attempt=\(generation) generation=\(generation) state=committed")
            recordUsbLifecycleDiagnostic("[USB_SESSION_COMMIT] generation=\(generation)")
            challengeUsbCandidateIfCommitted()
        }
    }

    private func clearPendingTransportOffer(
        abortUsbSplit: Bool = true,
        abortWifi: Bool = true,
        invalidateNegotiationTimer: Bool = true
    ) {
        if invalidateNegotiationTimer {
            negotiationFallbackToken &+= 1
        }
        if abortUsbSplit,
           let offer = pendingTransportOffer,
           offer.mode == RealtimeTransportMode.usbSplitTLS {
            _ = usbSplitCommitGate.abort(sessionID: offer.sessionID)
            usbLaneServer.abort()
            usbLaneConnections.values.forEach { $0.cancel() }
            usbLaneConnections.removeAll()
        }
        if abortWifi,
           let offer = pendingTransportOffer,
           offer.mode == RealtimeTransportMode.wifiRTP {
            wifiCommitGate.abort()
            wifiMediaReceiver.clearOffer()
        }
        pendingTransportOffer?.zeroSecrets()
        pendingTransportOffer = nil
    }

    private func scheduleUsbSplitOfferTimeout(
        generation: UInt64,
        sessionID: SessionID
    ) {
        negotiationFallbackToken &+= 1
        let token = negotiationFallbackToken
        networkQueue.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.negotiationFallbackToken == token,
                  self.usbSplitCommitGate.abort(
                    sessionID: sessionID) else { return }
            self.usbLaneServer.abort()
            self.usbLaneConnections.values.forEach { $0.cancel() }
            self.usbLaneConnections.removeAll()
            self.clearPendingTransportOffer(abortUsbSplit: false)
            self.commitLegacyTransport(generation: generation)
        }
    }

    private func scheduleLegacyFallback(generation: UInt64) {
        negotiationFallbackToken &+= 1
        let token = negotiationFallbackToken
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(750)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.negotiationFallbackToken == token,
                  self.wifiCommitGate.legacyFallbackAllowed else { return }
            self.clearPendingTransportOffer()
            self.commitLegacyTransport(generation: generation)
        }
    }

    private func handleWifiProbeAuthenticated(
        generation: UInt64,
        sessionID: SessionID
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration != generation,
              let offer = pendingTransportOffer,
              offer.mode == RealtimeTransportMode.wifiRTP,
              offer.sessionID == sessionID,
              let deadlineToken =
                wifiCommitGate.acceptProbe(sessionID: sessionID) else { return }

        // The authenticated UDP path is authoritative. The initial legacy
        // fallback must never race a host that is about to commit Wi-Fi.
        negotiationFallbackToken &+= 1
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(
                WifiTransportTiming.clientPostProbeCommitTimeoutMs)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.wifiCommitGate.timeout(
                    sessionID: sessionID,
                    token: deadlineToken) else { return }
            let fallback = TransportReady(
                version: 1,
                mode: RealtimeTransportMode.legacyTLS,
                status: TransportReadyStatus.ready,
                sessionID: sessionID,
                audioCodec: AudioCodecCapabilities.pcm)
            guard let payload = fallback.encode(),
                  let fallbackToken = self.wifiCommitGate.fallbackToken
            else {
                self.handleStreamError(
                    "Unable to request Wi-Fi legacy fallback.")
                return
            }
            self.sendWireMessage(
                type: .transportReady,
                payload: payload,
                sequence: 0)
            self.networkQueue.asyncAfter(
                deadline: .now() + .milliseconds(
                    WifiTransportTiming.clientFallbackCommitTimeoutMs)
            ) { [weak self] in
                guard let self,
                      generation == self.connectionGeneration,
                      self.wireAuthenticatedGeneration == generation,
                      self.committedTransportGeneration != generation,
                      self.wifiCommitGate.fallbackTimeout(
                        sessionID: sessionID,
                        token: fallbackToken) else { return }
                self.handleStreamError(
                    "Wi-Fi legacy fallback commit timed out.")
            }
        }
    }

    private func handleWifiCommittedFailure(
        generation: UInt64,
        error: Error
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: generation,
            connectionGeneration: connectionGeneration,
            committedGeneration: committedTransportGeneration) else { return }
        guard committedRealtimeMode == RealtimeTransportMode.wifiRTP,
              wifiLegacyFallbackRequestGeneration != generation,
              let sessionID = committedRealtimeSessionID,
              connection != nil else {
            if wifiLegacyFallbackRequestGeneration == generation {
                return
            }
            handleStreamError(
                "Wi-Fi media transport failed: \(error.localizedDescription)")
            return
        }
        wifiLegacyFallbackRequestGeneration = generation
        wifiMediaReceiver.clearOffer()
        AudioManager.shared.reset()
        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        guard let payload = ready.encode() else {
            handleStreamError("Unable to encode Wi-Fi fallback request.")
            return
        }
        sendWireMessage(
            type: .transportReady,
            payload: payload,
            sequence: 0)
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(
                WifiTransportTiming.clientPostProbeCommitTimeoutMs)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wifiLegacyFallbackRequestGeneration == generation,
                  self.committedRealtimeMode ==
                    RealtimeTransportMode.wifiRTP else { return }
            self.handleStreamError(
                "Wi-Fi fallback commit timed out after media failure.")
        }
    }

    @discardableResult
    func fallbackCommittedWifiToLegacy(
        generation: UInt64
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation,
              committedRealtimeMode == RealtimeTransportMode.wifiRTP,
              wifiLegacyFallbackGeneration != generation,
              let expectedConnection = connection else {
            return false
        }
        wifiLegacyFallbackGeneration = generation
        wifiLegacyFallbackRequestGeneration = nil
        mirrorControl.retireTransportPresentation()
        mirrorTerminalSend=nil
        publishMirrorStateOnQueue()
        committedRealtimeMode = RealtimeTransportMode.legacyTLS
        committedTransportAudioAvailable = true
        wifiMediaReceiver.clearOffer()
        decoder.invalidate(waitForCompletion: true)
        guard connection === expectedConnection,
              generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation,
              committedRealtimeMode == RealtimeTransportMode.legacyTLS,
              wifiLegacyFallbackGeneration == generation else { return false }
        beginOwnedDecoderSession(networkGeneration: generation)
        videoPayloadCounter.begin(generation: generation)
        videoRxSampler.reset()
        lastHudSnapshotPublishedAt = 0
        startLegacyTelemetryTimers()
        AudioManager.shared.reset()
        reconcileRealtimeAudioPlayback(
            generation: generation, mode: RealtimeTransportMode.legacyTLS,
            audioEnabled: clientSettingsState.effective.audioEnabled)
        return true
    }

    // Removed: inactive four-byte video framing and recursive Data
    // accumulation. The SCST loop above is the sole receive path.

    // MARK: - Private: Stream Error Helper

    private func handleStreamError(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if usbListenerExplicitlyStarted {
            guard let current = usbScdpConnection else { return }
            teardownUsbSession(
                connection: current, generation: connectionGeneration,
                reason: reason)
            return
        }
        teardownCurrentSession()
        print("[NetworkManager] ⚠️ \(reason)")
        setState(.disconnected(reason: reason))
        scheduleAutoReconnect(reset: false)
    }

    private func teardownUsbSession(
        connection: NWConnection,
        generation: UInt64,
        reason: String
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard usbListenerExplicitlyStarted,
              generation == connectionGeneration,
              usbScdpConnection === connection,
              self.connection === connection else { return }
        let listenerStillReady: Bool
        if let listener = usbListener, case .ready = listener.state {
            listenerStillReady = true
        } else {
            listenerStillReady = false
        }
        recordUsbLifecycleDiagnostic(
            "[USB_SESSION_LOST] generation=\(generation) connectionId=\(ObjectIdentifier(connection)) listenerStillReady=\(listenerStillReady) reason=\(reason)")
        recordUsbLifecycleDiagnostic(
            "[USB_RECOVERY_CANDIDATE] attempt=\(generation) generation=\(generation) state=failed")
        let replacement: PendingUsbCandidate?
        if let pending = pendingUsbCandidate, ownsUsbCandidate(pending) {
            replacement = takeUsbCandidate()
        } else {
            replacement = nil
        }
        teardownCurrentSession()
        recordUsbLifecycleDiagnostic(
            "[USB_LISTENER_REUSE] oldGeneration=\(generation) acceptingNext=\(listenerStillReady)")
        recordUsbLifecycleDiagnostic(
            "[USB_RECOVERY_CANDIDATE] attempt=\(generation) generation=\(generation) state=retired")
        setState(.listening)
        if let replacement, usbListenerExplicitlyStarted,
           listenerGeneration == replacement.listenerGeneration, usbListener != nil {
            recordUsbLifecycleDiagnostic("[USB_CANDIDATE_ARBITRATION] arbitration=\(replacement.id) action=promote_candidate reason=\(reason)")
            installUsbCandidate(replacement.candidate)
        } else {
            replacement?.candidate.cancel()
        }
    }

    private func teardownCurrentSession() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        resetRemoteInputOnQueue()
        remoteInputConnection = false
        cancelUsbCandidateArbitration(reason: "session_teardown")
        cancelLegacyUsbPcmFreshFence()
        legacyUsbPlaybackEnabledGeneration = nil
        pendingClientPings.removeAll(keepingCapacity: true)
        wifiBackgroundDisconnectWorkItem?.cancel()
        wifiBackgroundDisconnectWorkItem = nil
        wifiLifecycleTransitionGeneration = nil
        wifiWaitingOwner = nil
        pendingUsbForegroundDecoderRearmGeneration = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        let failedGeneration = connectionGenerationClock.advance()
        resetAutoAcceptOnQueue()
        advanceReceivedRevisionOnQueue()
        resetDirectTouchSessionOnQueue()
        wireReceiveActiveGeneration = nil
        wireReceiveOutstanding = nil
        transferReceiveSuffix = nil
        wireAuthenticatedGeneration = nil
        committedTransportGeneration = nil
        committedRealtimeMode = nil
        committedTransportAudioAvailable = false
        committedRealtimeSessionID = nil
        wifiLegacyFallbackGeneration = nil
        wifiLegacyFallbackRequestGeneration = nil
        advertisedClientCapabilities = nil
        resetDisplaySession()
        clearPendingTransportOffer()
        wireParser.reset(generation: failedGeneration)
        dataTransfers?.retire(); dataTransfers = nil; transferReceivePending = 0
        decoder.invalidate(waitForCompletion: !usbListenerExplicitlyStarted)
        AudioManager.shared.reset()
        connection?.cancel()
        connection = nil
        // The socket is retired; late completion IDs must not gate its successor.
        controlChannelWriter.abandonConnection()
        usbScdpConnection = nil
        usbLaneServer.abort()
        usbLaneConnections.values.forEach { $0.cancel() }
        usbLaneConnections.removeAll()
        wifiMediaReceiver.cancel()
        stopTelemetryTimer()
    }

    private func reconcileRealtimeAudioPlayback(
        generation: UInt64,
        mode: UInt8,
        audioEnabled: Bool
    ) {
        guard generation == connectionGeneration,
              committedTransportGeneration == generation,
              committedRealtimeMode == mode else { return }
        let playbackEnabled = audioEnabled && clientSettingsState.desired.audioEnabled &&
            committedTransportAudioAvailable
        if activeTransportKind == .usb, mode == RealtimeTransportMode.legacyTLS {
            if !playbackEnabled {
                cancelLegacyUsbPcmFreshFence()
                legacyUsbPlaybackEnabledGeneration = nil
            } else if legacyUsbPlaybackEnabledGeneration != generation {
                legacyUsbPlaybackEnabledGeneration = generation
                AudioManager.shared.beginLegacySession(generation: generation)
                armLegacyUsbPcmFreshFence(generation: generation)
            }
        }
        if mode == RealtimeTransportMode.legacyTLS, playbackEnabled,
           activeTransportKind != .usb {
            AudioManager.shared.beginLegacySession(generation: generation)
        }
        guard RealtimeAudioTimerPolicy.shouldRun(
            mode: mode,
            audioEnabled: playbackEnabled) else {
            if !playbackEnabled {
                #if targetEnvironment(simulator)
                if let realtimeAudioPlaybackForTesting {
                    realtimeAudioPlaybackForTesting(false)
                    return
                }
                #endif
                AudioManager.shared.reset()
            }
            return
        }
        #if targetEnvironment(simulator)
        if let realtimeAudioPlaybackForTesting {
            realtimeAudioPlaybackForTesting(true)
            return
        }
        #endif
        AudioManager.shared.beginRealtimeSession(
            generation: generation,
            profile: mode == RealtimeTransportMode.wifiRTP ? .wifi : .usb)
    }

    // MARK: - Private: Thread-Safe State Transition

    private func recordUsbLifecycleDiagnostic(_ line: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let timed = "\(line) uptime=\(uptime) uptime_ms=\(Int64(uptime * 1000))"
        // The listener also exists between telemetry files; keep these sparse
        // events visible in the device console throughout that interval.
        print(timed)
        recordDiagnosticLine(timed)
    }

    private func recordAppAudioLifecycleDiagnostic(event: String, phase: String, foregroundBefore: Bool) {
        recordUsbLifecycleDiagnostic("[APP_AUDIO_LIFECYCLE] event=\(event) phase=\(phase) isForegroundActive_before=\(foregroundBefore ? 1 : 0) isForegroundActive_after=\(isForegroundActive ? 1 : 0) connectionGeneration=\(connectionGeneration) committedTransportGeneration=\(committedTransportGeneration.map { String($0) } ?? "none") wireAuthenticatedGeneration=\(wireAuthenticatedGeneration.map { String($0) } ?? "none") activeTransportKind=\(activeTransportKind == .usb ? "usb" : "wifi") committedRealtimeMode=\(committedRealtimeMode.map { String($0) } ?? "none") legacyUsbPlaybackEnabledGeneration=\(legacyUsbPlaybackEnabledGeneration.map { String($0) } ?? "none") usbLegacyPcmFreshFenceGeneration=\(usbLegacyPcmFreshFenceGeneration.map { String($0) } ?? "none") usbLegacyPcmFreshFenceNonce_present=\(usbLegacyPcmFreshFenceNonce != nil ? 1 : 0) \(AudioManager.audioSessionDiagnosticFields)")
    }

    #if targetEnvironment(simulator)
    // Captures the real pending-switch completion without wall-clock sleeps in XCTest.
    var mirrorSwitchDeadlineForTesting: ((TimeInterval, @escaping () -> Void) -> Void)?
    var captureTargetDecoderForTesting: UInt64? { currentCaptureTargetDecoderOwner?.decoder }
    func receiveCaptureTargetWireForTesting(type: WireMessageType, payload: Data, flags: UInt16 = 0,
                                            sequence: UInt32 = 0, generation: UInt64, connection owner: NWConnection) {
        networkQueue.sync {
            guard generation == connectionGeneration, activeControlConnection === owner,
                  wireAuthenticatedGeneration == generation, committedTransportGeneration == generation else { return }
            handleWireMessage(WireMessage(header: WireHeader(type: type, flags: flags,
                payloadLength: payload.count, sequence: sequence), payload: payload, firstByteAt: CACurrentMediaTime()),
                generation: generation)
        }
    }
    func receiveCaptureTargetVideoForTesting(_ data: Data, sequence: UInt32, isIDR: Bool,
                                             generation: UInt64, connection owner: NWConnection) {
        networkQueue.sync {
            guard generation == connectionGeneration, activeControlConnection === owner,
                  wireAuthenticatedGeneration == generation, committedTransportGeneration == generation,
                  committedRealtimeMode == RealtimeTransportMode.wifiRTP else { return }
            _=consumeCaptureTargetVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                                               lengthPrefixed: true, receivedAt: CACurrentMediaTime())
        }
    }
    func receiveRemoteMonitorContextForTesting(_ context: RemoteInputContextCommand, keyframe: Bool) {
        networkQueue.sync {
            guard let payload = context.encode() else { return }
            handleWireMessage(WireMessage(header: WireHeader(type: .remoteInputContext, flags: 0,
                payloadLength: payload.count, sequence: 0), payload: payload, firstByteAt: 0), generation: connectionGeneration)
            if keyframe { remoteFeatures.keyframeArrived(); publishRemoteInputOnQueue(contextChanged: false) }
        }
    }
    func bypassRemoteMonitorAdmissionForTesting(target: UInt64, catalogue: RemoteMonitorCatalogueCommand) {
        networkQueue.async {
            guard let request = self.remoteMonitors.select(targetId: target, catalogue: catalogue,
                session: self.remoteMonitors.session, inputReady: true, controlEnabled: true), let payload = request.encode() else { return }
            self.sendWireMessage(type: .remoteMonitorSelectRequest, payload: payload, sequence: 0)
        }
    }
    func beginRemoteMonitorForTesting(acceptedFeatures: UInt64) {
        networkQueue.sync {
            remoteInputConnection = true
            resetRemoteInputOnQueue()
            _ = remoteFeatures.begin(now: 0)
            _ = remoteFeatures.pong(flags: 0x4000, now: 1)
            let payload = RemoteFeaturesMessage(features: acceptedFeatures).encode()
            handleWireMessage(WireMessage(header: WireHeader(type: .remoteFeaturesResult, flags: 0,
                payloadLength: payload.count, sequence: 0), payload: payload, firstByteAt: 0), generation: connectionGeneration)
        }
    }
    func beginMirrorControlForTesting(generation:UInt64, monitorSelection:Bool=false, terminal:Bool=false) {
        mirrorControl.beginSession(generation)
        _=mirrorControl.helloIfAdvertised(session:generation,flags:terminal ? 0x7000:(monitorSelection ? 0x6000:0x4000))
        mirrorSwitchAdvertised=monitorSelection
    }
    var mirrorDecoderGenerationForTesting:UInt64? {currentMirrorDecoderOwner?.decoder}
    func receiveMirrorWireForTesting(type:WireMessageType,payload:Data,generation:UInt64,connection owner:NWConnection) {
        networkQueue.sync {
            guard generation==connectionGeneration,connection===owner,wireAuthenticatedGeneration==generation else {return}
            handleWireMessage(WireMessage(header:WireHeader(type:type,flags:0,payloadLength:payload.count,sequence:0),
                payload:payload,firstByteAt:ProcessInfo.processInfo.systemUptime),generation:generation)
        }
    }
    func transferObserverForTesting() -> (DataTransferManager, (DataTransferManager.Snapshot) -> Void) {
        networkQueue.sync {
            beginDataTransfer(generation: connectionGeneration)
            return (dataTransfers!, dataTransfers!.changed!)
        }
    }
    var receivedRevisionForTesting: UInt64 { receivedActionClock.current }
    // Deterministic admission/receive boundary only; absent from device builds.
    var transferReceiveForTesting: ((Int, @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) -> Void)?
    var transferPostForTesting: ((TransferPacket, @escaping () -> Void) -> Bool)?
    func startTransferReceiveForTesting(manager: DataTransferManager?, authenticated: Bool = true) {
        networkQueue.sync {
            dataTransfers = manager
            transferReceivePending = 0
            transferReceiveSuffix = nil
            wireReceiveOutstanding = nil
            wireParser.reset(generation: connectionGeneration)
            wireAuthenticatedGeneration = authenticated ? connectionGeneration : nil
            receiveWireChunk(generation: connectionGeneration)
        }
    }
    // Simulator-only authorization fixture. Uses the real session/manager boundary.
    func configureTransferAuthorizationForTesting(manager: DataTransferManager?, authenticated: Bool,
                                                   committed: Bool, usb: Bool = false) {
        networkQueue.sync {
            dataTransfers = manager
            usbListenerExplicitlyStarted = usb
            wireAuthenticatedGeneration = authenticated ? connectionGeneration : nil
            committedTransportGeneration = committed ? connectionGeneration : nil
            refreshAutoAcceptPolicyOnQueue()
        }
    }
    var transferPendingForTesting: Int { networkQueue.sync { transferReceivePending } }
    func beginTransferWriterForTesting() {
        networkQueue.sync { controlChannelWriter.begin(generation: connectionGeneration) }
    }
    func enqueueTransferWireForTesting(bulk: Bool, completion: @escaping (NWError?) -> Void) {
        networkQueue.async {
            self.sendWireMessage(type: bulk ? .transferEnd : .ping, payload: Data(count: bulk ? 25 : 16), sequence: 0, bulk: bulk, completion: completion)
        }
    }

    var realtimeAudioPlaybackForTesting: ((Bool) -> Void)?
    var controlSendForAudioTesting: ((Data, @escaping (NWError?) -> Void) -> Void)?

    func isLegacyPcmFreshFencePingForTesting(_ data: Data) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard data.count == WireProtocol.headerSize + 16,
              data[5] == WireMessageType.ping.rawValue else { return false }
        let nonce = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: WireProtocol.headerSize + 8, as: UInt64.self).littleEndian
        }
        return usbLegacyPcmFreshFenceNonce == nonce
    }

    func receiveUsbWireForTesting(type: WireMessageType, payload: Data,
                                  generation: UInt64, connection owner: NWConnection) {
        networkQueue.sync {
            guard generation == connectionGeneration, connection === owner,
                  usbScdpConnection === owner else { return }
            handleWireMessage(WireMessage(header: WireHeader(type: type, flags: 0,
                payloadLength: payload.count, sequence: 0), payload: payload,
                firstByteAt: ProcessInfo.processInfo.systemUptime), generation: generation)
        }
    }

    var usbCandidateArbitrationForTesting: (id: UInt64, candidate: NWConnection, generation: UInt64, nonce: UInt64?, deadline: TimeInterval)? {
        networkQueue.sync {
            pendingUsbCandidate.map { ($0.id, $0.candidate, $0.incumbentGeneration, $0.livenessNonce, $0.deadline) }
        }
    }

    func expireUsbCandidateForTesting(id: UInt64) {
        networkQueue.sync { expireUsbCandidate(id: id) }
    }

    private var testingPerformanceFeedbackNow: TimeInterval?
    func seedPerformanceWindowForTesting(mode: PipelineMode = .office, at now: TimeInterval) {
        networkQueue.sync {
            testingPerformanceFeedbackNow = now
            desiredPipelineMode = mode
            committedPipelineMode.request(mode)
            _ = committedPipelineMode.acknowledge(mode, at: now - 3)
            transportTelemetry.beginFreshFrameRate(generation: connectionGeneration, at: now - 1.1)
        }
    }
    func advancePerformanceFeedbackClockForTesting(to now: TimeInterval) {
        networkQueue.sync { testingPerformanceFeedbackNow = now }
    }
    func sendPerformanceFeedbackForTesting() -> UInt32 {
        networkQueue.sync { sendPerformanceFeedback(); return performanceFeedbackSequence }
    }
    func performanceSampleForTesting(at now: TimeInterval) -> ClientFreshFrameRateSample? {
        networkQueue.sync {
            transportTelemetry.freshFrameRateSample(generation: connectionGeneration, at: now)
        }
    }

    func installUsbLaneForParserTesting(_ lane: UsbLaneKind, connection: NWConnection) {
        networkQueue.sync {
            usbLaneConnections[lane]?.cancel()
            usbLaneConnections[lane] = connection
            connection.start(queue: networkQueue)
            startUsbLaneReceiveLoop(connection, lane: lane, generation: connectionGeneration)
        }
    }

    func installUsbAudioLaneForTesting() -> NWConnection {
        networkQueue.sync {
            let lane = NWConnection(host: "127.0.0.1", port: 27015, using: .tcp)
            usbLaneConnections[.audio]?.cancel()
            usbLaneConnections[.audio] = lane
            return lane
        }
    }

    func failUsbAudioLaneForTesting(_ connection: NWConnection, generation: UInt64, reason: String) {
        networkQueue.sync { retireUsbAudioLane(connection, generation: generation, reason: reason) }
    }

    func commitAudioTransportForTesting(mode: UInt8, audioAvailable: Bool) {
        networkQueue.sync {
            wireAuthenticatedGeneration = connectionGeneration
            commitRealtimeTransport(
                generation: connectionGeneration, mode: mode,
                audioEnabled: audioAvailable)
        }
    }

    func reconcileAudioForTesting(generation: UInt64, mode: UInt8, audioEnabled: Bool) {
        networkQueue.sync {
            reconcileRealtimeAudioPlayback(
                generation: generation, mode: mode, audioEnabled: audioEnabled)
        }
    }

    var clientDebugLoggingEnabledForTesting: Bool {
        networkQueue.sync { clientDebugLoggingEnabled }
    }

    // Read-only ownership snapshot for real Network.framework regression tests.
    struct USBSessionSnapshot {
        let listener: NWListener?
        let listenerIntent: Bool
        let connection: NWConnection?
        let generation: UInt64
        let authenticatedGeneration: UInt64?
        let committedGeneration: UInt64?
        let pendingDisplay: DisplayConfigurationRequest?
        let orientation: ClientDisplayOrientation?
    }

    var networkQueueForTesting: DispatchQueue { networkQueue }
    var networkQueueKeyForTesting: DispatchSpecificKey<Bool> { networkQueueKey }
    var decoderForTesting: DecoderManager { decoder }
    var wifiMediaReceiverForTesting: WifiMediaReceiver { wifiMediaReceiver }

    func wifiSessionSnapshotForTesting() -> (
        connection: NWConnection?, generation: UInt64,
        committedGeneration: UInt64?
    ) {
        networkQueue.sync {
            (connection, connectionGeneration, committedTransportGeneration)
        }
    }

    func wifiLifecycleSnapshotForTesting() -> (
        connection: NWConnection?, generation: UInt64,
        authenticatedGeneration: UInt64?, committedGeneration: UInt64?,
        realtimeMode: UInt8?, waitingGeneration: UInt64?,
        inactiveTransitionGeneration: UInt64?,
        graceActive: Bool, receiveActiveGeneration: UInt64?,
        initialReceiveStarts: Int, writerBegins: Int,
        clientHelloCount: Int, pingAttempts: Int
    ) {
        networkQueue.sync {
            (connection, connectionGeneration, wireAuthenticatedGeneration,
             committedTransportGeneration, committedRealtimeMode,
             wifiWaitingOwner?.generation, wifiLifecycleTransitionGeneration,
             wifiBackgroundDisconnectWorkItem != nil,
             wireReceiveActiveGeneration, testingInitialReceiveStarts,
             testingWriterBegins, testingClientHelloCount, testingPingAttempts)
        }
    }

    func simulateWifiControlSendErrorForTesting(
        _ error: NWError = .posix(.ENETDOWN),
        generation: UInt64, connection expectedConnection: NWConnection
    ) {
        networkQueue.sync {
            handleControlSendError(
                error, generation: generation,
                connection: expectedConnection, transport: .wifi)
        }
    }

    func simulateWifiControlReceiveErrorForTesting(
        _ error: NWError = .posix(.ENETDOWN),
        generation: UInt64, connection expectedConnection: NWConnection
    ) {
        networkQueue.sync {
            handleWireReceiveError(
                error, generation: generation,
                connection: expectedConnection)
        }
    }

    func setWifiWaitingOwnerForTesting(
        generation: UInt64, connection expectedConnection: NWConnection
    ) {
        networkQueue.sync {
            wifiWaitingOwner = WifiWaitingOwner(
                generation: generation,
                connectionID: ObjectIdentifier(expectedConnection))
        }
    }

    func isWifiConnectionReadyForTesting(
        connection expectedConnection: NWConnection,
        generation: UInt64
    ) -> Bool {
        networkQueue.sync {
            isWifiConnectionReadyOnQueue(
                expectedConnection, generation: generation)
        }
    }

    func expireWifiBackgroundGraceForTesting() {
        networkQueue.sync {
            wifiBackgroundDisconnectWorkItem?.perform()
        }
    }

    func simulateCommittedWifiSessionForTesting(
        mode: UInt8 = RealtimeTransportMode.wifiRTP
    ) -> (connection: NWConnection, generation: UInt64) {
        networkQueue.sync {
            let peer = NWConnection(host: "127.0.0.1", port: 27015, using: .tcp)
            let generation = connectionGenerationClock.advance()
            resetAutoAcceptOnQueue()
            advanceReceivedRevisionOnQueue()
            resetDirectTouchSessionOnQueue()
            connection?.cancel()
            wifiBackgroundDisconnectWorkItem?.cancel()
            wifiBackgroundDisconnectWorkItem = nil
            wifiLifecycleTransitionGeneration = nil
            wifiWaitingOwner = nil
            connection = peer
            setupStateHandler(for: peer)
            testingSimulatedWifiSession = true
            wireReceiveActiveGeneration = generation
            wireAuthenticatedGeneration = generation
            committedTransportGeneration = generation
            committedRealtimeMode = mode
            committedTransportAudioAvailable = true
            lastClientPingSentAt = .greatestFiniteMagnitude
            beginOwnedDecoderSession(networkGeneration: generation)
            setState(.streaming)
            return (peer, generation)
        }
    }

    func stopForTesting() {
        networkQueue.sync { self.stopOnQueue() }
    }

    func publishHudSnapshotForTesting(_ snapshot: TransportHudSnapshot) {
        networkQueue.sync { publishHudSnapshot(snapshot) }
    }

    func setCommittedRealtimeModeForTesting(_ mode: UInt8?) {
        networkQueue.sync { committedRealtimeMode = mode }
    }

    func enqueueControlForTesting(
        completion: @escaping (NWError?) -> Void
    ) {
        networkQueue.async {
            self.controlChannelWriter.begin(generation: self.connectionGeneration)
            _ = self.controlChannelWriter.enqueue(
                Data([0x01]),
                completion: completion)
        }
    }

    func usbSessionSnapshot() -> USBSessionSnapshot {
        let block = {
            USBSessionSnapshot(
                listener: self.usbListener,
                listenerIntent: self.usbListenerExplicitlyStarted,
                connection: self.usbScdpConnection,
                generation: self.connectionGeneration,
                authenticatedGeneration: self.wireAuthenticatedGeneration,
                committedGeneration: self.committedTransportGeneration,
                pendingDisplay: self.displayRequestGate.pending,
                orientation: self.observedInterfaceOrientation)
        }
        if DispatchQueue.getSpecific(key: networkQueueKey) != nil {
            return block()
        } else {
            return networkQueue.sync(execute: block)
        }
    }

    func simulateSessionAuthenticatedAndCommitted(mode: UInt8 = RealtimeTransportMode.legacyTLS) {
        let block = {
            self.wireAuthenticatedGeneration = self.connectionGeneration
            self.commitRealtimeTransport(generation: self.connectionGeneration, mode: mode)
        }
        if DispatchQueue.getSpecific(key: networkQueueKey) != nil {
            block()
        } else {
            networkQueue.sync(execute: block)
        }
    }
    #endif

    private func setState(_ newState: ConnectionState) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        transportState = newState
        if case .authFailed = newState { resetAutoAcceptOnQueue() }
        if newState == .streaming { publishAutoReconnectAttempt(0) }
        DispatchQueue.main.async {
            self.connectionState = newState
        }
    }

    // MARK: - Published Telemetry

    /// Last-frame header-and-payload receive duration in milliseconds, not RTT.
    /// Updated on main thread — safe for SwiftUI binding via StreamManager.
    @Published public var lastFrameReceiveDurationMs: Double = 0.0

    /// Last-frame VideoToolbox decode latency in milliseconds.
    /// Set by DecoderManager; read by the 2Hz telemetry timer.
    @Published public var lastDecodeLatencyMs: Double = 0.0

    /// The sole SwiftUI-facing transport telemetry publication (2 Hz maximum).
    @Published public private(set) var hudTelemetry = TransportHudSnapshot(
        frameReceiveMs: 0,
        decodeMs: 0)

    private var captureTargetOwnsPresentation: Bool {
        captureTargets.enabled && (captureTargets.pending != nil || captureTargets.applied != nil || captureTargets.inputBlocked)
    }
    private var currentCaptureTargetDecoderOwner: CaptureTargetDecoderOwner? {
        mirrorDecoderLock.lock();defer { mirrorDecoderLock.unlock() };return captureTargetDecoderOwner
    }
    public func legacyInputIsCurrent(revision: UInt64) -> Bool {
        mirrorControl.legacyRegistrationIsCurrent(revision: revision)
    }

    @MainActor public func requestCaptureTarget(_ id: UInt64, catalogue: CaptureTargetCatalogue) {
        let generation=connectionGenerationClock.current
        let admitted: (CaptureTargetRequest, UUID, NWConnection)? = networkQueue.sync {
            let age=ProcessInfo.processInfo.systemUptime-captureTargetCatalogueAt
            guard !remoteInputConnection, generation == connectionGeneration,
                  wireAuthenticatedGeneration == generation, committedTransportGeneration == generation,
                  let connection=activeControlConnection else { return nil }
            guard age >= 0, age < 30 else { refreshCaptureTargetsOnQueue();return nil }
            let session=captureTargets.session
            guard let request=captureTargets.select(id, catalogue: catalogue, session: session) else { return nil }
            cancelCaptureTargetRecoveryOnQueue()
            captureTargetMirrorRevisionAtTap=mirrorControl.currentState?.revision ?? 0
            return (request, session, connection)
        }
        guard let (request, session, connection)=admitted else { return }
        // These existing methods emit terminal releases and retire marked text synchronously on main.
        captureTargetRetireInput?()
        // Drain the retired callbacks' queued encodes before blocking their old tickets.
        networkQueue.sync { mirrorControl.setCaptureTargetInputBlocked(true, session: generation) }
        networkQueue.async { [weak self] in
            guard let self, self.captureTargets.session == session,
                  self.captureTargets.pending?.request == request, self.connectionGeneration == generation,
                  self.activeControlConnection === connection, let payload=try? request.encode() else { return }
            self.sendWireMessage(type: .sourceSwitchRequest, payload: payload, sequence: 0)
            self.publishMirrorStateOnQueue()
            self.scheduleCaptureTargetCallback(CaptureTargetProtocol.terminalWait) { [weak self, weak connection] in
                guard let self, let connection, self.activeControlConnection === connection,
                      self.connectionGeneration == generation,
                      self.captureTargets.expire(transaction: request.transaction, session: session) else { return }
                self.retireCaptureTargetDecoderOnQueue()
                self.refreshCaptureTargetsOnQueue();self.publishMirrorStateOnQueue()
            }
        }
    }
    private func refreshCaptureTargetsOnQueue() {
        guard wireAuthenticatedGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              let payload=captureTargets.refresh(session: captureTargets.session) else { return }
        sendWireMessage(type: .sourceHello, payload: payload, sequence: 0)
        scheduleCaptureTargetListWaitOnQueue()
    }
    private func scheduleCaptureTargetListWaitOnQueue() {
        let session=captureTargets.session
        scheduleCaptureTargetCallback(5) { [weak self] in
            guard let self, self.captureTargets.session == session else { return }
            self.captureTargets.markListUnavailable(session: session);self.publishMirrorStateOnQueue()
        }
    }
    private func scheduleCaptureTargetCallback(_ seconds: TimeInterval, recovery: Bool = false,
                                               completion: @escaping () -> Void) {
        #if targetEnvironment(simulator)
        if let schedule=captureTargetScheduleForTesting { schedule(seconds, completion);return }
        #endif
        let work=DispatchWorkItem(block: completion)
        if recovery { captureTargetRecoveryWork.append(work) }
        networkQueue.asyncAfter(deadline: .now()+seconds, execute: work)
    }
    private func cancelCaptureTargetRecoveryOnQueue() {
        captureTargetRecoveryToken=nil
        captureTargetRecoveryWork.forEach { $0.cancel() };captureTargetRecoveryWork.removeAll()
    }
    private func retireCaptureTargetDecoderOnQueue() {
        cancelCaptureTargetRecoveryOnQueue();captureTargetVideo.reset()
        captureTargetDecodeStarted=false;captureTargetLastVideoSequence=nil
        mirrorDecoderLock.lock();captureTargetDecoderOwner=nil;mirrorDecoderOwner=nil;mirrorDecoderLock.unlock()
        decoder.invalidate(waitForCompletion: false)
        guard nextMirrorDecoder != UInt64.max else { handleStreamError("Source decoder identity exhausted.");return }
        nextMirrorDecoder+=1
        decoder.beginSession(generation: nextMirrorDecoder)
    }
    private func abandonCaptureTargetPresentationOnQueue() {
        guard captureTargets.enabled else { return }
        captureTargets.abandonPresentation(session: captureTargets.session)
        mirrorControl.setCaptureTargetInputBlocked(true)
        retireCaptureTargetDecoderOnQueue()
        refreshCaptureTargetsOnQueue();publishMirrorStateOnQueue()
    }
    private func captureTargetModeIsReady(_ applied: CaptureTargetResult) -> Bool {
        guard let state=mirrorControl.currentState, state.revision > captureTargetMirrorRevisionAtTap else { return false }
        if applied.kind == .extend { return state.mode == .virtualDisplay }
        return state.epoch == applied.epoch && state.source == applied.source && state.geometry != nil &&
            state.firstFrame != nil && (state.mode == .viewOnly || state.mode == .awaitingPresentation || state.mode == .active)
    }
    private func captureTargetModeMatches(owner: CaptureTargetDecoderOwner) -> Bool {
        guard captureTargets.session == owner.session, let applied=captureTargets.applied,
              applied.transaction == owner.transaction, applied.owner == owner.owner,
              applied.epoch == owner.epoch, applied.source == owner.source,
              captureTargetModeIsReady(applied) else { return false }
        // Virtual MirrorState has a separate identity; remember it to detect later supersession.
        return owner.kind != .extend || mirrorControl.currentState?.epoch == owner.mirrorEpoch
    }
    private func advanceCaptureTargetVideoOnQueue() {
        guard let applied=captureTargets.applied, captureTargetModeIsReady(applied),
              let state=mirrorControl.currentState, let kind=applied.kind else { return }
        if currentCaptureTargetDecoderOwner == nil {
            guard nextMirrorDecoder != UInt64.max else { handleStreamError("Source decoder identity exhausted.");return }
            nextMirrorDecoder+=1
            let owner=CaptureTargetDecoderOwner(session: captureTargets.session, generation: connectionGeneration,
                transaction: applied.transaction, owner: applied.owner, epoch: applied.epoch, source: applied.source,
                decoder: nextMirrorDecoder, kind: kind, mirrorEpoch: state.epoch)
            mirrorDecoderLock.lock();captureTargetDecoderOwner=owner;mirrorDecoderOwner=nil;mirrorDecoderLock.unlock()
            decoder.invalidate(waitForCompletion: false)
            decoder.beginSession(generation: owner.decoder)
            if activeVideoCodec == .h264 {
                guard let sets=captureTargetH264ParameterSets, sets.count == 2,
                      decoder.configureH264(sps: sets[0], pps: sets[1]) else {
                    abandonCaptureTargetPresentationOnQueue();return
                }
            }
        }
        guard !captureTargetDecodeStarted else { return }
        let frames=captureTargetVideo.take(firstFrame: applied.firstFrame)
        guard !frames.isEmpty else { return }
        captureTargetDecodeStarted=true
        for frame in frames { decodeCaptureTargetFrameOnQueue(frame) }
    }
    private func decodeCaptureTargetFrameOnQueue(_ frame: CaptureTargetVideoBuffer.Frame) {
        guard let applied=captureTargets.applied, let owner=currentCaptureTargetDecoderOwner,
              captureTargetModeMatches(owner: owner),
              MirrorControlCodec.sequenceAtOrAfter(frame.sequence, applied.firstFrame) else { return }
        if let last=captureTargetLastVideoSequence, !MirrorControlCodec.sequenceAtOrAfter(frame.sequence, last &+ 1) { return }
        captureTargetLastVideoSequence=frame.sequence
        #if targetEnvironment(simulator)
        if let decode=captureTargetDecodeForTesting { decode(frame.data, frame.sequence, owner.decoder);return }
        #endif
        decoder.processInputData(frame.data, sequence: frame.sequence, isIDR: frame.isIDR,
                                 isLengthPrefixed: frame.lengthPrefixed, receivedAt: frame.receivedAt)
    }
    /// Both the TLS parser and authenticated RTP access-unit owner pass through this same gate.
    private func consumeCaptureTargetVideoOnQueue(_ data: Data, sequence: UInt32, isIDR: Bool,
                                                  lengthPrefixed: Bool, receivedAt: TimeInterval) -> Bool {
        guard captureTargetOwnsPresentation else { return false }
        let frame=CaptureTargetVideoBuffer.Frame(data: data, sequence: sequence, isIDR: isIDR,
                                                lengthPrefixed: lengthPrefixed, receivedAt: receivedAt)
        if let pending=captureTargets.pending {
            if pending.accepted { captureTargetVideo.append(frame) }
            return true
        }
        guard let applied=captureTargets.applied,
              MirrorControlCodec.sequenceAtOrAfter(sequence, applied.firstFrame) else { return true }
        if captureTargetDecodeStarted { decodeCaptureTargetFrameOnQueue(frame) }
        else { captureTargetVideo.append(frame);advanceCaptureTargetVideoOnQueue() }
        return true
    }
    private func sendCaptureTargetRecoveryOnQueue(_ applied: CaptureTargetResult) {
        guard captureTargets.applied == applied, wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration, let payload=try? applied.recoveryPayload() else { return }
        sendWireMessage(type: .videoFeedback, payload: payload, sequence: 0, flags: CaptureTargetProtocol.recoveryFlag)
    }
    private func startCaptureTargetRecoveryOnQueue() {
        guard let applied=captureTargets.applied else { return }
        cancelCaptureTargetRecoveryOnQueue()
        let token=UUID(), session=captureTargets.session
        captureTargetRecoveryToken=token
        if !captureTargetDecodeStarted { sendCaptureTargetRecoveryOnQueue(applied) }
        for second in 1...5 {
            scheduleCaptureTargetCallback(TimeInterval(second), recovery: true) { [weak self] in
                guard let self, self.captureTargetRecoveryToken == token, self.captureTargets.session == session,
                      self.captureTargets.applied == applied, self.captureTargets.inputBlocked else { return }
                if second == 5 { self.abandonCaptureTargetPresentationOnQueue() }
                else { self.sendCaptureTargetRecoveryOnQueue(applied) }
            }
        }
    }
    private func recoverCaptureTargetDecodeRootOnQueue() {
        guard captureTargets.applied != nil else { return }
        // Keep an existing attempt's deadline. A decoder failure never extends its five-second budget.
        if captureTargetRecoveryToken != nil {
            captureTargetDecodeStarted=false;captureTargetLastVideoSequence=nil;captureTargetVideo.reset()
            if let applied=captureTargets.applied { sendCaptureTargetRecoveryOnQueue(applied) }
            return
        }
        captureTargets.requireFreshPresentation(session: captureTargets.session)
        mirrorControl.setCaptureTargetInputBlocked(true)
        retireCaptureTargetDecoderOnQueue();advanceCaptureTargetVideoOnQueue()
        startCaptureTargetRecoveryOnQueue();publishMirrorStateOnQueue()
    }
    private func captureTargetPacketIsCurrent(_ data: Data) -> Bool {
        guard data.count >= 16, data[0] == 0x53, data[1] == 0x43 else { return true }
        if data[5] == WireMessageType.sourceSwitchRequest.rawValue {
            guard data.count == 56, let request=captureTargets.pending?.request else { return false }
            return data.loadLittleEndian(UInt64.self, at: 24) == request.transaction &&
                data.loadLittleEndian(UInt64.self, at: 32) == request.owner
        }
        if data[5] == WireMessageType.videoFeedback.rawValue,
           data.loadLittleEndian(UInt16.self, at: 6) == CaptureTargetProtocol.recoveryFlag {
            guard data.count == 40, let applied=captureTargets.applied else { return false }
            return data.loadLittleEndian(UInt64.self, at: 16) == applied.owner &&
                data.loadLittleEndian(UInt64.self, at: 24) == applied.epoch &&
                data.loadLittleEndian(UInt64.self, at: 32) == applied.source
        }
        return true
    }

    private var currentMirrorDecoderOwner: MirrorDecoderOwner? {
        mirrorDecoderLock.lock(); defer { mirrorDecoderLock.unlock() }; return mirrorDecoderOwner
    }
    private func beginOwnedDecoderSession(networkGeneration generation: UInt64) {
        if captureTargetOwnsPresentation { abandonCaptureTargetPresentationOnQueue() }
        guard let state = mirrorControl.currentState else { decoder.beginSession(generation: generation); return }
        guard generation & 0x8000_0000_0000_0000 == 0, nextMirrorDecoder != UInt64.max else {
            handleStreamError("Physical-source decoder identity exhausted."); return
        }
        nextMirrorDecoder += 1
        let owner = MirrorDecoderOwner(connection: generation, decoder: nextMirrorDecoder, epoch: state.epoch, source: state.source)
        mirrorDecoderLock.lock(); mirrorDecoderOwner = owner; mirrorDecoderLock.unlock()
        decoder.beginSession(generation: owner.decoder)
    }
    private func publishMirrorStateOnQueue() {
        let generation = connectionGenerationClock.current
        let state = mirrorControl.currentState
        let revision = mirrorControl.gestureRevision
        let catalogue:MirrorMonitorCatalogue?
        if let state,mirrorCatalogueSource?.epoch==state.epoch,
           mirrorCatalogueSource?.source==state.source,mirrorControl.hasPresentedCurrentSource {
            catalogue=currentMirrorCatalogue
            if catalogue != nil {mirrorSwitchPending=false;mirrorSwitchAttempt=nil;mirrorSwitchDeadlineToken=nil}
        } else {catalogue=nil}
        let pending=mirrorSwitchPending
        let picker=mirrorControl.supportsScreenPicker
        let sources=captureTargets
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.mirrorControlState = state; self.mirrorInputRevision = revision
            self.mirrorMonitorCatalogue=catalogue;self.mirrorMonitorSwitchPending=pending
            self.mirrorScreenPickerSupported=picker
            self.captureTargetState=sources
        }
    }
    /// Screen picker opened: ask the Host for a fresh list (the stored one goes stale after 30 s).
    public func refreshMirrorScreens() {
        let generation=connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            if self.captureTargets.enabled { self.refreshCaptureTargetsOnQueue() }
            else { self.sendScreenPickerAction { $0.screenListRequest() } }
        }
    }
    /// Ask the attended Host to allow monitor switching. The Host shows a notice; nothing is granted here.
    public func requestMirrorSwitchPermission() {
        let generation=connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation else { return }
            let action=self.captureTargets.enabled
                ? self.mirrorControl.typedSwitchPermissionRequest(negotiated: true)
                : self.mirrorControl.switchPermissionRequest()
            if let action { self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0) }
        }
    }
    private func sendScreenPickerAction(_ make: @escaping (MirrorClientControl) -> Data?) {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  let action = make(self.mirrorControl) else { return }
            self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0)
        }
    }
    public var mirrorTicketAtRegistration: MirrorInputTicket? { mirrorControl.captureTicket() }
    public var permitsLegacyVirtualInput: Bool { mirrorControl.allowsLegacyVirtualInput }
    /// Settings over the stream pauses local input only; the Host keeps its attended grant.
    public func setMirrorInputSettingsPresented(_ open: Bool) {
        let generation = connectionGenerationClock.current
        mirrorControl.setSettingsPresented(open)
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            self.publishMirrorStateOnQueue()
        }
    }
    /// Explicit Release control: revokes the Host grant.
    public func releaseMirrorControl() {
        let generation = connectionGenerationClock.current
        let action = mirrorControl.suspendInput()
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            self.mirrorTerminalSend=nil
            if let action, self.wireAuthenticatedGeneration == generation {
                self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0)
            }
            self.publishMirrorStateOnQueue()
        }
    }
    public func requestMirrorControl() {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration,
                  let action = self.mirrorControl.requestControl() else { return }
            self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0)
        }
    }
    public func requestMirrorMonitor(_ id:UInt64, catalogue:MirrorMonitorCatalogue) {
        let generation=connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self,generation==self.connectionGeneration,
                  self.wireAuthenticatedGeneration==generation,self.committedTransportGeneration==generation,
                  !self.mirrorSwitchPending,let connection=self.activeControlConnection,
                  self.currentMirrorCatalogue==catalogue,
                  self.mirrorControl.hasPresentedCurrentSource,
                  ProcessInfo.processInfo.systemUptime-self.mirrorCatalogueReceivedAt<30,
                  let payload=try? catalogue.switchRequest(id) else {return}
            // A consumed catalogue cannot submit another switch while its transaction is pending.
            self.currentMirrorCatalogue=nil
            self.mirrorCatalogueSource=nil;self.mirrorSwitchPending=true
            let attempt=UUID()
            self.mirrorSwitchAttempt=attempt
            if self.mirrorControl.supportsTerminalSwitch {
                guard self.nextMirrorTerminalNonce != UInt64.max else {
                    self.mirrorControl.cancelTerminalSwitch();self.mirrorSwitchPending=false
                    self.mirrorSwitchAttempt=nil;self.publishMirrorStateOnQueue();return
                }
                self.nextMirrorTerminalNonce+=1
                let nonce=self.nextMirrorTerminalNonce
                guard let retirement=self.mirrorControl.beginTerminalSwitch(nonce:nonce) else {
                    self.mirrorSwitchPending=false;self.mirrorSwitchAttempt=nil
                    self.publishMirrorStateOnQueue();return
                }
                self.mirrorTerminalSend=MirrorTerminalSend(attempt:attempt,nonce:nonce,generation:generation,
                    connection:connection,payload:payload,catalogueReceivedAt:self.mirrorCatalogueReceivedAt)
                self.sendWireMessage(type:.mirrorAction,payload:retirement,sequence:0) { [weak self] error in
                    guard let self,var pending=self.mirrorTerminalSend,pending.attempt==attempt,
                          self.connectionGeneration==generation,self.activeControlConnection === connection else {return}
                    guard error == nil else {
                        self.mirrorControl.cancelTerminalSwitch();self.mirrorTerminalSend=nil;return
                    }
                    pending.written=true;self.mirrorTerminalSend=pending
                    self.advanceMirrorTerminalSwitchOnQueue()
                }
            } else {
                if let retirement=self.mirrorControl.suspendInput() {
                    self.sendWireMessage(type:.mirrorAction,payload:retirement,sequence:0)
                }
                self.sendWireMessage(type:.mirrorSwitchRequest,payload:payload,sequence:0)
            }
            self.publishMirrorStateOnQueue()
            self.scheduleMirrorSwitchDeadlineOnQueue(attempt:attempt,generation:generation,connection:connection)
        }
    }
    private func scheduleMirrorSwitchDeadlineOnQueue(attempt:UUID,generation:UInt64,connection:NWConnection) {
            let deadlineToken=UUID();mirrorSwitchDeadlineToken=deadlineToken
            let completion: () -> Void = { [weak self, weak connection] in
                guard let self,let connection,self.mirrorSwitchAttempt==attempt,
                      self.mirrorSwitchDeadlineToken==deadlineToken,
                      self.connectionGeneration==generation,self.wireAuthenticatedGeneration==generation,
                      self.committedTransportGeneration==generation,
                      self.activeControlConnection === connection else {return}
                // No response means unknown, never a selected monitor or renewed input grant.
                self.mirrorSwitchAttempt=nil;self.mirrorSwitchPending=false
                self.mirrorSwitchDeadlineToken=nil
                if self.mirrorControl.supportsTerminalSwitch {self.mirrorControl.cancelTerminalSwitch()}
                self.mirrorTerminalSend=nil
                self.currentMirrorCatalogue=nil;self.mirrorCatalogueSource=nil
                self.publishMirrorStateOnQueue()
            }
            #if targetEnvironment(simulator)
            if let schedule=mirrorSwitchDeadlineForTesting {schedule(5,completion);return}
            #endif
            networkQueue.asyncAfter(deadline:.now()+5,execute:completion)
    }
    private func advanceMirrorTerminalSwitchOnQueue() {
        dispatchPrecondition(condition:.onQueue(networkQueue))
        guard let pending=mirrorTerminalSend,pending.written,
              mirrorSwitchAttempt==pending.attempt,mirrorSwitchPending,
              connectionGeneration==pending.generation,wireAuthenticatedGeneration==pending.generation,
              committedTransportGeneration==pending.generation,
              activeControlConnection === pending.connection else {return}
        guard ProcessInfo.processInfo.systemUptime-pending.catalogueReceivedAt<30 else {
            mirrorControl.cancelTerminalSwitch();mirrorTerminalSend=nil;return
        }
        guard mirrorControl.takeTerminalSwitch(nonce:pending.nonce) else {return}
        mirrorTerminalSend=nil
        sendWireMessage(type:.mirrorSwitchRequest,payload:pending.payload,sequence:0)
        // Terminal retirement and the D03-P response are distinct bounded phases.
        scheduleMirrorSwitchDeadlineOnQueue(attempt:pending.attempt,generation:pending.generation,connection:pending.connection)
    }
    public func setMirrorInputForeground(_ active: Bool) {
        let generation = connectionGenerationClock.current
        let action = mirrorControl.setForeground(active)
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            if !active {self.mirrorTerminalSend=nil}
            if let action, self.wireAuthenticatedGeneration == generation {
                self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0)
            }
            self.publishMirrorStateOnQueue()
        }
    }
    public func sendMirrorInput(ticket: MirrorInputTicket, kind: MirrorInputKind, payload: Data) {
        networkQueue.async { [weak self] in
            guard let self, ticket.session == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == ticket.session,
                  self.committedTransportGeneration == ticket.session,
                  self.transportState == .streaming,
                  let envelope = try? self.mirrorControl.encodeInput(ticket: ticket, kind: kind, payload: payload) else { return }
            // Existing bounded reliable lane. No UDP/raw fallback, no terminal coalescing.
            self.sendWireMessage(type: .mirrorInput, payload: envelope, sequence: 0, movement: false)
        }
    }
    public static func mirrorPencilPayload(type: TouchEventType, x: UInt16, y: UInt16, pressure: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = 0x49; bytes[1] = 0x54; bytes[2] = type.rawValue; bytes[3] = pressure
        bytes[4] = UInt8(truncatingIfNeeded: x); bytes[5] = UInt8(truncatingIfNeeded: x >> 8)
        bytes[6] = UInt8(truncatingIfNeeded: y); bytes[7] = UInt8(truncatingIfNeeded: y >> 8)
        return Data(bytes)
    }

    /// Records completion of the Metal command buffer as a distinct presentation stage.
    public func recordRenderCompletion(sequence: UInt32, generation: UInt64) {
        mirrorDecoderLock.lock()
        let typed = captureTargetDecoderOwner
        let captured = mirrorDecoderOwner
        mirrorDecoderLock.unlock()
        if let typed, typed.decoder == generation {
            networkQueue.async { [weak self] in
                guard let self, self.currentCaptureTargetDecoderOwner == typed,
                      self.captureTargets.session == typed.session, self.connectionGeneration == typed.generation,
                      self.captureTargetDecodeStarted, self.captureTargetModeMatches(owner: typed),
                      let applied=self.captureTargets.applied,
                      MirrorControlCodec.sequenceAtOrAfter(sequence, applied.firstFrame) else { return }
                self.transportTelemetry.recordRenderCompletion(sequence: sequence, generation: typed.generation)
                if self.captureTargets.observeRendered(sequence: sequence, session: typed.session) {
                    self.cancelCaptureTargetRecoveryOnQueue()
                    self.mirrorControl.setCaptureTargetInputBlocked(false)
                }
                if typed.kind == .physical,
                   let ack=self.mirrorControl.observeRendered(session: typed.generation, sequence: sequence) {
                    self.sendWireMessage(type: .mirrorAction, payload: ack, sequence: 0)
                }
                self.publishMirrorStateOnQueue()
            }
            return
        }
        if let captured, captured.decoder == generation {
            transportTelemetry.recordRenderCompletion(sequence: sequence, generation: captured.connection)
            networkQueue.async { [weak self] in
                guard let self, captured.connection == self.connectionGeneration,
                      self.currentMirrorDecoderOwner == captured,
                      self.mirrorControl.currentState?.epoch == captured.epoch,
                      self.mirrorControl.currentState?.source == captured.source else { return }
                if let ack=self.mirrorControl.observeRendered(session: captured.connection, sequence: sequence) {
                    self.sendWireMessage(type: .mirrorAction, payload: ack, sequence: 0)
                    self.publishMirrorStateOnQueue()
                }
            }
        } else if generation & 0x8000_0000_0000_0000 == 0 {
            transportTelemetry.recordRenderCompletion(sequence: sequence, generation: generation)
        }
    }

    public func recordDrawableCommitted(
        sequence: UInt32,
        generation: UInt64
    ) {
        transportTelemetry.recordDrawableCommitted(
            sequence: sequence,
            generation: generation)
    }

    public func recordRenderDrop(sequence: UInt32, generation: UInt64) {
        transportTelemetry.recordRenderDrop(
            sequence: sequence,
            generation: generation)
    }

    func recordDiagnosticLine(_ line: String) {
        transportTelemetry.recordDiagnosticLine(line)
    }

}

// MARK: - Private Extensions

/// Clamps a `Float` to [lo, hi] inclusive.
/// Used by `sendTouchEventNormalized` to guard against out-of-range gesture values.
private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
enum WifiConnectionReadinessPolicy {
    static func isReady(
        actualReady: Bool,
        waitingOwned: Bool,
        simulatedReady: Bool = false
    ) -> Bool {
        if actualReady { return true }
        if waitingOwned { return false }
        return simulatedReady
    }
}

enum KeyboardInputDeliveryPolicy {
    static func maySend(action: KeyboardInputAction, inputSuppressed: Bool) -> Bool {
        !inputSuppressed || action == .keyUp
    }
}

enum PointerInputDeliveryPolicy {
    static func maySend(action: PointerInputAction, inputSuppressed: Bool) -> Bool {
        !inputSuppressed || action == .leftUp
    }
}

enum DirectTouchDeliveryPolicy {
    static func maySend(phase: DirectTouchPhase, inputSuppressed: Bool) -> Bool {
        !inputSuppressed || phase == .up || phase == .cancel
    }
}


// One main-thread owner for the remote session's bar, hardware and pointer input.
struct RemoteSessionInputConfiguration: Equatable {
    let remote: Bool
    let connected: Bool
    let active: Bool
    let generation: UInt64
    let features: UInt64
    let context: RemoteInputContextCommand?
    let ready: Bool
    let revision: UInt64
}

@MainActor final class RemoteSessionInputState: ObservableObject {
    @Published var keyboard = RemoteKeyboardState(token: 0)
    @Published private(set) var mouseMode: RemoteMouseMode = .auto
    @Published private(set) var configuration: RemoteSessionInputConfiguration?
    @Published private(set) var waitingForContext = false
    var sendKey: (RemoteScanKeyCommand, UInt64) -> Void = { _, _ in }
    var sendPointer: (RemotePointerCommand, UInt64) -> Void = { _, _ in }
    var sendReset: (RemoteInputResetCommand, UInt64) -> Void = { _, _ in }
    private weak var boundNetwork: NetworkManager?
    private func publishMonitorControl() {
        boundNetwork?.updateRemoteMonitorControl(configuration: configuration, enabled: pointerEnabled, available: monitorControlAvailable)
    }
    private var blockedToken: UInt64?
    private var hardwareUsages: Set<Int> = []
    private var suppressedUsages: Set<Int> = []
    private var videoRect = CGRect.zero
    private var mouse = RemoteMouseInput(context: nil, videoRect: .zero, generation: 0, inputReady: false)

    var usesScanKeyboard: Bool { configuration?.remote == true && (configuration!.features & 1) != 0 }
    var usesEnhancedPointer: Bool { configuration?.remote == true && (configuration!.features & 2) != 0 }
    var generation: UInt64 { configuration?.generation ?? 0 }
    var token: UInt64 { configuration?.context?.token ?? 0 }
    var revision: UInt64 { configuration?.revision ?? 0 }
    private var enabled: Bool {
        guard let c = configuration, c.remote, c.connected, c.active, c.ready,
              let context = c.context, context.state == 1, context.token != 0,
              [1, 2, 3].contains(context.desktop),
              context.width > 0, context.height > 0 else { return false }
        return !waitingForContext
    }
    var keyboardEnabled: Bool { usesScanKeyboard && enabled }
    var pointerEnabled: Bool { usesEnhancedPointer && enabled }
    /// Permission survives a missing capture source; normal input still uses the existing ready/context gate.
    var monitorControlAvailable: Bool {
        guard let c = configuration else { return false }
        return c.remote && c.connected && c.active && c.features & 7 == 7
    }

    func bind(_ network: NetworkManager) {
        boundNetwork = network
        publishMonitorControl()
        sendKey = { [weak network] in network?.sendRemoteScanKey($0, expectedGeneration: $1) }
        sendPointer = { [weak network] in network?.sendRemotePointer($0, expectedGeneration: $1) }
        sendReset = { [weak network] in network?.sendRemoteInputReset($0, expectedGeneration: $1) }
    }

    func configure(_ value: RemoteSessionInputConfiguration) {
        guard configuration != value else { return }
        defer { publishMonitorControl() }
        let old = configuration
        let changedConnection = old?.generation != value.generation || old?.remote != value.remote
        let retired = changedConnection || old?.revision != value.revision || old?.context != value.context
            || old?.features != value.features || !value.connected || !value.ready
        if retired {
            suppressedUsages.formUnion(hardwareUsages)
            hardwareUsages.removeAll()
            keyboard = RemoteKeyboardState(token: 0)
            mouse = RemoteMouseInput(context: nil, videoRect: videoRect,
                generation: value.generation, mode: mouseMode, inputReady: false)
        } else if old?.active == true && !value.active {
            suspend(reason: 0)
        }
        if changedConnection {
            blockedToken = nil
            mouseMode = .auto
            mouse = RemoteMouseInput(context: nil, videoRect: videoRect,
                generation: value.generation, mode: .auto, inputReady: false)
        }
        configuration = value
        waitingForContext = blockedToken != nil && (value.context == nil || value.context?.token == 0 || blockedToken == value.context?.token)
        if !waitingForContext { blockedToken = nil }
        if keyboardEnabled && keyboard.token != token { keyboard = RemoteKeyboardState(token: token) }
        _ = mouse.configure(context: value.context, videoRect: videoRect,
            generation: value.generation, inputReady: pointerEnabled)
    }

    func setVideoRect(_ rect: CGRect) {
        guard rect != videoRect else { return }
        videoRect = rect
        let commands = mouse.configure(context: configuration?.context, videoRect: rect,
            generation: generation, inputReady: pointerEnabled)
        commands.forEach { sendPointer($0, generation) }
    }

    @discardableResult func hardware(usage: Int, phase: RemoteHardwareKeyboard.Phase) -> Bool {
        if suppressedUsages.contains(usage) {
            if phase != .began { suppressedUsages.remove(usage) }
            return true
        }
        guard keyboardEnabled else { return false }
        if phase != .began && !hardwareUsages.contains(usage) { return false }
        var copy = keyboard
        var commands: [RemoteScanKeyCommand] = []
        let handled = RemoteHardwareKeyboard.handle(usage: usage, phase: phase,
            state: &copy, send: { commands.append($0) })
        keyboard = copy
        if handled {
            if phase == .began { hardwareUsages.insert(usage) } else { hardwareUsages.remove(usage) }
        }
        commands.forEach { emitKey($0, generation: generation) }
        return handled
    }

    func emitKey(_ key: RemoteScanKeyCommand, generation: UInt64) {
        guard keyboardEnabled, self.generation == generation, key.token == token else { return }
        sendKey(key, generation)
    }

    func acceptsText(token: UInt64?, generation: UInt64) -> Bool {
        guard self.generation == generation, let c = configuration,
              c.remote, c.connected, c.active else { return false }
        return usesScanKeyboard ? keyboardEnabled && token == self.token : true
    }

    func softwareKey(_ key: KeyboardInputCommand) {
        let usage: Int
        switch key.virtualKey {
        case 0x08: usage = 0x2a
        case 0x09: usage = 0x2b
        case 0x0d: usage = 0x28
        case 0x1b: usage = 0x29
        default: return
        }
        guard keyboardEnabled else { return }
        // A software control key is a bar owner, never a physical-key owner.
        guard let physical = RemoteHardwareKeyboard.key(forUsage: usage) else { return }
        let commands = key.action == .keyDown ? keyboard.barKeyDown(physical) : keyboard.barKeyUp(physical)
        commands.forEach { emitKey($0, generation: generation) }
    }

    func pointer(token: UInt64, generation: UInt64,
                 _ operation: (inout RemoteMouseInput) -> [RemotePointerCommand]) {
        guard pointerEnabled, self.token == token, self.generation == generation else { return }
        operation(&mouse).forEach { sendPointer($0, generation) }
    }

    func middleClick() {
        let t = token, g = generation
        pointer(token: t, generation: g) { $0.middleClick(token: t, generation: g) }
    }

    func changeMouseMode(_ mode: RemoteMouseMode) {
        guard pointerEnabled, mode != mouseMode else { return }
        suspend(reason: 3)
        mouseMode = mode
        mouse = RemoteMouseInput(context: nil, videoRect: videoRect,
            generation: generation, mode: mode, inputReady: false)
    }

    func suspend(reason: UInt8) {
        guard enabled, usesScanKeyboard || usesEnhancedPointer else { return }
        defer { publishMonitorControl() }
        let t = token, g = generation
        let keys = keyboard.reset()
        let buttons = mouse.reset(token: t, generation: g)
        // Ordinary keys and all buttons precede modifier releases.
        for key in keys where !RemotePhysicalKey(scan: key.scan, flags: key.flags).isModifier {
            sendKey(key, g)
        }
        buttons.forEach { sendPointer($0, g) }
        for key in keys where RemotePhysicalKey(scan: key.scan, flags: key.flags).isModifier {
            sendKey(key, g)
        }
        suppressedUsages.formUnion(hardwareUsages)
        hardwareUsages.removeAll()
        keyboard = RemoteKeyboardState(token: 0)
        blockedToken = t
        waitingForContext = true
        _ = mouse.configure(context: configuration?.context, videoRect: videoRect,
            generation: g, inputReady: false)
        sendReset(RemoteInputResetCommand(reason: reason, token: t), g)
    }
}
