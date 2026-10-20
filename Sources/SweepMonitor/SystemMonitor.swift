import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One reading of the Mac's vital signs.
public struct SystemSnapshot: Sendable, Equatable {
    public struct Memory: Sendable, Equatable {
        public var total: UInt64
        public var used: UInt64
        public var wired: UInt64
        public var compressed: UInt64
        public var cached: UInt64
        public var swapUsed: UInt64
        /// 1 = normal, 2 = warning, 4 = critical (macOS's own judgement).
        public var pressureLevel: Int
        public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    public struct Disk: Sendable, Equatable {
        public var total: UInt64
        /// Space macOS can make available (includes purgeable).
        public var available: UInt64
        public var freeFraction: Double { total == 0 ? 0 : Double(available) / Double(total) }
    }

    public struct Battery: Sendable, Equatable {
        public var charge: Double
        public var isCharging: Bool
        public var isPluggedIn: Bool
        public var minutesRemaining: Int?
        public var cycleCount: Int?
        /// Maximum capacity relative to design capacity.
        public var health: Double?
        /// Charge cycles the battery is designed for (1000 on recent MacBooks).
        public var designCycleCount: Int? = nil
    }

    public struct Network: Sendable, Equatable {
        public var bytesInPerSecond: Double
        public var bytesOutPerSecond: Double
    }

    public var date: Date
    /// 0…1 across all cores, nil on the first reading.
    public var cpuUsage: Double?
    public var cpuCores: Int
    public var memory: Memory
    public var disk: Disk
    public var battery: Battery?
    public var network: Network?
    public var uptime: TimeInterval
    public var thermalState: ProcessInfo.ThermalState
}

/// Takes readings; keeps the previous one to turn counters into rates.
public final class SystemMonitor: @unchecked Sendable {
    private var lastTicks: [UInt64]?
    private var lastNetwork: (date: Date, counters: [String: Traffic])?
    private let lock = NSLock()

    public init() {}

    public func sample(volume: String = "/") -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let ticks = Self.cpuTicks()
        var cpu: Double?
        if let previous = lastTicks, let ticks, previous.count == ticks.count {
            // ticks: [user, system, idle, nice] per core, flattened
            var busy: UInt64 = 0, total: UInt64 = 0
            // The kernel's tick counters are 32-bit, so differences are taken in 32 bits to survive a wrap.
            func delta(_ index: Int) -> UInt64 {
                UInt64(UInt32(truncatingIfNeeded: ticks[index]) &- UInt32(truncatingIfNeeded: previous[index]))
            }
            for index in stride(from: 0, to: ticks.count, by: 4) {
                let user = delta(index), system = delta(index + 1)
                let idle = delta(index + 2), nice = delta(index + 3)
                busy += user + system + nice
                total += user + system + idle + nice
            }
            cpu = total == 0 ? 0 : Double(busy) / Double(total)
        }
        lastTicks = ticks

        let counters = Self.interfaceCounters()
        var network: SystemSnapshot.Network?
        if let previous = lastNetwork {
            let seconds = max(now.timeIntervalSince(previous.date), 0.001)
            let moved = Self.traffic(from: previous.counters, to: counters)
            network = .init(bytesInPerSecond: Double(moved.bytesIn) / seconds, bytesOutPerSecond: Double(moved.bytesOut) / seconds)
        }
        lastNetwork = (now, counters)

        return SystemSnapshot(date: now, cpuUsage: cpu, cpuCores: ProcessInfo.processInfo.activeProcessorCount,
                              memory: Self.memory(), disk: Self.disk(volume), battery: Self.battery(), network: network,
                              uptime: Self.uptime(), thermalState: ProcessInfo.processInfo.thermalState)
    }

    // MARK: Readers

    static func cpuTicks() -> [UInt64]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [UInt64] = []
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks += [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map { UInt64(UInt32(bitPattern: info[base + Int($0)])) }
        }
        return ticks
    }

    static func memory() -> SystemSnapshot.Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return .init(total: total, used: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, pressureLevel: 1)
        }
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let app = (UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        // "Memory used" as Activity Monitor shows it: app memory + wired + compressed.
        let used = min(total, app + wired + compressed)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.stride
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        return .init(total: total, used: used, wired: wired, compressed: compressed, cached: cached,
                     swapUsed: swap.xsu_used, pressureLevel: Int(level))
    }

    static func disk(_ volume: String) -> SystemSnapshot.Disk {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: keys)
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        let available = important ?? UInt64(values?.volumeAvailableCapacity ?? 0)
        return .init(total: total, available: min(available, total))
    }

    public static func battery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let minutes = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            var battery = SystemSnapshot.Battery(
                charge: Double(current) / Double(maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: minutes, cycleCount: nil, health: nil)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                battery.cycleCount = (property("CycleCount") as? NSNumber)?.intValue
                battery.designCycleCount = (property("DesignCycleCount9C") as? NSNumber)?.intValue
                // Newer macOS keeps capacities in a "BatteryData" dictionary; older versions at the top level.
                let data = property("BatteryData") as? [String: Any] ?? [:]
                battery.health = Self.health(
                    design: (property("DesignCapacity") as? NSNumber)?.intValue ?? (data["DesignCapacity"] as? NSNumber)?.intValue,
                    full: [(property("AppleRawMaxCapacity") as? NSNumber)?.intValue, (property("NominalChargeCapacity") as? NSNumber)?.intValue,
                           (data["NominalChargeCapacity"] as? NSNumber)?.intValue, (data["FullChargeCapacity"] as? NSNumber)?.intValue]
                        .compactMap { $0 }.first)
            }
            return battery
        }
        return nil
    }

    /// Maximum capacity as a fraction of the design capacity, as System Settings → Battery shows it.
    static func health(design: Int?, full: Int?) -> Double? {
        guard let design, design > 0, let full, full > 100 else { return nil }
        return min(1, Double(full) / Double(design))
    }

    struct Traffic: Equatable {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    /// Bytes moved between two readings, interface by interface. An interface that appeared, disappeared or
    /// reset its counters (a VPN reconnecting, a USB adapter unplugged) adds nothing instead of a huge jump.
    static func traffic(from previous: [String: Traffic], to current: [String: Traffic]) -> Traffic {
        var moved = Traffic(bytesIn: 0, bytesOut: 0)
        for (name, now) in current {
            guard let before = previous[name] else { continue }
            if now.bytesIn >= before.bytesIn { moved.bytesIn += now.bytesIn - before.bytesIn }
            if now.bytesOut >= before.bytesOut { moved.bytesOut += now.bytesOut - before.bytesOut }
        }
        return moved
    }

    /// Loopback, and tunnels whose traffic is also counted on the physical interface carrying it.
    static func isCounted(_ name: String) -> Bool {
        !["lo", "utun", "ipsec", "ppp", "gif", "stf", "tun", "tap"].contains { name.hasPrefix($0) }
    }

    /// 64-bit byte counters per interface (the `getifaddrs` ones are 32-bit and wrap every 4 GB).
    static func interfaceCounters() -> [String: Traffic] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }
        var counters: [String: Traffic] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if isCounted(interface) {
                            counters[interface] = Traffic(bytesIn: message.ifm_data.ifi_ibytes, bytesOut: message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += size
            }
        }
        return counters
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }
}
