import Observation
import StarPulseCore
import SwiftUI

@MainActor @Observable
final class SatelliteStore {
    enum State: Equatable { case needsAccount, loading, active, failed(String) }

    var state = State.needsAccount
    var inView: [SatelliteSky] = []
    var serving: SatelliteSky?
    var constellationSize = 0
    var elementsDownloadedAt: Date?
    private var tles: [TLE] = []
    private var loadedAt = Date.distantPast
    private var tracker: StarlinkTracker?
    private var chooser = ServingChooser()
    private var task: Task<Void, Never>?

    /// Element sets are refetched after six hours; they age by roughly a kilometre a day.
    private static let maxAge: TimeInterval = 6 * 3600

    /// Runs only while a sky view is on screen. `context` supplies the dish's obstruction map and boresight azimuth.
    func start(observer: Observer?, context: @escaping @MainActor () -> (ObstructionMap?, Double)) {
        task?.cancel()
        guard let observer else { state = .needsAccount; return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.tles.isEmpty || Date().timeIntervalSince(self.loadedAt) > Self.maxAge {
                    self.state = .loading
                    #if DEBUG
                    // Development aid: read a saved CelesTrak file so the view can be checked without spending the 2 hour download quota.
                    if let path = UserDefaults.standard.string(forKey: "debugTLEFile"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
                        self.tles = TLE.parse(text)
                    } else {
                        let load = try await TLELoader.load(cache: .standard)
                        self.tles = load.tles
                        self.elementsDownloadedAt = load.downloadedAt
                    }
                    #else
                    let load = try await TLELoader.load(cache: .standard)
                    self.tles = load.tles
                    self.elementsDownloadedAt = load.downloadedAt
                    #endif
                    self.loadedAt = Date()
                }
                if self.tracker?.observer != observer { self.tracker = StarlinkTracker(tles: self.tles, observer: observer) }
                self.constellationSize = self.tracker?.constellationSize ?? 0
                self.state = .active
                while !Task.isCancelled, let tracker = self.tracker {
                    let now = Date()
                    let visible = tracker.inView(at: now)
                    let (map, boresight) = context()
                    self.inView = visible
                    self.serving = self.chooser.choose(inView: visible, at: now) { sat in
                        map?.isClear(azimuthDeg: sat.azimuthDeg, elevationDeg: sat.elevationDeg, boresightAzimuthDeg: boresight) ?? true
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}

struct SatelliteView: View {
    var store: TelemetryStore
    var account: AccountStore

    private var satellites: SatelliteStore { store.satellites }

    private var observer: Observer? {
        #if DEBUG
        if Anonymizer.isOn { return Observer(latitudeDeg: 47.674, longitudeDeg: -122.121) }
        #endif
        guard case .connected(let info) = account.state, let lat = info.latitude, let lon = info.longitude else { return nil }
        // Altitude is unknown; at Starlink's 550 km a few hundred metres change the angles by far less than a pixel.
        return Observer(latitudeDeg: lat, longitudeDeg: lon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch satellites.state {
            case .needsAccount:
                switch account.state {
                case .connected:
                    Text("Your Starlink account did not return coordinates for the service address, so the sky cannot be placed.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                case .connecting:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to your Starlink account…").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary) }
                default:
                    Text("The sky view needs your location. It is taken from the service address of your Starlink account and kept in memory only.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                    Button("Sign in to Starlink…") { account.signIn() }.help("Open the Starlink sign-in page")
                }
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading orbital elements from CelesTrak…").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary) }
            case .failed(let message):
                Text("Could not load satellite positions. \(message)").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                Button("Try again") { startTracking() }.help("Fetch the orbital elements again")
            case .active:
                SkySceneView(mode: .sky, map: store.obstructionMap, boresightAzimuthDeg: Double(store.status?.boresightAzimuthDeg ?? 0),
                             boresightElevationDeg: Double(store.status?.boresightElevationDeg ?? 90),
                             satellites: satellites.inView, serving: satellites.serving, rotating: true)
                    .frame(height: 380).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Drag to orbit, scroll or pinch to zoom. Dots on the dome are the dish's obstruction map; dots beyond it are satellites.")
                    .font(Theme.ui(10)).foregroundStyle(Theme.inkSecondary)
                if let downloaded = satellites.elementsDownloadedAt {
                    Text("Orbital elements downloaded \(downloaded.formatted(date: .omitted, time: .shortened))").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                }
                Text("\(satellites.inView.count) in view · \(satellites.inView.filter { $0.elevationDeg >= ServingChooser.elevationFloorDeg }.count) above 25° · constellation \(satellites.constellationSize)")
                    .font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary)
                if let serving = satellites.serving {
                    HStack {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        Text("Likely serving: \(serving.name)").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(String(format: "el %.0f°  az %.0f°  %.0f km", serving.elevationDeg, serving.azimuthDeg, serving.rangeKm)).font(Theme.mono(11)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Text("Positions are computed on this Mac from CelesTrak's SpaceX-supplied orbital elements. The serving satellite is an inference: the highest one above 25° in a clear part of the dish's obstruction map, re-picked every 15 seconds. The dish does not report which satellite it uses.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .onAppear { startTracking() }
        .onDisappear { satellites.stop() }
        .onChange(of: observer) { _, _ in startTracking() }
    }

    private func startTracking() {
        satellites.start(observer: observer) { [store] in (store.obstructionMap, Double(store.status?.boresightAzimuthDeg ?? 0)) }
    }
}
