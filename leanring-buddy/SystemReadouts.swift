//
//  SystemReadouts.swift
//  leanring-buddy
//
//  Read-only probes of memory pressure and local model residency.
//
//  Both numbers exist to make the machine's real limits visible. Local
//  models only stay fast while they stay resident in memory, and on a
//  machine that is near its ceiling they get evicted silently — the user
//  sees an interaction that was quick a minute ago suddenly take far
//  longer, with nothing on screen to explain it. Surfacing free memory and
//  whether the model is currently loaded turns that into something legible.
//

import Foundation

enum SystemReadouts {
    /// Physical memory summary, e.g. "12.4 GB used of 18 GB · 1.2 GB free".
    /// Memory as separate values rather than one joined line.
    ///
    /// `memorySummary()` is built for a wide row and truncates badly in the
    /// sidebar, where the number matters most. Returning the parts lets a
    /// narrow caller stack them and draw a fill bar, which communicates
    /// pressure faster than any string does.
    struct MemoryBreakdown {
        let usedText: String
        let totalText: String
        let freeText: String
        let compressedText: String?
        /// 0...1, for a fill bar.
        let usedFraction: Double
    }

    static func memoryBreakdown() -> MemoryBreakdown {
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryBreakdown(
                usedText: "—",
                totalText: formatted(bytes: totalBytes),
                freeText: "—",
                compressedText: nil,
                usedFraction: 0
            )
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freeBytes = (UInt64(statistics.free_count) + UInt64(statistics.speculative_count)) * pageSize
        let usedBytes = totalBytes > freeBytes ? totalBytes - freeBytes : 0
        let compressedBytes = UInt64(statistics.compressor_page_count) * pageSize

        return MemoryBreakdown(
            usedText: formatted(bytes: usedBytes),
            totalText: formatted(bytes: totalBytes),
            freeText: formatted(bytes: freeBytes),
            compressedText: compressedBytes > 0 ? formatted(bytes: compressedBytes) : nil,
            usedFraction: totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        )
    }

    static func memorySummary() -> String {
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return "\(formatted(bytes: totalBytes)) total"
        }

        let pageSize = UInt64(vm_kernel_page_size)
        // "Free" in the sense a user cares about: pages that are immediately
        // available, which includes the speculative ones the kernel is happy
        // to give up.
        let freeBytes = (UInt64(statistics.free_count) + UInt64(statistics.speculative_count)) * pageSize
        let usedBytes = totalBytes > freeBytes ? totalBytes - freeBytes : 0

        var summary = "\(formatted(bytes: usedBytes)) used of \(formatted(bytes: totalBytes))"
        summary += " · \(formatted(bytes: freeBytes)) free"

        // Compressed memory is the honest early-warning sign of pressure —
        // it climbs well before anything visibly breaks.
        let compressedBytes = UInt64(statistics.compressor_page_count) * pageSize
        if compressedBytes > 0 {
            summary += " · \(formatted(bytes: compressedBytes)) compressed"
        }
        return summary
    }

    /// Which model Ollama currently holds in memory, if any.
    static func ollamaResidencySummary(
        baseURL: String = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
            ?? "http://localhost:11434"
    ) async -> String {
        guard let url = URL(string: "\(baseURL)/api/ps") else { return "unavailable" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = payload["models"] as? [[String: Any]] else {
                return "not loaded"
            }

            guard let model = models.first else { return "not loaded (will reload on next request)" }

            let name = model["name"] as? String ?? "unknown"
            guard let sizeBytes = model["size"] as? Double else { return name }
            return "\(name) · \(formatted(bytes: UInt64(sizeBytes))) resident"
        } catch {
            return "Ollama not reachable"
        }
    }

    private static func formatted(bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 {
            return String(format: "%.1f GB", gigabytes)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
