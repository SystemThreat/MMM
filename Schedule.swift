import Foundation
import IOKit.ps
import CoreGraphics

/// SETUP's mining schedule. The default (always, no heat check) never holds mining.
struct MiningSchedule: Equatable {
    var mode = "always", idle = 10, from = "22:00", to = "07:00", hot = false
    static let modes = ["always", "power", "idle", "hours"]
    init() {}
    /// nil for anything out of range: an unknown mode, idle outside 1…120 minutes, a time not HH:MM, equal hours.
    init?(_ d: [String: Any]) {
        guard let m = d["mode"] as? String, Self.modes.contains(m),
              let idle = (d["idle"] as? Int) ?? (d["idle"] as? String).flatMap({ Int($0) }), (1...120).contains(idle),
              let from = d["from"] as? String, let to = d["to"] as? String,
              let a = minuteOfDay(from), let b = minuteOfDay(to), m != "hours" || a != b else { return nil }
        mode = m; self.idle = idle; self.from = from; self.to = to; hot = d["hot"] as? Bool ?? false
    }
    var dict: [String: Any] { ["mode": mode, "idle": idle, "from": from, "to": to, "hot": hot] }
}
/// "HH:MM" (24 h) → minutes since midnight.
func minuteOfDay(_ s: String) -> Int? {
    guard s.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { return nil }
    return Int(s.prefix(2))! * 60 + Int(s.suffix(2))!
}
struct ScheduleSensors { var onAC: Bool?; var idleSeconds: Double; var minute: Int; var thermal: ProcessInfo.ThermalState }
/// Why the schedule holds mining now, or nil. An unreadable power source never holds; heat is checked first.
func scheduleHold(_ s: MiningSchedule, _ now: ScheduleSensors) -> (code: String, reason: String)? {
    if s.hot, now.thermal == .serious || now.thermal == .critical { return ("hot", "the Mac is hot (" + (now.thermal == .critical ? "critical" : "serious") + ")") }
    switch s.mode {
    case "power" where now.onAC == false: return ("power", "on battery power")
    case "idle" where now.idleSeconds < Double(s.idle * 60): return ("idle", "the Mac is in use — mines after \(s.idle) idle min")
    case "hours":
        guard let a = minuteOfDay(s.from), let b = minuteOfDay(s.to) else { return nil }
        let inside = a < b ? (a..<b).contains(now.minute) : now.minute >= a || now.minute < b   // a > b: overnight
        return inside ? nil : ("hours", "outside mining hours \(s.from)–\(s.to)")
    default: return nil
    }
}
func readScheduleSensors(_ date: Date = Date()) -> ScheduleSensors {
    var onAC: Bool?
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
        onAC = (type as String) == kIOPMACPowerKey   // UPS power counts as off the adapter
    }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return ScheduleSensors(onAC: onAC, idleSeconds: idle, minute: (c.hour ?? 0) * 60 + (c.minute ?? 0), thermal: ProcessInfo.processInfo.thermalState)
}
