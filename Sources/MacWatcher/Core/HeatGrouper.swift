import Foundation

/// Groups processes into calm, logical app/family heat culprits (CPU + GPU + Disk I/O)
/// and applies sort hysteresis so near-ties never jitter or jump under the user's cursor.
public enum HeatGrouper {
    public static func group(
        processes: [ProcessEntry],
        window: HeatWindow,
        totalHeatSeconds: Double,
        previousOrder: [String],
        freezeOrder: Bool
    ) -> [HeatGroup] {
        var buckets: [String: [ProcessEntry]] = [:]
        var namesByKey: [String: String] = [:]
        var bundleByKey: [String: String] = [:]

        for proc in processes {
            let (key, groupName, bundlePath) = groupingKey(for: proc)
            buckets[key, default: []].append(proc)
            if namesByKey[key] == nil {
                namesByKey[key] = groupName
            }
            if let bundlePath, bundleByKey[key] == nil {
                bundleByKey[key] = bundlePath
            }
        }

        let denominator = max(totalHeatSeconds, 0.001)
        var groups: [HeatGroup] = []
        groups.reserveCapacity(buckets.count)

        for (key, rawMembers) in buckets {
            let sortedMembers = rawMembers.sorted { a, b in
                let ha = a.heatScore(for: window)
                let hb = b.heatScore(for: window)
                if abs(ha - hb) > 0.05 { return ha > hb }
                if abs(a.cpuPercent - b.cpuPercent) > 0.5 { return a.cpuPercent > b.cpuPercent }
                return a.memoryBytes > b.memoryBytes
            }

            guard let rep = sortedMembers.first else { continue }

            let sumScore = sortedMembers.reduce(0.0) { $0 + $1.heatScore(for: window) }
            let sumCPUHeat = sortedMembers.reduce(0.0) { $0 + $1.cpuHeatSeconds(for: window) }
            let sumGPUHeat = sortedMembers.reduce(0.0) { $0 + $1.gpuHeatSeconds(for: window) }
            let sumDisk = sortedMembers.reduce(UInt64(0)) { $0 &+ $1.diskIOBytes(for: window) }
            let sumLiveCPU = sortedMembers.reduce(0.0) { $0 + $1.cpuPercent }
            let sumMem = sortedMembers.reduce(UInt64(0)) { $0 + ($1.isExited ? 0 : $1.memoryBytes) }
            let exitedCount = sortedMembers.filter(\.isExited).count
            let activeCount = sortedMembers.count - exitedCount
            let share = totalHeatSeconds > 0.1 ? min(100.0, (sumScore / denominator) * 100.0) : 0.0

            groups.append(HeatGroup(
                id: key,
                name: namesByKey[key] ?? rep.name,
                bundlePath: bundleByKey[key],
                representative: rep,
                members: sortedMembers,
                heatSeconds: sumScore,
                cpuHeatSeconds: sumCPUHeat,
                gpuHeatSeconds: sumGPUHeat,
                diskIOBytes: sumDisk,
                heatSharePercent: share,
                liveCPUPercent: sumLiveCPU,
                totalMemoryBytes: sumMem,
                isSystemGroup: sortedMembers.allSatisfy(\.isSystemProcess),
                activeCount: activeCount,
                exitedCount: exitedCount
            ))
        }

        var ranked = groups.sorted { a, b in
            if abs(a.heatSeconds - b.heatSeconds) > 0.05 {
                return a.heatSeconds > b.heatSeconds
            }
            if abs(a.liveCPUPercent - b.liveCPUPercent) > 0.5 {
                return a.liveCPUPercent > b.liveCPUPercent
            }
            return a.totalMemoryBytes > b.totalMemoryBytes
        }

        guard !previousOrder.isEmpty else {
            return ranked
        }

        let prevIndex = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($1, $0) })

        if freezeOrder {
            ranked.sort { a, b in
                let ia = prevIndex[a.id] ?? Int.max
                let ib = prevIndex[b.id] ?? Int.max
                if ia != ib { return ia < ib }
                return a.heatSeconds > b.heatSeconds
            }
            return ranked
        }

        var byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        var ordered: [HeatGroup] = []
        ordered.reserveCapacity(ranked.count)

        for id in previousOrder {
            if let g = byID.removeValue(forKey: id) {
                ordered.append(g)
            }
        }
        for g in ranked where byID[g.id] != nil {
            ordered.append(g)
        }

        for i in 1..<ordered.count {
            var j = i
            while j > 0 {
                let curr = ordered[j]
                let above = ordered[j - 1]
                let margin = max(0.5, above.heatSeconds * 0.10)
                let beatsHeat = curr.heatSeconds > above.heatSeconds + margin
                let beatsColdStart = above.heatSeconds < 0.2 && curr.heatSeconds < 0.2 && curr.liveCPUPercent > above.liveCPUPercent + 5.0
                if beatsHeat || beatsColdStart {
                    ordered.swapAt(j, j - 1)
                    j -= 1
                } else {
                    break
                }
            }
        }

        return ordered
    }

    private static func groupingKey(for proc: ProcessEntry) -> (key: String, name: String, bundlePath: String?) {
        if let bundlePath = proc.bundlePath {
            let appName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let cleanName = appName.isEmpty ? proc.name : appName
            return ("app:\(bundlePath)", cleanName, bundlePath)
        }
        let baseName = proc.rawName.isEmpty ? proc.name : proc.rawName
        return ("proc:\(baseName.lowercased())", proc.name, nil)
    }
}
