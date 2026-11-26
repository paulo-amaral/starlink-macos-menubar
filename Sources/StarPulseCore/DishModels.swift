import Foundation

public struct DishStatus: Sendable, Equatable {
    public var deviceId = ""
    public var hardwareVersion = ""
    public var softwareVersion = ""
    public var countryCode = ""
    public var uptimeSeconds: UInt64 = 0
    public var latencyMs: Float = 0
    public var dropRate: Float = 0
    public var downlinkBps: Float = 0
    public var uplinkBps: Float = 0
    public var fractionObstructed: Float = 0
    public var currentlyObstructed = false
    /// How long the dish has been mapping the sky (obstruction stats valid_s).
    public var obstructionObservedSeconds: Float = 0
    public var boresightAzimuthDeg: Float = 0
    public var boresightElevationDeg: Float = 0
    public var ethSpeedMbps: Int32 = 0
    public var desiredAzimuthDeg: Float = 0
    /// 0 when the dish sent no target (proto3 drops zero values).
    public var desiredElevationDeg: Float = 0
    public var tiltAngleDeg: Float = 0
    /// AttitudeEstimationState: 1 unconverged and 2 converged make the alignment reading valid.
    public var attitudeState: Int = 0
    /// UserMobilityClass: 0 stationary, 1 nomadic, 2 mobile.
    public var mobilityClass: Int = 0
    /// Names of the DishAlerts booleans that are currently true.
    public var activeAlerts: [String] = []
    /// SoftwareUpdateState (1021): 1 idle, 2 to 5 downloading or installing, 6 reboot required.
    public var softwareUpdateState = 0
    /// swupdate_reboot_ready (1030).
    public var updateRebootReady = false
    /// When the dish plans to restart for the update (1026 field 4), if it said.
    public var updateRebootAt: Date?
    /// UtDisablementCode (1024): 1 is OKAY; higher codes restrict service.
    public var disablementCode = 0
    /// RateLimitReason (1044 download, 1045 upload): 1 is NO_LIMIT.
    public var downloadLimitReason = 0
    public var uploadLimitReason = 0
    public init() {}

    public var isUpdateWaitingForReboot: Bool { updateRebootReady || softwareUpdateState == 6 }

    /// The active alerts in plain words; a name without a known wording is shown as is.
    public var alertTitles: [String] { activeAlerts.map(Self.alertTitle) }

    /// Active alerts that need attention.
    public var problemAlertTitles: [String] {
        activeAlerts.filter { !Self.statusFlags.contains($0) }.map(Self.alertTitle)
    }

    /// Active flags that describe what the dish is doing rather than a fault.
    public var statusFlagTitles: [String] {
        activeAlerts.filter { Self.statusFlags.contains($0) }.map(Self.alertTitle)
    }

    /// StarPulse's choice. lowerSignalThanPredicted is left out of the dish's own get_diagnostics
    /// alerts and stays set on a live dish with signal quality 1.0 and no ping loss (2026.11.12);
    /// the others report normal operation. A pending update has its own notice.
    static let statusFlags: Set<String> = [
        "isHeating", "isPowerSaveIdle", "installPending", "obstructionMapReset", "roaming", "lowerSignalThanPredicted",
    ]

    public static func alertTitle(_ name: String) -> String { alertWording[name] ?? name }

    static let alertWording: [String: String] = [
        "motorsStuck": "Dish motors are stuck",
        "thermalShutdown": "Dish shut down to cool off",
        "thermalThrottle": "Dish is too hot; speed reduced",
        "unexpectedLocation": "Dish is outside its expected location",
        "mastNotNearVertical": "Mast is not vertical",
        "slowEthernetSpeeds": "Slow Ethernet link",
        "roaming": "Roaming",
        "installPending": "Software update waiting to install",
        "isHeating": "Heating to melt snow",
        "powerSupplyThermalThrottle": "Power supply is too hot; speed reduced",
        "isPowerSaveIdle": "Power save mode is on",
        "lowMotorCurrent": "Low motor current",
        "lowerSignalThanPredicted": "Signal below the dish's forecast, often weather; no action needed",
        "slowEthernetSpeeds100": "Ethernet link limited to 100 Mbps",
        "obstructionMapReset": "Obstruction map was reset",
        "dishWaterDetected": "Water detected in the dish",
        "routerWaterDetected": "Water detected in the router",
        "noEthernetLink": "No Ethernet link",
        "dbfTelemStale": "Dish telemetry is out of date",
        "upsuRouterPortSlow": "Power supply's router port is slow",
    ]
}

public struct TelemetrySample: Sendable, Equatable {
    public var timestamp: Date
    /// nil when the dish reported no ping (an outage second), not zero latency.
    public var latencyMs: Float?
    public var dropRate: Float
    public var downlinkBps: Float
    public var uplinkBps: Float
    public var powerW: Float
    /// The dish's own sample counter since boot: a fixed identity while the ring buffer advances.
    public var sequence: UInt64 = 0
}

public struct DishEvent: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable { case unknown = 0, warning, caution, advisory }
    public var id: String { "\(startTimestampNs)-\(reason)" }
    public var severity: Severity
    public var reason: Int
    public var startTimestampNs: Int64
    public var durationNs: UInt64
    public var start: Date { Date(timeIntervalSince1970: Double(startTimestampNs) / 1e9) }
    public var duration: TimeInterval { Double(durationNs) / 1e9 }
    public var title: String { DishEvent.titles[reason] ?? "Event \(reason)" }

    // EventReason values from the dish's reflection dump (schema/dish.protoset).
    static let titles: [Int: String] = [
        1: "Unknown outage", 2: "Booting", 3: "Stowed", 4: "Thermal shutdown",
        5: "No schedule", 6: "No satellites", 7: "Obstructed", 8: "No downlink",
        9: "No pings", 10: "Sleeping", 11: "Moving while not allowed", 12: "High downlink packet loss",
        19: "Sky search", 22: "Rain, low SNR", 23: "Ethernet: no link", 24: "Ethernet: slow link",
        25: "Ethernet: 100 Mbps link", 50: "RF inhibited", 52: "User reported issue",
    ]
}

public struct DishHistory: Sendable, Equatable {
    public var samples: [TelemetrySample]
    public var events: [DishEvent]
    public var newestCounter: UInt64
}
