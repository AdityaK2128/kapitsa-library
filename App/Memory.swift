import Darwin
import Foundation

/// What macOS can give a model right now, read the way Activity Monitor does.
enum SystemMemory {
    static var totalGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// Memory macOS can hand out without swapping, as Activity Monitor computes it: everything except wired
    /// memory, compressed memory and app memory (anonymous pages that are not purgeable). Cached files and
    /// inactive pages count as available, because macOS reclaims them on demand.
    static func availableGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return totalGB / 2 }
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = Double(UInt64(stats.wire_count) + UInt64(stats.compressor_page_count) + appPages) * Double(vm_kernel_page_size) / 1_073_741_824
        return max(0, totalGB - used)
    }

    /// 1 normal, 2 warning, 4 critical.
    static func pressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 0
    }

    static func swapUsedGB() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Double(usage.xsu_used) / 1_073_741_824 : 0
    }

    /// GPU memory Kapitsa may hold with Memory Protection on: what other apps leave, less the reserve, and
    /// never above Kapitsa's own ceiling (Metal's recommended working set, about 94% of RAM).
    static func safeBudgetGB(margin: Double = Prefs.memoryMargin) -> Double {
        let budget = max(0, min(availableGB() - margin, totalGB * 0.9))
        return (budget * 10).rounded(.down) / 10
    }

    enum Fit { case comfortable, reclaims, tight }

    /// How a model of this size sits on this Mac right now.
    static func fit(needGB: Double) -> Fit {
        if needGB > totalGB * 0.85 { return .tight }
        if needGB > availableGB() - Prefs.memoryMargin { return .reclaims }
        return .comfortable
    }

    /// Rough need of a model at a small working set: weights, drafter, and KV/buffers.
    static func estimatedNeedGB(_ model: LocalModel) -> Double {
        let drafter = model.drafter.isEmpty ? 0 : folderWeightsGB(model.drafter)
        return Double(model.size) / 1_073_741_824 + drafter + 1.5
    }

    static func folderWeightsGB(_ path: String) -> Double {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix(".") }.reduce(0.0) { total, name in
            total + Double(FileManager.default.sizeFollowingLinks(atPath: path + "/" + name)) / 1_073_741_824
        }
    }

    static func allocatedBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
