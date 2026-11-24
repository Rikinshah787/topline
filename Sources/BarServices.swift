import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Live system info for widgets: CPU, memory, battery, frontmost app, running apps.
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var battery: Int?
    @Published var charging = false
    @Published var pluggedIn = false
    @Published var frontApp = ""
    @Published var runningBundleIDs: Set<String> = []
    /// Bytes per second over Wi-Fi / Ethernet / cellular.
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    private var lastNet: (down: UInt64, up: UInt64, time: Date)?

    private var lastTicks: (used: Double, total: Double)?
    private var timer: Timer?

    private init() {
        update()
        updateApps()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateApps() }
            }
        }
    }

    private func updateApps() {
        let ws = NSWorkspace.shared
        if let front = ws.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontApp = front.localizedName ?? ""
        }
        runningBundleIDs = Set(ws.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func update() {
        // CPU
        if let t = Self.cpuTicks() {
            if let last = lastTicks, t.total > last.total {
                cpu = (t.used - last.used) / (t.total - last.total) * 100
            }
            lastTicks = t
        }
        // Memory (app + wired + compressed, like Activity Monitor's "Memory Used")
        if let used = Self.memoryUsed() {
            memory = used / Double(ProcessInfo.processInfo.physicalMemory) * 100
        }
        // Network
        let (down, up) = Self.netBytes()
        let now = Date()
        if let last = lastNet, down >= last.down, up >= last.up {   // counters are 32-bit and can wrap; skip that sample
            let dt = now.timeIntervalSince(last.time)
            if dt > 0 { netDown = Double(down - last.down) / dt; netUp = Double(up - last.up) / dt }
        }
        lastNet = (down, up, now)
        // Battery
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as [CFTypeRef]
        battery = nil
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                battery = Int((Double(cap) / Double(max) * 100).rounded())
            }
            charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            pluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }

    private static func netBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var down: UInt64 = 0, up: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data else { continue }
            let name = String(cString: a.ifa_name)
            // Physical interfaces only — VPN tunnels (utun) would double-count the same traffic.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(d.ifi_ibytes); up += UInt64(d.ifi_obytes)
        }
        return (down, up)
    }

    private static func cpuTicks() -> (used: Double, total: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0), sys = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        return (user + sys + nice, user + sys + idle + nice)
    }

    private static func memoryUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = Double(sysconf(_SC_PAGESIZE))
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }
}

/// Fetches quotes for every stock widget on the bar.
@MainActor
final class QuoteStore: ObservableObject {
    static let shared = QuoteStore()

    @Published var quotes: [String: Quote] = [:]
    private var lastFetch: [String: Date] = [:]
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private var symbols: Set<String> {
        var s = Set<String>()
        for z in Zone.allCases {
            for item in BarStore.shared.layout[z] {
                if case .widget(.stock, let sym?) = item.kind { s.insert(sym) }
            }
        }
        return s
    }

    /// Fetches any symbol that's new or older than the refresh interval.
    func sync(force: Bool = false) {
        let now = Date()
        for sym in symbols where force || now.timeIntervalSince(lastFetch[sym] ?? .distantPast) >= Prefs.refreshInterval {
            lastFetch[sym] = now
            Task { @MainActor in
                if let q = try? await fetchQuote(sym) {
                    self.quotes[sym] = q
                    PriceAlerts.shared.check(q)
                }
            }
        }
    }
}

/// Keeps the Mac (and display) awake — indefinitely or for a set time.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published private(set) var active = false
    @Published private(set) var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func start(minutes: Int?) {
        stop()
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Topline Keep Awake" as CFString, &id) == kIOReturnSuccess else { return }
        assertion = id
        active = true
        if let minutes {
            until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if active { IOPMAssertionRelease(assertion) }
        active = false
        until = nil
    }

    func toggle() { active ? stop() : start(minutes: nil) }
}

/// "840 KB/s", "12.4 MB/s"
func formatRate(_ bytesPerSec: Double) -> String {
    let kb = bytesPerSec / 1024
    if kb < 1000 { return String(format: "%.0f KB/s", kb) }
    let mb = kb / 1024
    return mb < 100 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f MB/s", mb)
}
