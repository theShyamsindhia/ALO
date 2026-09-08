import Darwin

/// Bridge expiry uses elapsed time including sleep. Audio's absolute clock is
/// deliberately unchanged. Deadlines remain invalid across receiver restart.
public enum DeviceMessagingClock {
    public static func nowNanos() -> UInt64 {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0, info.numer > 0 else { return UInt64.max }
        let ticks = mach_continuous_time()
        let quotient = ticks / UInt64(info.denom)
        let remainder = ticks % UInt64(info.denom)
        let (whole, overflow) = quotient.multipliedReportingOverflow(by: UInt64(info.numer))
        let fraction = remainder * UInt64(info.numer) / UInt64(info.denom)
        let (result, additionOverflow) = whole.addingReportingOverflow(fraction)
        return overflow || additionOverflow ? UInt64.max : result
    }
}
