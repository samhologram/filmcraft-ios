import Foundation
@preconcurrency import FilmCraftKit

/// Tick <-> display conversions. Edit math stays in ticks; seconds exist only for display and zoom.
enum Timecode {
    /// Ticks per second (`filmcraft_time::TICKS_PER_SECOND`, 254 016 000 000).
    static let ticksPerSecond: Int64 = {
        let value = FilmCraftKit.ticksPerSecond()
        return value > 0 ? value : 254_016_000_000
    }()

    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(ticksPerSecond) }

    static func ticks(seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let value = seconds * Double(ticksPerSecond)
        guard value > Double(Int64.min / 2), value < Double(Int64.max / 2) else { return value < 0 ? 0 : Int64.max / 2 }
        return Int64(value)
    }

    /// Duration of one frame in ticks (rounded down; never 0).
    static func frameTicks(fpsNum: UInt32, fpsDen: UInt32) -> Int64 {
        guard fpsNum > 0, fpsDen > 0 else { return ticksPerSecond / 30 }
        let (product, overflow) = ticksPerSecond.multipliedReportingOverflow(by: Int64(fpsDen))
        guard !overflow else { return ticksPerSecond / 30 }
        return max(1, product / Int64(fpsNum))
    }

    static func frameTicks(_ state: ProjectState) -> Int64 { frameTicks(fpsNum: state.fpsNum, fpsDen: state.fpsDen) }

    /// "HH:MM:SS:FF".
    static func string(_ ticks: Int64, _ state: ProjectState) -> String {
        formatTimecode(ticks: max(0, ticks), fpsNum: max(1, state.fpsNum), fpsDen: max(1, state.fpsDen))
    }

    /// Frames per second as a Double (display / display-link pacing).
    static func fps(_ state: ProjectState) -> Double {
        guard state.fpsNum > 0, state.fpsDen > 0 else { return 30 }
        return Double(state.fpsNum) / Double(state.fpsDen)
    }
}
