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
    case submittingPIN
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
    @Published private(set) var trustedHostForgetOutcome: TrustedHostForgetOutcome?
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
    private var wifiAuthentication = WifiAuthenticationState()
    private var pinResponseDeadline: DispatchWorkItem?
    private var hostIdentityConfirmed = false
    private var trustedCredential: TrustedHostCredential?
    private var trustedCredentialStore = TrustedHostCredentialStore()
    private var trustedHostFingerprintStore = TrustedHostFingerprintStore()
    private static let trustedHostCleanupKey = "trustedHostPendingCleanup"
    private var trustedHostCleanup: [String: Bool] // Network queue; value records PC confirmation.
    private struct PendingTrustedHostForget {
        let fingerprint: String
        let endpoint: NWEndpoint?
        let generation: UInt64
        let timeout: DispatchWorkItem
    }
    private var pendingTrustedHostForget: PendingTrustedHostForget?
    private var discoveredWifiEndpoints: [NWEndpoint] = []
    private var triedWifiReconnectTargets: Set<WifiReconnectTarget> = []
    private var expectedWifiReconnectFingerprint: String?
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
    private var legacyInputLifetime = InputLifetime()
    private var activeDirectTouchCommand: DirectTouchContactCommand?
    @Published private(set) var transferSnapshot = DataTransferManager.Snapshot()
    private var dataTransfers: DataTransferManager?
    @Published private(set) var remoteFileStatus: String?
    @Published private(set) var remoteFileWaiting = false
    @Published private(set) var remoteFileCanStart = false
    @Published private(set) var remoteSecureDesktopSupported = false
    @Published private(set) var remoteSecureDesktopCovered = false
    @Published private(set) var remoteSecureDesktopControl = false
    @Published private(set) var remoteSecureDesktopCanSas = true
    private var remoteSecureDesktop = RemoteSecureDesktopState()
    private let remoteSecureDesktopPublicationClock = ConnectionGenerationClock()
    private var remoteSecureControlIntent = false
    private var remoteTimedVideoLatched = false
    private var remoteTimedVideoNeedsIDR = false
    private var remoteTimedVideo = RemoteTimedVideoAssembler()
    private let remoteVideoTiming = RemoteVideoPresentationTiming()
    private let remoteAudioPlayback = RemoteAudioPlayback()
    private var remoteAudio = RemoteAudioSession()
    private var remoteAudioRequested = false
    private var remoteAudioFeaturesReceived = false
    private var remoteAudioOutputFailed = false
    @Published private(set) var remoteAudioPreferred = false
    @Published private(set) var remoteAudioStatus: String?
    private let remoteAudioPublicationClock = ConnectionGenerationClock()
    private var remoteSecureDesktopEnabled: Bool {
        streamSettingsDefaults.bool(forKey: RemoteSecureDesktopState.preferenceKey)
    }
    @Published private(set) var remoteClipboardEnabled: Bool
    @Published private(set) var automaticClipboardSending: Bool
    @Published private(set) var clipboardMissedCopyNotice: String?
    @MainActor private var clipboardNoticeTask: Task<Void, Never>?
    private let remoteClipboardAuthority = RemoteClipboardAuthority()
    private let remoteClipboardWorker = RemoteClipboardContentWorker()
    private var remoteClipboardLease = RemoteClipboardLease()
    private var remoteClipboardTimer: DispatchSourceTimer?
    private var remoteClipboardPresentation: ClipboardPresentation?
    private var remoteClipboardTransfer: RemoteClipboardTransfer?
    private var remoteClipboardCounter: UInt64 = 0
    private var remoteClipboardPeerOrigin: UUID?
    private var remoteClipboardPeerCounter: UInt64 = 0
    private var remoteClipboardSeenUpdates: [UUID] = []
    private var remoteClipboardStatusHistory = Set<UUID>()
    private static let clipboardStatusHistoryLimit = 4096
    private var remoteClipboardOutgoingAutomatic = false
    private var castingClipboardRoute: CastingClipboardRoute?
    private var castingClipboardChallenge: Data?
    private var castingClipboardDeadline: TimeInterval = 0
    private var castingClipboardParserGeneration: UInt64?
    #if targetEnvironment(simulator)
    @MainActor var clipboardReadSourceForTesting: RemoteClipboardPasteboard.ReadSource?
    private var castingClipboardTLSForTesting: Bool?
    #endif
    @MainActor lazy var remoteClipboardPasteboard = makeClipboardPasteboard()

    @MainActor private func makeClipboardPasteboard() -> RemoteClipboardPasteboard {
        #if targetEnvironment(simulator)
        let readSource = clipboardReadSourceForTesting
        #else
        let readSource: RemoteClipboardPasteboard.ReadSource? = nil
        #endif
        return RemoteClipboardPasteboard(
            authority: remoteClipboardAuthority, worker: remoteClipboardWorker,
            send: { [weak self] grant, revision, content, automatic in
                self?.networkQueue.async { [weak self] in
                    self?.offerRemoteClipboard(grant: grant, revision: revision, content: content, automatic: automatic)
                }
            },
            changed: { [weak self] grant, revision in
                self?.networkQueue.async { [weak self] in
                    guard let self, self.remoteClipboardGrant == grant,
                          self.remoteClipboardTransfer?.revision != revision else { return }
                    self.cancelRemoteClipboardTransfer(.superseded)
                }
            }, readSource: readSource)
    }
    private var remoteFileAccess: RemoteFileAccess?
    private let remoteFileActionClock = ConnectionGenerationClock()
    private var remoteFileIO: DataTransferManager?
    private var remoteFileBackgrounded = false
    private var remoteFilePacing = RemoteFileMediaPacing()
    private var pendingRemoteFileWrite: DispatchWorkItem?
    private var remoteFileWriteToken: UUID?
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
        let terminalError: NWError?
    }
    private var transferReceiveSuffix: TransferReceiveSuffix?
    private var wireReceiveOutstanding: (generation: UInt64, connection: ObjectIdentifier)?
    private let connectionGenerationClock = ConnectionGenerationClock()
    private var connectionGeneration: UInt64 {
        connectionGenerationClock.current
    }
    var remoteKeyboardGeneration: UInt64 { connectionGenerationClock.current }
    private var remoteInputConnection = false
    private var remoteFeatures = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
    private var remoteMonitors = RemoteMonitorState()
    private let remoteMonitorControl = RemoteMonitorControlAuthority()
    private var remoteMonitorAdmission: (requestId: UInt64, inputRevision: UInt64, controlRevision: UInt64)?
    private let remoteMonitorPublicationClock = ConnectionGenerationClock()
    @Published public private(set) var remoteMonitorState = RemoteMonitorState()
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
    @Published private(set) var screenSwitchPermissionPending = false
    @Published private(set) var screenSwitchPermissionNotice: String?
    private var captureTargets = CaptureTargetState()
    private var captureTargetAdvertisementGeneration: UInt64?
    private var screenSwitchPermissionRequest: UUID?
    private var screenSwitchPermissionTimedOut = false
    private var captureAvailability = CaptureAvailabilityState()
    private var captureReadinessClock = CaptureReadinessClock()
    @Published public private(set) var captureAvailabilityNotice: String?
    @Published public private(set) var captureInputBlocked = false
    @Published private(set) var iPadPointerV2Supported = false
    @Published private(set) var iPadPointerV2Generation: UInt64 = 0
    private var remoteDirectLifetime = InputLifetime()
    private var captureTargetVideo = CaptureTargetVideoBuffer()
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
    // Connection control is confined to networkQueue. Published state never contains proof secrets.
    @Published private(set) var connectionSwitchState = ConnectionSwitchState()
    private var connectionSwitch = ConnectionSwitchState()
    private var committedConnectionRoute: ConnectionRoute = .unknown
    private var connectionAdvertisement: UInt16 = 0
    private var pairedControlGeneration: UInt64?
    private var trustedProofGeneration: UInt64?
    private var connectionProof: ConnectionProofContext?
    private var connectionUSBProbe: NWConnection?
    private var connectionUSBProbeFrame: Data?
    private var connectionUSBProbeDeadline: TimeInterval?
    private var connectionUSBProbeAttempted = false
    private var connectionUSBCandidate: NWConnection?
    private var connectionSelectedEndpoint: NWEndpoint?
    private var connectionSelectedCredential: TrustedHostCredential?
    @Published private(set) var retainedSwitchRoute: ConnectionRoute?
    private var switchPictureTarget: ConnectionRoute?
    private var switchDiagnosticStart: TimeInterval?
    private var wifiRollbackAttempt = 0
    private var connectionExpectedRetirement = false
    private var connectionHandoffInProgress = false
    private var connectionOperation = UUID()
    private var connectionRollbackRetry: DispatchWorkItem?
    private var connectionLastInputFence = false
    private var connectionStatusTimer: DispatchSourceTimer?
    private var usbIdentity = USBSessionIdentityProof()
    private var usbReadinessPongWrittenGeneration: UInt64?
    private var usbIdentityDeadline: DispatchWorkItem?
    private var usbControlTLSUpgrade: USBControlTLSUpgrade?
    // Remember offers across in-process retries. Only proven TLS is saved in the credential.
    private var usbTLSAdvertisedHosts = Set<String>()
    private var connectionListenerCompletion: (() -> Void)?
    private var connectionListenerPreparationAt: TimeInterval?
    private var connectionVideo = CaptureTargetVideoBuffer()
    private var connectionVideoStarted = false
    private var connectionVideoInFlight: UInt32?
    private var connectionVideoPresentationRoot: UInt32?
    private var connectionVideoHasPresentedRoot = false
    private var connectionVideoNeedsIDR = false
    private var connectionCompleted: ConnectionSelectResult?
    private var connectionDisplayRequest: UInt32?
    private var connectionDisplayReady = false
    private var connectionReadyDisplay: DisplayReady?
    private var connectionDecoder: (network: UInt64, decoder: UInt64, domain: ConnectionFrameDomain)? // mirrorDecoderLock
    #if targetEnvironment(simulator)
    var connectionControlNowForTesting: (() -> TimeInterval)?
    var connectionListenerPortForTesting: UInt16?
    var connectionListenerReadyForTesting: (() -> Void)?
    var usbIdentityCredentialLoadForTesting: (() -> TrustedHostCredential?)?
    var usbServerTLSIdentityForTesting: USBServerTLSIdentity?
    private var connectionVideoReceivedAtForTesting: TimeInterval?
    #endif
    private lazy var controlChannelWriter = ControlChannelWriter(
        queue: networkQueue,
        sender: { [weak self] data, diagnostic, completion in
            guard let self else {
                completion(.posix(.ECANCELED))
                return
            }
            guard self.remoteFilePacketIsCurrent(data, startingWrite: true),
                  self.remoteClipboardPacketIsCurrent(data, startingWrite: true) else { completion(.posix(.ECANCELED)); return }
            if self.captureAvailability.inputBlocked && (CaptureAvailabilityProtocol.isNewInputPacket(data) || self.isNewRemoteV2InputPacket(data)) {
                completion(nil); return
            }
            if self.mirrorControl.isLegacyVirtualInputSuspended,
               (data.count == TouchWireProtocol.packetSize && data.loadLittleEndian(UInt16.self, at: 0) == TouchWireProtocol.magic ||
                data.count >= WireProtocol.headerSize && MirrorInputKind(rawValue: data[5]) != nil),
               CaptureAvailabilityProtocol.isNewInputPacket(data) {
                completion(nil); return
            }
            if !self.remoteInputPacketIsCurrent(data) || !self.captureTargetPacketIsCurrent(data) || !self.connectionControlPacketIsCurrent(data) {
                completion(nil)
                return
            }
            guard self.admitWifiAuthenticationWrite(data) else {
                completion(.posix(.ECANCELED))
                self.handleStreamError("Unexpected authentication request stage."); return
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
        queue: networkQueue, allowsRemoteFiles: { [weak self] in self?.mayReceiveRemoteFiles == true },
        allowsSecureDesktop: { [weak self] in self?.remoteSecureDesktop.supported == true },
        allowsSasAvailability: { [weak self] in self?.remoteSecureDesktop.sasAvailabilitySupported == true },
        allowsRemoteAudio: { [weak self] in self?.mayReceiveRemoteAudio == true },
        allowsRemoteClipboard: { [weak self] in
            guard let self else { return false }
            return self.remoteClipboardNegotiated || self.castingClipboardParserGeneration == self.connectionGeneration
        })
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
            mirrorControl.beginSession(wireAuthenticatedGeneration ?? 0, preservingUserStop: connectionHandoffInProgress)
            mirrorControl.setConnectionInputBlocked(connectionSwitch.inputBlocked)
            captureAvailability.begin(generation: wireAuthenticatedGeneration ?? 0)
            captureReadinessClock.setSuspended(false, at: connectionControlNow())
            decoder.resetCaptureOutputFence()
            wifiMediaReceiver.setCaptureSuspended(false)
            captureTargets.begin(generation: wireAuthenticatedGeneration ?? 0)
            captureTargetAdvertisementGeneration = nil
            screenSwitchPermissionRequest = nil
            screenSwitchPermissionTimedOut = false
            deferredSourceDisplay = nil
            captureTargetVideo.reset();captureTargetDecodeStarted=false
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
        didSet { if oldValue != committedTransportGeneration { refreshAutoAcceptPolicyOnQueue(); resetAdaptiveMediaOnQueue() } }
    }
    private func adaptiveNow() -> TimeInterval {
        #if targetEnvironment(simulator)
        if let clock=adaptiveMediaClockForTesting { return clock() }
        #endif
        return CACurrentMediaTime()
    }
    #if targetEnvironment(simulator)
    var adaptiveMediaClockForTesting: (() -> TimeInterval)?
    #endif
    private var qualityProbe = AdaptiveMediaProbe()
    private var qualityBaselinePresented = false
    private var qualityBaselineDecoder: UInt64?
    private var qualityBaselineIDRs: Set<UInt32> = []
    private var qualitySession: AdaptiveMediaSession?
    private var sourceRollback: (request: CaptureTargetRequest, identity: AdaptiveMediaIdentity, firstFrame: UInt32, decoder: UInt64)?
    private var qualityProbeDeadline: DispatchWorkItem?
    private var qualityFeedbackTimer: DispatchSourceTimer?
    private var qualityFeedbackIdentity: AdaptiveMediaIdentity?
    private var qualityWindow = AdaptiveMediaWindow(started: 0)
    private var manualReconnectPresentation: (
        identity: AdaptiveMediaIdentity, decoder: UInt64, frame: UInt64, started: TimeInterval, at: TimeInterval
    )?
    private var manualReconnectHealthy = false
    private var qualityRttSeconds: TimeInterval = 0
    private var qualityConnectionID: ObjectIdentifier?
    private var qualityHostID: Data?
    private var qualityAutoOptIn = false
    private var qualityPolicyDirty = false
    private var qualityOwnsPolicy = false
    private var remoteManualRestorePending = false
    private var remoteManualOverride = false
    private var remoteSettingsReady = false
    private var remoteSettingsGetID: UInt32?
    private var remoteManualRequestID: UInt32?
    private let streamSettingsDefaults: UserDefaults
    @Published public private(set) var adaptiveQualityAvailable = false
    @Published public private(set) var autoQualityEnabled = false
    @Published public private(set) var savedAutoQualityEnabled = false
    @Published private(set) var adaptiveQualityBackoffActive = false
    @Published private(set) var legacyAutomaticBitrateUnavailable = false
    @Published public private(set) var adaptiveQualityUnavailableReason = "Auto quality requires a streaming connection."
    @Published public private(set) var effectiveQualitySummary: String?
    @Published public private(set) var adaptiveDesktopSize: CGSize?
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
        currentDecoderGeneration: { [weak self] in self?.decoder.currentSessionGeneration },
        decoder: { [weak self] data, sequence, isIDR, receivedAt in
            guard let self,
                  self.committedTransportGeneration == self.connectionGeneration,
                  self.committedRealtimeMode == RealtimeTransportMode.wifiRTP else { return }
            guard self.adaptiveIncomingOnQueue(data, sequence: sequence, isIDR: isIDR, receivedAt: receivedAt, receiveUs: self.transportTelemetry.adaptiveReceiveDuration(sequence:sequence,generation:self.connectionGeneration)) else { return }
            self.captureAvailability.noteFrameReceived(sequence: sequence)
            if self.consumeConnectionVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                lengthPrefixed: true, receivedAt: receivedAt, domain: .rtp) { return }
            if self.captureTargetOwnsPresentation {
                self.recordVideoPayloadReceived(data.count, sequence: sequence)
                _=self.consumeCaptureTargetVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                    lengthPrefixed: true, receivedAt: receivedAt)
                return
            }
            guard self.mirrorControl.permitsVideoSequence(sequence) else { return }
            self.recordVideoPayloadReceived(data.count, sequence: sequence)
            guard self.admitCaptureContinuationOnQueue(sequence: sequence, decoder: self.decoder.currentSessionGeneration, isIDR: isIDR) else { return }
            self.submitVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                lengthPrefixed: true, receivedAt: receivedAt)
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
            if generation == self.connectionGeneration, self.castingAdaptiveRoute == .wifiRTP, self.qualitySession != nil,
               case .expired = outcome {
                self.qualityWindow.drop(0)
                self.sendAdaptiveFeedbackOnQueue()
            }
        },
        securityDropObserver: { [weak self] counters in
            self?.transportTelemetry.recordWifiSecurityDrops(counters)
        },
        rttObserver: { [weak self] durationMs in
            guard let self else { return }
            self.transportTelemetry.recordRtt(durationMs: durationMs)
            self.qualityRttSeconds = durationMs/1000
            self.qualityWindow.recordRtt(us:AdaptiveMediaWindow.us(durationMs/1000),now:CACurrentMediaTime())
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
            guard let self else { return }
            // Aborting the split-lane listeners is queued. Ignore a retired USB listener's late failure.
            if self.connectionHandoffInProgress && (self.committedConnectionRoute != .usb || self.connection == nil) { return }
            self.handleStreamError(
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
            captureAvailability.resetMediaDomain()
            wifiMediaReceiver.setCaptureSuspended(captureAvailability.inputBlocked)
            if oldValue != nil, committedRealtimeMode != nil, captureTargets.enabled {
                if captureAvailability.negotiated {
                    captureTargets.retireRoute(preserveAppliedSource: captureAvailability.negotiated)
                } else { captureTargets.retireRoute() }
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
    private struct DisplayRotationDiagnostic {
        let request: DisplayConfigurationRequest
        let chainID: UInt32
        let transport: ActiveTransportKind
        let startedAt: TimeInterval
        var sentAt: TimeInterval?
        var readyAt: TimeInterval?
        var presentedAt: TimeInterval?

        func matchesPresentation(_ size: CGSize) -> Bool {
            guard size.width > 0, size.height > 0,
                  (size.width > size.height) == (request.width > request.height) else { return false }
            let source = size.width * CGFloat(request.height)
            let target = size.height * CGFloat(request.width)
            // Allow pixel alignment when the encoder scales the desktop.
            return abs(source - target) <= target * 0.02
        }
    }
    private var displayRotationDiagnostic: DisplayRotationDiagnostic?
    private var displayRotationChainID: UInt32?
    #if targetEnvironment(simulator)
    var displayRotationDiagnosticSinkForTesting: ((String) -> Void)?
    #endif
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
        streamSettingsDefaults = userDefaults
        trustedHostCleanup = userDefaults.dictionary(forKey: Self.trustedHostCleanupKey) as? [String: Bool] ?? [:]
        remoteClipboardEnabled = userDefaults.bool(forKey: Clipboard.preferenceKey)
        automaticClipboardSending = Self.automaticClipboardPreference(in: userDefaults)
        retainedTransferRoot = receivedFilesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenCasting Transfers")
        networkQueue.setSpecific(key: networkQueueKey, value: true)
        clientDebugLoggingEnabled = ClientDebugLoggingPreference.load(
            defaults: userDefaults)
        ClientStreamSettingsStore.migrateCastingBitrate(defaults: userDefaults)
        ClientStreamSettingsStore.migrateRemoteBitrate(defaults: userDefaults)
        let desired = ClientStreamSettingsStore.load(defaults: userDefaults)
        clientSettingsState = ClientSettingsStateModel(desired: desired)
        desiredBitrateMbps = desired.bitrateMbps
        desiredAudioEnabled = desired.audioEnabled
        desiredAdaptiveBitrateEnabled = desired.adaptiveBitrateEnabled
        reconnectEnabled = RecentWifiResumeStore.consumeIfValid(defaults: userDefaults)
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
            guard let self, self.decoder.currentSessionGeneration == generation else { return }
            self.transportTelemetry.recordDecodeCallback(
                sequence: sequence,
                generation: self.telemetryGeneration(forDecoder: generation),
                decodeStartedAt: decodeStartedAt,
                durationMs: latencyMs)
        }
        decoder.onAdaptiveDecoded = { [weak self] sequence, generation, queueUs, decodeUs in
            self?.networkQueue.async { [weak self] in
                guard let self, self.decoder.currentSessionGeneration == generation,
                      let frame = self.adaptiveFrameOnQueue(sequence) else { return }
                self.qualityWindow.decoded(frame:frame,queueUs:queueUs,decodeUs:decodeUs)
                if self.qualityWindow.hasPressureSpike { self.sendAdaptiveFeedbackOnQueue() }
            }
        }
        decoder.onDecodeCompleted = {
            [weak self] sequence, generation, succeeded in
            guard let self else { return }
            self.networkQueue.async {
                let networkGeneration: UInt64
                if let owner = self.currentConnectionDecoder, owner.decoder == generation { networkGeneration = owner.network }
                else if let owner = self.currentCaptureTargetDecoderOwner, owner.decoder == generation { networkGeneration = owner.generation }
                else if let owner = self.currentMirrorDecoderOwner, owner.decoder == generation { networkGeneration = owner.connection }
                else if generation & 0x8000_0000_0000_0000 == 0 { networkGeneration = generation }
                else { return }
                if succeeded {
                    self.observeCaptureContinuationOnQueue(sequence: sequence, decoder: generation, decoded: true, presented: false)
                }
                self.adaptiveDecodeCompletedOnQueue(sequence: sequence, decoder: generation, succeeded: succeeded)
                self.wifiMediaReceiver.decoderDidComplete(
                    sequence: sequence,
                    generation: networkGeneration,
                    succeeded: succeeded,
                    decoderGeneration: generation)
                if succeeded, let owner = self.currentConnectionDecoder, owner.decoder == generation,
                   owner.network == self.connectionGeneration, self.connectionVideoInFlight == sequence {
                    self.connectionVideoInFlight = nil
                    self.drainConnectionVideoOnQueue()
                }
            }
        }
        decoder.onFrameDropped = { [weak self] sequence, generation in
            guard let self else { return }
            self.transportTelemetry.recordDropped(
                sequence: sequence,
                generation: self.telemetryGeneration(forDecoder: generation))
            self.networkQueue.async { [weak self] in
                self?.connectionVideoDroppedOnQueue(sequence: sequence, decoder: generation)
            }
        }
        decoder.onMailboxAge = { [weak self] sequence, ageMs in
            self?.transportTelemetry.recordMailboxAge(sequence: sequence, ageMs: ageMs)
        }
        decoder.onRecoveryNeeded = { [weak self] in
            guard let self else { return }
            self.networkQueue.async {
                guard self.wireAuthenticatedGeneration == self.connectionGeneration, !self.captureAvailability.inputBlocked else { return }
                // The sequence-bearing drop callback owns recovery during handoff and its drain.
                if self.currentConnectionDecoder?.network == self.connectionGeneration,
                   self.connectionVideoStarted && (self.connectionHandoffInProgress || self.connectionVideoDraining) { return }
                if self.captureTargets.applied != nil {
                    self.recoverCaptureTargetDecodeRootOnQueue()
                } else {
                    self.requestVideoRecoveryOnQueue()
                }
            }
        }
        if let pcConfirmed = trustedHostCleanup.values.first {
            trustedHostForgetOutcome = .cleanupIncomplete(pcConfirmed: pcConfirmed)
        }
        refreshReceivedFiles()
    }

    // MARK: - Public API

    deinit {
        pendingTrustedHostForget?.timeout.cancel()
        remoteClipboardTimer?.cancel()
        connectionStatusTimer?.cancel()
        qualityFeedbackTimer?.cancel()
        connectionProof?.erase()
        usbIdentityDeadline?.cancel()
        usbControlTLSUpgrade?.removeRegistration()
    }

    public func setDesiredPipelineMode(_ mode: PipelineMode) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.desiredPipelineMode = mode
            self.committedPipelineMode.request(mode)
            if !self.remoteInputConnection, self.qualitySession?.current != nil {
                self.qualityPolicyDirty=true; self.sendAdaptivePolicyOnQueue(auto:self.qualityAutoOptIn); return
            }
            guard self.wireAuthenticatedGeneration ==
                    self.connectionGeneration else { return }
            self.sendDesiredPipelineMode(reason: "user_preference")
        }
    }

    /// Connect to the Windows host over TLS using an NWEndpoint directly (e.g. from Bonjour discovery).
    /// - Parameter endpoint: The resolved NWEndpoint (service endpoint or hostPort)
    public func connect(to endpoint: NWEndpoint) {
        connect(to: endpoint, legacyHost: nil)
    }

    private func connect(to endpoint: NWEndpoint, legacyHost: String?) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard self.transportState == .idle || self.isDisconnectedOnQueue,
                  self.pendingTrustedHostForget == nil,
                  !self.wifiTargetHasPendingCleanup(endpoint) else { return }
            self.remoteSecureControlIntent = false
            if let target = WifiReconnectTargetPolicy.target(from: endpoint) {
                WifiReconnectTargetStore.save(target, defaults: self.streamSettingsDefaults)
                if let legacyHost { self.streamSettingsDefaults.set(legacyHost, forKey: Self.lastKnownHostKey) }
            }
            self.triedWifiReconnectTargets.removeAll()
            self.publishAutoReconnectAttempt(0)
            self.connectOnQueue(to: endpoint)
        }
    }

    /// The last Wi-Fi PC (saved target, or the legacy typed host) can be reconnected to.
    public var hasReconnectTarget: Bool {
        savedWifiReconnectTarget?.endpoint != nil
    }

    private var savedWifiReconnectTarget: WifiReconnectTarget? {
        WifiReconnectTargetSelection.preferred(
            structured: WifiReconnectTargetStore.load(defaults: streamSettingsDefaults),
            legacyHost: streamSettingsDefaults.string(forKey: Self.lastKnownHostKey))
    }

    func updateDiscoveredWifiEndpoints(_ endpoints: [NWEndpoint]) {
        networkQueue.async { [weak self] in self?.discoveredWifiEndpoints = endpoints }
    }

    /// One-tap Reconnect on the connect screen: the same endpoint automatic reconnects use.
    public func reconnectLastPC() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.publishAutoReconnectAttempt(0)
            self.connectSavedWifiOnQueue()
        }
    }

    private func publishAutoReconnectAttempt(_ attempt: Int) {
        DispatchQueue.main.async { self.autoReconnectAttempt = attempt }
    }

    private func connectOnQueue(to endpoint: NWEndpoint, expectedFingerprint: String? = nil) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if let expectedFingerprint, trustedHostCleanup[expectedFingerprint] != nil { return }
        guard !wifiTargetHasPendingCleanup(endpoint) else { return }
        let rollingBack = connectionSwitch.pending?.rollingBack == true
        guard !rollingBack || connectionSwitch.pending?.rollbackRoute == .wifi && endpoint == connectionSelectedEndpoint else { return }
        reconnectEnabled = !connectionHandoffInProgress
        guard transportState == .idle || isDisconnectedOnQueue else { return }
        committedConnectionRoute = .wifi
        pairedControlGeneration = nil; trustedProofGeneration = nil; connectionAdvertisement = 0
        usbIdentity = USBSessionIdentityProof(); usbReadinessPongWrittenGeneration = nil
        usbIdentityDeadline?.cancel(); usbIdentityDeadline = nil
        if !connectionHandoffInProgress { resetConnectionControlOnQueue() }
        connectionSelectedEndpoint = endpoint
        expectedWifiReconnectFingerprint = expectedFingerprint

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
        wifiAuthentication = WifiAuthenticationState()
        reconnectWorkItem?.cancel()
        resetDisplaySession()
        let parameters = buildTLSParameters(for: endpoint, expectedFingerprint: expectedFingerprint)
        let newConnection = NWConnection(to: endpoint, using: parameters)
        connection = newConnection
        if connectionHandoffInProgress { logSwitch(.dial, route: .wifi) }

        setupStateHandler(for: newConnection)
        setState(.connecting)
        if !connectionHandoffInProgress { print("[IPAD][TCP_CONNECT] transport=wifi generation=\(connectionGeneration)") }
        connectionTimeoutWorkItem?.cancel()
        let generation = connectionGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation, self.transportState == .connecting else { return }
            if self.connectionHandoffInProgress {
                if self.connectionSwitch.pending?.rollingBack == true { self.recoverConnectionControlOnQueue(.connectionLost) }
                else { self.recoverConnectionControlOnQueue(.peerTimeout) }
                return
            }
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
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(
            host: RemoteHostAddress.networkHost(host),
            port: port
        )
        connect(to: endpoint, legacyHost: host)
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
            self.refreshClipboardOnQueue()
            self.updateRemoteAudioSuspensionOnQueue()
            self.remoteFileBackgrounded = false
            self.publishRemoteFileAccessOnQueue()
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
            if self.connectionSwitch.pending != nil {
                self.connectionStatusTickOnQueue()
                return
            }
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
            RecentWifiResumeStore.clear(defaults: self.streamSettingsDefaults)

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

            if !self.usbListenerExplicitlyStarted, self.activeTransportKind == .wifi,
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
                self.scheduleAutoReconnect()
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
            self.refreshClipboardOnQueue(forceDisable: true)
            self.updateRemoteAudioSuspensionOnQueue()
            self.publishRemoteFileAccessOnQueue()
            self.manualReconnectPresentation = nil
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
            self.refreshClipboardOnQueue(forceDisable: true)
            self.updateRemoteAudioSuspensionOnQueue()
            self.backgroundRemoteFilesOnQueue()
            self.manualReconnectPresentation = nil
            // Foreground eligibility is closed first; discard its old sample window.
            self.transportTelemetry.beginFreshFrameRate(
                generation: self.connectionGeneration, at: self.performanceFeedbackTime())
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.wifiBackgroundDisconnectWorkItem?.cancel()
            self.wifiBackgroundDisconnectWorkItem = nil

            // The handoff owns its listener, decoder and deadline across this transition.
            if self.connectionSwitch.pending != nil {
                self.wifiLifecycleTransitionGeneration = nil
                self.connectionStatusTickOnQueue()
                return
            }

            guard !self.usbListenerExplicitlyStarted, self.activeTransportKind != .usb else {
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
                        isUSB: self.activeTransportKind == .usb,
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
            guard self.wifiAuthentication.confirm() else { return }
            self.hostIdentityConfirmed = true
            self.hostIdentityConfirmationRequired = false
            self.sendTrustedClientHello(generation: self.connectionGeneration)
        }
    }

    /// Sends the 4-digit PIN to the server as an 8-byte AuthPacketHeader.
    /// A rejected PIN can be retried. A pending submission owns the next result.
    public func sendAuthPIN(_ pin: String) {
        networkQueue.async { [weak self] in
            guard let self,
                  (self.transportState == .awaitingPIN || self.isAuthFailedOnQueue),
                  self.activeTransportKind == .wifi, self.hostIdentityConfirmed,
                  self.wifiAuthentication.stage == .pin,
                  let pinValue = UInt32(pin), pin.count == 4 else { return }
            self.setState(.submittingPIN)
            var packet = Data(count: AuthProtocol.packetSize)
            packet.withUnsafeMutableBytes { buf in
                buf.storeBytes(of: AuthProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
                buf.storeBytes(of: pinValue.littleEndian, toByteOffset: 4, as: UInt32.self)
            }
            let generation = self.connectionGeneration
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, generation == self.connectionGeneration,
                      self.transportState == .submittingPIN else { return }
                self.handleStreamError("PIN response timed out.")
            }
            self.pinResponseDeadline = deadline
            self.networkQueue.asyncAfter(deadline: .now() + 30, execute: deadline)
            self.enqueueControlData(packet) { [weak self] error in
                guard let self, generation == self.connectionGeneration,
                      self.pinResponseDeadline === deadline else { return }
                if error != nil {
                    self.handleStreamError("PIN send failed.")
                } else {
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
        let requestedGeneration = connectionGenerationClock.current
        let requestedRevision = mirrorControl.gestureRevision
        let mayStart = mirrorControl.allowsLegacyVirtualInput
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
            guard let self, requestedGeneration == self.connectionGeneration else { return }
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
            } else if type != .up && self.displayRequestGate.isInputSuppressed {
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
            guard self.legacyInputLifetime.accept(kind: .pencil, payload: packet,
                generation: requestedGeneration, revision: 0,
                mayStart: mayStart && requestedRevision == self.mirrorControl.gestureRevision && self.mirrorControl.allowsLegacyVirtualInput && !self.displayRequestGate.isInputSuppressed) else { return }
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
        let requestedRevision = mirrorControl.gestureRevision
        let requestedInputToken = remoteInputContext?.token
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration,
                  requestedRevision == self.mirrorControl.gestureRevision, self.mirrorControl.allowsLegacyVirtualInput else { return }
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
        let requestedGeneration = connectionGenerationClock.current
        let requestedRevision = mirrorControl.gestureRevision
        let mayStart = mirrorControl.allowsLegacyVirtualInput
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration else { return }
            let generation = requestedGeneration
            guard self.transportState == .streaming,
                  self.committedTransportGeneration == generation,
                  command.virtualKey != 0,
                  KeyboardInputDeliveryPolicy.maySend(
                    action: command.action,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else { return }
            guard !self.remoteInputConnection || self.remoteFeatures.accepted & 1 == 0 else { return }
            guard self.legacyInputLifetime.accept(kind: .keyboard, payload: command.encode(),
                generation: requestedGeneration, revision: 0,
                mayStart: mayStart && requestedRevision == self.mirrorControl.gestureRevision && self.mirrorControl.allowsLegacyVirtualInput && !self.displayRequestGate.isInputSuppressed) else { return }
            self.sendWireMessage(
                type: .keyboardInput,
                payload: command.encode(),
                sequence: 0,
                movement: false)
        }
    }

    private func beginRemoteFeaturesAfterAuthentication(generation: UInt64) {
        guard remoteInputConnection else { return }
        let pairingPending = activeTransportKind == .wifi &&
            (wifiAuthentication.stage == .paired || wifiAuthentication.stage == .trusted)
        if remoteClipboardPreference && pairingPending {
            // The host sends AuthResult before PairingSuccess or TrustedAuthResult.
            // Keep enhanced input available if an older host omits that second message.
            networkQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.beginRemoteFeaturesOnQueue(generation: generation)
            }
        } else {
            beginRemoteFeaturesOnQueue(generation: generation)
        }
    }

    private func beginRemoteFeaturesOnQueue(generation: UInt64) {
        guard generation == connectionGeneration, wireAuthenticatedGeneration == generation,
              remoteInputConnection, remoteFeatures.begin(now: ProcessInfo.processInfo.systemUptime) else { return }
        _ = sendClientPing(force: true, purpose: .telemetry, remoteFeaturesProbe: true)
        scheduleRemoteFeaturesTimeout(generation: generation)
    }

    private func scheduleRemoteFeaturesTimeout(generation: UInt64) {
        guard let deadline = remoteFeatures.nextPongDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        networkQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  self.wireAuthenticatedGeneration == generation, self.remoteInputConnection else { return }
            if self.remoteFeatures.expire(now: ProcessInfo.processInfo.systemUptime) {
                _ = self.sendClientPing(force: true, purpose: .telemetry, remoteFeaturesProbe: true)
            }
            self.scheduleRemoteFeaturesTimeout(generation: generation)
            if self.remoteFeatures.negotiationSettled, self.remoteSecureDesktopEnabled { self.beginAdaptiveProbeOnQueue() }
        }
    }

    private func publishRemoteInputOnQueue(contextChanged: Bool = true) {
        publishRemoteFileAccessOnQueue()
        if remoteClipboardLease.nonce != nil { tickRemoteClipboard() }
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
        castingClipboardRoute = nil
        castingClipboardParserGeneration = nil
        resetRemoteClipboard()
        remoteSecureDesktop = RemoteSecureDesktopState()
        remoteTimedVideoLatched = false
        remoteTimedVideoNeedsIDR = false
        remoteTimedVideo.reset()
        remoteVideoTiming.reset()
        remoteAudio = RemoteAudioSession()
        remoteAudioRequested = false
        remoteAudioFeaturesReceived = false
        remoteAudioOutputFailed = false
        updateRemoteAudioPlaybackOnQueue()
        publishRemoteSecureDesktopOnQueue()
        remoteFileAccess = nil
        retireRemoteFileIOOnQueue()
        remoteFilePacing = RemoteFileMediaPacing()
        remoteFeatures = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
        remoteMonitors.begin(session: UUID(), acceptedFeatures: 0)
        remoteMonitorControl.update(generation: 0, context: nil, enabled: false)
        remoteMonitorAdmission = nil
        publishRemoteInputOnQueue()
    }

    func setRemoteSecureControl(_ enabled: Bool) {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, self.wireAuthenticatedGeneration == generation,
                  self.connectionGeneration == generation, !enabled || self.isForegroundActive,
                  let request = self.remoteSecureDesktop.setControl(enabled) else { return }
            self.remoteSecureControlIntent = enabled
            if !enabled && self.remoteSecureDesktop.desktop != .standard {
                self.fenceRemoteSecureDesktopOnQueue(.fence)
            } else {
                self.publishRemoteSecureDesktopOnQueue()
            }
            self.sendRemoteSecureDesktopOnQueue(request)
        }
    }

    private func publishRemoteSecureDesktopOnQueue() {
        let secure = remoteSecureDesktop, generation = connectionGeneration
        let publication = remoteSecureDesktopPublicationClock.advance()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation,
                  self.remoteSecureDesktopPublicationClock.current == publication else { return }
            self.remoteSecureDesktopSupported = secure.supported
            self.remoteSecureDesktopCovered = secure.covered
            self.remoteSecureDesktopControl = secure.control
            self.remoteSecureDesktopCanSas = secure.canSas
        }
    }

    private func sendRemoteSecureDesktopOnQueue(_ message: RemoteSecureDesktopProtocol.Message) {
        guard let payload = RemoteSecureDesktopProtocol.encode(message) else { return }
        sendWireMessage(type: message.type, payload: payload, sequence: 0)
    }

    private func receiveRemoteSecureDesktopOnQueue(_ header: WireHeader, payload: Data) {
        guard remoteInputConnection, remoteSecureDesktop.supported,
              let message = RemoteSecureDesktopProtocol.decode(type: header.type, payload: payload, flags: header.flags) else {
            handleStreamError("Invalid secure desktop state."); return
        }
        if case let .sasAvailability(available) = message {
            remoteSecureDesktop.updateSasAvailability(available)
            publishRemoteSecureDesktopOnQueue()
            return
        }
        let change = remoteSecureDesktop.receive(message, adaptiveOwner: qualitySession?.owner != nil,
                                                timedVideo: remoteTimedVideoLatched)
        fenceRemoteSecureDesktopOnQueue(change)
        if change != .reconnect, case let .state(_, .firstFrame, _, _, _, _, _, sequence) = message {
            let generation = connectionGeneration
            networkQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.connectionGeneration == generation,
                      self.remoteSecureDesktop.awaitsWireIDR(sequence: sequence) else { return }
                self.handleStreamError("Missing secure desktop first picture.")
            }
        }
    }

    private func fenceRemoteSecureDesktopOnQueue(_ change: RemoteSecureDesktopState.Change) {
        guard change != .unchanged else { return }
        resetRemoteTimedVideoOnQueue()
        updateRemoteAudioSuspensionOnQueue()
        decoder.fenceCaptureContinuation()
        captureTargetVideo.reset()
        connectionVideo.reset()
        remoteFeatures.invalidateInput()
        remoteMonitorAdmission = nil
        revokeRemoteFilesOnQueue()
        publishRemoteSecureDesktopOnQueue()
        publishRemoteInputOnQueue()
        if change == .reconnect {
            manualReconnectHealthy = false
            handleStreamError("Reconnecting after Windows desktop change.")
            return
        }
        guard nextMirrorDecoder != UInt64.max else { handleStreamError("Decoder identity exhausted."); return }
        nextMirrorDecoder += 1
        decoder.invalidate(waitForCompletion: false)
        decoder.clearAdaptiveMedia()
        decoder.beginSession(generation: nextMirrorDecoder)
    }

    private var remoteAudioHostID: Data? {
        guard remoteInputConnection, wireAuthenticatedGeneration == connectionGeneration,
              pairedControlGeneration == connectionGeneration else { return nil }
        return trustedCredential?.hostID
    }

    private var mayReceiveRemoteAudio: Bool {
        remoteAudioHostID != nil && remoteFeatures.accepted & RemoteFeatureNegotiation.remoteAudioFeature != 0
    }

    func setRemoteAudioPreferred(_ enabled: Bool) {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  self.remoteAudioFeaturesReceived, let hostID = self.remoteAudioHostID,
                  self.remoteAudio.preferred != enabled else { return }
            ClientStreamSettingsStore.saveRemoteAudio(enabled, hostID: hostID, defaults: self.streamSettingsDefaults)
            if !enabled { self.remoteAudioOutputFailed = false }
            self.sendRemoteAudioOnQueue(self.remoteAudio.prefer(enabled))
            self.updateRemoteAudioSuspensionOnQueue()
            if enabled, !self.remoteAudioRequested, let endpoint = self.connectionSelectedEndpoint {
                // SCST 61/62 is a one-time negotiation on each TLS connection.
                self.teardownCurrentSession()
                self.setState(.disconnected(reason: "Reconnecting to enable remote audio"))
                self.connectOnQueue(to: endpoint)
            }
        }
    }

    private func publishRemoteAudioOnQueue() {
        let preferred = remoteAudio.preferred
        let status: String?
        if !remoteAudioFeaturesReceived || remoteAudioHostID == nil {
            status = nil
        } else if !preferred {
            status = remoteAudioRequested ? "" : "Turning audio on requires a reconnect."
        } else if !mayReceiveRemoteAudio {
            status = "Remote audio is unavailable on this PC."
        } else if remoteAudioOutputFailed {
            status = "Audio output is unavailable. Turn remote audio off and on to retry."
        } else if remoteAudio.suspended {
            status = "Remote audio paused."
        } else if remoteAudio.pending != nil || remoteAudio.phase == .pending {
            status = "Waiting for remote audio…"
        } else {
            switch remoteAudio.phase {
            case .streaming: status = "Remote audio streaming."
            case .paused, .denied:
                switch remoteAudio.reason {
                case .policy, .revoked: status = "Remote audio blocked by PC policy."
                case .desktop, .session: status = "Remote audio paused on the PC."
                case .budget: status = "Remote audio paused for connection bandwidth."
                default: status = "The PC’s audio output is unavailable."
                }
            case .off, .pending: status = "Remote audio is off."
            }
        }
        let publication = remoteAudioPublicationClock.advance()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteAudioPublicationClock.current == publication else { return }
            if self.remoteAudioPreferred != preferred { self.remoteAudioPreferred = preferred }
            if self.remoteAudioStatus != status { self.remoteAudioStatus = status }
        }
    }

    private func updateRemoteAudioSuspensionOnQueue() {
        let request = remoteAudio.suspend(!isForegroundActive || remoteSecureDesktop.restrictsFeatures || remoteAudioOutputFailed)
        sendRemoteAudioOnQueue(request)
        updateRemoteAudioPlaybackOnQueue()
    }

    private func updateRemoteAudioPlaybackOnQueue() {
        let epoch = remoteAudio.activeEpoch, generation = connectionGeneration
        let timing = remoteAudioPlayback.setEpoch(epoch) { [weak self] in
            self?.networkQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation, self.remoteAudio.activeEpoch == epoch else { return }
                self.remoteAudioOutputFailed = true
                self.recordDiagnosticLine("[REMOTE_AUDIO] output=unavailable")
                self.updateRemoteAudioSuspensionOnQueue()
            }
        }
        if let timing {
            recordDiagnosticLine("[REMOTE_AUDIO] startupMs=\(timing.startupMs ?? -1) maximumVideoHoldMs=\(timing.maximumVideoHoldMs)")
        }
        publishRemoteAudioOnQueue()
    }

    private func sendRemoteAudioOnQueue(_ request: RemoteAudioSession.Request?) {
        guard let request, mayReceiveRemoteAudio,
              let payload = RemoteAudioProtocol.encode(.set(operation: request.operation, requestId: request.id)) else { return }
        sendWireMessage(type: .remoteAudioSet, payload: payload, sequence: 0)
    }

    private func admitRemoteAudioOnQueue(_ request: RemoteAudioSession.Request) -> Bool {
        guard remoteAudio.admit(request, now: ProcessInfo.processInfo.systemUptime) else { return false }
        let generation = connectionGeneration
        networkQueue.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self, self.connectionGeneration == generation, self.remoteAudio.pending == request else { return }
            let retry = self.remoteAudio.tick(now: ProcessInfo.processInfo.systemUptime)
            self.sendRemoteAudioOnQueue(retry)
            self.publishRemoteAudioOnQueue()
        }
        return true
    }

    private func resetRemoteTimedVideoOnQueue() {
        remoteTimedVideo.reset()
        remoteVideoTiming.reset()
    }

    private func recoverRemoteTimedVideoOnQueue() {
        resetRemoteTimedVideoOnQueue()
        remoteTimedVideoNeedsIDR = true
        decoder.fenceCaptureContinuation(requiringAuthorization: false)
    }

    func remoteVideoPresentationDeadline(sequence: UInt32, generation: UInt64, now: TimeInterval) -> TimeInterval {
        remoteVideoTiming.deadline(sequence: sequence, generation: generation, now: now, playback: remoteAudioPlayback)
    }

    private func receiveRemoteAudioOnQueue(_ message: WireMessage, generation: UInt64) {
        let header = message.header
        guard mayReceiveRemoteAudio, let value = RemoteAudioProtocol.decode(type: header.type, payload: message.payload,
                                                                           flags: header.flags, sequence: header.sequence) else {
            handleStreamError("Invalid remote audio framing.")
            return
        }
        switch value {
        case let .state(phase, reason, requestID, epoch, startUs):
            if phase == .streaming && !remoteTimedVideoLatched {
                guard !remoteSecureDesktop.restrictsFeatures else {
                    handleStreamError("Timed video started during a secure desktop transition.")
                    return
                }
                remoteTimedVideoLatched = true
                recoverRemoteTimedVideoOnQueue()
            }
            let previous = (remoteAudio.phase, remoteAudio.reason)
            let request = remoteAudio.receive(phase, reason: reason, requestID: requestID, epoch: epoch, startUs: startUs)
            if previous != (remoteAudio.phase, remoteAudio.reason) {
                recordDiagnosticLine("[REMOTE_AUDIO] phase=\(remoteAudio.phase.rawValue) reason=\(remoteAudio.reason.rawValue)")
            }
            sendRemoteAudioOnQueue(request)
            updateRemoteAudioPlaybackOnQueue()
        case let .packet(sequence, epoch, captureUs, opus):
            if remoteAudio.acceptPacket(sequence: sequence, epoch: epoch, captureUs: captureUs) {
                remoteAudioPlayback.enqueue(epoch: epoch, packet: .init(sequence: sequence, captureUs: captureUs, opus: opus))
            }
        case let .timedVideo(flags, frame, total, offset, captureUs, fragment):
            guard remoteTimedVideoLatched else {
                handleStreamError("Timed video arrived before remote audio streaming.")
                return
            }
            if offset == 0 && remoteTimedVideo.hasPartial { recoverRemoteTimedVideoOnQueue() }
            switch remoteTimedVideo.push(flags: flags, frame: frame, total: total, offset: offset,
                                         captureUs: captureUs, fragment: fragment, receivedAt: message.firstByteAt) {
            case .partial:
                break
            case .recover:
                recoverRemoteTimedVideoOnQueue()
            case .complete(let unit):
                if remoteTimedVideoNeedsIDR {
                    guard UInt16(unit.flags) & WireProtocol.videoFlagIDR != 0,
                          RemoteSecureDesktopState.hasIDR(unit.bytes, lengthPrefixed: true) else { return }
                    remoteTimedVideoNeedsIDR = false
                }
                let header = WireHeader(type: .video, flags: UInt16(unit.flags), payloadLength: unit.bytes.count, sequence: unit.frame)
                receiveWireVideoOnQueue(WireMessage(header: header, payload: unit.bytes, firstByteAt: unit.firstByteAt),
                                        generation: generation, timedCaptureUs: unit.captureUs)
            }
        case .set:
            handleStreamError("Unexpected client-direction remote audio request.")
        }
    }

    private func publishRemoteMonitorsOnQueue() {
        let snapshot = remoteMonitors
        let publication = remoteMonitorPublicationClock.advance()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteMonitorPublicationClock.current == publication else { return }
            self.remoteMonitorState = snapshot
        }
    }
    // MARK: - Session clipboard

    private typealias Clipboard = RemoteClipboardProtocol

    private struct CastingClipboardRoute: Equatable {
        let generation: UInt64
        let owner: ObjectIdentifier
        let mode: UInt8
    }

    private struct ClipboardPresentation: Equatable {
        let generation: UInt64
        let supported: Bool
        let grant: RemoteClipboardAuthority.Grant?
        let reason: Clipboard.Reason
    }

    @MainActor func setRemoteClipboardEnabled(_ enabled: Bool) {
        remoteClipboardEnabled = enabled
        streamSettingsDefaults.set(enabled, forKey: Clipboard.preferenceKey)
        if !enabled {
            remoteClipboardAuthority.update(nil, deadline: 0, transfer: nil)
            remoteClipboardPasteboard.setAutomatic(false)
            remoteClipboardPasteboard.update(supported: remoteClipboardPasteboard.supported, grant: nil, reason: .ok)
            clearClipboardMissedCopyNotice()
        }
        networkQueue.async { [weak self] in self?.refreshClipboardOnQueue(forceDisable: !enabled) }
    }

    @MainActor func setAutomaticClipboardSending(_ enabled: Bool) {
        automaticClipboardSending = enabled
        streamSettingsDefaults.set(enabled, forKey: Clipboard.automaticPreferenceKey)
        remoteClipboardPasteboard.setAutomatic(enabled)
        if !enabled {
            networkQueue.async { [weak self] in
                guard let self, self.remoteClipboardOutgoingAutomatic else { return }
                self.cancelRemoteClipboardTransfer(.superseded)
            }
        }
    }

    @MainActor func setRemoteClipboardSceneActive(_ active: Bool) {
        remoteClipboardAuthority.setSceneActive(active)
        if !active {
            remoteClipboardPasteboard.sceneDidResign()
            clearClipboardMissedCopyNotice()
        }
        networkQueue.async { [weak self] in self?.refreshClipboardOnQueue(forceDisable: !active) }
    }

    private var remoteClipboardPreference: Bool {
        streamSettingsDefaults.bool(forKey: Clipboard.preferenceKey)
    }

    private static func automaticClipboardPreference(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Clipboard.automaticPreferenceKey) as? Bool ?? true
    }

    private var wantsRemoteClipboard: Bool { remoteAudioHostID != nil && remoteClipboardPreference }

    private var remoteClipboardNegotiated: Bool {
        remoteAudioHostID != nil && remoteFeatures.accepted & Clipboard.features == Clipboard.features
    }

    private var currentCastingClipboardRoute: CastingClipboardRoute? {
        guard !remoteInputConnection, wireAuthenticatedGeneration == connectionGeneration,
              pairedControlGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              let owner = activeControlConnection, let mode = committedRealtimeMode else { return nil }
        return CastingClipboardRoute(generation: connectionGeneration, owner: ObjectIdentifier(owner), mode: mode)
    }

    private var castingClipboardNegotiated: Bool {
        guard let route = castingClipboardRoute else { return false }
        return route == currentCastingClipboardRoute && remoteClipboardLease.nonce != nil
    }

    private var clipboardNegotiated: Bool { remoteClipboardNegotiated || castingClipboardNegotiated }

    private var mayNegotiateCastingClipboard: Bool {
        remoteClipboardPreference && remoteClipboardAuthority.sceneActive && isForegroundActive &&
            !connectionSwitch.inputBlocked && !connectionHandoffInProgress && !captureAvailability.inputBlocked
    }

    private func refreshClipboardOnQueue(forceDisable: Bool = false) {
        if let route = castingClipboardRoute, route != currentCastingClipboardRoute ||
            (castingClipboardChallenge != nil && (forceDisable || !mayNegotiateCastingClipboard)) {
            castingClipboardRoute = nil
            resetRemoteClipboard()
        }
        if !forceDisable, castingClipboardRoute == nil, mayNegotiateCastingClipboard,
           let route = currentCastingClipboardRoute {
            let nonce = UUID().uuid
            let challenge = withUnsafeBytes(of: nonce) { Data($0) }
            castingClipboardRoute = route
            castingClipboardChallenge = challenge
            castingClipboardDeadline = ProcessInfo.processInfo.systemUptime + 2
            sendWireMessage(type: .ping, payload: challenge, sequence: 0, flags: Clipboard.castingCapability)
        }
        tickRemoteClipboard(forceDisable: forceDisable)
    }

    private func receiveCastingClipboardPong(_ payload: Data, flags: UInt16) -> Bool {
        guard !remoteInputConnection else { return false }
        let capability = flags == Clipboard.castingCapability
        guard let route = castingClipboardRoute, route == currentCastingClipboardRoute,
              let owner = activeControlConnection, let challenge = castingClipboardChallenge,
              capability || challenge == payload else {
            return capability
        }
        castingClipboardChallenge = nil
        guard capability, challenge == payload,
              ProcessInfo.processInfo.systemUptime < castingClipboardDeadline else { return true }
        guard mayNegotiateCastingClipboard else {
            castingClipboardRoute = nil
            return true
        }
        // USB identity can be proved over raw TCP. Only the nonsensitive probe may use that stream.
        #if targetEnvironment(simulator)
        let tls = castingClipboardTLSForTesting ?? (owner.metadata(definition: NWProtocolTLS.definition) is NWProtocolTLS.Metadata)
        #else
        let tls = owner.metadata(definition: NWProtocolTLS.definition) is NWProtocolTLS.Metadata
        #endif
        if tls { beginRemoteClipboard(casting: true) }
        return true
    }

    private var remoteClipboardEligible: Bool {
        guard clipboardNegotiated, remoteClipboardPreference, remoteClipboardAuthority.sceneActive,
              isForegroundActive, committedTransportGeneration == connectionGeneration,
              !captureAvailability.inputBlocked else { return false }
        if castingClipboardNegotiated {
            return mayNegotiateCastingClipboard && mirrorControl.ownsClipboardControl
        }
        return remoteFeatures.inputReady && remoteFeatures.context?.desktop == 1 && !remoteSecureDesktop.restrictsFeatures
    }

    private var remoteClipboardGrant: RemoteClipboardAuthority.Grant? {
        guard let state = remoteClipboardLease.grant, remoteClipboardEligible,
              ProcessInfo.processInfo.systemUptime < remoteClipboardLease.validUntil else { return nil }
        return RemoteClipboardAuthority.Grant(token: state.token, epoch: state.epoch,
                                               directions: state.directions, maxBytes: state.maxBytes)
    }

    private func beginRemoteClipboard(casting: Bool = false) {
        guard casting || remoteClipboardNegotiated, let hello = remoteClipboardLease.start(),
              let nonce = remoteClipboardLease.nonce else { return }
        // On a same-stream route change, parse bounded late frames and drop them in the lease handler.
        if casting { castingClipboardParserGeneration = connectionGeneration }
        sendWireMessage(type: casting ? .castingClipboardHello : hello.type, payload: hello.encode(), sequence: 0) { [weak self] error in
            guard let self, error != nil, self.remoteClipboardLease.nonce == nonce else { return }
            if casting { self.castingClipboardRoute = nil }
            self.resetRemoteClipboard()
        }
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tickRemoteClipboard() }
        remoteClipboardTimer = timer
        timer.resume()
        publishRemoteClipboard(supported: true)
    }

    private func resetRemoteClipboard() {
        castingClipboardChallenge = nil
        castingClipboardDeadline = 0
        remoteClipboardTimer?.cancel()
        remoteClipboardTimer = nil
        remoteClipboardLease = RemoteClipboardLease()
        remoteClipboardCounter = 0
        retireRemoteClipboardGrant()
        publishRemoteClipboard(supported: false)
    }

    private func retireRemoteClipboardGrant() {
        clearRemoteClipboardTransfer()
        remoteClipboardPeerOrigin = nil
        remoteClipboardPeerCounter = 0
        remoteClipboardSeenUpdates.removeAll()
        remoteClipboardStatusHistory.removeAll()
    }

    private func updateRemoteClipboardFence() {
        let state = remoteClipboardGrant != nil ? remoteClipboardLease.grant : nil
        remoteClipboardAuthority.update(state, deadline: remoteClipboardLease.validUntil,
                                        transfer: remoteClipboardTransfer)
    }

    private func publishRemoteClipboard(supported: Bool) {
        updateRemoteClipboardFence()
        let result = ClipboardPresentation(generation: connectionGeneration, supported: supported,
                                           grant: remoteClipboardGrant, reason: remoteClipboardLease.reason)
        let previous = remoteClipboardPresentation
        guard previous != result else { return }
        remoteClipboardPresentation = result
        DispatchQueue.main.async { [weak self] in
            guard let self, !result.supported || self.connectionGenerationClock.current == result.generation else { return }
            self.remoteClipboardPasteboard.update(supported: result.supported, grant: result.grant, reason: result.reason)
            if previous?.grant != result.grant {
                self.clearClipboardMissedCopyNotice()
                if result.grant != nil { self.remoteClipboardPasteboard.setAutomatic(self.automaticClipboardSending) }
            }
        }
    }

    private func tickRemoteClipboard(forceDisable: Bool = false) {
        guard remoteClipboardLease.nonce != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = remoteClipboardLease.grant
        let signal = remoteClipboardLease.tick(eligible: !forceDisable && remoteClipboardEligible, now: now,
                                               requestTimeout: castingClipboardNegotiated ? 15 : 3)
        if previous != remoteClipboardLease.grant { retireRemoteClipboardGrant() }
        if let signal { sendWireMessage(type: signal.type, payload: signal.encode(), sequence: 0) }
        publishRemoteClipboard(supported: clipboardNegotiated)
        if remoteClipboardTransfer?.expired(now: now) == true {
            cancelRemoteClipboardTransfer(.timeout)
        }
    }

    private func remoteClipboardPacketIsCurrent(_ data: Data, startingWrite: Bool = false) -> Bool {
        guard data.count >= WireProtocol.headerSize, Self.isClipboardPacket(data[5], flags: Self.wireFlags(data)),
              let type = WireMessageType(rawValue: data[5]) else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let payload = data.dropFirst(WireProtocol.headerSize)
        if type == .ping {
            return castingClipboardRoute == currentCastingClipboardRoute && castingClipboardChallenge == payload &&
                now < castingClipboardDeadline && mayNegotiateCastingClipboard
        }
        let codecType = type == .castingClipboardHello ? .clipboardHello : type
        guard clipboardNegotiated, let message = Clipboard.decode(type: codecType, payload: payload) else { return false }
        switch message {
        case .hello(_, _, _, let nonce):
            return remoteClipboardLease.nonce == nonce && (type == .castingClipboardHello
                ? castingClipboardNegotiated && now < castingClipboardDeadline && mayNegotiateCastingClipboard
                : remoteClipboardNegotiated)
        case .control(let action, _, let id, _, let nonce):
            guard remoteClipboardLease.nonce == nonce, action == .disable || remoteClipboardEligible,
                  remoteClipboardLease.mayWrite(action, id: id, now: now) else { return false }
            if startingWrite, action == .renew {
                guard remoteClipboardLease.admitRenew(id, now: now) else { return false }
                updateRemoteClipboardFence()
            }
            return true
        default:
            guard let grant = remoteClipboardGrant, let prefix = message.prefix,
                  grant.token == prefix.token, grant.epoch == prefix.epoch else { return false }
            switch message {
            case .cancel, .result, .response(_, false, _, _): return true
            default:
                return remoteClipboardTransfer?.offer.prefix == prefix &&
                    (!remoteClipboardOutgoingAutomatic || Self.automaticClipboardPreference(in: streamSettingsDefaults))
            }
        }
    }

    private static func wireFlags(_ data: Data) -> UInt16 { UInt16(data[6]) | UInt16(data[7]) << 8 }

    private static func isClipboardPacket(_ type: UInt8, flags: UInt16) -> Bool {
        (84...92).contains(type) || type == WireMessageType.castingClipboardHello.rawValue ||
            (type == WireMessageType.ping.rawValue && flags == Clipboard.castingCapability)
    }

    private func sendRemoteClipboard(_ message: Clipboard.Message, completion: @escaping (Bool) -> Void = { _ in }) {
        sendWireMessage(type: message.type, payload: message.encode(), sequence: 0, bulk: true) { error in
            completion(error == nil)
        }
    }

    @MainActor private func clearClipboardMissedCopyNotice() {
        clipboardNoticeTask?.cancel()
        clipboardNoticeTask = nil
        if clipboardMissedCopyNotice != nil { clipboardMissedCopyNotice = nil }
    }

    private func noticeMissedClipboardCopy(grant: RemoteClipboardAuthority.Grant) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteClipboardAuthority.allows(grant, direction: 2) else { return }
            self.clipboardMissedCopyNotice = "A copy on the PC was missed - copy it again"
            self.clipboardNoticeTask?.cancel()
            self.clipboardNoticeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.clearClipboardMissedCopyNotice()
            }
        }
    }

    private func recordClipboardUpdate(_ id: UUID) -> Bool {
        guard !remoteClipboardSeenUpdates.contains(id), !remoteClipboardStatusHistory.contains(id) else { return false }
        remoteClipboardSeenUpdates.append(id)
        if remoteClipboardSeenUpdates.count > 128 { remoteClipboardSeenUpdates.removeFirst() }
        // A late transfer cancel must not become a missed-copy notice after replay-cache eviction.
        if remoteClipboardStatusHistory.count < Self.clipboardStatusHistoryLimit {
            remoteClipboardStatusHistory.insert(id)
        }
        return true
    }

    private func noticeRemoteClipboard(_ notice: String?, grant: RemoteClipboardAuthority.Grant) {
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.remoteClipboardPasteboard.setTransferNotice(notice, grant: grant)
        }
    }

    private func clearRemoteClipboardTransfer() {
        let hadTransfer = remoteClipboardTransfer != nil
        remoteClipboardTransfer = nil
        remoteClipboardOutgoingAutomatic = false
        updateRemoteClipboardFence()
        if hadTransfer {
            controlChannelWriter.discardPending(where: { [weak self] data in
                guard let self, data.count >= WireProtocol.headerSize, (87...92).contains(data[5]) else { return false }
                return !self.remoteClipboardPacketIsCurrent(data)
            }, error: .posix(.ECANCELED))
        }
    }

    private func cancelRemoteClipboardTransfer(_ reason: Clipboard.Reason) {
        guard let transfer = remoteClipboardTransfer else { return }
        clearRemoteClipboardTransfer()
        if let grant = remoteClipboardGrant {
            sendRemoteClipboard(.cancel(transfer.offer.prefix, reason))
            if reason != .superseded { noticeRemoteClipboard("Clipboard transfer ended.", grant: grant) }
        }
    }

    private func offerRemoteClipboard(grant: RemoteClipboardAuthority.Grant, revision: Int, content: RemoteClipboardContent,
                                      automatic: Bool) {
        guard remoteClipboardGrant == grant, grant.directions & 1 != 0,
              !automatic || Self.automaticClipboardPreference(in: streamSettingsDefaults),
              let state = remoteClipboardLease.grant, state.formats & content.format.rawValue != 0,
              content.bytes.count <= state.maxBytes, let origin = remoteClipboardLease.nonce else { return }
        let prefix = Clipboard.Prefix(token: grant.token, epoch: grant.epoch, update: UUID())
        guard recordClipboardUpdate(prefix.update) else { return }
        cancelRemoteClipboardTransfer(.superseded)
        remoteClipboardCounter += 1
        let offer = Clipboard.Offer(prefix: prefix, format: content.format, formats: content.formats,
                                    length: content.bytes.count, origin: origin, counter: remoteClipboardCounter,
                                    revision: UInt64(truncatingIfNeeded: revision), digest: content.digest)
        remoteClipboardTransfer = RemoteClipboardTransfer(offer: offer, outgoingBytes: content.bytes,
                                                          now: ProcessInfo.processInfo.systemUptime)
        remoteClipboardOutgoingAutomatic = automatic
        updateRemoteClipboardFence()
        noticeRemoteClipboard("Sending clipboard?", grant: grant)
        sendRemoteClipboard(.offer(offer)) { [weak self] sent in self?.remoteClipboardSendCompleted(prefix, sent: sent) }
    }

    private func remoteClipboardSendCompleted(_ prefix: Clipboard.Prefix, sent: Bool) {
        if !sent, remoteClipboardTransfer?.offer.prefix == prefix { cancelRemoteClipboardTransfer(.busy) }
    }

    private func sendNextRemoteClipboardChunk(_ prefix: Clipboard.Prefix) {
        guard remoteClipboardGrant != nil, let state = remoteClipboardLease.grant,
              let transfer = remoteClipboardTransfer, transfer.offer.prefix == prefix,
              let next = transfer.next(maxChunk: state.maxChunk, now: ProcessInfo.processInfo.systemUptime) else { return }
        sendRemoteClipboard(next) { [weak self] sent in
            guard let self else { return }
            if sent { self.sendNextRemoteClipboardChunk(prefix) }
            else { self.remoteClipboardSendCompleted(prefix, sent: false) }
        }
    }

    private func receiveRemoteClipboard(type: WireMessageType, flags: UInt16, payload: Data) {
        if !remoteInputConnection, !castingClipboardNegotiated { return }
        guard clipboardNegotiated, let message = Clipboard.decode(type: type, payload: payload, flags: flags) else {
            handleStreamError("Invalid remote clipboard frame.")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if case .state(let state) = message {
            let previous = remoteClipboardLease.grant
            remoteClipboardLease.receive(state, eligible: remoteClipboardEligible, now: now)
            if previous != remoteClipboardLease.grant { retireRemoteClipboardGrant() }
            tickRemoteClipboard()
            return
        }
        guard let grant = remoteClipboardGrant, let state = remoteClipboardLease.grant,
              let prefix = message.prefix, grant.token == prefix.token, grant.epoch == prefix.epoch else { return }

        if case .offer(let offer) = message {
            acceptRemoteClipboardOffer(offer, grant: grant, state: state, now: now)
            return
        }
        guard let transfer = remoteClipboardTransfer, transfer.offer.prefix == prefix else {
            if case .cancel(_, let reason) = message, grant.directions & 2 != 0,
               reason == .clipboardBusy || reason == .timeout,
               remoteClipboardStatusHistory.count < Self.clipboardStatusHistoryLimit,
               remoteClipboardStatusHistory.insert(prefix.update).inserted {
                noticeMissedClipboardCopy(grant: grant)
            }
            return
        }
        if transfer.expired(now: now) { cancelRemoteClipboardTransfer(.timeout); return }
        switch message {
        case .response(_, let accepted, _, _):
            guard transfer.outgoing else { return }
            if !accepted {
                clearRemoteClipboardTransfer()
                noticeRemoteClipboard("The PC declined this clipboard item.", grant: grant)
            } else if transfer.accept(revision: 0, now: now) {
                sendNextRemoteClipboardChunk(prefix)
            }
        case .chunk(_, let index, let offset, let data):
            guard transfer.append(index: index, offset: offset, data: data, maxChunk: state.maxChunk, now: now) else {
                cancelRemoteClipboardTransfer(.invalidChunk); return
            }
        case .end(_, let length, let digest):
            guard let revision = transfer.revision, let bytes = transfer.finish(length: length, digest: digest, now: now) else {
                cancelRemoteClipboardTransfer(.hashMismatch); return
            }
            updateRemoteClipboardFence()
            prepareRemoteClipboardApply(transfer.offer, bytes: bytes, revision: revision, grant: grant)
        case .result(_, let applied, _, _):
            guard transfer.awaitingResult else { return }
            clearRemoteClipboardTransfer()
            noticeRemoteClipboard(applied ? "Clipboard sent to PC." : "The PC couldn?t apply this clipboard item.", grant: grant)
        case .cancel:
            clearRemoteClipboardTransfer()
            noticeRemoteClipboard(nil, grant: grant)
        default: break
        }
    }

    private func acceptRemoteClipboardOffer(_ offer: Clipboard.Offer, grant: RemoteClipboardAuthority.Grant,
                                           state: Clipboard.State, now: TimeInterval) {
        guard grant.directions & 2 != 0, (remoteClipboardPeerOrigin == nil || remoteClipboardPeerOrigin == offer.origin),
              offer.origin != remoteClipboardLease.nonce, offer.counter > remoteClipboardPeerCounter,
              recordClipboardUpdate(offer.prefix.update) else { return }
        remoteClipboardPeerOrigin = offer.origin
        remoteClipboardPeerCounter = offer.counter
        guard state.formats & offer.format.rawValue != 0, offer.length <= state.maxBytes else {
            sendRemoteClipboard(.response(offer.prefix, false, offer.length > state.maxBytes ? .tooLarge : .unsupportedFormat, 0))
            return
        }

        // The host serializes valid Offers across directions. This later Offer supersedes the old one.
        clearRemoteClipboardTransfer()
        remoteClipboardTransfer = RemoteClipboardTransfer(offer: offer, now: now)
        updateRemoteClipboardFence()
        noticeRemoteClipboard("Receiving clipboard?", grant: grant)
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            let revision = self.remoteClipboardPasteboard.revision(grant: grant, prefix: offer.prefix)
            self.networkQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation, self.remoteClipboardGrant == grant,
                      let transfer = self.remoteClipboardTransfer, transfer.offer.prefix == offer.prefix else { return }
                guard let revision, transfer.accept(revision: revision, now: ProcessInfo.processInfo.systemUptime) else {
                    self.cancelRemoteClipboardTransfer(.staleGrant)
                    return
                }
                self.sendRemoteClipboard(.response(offer.prefix, true, .ok, UInt64(truncatingIfNeeded: revision))) {
                    [weak self] sent in self?.remoteClipboardSendCompleted(offer.prefix, sent: sent)
                }
            }
        }
    }

    private func prepareRemoteClipboardApply(_ offer: Clipboard.Offer, bytes: Data, revision: Int,
                                             grant: RemoteClipboardAuthority.Grant) {
        let generation = connectionGeneration
        let authority = remoteClipboardAuthority
        let queued = remoteClipboardWorker.submit { [weak self] in
            guard authority.allows(grant, direction: 2, prefix: offer.prefix) else { return }
            let content = RemoteClipboardContent.prepare(bytes, format: offer.format, formats: offer.formats, fromWire: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGenerationClock.current == generation else { return }
                let finish: (Clipboard.Reason, Int) -> Void = { [weak self] reason, appliedRevision in
                    self?.networkQueue.async { [weak self] in
                        guard let self, self.connectionGeneration == generation, self.remoteClipboardGrant == grant,
                              self.remoteClipboardTransfer?.offer.prefix == offer.prefix else { return }
                        self.clearRemoteClipboardTransfer()
                        self.sendRemoteClipboard(.result(offer.prefix, reason == .ok, reason, UInt64(truncatingIfNeeded: appliedRevision)))
                        self.noticeRemoteClipboard(reason == .ok ? "Clipboard received from PC." : "This clipboard item couldn?t be applied.", grant: grant)
                    }
                }
                if let content {
                    self.remoteClipboardPasteboard.apply(content, revision: revision, grant: grant, prefix: offer.prefix, completion: finish)
                } else { finish(.unsupportedFormat, revision) }
            }
        }
        if !queued { cancelRemoteClipboardTransfer(.busy) }
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
    @MainActor public func requestRemoteMonitor(_ id: UInt64, catalogue: RemoteMonitorCatalogueCommand) {
        captureTargetRetireInput?()
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

    func retireIPadInputScope(expectedGeneration: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == expectedGeneration else { return }
            self.controlChannelWriter.discardPending { data in
                CaptureAvailabilityProtocol.isNewInputPacket(data) || self.isNewRemoteV2InputPacket(data)
            }
        }
    }

    private func isNewRemoteV2InputPacket(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let payload = Data(data.dropFirst(16))
        if data[5] == WireMessageType.remoteDirectTouch.rawValue { return RemoteDirectTouchCommand.decode(payload)?.terminal != true }
        if data[5] == WireMessageType.remotePointer.rawValue { return RemotePointerCommand.decode(payload).map { !($0.kind == 2 && $0.a == 1) } ?? true }
        if data[5] == WireMessageType.remoteScanKey.rawValue { return RemoteScanKeyCommand.decode(payload)?.action != 1 }
        if data[5] == WireMessageType.remoteCommittedText.rawValue { return true }
        return false
    }

    private func remoteInputPacketIsCurrent(_ data: Data) -> Bool {
        guard data.count >= 16, let type = WireMessageType(rawValue: data[5]) else { return true }
        if type == .remoteAudioSet {
            guard mayReceiveRemoteAudio,
                  case let .set(operation, id)? = RemoteAudioProtocol.decode(type: type, payload: Data(data.dropFirst(16))),
                  operation != .enable || !remoteSecureDesktop.restrictsFeatures else { return false }
            return admitRemoteAudioOnQueue(.init(operation: operation, id: id))
        }
        if !remoteInputConnection { return !(61...71).contains(type.rawValue) && type != .remoteDirectTouch }
        let payload = Data(data.dropFirst(16))
        if type == .remoteSecureDesktopRequest {
            guard let request = RemoteSecureDesktopProtocol.decode(type: type, payload: payload),
                  remoteSecureDesktop.admitRequest(request) else { return false }
            publishRemoteSecureDesktopOnQueue()
            return true
        }
        if type == .remoteCommand, payload.count == 3, payload[1] == RemoteHostCommand.secureAttention.rawValue {
            return remoteSecureDesktop.canSas
        }
        if remoteSecureDesktop.restrictsFeatures {
            switch type {
            case .remoteScanKey, .remotePointer:
                guard remoteSecureDesktop.allowsScanAndPointer else { return false }
            case .keyboardInput, .pointerInput, .textCommit, .directTouchContact, .remoteCommittedText,
                 .remoteDirectTouch, .iPadPointerV2, .remoteMonitorSelectRequest:
                return false
            default: break
            }
        }
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
            return remoteFeatures.maySend(feature: pointer.kind == 4 ? 0x12 : 2, token: pointer.token)
        case .remoteDirectTouch:
            guard let contact = RemoteDirectTouchCommand.decode(payload) else { return false }
            return remoteFeatures.maySend(feature: 8, token: contact.token) && remoteFeatures.context?.desktop == 1
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
                  self.remoteFeatures.maySend(feature: command.kind == 4 ? 0x12 : 2, token: command.token), let payload = command.encode() else { return }
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

    @MainActor func endRemoteFileControl(generation: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.revokeRemoteFilesOnQueue()
        }
    }

    private func resetDirectTouchSessionOnQueue() {
        legacyInputLifetime = InputLifetime()
        remoteDirectLifetime = InputLifetime()
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
        _ = legacyInputLifetime.accept(kind: .directTouch, payload: cancel.encode(),
            generation: connectionGeneration, revision: 0, mayStart: false)
        sendWireMessage(type: .directTouchContact, payload: cancel.encode(), sequence: 0)
    }

    func sendIPadPointerV2(_ command: IPadPointerV2Command, expectedGeneration: UInt64, revision: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == expectedGeneration,
                  self.wireAuthenticatedGeneration == expectedGeneration,
                  self.committedTransportGeneration == expectedGeneration, self.transportState == .streaming,
                  !self.remoteInputConnection, self.connectionAdvertisement & IPadPointerV2Command.capability != 0,
                  let payload = command.encode(),
                  command.terminal || !self.displayRequestGate.isInputSuppressed,
                  self.legacyInputLifetime.accept(kind: .iPadPointerV2, payload: payload,
                    generation: expectedGeneration, revision: 0,
                    mayStart: revision == self.mirrorControl.gestureRevision && self.mirrorControl.allowsLegacyVirtualInput && !self.captureAvailability.inputBlocked) else { return }
            self.sendWireMessage(type: .iPadPointerV2, payload: payload, sequence: 0)
        }
    }

    func sendRemoteDirectTouch(_ command: RemoteDirectTouchCommand, expectedGeneration: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.remoteInputConnection, self.connectionGeneration == expectedGeneration,
                  self.transportState == .streaming, self.committedTransportGeneration == expectedGeneration,
                  self.remoteFeatures.maySend(feature: 8, token: command.token), self.remoteFeatures.context?.desktop == 1,
                  command.terminal || (!self.displayRequestGate.isInputSuppressed && !self.captureAvailability.inputBlocked),
                  let payload = command.encode() else { return }
            let identity = DirectTouchContactCommand(phase: command.phase, pressure: 255, contactID: command.contactID, x: command.x,y: command.y)
            guard self.remoteDirectLifetime.accept(kind: .directTouch, payload: identity.encode(),
                generation: expectedGeneration, revision: command.token, mayStart: !self.captureAvailability.inputBlocked) else { return }
            self.sendWireMessage(type: .remoteDirectTouch, payload: payload, sequence: 0)
        }
    }

    public func sendDirectTouchContact(_ command: DirectTouchContactCommand) {
        let requestedGeneration = connectionGenerationClock.current
        let requestedRevision = mirrorControl.gestureRevision
        let mayStart = mirrorControl.allowsLegacyVirtualInput
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration,
                  self.transportState == .streaming,
                  self.committedTransportGeneration == requestedGeneration,
                  command.contactID != 0,
                  DirectTouchDeliveryPolicy.maySend(phase: command.phase,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else { return }
            if command.phase == .down {
                guard self.activeDirectTouchCommand == nil else { return }
            } else {
                guard self.activeDirectTouchCommand?.contactID == command.contactID else { return }
            }
            guard self.legacyInputLifetime.accept(kind: .directTouch, payload: command.encode(),
                generation: requestedGeneration, revision: 0,
                mayStart: mayStart && requestedRevision == self.mirrorControl.gestureRevision && self.mirrorControl.allowsLegacyVirtualInput && !self.displayRequestGate.isInputSuppressed) else { return }
            self.activeDirectTouchCommand = command.phase == .up || command.phase == .cancel ? nil : command
            self.sendWireMessage(type: .directTouchContact, payload: command.encode(), sequence: 0,
                movement: command.phase == .update)
        }
    }

    public func sendPointerInput(_ command: PointerInputCommand) {
        let requestedGeneration = connectionGenerationClock.current
        let requestedRevision = mirrorControl.gestureRevision
        let mayStart = mirrorControl.allowsLegacyVirtualInput
        networkQueue.async { [weak self] in
            guard let self, requestedGeneration == self.connectionGeneration else { return }
            let generation = requestedGeneration
            guard self.transportState == .streaming,
                  self.committedTransportGeneration == generation,
                  PointerInputDeliveryPolicy.maySend(
                    action: command.action,
                    inputSuppressed: self.displayRequestGate.isInputSuppressed) else {
                return
            }
            guard !self.remoteInputConnection || self.remoteFeatures.accepted & 2 == 0 else { return }
            guard self.legacyInputLifetime.accept(kind: .pointer, payload: command.encode(),
                generation: requestedGeneration, revision: 0,
                mayStart: mayStart && requestedRevision == self.mirrorControl.gestureRevision && self.mirrorControl.allowsLegacyVirtualInput && !self.displayRequestGate.isInputSuppressed) else { return }
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
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  !self.awaitingCastingSettingsIdentity else { return }
            if self.remoteInputConnection {
                let manual = desired.forSession(remote: true)
                if let hostID = self.qualityHostID {
                    ClientStreamSettingsStore.save(manual, hostID: hostID, remote: true, defaults: self.streamSettingsDefaults)
                }
                self.clientSettingsState.setDesired(manual)
                DispatchQueue.main.async {
                    guard self.connectionGenerationClock.current == generation else { return }
                    self.desiredBitrateMbps = manual.bitrateMbps
                }
                // Editing the fallback in Auto does not override host adaptation.
                guard !self.qualityAutoOptIn || !self.remoteQualityNegotiated else { return }
                self.remoteManualRestorePending = true
                self.remoteManualOverride = true
                self.restoreRemoteManualIfReady()
                return
            }
            let audioChanged = desired.audioEnabled != self.clientSettingsState.desired.audioEnabled
            let legacyAutoChanged = desired.adaptiveBitrateEnabled != self.clientSettingsState.desired.adaptiveBitrateEnabled
            ClientStreamSettingsStore.save(desired, hostID: self.qualityHostID, defaults: self.streamSettingsDefaults)
            self.clientSettingsState.setDesired(desired)
            DispatchQueue.main.async {
                guard self.connectionGenerationClock.current == generation else { return }
                self.desiredBitrateMbps = desired.bitrateMbps
                self.desiredAudioEnabled = desired.audioEnabled
                self.desiredAdaptiveBitrateEnabled = desired.adaptiveBitrateEnabled
            }
            if !self.remoteInputConnection, self.qualitySession?.current != nil, !audioChanged, !legacyAutoChanged {
                self.qualityPolicyDirty = true
                self.sendAdaptivePolicyOnQueue(auto:self.qualityAutoOptIn)
                return
            }
            if !self.remoteInputConnection, self.qualitySession?.current != nil {
                self.qualityPolicyDirty=self.qualityAutoOptIn; self.qualityOwnsPolicy=false
            }
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
            adaptiveBitrateEnabled: ClientStreamSettingsStore.load(defaults: streamSettingsDefaults).adaptiveBitrateEnabled)
    }

    @discardableResult
    private func sendDesiredSettingsIfPossible(
        reason: String
    ) -> DesiredSettingsSendResult {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard transportState == .streaming,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration,
              !awaitingCastingSettingsIdentity else {
            let result = DesiredSettingsSendResult.waitingForHost
            DispatchQueue.main.async {
                self.settingsApplyStatus = DesiredSettingsSendPolicy.status(for: result)
            }
            print("[IPAD][SETTINGS_SEND] result=waiting_for_host reason=\(reason)")
            return result
        }
        // Host effective DS2 bitrate/FPS is not a changed saved manual target.
        if !remoteInputConnection, qualityOwnsPolicy, qualitySession?.current != nil, reason != "user_change" {
            return .waitingForHost
        }
        let desired = clientSettingsState.desired.forSession(remote: remoteInputConnection, manualFallback: usesManualQualityFallback)
        let requestID = nextSettingsRequestID
        nextSettingsRequestID &+= 1
        let generation = clientSettingsState.generation
        let payload = ClientSettingsWireCodec.update(requestID: requestID,
            generation: generation, desired: desired, remote: remoteInputConnection)
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

    private func requestCurrentSettingsIfNeeded(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation,
              settingsSyncPolicy.shouldRequestSettings(
                committedGeneration: generation) else { return }
        let requestID = nextSettingsRequestID
        nextSettingsRequestID &+= 1
        print(
            "[IPAD][SETTINGS_SYNC_REQUEST] " +
            "generation=\(generation) request=\(requestID)")
        if remoteInputConnection { remoteSettingsGetID = requestID }
        sendWireMessage(
            type: .settingsGet,
            payload: ClientSettingsWireCodec.get(requestID: requestID),
            sequence: requestID)
    }

    public func forgetTrustedHost(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        forgetTrustedHost(endpoint: .hostPort(host: RemoteHostAddress.networkHost(host), port: port))
    }
    public func forgetTrustedHost(endpoint requestedEndpoint: NWEndpoint? = nil) {
        requestTrustedHostForget(endpoint: requestedEndpoint, useCurrentSession: false)
    }

    func forgetCurrentTrustedHost() {
        requestTrustedHostForget(endpoint: nil, useCurrentSession: true)
    }

    private func requestTrustedHostForget(endpoint requestedEndpoint: NWEndpoint?, useCurrentSession: Bool) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            let incumbent = self.trustedCredential
            let endpoint: NWEndpoint?
            let currentFingerprint: String?
            if useCurrentSession {
                endpoint = self.connection != nil && self.activeTransportKind == .wifi ? self.connectionSelectedEndpoint : nil
                currentFingerprint = incumbent.map(\.fingerprint).flatMap {
                    self.ownsTrustedHostSession($0) ? $0 : nil
                }
            } else {
                endpoint = requestedEndpoint ?? self.loadWifiReconnectEndpoint()
                currentFingerprint = nil
            }
            let fingerprint = currentFingerprint ?? endpoint.flatMap { self.trustedHostFingerprintStore.load(endpoint: $0) }
            guard let fingerprint else {
                let removed = self.reconnectTargetBelongsTo(endpoint: endpoint, fingerprint: nil)
                if removed { self.clearSavedReconnectTarget() }
                self.publishTrustedHostForgetOutcome(removed ? .savedTargetRemoved : .noSavedPairing)
                return
            }

            let generation = self.connectionGeneration
            guard self.transportState == .streaming, self.wireAuthenticatedGeneration == generation,
                  self.pairedControlGeneration == generation, !self.connectionHandoffInProgress,
                  let incumbent, incumbent.fingerprint == fingerprint,
                  self.ownsTrustedHostSession(fingerprint) else {
                self.removeLocalTrust(fingerprint, endpoint: endpoint, confirmed: false, closeSession: true)
                return
            }
            guard self.pendingTrustedHostForget == nil else { return }

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishPendingTrustedHostForget(generation: generation, confirmed: false)
            }
            self.pendingTrustedHostForget = PendingTrustedHostForget(
                fingerprint: fingerprint, endpoint: endpoint, generation: generation, timeout: timeout)
            self.networkQueue.asyncAfter(deadline: .now() + 2, execute: timeout)
            self.sendWireMessage(type: .forgetDevice, payload: Data([1]) + incumbent.deviceID, sequence: 0) { [weak self] error in
                if error != nil { self?.finishPendingTrustedHostForget(generation: generation, confirmed: false) }
            }
        }
    }

    @MainActor func dismissTrustedHostForgetOutcome() { trustedHostForgetOutcome = nil }

    func retryTrustedHostCleanup() {
        networkQueue.async { [weak self] in
            guard let self, let (fingerprint, pcConfirmed) = self.trustedHostCleanup.first else { return }
            self.removeLocalTrust(fingerprint, endpoint: nil, confirmed: pcConfirmed, closeSession: true)
        }
    }

    private func saveTrustedHostCleanup() {
        streamSettingsDefaults.set(trustedHostCleanup, forKey: Self.trustedHostCleanupKey)
    }

    private func wifiTargetHasPendingCleanup(_ endpoint: NWEndpoint) -> Bool {
        guard !trustedHostCleanup.isEmpty,
              let fingerprint = trustedHostFingerprintStore.fingerprintForCleanup(endpoint: endpoint) else { return false }
        return trustedHostCleanup[fingerprint] != nil
    }

    private func publishTrustedHostForgetOutcome(_ outcome: TrustedHostForgetOutcome) {
        DispatchQueue.main.async { self.trustedHostForgetOutcome = outcome }
    }

    private func ownsTrustedHostSession(_ fingerprint: String) -> Bool {
        guard connection != nil else { return false }
        if activeTransportKind == .wifi { return verifiedHostFingerprint == fingerprint }
        return pairedControlGeneration == connectionGeneration && trustedCredential?.fingerprint == fingerprint
    }

    private func reconnectTargetBelongsTo(endpoint: NWEndpoint?, fingerprint: String?) -> Bool {
        guard let target = savedWifiReconnectTarget, let savedEndpoint = target.endpoint else { return false }
        return endpoint.flatMap(WifiReconnectTargetPolicy.target(from:)) == target ||
            fingerprint != nil && trustedHostFingerprintStore.fingerprintForCleanup(endpoint: savedEndpoint) == fingerprint
    }

    private func clearSavedReconnectTarget() {
        WifiReconnectTargetStore.clear(defaults: streamSettingsDefaults)
        streamSettingsDefaults.removeObject(forKey: Self.lastKnownHostKey)
        RecentWifiResumeStore.clear(defaults: streamSettingsDefaults)
        reconnectEnabled = false
        triedWifiReconnectTargets.removeAll()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        publishAutoReconnectAttempt(0)
    }

    private func removeLocalTrust(_ fingerprint: String, endpoint: NWEndpoint?, confirmed: Bool, closeSession: Bool) {
        let ownsSelectedEndpoint = expectedWifiReconnectFingerprint == fingerprint ||
            connectionSelectedEndpoint.flatMap { trustedHostFingerprintStore.load(endpoint: $0) } == fingerprint
        let ownsSession = ownsTrustedHostSession(fingerprint) ||
            (ownsSelectedEndpoint && activeTransportKind == .wifi && connection != nil)
        let ownsSavedTarget = reconnectTargetBelongsTo(endpoint: endpoint, fingerprint: fingerprint)
        let wasPending = trustedHostCleanup[fingerprint] != nil
        let pcConfirmed = confirmed || trustedHostCleanup[fingerprint] == true
        // Record which pairing to block and retry before invalidating its lookup keys.
        trustedHostCleanup[fingerprint] = pcConfirmed
        saveTrustedHostCleanup()
        let credentialRemoved = trustedCredentialStore.delete(fingerprint: fingerprint)
        var outcome: TrustedHostForgetOutcome
        if credentialRemoved {
            usbTLSAdvertisedHosts.remove(fingerprint)
            if ownsSavedTarget { clearSavedReconnectTarget() }
            if ownsSelectedEndpoint {
                connectionSelectedEndpoint = nil
                expectedWifiReconnectFingerprint = nil
            }
            if trustedCredential?.fingerprint == fingerprint { trustedCredential = nil }
            if connectionSelectedCredential?.fingerprint == fingerprint { connectionSelectedCredential = nil }
            if trustedHostFingerprintStore.delete(fingerprint: fingerprint) {
                trustedHostCleanup.removeValue(forKey: fingerprint)
                saveTrustedHostCleanup()
                outcome = pcConfirmed ? .both : .localOnly
                if let remainingConfirmation = trustedHostCleanup.values.first {
                    outcome = .cleanupIncomplete(pcConfirmed: remainingConfirmation)
                }
            } else {
                outcome = .cleanupIncomplete(pcConfirmed: pcConfirmed)
            }
        } else if wasPending {
            outcome = .cleanupIncomplete(pcConfirmed: pcConfirmed)
        } else {
            trustedHostCleanup.removeValue(forKey: fingerprint)
            saveTrustedHostCleanup()
            outcome = .localFailed(pcConfirmed: pcConfirmed)
        }
        if closeSession && ownsSession {
            if activeTransportKind == .usb, let connection {
                teardownUsbSession(connection: connection, generation: connectionGeneration, reason: "pairing_removed")
            } else {
                teardownCurrentSession()
                setState(.idle)
            }
        }
        publishTrustedHostForgetOutcome(outcome)
    }

    private func finishPendingTrustedHostForget(generation: UInt64, confirmed: Bool, closeSession: Bool = true) {
        guard let pending = pendingTrustedHostForget, pending.generation == generation else { return }
        pendingTrustedHostForget = nil
        pending.timeout.cancel()
        removeLocalTrust(pending.fingerprint, endpoint: pending.endpoint, confirmed: confirmed,
                         closeSession: closeSession && generation == connectionGeneration)
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
        if let pending = connectionSwitch.pending { logSwitch(.userStop, route: pending.request.target, reason: .localOperation) }
        finishPendingTrustedHostForget(generation: connectionGeneration, confirmed: false, closeSession: false)
        resetUsbControlTLSOnQueue()
        remoteSecureControlIntent = false
        resetConnectionControlOnQueue()
        committedConnectionRoute = .unknown
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
        RecentWifiResumeStore.clear(defaults: streamSettingsDefaults)
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
        createOrdinaryUsbListenerOnQueue(port: port)
    }

    private func createOrdinaryUsbListenerOnQueue(port: UInt16) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        listenerGeneration &+= 1
        let generation = listenerGeneration

        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: USBControlTLSFramer.definition), at: 0)
            guard let listenerPort = NWEndpoint.Port(rawValue: port) else { throw USBListenerError.invalidPort }
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: listenerPort)
            let listener = try NWListener(using: parameters)
            usbListener = listener

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener,
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
                    if self.usbListenerExplicitlyStarted && self.connection == nil { self.setState(.listening) }
                    let completion = self.connectionListenerCompletion; self.connectionListenerCompletion = nil
                    self.connectionListenerPreparationAt = nil
                    completion?()
                    #if targetEnvironment(simulator)
                    self.connectionListenerReadyForTesting?()
                    #endif
                case .failed(let error):
                    if self.retireUSBListenerDuringWifiAttemptOnQueue() { return }
                    if self.connectionHandoffInProgress { self.recoverConnectionControlOnQueue(.listenerClosed); return }
                    if !self.usbListenerExplicitlyStarted {
                        self.rejectConnectionPreflightOnQueue(.listenerClosed); return
                    }
                    self.stop()
                    self.recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=failed port=\(port) reason=\(error)")
                    self.setState(.disconnected(
                        reason: "USB listener failed: \(error.localizedDescription)"))
                case .cancelled:
                    if self.retireUSBListenerDuringWifiAttemptOnQueue() { return }
                    if self.connectionHandoffInProgress { self.recoverConnectionControlOnQueue(.listenerClosed); return }
                    if !self.usbListenerExplicitlyStarted {
                        self.rejectConnectionPreflightOnQueue(.listenerClosed); return
                    }
                    self.stop()
                    self.recordUsbLifecycleDiagnostic("[USB_LISTENER_STATE] state=cancelled port=\(port) reason=listener_cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self, weak listener] newConnection in
                guard let self, let listener,
                      self.usbListener === listener,
                      generation == self.listenerGeneration else {
                    newConnection.cancel()
                    return
                }
                if self.handleConnectionSwitchUSBCandidateOnQueue(newConnection) { return }
                guard self.usbListenerExplicitlyStarted else { newConnection.cancel(); return }
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
            if connectionSwitch.pending?.rollbackRoute == .usb {
                failConnectionControlOnQueue(.listenerClosed); return
            }
            if !usbListenerExplicitlyStarted { rejectConnectionPreflightOnQueue(.listenerClosed); return }
            usbListenerExplicitlyStarted = false
            usbListener = nil
            setState(.disconnected(
                reason: "Unable to start USB listener: \(error.localizedDescription)"))
        }
    }

    private func installUsbCandidate(_ candidate: NWConnection, preserveContinuation: Bool = false) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if !preserveContinuation { resetConnectionControlOnQueue() }
        usbIdentity = USBSessionIdentityProof(); usbReadinessPongWrittenGeneration = nil
        usbIdentityDeadline?.cancel(); usbIdentityDeadline = nil
        pairedControlGeneration = nil; connectionAdvertisement = 0
        committedConnectionRoute = .usb
        _ = connectionGenerationClock.advance()
        resetAutoAcceptOnQueue()
        advanceReceivedRevisionOnQueue()
        resetDirectTouchSessionOnQueue()
        clientSettingsState.resetHostGeneration()
        settingsReconciliationGate.reset()
        usbScdpConnection = candidate
        connection = candidate
        if connectionHandoffInProgress { logSwitch(.dial, route: .usb) }
        prepareUsbControlTLSOnQueue(candidate)
        recordUsbLifecycleDiagnostic("[USB_RECOVERY_CANDIDATE] attempt=\(connectionGeneration) generation=\(connectionGeneration) state=start")
        recordUsbLifecycleDiagnostic("[USB_SESSION_ACCEPT] generation=\(connectionGeneration) connectionId=\(ObjectIdentifier(candidate))")
        setupStateHandler(for: candidate)
        setState(.connecting)
        if connectionSwitch.pending?.rollbackRoute == .usb {
            // A peer can leave the readiness framer preparing without delivering EOF.
            // Bound that dial independently of the TLS handshake and proof deadlines.
            let generation = connectionGeneration
            networkQueue.asyncAfter(deadline: .now() + USBControlTLSUpgrade.budget) { [weak self, weak candidate] in
                guard let self, let candidate, self.connectionGeneration == generation,
                      self.connection === candidate, self.usbScdpConnection === candidate,
                      self.connectionSwitch.pending?.rollbackRoute == .usb,
                      self.usbIdentity.phase == .initial,
                      !self.usbControlTLSAwaitingProof else { return }
                self.recoverConnectionControlOnQueue(.connectionLost)
            }
        }
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
    private func buildTLSParameters(for endpoint: NWEndpoint, expectedFingerprint: String?) -> NWParameters {
        let verificationGeneration = connectionGeneration
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, securityTrust, completionHandler in
                guard let self, self.connectionGeneration == verificationGeneration else {
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
                if self.trustedHostCleanup[fingerprint] != nil {
                    completionHandler(false)
                    return
                }
                // Reconnect candidates must prove the saved PC's identity before any SCST exchange.
                if let expectedFingerprint, fingerprint != expectedFingerprint {
                    completionHandler(false)
                    return
                }
                if self.connectionSwitch.pending?.rollingBack == true,
                   fingerprint != self.connectionSelectedCredential?.fingerprint {
                    completionHandler(false)
                    return
                }
                let decision = WifiHostIdentityPolicy.decide(
                    presentedFingerprint: fingerprint,
                    pinnedFingerprint: self.trustedHostFingerprintStore.load(endpoint: endpoint) ?? expectedFingerprint ??
                        self.trustedHostFingerprintStore.migrateLegacy(endpoint: endpoint, presented: fingerprint,
                            credential: self.trustedCredentialStore.load(fingerprint: fingerprint)))
                guard let identityCode = WifiHostIdentityPolicy.identityCode(
                    for: fingerprint) else {
                    completionHandler(false)
                    return
                }
                self.wifiAuthentication.begin(confirmed: decision == .trusted)
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
                    if !self.connectionHandoffInProgress { print("[IPAD][TLS_VERIFY] identity=known accepted=true") }
                    completionHandler(true)
                case .requiresFirstPairingConfirmation:
                    self.hostIdentityConfirmationRequired = true
                    self.hostIdentityConfirmed = false
                    if !self.connectionHandoffInProgress { print("[IPAD][TLS_VERIFY] identity=unknown awaiting_confirmation") }
                    completionHandler(true)
                case .rejected:
                    self.hostIdentityConfirmationRequired = false
                    self.hostIdentityConfirmed = false
                    if !self.connectionHandoffInProgress { print("[IPAD][TLS_VERIFY] identity=mismatch accepted=false") }
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
        guard let identity = USBServerTLSIdentity() else {
            throw USBListenerError.identityUnavailable
        }

        let fingerprint = identity.leafHash.map { String(format: "%02X", $0) }.joined()
        DispatchQueue.main.async {
            self.usbServerFingerprint = fingerprint
        }

        let parameters = NWParameters(
            tls: identity.makeOptions(),
            tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
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
                (self.activeTransportKind != .usb ||
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
            if self.activeTransportKind == .usb,
               self.usbScdpConnection !== connection { return }
            if self.usbControlTLSAwaitingProof {
                switch state {
                case .failed, .cancelled, .waiting:
                    self.failSecureUsbOnQueue(.connectionLost)
                    return
                default: break
                }
            }
            switch state {
            case .failed, .cancelled:
                if self.handleConnectionRetirementOnQueue(connection: connection, generation: generation, source: .socket) { return }
                if self.connectionSwitch.pending != nil {
                    if case .failed(let error) = state, case .tls = error {
                        self.logSwitch(.tlsFailed, route: self.committedConnectionRoute, reason: .identityUnavailable)
                    }
                    self.handleStreamError("Connection change transport lost.")
                    return
                }
            default: break
            }
            switch state {
            case .setup:
                print("[IPAD][NW_STATE] setup")
            case .preparing:
                print("[IPAD][NW_STATE] preparing")
            case .waiting(let error):
                if self.connectionHandoffInProgress {
                    if self.handleConnectionRetirementOnQueue(connection: connection, generation: generation, source: .waiting) { return }
                    if self.connectionSwitch.pending?.request.target == .wifi,
                       self.connectionSwitch.pending?.rollingBack == false,
                       WifiNetworkErrorPolicy.disposition(for: error) == .terminal {
                        // The failed Wi-Fi dial may already have a USB restore dial queued.
                        self.recoverConnectionControlOnQueue(.connectionLost)
                        return
                    }
                    // Network.framework may still reach ready. TCP/auth and handoff deadlines remain armed.
                    self.logSwitch(.targetWaiting, route: self.committedConnectionRoute, source: .waiting)
                    return
                }
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
                if self.connectionHandoffInProgress && !self.connectionExpectedRetirement {
                    self.logSwitch(.connected, route: self.committedConnectionRoute)
                    if self.activeTransportKind == .wifi { self.logSwitch(.tlsOK, route: .wifi) }
                }
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
                        if self.connectionHandoffInProgress { self.recoverConnectionControlOnQueue(.identityUnavailable); return }
                        print("[IPAD][PAIRING_GATED] reason=host_identity_confirmation")
                        self.setState(.awaitingHostIdentity)
                    } else {
                        self.sendTrustedClientHello(generation: generation)
                    }
                } else {
                    self.startWireReceiveLoop(generation: generation)
                    if self.usbControlTLSAwaitingProof {
                        self.beginUsbControlTLSProofOnQueue(connection, generation: generation)
                    }
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
                    self.scheduleAutoReconnect()
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
                    self.scheduleAutoReconnect()
                }

            default:
                break
            }
        }
    }

    // MARK: - Private: Auth Handshake

    private func admitWifiAuthenticationWrite(_ data: Data) -> Bool {
        guard activeTransportKind == .wifi else { return true }
        // Advance only at the writer's actual send boundary, not when a UI action queues it.
        if data.count == AuthProtocol.packetSize,
           data.loadLittleEndian(UInt32.self, at: 0) == AuthProtocol.magic {
            return hostIdentityConfirmed && wifiAuthentication.sentPIN()
        }
        guard data.count >= WireProtocol.headerSize,
              data.loadLittleEndian(UInt32.self, at: 0) == WireProtocol.magic else { return true }
        if data[5] == WireMessageType.clientHello.rawValue {
            return hostIdentityConfirmed && !hostIdentityConfirmationRequired && wifiAuthentication.sentHello()
        }
        if data[5] == WireMessageType.trustedDeviceProof.rawValue {
            return hostIdentityConfirmed && wifiAuthentication.sentProof()
        }
        return true
    }

    private func sendTrustedClientHello(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        #if targetEnvironment(simulator)
        testingClientHelloCount += 1
        #endif
        guard generation == connectionGeneration,
              hostIdentityConfirmed, !hostIdentityConfirmationRequired,
              let fingerprint = verifiedHostFingerprint else {
            handleStreamError("TLS host identity was unavailable after verification.")
            return
        }
        let stored = trustedCredentialStore.load(fingerprint: fingerprint)
        if connectionHandoffInProgress && !connectionPairingMatches(stored) {
            recoverConnectionControlOnQueue(.identityUnavailable); return
        }
        trustedCredential = stored
        let deviceID = stored?.deviceID ?? trustedDeviceID
        let sessionID = stored?.sessionID ?? Data(repeating: 0, count: 16)
        guard let payload = WireProtocol.clientHello(deviceID: deviceID, sessionID: sessionID, name: UIDevice.current.name) else {
            handleStreamError("Trusted device identity is malformed.")
            return
        }
        print(stored == nil
            ? "[IPAD][PAIRING_REQUIRED] credential=absent"
            : "[IPAD][TRUSTED_CREDENTIAL_FOUND] credential=present")
        if connectionHandoffInProgress { logSwitch(.authSent, route: .wifi) }
        sendWireMessage(type: .clientHello, payload: payload, sequence: 0)
    }

    private func markRecentWifiResumeIntentIfEligible() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard reconnectEnabled,
              !usbListenerExplicitlyStarted, activeTransportKind == .wifi,
              connection != nil,
              transportState == .streaming else {
            RecentWifiResumeStore.clear(defaults: streamSettingsDefaults)
            return
        }
        RecentWifiResumeStore.mark(defaults: streamSettingsDefaults)
    }

    private func loadWifiReconnectEndpoint() -> NWEndpoint? {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard let target = savedWifiReconnectTarget, let endpoint = target.endpoint else { return nil }
        if WifiReconnectTargetStore.load(defaults: streamSettingsDefaults) == nil,
           target.kind == .hostPort {
            WifiReconnectTargetStore.save(target, defaults: streamSettingsDefaults)
        }
        return endpoint
    }

    private func connectSavedWifiOnQueue() {
        guard transportState == .idle || isDisconnectedOnQueue,
              pendingTrustedHostForget == nil, let saved = loadWifiReconnectEndpoint(),
              !wifiTargetHasPendingCleanup(saved) else { return }
        let fingerprint = trustedHostFingerprintStore.load(endpoint: saved)
        let endpoints = fingerprint.map { reconnectEndpoints(saved: saved, fingerprint: $0) } ?? [saved]
        let routes = endpoints.compactMap { endpoint in
            WifiReconnectTargetPolicy.target(from: endpoint).map { ($0, endpoint) }
        }
        if routes.allSatisfy({ triedWifiReconnectTargets.contains($0.0) }) {
            triedWifiReconnectTargets.removeAll()
        }
        guard let (target, endpoint) = routes.first(where: { !triedWifiReconnectTargets.contains($0.0) }) else { return }
        triedWifiReconnectTargets.insert(target)
        #if targetEnvironment(simulator)
        if let reconnectRouteForTesting {
            reconnectRouteForTesting(endpoint, fingerprint)
            return
        }
        #endif
        connectOnQueue(to: endpoint, expectedFingerprint: fingerprint)
    }

    private func reconnectEndpoints(saved: NWEndpoint, fingerprint: String) -> [NWEndpoint] {
        guard case .hostPort(let host, let port) = saved,
              let address = RemoteHostAddress.parse(String(describing: host)), address.kind != .dnsName else {
            return [saved]
        }
        // Bonjour advertises casting only. The whole-PC service keeps its port and can use a known DNS alias.
        let bonjour = port.rawValue == 27015 ? discoveredWifiEndpoints.filter {
            if case .service = $0 { return true }
            return false
        } : []
        let discovered = bonjour.map { ($0, trustedHostFingerprintStore.load(endpoint: $0)) }
        let known = trustedHostFingerprintStore.targets(for: fingerprint).compactMap { target -> NWEndpoint? in
            switch target.kind {
            case .service:
                return port.rawValue == 27015 ? target.endpoint : nil
            case .hostPort:
                guard target.port == port.rawValue, target.host.flatMap(RemoteHostAddress.parse)?.kind == .dnsName else { return nil }
                return target.endpoint
            }
        }
        // Older pin records do not store the endpoint. Recover known DNS names from recent entries.
        let recentDNS = RecentRemoteHostStore.load(defaults: streamSettingsDefaults).compactMap { entry -> NWEndpoint? in
            guard entry.port == port.rawValue, let address = RemoteHostAddress.parse(entry.host),
                  address.kind == .dnsName else { return nil }
            let endpoint = NWEndpoint.hostPort(host: RemoteHostAddress.networkHost(address.host), port: port)
            return trustedHostFingerprintStore.load(endpoint: endpoint) == fingerprint ? endpoint : nil
        }
        // Probe unfamiliar Bonjour services only after the saved address, under the same TLS identity check.
        return discovered.filter { $0.1 == fingerprint }.map { $0.0 } + known + recentDNS + [saved] +
            discovered.filter { $0.1 == nil }.map { $0.0 }
    }

    private func scheduleAutoReconnect() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard !connectionHandoffInProgress, !connectionSwitch.offersReconnect else { return }
        guard isForegroundActive,
              reconnectEnabled,
              pendingTrustedHostForget == nil, hasReconnectTarget else {
            publishAutoReconnectAttempt(0) // Nothing is scheduled, so the screen must not say "Reconnecting".
            return
        }
        reconnectWorkItem?.cancel()
        let delay = TrustedReconnectPolicy.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        publishAutoReconnectAttempt(reconnectAttempt)
        print("[IPAD][AUTO_RECONNECT_ATTEMPT] attempt=\(reconnectAttempt) delay=\(delay)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isForegroundActive, self.reconnectEnabled else { return }
            guard self.connection == nil else { return }
            print("[IPAD][AUTO_RECONNECT_BEGIN] endpoint=persisted_target")
            self.connectSavedWifiOnQueue()
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
            if connectionHandoffInProgress { failConnectionControlOnQueue(.identityUnavailable); return }
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
        trustedProofGeneration = generation
        sendWireMessage(type: .trustedDeviceProof, payload: response, sequence: 0)
    }

    private func storePairingCredential(_ payload: Data) {
        guard payload.count == 80, hostIdentityConfirmed, !hostIdentityConfirmationRequired,
              wifiAuthentication.mayPersistPairing,
              let fingerprint = verifiedHostFingerprint,
              let endpoint = connectionSelectedEndpoint else {
            handleStreamError("Unexpected pairing credential."); return
        }
        guard wifiAuthentication.receive(.pairingSuccess) else { handleStreamError("Unexpected pairing credential."); return }
        let credential = TrustedHostCredential(
            fingerprint: fingerprint,
            hostID: payload.subdata(in: 0..<16),
            deviceID: payload.subdata(in: 16..<32),
            secret: payload.subdata(in: 48..<80),
            sessionID: payload.subdata(in: 32..<48),
            usbControlTLSSeen: trustedCredential?.fingerprint == fingerprint ? trustedCredential?.usbControlTLSSeen : nil)
        guard credential.deviceID == (trustedCredential?.deviceID ?? trustedDeviceID) else {
            handleStreamError("Pairing credential does not match this device."); return
        }
        let isNewPairing = trustedCredential?.hostID != credential.hostID
        var credentialSaved: Bool?
        let pinsSaved = trustedHostFingerprintStore.save(fingerprint, endpoint: endpoint, hostID: credential.hostID) {
            let saved = trustedCredentialStore.save(credential)
            credentialSaved = saved
            return saved
        }
        guard pinsSaved else {
            if credentialSaved == true {
                if let previous = trustedCredential { _ = trustedCredentialStore.save(previous) }
                else { trustedCredentialStore.delete(fingerprint: fingerprint) }
            }
            handleStreamError(credentialSaved == false
                ? "Unable to save the trusted Host credential in Keychain."
                : "Unable to save the trusted Host identity in Keychain.")
            return
        }
        trustedCredential = credential
        if isNewPairing {
            ClientStreamSettingsStore.initializeCastingBitrateForNewPairing(hostID: credential.hostID,
                                                                            remote: remoteInputConnection, defaults: streamSettingsDefaults)
        }
        if activeTransportKind == .wifi {
            pairedControlGeneration = connectionGeneration
            refreshAdaptiveQualityPreferenceOnQueue()
            negotiateConnectionControlOnQueue()
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
        let effective = state.preference
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
        let desiredForSession = clientSettingsState.desired.forSession(remote: remoteInputConnection, manualFallback: usesManualQualityFallback)
        let decision = settingsReconciliationGate.decision(
            hostGeneration: state.generation,
            desired: desiredForSession,
            effective: effective,
            outcome: resolvedOutcome,
            remote: remoteInputConnection)
        if !remoteInputConnection, case .rejected(.runtimeApplyFailed) = resolvedOutcome {
            let desired = clientSettingsState.desired
            print(
                "[IPAD][SETTINGS_RUNTIME_RECOVERY_ARMED] " +
                "generation=\(state.generation) " +
                "desired_bitrate=\(UInt32(desired.bitrateMbps * 1_000_000)) " +
                "desired_audio=\(desired.audioEnabled)")
        }
        let isInSync = desiredForSession.matchesReportedSettings(effective)
        let rejected: Bool
        if case .rejected = resolvedOutcome { rejected = true } else { rejected = false }
        let status: String
        if remoteInputConnection {
            switch resolvedOutcome {
            case .state: status = "PC settings received"
            case .applied: status = "Applied"
            case .rejected: status = "Rejected by Host"
            }
        } else if isInSync {
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
        if remoteInputConnection {
            let requestID = payload.loadLittleEndian(UInt32.self, at: 4)
            if outcome == .state, requestID == remoteSettingsGetID {
                remoteSettingsReady = true
                remoteSettingsGetID = nil
            }
            if outcome != .state, requestID == remoteManualRequestID {
                remoteManualRequestID = nil
            }
            restoreRemoteManualIfReady()
            sendAdaptivePolicyOnQueue(auto: qualityAutoOptIn)
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
        if !connectionHandoffInProgress { transportTelemetry.stopLogging() }
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
        let profile = activeTransportKind == .usb ? "usb" : "wifi"
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

    private func sendVideoFeedback(reportDecodeLoss: Bool = false) {
        guard wireAuthenticatedGeneration == connectionGeneration else { return }
        publishAudioDiagnosticsIfDue()
        #if targetEnvironment(simulator)
        testingVideoFeedbackCount += 1
        #endif
        sendClientPingIfDue()
        let feedback = transportTelemetry.makeFeedback()
        if mayReceiveRemoteFiles {
            let now = ProcessInfo.processInfo.systemUptime
            if remoteFileAccess?.expire(now: now) == true {
                revokeRemoteFilesOnQueue()
                remoteFileAccess?.markTimedOut()
                publishRemoteFileAccessOnQueue()
            }
            remoteFilePacing.feedback(now: now, presented: feedback.0,
                                      queueAge: feedback.4, drops: feedback.5)
            remoteFileIO?.checkRemoteDeadline(now: now, paused: remoteFilePacing.rate(now: now, unsettled: remoteFileMediaBlocked) == 0)
            controlChannelWriter.drain()
        }
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: feedback.0.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: feedback.1.littleEndian, toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: feedback.2.littleEndian, toByteOffset: 8, as: UInt16.self)
            let needsIDR = remoteTimedVideoNeedsIDR || (remoteSecureDesktop.needsKeyframe && !remoteSecureDesktop.covered)
            let dropped = needsIDR ? max(feedback.3, 1) : feedback.3
            bytes.storeBytes(of: dropped.littleEndian, toByteOffset: 10, as: UInt16.self)
            bytes.storeBytes(of: feedback.4.littleEndian, toByteOffset: 12, as: UInt16.self)
            let droppedAccessUnits = reportDecodeLoss ? max(feedback.5, 1) : feedback.5
            bytes.storeBytes(of: droppedAccessUnits.littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        let stages = transportTelemetry.frameStageP95Ms()
        let feedbackFlags = transportTelemetry.feedbackValidityFlags()
        sendWireMessage(
            type: .videoFeedback,
            payload: payload,
            sequence: feedback.0,
            flags: feedbackFlags,
            coalesceFeedback: !(reportDecodeLoss && activeTransportKind == .usb))
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
        // The dedicated USB probes already measure this owner. Do not put an
        // unrelated telemetry Pong ahead of their single-use liveness proof.
        if purpose == .telemetry, activeTransportKind == .usb,
           (usbLegacyPcmFreshFenceNonce != nil || pendingUsbCandidate != nil) { return nil }
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
        var flags: UInt16 = 0
        if remoteFeaturesProbe {
            let clipboardProbe = wantsRemoteClipboard
            remoteFeatures.recordProbe(payload, clipboard: clipboardProbe)
            flags = clipboardProbe ? Clipboard.marker : RemoteFeatureNegotiation.supportedFlag
        }
        sendWireMessage(type: .ping, payload: payload, sequence: UInt32(truncatingIfNeeded: nonce), flags: flags)
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

    struct TransferActionScope: Equatable {
        let generation: UInt64
        let remote: Bool
        let fileEpoch: UInt64
    }

    @MainActor var transferActionScope: TransferActionScope {
        TransferActionScope(generation: connectionGenerationClock.current, remote: isRemoteControlSession,
                            fileEpoch: remoteFileActionClock.current)
    }

    private func ownsTransferAction(_ scope: TransferActionScope) -> Bool {
        scope.generation == connectionGeneration && scope.remote == remoteInputConnection &&
            (!scope.remote || scope.fileEpoch == remoteFileActionClock.current) &&
            wireAuthenticatedGeneration == scope.generation && committedTransportGeneration == scope.generation
    }

    func sendTransferFiles(_ urls: [URL], scope: TransferActionScope) {
        networkQueue.async { [weak self] in
            guard let self, self.ownsTransferAction(scope), !urls.isEmpty else { return }
            if scope.remote { self.startRemoteFileActionOnQueue(.upload(urls)) }
            else { self.dataTransfers?.sendFiles(urls) }
        }
    }
    func requestRemoteFiles(scope: TransferActionScope) {
        networkQueue.async { [weak self] in
            guard let self, scope.remote, self.ownsTransferAction(scope) else { return }
            self.startRemoteFileActionOnQueue(.download)
        }
    }
    func retryRemoteFiles(scope: TransferActionScope) {
        networkQueue.async { [weak self] in
            guard let self, scope.remote, self.ownsTransferAction(scope), self.mayStartRemoteFiles,
                  self.remoteFileAccess?.waiting == false else { return }
            self.remoteFileIO?.retryRemoteFiles()
        }
    }
    func decideTransfer(_ accepted: Bool, consent: DataTransferManager.Consent) {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation,
                  self.wireAuthenticatedGeneration == generation, self.committedTransportGeneration == generation else { return }
            if self.remoteInputConnection {
                guard self.remoteFileAccess?.grant != nil, self.isForegroundActive else { return }
                self.remoteFileIO?.decide(accepted, consent: consent)
            } else { self.dataTransfers?.decide(accepted, consent: consent) }
        }
    }
    func cancelTransfer(scope: TransferActionScope) {
        networkQueue.async { [weak self] in
            guard let self, self.ownsTransferAction(scope) else { return }
            self.controlChannelWriter.cancelBulk()
            if scope.remote { self.remoteFileIO?.cancel() }
            else { self.dataTransfers?.cancel() }
        }
    }

    private var mayReceiveRemoteFiles: Bool {
        remoteInputConnection && wireAuthenticatedGeneration == connectionGeneration &&
            remoteFeatures.accepted & RemoteFeatureNegotiation.remoteFileFeature != 0
    }

    private var mayStartRemoteFiles: Bool {
        mayReceiveRemoteFiles && committedTransportGeneration == connectionGeneration &&
            isForegroundActive && !remoteFileBackgrounded && !captureAvailability.inputBlocked &&
            !remoteSecureDesktop.restrictsFeatures && remoteFeatures.inputReady &&
            remoteFeatures.context?.desktop == 1
    }

    private func publishRemoteFileAccessOnQueue() {
        let generation = connectionGeneration
        let status = remoteFileAccess?.status
        let waiting = remoteFileAccess?.waiting == true
        let canStart = mayStartRemoteFiles
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.remoteFileStatus = status
            self.remoteFileWaiting = waiting
            self.remoteFileCanStart = canStart
        }
    }

    private func startRemoteFileActionOnQueue(_ selection: RemoteFileAccess.Selection) {
        guard mayStartRemoteFiles, remoteFileIO?.hasActiveTransfer != true,
              remoteFileAccess?.waiting == false else { return }
        if case let .upload(urls) = selection, let access = remoteFileAccess, access.grant != nil, access.mayUpload {
            remoteFileIO?.sendFiles(urls)
        } else if let request = remoteFileAccess?.start(selection) {
            sendRemoteFileMessage(request)
        }
        publishRemoteFileAccessOnQueue()
    }

    private func revokeRemoteFilesOnQueue() {
        guard remoteFileAccess != nil else { return }
        _ = remoteFileActionClock.advance()
        let release = remoteFileAccess?.revoke()
        retireRemoteFileIOOnQueue()
        if let release { sendRemoteFileMessage(release) }
        publishRemoteFileAccessOnQueue()
    }

    private func backgroundRemoteFilesOnQueue() {
        remoteFileBackgrounded = true
        revokeRemoteFilesOnQueue()
    }

    private func retireRemoteFileIOOnQueue() {
        guard let manager = remoteFileIO else { return }
        remoteFileIO = nil
        pendingRemoteFileWrite?.cancel()
        pendingRemoteFileWrite = nil
        remoteFileWriteToken = nil
        manager.retire()
        controlChannelWriter.discardPending(where: { data in
            guard data.count >= WireProtocol.headerSize else { return false }
            return data[5] == WireMessageType.remoteFilePacket.rawValue ||
                data[5] == WireMessageType.remoteFileWindow.rawValue
        }, error: .posix(.ECANCELED))
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.transferSnapshot = DataTransferManager.Snapshot()
        }
    }

    private func sendRemoteFileMessage(_ message: RemoteFileProtocol.Message, completion: @escaping (Bool) -> Void = { _ in }) {
        guard mayReceiveRemoteFiles, let payload = RemoteFileProtocol.encode(message) else { completion(false); return }
        let pacedBytes: Int
        switch message {
        case let .packet(_, packet) where packet.kind == .chunk: pacedBytes = packet.bytes.count
        case .window: pacedBytes = WireProtocol.headerSize + payload.count
        default: pacedBytes = 0
        }
        guard pacedBytes > 0 else {
            sendWireMessage(type: message.type, payload: payload, sequence: 0) { completion($0 == nil) }
            return
        }
        let generation = connectionGeneration
        let token = UUID()
        pendingRemoteFileWrite?.cancel()
        remoteFileWriteToken = token
        sendPacedRemoteFile(message, payload: payload, bytes: pacedBytes, generation: generation,
                            token: token, started: ProcessInfo.processInfo.systemUptime, completion: completion)
    }

    private func sendPacedRemoteFile(_ message: RemoteFileProtocol.Message, payload: Data, bytes: Int, generation: UInt64,
                                    token: UUID, started: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard remoteFileWriteToken == token else { completion(false); return }
        pendingRemoteFileWrite = nil
        guard connectionGeneration == generation, mayWriteRemoteFileMessage(message, startingWrite: false) else {
            remoteFileWriteToken = nil
            completion(false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let rate = remoteFilePacing.rate(now: now, unsettled: remoteFileMediaBlocked)
        if rate > 0, now >= remoteFilePacing.nextWrite {
            remoteFilePacing.reserve(bytes: bytes, now: now, rate: rate)
            remoteFileWriteToken = nil
            sendWireMessage(type: message.type, payload: payload, sequence: 0, bulk: true) { completion($0 == nil) }
        } else if now - started < 300 {
            let work = DispatchWorkItem { [weak self] in
                self?.sendPacedRemoteFile(message, payload: payload, bytes: bytes, generation: generation,
                                          token: token, started: started, completion: completion)
            }
            pendingRemoteFileWrite = work
            networkQueue.asyncAfter(deadline: .now() + 0.05, execute: work)
        } else {
            remoteFileWriteToken = nil
            completion(false)
        }
    }

    private var remoteFileMediaBlocked: Bool {
        captureAvailability.inputBlocked || adaptiveMediaUnsettled || qualitySession?.pending != nil
    }

    private func remoteFilePacketIsCurrent(_ data: Data, startingWrite: Bool = false) -> Bool {
        guard data.count >= WireProtocol.headerSize,
              data.loadLittleEndian(UInt32.self, at: 0) == WireProtocol.magic,
              let type = WireMessageType(rawValue: data[5]), (100...103).contains(type.rawValue) else { return true }
        guard mayReceiveRemoteFiles,
              let message = RemoteFileProtocol.decode(type: type, payload: Data(data.dropFirst(WireProtocol.headerSize)), flags: 0) else { return false }
        return mayWriteRemoteFileMessage(message, startingWrite: startingWrite)
    }

    private func mayWriteRemoteFileMessage(_ message: RemoteFileProtocol.Message, startingWrite: Bool) -> Bool {
        switch message {
        case .control(let operation, let request, _, let grant):
            if operation == .release { return true }
            guard !remoteFileBackgrounded, remoteFileAccess?.mayWriteRequest(request) == true else { return false }
            guard operation == .requestGrant || remoteFileAccess?.grant == grant else { return false }
            if startingWrite { remoteFileAccess?.didStartRequest(request) }
            return true
        case .packet(let grant, let packet):
            guard !remoteFileBackgrounded, remoteFileAccess?.grant == grant, let manager = remoteFileIO else { return false }
            // Busy and terminal packets may outlive the batch that produced them.
            return packet.kind == .cancel || packet.kind == .ack || (packet.kind == .response && !packet.accepted) || manager.owns(packet)
        case .window(let grant, let offer, let index, let consumed, let limit, let chunks):
            guard !remoteFileBackgrounded, remoteFileAccess?.grant == grant, let manager = remoteFileIO else { return false }
            let window = DataTransferManager.FileWindow(offer: offer, file: index, consumed: consumed, limit: limit, chunks: chunks)
            return manager.authorizeRemoteWindow(window, beginWrite: startingWrite)
        case .state: return false
        }
    }

    private func beginRemoteFileIOOnQueue(grant: UUID) {
        retireRemoteFileIOOnQueue()
        let generation = connectionGeneration
        let identity = remoteFileAccess?.identity
        let send: (RemoteFileProtocol.Message, @escaping (Bool) -> Void) -> Void = { [weak self] message, completion in
            guard let self else { completion(false); return }
            self.networkQueue.async {
                guard self.connectionGeneration == generation, self.remoteFileAccess?.identity == identity,
                      self.remoteFileAccess?.grant == grant, !self.remoteFileBackgrounded else { completion(false); return }
                self.sendRemoteFileMessage(message, completion: completion)
            }
        }
        let manager = DataTransferManager(generation: generation, directory: retainedTransferRoot, transport: "Remote",
                                          receivedLibrary: retainedFileLibrary,
                                          onLibraryReady: { [weak self] library in
            self?.networkQueue.async { [weak self] in self?.retainedFileLibrary = library }
        }, remoteWindowSender: { window, completion in
            send(.window(grantId: grant, offerId: window.offer, fileIndex: window.file, consumedOffset: window.consumed,
                         maxOffset: window.limit, maxChunkIndexExclusive: window.chunks), completion)
        }) { packet, completion in
            send(.packet(grantId: grant, transfer: packet), completion)
        }
        remoteFileIO = manager
        observeDataTransfer(manager, generation: generation, transport: "Remote", remote: true)
    }

    private func receiveRemoteFileOnQueue(_ header: WireHeader, payload: Data) {
        guard mayReceiveRemoteFiles, let message = RemoteFileProtocol.decode(type: header.type, payload: payload, flags: header.flags) else {
            handleStreamError("Invalid remote file message."); return
        }
        switch message {
        case .state:
            let oldGrant = remoteFileAccess?.grant
            let effects = remoteFileAccess?.receive(message, allowed: !remoteFileBackgrounded) ?? []
            if oldGrant != nil, remoteFileAccess?.grant == nil { _ = remoteFileActionClock.advance() }
            if let grant = remoteFileAccess?.grant, grant != oldGrant { beginRemoteFileIOOnQueue(grant: grant) }
            for effect in effects {
                switch effect {
                case .send(let outgoing): sendRemoteFileMessage(outgoing)
                case .upload(let urls): remoteFileIO?.sendFiles(urls)
                case .retire: retireRemoteFileIOOnQueue()
                }
            }
            publishRemoteFileAccessOnQueue()
        case let .packet(grant, packet):
            guard grant == remoteFileAccess?.grant, !remoteFileBackgrounded, let manager = remoteFileIO else { return }
            if packet.kind == .offer {
                guard remoteFileAccess?.takeIncomingOffer(grant: grant, offer: packet.id) == true else { return }
                publishRemoteFileAccessOnQueue()
            }
            if packet.kind == .cancel && manager.owns(packet) { controlChannelWriter.cancelBulk() }
            postRemoteFileWork { manager.post(packet, completion: $0) }
        case let .window(grant, offer, file, consumed, limit, chunks):
            guard grant == remoteFileAccess?.grant, !remoteFileBackgrounded, let manager = remoteFileIO else { return }
            let window = DataTransferManager.FileWindow(offer: offer, file: file, consumed: consumed, limit: limit, chunks: chunks)
            postRemoteFileWork { manager.postRemoteFileWindow(window, completion: $0) }
        case .control: handleStreamError("Unexpected remote file command.")
        }
    }

    private func postRemoteFileWork(_ post: (@escaping () -> Void) -> Bool) {
        let generation = connectionGeneration
        transferReceivePending += 1
        if !post({ [weak self] in
            self?.networkQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.transferReceivePending = max(0, self.transferReceivePending - 1)
                if self.transferReceiveHasCapacity { self.receiveWireChunk(generation: generation) }
            }
        }) { transferReceivePending -= 1 }
    }

    private func beginDataTransfer(generation: UInt64) {
        guard !remoteInputConnection, generation == connectionGeneration, dataTransfers == nil else { return }
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
        dataTransfers = manager
        observeDataTransfer(manager, generation: generation, transport: activeTransportKind == .usb ? "USBC" : "WiFi", remote: false)
        refreshAutoAcceptPolicyOnQueue()
    }

    private func observeDataTransfer(_ manager: DataTransferManager, generation: UInt64, transport: String, remote: Bool) {
        manager.diagnostic = { [weak self] line in
            self?.recordDiagnosticLine(line + " transport=\(transport)")
        }
        manager.changed = { [weak self, weak manager] snapshot in
            guard let self else { return }
            self.networkQueue.async {
                guard let manager, (remote ? self.remoteFileIO : self.dataTransfers) === manager,
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
    }
    private func sendWireMessage(
        type: WireMessageType,
        payload: Data,
        sequence: UInt32,
        flags: UInt16 = 0,
        coalesceFeedback: Bool = true,
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
            telemetry: coalesceFeedback && type == .videoFeedback && flags != CaptureTargetProtocol.recoveryFlag,
            movement: movement,
            bulk: bulk,
            completion: { [weak self] error in
                // Queued bulk cancellation is terminal for its transfer owner,
                // not a transport send failure. Preserve the authenticated session.
                if bulk || Self.isClipboardPacket(type.rawValue, flags: flags) || (100...103).contains(type.rawValue),
                   case .posix(.ECANCELED)? = error {
                    completion(error)
                    return
                }
                if Self.isClipboardPacket(type.rawValue, flags: flags), case .posix(.ENOBUFS)? = error {
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
        guard generation == connectionGeneration, connection === sentConnection else { return }
        if let sentConnection, handleConnectionRetirementOnQueue(connection: sentConnection, generation: generation, source: .send) {
            return
        }
        if transport == .wifi, let sentConnection,
           shouldPreserveTransientWifiControlError(error, generation: generation, connection: sentConnection) {
            recordWifiLifecycleDiagnostic(
                "generation=\(generation) event=control_send_error " +
                "action=preserve_transient")
            return
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
            guard let self, generation == self.connectionGeneration, self.adaptivePacketIsCurrent(data) else { return }
            guard self.remoteFilePacketIsCurrent(data), self.remoteClipboardPacketIsCurrent(data) else {
                completion(.posix(.ECANCELED)); return
            }
            if bulk {
                let paced = data.count >= WireProtocol.headerSize && (100...103).contains(data[5])
                let ready: (() -> Bool)? = paced ? { [weak self] in
                    guard let self, self.remoteFilePacketIsCurrent(data) else { return true }
                    return self.remoteFilePacing.rate(now: ProcessInfo.processInfo.systemUptime,
                                                     unsettled: self.remoteFileMediaBlocked) > 0
                } : nil
                if !self.controlChannelWriter.enqueueBulk(data, ready: ready, completion: completion) { completion(.posix(.ENOBUFS)) }
            } else if telemetry {
                self.controlChannelWriter.enqueueTelemetry(data, completion: completion)
            } else if movement {
                self.controlChannelWriter.enqueueMovement(data, completion: completion)
            } else if !self.controlChannelWriter.enqueue(data, completion: completion) {
                if data.count >= WireProtocol.headerSize, Self.isClipboardPacket(data[5], flags: Self.wireFlags(data)) {
                    completion(.posix(.ECANCELED))
                    return
                }
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
                               receivedAt: suffix.receivedAt, isComplete: suffix.isComplete, terminalError: suffix.terminalError)
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
            // A receive completion can carry the last control frame and an error together.
            // Consume that frame before classifying the origin, including across parser backpressure.
            if let error, data?.isEmpty != false || self.connectionSwitch.pending == nil {
                self.handleWireReceiveError(
                    error, generation: generation, connection: connection)
                return
            }

            self.consumeWireReceive(data ?? Data(), generation: generation, connection: connection,
                                    receivedAt: CACurrentMediaTime(), isComplete: isComplete, terminalError: error)
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
                                    receivedAt: TimeInterval, isComplete: Bool, terminalError: NWError?) {
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
                receivedAt: receivedAt, generation: generation, connection: connection, isComplete: isComplete, terminalError: terminalError)
            return
        }
        if let terminalError {
            handleWireReceiveError(terminalError, generation: generation, connection: connection)
            return
        }
        if isComplete {
            if handleConnectionRetirementOnQueue(connection: connection, generation: generation, source: .eof) { return }
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
        if handleConnectionRetirementOnQueue(connection: receivedConnection, generation: generation, source: .receive) { return }
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
            if usbControlTLSAwaitingProof { failSecureUsbOnQueue(); return }
            if remoteSecureDesktop.expectsIDR {
                handleStreamError("Missing secure desktop first picture."); return
            }
            if activeTransportKind == .wifi,
               [.authResult, .pairingRequired, .trustedDeviceChallenge, .pairingSuccess,
                .trustedAuthResult, .sessionResumeResult].contains(header.type) {
                handleStreamError("Malformed authentication message."); return
            }
            if activeTransportKind == .usb, wireAuthenticatedGeneration != generation, usbIdentity.pending,
               [.trustedDeviceChallenge, .trustedDeviceProof, .pairingSuccess, .sessionResumeResult].contains(header.type) {
                usbIdentity.abandon(); finishUsbIdentityOnQueue(generation: generation, identified: false)
            }
            print("[NetworkManager] Discarded malformed \(header.type) payload.")
        case .message(let message):
            handleWireMessage(message, generation: generation)
        }
    }

    private func handleWireMessage(_ message: WireMessage, generation: UInt64) {
        let header = message.header
        let payload = message.payload
        if remoteSecureDesktop.expectsIDR, header.type != .video {
            handleStreamError("Missing secure desktop first picture."); return
        }

        if (header.type == .captureAvailability || header.type == .captureAvailabilityHello),
           wireAuthenticatedGeneration != generation {
            recordDiagnosticLine("[CAPTURE_AVAILABILITY] ignored=unauthenticated")
            return
        }
        if activeTransportKind == .wifi,
           [.pairingRequired, .trustedDeviceChallenge, .authResult, .trustedAuthResult, .sessionResumeResult].contains(header.type) {
            let validPayload: Bool
            switch header.type {
            case .trustedDeviceChallenge: validPayload = payload.count == 112 && header.flags == 0
            case .pairingRequired, .trustedAuthResult: validPayload = !payload.isEmpty && payload[0] <= 1 && header.flags == 0
            case .sessionResumeResult: validPayload = payload.count == 17 && payload[0] <= 1 && header.flags == 0
            default: validPayload = !payload.isEmpty && payload[0] <= 1 &&
                header.flags & ~WireProtocol.realtimeNegotiationSupportedFlag == 0
            }
            guard hostIdentityConfirmed, !hostIdentityConfirmationRequired, validPayload,
                  wifiAuthentication.receive(header.type, accepted: payload.first == 1) else {
                handleStreamError("Unexpected authentication stage."); return
            }
        }
        guard wireAuthenticatedGeneration == generation else {
            if activeTransportKind == .usb {
                guard generation == connectionGeneration, wireReceiveActiveGeneration == generation,
                      let current = connection, usbScdpConnection === current else { return }
                receiveUsbIdentityOnQueue(message, generation: generation)
                return
            }
            if header.type == .pairingRequired {
                if connectionHandoffInProgress { recoverConnectionControlOnQueue(.identityUnavailable); return }
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
                if transportState == .submittingPIN { setState(.connecting) }
                // Casting can authenticate and deliver a baseline on every failed cutover retry.
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                print("[IPAD][AUTO_RECONNECT_SUCCESS] generation=\(generation)")
                wireAuthenticatedGeneration = generation
                committedTransportGeneration = nil
                beginRemoteFeaturesAfterAuthentication(generation: generation)
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
                if connectionHandoffInProgress { recoverConnectionControlOnQueue(.identityUnavailable); return }
                setState(.authFailed(
                    reason: reason.isEmpty ? "Incorrect PIN. Please try again." : reason))
            }
            return
        }

        if activeTransportKind == .usb && [.clientHello, .pairingRequired, .trustedDeviceChallenge,
            .trustedDeviceProof, .pairingSuccess, .trustedAuthResult, .sessionResumeResult].contains(header.type) && usbIdentity.optedIn {
            return
        }

        switch header.type {
        case .transferOffer, .transferResponse, .transferChunk, .transferFileEnd, .transferFileAck, .transferCancel, .transferEnd, .transferAck:
            guard !remoteInputConnection, wireAuthenticatedGeneration == generation, committedTransportGeneration == generation,
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
            guard header.flags == 0 else { handleStreamError("Unexpected pairing flags."); return }
            if connectionHandoffInProgress { recoverConnectionControlOnQueue(.identityUnavailable); return }
            storePairingCredential(payload)
            if pairedControlGeneration == generation { beginRemoteFeaturesOnQueue(generation: generation) }

        case .trustedAuthResult:
            guard !payload.isEmpty, payload[0] != 0 else {
                if connectionHandoffInProgress { recoverConnectionControlOnQueue(.identityUnavailable); return }
                setState(.authFailed(reason: "Trusted device authentication failed."))
                return
            }
            print("[IPAD][TRUSTED_AUTH_SUCCESS] generation=\(generation)")
            if activeTransportKind == .wifi, trustedProofGeneration == generation, let credential = trustedCredential,
               credential.fingerprint == verifiedHostFingerprint, !hostIdentityConfirmationRequired {
                if let endpoint = connectionSelectedEndpoint,
                   let target = WifiReconnectTargetPolicy.target(from: endpoint),
                   !trustedHostFingerprintStore.targets(for: credential.fingerprint).contains(target) {
                    _ = trustedHostFingerprintStore.save(credential.fingerprint, endpoint: endpoint,
                        hostID: credential.hostID, select: false)
                }
                pairedControlGeneration = generation
                refreshAdaptiveQualityPreferenceOnQueue()
                negotiateConnectionControlOnQueue()
                beginRemoteFeaturesOnQueue(generation: generation)
            }

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
            guard generation == connectionGeneration, header.flags == 0,
                  payload.count == 2, payload[0] == 1, payload[1] <= 1,
                  let pending = pendingTrustedHostForget, ownsTrustedHostSession(pending.fingerprint) else { return }
            finishPendingTrustedHostForget(generation: generation, confirmed: payload[1] == 1)

        case .displayCapabilities:
            guard let capabilities = DisplayCapabilities.decode(payload) else {
                handleStreamError("Malformed display capabilities.")
                return
            }
            if !remoteInputConnection,
               let hello = captureAvailability.hello(flags: header.flags,
                    authenticated: wireAuthenticatedGeneration == generation, generation: generation) {
                sendWireMessage(type: .captureAvailabilityHello, payload: hello, sequence: 0)
            }
            let pointerV2 = header.flags & IPadPointerV2Command.capability != 0
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGenerationClock.current == generation else { return }
                self.iPadPointerV2Supported = pointerV2
                self.iPadPointerV2Generation = generation
            }
            connectionAdvertisement = header.flags
            negotiateConnectionControlOnQueue()
            if let hello = mirrorControl.helloIfAdvertised(session: generation, flags: header.flags) {
                mirrorSwitchAdvertised=header.flags & 0x2000 != 0
                sendWireMessage(type: .mirrorHello, payload: hello, sequence: 0)
            }
            captureTargetAdvertisementGeneration = generation
            negotiateCaptureTargetsOnQueue()
            receiveDisplayCapabilities(capabilities)

        case .captureAvailability:
            guard !remoteInputConnection else { return }
            receiveCaptureAvailabilityOnQueue(payload, flags: header.flags, generation: generation)
            return
        case .captureAvailabilityHello:
            recordDiagnosticLine("[CAPTURE_AVAILABILITY] ignored=direction")
            return

        case .connectionState, .connectionSelectResult:
            receiveConnectionControlOnQueue(message, generation: generation)
            return
        case .connectionHello, .connectionSelectRequest:
            handleStreamError("Invalid connection control direction.")
            return

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
            if !remoteInputConnection { decoder.configureRefreshRate(UInt32(mode.targetFps)) }
            // The USB request already reconciled source ownership. An FPS echo
            // can arrive between retirement and the confirming catalogue.
            if (activeTransportKind != .usb || connectionHandoffInProgress) && captureTargetOwnsPresentation {
                abandonCaptureTargetPresentationOnQueue()
            }
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
                    let state = transition.state
                    let resumedVirtualDisplay = oldState?.mode == .unavailable &&
                        oldState?.source == 0 && state.mode == .virtualDisplay
                    // A virtual restart can publish several Unavailable epochs before
                    // confirming VirtualDisplay. The first retirement fences old frames.
                    let preservesVirtualDecoder = !connectionHandoffInProgress &&
                        currentMirrorDecoderOwner != nil &&
                        ((oldState?.mode == .virtualDisplay && state.mode == .virtualDisplay) ||
                         (oldState?.mode == .unavailable && oldState?.source == 0 &&
                          (resumedVirtualDisplay || (state.mode == .unavailable && state.source == 0))))
                    if oldState?.epoch != state.epoch && !captureTargetOwnsPresentation && !preservesVirtualDecoder {
                        if connectionHandoffInProgress && connectionVideoStarted {
                            failConnectionControlOnQueue(.localOperation); return
                        }
                        currentMirrorCatalogue=nil;mirrorCatalogueSource=nil
                        let isVirtualDisplayRestart = !connectionHandoffInProgress &&
                            oldState?.mode == .virtualDisplay && state.mode == .unavailable && state.source == 0
                        // Fence old tickets immediately. The next virtual IDR can
                        // replace the VT format from its parameter sets without
                        // waiting behind teardown before the first submission.
                        if !isVirtualDisplayRestart { decoder.invalidate(waitForCompletion: false) }
                        beginOwnedDecoderSession(networkGeneration: generation)
                    }
                    // An IDR may arrive before the control state admits video again.
                    let firstPhysicalAnchor = oldState?.firstFrame == nil && state.firstFrame != nil
                    if !captureAvailability.inputBlocked, !captureTargetOwnsPresentation,
                       firstPhysicalAnchor || (resumedVirtualDisplay && !connectionHandoffInProgress) {
                        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                            wifiMediaReceiver.requestImmediateRecoveryFeedback(generation: generation)
                        } else if activeTransportKind == .usb && resumedVirtualDisplay {
                            requestVideoRecoveryOnQueue()
                        } else if let recovery=mirrorControl.presentationRecoveryRequest() {
                            sendWireMessage(type:.mirrorAction,payload:recovery,sequence:0)
                        }
                    }
                    if let ack = transition.acknowledgement { sendWireMessage(type: .mirrorAction, payload: ack, sequence: 0) }
                    advanceMirrorTerminalSwitchOnQueue()
                    if captureTargets.pending == nil, let owner=currentCaptureTargetDecoderOwner, !captureTargetModeMatches(owner: owner) {
                        abandonCaptureTargetPresentationOnQueue()
                    } else { advanceCaptureTargetVideoOnQueue() }
                    advanceConnectionVideoOnQueue()
                    publishMirrorStateOnQueue()
                }
            } catch { handleStreamError("Invalid physical-source control state.") }
            return
        case .sourceCatalogue:
            guard !remoteInputConnection, committedTransportGeneration == generation, captureTargets.enabled,
                  header.flags == 0 else { return }
            do {
                let value=try CaptureTargetCatalogue.decode(payload)
                if captureTargets.receiveCatalogue(value, session: captureTargets.session,
                    preservingSuspendedPresentation: captureAvailability.inputBlocked) {
                    if let applied=captureTargets.applied, (value.epoch != applied.epoch || value.state != 1),
                       !(captureAvailability.inputBlocked && value.epoch == applied.epoch && value.currentId == applied.currentId) {
                        abandonCaptureTargetPresentationOnQueue()
                    }
                    advanceCaptureTargetVideoOnQueue()
                    publishMirrorStateOnQueue()
                }
            } catch { handleStreamError("Invalid capture source catalogue.") }
            return
        case .sourceSwitchResult:
            guard !remoteInputConnection, committedTransportGeneration == generation, captureTargets.enabled,
                  header.flags == 0 else { return }
            do {
                let value=try CaptureTargetResult.decode(payload)
                let selection=captureTargets.pending
                let wasAccepted=selection?.accepted == true
                guard captureTargets.receiveResult(value, session: captureTargets.session) else { return }
                if value.status == .accepted {
                    if !wasAccepted {
                        if sourceRollback != nil { retirePendingAdaptiveOnQueue() }
                        retireCaptureTargetDecoderOnQueue()
                        if let selection, let connection = activeControlConnection {
                            scheduleCaptureTargetTerminalWaitOnQueue(selection.request, connection: connection, accepted: true)
                        }
                    }
                } else if let applied=captureTargets.applied {
                    if captureTargets.catalogue?.epoch != applied.epoch || captureTargets.catalogue?.state != 1 {
                        abandonCaptureTargetPresentationOnQueue()
                    } else { advanceCaptureTargetVideoOnQueue();startCaptureTargetRecoveryOnQueue() }
                } else if !restoreCaptureTargetAfterRollbackOnQueue(value, selection: selection) {
                    retireCaptureTargetDecoderOnQueue()
                }
                if captureTargets.pending == nil { sourceRollback=nil }
                if captureTargets.needsCatalogueRefresh { refreshCaptureTargetsOnQueue() }
                publishMirrorStateOnQueue()
                flushDeferredSourceDisplayOnQueue()
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
                mirrorCatalogueReceivedAt=captureReadinessNow()
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
        case .remoteDirectTouch, .iPadPointerV2, .directTouchContact, .pointerInput, .keyboardInput, .textCommit:
            return

        case .video:
            guard !remoteTimedVideoLatched else {
                handleStreamError("Plain video arrived after timed video started.")
                return
            }
            receiveWireVideoOnQueue(message, generation: generation)

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
            if receiveCastingClipboardPong(payload, flags: header.flags) { return }
            receiveAdaptivePongOnQueue(payload, flags: header.flags, sequence: header.sequence)
            let nonce = payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
            }
            if remoteInputConnection, generation == connectionGeneration, wireAuthenticatedGeneration == generation,
               let clipboardProbe = remoteFeatures.consumeProbeReply(payload) {
                let audioPreferred = remoteAudioHostID.map {
                    ClientStreamSettingsStore.loadRemoteAudio(hostID: $0, defaults: streamSettingsDefaults)
                } ?? false
                remoteAudio = RemoteAudioSession(preferred: audioPreferred)
                updateRemoteAudioSuspensionOnQueue()
                if let request = remoteFeatures.pong(flags: header.flags, now: ProcessInfo.processInfo.systemUptime,
                                                     requestRemoteFiles: true, requestSecureDesktop: remoteSecureDesktopEnabled,
                                                     requestRemoteAudio: audioPreferred,
                                                      requestClipboard: clipboardProbe && wantsRemoteClipboard) {
                    remoteAudioRequested = audioPreferred
                    sendWireMessage(type: .remoteFeaturesRequest, payload: request, sequence: 0)
                } else if remoteSecureDesktopEnabled {
                    beginAdaptiveProbeOnQueue()
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
                qualityRttSeconds = rttMs / 1000
                qualityWindow.recordRtt(us: AdaptiveMediaWindow.us(rttMs / 1000), now: CACurrentMediaTime())
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

        case .qualityCapabilities, .qualityState, .qualityConfiguration:
            receiveAdaptiveOnQueue(type: header.type, payload: payload, flags: header.flags, sequence: header.sequence)
        case .qualityHello, .qualityPolicySet, .qualityFeedback, .qualityConfigurationAck:
            return
        case .videoFeedback:
            return

        case .audio:
            guard committedTransportGeneration == generation, !remoteSecureDesktop.restrictsFeatures else { return }
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
                wifiMediaReceiver.setCaptureSuspended(captureAvailability.inputBlocked)
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

        case .remoteFileState, .remoteFilePacket, .remoteFileWindow:
            receiveRemoteFileOnQueue(header, payload: payload)
        case .remoteSecureDesktopState, .remoteSasAvailability:
            receiveRemoteSecureDesktopOnQueue(header, payload: payload)
        case .remoteAudioState, .remoteAudioPacket, .remoteTimedVideo:
            receiveRemoteAudioOnQueue(message, generation: generation)
        case .remoteFileControl, .remoteAudioSet, .remoteSecureDesktopRequest:
            handleStreamError("Unnegotiated remote feature message.")
        case .clipboardState, .clipboardOffer, .clipboardOfferResponse, .clipboardChunk,
             .clipboardEnd, .clipboardResult, .clipboardCancel:
            receiveRemoteClipboard(type: header.type, flags: header.flags, payload: payload)
        case .clipboardHello, .clipboardControl, .castingClipboardHello:
            handleStreamError("Invalid remote clipboard direction.")
        case .remoteFeaturesResult:
            guard remoteInputConnection, remoteFeatures.result(flags: header.flags, payload: payload) else {
                handleStreamError("Invalid remote feature result."); return
            }
            beginRemoteClipboard()
            let intent = remoteSecureDesktop.begin(accepted: remoteFeatures.accepted,
                                                   control: remoteSecureControlIntent && remoteSecureDesktopEnabled)
            remoteAudioFeaturesReceived = true
            updateRemoteAudioSuspensionOnQueue()
            sendRemoteAudioOnQueue(remoteAudio.negotiate(granted: mayReceiveRemoteAudio))
            publishRemoteAudioOnQueue()
            publishRemoteSecureDesktopOnQueue()
            if let intent { sendRemoteSecureDesktopOnQueue(intent) }
            if remoteSecureDesktopEnabled { beginAdaptiveProbeOnQueue() }
            remoteMonitors.begin(session: UUID(), acceptedFeatures: remoteFeatures.accepted)
            if mayReceiveRemoteFiles { remoteFileAccess = RemoteFileAccess() }
            remoteMonitorAdmission = nil
            publishRemoteInputOnQueue()
            requestRemoteCatalogueOnQueue()
        case .remoteInputContext:
            let previousDesktopEpoch = remoteFeatures.context?.desktopEpoch
            guard remoteInputConnection, remoteFeatures.receiveContext(flags: header.flags, payload: payload) else {
                handleStreamError("Invalid remote input context."); return
            }
            if remoteTimedVideoLatched, let previousDesktopEpoch, previousDesktopEpoch != remoteFeatures.context?.desktopEpoch {
                recoverRemoteTimedVideoOnQueue()
            }
            if let context = remoteFeatures.context,
               remoteFileAccess?.desktopRequiresRevocation(context) == true {
                revokeRemoteFilesOnQueue()
            }
            if remoteSecureDesktop.supported, let context = remoteFeatures.context,
               let desktop = RemoteSecureDesktopProtocol.Desktop(rawValue: context.desktop) {
                let change = remoteSecureDesktop.observeDesktop(desktop, adaptiveOwner: qualitySession?.owner != nil,
                                                               timedVideo: remoteTimedVideoLatched)
                if change != .unchanged { fenceRemoteSecureDesktopOnQueue(change); return }
                if !remoteSecureDesktop.allowsScanAndPointer { remoteFeatures.invalidateInput() }
                else if remoteSecureDesktop.hasPresentedBarrier { remoteFeatures.keyframeArrived() }
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
                if remoteTimedVideoLatched, result.status == 0 { recoverRemoteTimedVideoOnQueue() }
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


    private func receiveWireVideoOnQueue(_ message: WireMessage, generation: UInt64, timedCaptureUs: UInt64? = nil) {
        let header = message.header, payload = message.payload
        guard committedTransportGeneration == generation else { return }
        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
            // A legacy payload cannot authorize its own transition. The
            // exact host commit must arrive first on authenticated TLS.
            return
        }
        let isIDR = header.flags & WireProtocol.videoFlagIDR != 0
        let lengthPrefixed = header.flags & WireProtocol.videoFlagLengthPrefixed != 0
        #if targetEnvironment(simulator)
        let receivedAt = connectionVideoReceivedAtForTesting ?? CACurrentMediaTime()
        #else
        let receivedAt = CACurrentMediaTime()
        #endif
        if remoteSecureDesktop.supported {
            let decoderGeneration = decoder.currentSessionGeneration
            let verifiedIDR = isIDR && (!remoteSecureDesktop.expectsIDR ||
                RemoteSecureDesktopState.hasIDR(payload, lengthPrefixed: lengthPrefixed))
            switch remoteSecureDesktop.admit(sequence: header.sequence, isIDR: verifiedIDR, decoder: decoderGeneration) {
            case .invalid:
                handleStreamError("Invalid secure desktop first picture."); return
            case .drop: return
            case .barrier:
                decoder.authorizeCaptureOutput(sequence: header.sequence, generation: decoderGeneration)
                decoder.processInputData(payload, sequence: header.sequence, isIDR: true,
                                         isLengthPrefixed: lengthPrefixed, receivedAt: receivedAt)
                let sequence = header.sequence
                networkQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                          self.remoteSecureDesktop.awaitsPresentation(sequence: sequence, decoder: decoderGeneration) else { return }
                    self.handleStreamError("Secure desktop first picture was not presented.")
                }
                return
            case .pass:
                if qualityProbe.phase == .idle { beginAdaptiveProbeOnQueue() }
            }
        }
        if mayReceiveRemoteFiles { remoteFilePacing.received(bytes: payload.count) }
        let qualityReceivedAt = adaptiveNow()
        if qualitySession?.usesOrderedVideo == true, qualitySession?.current != nil {
            if castingAdaptiveRoute?.usesOrderedVideo == true, captureAvailability.wireSuspended {
                qualityWindow.drop(3)
                return
            }
            guard admitOrderedAdaptiveVideoOnQueue(payload, sequence: header.sequence, isIDR: isIDR,
                                                  lengthPrefixed: lengthPrefixed) else { return }
        }
        guard adaptiveIncomingOnQueue(payload, sequence: header.sequence, isIDR: isIDR,
            receivedAt: qualityReceivedAt, receiveUs: AdaptiveMediaWindow.us(receivedAt-message.firstByteAt)) else { return }
        captureAvailability.noteFrameReceived(sequence: header.sequence)
        if consumeConnectionVideoOnQueue(payload, sequence: header.sequence,
            isIDR: header.flags & WireProtocol.videoFlagIDR != 0,
            lengthPrefixed: header.flags & WireProtocol.videoFlagLengthPrefixed != 0,
            receivedAt: receivedAt, domain: .scst) { return }
        if !captureTargetOwnsPresentation {
            guard mirrorControl.permitsVideoSequence(header.sequence) else { return }
        }
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
        guard admitCaptureContinuationOnQueue(sequence: header.sequence, decoder: decoder.currentSessionGeneration,
            isIDR: header.flags & WireProtocol.videoFlagIDR != 0) else { return }
        #if targetEnvironment(simulator)
        if let decode = captureTargetDecodeForTesting, remoteInputConnection || castingAdaptiveRoute?.usesOrderedVideo == true {
            decode(payload, header.sequence, decoder.currentSessionGeneration)
            return
        }
        #endif
        if let timedCaptureUs {
            remoteVideoTiming.record(sequence: header.sequence, generation: decoder.currentSessionGeneration,
                                     captureUs: timedCaptureUs, receivedAt: receivedAt)
        }
        decoder.processInputData(
            payload,
            sequence: header.sequence,
            isIDR: (header.flags & WireProtocol.videoFlagIDR) != 0,
            isLengthPrefixed:
                (header.flags & WireProtocol.videoFlagLengthPrefixed) != 0,
            receivedAt: receivedAt)
    }

    private var activeTransportKind: ActiveTransportKind {
        committedConnectionRoute == .usb || committedConnectionRoute == .unknown && usbListenerExplicitlyStarted ? .usb : .wifi
    }

    private func isCurrentCommittedUsbStreamingSessionOnQueue(
        generation: UInt64? = nil
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard activeTransportKind == .usb,
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
        if activeTransportKind == .usb && !connectionHandoffInProgress { releasePresentedSourceOnQueue() }
        if captureTargets.pending != nil || captureTargets.applied != nil { abandonCaptureTargetPresentationOnQueue() }
        committedPipelineMode.request(desiredPipelineMode)
        sendWireMessage(
            type: .pipelineMode,
            payload: desiredPipelineMode.encode(),
            sequence: 0)
        recordDiagnosticLine(
            "[IPAD][PIPELINE_MODE] mode=\(desiredPipelineMode) reason=\(reason)")
    }

    private var deferredSourceDisplay: (preference: DisplayPreference, orientation: ClientDisplayOrientation)?

    private func flushDeferredSourceDisplayOnQueue() {
        guard !captureTargets.isSwitching, let deferred = deferredSourceDisplay else { return }
        deferredSourceDisplay = nil
        requestDisplayConfiguration(preference: deferred.preference, interfaceOrientation: deferred.orientation)
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

        if captureTargets.isSwitching {
            deferredSourceDisplay = (preference, interfaceOrientation)
            return
        }

        let reconciledPreference = preference.reconciled(with: capabilities)
        latestDisplayPreference = reconciledPreference
        let proposed = reconciledPreference.makeRequest(
            interfaceOrientation: interfaceOrientation,
            requestId: 0)
        guard let request = displayRequestGate.begin(proposed) else { return }
        if connectionHandoffInProgress, connectionSwitch.pending != nil {
            trackConnectionDisplayRequestOnQueue(request.requestId)
        }
        releasePresentedSourceOnQueue()
        pendingDisplayPreference = reconciledPreference
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayConfigurationPending = true
            self?.displayConfigurationFailureMessage = nil
        }
        sendDisplayConfigurationRequest(request)
    }

    private func releasePresentedSourceOnQueue() {
        if captureTargets.releasePresentedSourceForDisplayChange() {
            // This source already rendered. Return video to the ordinary display
            // path and preserve the completed switch outcome.
            let state = mirrorControl.currentState
            mirrorDecoderLock.lock()
            if let owner = captureTargetDecoderOwner, let state {
                mirrorDecoderOwner = MirrorDecoderOwner(connection: owner.generation, decoder: owner.decoder,
                    epoch: state.epoch, source: state.source)
            }
            captureTargetDecoderOwner = nil
            mirrorDecoderLock.unlock()
            captureTargetVideo.reset()
            captureTargetDecodeStarted = false
            captureTargetLastVideoSequence = nil
            publishMirrorStateOnQueue()
        }
    }

    private func sendDisplayConfigurationRequest(
        _ request: DisplayConfigurationRequest, continuingChain: Bool = false
    ) {
        let inheritedChain = continuingChain ? displayRotationChainID : displayRotationDiagnostic?.chainID
        finishDisplayRotationDiagnostic(outcome: "superseded")
        let changesOrientation = displayRequestGate.effective.map { $0.orientation != request.orientation } ?? false
        displayRotationChainID = inheritedChain ?? (changesOrientation ? request.requestId : nil)
        if let chainID = displayRotationChainID {
            displayRotationDiagnostic = DisplayRotationDiagnostic(
                request: request, chainID: chainID, transport: activeTransportKind,
                startedAt: CACurrentMediaTime())
            networkQueue.asyncAfter(deadline: .now() + .seconds(20)) { [weak self] in
                guard let self, self.displayRotationDiagnostic?.request.requestId == request.requestId else { return }
                self.finishDisplayRotationDiagnostic(outcome: "timeout")
            }
        }
        if activeTransportKind == .usb {
            recordUsbLifecycleDiagnostic(
                "[USB_RECONNECT_DISPLAY] generation=\(connectionGeneration) desiredOrientation=\(request.orientation)")
        }
        sendWireMessage(type: .displayConfigurationRequest, payload: request.encode(),
            sequence: request.requestId) { [weak self] error in
                guard let self, self.displayRotationDiagnostic?.request.requestId == request.requestId else { return }
                guard error == nil else {
                    self.finishDisplayRotationDiagnostic(outcome: "send_failed")
                    return
                }
                self.displayRotationDiagnostic?.sentAt = CACurrentMediaTime()
            }
    }

    private func finishDisplayRotationDiagnostic(outcome: String) {
        guard let rotation = displayRotationDiagnostic else { return }
        displayRotationDiagnostic = nil
        func elapsed(_ time: TimeInterval?) -> String {
            guard let time else { return "-" }
            return String(Int(max(0, time - rotation.startedAt) * 1_000))
        }
        let request = rotation.request
        let line =
            "[DISPLAY_ROTATION] request=\(request.requestId) chain=\(rotation.chainID) transport=\(rotation.transport) " +
            "size=\(request.width)x\(request.height) sent_ms=\(elapsed(rotation.sentAt)) " +
            "ack_ms=\(elapsed(rotation.readyAt)) first_present_ms=\(elapsed(rotation.presentedAt)) " +
            "elapsed_ms=\(elapsed(CACurrentMediaTime())) outcome=\(outcome)"
        recordDiagnosticLine(line)
        #if targetEnvironment(simulator)
        displayRotationDiagnosticSinkForTesting?(line)
        #endif
    }

    private func finishPresentedDisplayRotationIfReady() {
        guard let rotation = displayRotationDiagnostic,
              rotation.readyAt != nil, rotation.presentedAt != nil else { return }
        finishDisplayRotationDiagnostic(outcome: "presented")
    }

    private func receiveDisplayReady(_ ready: DisplayReady) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard displayRequestGate.pending?.requestId == ready.requestId else {
            return
        }
        let nextRequest = displayRequestGate.accept(ready)
        guard displayRequestGate.effective?.requestId == ready.requestId else { return }
        if captureTargetOwnsPresentation { abandonCaptureTargetPresentationOnQueue() }
        if displayRotationDiagnostic?.request.requestId == ready.requestId {
            displayRotationDiagnostic?.readyAt = CACurrentMediaTime()
            finishPresentedDisplayRotationIfReady()
        }
        if let nextRequest,
           let latestPreference = latestDisplayPreference {
            if connectionHandoffInProgress {
                trackConnectionDisplayRequestOnQueue(nextRequest.requestId)
            }
            pendingDisplayPreference = latestPreference
            sendDisplayConfigurationRequest(nextRequest, continuingChain: true)
            return
        }
        guard let appliedPreference = pendingDisplayPreference else {
            return
        }
        if connectionHandoffInProgress, connectionDisplayRequest == ready.requestId {
            connectionDisplayReady = true
            connectionReadyDisplay = ready
            recordDiagnosticLine("[CONNECTION_CONTROL] event=display_ready request=\(ready.requestId)")
            advanceConnectionVideoOnQueue()
        }
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
        if displayRotationDiagnostic?.request.requestId == failure.requestId {
            finishDisplayRotationDiagnostic(outcome: "rejected")
        }
        let nextRequest = displayRequestGate.reject(failure)
        if let nextRequest,
           let latestPreference = latestDisplayPreference {
            if connectionHandoffInProgress {
                trackConnectionDisplayRequestOnQueue(nextRequest.requestId)
            }
            pendingDisplayPreference = latestPreference
            sendDisplayConfigurationRequest(nextRequest, continuingChain: true)
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
        decoder.configureRefreshRate(remoteInputConnection ? 120 : UInt32(PipelineMode.office.targetFps))
        finishDisplayRotationDiagnostic(outcome: "session_ended")
        displayRotationChainID = nil
        orientationDebounceWorkItem?.cancel()
        orientationDebounceWorkItem = nil
        deferredSourceDisplay = nil
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
        if !adaptiveQualityTransport { reconnectAttempt = 0 }
        refreshAdaptiveQualityPreferenceOnQueue()
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
        negotiateCaptureTargetsOnQueue()
        requestCurrentSettingsIfNeeded(generation: generation)
        beginAdaptiveProbeOnQueue()
        refreshClipboardOnQueue()
        if connectionSwitch.pending?.rollingBack == true { advanceConnectionVideoOnQueue() }
        if activeTransportKind == .usb {
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
        refreshClipboardOnQueue()
        committedTransportAudioAvailable = true
        wifiMediaReceiver.clearOffer()
        decoder.fenceCaptureContinuation()
        decoder.invalidate(waitForCompletion: usbListener == nil)
        resetAdaptiveMediaOnQueue(preserveHostPreference: true)
        pendingClientPings = pendingClientPings.filter { $0.value.purpose != .telemetry }
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
        transportTelemetry.beginRuntimeSession()
        if committedPipelineMode.active != nil { transportTelemetry.beginFreshFrameRate(generation: generation) }
        startLegacyTelemetryTimers()
        AudioManager.shared.reset()
        reconcileRealtimeAudioPlayback(
            generation: generation, mode: RealtimeTransportMode.legacyTLS,
            audioEnabled: clientSettingsState.effective.audioEnabled)
        if qualityHostID != nil {
            settingsReconciliationGate.reset()
            settingsSyncPolicy.reset()
            requestCurrentSettingsIfNeeded(generation: generation)
        }
        return true
    }

    // Removed: inactive four-byte video framing and recursive Data
    // accumulation. The SCST loop above is the sole receive path.

    // MARK: - Private: Stream Error Helper

    private func handleStreamError(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if usbControlTLSAwaitingProof { failSecureUsbOnQueue(); return }
        if connectionHandoffInProgress || connectionSwitch.pending != nil {
            if recoverConnectionControlOnQueue(.connectionLost) { return }
            if connection != nil { teardownCurrentSession() }
            setState(.disconnected(reason: "Connection lost"))
            return
        }
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
        scheduleAutoReconnect()
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
        if handleConnectionRetirementOnQueue(connection: connection, generation: generation, source: .socket) { return }
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
        wifiAuthentication = WifiAuthenticationState()
        dispatchPrecondition(condition: .onQueue(networkQueue))
        resetUsbControlTLSOnQueue()
        usbIdentityDeadline?.cancel(); usbIdentityDeadline = nil
        finishPendingTrustedHostForget(generation: connectionGeneration, confirmed: false, closeSession: false)
        // Reset only at retirement. A later unresolved cutover must still
        // preserve the current retry delay.
        if manualReconnectHealthy, !adaptiveMediaUnsettled { reconnectAttempt = 0 }
        pairedControlGeneration = nil; trustedProofGeneration = nil; connectionAdvertisement = 0
        if !connectionHandoffInProgress { resetConnectionControlOnQueue(preserveFailure: connectionSwitch.offersReconnect) }
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
        // A Wi-Fi incumbent can retire while the USB handoff listener already accepts on this queue.
        decoder.invalidate(waitForCompletion: activeTransportKind != .usb && usbListener == nil)
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
    func commitCastingClipboardRouteForTesting(usb: Bool, tls: Bool) -> (connection: NWConnection, generation: UInt64) {
        let owner = simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        networkQueue.sync {
            controlChannelWriter.abandonConnection()
            controlChannelWriter.begin(generation: owner.generation)
            wireParser.reset(generation: owner.generation)
            committedConnectionRoute = usb ? .usb : .wifi
            usbScdpConnection = usb ? owner.connection : nil
            pairedControlGeneration = owner.generation
            castingClipboardTLSForTesting = tls
            refreshClipboardOnQueue()
        }
        return owner
    }

    func beginRemoteClipboardForTesting(remoteFiles: Bool = false) -> (connection: NWConnection, generation: UInt64) {
        let owner = simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        networkQueue.sync {
            controlChannelWriter.begin(generation: owner.generation)
            wireParser.reset(generation: owner.generation)
            pairedControlGeneration = owner.generation
            trustedCredential = TrustedHostCredential(fingerprint: "", hostID: Data(count: 16), deviceID: Data(),
                                                       secret: Data(), sessionID: Data())
            _ = remoteFeatures.begin(now: 0)
            _ = remoteFeatures.pong(flags: Clipboard.marker, now: 1, requestRemoteFiles: remoteFiles, requestClipboard: true)
            let fileFeatures = remoteFiles ? RemoteFeatureNegotiation.remoteFileFeature : 0
            let payload = RemoteFeaturesMessage(features: Clipboard.features | 3 | fileFeatures).encode()
            handleWireMessage(WireMessage(header: WireHeader(type: .remoteFeaturesResult, flags: 0,
                payloadLength: payload.count, sequence: 0), payload: payload, firstByteAt: 0), generation: owner.generation)
        }
        let context = RemoteInputContextCommand(state: 1, desktop: 1, token: 1, desktopEpoch: 1,
                                                left: 0, top: 0, width: 1, height: 1)
        receiveRemoteMonitorContextForTesting(context, keyframe: true)
        return owner
    }

    var hasReservedRemoteFileWriteForTesting: Bool {
        networkQueue.sync { remoteFilePacing.nextWrite > 0 }
    }

    func setRemoteFilePacingForTesting(healthy: Bool) {
        networkQueue.sync {
            remoteFilePacing = RemoteFileMediaPacing()
            if healthy {
                let now = ProcessInfo.processInfo.systemUptime
                remoteFilePacing.feedback(now: now - 1.25, presented: 0, queueAge: 0, drops: 0)
                remoteFilePacing.received(bytes: 1_000_000)
                remoteFilePacing.feedback(now: now, presented: 1, queueAge: 0, drops: 0)
            }
            controlChannelWriter.drain()
        }
    }

    func receiveClipboardWireForTesting(_ bytes: Data, generation: UInt64, connection owner: NWConnection) {
        networkQueue.sync {
            guard generation == connectionGeneration, activeControlConnection === owner,
                  wireAuthenticatedGeneration == generation, committedTransportGeneration == generation else { return }
            wireParser.consume(bytes, generation: generation) { [weak self] event in
                self?.handleWireParserEvent(event, generation: generation)
            }
        }
    }

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
            let receivedAt = CACurrentMediaTime()
            guard adaptiveIncomingOnQueue(data, sequence: sequence, isIDR: isIDR,
                                          receivedAt: receivedAt, receiveUs: nil) else { return }
            captureAvailability.noteFrameReceived(sequence: sequence)
            _=consumeCaptureTargetVideoOnQueue(data, sequence: sequence, isIDR: isIDR,
                                               lengthPrefixed: true, receivedAt: receivedAt)
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
    func beginRemoteMonitorForTesting(acceptedFeatures: UInt64, requestRemoteFiles: Bool = false) {
        networkQueue.sync {
            remoteInputConnection = true
            resetRemoteInputOnQueue()
            _ = remoteFeatures.begin(now: 0)
            _ = remoteFeatures.pong(flags: 0x4000, now: 1, requestRemoteFiles: requestRemoteFiles)
            let payload = RemoteFeaturesMessage(features: acceptedFeatures).encode()
            handleWireMessage(WireMessage(header: WireHeader(type: .remoteFeaturesResult, flags: 0,
                payloadLength: payload.count, sequence: 0), payload: payload, firstByteAt: 0), generation: connectionGeneration)
        }
    }
    func backgroundRemoteFilesForTesting() {
        networkQueue.sync { backgroundRemoteFilesOnQueue() }
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
    func requestCurrentSettingsForTesting(generation: UInt64) {
        networkQueue.sync { requestCurrentSettingsIfNeeded(generation: generation) }
    }
    func sendDesiredSettingsForTesting() -> DesiredSettingsSendResult {
        networkQueue.sync { sendDesiredSettingsIfPossible(reason: "test_explicit_change") }
    }
    func enqueueTransferWireForTesting(bulk: Bool, completion: @escaping (NWError?) -> Void) {
        networkQueue.async {
            self.sendWireMessage(type: bulk ? .transferEnd : .ping, payload: Data(count: bulk ? 25 : 16), sequence: 0, bulk: bulk, completion: completion)
        }
    }

    var realtimeAudioPlaybackForTesting: ((Bool) -> Void)?
    var controlSendForAudioTesting: ((Data, @escaping (NWError?) -> Void) -> Void)?

    func sendTelemetryPingForTesting() -> UInt64? {
        networkQueue.sync { sendClientPing(force: true, purpose: .telemetry) }
    }

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

    func useAutomaticOrientationForTesting() {
        networkQueue.sync { activeDisplayPreference = .defaultValue }
    }

    func runOrientationDebounceForTesting() {
        networkQueue.sync {
            orientationDebounceWorkItem?.perform()
            orientationDebounceWorkItem?.cancel()
            orientationDebounceWorkItem = nil
        }
    }

    func simulateCommittedWifiSessionForTesting(
        mode: UInt8 = RealtimeTransportMode.wifiRTP,
        remote: Bool = false
    ) -> (connection: NWConnection, generation: UInt64) {
        networkQueue.sync {
            let peer = NWConnection(host: "127.0.0.1", port: 27015, using: .tcp)
            let generation = connectionGenerationClock.advance()
            resetAutoAcceptOnQueue()
            advanceReceivedRevisionOnQueue()
            resetDirectTouchSessionOnQueue()
            // Match production Wi-Fi setup: each connection has its own settings revisions and retry budget.
            clientSettingsState.resetHostGeneration()
            settingsReconciliationGate.reset()
            settingsSyncPolicy.reset()
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
            // Match connect(to:): session role is selected locally, not by feature-result packets.
            remoteInputConnection = remote
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGenerationClock.current == generation else { return }
                self.isRemoteControlSession = remote
            }
            beginOwnedDecoderSession(networkGeneration: generation)
            setState(.streaming)
            return (peer, generation)
        }
    }

    func stopForTesting() {
        networkQueue.sync { self.stopOnQueue() }
    }

    var reconnectAttemptForTesting: Int {
        get { networkQueue.sync { reconnectAttempt } }
        set { networkQueue.sync { reconnectAttempt = newValue } }
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
        if newState != .submittingPIN {
            pinResponseDeadline?.cancel()
            pinResponseDeadline = nil
        }
        transportState = newState
        if case .authFailed = newState { resetAutoAcceptOnQueue() }
        if newState == .streaming {
            triedWifiReconnectTargets.removeAll()
            publishAutoReconnectAttempt(0)
        }
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
    private var screenSwitchInProgressOnQueue: Bool { captureTargets.isSwitching || mirrorSwitchPending }
    private var currentCaptureTargetDecoderOwner: CaptureTargetDecoderOwner? {
        mirrorDecoderLock.lock();defer { mirrorDecoderLock.unlock() };return captureTargetDecoderOwner
    }
    public func legacyInputIsCurrent(revision: UInt64) -> Bool {
        mirrorControl.legacyRegistrationIsCurrent(revision: revision)
    }
    var legacyVirtualInputSuspended: Bool { mirrorControl.isLegacyVirtualInputSuspended }

    @MainActor public func requestCaptureTarget(_ id: UInt64, catalogue: CaptureTargetCatalogue) {
        let generation=connectionGenerationClock.current
        guard networkQueue.sync(execute: { connectionSwitch.pending == nil && displayRequestGate.pending == nil }) else { return }
        // Retire held input on the caller before any queue admission or early
        // rejection. Releasing a key/button must not depend on catalogue age.
        captureTargetRetireInput?()
        let admitted: (CaptureTargetRequest, UUID, NWConnection)? = networkQueue.sync {
            guard !remoteInputConnection, generation == connectionGeneration,
                  wireAuthenticatedGeneration == generation, committedTransportGeneration == generation,
                  connectionSwitch.pending == nil, displayRequestGate.pending == nil,
                  let connection=activeControlConnection else {
                recordDiagnosticLine("[CAPTURE_TARGET] event=local_rejection reason=connection_unavailable"); return nil
            }
            // Only the host knows when this catalogue was issued. Send the
            // exact selected authority once; a Stale result refreshes it.
            let session=captureTargets.session
            guard let request=captureTargets.select(id, catalogue: catalogue, session: session) else {
                recordDiagnosticLine("[CAPTURE_TARGET] event=local_rejection reason=selection_unavailable"); return nil
            }
            retirePendingAdaptiveOnQueue()
            cancelCaptureTargetRecoveryOnQueue()
            captureTargetMirrorRevisionAtTap=mirrorControl.currentState?.revision ?? 0
            return (request, session, connection)
        }
        guard let (request, session, connection)=admitted else { return }
        // Drain the retired callbacks' queued encodes before blocking their old tickets.
        networkQueue.sync { mirrorControl.setCaptureTargetInputBlocked(true, session: generation) }
        networkQueue.async { [weak self] in
            guard let self, self.captureTargets.session == session,
                  self.captureTargets.pending?.request == request, self.connectionGeneration == generation,
                  self.activeControlConnection === connection, let payload=try? request.encode() else { return }
            self.sendWireMessage(type: .sourceSwitchRequest, payload: payload, sequence: 0)
            self.publishMirrorStateOnQueue()
            self.scheduleCaptureTargetTerminalWaitOnQueue(request, connection: connection, accepted: false)
        }
    }
    private func scheduleCaptureTargetTerminalWaitOnQueue(_ request: CaptureTargetRequest, connection: NWConnection,
                                                         accepted: Bool) {
        let session = captureTargets.session
        scheduleCaptureTargetCallback(CaptureTargetProtocol.terminalWait) { [weak self, weak connection] in
            guard let self, let connection, self.activeControlConnection === connection,
                  self.captureTargets.pending?.accepted == accepted,
                  self.captureTargets.expire(transaction: request.transaction, session: session) else { return }
            self.retireCaptureTargetDecoderOnQueue()
            self.refreshCaptureTargetsOnQueue();self.publishMirrorStateOnQueue()
            self.flushDeferredSourceDisplayOnQueue()
        }
    }
    private func negotiateCaptureTargetsOnQueue() {
        let generation = connectionGeneration
        guard !remoteInputConnection, wireAuthenticatedGeneration == generation,
              committedTransportGeneration == generation, captureTargetAdvertisementGeneration == generation,
              let hello = captureTargets.advertise(flags: connectionAdvertisement, generation: generation) else { return }
        mirrorControl.enableTypedSources(session: generation)
        sendWireMessage(type: .sourceHello, payload: hello, sequence: 0)
        scheduleCaptureTargetListWaitOnQueue()
        publishMirrorStateOnQueue()
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
        let deadline = captureReadinessNow() + seconds
        scheduleCaptureProgressCallback(seconds, deadline: deadline, recovery: recovery, completion: completion)
    }
    private func scheduleCaptureProgressCallback(_ seconds: TimeInterval, deadline: TimeInterval,
                                                 recovery: Bool, recheck: Bool = false,
                                                 completion: @escaping () -> Void) {
        let generation = connectionGeneration
        let recoveryToken = captureTargetRecoveryToken
        let checked = { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            if recovery && self.captureTargetRecoveryToken != recoveryToken { return }
            let remaining = deadline - self.captureReadinessNow()
            if self.captureAvailability.negotiated && (self.captureAvailability.inputBlocked || remaining > 0) {
                self.scheduleCaptureProgressCallback(max(0.05, min(1, remaining)), deadline: deadline,
                    recovery: recovery, recheck: true, completion: completion)
                return
            }
            completion()
        }
        #if targetEnvironment(simulator)
        if let schedule=captureTargetScheduleForTesting { schedule(seconds, checked);return }
        #endif
        let work=DispatchWorkItem(block: checked)
        if recovery && !recheck { captureTargetRecoveryWork.append(work) }
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
        captureTargets.abandonPresentation(session: captureTargets.session, allowSameSourceReattach: captureAvailability.negotiated)
        mirrorControl.setCaptureTargetInputBlocked(true)
        retireCaptureTargetDecoderOnQueue()
        refreshCaptureTargetsOnQueue();publishMirrorStateOnQueue()
        flushDeferredSourceDisplayOnQueue()
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
        guard admitCaptureContinuationOnQueue(sequence: frame.sequence, decoder: owner.decoder, isIDR: frame.isIDR) else { return }
        captureTargetLastVideoSequence=frame.sequence
        submitCaptureTargetFrameOnQueue(frame, generation: owner.decoder)
    }
    private func submitCaptureTargetFrameOnQueue(_ frame: CaptureTargetVideoBuffer.Frame, generation: UInt64) {
        #if targetEnvironment(simulator)
        if let decode=captureTargetDecodeForTesting { decode(frame.data, frame.sequence, generation);return }
        #endif
        submitVideoOnQueue(frame.data, sequence: frame.sequence, isIDR: frame.isIDR,
                           lengthPrefixed: frame.lengthPrefixed, receivedAt: frame.receivedAt)
    }
    /// Both the TLS parser and authenticated RTP access-unit owner pass through this same gate.
    private func consumeCaptureTargetVideoOnQueue(_ data: Data, sequence: UInt32, isIDR: Bool,
                                                  lengthPrefixed: Bool, receivedAt: TimeInterval) -> Bool {
        guard captureTargetOwnsPresentation else { return false }
        let frame=CaptureTargetVideoBuffer.Frame(data: data, sequence: sequence, isIDR: isIDR,
                                                lengthPrefixed: lengthPrefixed, receivedAt: receivedAt)
        if let pending=captureTargets.pending {
            if pending.accepted { captureTargetVideo.append(frame) }
            else if let rollback=sourceRollback, rollback.request == pending.request,
                    rollback.decoder == decoder.currentSessionGeneration,
                    rollback.identity == (qualitySession?.pending ?? qualitySession?.current)?.identity {
                if let last=captureTargetLastVideoSequence, !MirrorControlCodec.sequenceAtOrAfter(sequence, last &+ 1) { return true }
                if admitCaptureContinuationOnQueue(sequence: sequence, decoder: rollback.decoder, isIDR: isIDR) {
                    captureTargetLastVideoSequence=sequence
                    submitCaptureTargetFrameOnQueue(frame, generation: rollback.decoder)
                }
            }
            return true
        }
        if captureTargets.awaitingReattachIDR {
            guard captureTargets.anchorReattachedSource(sequence: sequence, isIDR: isIDR) else { return true }
        }
        guard let applied=captureTargets.applied,
              MirrorControlCodec.sequenceAtOrAfter(sequence, applied.firstFrame) else { return true }
        if captureTargetDecodeStarted { decodeCaptureTargetFrameOnQueue(frame) }
        else { captureTargetVideo.append(frame);advanceCaptureTargetVideoOnQueue() }
        return true
    }
    private func restoreCaptureTargetAfterRollbackOnQueue(_ result: CaptureTargetResult, selection: CaptureTargetState.Pending?) -> Bool {
        guard let selection, !selection.accepted, let rollback=sourceRollback, rollback.request == selection.request,
              qualitySession?.applied?.identity == rollback.identity, rollback.decoder == decoder.currentSessionGeneration,
              let state=mirrorControl.currentState, state.revision > 0, let kind=result.kind else { return false }
        if kind == .extend {
            guard state.mode == .virtualDisplay else { return false }
        } else {
            guard state.epoch == result.epoch, state.source == result.source, state.geometry != nil,
                  state.firstFrame != nil, state.mode == .viewOnly || state.mode == .awaitingPresentation || state.mode == .active else { return false }
        }
        guard captureTargets.restoreRollbackPresentation(result, previous: selection.previousCatalogue,
                                                         firstFrame: rollback.firstFrame) else { return false }
        // The host confirmed the same source after the rollback presented. Keep that decoder
        // and its dependency chain for the next inter frame while the normal input fences hold.
        captureTargetMirrorRevisionAtTap=state.revision-1
        let owner=CaptureTargetDecoderOwner(session: captureTargets.session, generation: connectionGeneration,
            transaction: result.transaction, owner: result.owner, epoch: result.epoch, source: result.source,
            decoder: rollback.decoder, kind: kind, mirrorEpoch: state.epoch)
        mirrorDecoderLock.lock();captureTargetDecoderOwner=owner;mirrorDecoderOwner=nil;mirrorDecoderLock.unlock()
        captureTargetDecodeStarted=true
        return true
    }
    private func sendCaptureTargetRecoveryOnQueue(_ applied: CaptureTargetResult) {
        guard !captureAvailability.inputBlocked, captureTargets.applied == applied, wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration, let payload=try? applied.recoveryPayload() else { return }
        sendWireMessage(type: .videoFeedback, payload: payload, sequence: 0, flags: CaptureTargetProtocol.recoveryFlag)
    }
    private func startCaptureTargetRecoveryOnQueue() {
        guard !captureAvailability.inputBlocked, let applied=captureTargets.applied else { return }
        cancelCaptureTargetRecoveryOnQueue()
        let token=UUID(), session=captureTargets.session
        captureTargetRecoveryToken=token
        if !captureTargetDecodeStarted { sendCaptureTargetRecoveryOnQueue(applied) }
        for second in 1...5 {
            scheduleCaptureTargetCallback(TimeInterval(second), recovery: true) { [weak self] in
                guard let self, self.captureTargetRecoveryToken == token, self.captureTargets.session == session,
                      let current = self.captureTargets.applied, current.transaction == applied.transaction,
                      self.captureTargets.inputBlocked, !self.captureAvailability.inputBlocked else { return }
                if second == 5 { self.abandonCaptureTargetPresentationOnQueue() }
                else { self.sendCaptureTargetRecoveryOnQueue(current) }
            }
        }
    }
    private func recoverCaptureTargetDecodeRootOnQueue() {
        guard !captureAvailability.inputBlocked, captureTargets.applied != nil else { return }
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

    private func telemetryGeneration(forDecoder generation: UInt64) -> UInt64 {
        mirrorDecoderLock.lock()
        defer { mirrorDecoderLock.unlock() }
        if let owner = connectionDecoder, owner.decoder == generation { return owner.network }
        if let owner = captureTargetDecoderOwner, owner.decoder == generation { return owner.generation }
        if let owner = mirrorDecoderOwner, owner.decoder == generation { return owner.connection }
        return generation
    }

    // MARK: - Connection control (casting only, CC-01 through CC-21)
    private func connectionPairingMatches(_ credential: TrustedHostCredential?) -> Bool {
        guard let credential, let original = connectionSelectedCredential else { return false }
        return credential.fingerprint == original.fingerprint && credential.hostID == original.hostID &&
            credential.deviceID == original.deviceID && credential.secret == original.secret
    }
    private func selectedUsbCredentialOnQueue() -> TrustedHostCredential? {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        #if targetEnvironment(simulator)
        if let load = usbIdentityCredentialLoadForTesting { return load() }
        #endif
        let fingerprint = connectionSelectedCredential?.fingerprint ?? trustedHostFingerprintStore.load()
        guard let fingerprint, trustedHostCleanup[fingerprint] == nil else { return nil }
        return trustedCredentialStore.load(fingerprint: fingerprint)
    }

    private var usbControlTLSAwaitingProof: Bool {
        usbControlTLSUpgrade?.advertisedAt != nil && wireAuthenticatedGeneration != connectionGeneration
    }

    private func requiresUsbControlTLS(_ credential: TrustedHostCredential?) -> Bool {
        guard let credential else { return false }
        return credential.usbControlTLSSeen == true || usbTLSAdvertisedHosts.contains(credential.fingerprint)
    }

    private func prepareUsbControlTLSOnQueue(_ candidate: NWConnection) {
        resetUsbControlTLSOnQueue()
        guard let port = usbListener?.port, let credential = selectedUsbCredentialOnQueue(),
              !connectionHandoffInProgress || connectionPairingMatches(credential) else { return }
        let generation = connectionGeneration
        usbControlTLSUpgrade = USBControlTLSUpgrade(listenerPort: port, peer: candidate.endpoint,
             credential: credential, queue: networkQueue, loadIdentity: { [weak self] in
                 #if targetEnvironment(simulator)
                 if let identity = self?.usbServerTLSIdentityForTesting { return identity }
                 #endif
                 return USBServerTLSIdentity()
             }) { [weak self, weak candidate] advertisedAt in
                guard let self, let candidate, self.connection === candidate,
                      self.connectionGeneration == generation else { return }
                self.networkQueue.asyncAfter(deadline: advertisedAt + USBControlTLSUpgrade.budget) { [weak self, weak candidate] in
                    guard let self, let candidate, self.connection === candidate,
                          self.connectionGeneration == generation, self.usbControlTLSAwaitingProof,
                          self.wireReceiveActiveGeneration != generation else { return }
                    self.failSecureUsbOnQueue(.deadlineExceeded)
                }
                if self.selectedUsbCredentialOnQueue() != credential { self.failSecureUsbOnQueue(.identityUnavailable) }
            }
    }

    private func resetUsbControlTLSOnQueue() {
        usbControlTLSUpgrade?.removeRegistration()
        usbControlTLSUpgrade = nil
    }

    private func beginUsbControlTLSProofOnQueue(_ owner: NWConnection, generation: UInt64) {
        guard usbIdentity.phase == .initial else { return }
        let proofDeadline = DispatchTime.now() + USBControlTLSUpgrade.budget
        guard let upgrade = usbControlTLSUpgrade, let advertisedAt = upgrade.advertisedAt,
              DispatchTime.now() < advertisedAt + USBControlTLSUpgrade.budget,
              upgrade.peerVerified,
              let metadata = owner.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              selectedUsbCredentialOnQueue() == upgrade.credential else { failSecureUsbOnQueue(.identityUnavailable); return }
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
        guard version == .TLSv12 || version == .TLSv13 else { failSecureUsbOnQueue(); return }
        if connectionHandoffInProgress { logSwitch(.tlsOK, route: .usb) }
        // A completed handshake authenticates the pinned peer that made this offer.
        usbTLSAdvertisedHosts.insert(upgrade.credential.fingerprint)
        let now = connectionControlNow()
        guard usbIdentity.offer(flags: USBSessionIdentityProof.offerFlag, credential: upgrade.credential,
                                now: now, tlsLeafHash: upgrade.leafHash) == USBSessionIdentityProof.optInFlag,
              let hello = usbIdentity.clientHello(name: "iPad", now: now) else { failSecureUsbOnQueue(); return }
        usbReadinessPongWrittenGeneration = generation
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation, self.usbControlTLSAwaitingProof else { return }
            self.failSecureUsbOnQueue(.deadlineExceeded)
        }
        usbIdentityDeadline = deadline
        networkQueue.asyncAfter(deadline: proofDeadline, execute: deadline)
        if connectionHandoffInProgress { logSwitch(.authSent, route: .usb) }
        sendWireMessage(type: .clientHello, payload: hello, sequence: 0)
    }

    private func failSecureUsbOnQueue(_ reason: ConnectionReason = .proofFailed) {
        if connectionHandoffInProgress {
            if let old = connection, handleConnectionRetirementOnQueue(connection: old, generation: connectionGeneration) { return }
            logSwitch(.tlsFailed, route: .usb, reason: reason)
            if recoverConnectionControlOnQueue(.identityUnavailable) { return }
        } else {
            teardownCurrentSession()
        }
        setState(.disconnected(reason: "Secure USB connection failed - reconnect or re-pair"))
    }

    private func receiveUsbIdentityOnQueue(_ message: WireMessage, generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let header = message.header
        let receivedAt = connectionControlNow()
        usbIdentity.tick(now: receivedAt)
        if header.type == .ping, !usbControlTLSAwaitingProof {
            let selected = selectedUsbCredentialOnQueue()
            guard message.payload.count == 16 else {
                handleStreamError("Expected a 16-byte SCDP Ping before USB session commit."); return
            }
            if header.flags & USBControlTLSUpgrade.flag != 0 {
                failSecureUsbOnQueue()
                return
            }
            if requiresUsbControlTLS(selected) { failSecureUsbOnQueue(); return }
            var credential = header.flags & USBSessionIdentityProof.offerFlag != 0 ? selected : nil
            if connectionHandoffInProgress && !connectionPairingMatches(credential) { credential = nil }
            let flags = usbIdentity.offer(flags: header.flags, credential: credential, now: receivedAt)
            if flags == USBSessionIdentityProof.optInFlag {
                // Start at receipt, including credential lookup and Pong write time.
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self, generation == self.connectionGeneration,
                          self.wireAuthenticatedGeneration == nil else { return }
                    let pongPending = self.usbReadinessPongWrittenGeneration != generation
                    guard pongPending || self.usbIdentity.pending else { return }
                    let remaining = self.usbIdentity.remainingBudget(now: self.connectionControlNow())
                    if remaining > 0, let deadline = self.usbIdentityDeadline {
                        // Recheck the injected monotonic clock; an early timer
                        // cannot shorten the original receipt-based budget.
                        self.networkQueue.asyncAfter(deadline: .now() + remaining, execute: deadline)
                        return
                    }
                    self.usbIdentity.abandon()
                    if pongPending { self.handleStreamError("USB readiness Pong write timed out.") }
                    else { self.finishUsbIdentityOnQueue(generation: generation, identified: false) }
                }
                usbIdentityDeadline = deadline
                networkQueue.asyncAfter(deadline: .now() + max(0, receivedAt + 5 - connectionControlNow()), execute: deadline)
            }
            sendWireMessage(type: .pong, payload: message.payload, sequence: header.sequence, flags: flags) { [weak self] error in
                guard let self, generation == self.connectionGeneration,
                      self.wireAuthenticatedGeneration == nil else { return }
                guard error == nil else {
                    self.usbIdentity.abandon()
                    self.handleStreamError("USB readiness Pong write failed."); return
                }
                self.usbReadinessPongWrittenGeneration = generation
                if flags == USBSessionIdentityProof.optInFlag {
                    guard self.usbIdentity.remainingBudget(now: self.connectionControlNow()) > 0,
                          let hello = self.usbIdentity.clientHello(name: "iPad", now: self.connectionControlNow()) else {
                        self.finishUsbIdentityOnQueue(generation: generation, identified: false); return
                    }
                    if self.connectionHandoffInProgress { self.logSwitch(.authSent, route: .usb) }
                    self.sendWireMessage(type: .clientHello, payload: hello, sequence: 0)
                } else if !self.usbIdentity.pending {
                    self.finishUsbIdentityOnQueue(generation: generation, identified: false)
                }
            }
            return
        }
        guard usbIdentity.optedIn else {
            handleStreamError("Expected a 16-byte SCDP Ping before USB session commit."); return
        }
        if header.type == .trustedDeviceChallenge {
            guard let proof = usbIdentity.answer(message.payload, flags: header.flags, now: connectionControlNow()) else {
                finishUsbIdentityOnQueue(generation: generation, identified: false); return
            }
            sendWireMessage(type: .trustedDeviceProof, payload: proof, sequence: 0)
            return
        }
        if header.type == .trustedAuthResult {
            let live = selectedUsbCredentialOnQueue()
            if !usbControlTLSAwaitingProof && requiresUsbControlTLS(live) { failSecureUsbOnQueue(); return }
            let identified = usbIdentity.result(message.payload, flags: header.flags, currentCredential: live, now: connectionControlNow())
            if identified, var credential = live {
                if usbControlTLSAwaitingProof, credential.usbControlTLSSeen != true {
                    credential.usbControlTLSSeen = true
                    guard trustedCredentialStore.save(credential) else { failSecureUsbOnQueue(); return }
                }
                trustedCredential = credential
            }
            finishUsbIdentityOnQueue(generation: generation, identified: identified)
            return
        }
        if usbIdentity.pending {
            usbIdentity.abandon()
            finishUsbIdentityOnQueue(generation: generation, identified: false)
            return
        }
        handleStreamError("Expected a 16-byte SCDP Ping before USB session commit.")
    }
    private func finishUsbIdentityOnQueue(generation: UInt64, identified: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration, wireAuthenticatedGeneration == nil,
              wireReceiveActiveGeneration == generation,
              usbReadinessPongWrittenGeneration == generation,
              let current = connection, current === usbScdpConnection else { return }
        usbIdentityDeadline?.cancel(); usbIdentityDeadline = nil
        if !identified { usbIdentity.abandon() }
        guard identified else {
            if usbControlTLSAwaitingProof { failSecureUsbOnQueue(); return }
            if connectionHandoffInProgress { recoverConnectionControlOnQueue(.identityUnavailable); return }
            teardownCurrentSession()
            setState(.disconnected(reason: "USB host identity could not be verified. Pair over Wi-Fi first or update the PC host."))
            return
        }
        wireAuthenticatedGeneration = generation
        resetUsbControlTLSOnQueue()
        pairedControlGeneration = identified ? generation : nil
        commitLegacyTransport(generation: generation)
        print("[IPAD][USB_SCDP_READY] generation=\(generation)")
        recordUsbLifecycleDiagnostic("[USB_SCDP_READY] generation=\(generation)")
        if usbIdentity.optedIn { recordDiagnosticLine("[USB_IDENTITY] event=finished identified=\(identified ? 1 : 0)") }
        negotiateConnectionControlOnQueue()
    }
    private func connectionControlNow() -> TimeInterval {
        #if targetEnvironment(simulator)
        if let clock = connectionControlNowForTesting { return clock() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    private func captureReadinessNow() -> TimeInterval {
        captureReadinessClock.now(at: connectionControlNow())
    }
    private static func isAdaptiveControlPacket(_ data: Data) -> Bool {
        guard data.count >= WireProtocol.headerSize,
              data.loadLittleEndian(UInt32.self, at: 0) == WireProtocol.magic else { return false }
        return (93...99).contains(data[5]) ||
            (data[5] == WireMessageType.ping.rawValue &&
             data.loadLittleEndian(UInt16.self, at: 6) == AdaptiveMediaProtocol.probeFlag)
    }

    private func adaptivePacketIsCurrent(_ data: Data) -> Bool {
        guard Self.isAdaptiveControlPacket(data) else { return true }
        guard adaptiveQualityTransport, !connectionHandoffInProgress,
              wireAuthenticatedGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              let connection = activeControlConnection, qualityConnectionID == ObjectIdentifier(connection) else { return false }
        if data[5] == WireMessageType.ping.rawValue {
            return qualityProbe.matchesRequest(Data(data.dropFirst(WireProtocol.headerSize)),
                                               sequence: data.loadLittleEndian(UInt32.self, at: 12))
        }
        // Hello has the nonce first; all other outbound DS2 messages put
        // Owner immediately after the common eight-byte prefix.
        let ownerOffset = data[5] == WireMessageType.qualityHello.rawValue ? 40 : 24
        guard qualityProbe.phase == .enabled, data.count >= ownerOffset + 8,
              let session = qualitySession, session.castingRoute == castingAdaptiveRoute else { return false }
        return data.loadLittleEndian(UInt64.self, at: ownerOffset) == session.owner
    }

    private func connectionControlPacketIsCurrent(_ data: Data) -> Bool {
        if data.count == TouchWireProtocol.packetSize { return !connectionSwitch.inputBlocked }
        guard data.count >= 16 else { return true }
        guard adaptivePacketIsCurrent(data) else { return false }
        if connectionSwitch.inputBlocked && [UInt8(37), 38, 40, 41, 53, 64, 65, 67, 82, 83].contains(data[5]) {
            // Ownership was checked when the terminal was encoded. New input may
            // never leak out of the reliable queue after route admission closes.
            return !CaptureAvailabilityProtocol.isNewInputPacket(data) && !isNewRemoteV2InputPacket(data)
        }
        guard (76...79).contains(data[5]) else { return true }
        guard connectionSwitch.enabled, pairedControlGeneration == connectionGeneration else { return false }
        let payload = Data(data.dropFirst(16))
        if data[5] == 78 {
            guard let request = connectionSwitch.pending?.request else { return false }
            return (try? request.encode()) == payload
        }
        guard data[5] == 76, let hello = try? ConnectionHello.decode(payload) else { return false }
        if hello.kind == .optIn { return true }
        guard let proof = connectionProof, let pending = connectionSwitch.pending,
              hello.transaction == pending.request.transaction, hello.owner == pending.request.owner,
              hello.revision == pending.request.revision, hello.token == proof.token else { return false }
        return hello.kind == .resumeProof && pending.accepted && hello.target == pending.request.target &&
            hello.proof == proof.resumeHello().proof
    }
    public func refreshConnectionStatus() {
        networkQueue.async { [weak self] in
            guard let self, self.connectionSwitch.pending == nil,
                  let payload = self.connectionSwitch.refresh() else { return }
            self.sendWireMessage(type: .connectionHello, payload: payload, sequence: 0)
        }
    }
    public func reconnectConnectionOverWifi() {
        networkQueue.async { [weak self] in
            guard let self, self.connectionSwitch.offersReconnect,
                  let endpoint = self.connectionSelectedEndpoint ?? self.loadWifiReconnectEndpoint() else { return }
            self.resetConnectionControlOnQueue()
            self.teardownCurrentSession()
            self.usbListenerExplicitlyStarted = false
            self.usbListener?.cancel(); self.usbListener = nil
            self.setState(.disconnected(reason: ""))
            self.connectOnQueue(to: endpoint)
        }
    }
    private func logSwitch(_ event: ConnectionSwitchDiagnostic, route: ConnectionRoute, reason: ConnectionReason = .none,
                           source: ConnectionSwitchDiagnostic.Source? = nil) {
        guard let start = switchDiagnosticStart else { return }
        let elapsed = Int(max(0, connectionControlNow() - start) * 1000)
        recordDiagnosticLine(ConnectionSwitchDiagnostic.line(event, route: route, reason: reason,
            attempt: wifiRollbackAttempt, elapsedMs: elapsed, source: source))
    }
    private func publishConnectionControlOnQueue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if connectionLastInputFence != connectionSwitch.inputBlocked {
            connectionLastInputFence = connectionSwitch.inputBlocked
            recordDiagnosticLine("[CONNECTION_CONTROL] event=input_fence blocked=\(connectionLastInputFence ? 1 : 0)")
        }
        mirrorControl.setConnectionInputBlocked(connectionSwitch.inputBlocked)
        refreshClipboardOnQueue()
        let value = connectionSwitch
        if value.pending?.accepted != true || value.pending?.rollingBack == true { switchPictureTarget = nil }
        let heldRoute = switchPictureTarget
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Publication order follows networkQueue; no secret context is copied to UI.
            if self.retainedSwitchRoute != heldRoute { self.retainedSwitchRoute = heldRoute }
            self.connectionSwitchState = value
        }
    }
    private func eraseConnectionProofOnQueue() {
        connectionProof?.erase(); connectionProof = nil
    }
    private func handleConnectionSwitchUSBCandidateOnQueue(_ candidate: NWConnection) -> Bool {
        guard let pending = connectionSwitch.pending else { return false }
        if pending.protectedUSB && !pending.accepted && !pending.rollingBack {
            if pending.probeAnswered { holdConnectionSwitchUSBCandidateOnQueue(candidate) }
            else { startUSBHandoffProbeOnQueue(candidate) }
            return true
        }
        guard connectionHandoffInProgress else { return false }
        if pending.accepted && pending.request.target == .wifi && !pending.rollingBack {
            // Separate socket callbacks can deliver the host's restored USB dial before Wi-Fi loss.
            holdConnectionSwitchUSBCandidateOnQueue(candidate)
        } else if pending.rollbackRoute == .usb || pending.accepted && pending.request.target == .usb && !pending.rollingBack {
            if connectionExpectedRetirement, let old = connection {
                _ = handleConnectionRetirementOnQueue(connection: old, generation: connectionGeneration, source: .usbCandidate)
            }
            if connection == nil && !connectionExpectedRetirement,
               let current = connectionSwitch.pending, current.request == pending.request,
               current.rollbackRoute == pending.rollbackRoute {
                installUsbCandidate(candidate, preserveContinuation: true)
            } else { cancelSwitchCandidate(candidate, source: .candidateBusy) }
        } else { cancelSwitchCandidate(candidate, source: .rollbackRoute) }
        return true
    }
    private func cancelSwitchCandidate(_ candidate: NWConnection, source: ConnectionSwitchDiagnostic.Source) {
        logSwitch(.cancelled, route: .usb, reason: connectionSwitch.issue ?? .localOperation, source: source)
        candidate.cancel()
    }
    private func holdConnectionSwitchUSBCandidateOnQueue(_ candidate: NWConnection) {
        guard connectionUSBCandidate == nil else { cancelSwitchCandidate(candidate, source: .duplicateCandidate); return }
        connectionUSBCandidate = candidate
        #if targetEnvironment(simulator)
        connectionUSBCandidateHeldForTesting?()
        #endif
    }
    private func promoteConnectionSwitchUSBCandidateOnQueue() {
        guard let candidate = connectionUSBCandidate else { return }
        connectionUSBCandidate = nil
        if !handleConnectionSwitchUSBCandidateOnQueue(candidate) { cancelSwitchCandidate(candidate, source: .promotion) }
    }
    private func discardConnectionSwitchUSBCandidateOnQueue(source: ConnectionSwitchDiagnostic.Source = .cleanup) {
        guard let candidate = connectionUSBCandidate else { return }
        connectionUSBCandidate = nil
        cancelSwitchCandidate(candidate, source: source)
    }
    private func retireUSBListenerDuringWifiAttemptOnQueue() -> Bool {
        guard let pending = connectionSwitch.pending, pending.accepted, pending.request.target == .wifi,
              !pending.rollingBack else { return false }
        discardConnectionSwitchUSBCandidateOnQueue(source: .listener)
        closeUSBListenerOnQueue()
        return true
    }
    private func closeUSBListenerOnQueue() {
        guard let listener = usbListener else { return }
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        listener.cancel(); usbListener = nil; listenerGeneration &+= 1
    }
    private func startUSBHandoffProbeOnQueue(_ probe: NWConnection) {
        guard let pending = connectionSwitch.pending, pending.sent,
              pending.originGeneration == connectionGeneration,
              !connectionUSBProbeAttempted else { probe.cancel(); return }
        connectionUSBProbeAttempted = true
        connectionUSBProbe = probe
        connectionUSBProbeDeadline = connectionControlNow() + ConnectionControlProtocol.usbProbeWait
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            guard let self, let probe, self.connectionUSBProbe === probe else { return }
            switch state {
            case .failed, .cancelled:
                self.logSwitch(.probeFailed, route: .usb, reason: .connectionLost)
                self.closeUSBHandoffProbeOnQueue()
            default: break
            }
        }
        probe.start(queue: networkQueue)
        let length = ConnectionControlProtocol.usbProbeLength
        probe.receive(minimumIncompleteLength: length, maximumLength: length + 1) { [weak self, weak probe] data, _, _, error in
            guard let self, let probe, self.connectionUSBProbe === probe else { return }
            guard error == nil, let data, data.count == length else {
                self.logSwitch(.probeFailed, route: .usb, reason: error == nil ? .proofFailed : .connectionLost)
                self.closeUSBHandoffProbeOnQueue(); return
            }
            // Prepare and the probe arrive on different sockets. Either callback can arrive first.
            self.connectionUSBProbeFrame = data
            self.answerUSBHandoffProbeOnQueue()
        }
        networkQueue.asyncAfter(deadline: .now() + ConnectionControlProtocol.usbProbeWait) { [weak self, weak probe] in
            guard let self, let probe, self.connectionUSBProbe === probe else { return }
            self.logSwitch(.probeFailed, route: .usb, reason: .peerTimeout)
            self.closeUSBHandoffProbeOnQueue()
        }
    }
    private func answerUSBHandoffProbeOnQueue() {
        let now = connectionControlNow()
        guard let probe = connectionUSBProbe, let frame = connectionUSBProbeFrame,
              let deadline = connectionUSBProbeDeadline, let proof = connectionProof else { return }
        guard !expireConnectionControlOnQueue(now: now), now < deadline,
              let pong = proof.usbProbeReply(to: frame),
              connectionSwitch.markUSBProbeAnswered(generation: connectionGeneration, now: now) else {
            logSwitch(.probeFailed, route: .usb, reason: now >= deadline ? .peerTimeout : .proofFailed)
            closeUSBHandoffProbeOnQueue(); return
        }
        connectionUSBProbeFrame = nil
        logSwitch(.probeVerified, route: .usb)
        probe.send(content: pong, completion: .contentProcessed { [weak self, weak probe] _ in
            guard let self, let probe, self.connectionUSBProbe === probe else { return }
            self.closeUSBHandoffProbeOnQueue()
        })
    }
    private func closeUSBHandoffProbeOnQueue() {
        connectionUSBProbe?.stateUpdateHandler = nil
        connectionUSBProbe?.cancel(); connectionUSBProbe = nil
        connectionUSBProbeFrame = nil; connectionUSBProbeDeadline = nil
    }
    private func closeRoutePreparationOnQueue() {
        closeUSBHandoffProbeOnQueue(); connectionUSBProbeAttempted = false
        discardConnectionSwitchUSBCandidateOnQueue()
        connectionListenerCompletion = nil; connectionListenerPreparationAt = nil
        if !usbListenerExplicitlyStarted && activeTransportKind == .wifi { closeUSBListenerOnQueue() }
    }
    private func resetConnectionControlOnQueue(preserveFailure: Bool = false) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        connectionOperation = UUID(); connectionStatusTimer?.cancel(); connectionStatusTimer = nil
        connectionRollbackRetry?.cancel(); connectionRollbackRetry = nil
        closeRoutePreparationOnQueue(); eraseConnectionProofOnQueue()
        connectionHandoffInProgress = false; connectionExpectedRetirement = false
        pairedControlGeneration = nil; trustedProofGeneration = nil; connectionAdvertisement = 0
        connectionSelectedCredential = nil
        usbIdentity = USBSessionIdentityProof(); usbReadinessPongWrittenGeneration = nil
        usbIdentityDeadline?.cancel(); usbIdentityDeadline = nil
        resetConnectionPresentationOnQueue()
        switchDiagnosticStart = nil
        if !preserveFailure { connectionSwitch.begin(generation: connectionGeneration) }
        publishConnectionControlOnQueue()
    }
    private func startConnectionStatusTimerOnQueue() {
        guard connectionStatusTimer == nil else { return }
        let operation = connectionOperation
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.connectionOperation == operation else { return }
            self.connectionStatusTickOnQueue()
        }
        connectionStatusTimer = timer; timer.resume()
    }
    private func expireConnectionControlOnQueue(now: TimeInterval) -> Bool {
        if connectionSwitch.shouldTryRollbackAfterTimeout(now: now),
           connectionSwitch.beginRollback(reason: .deadlineExceeded, now: now) {
            startConnectionRollbackOnQueue()
            return true
        }
        let hadPending = connectionSwitch.pending != nil
        connectionSwitch.tick(now: now)
        guard hadPending, connectionSwitch.pending == nil else { return false }
        if connectionSwitch.offersReconnect {
            failConnectionControlOnQueue(.deadlineExceeded, retainMessage: true)
            return true
        }
        if connectionHandoffInProgress && !connectionSwitch.inputBlocked {
            finishConnectionControlOnQueue()
            publishConnectionControlOnQueue()
        }
        return false
    }
    private func connectionStatusTickOnQueue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let now = connectionControlNow()
        if expireConnectionControlOnQueue(now: now) { return }
        if let start = connectionListenerPreparationAt,
           now < start || now - start >= ConnectionControlProtocol.listenerWait {
            rejectConnectionPreflightOnQueue(.peerTimeout); return
        }
        publishConnectionControlOnQueue()
    }
    private func negotiateConnectionControlOnQueue() {
        guard !remoteInputConnection, wireAuthenticatedGeneration == connectionGeneration,
              pairedControlGeneration == connectionGeneration else { return }
        defer { refreshClipboardOnQueue() }
        if connectionSwitch.generation != connectionGeneration {
            if connectionHandoffInProgress {
                guard connectionAdvertisement & ConnectionControlProtocol.advertisementFlag != 0 else { return }
                guard let original = connectionSelectedCredential, connectionPairingMatches(trustedCredential) else {
                    recoverConnectionControlOnQueue(.identityUnavailable); return
                }
                if let route = connectionSwitch.pending?.rollbackRoute {
                    guard committedConnectionRoute == route,
                          route != .wifi || verifiedHostFingerprint == original.fingerprint &&
                            connectionAdvertisement & ConnectionControlProtocol.protectedHandoffFlag != 0,
                          connectionSwitch.bindRollback(generation: connectionGeneration, route: route,
                              authenticated: true, now: connectionControlNow()) else {
                        failConnectionControlOnQueue(.identityUnavailable); return
                    }
                    // Ordinary paired authentication and OptIn establish the restored route.
                    logSwitch(.rollbackAuthenticated, route: route)
                } else {
                    guard let proof = connectionProof,
                      connectionSwitch.bindReplacement(generation: connectionGeneration, route: committedConnectionRoute,
                          authenticated: true, now: connectionControlNow()) else {
                        recoverConnectionControlOnQueue(.identityUnavailable); return
                    }
                    let optIn = connectionSwitch.advertise(flags: connectionAdvertisement, authenticated: true, generation: connectionGeneration)
                    guard let payload = try? proof.resumeHello().encode() else { recoverConnectionControlOnQueue(.proofFailed); return }
                    sendWireMessage(type: .connectionHello, payload: payload, sequence: 0)
                    if committedConnectionRoute == .wifi, connectionAdvertisement & ConnectionControlProtocol.protectedHandoffFlag != 0,
                       let optIn {
                        sendWireMessage(type: .connectionHello, payload: optIn, sequence: 0)
                    }
                    logSwitch(.resumeSent, route: proof.target)
                    publishConnectionControlOnQueue(); return
                }
            } else { connectionSwitch.begin(generation: connectionGeneration) }
        }
        if let payload = connectionSwitch.advertise(flags: connectionAdvertisement, authenticated: true, generation: connectionGeneration) {
            sendWireMessage(type: .connectionHello, payload: payload, sequence: 0)
            startConnectionStatusTimerOnQueue()
            recordDiagnosticLine("[CONNECTION_CONTROL] event=opt_in")
        }
        publishConnectionControlOnQueue()
    }
    @MainActor public func requestConnectionRoute(_ route: ConnectionRoute, askPC: Bool = false,
                                                 retirePanelInput: (() -> Void)? = nil) {
        guard networkQueue.sync(execute: { !screenSwitchInProgressOnQueue && connectionSwitch.pending == nil }) else { return }
        // Existing UI cancellation releases contacts/keys before the serialized request fence.
        retirePanelInput?()
        captureTargetRetireInput?()
        networkQueue.async { [weak self] in
            guard let self, !self.remoteInputConnection,
                  !self.screenSwitchInProgressOnQueue,
                  self.pairedControlGeneration == self.connectionGeneration,
                  route != .wifi || self.connectionSelectedEndpoint != nil || self.loadWifiReconnectEndpoint() != nil else { return }
            if self.connectionSwitch.needsRefresh {
                if let payload = self.connectionSwitch.refresh() { self.sendWireMessage(type: .connectionHello, payload: payload, sequence: 0) }
                return
            }
            guard let request = self.connectionSwitch.select(route, askPC: askPC, now: self.connectionControlNow()),
                  let payload = try? request.encode() else { self.publishConnectionControlOnQueue(); return }
            self.retirePendingAdaptiveOnQueue()
            self.switchDiagnosticStart = self.connectionControlNow()
            self.wifiRollbackAttempt = 0
            self.connectionSwitch.deferRequestSend()
            self.connectionSelectedCredential = self.trustedCredential
            if route == .wifi && self.connectionSelectedEndpoint == nil {
                self.connectionSelectedEndpoint = self.loadWifiReconnectEndpoint()
            }
            self.resetDirectTouchSessionOnQueue()
            self.publishConnectionControlOnQueue()
            self.startConnectionStatusTimerOnQueue()
            let generation = self.connectionGeneration, operation = self.connectionOperation
            let send = { [weak self] in
                guard let self, self.connectionOperation == operation, self.connectionGeneration == generation,
                      self.connectionSwitch.pending?.request == request else { return }
                guard self.connectionSwitch.markRequestSent(transaction: request.transaction, now: self.connectionControlNow()) else {
                    self.rejectConnectionPreflightOnQueue(.staleRevision); return
                }
                self.sendWireMessage(type: .connectionSelectRequest, payload: payload, sequence: 0)
                self.publishConnectionControlOnQueue()
                self.logSwitch(.request, route: route)
            }
            if route == .usb && self.activeTransportKind == .wifi { self.ensureRouteUsbListenerOnQueue(ready: send) }
            else { send() }
        }
    }
    private func receiveConnectionControlOnQueue(_ message: WireMessage, generation: UInt64) {
        guard !remoteInputConnection, connectionSwitch.enabled, pairedControlGeneration == generation,
              generation == connectionGeneration, message.header.flags == 0 else {
            handleStreamError("Unnegotiated connection control message."); return
        }
        let now = connectionControlNow()
        if expireConnectionControlOnQueue(now: now) { return }
        do {
            if message.header.type == .connectionState {
                let value = try ConnectionControlState.decode(message.payload)
                if value.phase == .snapshot {
                    if connectionSwitch.receive(value, generation: generation, now: now) {
                        recordDiagnosticLine("[CONNECTION_CONTROL] event=state revision=\(value.revision) route=\(value.current.rawValue)")
                        if connectionSwitch.pending?.rollingBack == true { advanceConnectionVideoOnQueue() }
                    }
                } else {
                    guard connectionSwitch.preparing(value, generation: generation, now: now) else { return }
                    guard connectionProof == nil else { return } // never refresh an active proof/deadline
                    let target: ConnectionRoute = value.phase == .prepareUSB ? .usb : .wifi
                    connectionProof = ConnectionProofContext(target: target, transaction: value.transaction, owner: value.owner,
                        revision: value.revision, token: value.token, challenge: value.challenge, secret: value.secret)
                    if target == .usb { answerUSBHandoffProbeOnQueue() }
                    else if connectionSelectedEndpoint == nil { rejectConnectionPreflightOnQueue(.listenerClosed) }
                }
            } else {
                let value = try ConnectionSelectResult.decode(message.payload)
                let wasRollingBack = connectionSwitch.pending?.rollingBack == true
                guard connectionSwitch.receive(value, generation: generation, now: now) else { return }
                recordDiagnosticLine("[CONNECTION_CONTROL] event=result status=\(value.status.rawValue) reason=\(value.reason.rawValue)")
                switch value.status {
                case .accepted:
                    guard let proof = connectionProof, proof.token == value.token,
                          proof.target == value.target else {
                        failConnectionControlOnQueue(.proofFailed); return
                    }
                    closeUSBHandoffProbeOnQueue()
                    connectionHandoffInProgress = true; connectionExpectedRetirement = true
                    decoder.fenceCaptureContinuation()
                    resetAdaptiveMediaOnQueue(preserveHostPreference: true)
                    reconnectWorkItem?.cancel(); reconnectWorkItem = nil
                    cancelUsbCandidateArbitration(reason: "connection_change_accepted")
                    // Fence the drawable now. Retirement owns decoder cleanup.
                    mirrorControl.beginSession(0, preservingUserStop: true)
                    mirrorControl.setConnectionInputBlocked(true)
                    switchPictureTarget = value.target
                    logSwitch(.accepted, route: value.target)
                    publishConnectionControlOnQueue()
                    if value.target == .usb { promoteConnectionSwitchUSBCandidateOnQueue() }
                case .completed:
                    connectionCompleted = value; advanceConnectionVideoOnQueue()
                case .failed:
                    if wasRollingBack && !connectionSwitch.inputBlocked {
                        finishConnectionControlOnQueue()
                    } else if connectionSwitch.pending?.rollingBack == true {
                        if !wasRollingBack { startConnectionRollbackOnQueue() }
                    } else {
                        failConnectionControlOnQueue(value.reason, retainMessage: true)
                    }
                case .alreadyActive, .denied, .permissionRequired, .unavailable, .busy:
                    logSwitch(value.status == .alreadyActive ? .alreadyActive : .declined, route: value.target, reason: value.reason)
                    closeRoutePreparationOnQueue(); eraseConnectionProofOnQueue()
                    connectionSelectedCredential = nil
                }
            }
            publishConnectionControlOnQueue()
        } catch { handleStreamError("Malformed connection control message.") }
    }
    private func ensureRouteUsbListenerOnQueue(ready: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        if let listener = usbListener, case .ready = listener.state { ready(); return }
        guard connectionListenerCompletion == nil, activeTransportKind == .wifi else { return }
        connectionListenerCompletion = ready
        connectionListenerPreparationAt = connectionControlNow()
        if usbListener == nil {
            let port: UInt16
            #if targetEnvironment(simulator)
            port = connectionListenerPortForTesting ?? 42042
            #else
            port = 42042
            #endif
            createOrdinaryUsbListenerOnQueue(port: port)
        }
    }
    private func rejectConnectionPreflightOnQueue(_ reason: ConnectionReason) {
        // This path never touches incumbent connection/parser/decoder/generation or manual USB intent.
        guard let pending = connectionSwitch.pending else {
            closeRoutePreparationOnQueue(); eraseConnectionProofOnQueue(); return
        }
        if pending.accepted { failConnectionControlOnQueue(reason); return }
        // A local preflight error cannot withdraw an already sent 78. Retain
        // proof and input ownership until the host answers or the state expires.
        guard !pending.sent else { return }
        guard pending.originGeneration == connectionGeneration, let incumbent = connection,
              wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration, transportState == .streaming else {
            failConnectionControlOnQueue(.connectionLost); return
        }
        let alive: Bool
        if activeTransportKind == .wifi { alive = isWifiConnectionReadyOnQueue(incumbent, generation: connectionGeneration) }
        else if case .ready = incumbent.state { alive = true }
        else { alive = false }
        guard alive else { failConnectionControlOnQueue(.connectionLost); return }
        recordDiagnosticLine("[CONNECTION_CONTROL] event=preflight_failed reason=\(reason.rawValue)")
        closeRoutePreparationOnQueue(); eraseConnectionProofOnQueue()
        connectionSwitch.preflightFailed(reason: reason)
        connectionSelectedCredential = nil
        publishConnectionControlOnQueue()
    }
    private func handleConnectionRetirementOnQueue(connection old: NWConnection, generation: UInt64,
                                                   source: ConnectionSwitchDiagnostic.Source = .stream) -> Bool {
        guard connectionHandoffInProgress, connectionExpectedRetirement,
              let pending = connectionSwitch.pending, pending.accepted,
              pending.originGeneration == generation, connection === old else { return false }
        connectionExpectedRetirement = false
        logSwitch(.retirement, route: committedConnectionRoute, source: source)
        // Retain the ordinary listener and bounded transaction through expected retirement.
        old.stateUpdateHandler = nil
        teardownCurrentSession()
        pairedControlGeneration = nil; connectionAdvertisement = 0
        resetConnectionPresentationOnQueue()
        if pending.request.target == .usb {
            guard let listener = usbListener, case .ready = listener.state else {
                recoverConnectionControlOnQueue(.listenerClosed); return true
            }
            committedConnectionRoute = .usb; reconnectEnabled = false
            connectionSwitch.waitingForPeer()
            setState(.listening)
        } else {
            guard let endpoint = connectionSelectedEndpoint else { failConnectionControlOnQueue(.listenerClosed); return true }
            // Keep USB listening until Wi-Fi actually presents.
            usbListenerExplicitlyStarted = true
            committedConnectionRoute = .wifi
            connectionSwitch.waitingForPeer()
            setState(.disconnected(reason: ""))
            connectOnQueue(to: endpoint)
        }
        publishConnectionControlOnQueue(); return true
    }
    @discardableResult private func recoverConnectionControlOnQueue(_ reason: ConnectionReason) -> Bool {
        // Waiting and media errors can precede the terminal socket callback.
        if reason == .connectionLost, let old = connection,
           handleConnectionRetirementOnQueue(connection: old, generation: connectionGeneration) { return true }
        logSwitch(.recover, route: committedConnectionRoute, reason: reason)
        if reason == .connectionLost, connectionSwitch.pending?.rollbackRoute == .usb,
           committedConnectionRoute == .usb, usbListener != nil, connection != nil {
            // An interrupted restore dial spends the existing rollback budget.
            // Retire its authority so the next dial must authenticate afresh.
            connectionSwitch.resetRollbackAttempt()
            teardownCurrentSession()
            resetConnectionPresentationOnQueue()
            setState(.listening)
            publishConnectionControlOnQueue()
            return true
        }
        if connectionSwitch.pending?.rollbackRoute == .wifi && reason == .connectionLost {
            connectionSwitch.resetRollbackAttempt()
        } else if !connectionSwitch.beginRollback(reason: reason, now: connectionControlNow()) {
            failConnectionControlOnQueue(reason)
            return false
        }
        startConnectionRollbackOnQueue()
        return true
    }
    private func startConnectionRollbackOnQueue() {
        if let route = connectionSwitch.pending?.rollbackRoute {
            logSwitch(.rollbackStart, route: route, reason: connectionSwitch.issue ?? .connectionLost)
        }
        if connectionSwitch.pending?.rollbackRoute == .usb {
            connectionHandoffInProgress = true; connectionExpectedRetirement = false
            reconnectEnabled = false
            reconnectWorkItem?.cancel(); reconnectWorkItem = nil
            eraseConnectionProofOnQueue()
            if connection != nil { teardownCurrentSession() }
            resetConnectionPresentationOnQueue()
            usbListenerExplicitlyStarted = true
            committedConnectionRoute = .usb
            setState(.listening)
            if usbListener == nil {
                #if targetEnvironment(simulator)
                let port = connectionListenerPortForTesting ?? 42042
                #else
                let port: UInt16 = 42042
                #endif
                createOrdinaryUsbListenerOnQueue(port: port)
            }
            promoteConnectionSwitchUSBCandidateOnQueue()
            publishConnectionControlOnQueue()
        } else { startWifiRollbackAttemptOnQueue() }
    }
    private func startWifiRollbackAttemptOnQueue() {
        guard let endpoint = connectionSelectedEndpoint, connectionSelectedCredential != nil else {
            failConnectionControlOnQueue(.identityUnavailable); return
        }
        connectionHandoffInProgress = true; connectionExpectedRetirement = false
        reconnectEnabled = false
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        eraseConnectionProofOnQueue(); closeRoutePreparationOnQueue()
        usbListenerExplicitlyStarted = false
        closeUSBListenerOnQueue()
        if connection != nil { teardownCurrentSession() }
        resetConnectionPresentationOnQueue()
        setState(.disconnected(reason: "Reconnecting over Wi-Fi."))
        guard !expireConnectionControlOnQueue(now: connectionControlNow()) else { return }
        publishConnectionControlOnQueue()
        connectionRollbackRetry?.cancel()
        let operation = connectionOperation
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.connectionOperation == operation,
                  self.connectionSwitch.pending?.rollingBack == true, self.connection == nil,
                  !self.expireConnectionControlOnQueue(now: self.connectionControlNow()) else { return }
            self.connectionRollbackRetry = nil
            self.wifiRollbackAttempt += 1
            self.logSwitch(.wifiRollback, route: .wifi, reason: self.connectionSwitch.issue ?? .connectionLost)
            self.connectOnQueue(to: endpoint)
        }
        connectionRollbackRetry = retry
        networkQueue.asyncAfter(deadline: .now() + 1, execute: retry)
    }
    private func resetConnectionPresentationOnQueue() {
        resetConnectionVideoOnQueue()
        connectionCompleted = nil
        connectionDisplayRequest = nil; connectionDisplayReady = false; connectionReadyDisplay = nil
        mirrorDecoderLock.lock(); connectionDecoder = nil; mirrorDecoderLock.unlock()
    }
    private func resetConnectionVideoOnQueue() {
        connectionVideo.reset(); connectionVideoStarted = false
        connectionVideoInFlight = nil; connectionVideoPresentationRoot = nil
        connectionVideoHasPresentedRoot = false; connectionVideoNeedsIDR = false
    }
    private func trackConnectionDisplayRequestOnQueue(_ request: UInt32) {
        if connectionSwitch.pending?.rollingBack == true, connectionDisplayRequest != request {
            connectionSwitch.invalidateRollbackDisplay()
            resetConnectionPresentationOnQueue()
        }
        connectionDisplayRequest = request; connectionDisplayReady = false
    }
    private func failConnectionControlOnQueue(_ reason: ConnectionReason, retainMessage: Bool = false) {
        logSwitch(.failed, route: committedConnectionRoute, reason: reason)
        let retireReplacement = connectionHandoffInProgress
        connectionOperation = UUID()
        connectionRollbackRetry?.cancel(); connectionRollbackRetry = nil
        if !retainMessage { connectionSwitch.cancel(reason: reason) }
        closeRoutePreparationOnQueue(); eraseConnectionProofOnQueue()
        connectionSelectedCredential = nil; connectionHandoffInProgress = false; connectionExpectedRetirement = false
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil; reconnectEnabled = false
        resetConnectionPresentationOnQueue()
        connectionStatusTimer?.cancel(); connectionStatusTimer = nil
        if retireReplacement {
            // No automatic bounce or unproven replacement remains after Accepted.
            usbListenerExplicitlyStarted = false
            closeUSBListenerOnQueue()
            if connection != nil { teardownCurrentSession() } else { transportTelemetry.stopLogging() }
            setState(.disconnected(reason: "Connection change failed"))
        }
        switchDiagnosticStart = nil
        publishConnectionControlOnQueue()
    }
    private func finishConnectionControlOnQueue() {
        eraseConnectionProofOnQueue(); connectionSelectedCredential = nil
        connectionHandoffInProgress = false; connectionExpectedRetirement = false
        if committedConnectionRoute == .wifi {
            usbListenerExplicitlyStarted = false
            reconnectEnabled = true
        } else if committedConnectionRoute == .usb {
            usbListenerExplicitlyStarted = true
        }
        closeRoutePreparationOnQueue()
        connectionCompleted = nil
        mirrorControl.setConnectionInputBlocked(false)
        logSwitch(connectionSwitch.phase == .declined ? .restored : .presented,
                  route: committedConnectionRoute, reason: connectionSwitch.issue ?? .none)
        switchDiagnosticStart = nil
        beginAdaptiveProbeOnQueue()
    }
    private func submitVideoOnQueue(
        _ data: Data, sequence: UInt32, isIDR: Bool, lengthPrefixed: Bool, receivedAt: TimeInterval
    ) {
        if isIDR, committedRealtimeMode == RealtimeTransportMode.wifiRTP {
            wifiMediaReceiver.decoderDidSubmit(sequence: sequence, generation: connectionGeneration,
                decoderGeneration: decoder.currentSessionGeneration)
        }
        decoder.processInputData(data, sequence: sequence, isIDR: isIDR,
                                 isLengthPrefixed: lengthPrefixed, receivedAt: receivedAt)
    }

    private func consumeConnectionVideoOnQueue(_ data: Data, sequence: UInt32, isIDR: Bool,
        lengthPrefixed: Bool, receivedAt: TimeInterval, domain: ConnectionFrameDomain) -> Bool {
        if connectionHandoffInProgress {
            guard let pending = connectionSwitch.pending else { return false }
            // Old-route frames cannot acquire replacement ownership.
            guard pending.originGeneration != connectionGeneration else { return true }
        } else {
            guard connectionVideoDraining, let owner = currentConnectionDecoder,
                  owner.network == connectionGeneration, owner.domain == domain else { return false }
        }
        guard !captureAvailability.wireSuspended else { return true }
        let frame = CaptureTargetVideoBuffer.Frame(data: data, sequence: sequence, isIDR: isIDR,
            lengthPrefixed: lengthPrefixed, receivedAt: receivedAt)
        if connectionVideoStarted {
            guard isIDR || !connectionVideoNeedsIDR || !connectionVideo.frames.isEmpty else { return true }
            if connectionVideo.append(frame, continuesDecodeChain: !connectionVideoNeedsIDR) {
                drainConnectionVideoOnQueue()
            } else {
                recoverConnectionVideoChainOnQueue(after: sequence)
            }
        } else { connectionVideo.append(frame); advanceConnectionVideoOnQueue() }
        return true
    }

    private var connectionVideoDraining: Bool {
        connectionVideoInFlight != nil || connectionVideoNeedsIDR || !connectionVideo.frames.isEmpty
    }

    private func drainConnectionVideoOnQueue() {
        // Only the root may enter the renderer before its first presentation.
        // Afterward, each decode completion admits at most one buffered unit.
        guard connectionVideoInFlight == nil, connectionVideoPresentationRoot == nil,
              let owner = currentConnectionDecoder, owner.network == connectionGeneration,
              let frame = connectionVideo.popFirst() else { return }
        guard admitCaptureContinuationOnQueue(sequence: frame.sequence, decoder: owner.decoder, isIDR: frame.isIDR) else {
            recoverConnectionVideoChainOnQueue(after: frame.sequence)
            return
        }
        if frame.isIDR {
            connectionVideoNeedsIDR = false
            if !connectionVideoHasPresentedRoot {
                connectionVideoPresentationRoot = frame.sequence
                connectionSwitch.observeIDR(sequence: frame.sequence, domain: owner.domain,
                    decoder: owner.decoder, generation: owner.network)
            }
        }
        connectionVideoInFlight = frame.sequence
        submitVideoOnQueue(frame.data, sequence: frame.sequence, isIDR: frame.isIDR,
                           lengthPrefixed: frame.lengthPrefixed, receivedAt: frame.receivedAt)
    }

    private func connectionVideoDroppedOnQueue(sequence: UInt32, decoder generation: UInt64) {
        guard connectionVideoStarted, connectionHandoffInProgress || connectionVideoDraining,
              let owner = currentConnectionDecoder, owner.decoder == generation,
              owner.network == connectionGeneration else { return }
        if connectionVideoInFlight == sequence { connectionVideoInFlight = nil }
        if connectionVideoPresentationRoot == sequence {
            connectionVideoPresentationRoot = nil
            connectionSwitch.invalidateDecodeRoot(generation: owner.network)
            publishConnectionControlOnQueue()
        }
        recoverConnectionVideoChainOnQueue(after: sequence)
    }

    private func recoverConnectionVideoChainOnQueue(after sequence: UInt32) {
        if let next = connectionVideo.frames.first, next.isIDR, next.sequence != sequence,
           MirrorControlCodec.sequenceAtOrAfter(next.sequence, sequence) {
            drainConnectionVideoOnQueue()
            return
        }
        connectionVideo.reset()
        guard !connectionVideoNeedsIDR else { return }
        connectionVideoNeedsIDR = true
        guard !captureAvailability.inputBlocked else { return }
        requestVideoRecoveryOnQueue()
    }

    private func requestVideoRecoveryOnQueue() {
        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
            wifiMediaReceiver.requestImmediateRecoveryFeedback(generation: connectionGeneration)
        } else if let recovery = mirrorControl.presentationRecoveryRequest() {
            sendWireMessage(type: .mirrorAction, payload: recovery, sequence: 0)
        } else {
            sendVideoFeedback(reportDecodeLoss: true)
        }
    }
    private var currentConnectionDecoder: (network: UInt64, decoder: UInt64, domain: ConnectionFrameDomain)? {
        mirrorDecoderLock.lock(); defer { mirrorDecoderLock.unlock() }; return connectionDecoder
    }
    private func advanceConnectionVideoOnQueue() {
        guard let pending = connectionSwitch.pending, (pending.rollingBack || connectionCompleted != nil),
              connectionSwitch.generation == connectionGeneration, connectionDisplayReady,
              let request = connectionDisplayRequest, !connectionVideoStarted,
              committedTransportGeneration == connectionGeneration else { return }
        let now = connectionControlNow()
        guard !expireConnectionControlOnQueue(now: now) else { return }
        let domain: ConnectionFrameDomain = committedRealtimeMode == RealtimeTransportMode.wifiRTP ? .rtp : .scst
        if let state = mirrorControl.currentState, state.mode != .virtualDisplay {
            guard let geometry = state.geometry, state.firstFrame != nil,
                  let ready = connectionReadyDisplay,
                  geometry.frameWidth == Int(ready.width), geometry.frameHeight == Int(ready.height) else { return }
        } else if mirrorControl.currentState == nil && connectionAdvertisement & 0x4000 != 0 { return }
        let firstFrame: UInt32
        if pending.rollingBack {
            guard connectionSwitch.hasRollbackSnapshot else { return }
            connectionSwitch.noteRollbackReady(now: now)
            guard let sequence = connectionVideo.frames.first?.sequence else { return }
            firstFrame = sequence
        } else {
            guard let completed = connectionCompleted, completed.frameDomain == domain else { return }
            firstFrame = completed.firstFrame
        }
        guard connectionVideo.hasRoot(firstFrame: firstFrame) else { connectionVideo.reset(); return }
        guard nextMirrorDecoder != UInt64.max else { failConnectionControlOnQueue(.startFailed); return }
        nextMirrorDecoder += 1
        let owner = (network: connectionGeneration, decoder: nextMirrorDecoder, domain: domain)
        mirrorDecoderLock.lock(); connectionDecoder = owner; mirrorDecoderOwner = nil; captureTargetDecoderOwner = nil; mirrorDecoderLock.unlock()
        decoder.invalidate(waitForCompletion: false); decoder.beginSession(generation: owner.decoder)
        if activeVideoCodec == .h264 {
            guard let sets = captureTargetH264ParameterSets, sets.count == 2,
                  decoder.configureH264(sps: sets[0], pps: sets[1]) else { failConnectionControlOnQueue(.startFailed); return }
        }
        connectionSwitch.expectDisplay(request: request, decoder: owner.decoder, generation: connectionGeneration)
        connectionSwitch.displayReady(request: request, generation: connectionGeneration, now: now)
        connectionVideoStarted = true
        drainConnectionVideoOnQueue()
        publishConnectionControlOnQueue()
    }
    #if targetEnvironment(simulator)
    var reconnectRouteForTesting: ((NWEndpoint, String?) -> Void)?

    func installTrustedHostStoresForTesting(credentials: any TrustedHostCredentialBacking,
                                          pins: any TrustedHostCredentialBacking) {
        networkQueue.sync {
            trustedCredentialStore = TrustedHostCredentialStore(backing: credentials)
            trustedHostFingerprintStore = TrustedHostFingerprintStore(backing: pins)
        }
    }

    func setPairedHostForTesting(endpoint: NWEndpoint, credential: TrustedHostCredential) {
        networkQueue.sync {
            connectionSelectedEndpoint = endpoint
            verifiedHostFingerprint = credential.fingerprint
            trustedCredential = credential
            pairedControlGeneration = connectionGeneration
        }
    }

    var connectionUSBCandidateHeldForTesting: (() -> Void)?
    func stageConnectionPresentationForTesting(state: ConnectionSwitchState, request: UInt32, receivedAt: TimeInterval) {
        networkQueue.sync {
            connectionSwitch = state
            connectionHandoffInProgress = true
            switchPictureTarget = state.pending?.request.target
            connectionDisplayRequest = request
            connectionDisplayReady = true
            pairedControlGeneration = connectionGeneration
            connectionVideoReceivedAtForTesting = receivedAt
        }
    }

    func setConnectionIdentityForTesting(verified: Bool) {
        networkQueue.sync { pairedControlGeneration = verified ? connectionGeneration : nil }
    }
    func seedRouteEndpointForTesting(port: NWEndpoint.Port = 27015) {
        networkQueue.sync { connectionSelectedEndpoint = .hostPort(host: .ipv4(.loopback), port: port) }
    }
    func connectionIncumbentIsCurrentForTesting(_ peer: NWConnection) -> Bool {
        networkQueue.sync { connection === peer && activeTransportKind == .wifi && !usbListenerExplicitlyStarted }
    }
    func configureUsbIdentityForTesting() {
        networkQueue.sync {
            committedConnectionRoute = .usb; usbListenerExplicitlyStarted = true
            usbScdpConnection = connection; pairedControlGeneration = nil
            usbIdentity = USBSessionIdentityProof(); usbReadinessPongWrittenGeneration = nil; connectionAdvertisement = 0
            wireAuthenticatedGeneration = nil; committedTransportGeneration = nil
        }
    }
    func configureAuthenticationForTesting(confirmed: Bool, fingerprint: String, endpoint: NWEndpoint,
                                           credentials: any TrustedHostCredentialBacking,
                                           pins: any TrustedHostCredentialBacking) {
        networkQueue.sync {
            trustedCredentialStore = TrustedHostCredentialStore(backing: credentials)
            trustedHostFingerprintStore = TrustedHostFingerprintStore(backing: pins)
            connectionSelectedEndpoint = endpoint
            wireAuthenticatedGeneration = nil; committedTransportGeneration = nil
            verifiedHostFingerprint = fingerprint; verifiedHostIdentityCode = "fixture"
            hostIdentityConfirmed = confirmed; hostIdentityConfirmationRequired = !confirmed
            wifiAuthentication.begin(confirmed: confirmed)
            setState(confirmed ? .connecting : .awaitingHostIdentity)
            if confirmed { sendTrustedClientHello(generation: connectionGeneration) }
        }
    }
    var authenticationDeviceIDForTesting: Data { trustedDeviceID }
    func setConnectionCredentialForTesting(_ credential: TrustedHostCredential) {
        networkQueue.sync { trustedCredential = credential }
    }
    func receiveIdentityWireForTesting(type: WireMessageType, payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
        networkQueue.sync {
            handleWireMessage(WireMessage(header: WireHeader(type: type, flags: flags, payloadLength: payload.count,
                sequence: sequence), payload: payload, firstByteAt: 0), generation: connectionGeneration)
        }
    }
    func reportRouteStreamLossForTesting() {
        networkQueue.sync { handleStreamError("Connection change transport waiting.") }
    }
    func retireConnectionRouteForTesting() {
        networkQueue.sync {
            if let old = connection { _ = handleConnectionRetirementOnQueue(connection: old, generation: connectionGeneration) }
        }
    }
    var usbIdentityBoundForTesting: Bool { networkQueue.sync { pairedControlGeneration == connectionGeneration } }
    var preparedUSBListenerPortForTesting: NWEndpoint.Port? { networkQueue.sync { usbListener?.port } }
    var connectionProofPresentForTesting: Bool { networkQueue.sync { connectionProof != nil } }
    func captureContinuationForTesting(sequence: UInt32, decoder: UInt64, isIDR: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        captureAvailability.noteFrameReceived(sequence: sequence)
        _ = admitCaptureContinuationOnQueue(sequence: sequence, decoder: decoder, isIDR: isIDR)
    }
    func connectionStatusTickForTesting() { networkQueue.sync { connectionStatusTickOnQueue() } }
    #endif
    private func beginOwnedDecoderSession(networkGeneration generation: UInt64) {
        if !connectionHandoffInProgress {
            resetConnectionVideoOnQueue()
            mirrorDecoderLock.lock(); connectionDecoder = nil; mirrorDecoderLock.unlock()
        }
        if captureTargetOwnsPresentation { abandonCaptureTargetPresentationOnQueue() }
        guard let state = mirrorControl.currentState else {
            if wifiLegacyFallbackGeneration == generation {
                // RTP and SCST frame numbers can collide on the same socket.
                // The successor must have a distinct render/decode identity.
                guard nextMirrorDecoder != UInt64.max else { handleStreamError("Route decoder identity exhausted."); return }
                nextMirrorDecoder += 1
                mirrorDecoderLock.lock()
                connectionDecoder = (generation, nextMirrorDecoder, .scst)
                mirrorDecoderOwner = nil
                mirrorDecoderLock.unlock()
                decoder.beginSession(generation: nextMirrorDecoder)
            } else {
                decoder.beginSession(generation: generation)
            }
            return
        }
        guard generation & 0x8000_0000_0000_0000 == 0, nextMirrorDecoder != UInt64.max else {
            handleStreamError("Physical-source decoder identity exhausted."); return
        }
        nextMirrorDecoder += 1
        let owner = MirrorDecoderOwner(connection: generation, decoder: nextMirrorDecoder, epoch: state.epoch, source: state.source)
        mirrorDecoderLock.lock(); mirrorDecoderOwner = owner; mirrorDecoderLock.unlock()
        decoder.beginSession(generation: owner.decoder)
    }
    private func receiveCaptureAvailabilityOnQueue(_ payload: Data, flags: UInt16, generation: UInt64) {
        let wasWireSuspended = captureAvailability.wireSuspended
        switch captureAvailability.receive(payload, flags: flags, generation: generation) {
        case .ignored(let reason):
            recordDiagnosticLine("[CAPTURE_AVAILABILITY] ignored=\(reason)")
            return
        case .suspended(let retireInput):
            manualReconnectPresentation = nil
            captureReadinessClock.setSuspended(captureAvailability.inputBlocked, at: connectionControlNow())
            mirrorControl.setCaptureSuspended(captureAvailability.inputBlocked)
            wifiMediaReceiver.setCaptureSuspended(true)
            controlChannelWriter.discardPending(where: CaptureAvailabilityProtocol.isNewInputPacket)
            if !wasWireSuspended || retireInput {
                captureTargetVideo.reset(); connectionVideo.reset()
                if connectionVideoStarted {
                    connectionVideoInFlight = nil
                    connectionVideoNeedsIDR = true
                    if connectionVideoPresentationRoot != nil {
                        connectionVideoPresentationRoot = nil
                        connectionSwitch.invalidateDecodeRoot(generation: connectionGeneration)
                        publishConnectionControlOnQueue()
                    }
                }
                qualityBaselineIDRs.removeAll(keepingCapacity: true)
                decoder.fenceCaptureContinuation()
            }
            if retireInput {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectionGenerationClock.current == generation else { return }
                    self.captureTargetRetireInput?()
                }
            }
        case .updated: break
        }
        if remoteClipboardLease.nonce != nil { tickRemoteClipboard() }
        publishMirrorStateOnQueue()
    }
    private func admitCaptureContinuationOnQueue(sequence: UInt32, decoder: UInt64, isIDR: Bool) -> Bool {
        if let value = qualitySession?.pending ?? qualitySession?.current {
            let floor = qualitySession?.frameFloor ?? value.firstFrame
            guard let frame = qualitySession?.frameIdentity(sequence), frame >= floor else { return false }
            self.decoder.authorizeAdaptiveFrame(sequence:sequence)
        }
        let admitted = captureAvailability.admitFrame(sequence: sequence, decoder: decoder, isIDR: isIDR, generation: connectionGeneration)
        if admitted, captureAvailability.mayPresent(sequence: sequence, decoder: decoder) {
            self.decoder.authorizeCaptureOutput(sequence: sequence, generation: decoder)
            if isIDR, !qualityBaselinePresented, castingAdaptiveRoute != nil {
                if qualityBaselineDecoder != decoder || qualityBaselineIDRs.count >= 64 {
                    qualityBaselineIDRs.removeAll(keepingCapacity: true)
                }
                qualityBaselineDecoder = decoder
                qualityBaselineIDRs.insert(sequence)
            }
        }
        return admitted
    }
    private func observeCaptureContinuationOnQueue(sequence: UInt32, decoder: UInt64, decoded: Bool, presented: Bool) {
        guard wireAuthenticatedGeneration == connectionGeneration,
              self.decoder.currentSessionGeneration == decoder,
              captureAvailability.observeFrame(sequence: sequence, decoder: decoder, decoded: decoded,
                presented: presented, generation: connectionGeneration) else { return }
        mirrorControl.setCaptureSuspended(false)
        captureReadinessClock.setSuspended(false, at: connectionControlNow())
        wifiMediaReceiver.setCaptureSuspended(false)
        publishMirrorStateOnQueue()
    }
    private func publishMirrorStateOnQueue() {
        if !remoteInputConnection { refreshClipboardOnQueue() }
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
        if sources.catalogue?.allowed == true || catalogue?.allowed == true {
            screenSwitchPermissionRequest = nil
            screenSwitchPermissionTimedOut = false
        }
        let permissionPending = screenSwitchPermissionRequest != nil
        let permissionNotice = screenSwitchPermissionTimedOut ? "No answer from the PC" : nil
        let notice=captureAvailability.notice, inputBlocked=captureAvailability.inputBlocked
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.mirrorControlState = state; self.mirrorInputRevision = revision
            self.mirrorMonitorCatalogue=catalogue;self.mirrorMonitorSwitchPending=pending
            self.mirrorScreenPickerSupported=picker
            self.captureTargetState=sources
            self.screenSwitchPermissionPending = permissionPending
            self.screenSwitchPermissionNotice = permissionNotice
            self.captureAvailabilityNotice=notice;self.captureInputBlocked=inputBlocked
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
                  self.wireAuthenticatedGeneration == generation, self.activeControlConnection != nil,
                  self.connectionSwitch.pending == nil, !self.screenSwitchInProgressOnQueue,
                  self.screenSwitchPermissionRequest == nil else { return }
            let action=self.captureTargets.enabled
                ? self.mirrorControl.typedSwitchPermissionRequest(negotiated: true)
                : self.mirrorControl.switchPermissionRequest()
            guard let action else { return }
            let request = UUID()
            self.screenSwitchPermissionRequest = request
            self.screenSwitchPermissionTimedOut = false
            self.sendWireMessage(type: .mirrorAction, payload: action, sequence: 0)
            self.publishMirrorStateOnQueue()
            let expire = { [weak self] in
                guard let self, generation == self.connectionGeneration,
                      self.screenSwitchPermissionRequest == request else { return }
                self.screenSwitchPermissionRequest = nil
                self.screenSwitchPermissionTimedOut = true
                self.publishMirrorStateOnQueue()
            }
            // Current hosts publish grants in the catalogue. A prompt that closes
            // without a grant has no distinct screen-permission wire receipt.
            #if targetEnvironment(simulator)
            if let schedule = self.captureTargetScheduleForTesting { schedule(30, expire); return }
            #endif
            self.networkQueue.asyncAfter(deadline: .now() + .seconds(30), execute: DispatchWorkItem(block: expire))
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
    @MainActor public func releaseMirrorControl() {
        captureTargetRetireInput?()
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            let action = self.mirrorControl.suspendInput()
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
    @MainActor public func requestMirrorMonitor(_ id:UInt64, catalogue:MirrorMonitorCatalogue) {
        guard networkQueue.sync(execute: { connectionSwitch.pending == nil }) else { return }
        captureTargetRetireInput?()
        let generation=connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self,generation==self.connectionGeneration,
                  self.wireAuthenticatedGeneration==generation,self.committedTransportGeneration==generation,
                  self.connectionSwitch.pending == nil,
                  !self.mirrorSwitchPending,let connection=self.activeControlConnection,
                  self.currentMirrorCatalogue==catalogue,
                  self.mirrorControl.hasPresentedCurrentSource,
                  self.captureReadinessNow()-self.mirrorCatalogueReceivedAt<30,
                  let payload=try? catalogue.switchRequest(id) else {return}
            // A consumed catalogue cannot submit another switch while its transaction is pending.
            self.retirePendingAdaptiveOnQueue()
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
                if let retirement=self.mirrorControl.suspendInput(stopLegacyInput: false) {
                    self.sendWireMessage(type:.mirrorAction,payload:retirement,sequence:0)
                }
                self.sendWireMessage(type:.mirrorSwitchRequest,payload:payload,sequence:0)
            }
            self.publishMirrorStateOnQueue()
            self.scheduleMirrorSwitchDeadlineOnQueue(attempt:attempt,generation:generation,connection:connection)
        }
    }
    private func scheduleMirrorSwitchDeadlineOnQueue(attempt:UUID,generation:UInt64,connection:NWConnection,
                                                    expiresAt: TimeInterval? = nil) {
            let initial = expiresAt == nil
            let expiresAt = expiresAt ?? captureReadinessNow() + 5
            let delay: TimeInterval = initial ? 5 : max(0.05, min(5, expiresAt - captureReadinessNow()))
            let deadlineToken=UUID();mirrorSwitchDeadlineToken=deadlineToken
            let completion: () -> Void = { [weak self, weak connection] in
                guard let self,let connection,self.mirrorSwitchAttempt==attempt,
                      self.mirrorSwitchDeadlineToken==deadlineToken,
                      self.connectionGeneration==generation,self.wireAuthenticatedGeneration==generation,
                      self.committedTransportGeneration==generation,
                      self.activeControlConnection === connection else {return}
                if self.captureAvailability.negotiated &&
                    (self.captureAvailability.inputBlocked || self.captureReadinessNow() < expiresAt) {
                    self.scheduleMirrorSwitchDeadlineOnQueue(attempt: attempt, generation: generation,
                        connection: connection, expiresAt: expiresAt)
                    return
                }
                // No response means unknown, never a selected monitor or renewed input grant.
                self.mirrorSwitchAttempt=nil;self.mirrorSwitchPending=false
                self.mirrorSwitchDeadlineToken=nil
                if self.mirrorControl.supportsTerminalSwitch {self.mirrorControl.cancelTerminalSwitch()}
                self.mirrorTerminalSend=nil
                self.currentMirrorCatalogue=nil;self.mirrorCatalogueSource=nil
                self.publishMirrorStateOnQueue()
            }
            #if targetEnvironment(simulator)
            if let schedule=mirrorSwitchDeadlineForTesting {schedule(delay,completion);return}
            #endif
            networkQueue.asyncAfter(deadline:.now()+delay,execute:completion)
    }
    private func advanceMirrorTerminalSwitchOnQueue() {
        dispatchPrecondition(condition:.onQueue(networkQueue))
        guard let pending=mirrorTerminalSend,pending.written,
              mirrorSwitchAttempt==pending.attempt,mirrorSwitchPending,
              connectionGeneration==pending.generation,wireAuthenticatedGeneration==pending.generation,
              committedTransportGeneration==pending.generation,
              activeControlConnection === pending.connection else {return}
        guard captureReadinessNow()-pending.catalogueReceivedAt<30 else {
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
                  (kind != .iPadPointerV2 || self.connectionAdvertisement & IPadPointerV2Command.capability != 0),
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

    // Device: positive drawable presentation time. Simulator: successful current
    // present command completion (the Simulator SDK omits presentation handlers).
    func recordCapturePresentation(sequence: UInt32, generation: UInt64, sourceSize: CGSize? = nil) {
        let presentedAt = CACurrentMediaTime()
        networkQueue.async { [weak self] in
            guard let self, self.decoder.currentSessionGeneration == generation else { return }
            if let rotation = self.displayRotationDiagnostic, rotation.presentedAt == nil,
               presentedAt >= rotation.startedAt,
               let sourceSize, rotation.matchesPresentation(sourceSize) {
                self.displayRotationDiagnostic?.presentedAt = presentedAt
                self.finishPresentedDisplayRotationIfReady()
            }
            if let ack = self.remoteSecureDesktop.presented(sequence: sequence, decoder: generation) {
                self.decoder.resetCaptureOutputFence()
                self.updateRemoteAudioSuspensionOnQueue()
                self.publishRemoteSecureDesktopOnQueue()
                self.sendRemoteSecureDesktopOnQueue(ack)
                self.beginAdaptiveProbeOnQueue()
            }
            self.observeCaptureContinuationOnQueue(sequence: sequence, decoder: generation, decoded: false, presented: true)
            if !self.qualityBaselinePresented, self.qualityBaselineDecoder == generation,
               self.qualityBaselineIDRs.contains(sequence), !self.captureAvailability.inputBlocked {
                self.qualityBaselinePresented = true
                self.qualityBaselineIDRs.removeAll(keepingCapacity: true)
                self.beginAdaptiveProbeOnQueue()
            }
            self.adaptivePresentedOnQueue(sequence: sequence, decoder: generation)
        }
    }

    private func retirePendingAdaptiveOnQueue() {
        sourceRollback = nil
        guard qualitySession?.pending != nil else { return }
        qualitySession?.retirePendingConfiguration()
        updateAdaptiveFeedbackEpochOnQueue()
        decoder.clearAdaptiveMedia()
        if let applied=qualitySession?.applied { _ = decoder.prepareAdaptiveMedia(applied) }
    }
    private var castingAdaptiveRoute: AdaptiveCastingRoute? {
        guard !remoteInputConnection, let mode = committedRealtimeMode else { return nil }
        switch (activeTransportKind, mode) {
        case (.wifi, RealtimeTransportMode.wifiRTP): return .wifiRTP
        case (.wifi, RealtimeTransportMode.legacyTLS): return .wifiTLS
        case (.usb, RealtimeTransportMode.legacyTLS): return .usbTLS
        default: return nil
        }
    }
    private var adaptiveQualityTransport: Bool {
        if remoteInputConnection {
            return activeTransportKind == .wifi && committedRealtimeMode == RealtimeTransportMode.legacyTLS
        }
        return castingAdaptiveRoute != nil
    }
    private var adaptiveMediaUnsettled: Bool {
        qualitySession?.mediaRecoveryActive == true || qualitySession?.current?.status == 2
    }
    private var remoteQualityNegotiated: Bool {
        qualitySession?.remote == true && qualitySession?.current != nil
    }
    private func restoreRemoteManualIfReady() {
        guard remoteInputConnection, !remoteSecureDesktop.restrictsFeatures, remoteSettingsReady, remoteManualRestorePending,
              remoteManualRequestID == nil,
              qualityProbe.phase != .waiting,
              qualityProbe.phase != .enabled || remoteQualityNegotiated else { return }
        if remoteQualityNegotiated && qualityAutoOptIn && qualitySession?.supportsAuto == true {
            remoteManualRestorePending = false
            remoteManualOverride = false
            return
        }
        let desired = clientSettingsState.desired.bitrateMbps
        let effective = clientSettingsState.effective.bitrateMbps
        let send = remoteManualOverride || desired != effective
        remoteManualRestorePending = false
        remoteManualOverride = false
        if send, case .sent(let requestID) = sendDesiredSettingsIfPossible(reason: "remote_manual_target") {
            remoteManualRequestID = requestID
            let generation = connectionGeneration
            networkQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.connectionGeneration == generation,
                      self.remoteManualRequestID == requestID else { return }
                self.remoteManualRequestID = nil
                // The service may have applied the write. Check readback and
                // leave a new change to the user rather than resending it.
                self.remoteManualRestorePending = false
                self.remoteManualOverride = false
                self.remoteSettingsReady = false
                self.qualityPolicyDirty = false
                self.settingsSyncPolicy.reset()
                self.requestCurrentSettingsIfNeeded(generation: generation)
            }
        }
    }
    private var usesManualQualityFallback: Bool {
        qualityAutoOptIn || qualityProbe.phase == .backoff ||
            (castingAdaptiveRoute?.usesOrderedVideo == true && qualityProbe.phase == .legacy && qualityHostID != nil)
    }
    private var awaitingCastingSettingsIdentity: Bool {
        !remoteInputConnection && activeTransportKind == .wifi &&
            wireAuthenticatedGeneration == connectionGeneration &&
            (wifiAuthentication.stage == .paired || wifiAuthentication.stage == .trusted)
    }
    private func loadCastingStreamSettingsOnQueue(hostID: Data?, remote: Bool = false) {
        let desired = ClientStreamSettingsStore.load(hostID: hostID, remote: remote, defaults: streamSettingsDefaults)
        clientSettingsState.setDesired(desired)
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.desiredBitrateMbps = desired.bitrateMbps
        }
    }
    private func refreshAdaptiveQualityPreferenceOnQueue() {
        guard wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration,
              pairedControlGeneration == connectionGeneration, let hostID = trustedCredential?.hostID else {
            publishAdaptiveStateOnQueue()
            return
        }
        if qualityHostID != hostID {
            qualityHostID = hostID
            loadCastingStreamSettingsOnQueue(hostID: hostID, remote: remoteInputConnection)
            qualityAutoOptIn = ClientStreamSettingsStore.loadAutoQuality(hostID: hostID, remote: remoteInputConnection,
                                                                       defaults: streamSettingsDefaults)
            qualityPolicyDirty = qualityAutoOptIn
            if remoteInputConnection {
                remoteManualRestorePending = true
                restoreRemoteManualIfReady()
                sendAdaptivePolicyOnQueue(auto: qualityAutoOptIn)
                publishAdaptiveStateOnQueue()
                return
            }
            // The first v1 read may have been requested before pairing finished.
            // Reconcile again with the authenticated host's settings, including
            // on Wi-Fi RTP when the host does not support DS2.
            if settingsSyncPolicy.lastSettingsGetGeneration == connectionGeneration {
                settingsReconciliationGate.reset()
                settingsSyncPolicy.reset()
                requestCurrentSettingsIfNeeded(generation: connectionGeneration)
            }
            sendAdaptivePolicyOnQueue(auto: qualityAutoOptIn)
        }
        publishAdaptiveStateOnQueue()
    }
    private func resetAdaptiveMediaOnQueue(preserveHostPreference: Bool = false) {
        qualityProbeDeadline?.cancel(); qualityProbeDeadline = nil
        qualityFeedbackTimer?.cancel(); qualityFeedbackTimer = nil
        qualityProbe = AdaptiveMediaProbe()
        qualityBaselinePresented = false; qualityBaselineDecoder = nil
        qualityBaselineIDRs.removeAll(keepingCapacity: true)
        qualitySession = nil; qualityConnectionID = nil; sourceRollback = nil
        controlChannelWriter.discardPending(where: Self.isAdaptiveControlPacket)
        qualityFeedbackIdentity = nil
        manualReconnectPresentation = nil
        manualReconnectHealthy = false
        if !preserveHostPreference {
            if qualityHostID != nil { loadCastingStreamSettingsOnQueue(hostID: nil) }
            qualityHostID = nil; qualityAutoOptIn = false
            remoteManualRestorePending = false; remoteManualOverride = false; remoteSettingsReady = false
            remoteSettingsGetID = nil; remoteManualRequestID = nil
        }
        qualityWindow = AdaptiveMediaWindow(started:adaptiveNow()); qualityPolicyDirty = false
        qualityRttSeconds = 0; qualityOwnsPolicy = false; decoder.clearAdaptiveMedia()
        publishAdaptiveStateOnQueue()
    }
    private func publishAdaptiveStateOnQueue() {
        let generation = connectionGeneration
        let available = adaptiveQualityTransport && qualityHostID != nil && qualitySession?.supportsAuto == true
        let backingOff = qualityProbe.phase == .backoff
        let reason: String
        if backingOff {
            reason = "Auto temporarily unavailable after a failed quality switch"
        } else if !adaptiveQualityTransport {
            reason = remoteInputConnection ? "Auto quality requires a remote TLS connection." : "Auto quality requires a streaming connection."
        } else if castingAdaptiveRoute != nil, qualityProbe.phase == .idle || qualityProbe.phase == .waiting ||
                    (qualityProbe.phase == .enabled && qualitySession?.current == nil) {
            reason = "Checking Auto quality for this connection."
        } else if qualitySession?.supportsAuto != true {
            reason = remoteInputConnection ? "Auto quality is unavailable on this remote PC." : "Auto quality is unavailable on this connection."
        } else {
            reason = "Pair this PC to save its quality choice."
        }
        let applied = qualitySession?.applied, saved = qualityAutoOptIn, remote = remoteInputConnection
        let manualFallback = usesManualQualityFallback
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGenerationClock.current == generation else { return }
            self.adaptiveQualityAvailable = available; self.autoQualityEnabled = available && saved
            self.adaptiveQualityBackoffActive = backingOff
            self.legacyAutomaticBitrateUnavailable = manualFallback
            self.savedAutoQualityEnabled = saved; self.adaptiveQualityUnavailableReason = reason
            self.effectiveQualitySummary = applied?.displaySummary(remote: remote)
            self.adaptiveDesktopSize = applied?.desktopSize
        }
    }
    private func beginAdaptiveProbeOnQueue() {
        if remoteInputConnection && remoteSecureDesktopEnabled {
            // Learn the desktop lane before creating a DS2 owner on a DS7 reconnect.
            guard remoteFeatures.negotiationSettled, !remoteSecureDesktop.restrictsFeatures,
                  !remoteSecureDesktop.supported || remoteSecureDesktop.sawStandardVideo else { return }
        }
        guard adaptiveQualityTransport, !connectionHandoffInProgress, !captureAvailability.inputBlocked,
              remoteInputConnection || qualityBaselinePresented, wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration, let connection = activeControlConnection else { return }
        var ping=Data(count:16)
        ping.storeLittleEndian(UInt64.random(in:1...UInt64.max),at:0)
        ping.storeLittleEndian(UInt64.random(in:1...UInt64.max),at:8)
        guard qualityProbe.begin(ping, now: adaptiveNow(), castingRoute: castingAdaptiveRoute) else { return }
        qualityConnectionID=ObjectIdentifier(connection)
        let route = castingAdaptiveRoute
        sendWireMessage(type: .ping, payload: ping, sequence: castingAdaptiveRoute?.rawValue ?? 0, flags: AdaptiveMediaProtocol.probeFlag)
        let generation=connectionGeneration, identity=qualityConnectionID
        let work=DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation, self.qualityConnectionID == identity,
                  self.castingAdaptiveRoute == route,
                  self.qualityProbe.matchesRequest(ping, sequence: route?.rawValue ?? 0) else { return }
            self.qualityProbe.tick(now:self.adaptiveNow())
            if self.qualityProbe.phase == .legacy {
                self.adaptiveProbeDeclinedOnQueue()
            }
        }
        qualityProbeDeadline=work; networkQueue.asyncAfter(deadline:.now()+2,execute:work)
    }
    private func startAdaptiveFeedbackTimerOnQueue() {
        #if targetEnvironment(simulator)
        if adaptiveMediaClockForTesting != nil { return }
        #endif
        guard qualityFeedbackTimer == nil else { return }
        let generation = connectionGeneration, owner = qualitySession?.owner
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        let interval = AdaptiveMediaWindow.feedbackPollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.connectionGeneration == generation, self.qualitySession?.owner == owner else { return }
            self.sendAdaptiveFeedbackOnQueue()
        }
        qualityFeedbackTimer = timer
        timer.resume()
    }
    private func adaptiveProbeDeclinedOnQueue() {
        qualityProbeDeadline?.cancel(); qualityProbeDeadline = nil
        if qualityProbe.phase == .legacy { reconnectAttempt = 0 }
        if remoteInputConnection {
            restoreRemoteManualIfReady()
        } else if usesManualQualityFallback, !qualityAutoOptIn, clientSettingsState.desired.adaptiveBitrateEnabled {
            // A pre-probe SettingsState may already have reconciled legacy AutoBitrate.
            settingsReconciliationGate.reset()
            settingsSyncPolicy.reset()
            requestCurrentSettingsIfNeeded(generation: connectionGeneration)
        }
        publishAdaptiveStateOnQueue()
    }
    private func receiveAdaptivePongOnQueue(_ payload: Data, flags: UInt16, sequence: UInt32) {
        guard !remoteSecureDesktop.restrictsFeatures else { return }
        guard adaptiveQualityTransport, let connection=activeControlConnection,
              qualityConnectionID == ObjectIdentifier(connection),
              !connectionHandoffInProgress, wireAuthenticatedGeneration == connectionGeneration,
              committedTransportGeneration == connectionGeneration,
              qualityProbe.phase == .waiting else { return }
        let now = adaptiveNow(), started = qualityProbe.began
        _ = qualityProbe.accept(payload, flags: flags, sequence: sequence, now: now)
        let phase = qualityProbe.phase
        guard phase != .waiting else { return }
        qualityProbeDeadline?.cancel(); qualityProbeDeadline = nil
        switch phase {
        case .legacy, .backoff:
            adaptiveProbeDeclinedOnQueue()
        case .enabled:
            if now > started {
                qualityRttSeconds = now - started
                qualityWindow.recordRtt(us: AdaptiveMediaWindow.us(now - started), now: now)
            }
            let owner = UInt64.random(in: 1...UInt64.max), nonce = UInt64.random(in: 1...UInt64.max)
            qualitySession = AdaptiveMediaSession(owner: owner, nonce: nonce, remote: remoteInputConnection,
                                                  castingRoute: castingAdaptiveRoute ?? .wifiRTP)
            qualityPolicyDirty = qualityAutoOptIn
            sendAdaptiveOnQueue(AdaptiveMediaProtocol.hello(owner: owner, nonce: nonce))
            if qualitySession?.usesOrderedVideo == true {
                let generation = connectionGeneration
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                          self.qualitySession?.owner == owner, self.qualitySession?.current == nil else { return }
                    self.qualitySession = nil
                    self.qualityProbe.retire()
                    self.qualityFeedbackTimer?.cancel(); self.qualityFeedbackTimer = nil
                    self.adaptiveProbeDeclinedOnQueue()
                }
                qualityProbeDeadline = work
                networkQueue.asyncAfter(deadline: .now() + 8, execute: work)
            }
        case .waiting, .idle: break
        }
    }
    private func sendAdaptiveOnQueue(_ packet: AdaptiveMediaPacket) {
        guard adaptiveQualityTransport, !connectionHandoffInProgress, qualityProbe.phase == .enabled,
              wireAuthenticatedGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              let connection=activeControlConnection, qualityConnectionID == ObjectIdentifier(connection),
              let type=WireMessageType(rawValue:packet.type) else { return }
        sendWireMessage(type:type,payload:packet.encoded,sequence:0)
    }
    private func receiveAdaptiveOnQueue(type: WireMessageType, payload: Data, flags: UInt16, sequence: UInt32) {
        guard adaptiveQualityTransport, !connectionHandoffInProgress, qualityProbe.phase == .enabled,
              wireAuthenticatedGeneration == connectionGeneration, committedTransportGeneration == connectionGeneration,
              let connection=activeControlConnection, qualityConnectionID == ObjectIdentifier(connection),
              let packet=AdaptiveMediaProtocol.decode(type:type.rawValue,data:payload,flags:flags) else { return }
        if type == .qualityCapabilities {
            guard qualitySession?.acceptCapabilities(packet) == true else { return }
            startAdaptiveFeedbackTimerOnQueue()
            publishAdaptiveStateOnQueue(); return
        }
        guard let value=packet.effective else { return }
        if type == .qualityConfiguration {
            // Source/route selection owns decoder lifetime. A pure media change
            // must not reset those transactions or retire their input tickets.
            let selection=captureTargets.pending
            guard !connectionHandoffInProgress, !mirrorSwitchPending, selection?.accepted != true,
                  qualitySession?.configure(value, restoringSource: selection != nil, controlSequence: sequence) == true else { return }
            resetRemoteTimedVideoOnQueue()
            updateAdaptiveFeedbackEpochOnQueue()
            // Fence queued output synchronously and retain the held drawable.
            // Ordered transports install the new geometry at the reserved IDR.
            if qualitySession?.usesOrderedVideo == true {
                // Reject queued old output now, but switch the texture/decoder
                // contract only when the reserved SCST IDR actually arrives.
                decoder.fenceCaptureContinuation()
            } else {
                guard decoder.prepareAdaptiveMedia(value) else {
                    failAdaptiveConfigurationOnQueue(reason: 10); return
                }
            }
            if let selection {
                sourceRollback=(selection.request,value.identity,UInt32(truncatingIfNeeded:value.firstFrame),decoder.currentSessionGeneration)
                captureTargetLastVideoSequence=nil
            }
            sendAdaptiveOnQueue(AdaptiveMediaProtocol.ack(value,status:0))
            let identity=value.identity
            scheduleCaptureTargetCallback(max(3,6*qualityRttSeconds)) { [weak self] in
                guard let self, self.qualitySession?.pending?.identity == identity,
                      self.qualitySession?.firstPresented != true else { return }
                self.failAdaptiveConfigurationOnQueue(reason: 12)
            }
        } else {
            let previous=qualitySession?.current
            let pending = qualitySession?.pending
            guard qualitySession?.receiveState(value) == true else { return }
            // receiveState admits a matching pending epoch only after Presented.
            // Reason 7 is rollback (ApplyRejected), which cannot clear retries.
            if value.status == 0, let pending, pending.reason != 7, pending.identity == value.identity {
                reconnectAttempt = 0
            }
            updateAdaptiveFeedbackEpochOnQueue()
            if value.status == 0, previous?.identity != value.identity, previous == nil || previous?.identity.source != value.identity.source {
                // A baseline after reconnect/new source may already be scaled.
                // It has no ACK barrier; install its source/crop mapping too.
                if previous == nil { decoder.updateAdaptiveMedia(value) }
                else { _ = decoder.prepareAdaptiveMedia(value) }
                qualityPolicyDirty = qualityAutoOptIn
            } else if value.status == 0 || remoteInputConnection && pending?.identity == value.identity {
                decoder.updateAdaptiveMedia(value)
            }
            if qualitySession?.usesOrderedVideo == true {
                qualityProbeDeadline?.cancel(); qualityProbeDeadline = nil
                if remoteInputConnection { restoreRemoteManualIfReady() }
            }
            publishAdaptiveStateOnQueue()
            if value.status == 0 || value.status == 1 { sendAdaptivePolicyOnQueue(auto:qualityAutoOptIn) }
        }
    }
    private func updateAdaptiveFeedbackEpochOnQueue() {
        let identity = (qualitySession?.pending ?? qualitySession?.current)?.identity
        guard qualityFeedbackIdentity != identity else { return }
        qualityFeedbackIdentity = identity
        manualReconnectPresentation = nil
        qualityWindow.restart(started: adaptiveNow())
    }
    private func failAdaptiveConfigurationOnQueue(reason: UInt8) {
        guard let ack = qualitySession?.failed(reason: reason) else { return }
        updateAdaptiveFeedbackEpochOnQueue()
        sendAdaptiveOnQueue(ack)
    }
    public func setAutoQualityEnabled(_ enabled: Bool) {
        let generation = connectionGenerationClock.current
        networkQueue.async { [weak self] in
            guard let self, self.connectionGeneration == generation, self.adaptiveQualityTransport,
                  self.qualitySession?.supportsAuto == true, let hostID = self.qualityHostID else { return }
            guard enabled != self.qualityAutoOptIn else { return }
            ClientStreamSettingsStore.saveAutoQuality(enabled, hostID: hostID, remote: self.remoteInputConnection,
                                                      defaults: self.streamSettingsDefaults)
            self.qualityAutoOptIn = enabled
            if self.remoteInputConnection {
                self.qualitySession?.permitRemoteAutoRequestAgain()
                self.remoteManualRestorePending = !enabled
                self.remoteManualOverride = !enabled
                self.restoreRemoteManualIfReady()
            }
            self.qualityPolicyDirty=true; self.publishAdaptiveStateOnQueue()
            self.sendAdaptivePolicyOnQueue(auto:enabled)
        }
    }
    private func sendAdaptivePolicyOnQueue(auto: Bool) {
        guard adaptiveQualityTransport, qualityPolicyDirty, !captureAvailability.inputBlocked,
              !remoteInputConnection || (auto && remoteSettingsReady && remoteManualRequestID == nil),
              let packet=qualitySession?.makePolicy(auto:auto,
                manualBps:UInt32(clientSettingsState.desired.bitrateMbps*1_000_000),game:desiredPipelineMode == .game) else { return }
        qualityPolicyDirty=false; qualityOwnsPolicy=true; sendAdaptiveOnQueue(packet)
    }
    private func adaptiveFrameOnQueue(_ sequence: UInt32, requireReceived: Bool = true) -> UInt64? {
        guard qualitySession?.pending != nil || qualitySession?.current != nil,
              let floor=qualitySession?.frameFloor,
              let frame=qualitySession?.frameIdentity(sequence), frame >= floor else { return nil }
        if requireReceived, castingAdaptiveRoute?.usesOrderedVideo == true, !qualityWindow.hasReceived(frame: frame) { return nil }
        return frame
    }
    private func admitOrderedAdaptiveVideoOnQueue(_ data: Data, sequence: UInt32, isIDR: Bool,
                                                  lengthPrefixed: Bool) -> Bool {
        let hasParameterSets: Bool
        if qualitySession?.orderedVideoNeedsParameterSets == true, isIDR,
           let ranges = lengthPrefixed ? LengthPrefixedNALScanner.ranges(in: data) :
               (remoteInputConnection ? nil : AnnexBNALScanner.ranges(in: data)) {
            var kinds = Set<UInt8>()
            for range in ranges where range.count >= 2 { kinds.insert((data[range.lowerBound] >> 1) & 0x3f) }
            hasParameterSets = kinds.contains(32) && kinds.contains(33) && kinds.contains(34) &&
                (kinds.contains(19) || kinds.contains(20))
        } else {
            hasParameterSets = false
        }
        let admission = remoteInputConnection
            ? qualitySession?.admitRemote(sequence: sequence, isIDR: isIDR, hasParameterSets: hasParameterSets)
            : qualitySession?.admitCastingTLS(sequence: sequence, isIDR: isIDR, hasParameterSets: hasParameterSets)
        switch admission {
        case .regular?: return true
        case .cutover(let value)?:
            // The ordered decoder queue cleans up VT before decoding this IDR.
            // Keep the presentation owner and held drawable across media epochs.
            decoder.invalidate(waitForCompletion: false)
            guard decoder.prepareAdaptiveMedia(value) else {
                failAdaptiveConfigurationOnQueue(reason: 10)
                return false
            }
            return true
        case .missingFirstFrame?:
            failAdaptiveConfigurationOnQueue(reason: 7)
            return false
        case .discard?, nil:
            qualityWindow.drop(3)
            return false
        }
    }
    private func adaptiveIncomingOnQueue(_ data: Data, sequence: UInt32, isIDR: Bool,
                                        receivedAt: TimeInterval, receiveUs: UInt32?) -> Bool {
        guard qualitySession?.pending != nil || qualitySession?.current != nil else { return true }
        guard !captureAvailability.wireSuspended, qualitySession?.admit(sequence:sequence,isIDR:isIDR) == true else {
            qualityWindow.drop(captureAvailability.wireSuspended ? 3 : 2); return false
        }
        guard let frame=adaptiveFrameOnQueue(sequence, requireReceived: false) else { return false }
        qualityWindow.received(frame:frame,bytes:data.count,now:receivedAt,receiveUs:receiveUs)
        return true
    }
    private func adaptiveDecodeCompletedOnQueue(sequence: UInt32, decoder: UInt64, succeeded: Bool) {
        guard !succeeded, self.decoder.currentSessionGeneration == decoder,
              let frame=adaptiveFrameOnQueue(sequence) else { return }
        qualityWindow.drop(1)
        if frame == qualitySession?.pending?.firstFrame { failAdaptiveConfigurationOnQueue(reason: 4) }
    }
    private func adaptivePresentedOnQueue(sequence: UInt32, decoder: UInt64) {
        guard self.decoder.currentSessionGeneration == decoder, let frame=adaptiveFrameOnQueue(sequence) else { return }
        let now = adaptiveNow()
        qualityWindow.presented(frame:frame,now:now)
        recordManualReconnectPresentation(frame: frame, decoder: decoder, now: now)
        if let ack=qualitySession?.presented(sequence:sequence) { sendAdaptiveOnQueue(ack) }
        // A toggle made during suspension is applied only after fresh pixels.
        sendAdaptivePolicyOnQueue(auto:qualityAutoOptIn)
    }
    private func recordManualReconnectPresentation(frame: UInt64, decoder: UInt64, now: TimeInterval) {
        guard !manualReconnectHealthy, reconnectAttempt > 0 else { return }
        guard transportState == .streaming, isForegroundActive, !captureAvailability.inputBlocked,
              !adaptiveMediaUnsettled, let applied = qualitySession?.applied, applied.mode == 0 else {
            manualReconnectPresentation = nil
            return
        }
        var started = now
        if let last = manualReconnectPresentation, last.identity == applied.identity, last.decoder == decoder {
            guard frame > last.frame else { return }
            if now - last.at <= 1 { started = last.started }
        }
        manualReconnectPresentation = (applied.identity, decoder, frame, started, now)
        if now - started >= 5 { manualReconnectHealthy = true }
    }
    private func sendAdaptiveFeedbackOnQueue() {
        guard adaptiveQualityTransport, let identity = qualityFeedbackIdentity else { return }
        if remoteInputConnection {
            guard qualitySession?.pending == nil, qualitySession?.applied?.mode == 2,
                  remoteManualRequestID == nil else { return }
        }
        var activity: UInt8 = isForegroundActive ? 1 : 0
        if isForegroundActive && decoder.adaptivePresentationActive && !captureAvailability.inputBlocked { activity |= 2 }
        if captureAvailability.inputBlocked || captureTargetRecoveryToken != nil ||
            decoder.adaptiveDecodeRecoveryActive ||
            qualitySession?.mediaRecoveryActive == true ||
            (castingAdaptiveRoute == .wifiRTP && wifiMediaReceiver.isRecovering(generation: connectionGeneration)) {
            activity |= 4
        }
        if let feedback = qualityWindow.sample(identity: identity, now: adaptiveNow(), activity: activity) {
            sendAdaptiveOnQueue(feedback)
        }
    }
    #if targetEnvironment(simulator)
    func setAdaptiveHostForTesting(_ hostID: Data, usb: Bool = false) {
        networkQueue.sync {
            committedConnectionRoute = usb ? .usb : .wifi
            usbScdpConnection = usb ? connection : nil
            trustedCredential = TrustedHostCredential(fingerprint: "fixture", hostID: hostID,
                deviceID: Data(), secret: Data(), sessionID: Data())
            pairedControlGeneration = connectionGeneration
            refreshAdaptiveQualityPreferenceOnQueue()
        }
    }
    func beginAdaptiveMediaForTesting(baselinePresented: Bool = false) {
        networkQueue.sync {
            if baselinePresented { qualityBaselinePresented = true }
            beginAdaptiveProbeOnQueue()
        }
    }
    func receiveRemoteQualityFrameForTesting(_ bytes: Data, generation: UInt64, connection: NWConnection) {
        networkQueue.sync {
            guard remoteInputConnection, generation == connectionGeneration,
                  activeControlConnection === connection, wireAuthenticatedGeneration == generation else { return }
            let parser = WireStreamParser(generation: generation)
            parser.consume(bytes, generation: generation) { handleWireParserEvent($0, generation: generation) }
        }
    }
    func admitAdaptiveFrameForTesting(_ sequence: UInt32, isIDR: Bool, bytes: Int = 1, receiveUs: UInt32 = 100) -> Bool {
        networkQueue.sync {
            adaptiveIncomingOnQueue(Data(count: bytes), sequence: sequence, isIDR: isIDR,
                                    receivedAt: adaptiveNow(), receiveUs: receiveUs)
        }
    }
    func sendAdaptiveFeedbackForTesting() { networkQueue.sync { sendAdaptiveFeedbackOnQueue() } }
    #endif

    /// Records completion of the Metal command buffer as a distinct presentation stage.
    public func recordRenderCompletion(sequence: UInt32, generation: UInt64) {
        mirrorDecoderLock.lock()
        let routeDecoder = connectionDecoder
        let typed = captureTargetDecoderOwner
        let captured = mirrorDecoderOwner
        mirrorDecoderLock.unlock()
        if let routeDecoder, routeDecoder.decoder == generation {
            networkQueue.async { [weak self] in
                guard let self, self.connectionGeneration == routeDecoder.network,
                      self.currentConnectionDecoder?.decoder == generation else { return }
                self.transportTelemetry.recordRenderCompletion(sequence: sequence, generation: routeDecoder.network)
                let now = self.connectionControlNow()
                if self.expireConnectionControlOnQueue(now: now) { return }
                let presentedRoot = self.connectionVideoPresentationRoot == sequence
                if !self.connectionHandoffInProgress || self.connectionVideoHasPresentedRoot || presentedRoot {
                    self.connectionSwitch.rendered(sequence: sequence, domain: routeDecoder.domain,
                        decoder: generation, generation: routeDecoder.network, now: now)
                }
                if presentedRoot {
                    self.connectionVideoPresentationRoot = nil
                    self.connectionVideoHasPresentedRoot = true
                    self.switchPictureTarget = nil
                }
                if self.connectionHandoffInProgress && !self.connectionSwitch.inputBlocked {
                    self.finishConnectionControlOnQueue()
                }
                if presentedRoot { self.drainConnectionVideoOnQueue() }
                if let ack = self.mirrorControl.observeRendered(session: routeDecoder.network, sequence: sequence) {
                    self.sendWireMessage(type: .mirrorAction, payload: ack, sequence: 0)
                }
                self.publishConnectionControlOnQueue()
                self.publishMirrorStateOnQueue()
            }
            return
        }
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
                self.flushDeferredSourceDisplayOnQueue()
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
        } else if routeDecoder == nil, typed == nil, captured == nil, generation == connectionGenerationClock.current {
            transportTelemetry.recordRenderCompletion(sequence: sequence, generation: generation)
        }
    }

    public func recordDrawableCommitted(
        sequence: UInt32,
        generation: UInt64
    ) {
        guard decoder.currentSessionGeneration == generation else { return }
        transportTelemetry.recordDrawableCommitted(
            sequence: sequence,
            generation: telemetryGeneration(forDecoder: generation))
    }

    public func recordRenderDrop(sequence: UInt32, generation: UInt64) {
        networkQueue.async { [weak self] in
            guard let self, self.decoder.currentSessionGeneration == generation else { return }
            if self.connectionVideoPresentationRoot == sequence {
                self.connectionVideoDroppedOnQueue(sequence: sequence, decoder: generation)
            }
            guard self.adaptiveFrameOnQueue(sequence) != nil else { return }
            self.qualityWindow.drop(2)
            if self.qualitySession?.pending?.firstFrame == self.adaptiveFrameOnQueue(sequence) {
                self.failAdaptiveConfigurationOnQueue(reason: 4)
            }
        }
        transportTelemetry.recordRenderDrop(
            sequence: sequence,
            generation: telemetryGeneration(forDecoder: generation))
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
    var monitorSelectionWhilePaused = false
    // Closing local UI restores admission. Its controls may have armed a new drag.
    // Changes to transport or host authority still retire the originating scope.
    func requiresRetirement(comparedTo old: Self) -> Bool {
        !active || remote != old.remote || connected != old.connected || generation != old.generation ||
            features != old.features || context != old.context || ready != old.ready || revision != old.revision
    }

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
        boundNetwork?.updateRemoteMonitorControl(configuration: configuration,
            enabled: monitorSelectionEnabled, available: monitorControlAvailable)
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
    private var contextReady: Bool {
        guard let c = configuration, c.remote, c.connected, c.ready,
              let context = c.context, context.state == 1, context.token != 0,
              [1, 2, 3].contains(context.desktop),
              context.width > 0, context.height > 0 else { return false }
        return !waitingForContext
    }
    private var enabled: Bool { configuration?.active == true && contextReady }
    var keyboardEnabled: Bool { usesScanKeyboard && enabled }
    var pointerEnabled: Bool { usesEnhancedPointer && enabled }
    var monitorSelectionEnabled: Bool { monitorControlAvailable && contextReady }
    /// Permission survives a missing capture source; normal input still uses the existing ready/context gate.
    var monitorControlAvailable: Bool {
        guard let c = configuration else { return false }
        return c.remote && c.connected && (c.active || c.monitorSelectionWhilePaused) && c.features & 7 == 7
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
        // A local pause can arrive together with a UI revision. Retire while
        // the old token/context still owns the keys and every pointer device.
        if !changedConnection && old?.context == value.context && old?.features == value.features
            && value.connected && (!value.active || !value.ready) {
            suspend(reason: 0, preserveMonitorContext: value.monitorSelectionWhilePaused && value.ready)
        }
        if retired {
            suppressedUsages.formUnion(hardwareUsages)
            hardwareUsages.removeAll()
            keyboard = RemoteKeyboardState(token: 0)
            mouse = RemoteMouseInput(context: nil, videoRect: videoRect,
                generation: value.generation, mode: mouseMode, inputReady: false)
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

    func suspend(reason: UInt8, preserveMonitorContext: Bool = false) {
        if reason == 1 || reason == 2 {
            boundNetwork?.endRemoteFileControl(generation: generation)
        }
        guard enabled || monitorSelectionEnabled, usesScanKeyboard || usesEnhancedPointer else { return }
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
        guard !preserveMonitorContext else { return }
        blockedToken = t
        waitingForContext = true
        _ = mouse.configure(context: configuration?.context, videoRect: videoRect,
            generation: g, inputReady: false)
        sendReset(RemoteInputResetCommand(reason: reason, token: t), g)
    }
}
