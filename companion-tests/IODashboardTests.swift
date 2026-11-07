import Foundation

@main
struct IODashboardTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
            precondition(condition(), reason)
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        expect(IODashboardRules.fresh(now, now: now, maximumAge: 15), "current reading")
        expect(!IODashboardRules.fresh(now.addingTimeInterval(1), now: now, maximumAge: 15), "future reading")
        expect(!IODashboardRules.fresh(now.addingTimeInterval(-16), now: now, maximumAge: 15), "stale reading")
        expect(!IODashboardRules.fresh(Date(timeIntervalSince1970: .nan), now: now, maximumAge: 15), "nonfinite date")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        let start = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        func due(_ date: Date?, completed: Bool = false, archived: Date? = nil) -> Bool {
            IODashboardRules.dueToday(dueAt: date, completed: completed, archivedAt: archived, now: today, calendar: calendar)
        }
        expect(due(start), "local midnight is today")
        expect(due(tomorrow.addingTimeInterval(-1)), "last second today")
        expect(!due(tomorrow), "tomorrow excluded")
        expect(!due(start.addingTimeInterval(-1)), "yesterday excluded")
        expect(!due(nil), "undated task must not be invented as today")
        expect(!due(today, completed: true), "completed task excluded")
        expect(!due(today, archived: today), "archived task excluded")
        expect(!due(Date(timeIntervalSince1970: .infinity)), "nonfinite deadline excluded")
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        expect(!IODashboardRules.dueToday(dueAt: start, completed: false, archivedAt: nil, now: today, calendar: utc),
               "day selection respects caller timezone, not UTC by accident")

        func coordinate(_ latitude: Double = 31.2, _ longitude: Double = 121.5, _ accuracy: Double = 5,
                        _ timestamp: Date? = nil) -> Bool {
            IODashboardRules.validCoordinate(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy,
                                             timestamp: timestamp ?? now, now: now)
        }
        expect(coordinate(), "valid measured coordinate")
        expect(!coordinate(91), "out of range latitude")
        expect(!coordinate(31.2, .nan), "nonfinite longitude")
        expect(!coordinate(31.2, 121.5, -1), "invalid horizontal accuracy")
        expect(!coordinate(31.2, 121.5, 51), "poor horizontal accuracy")
        expect(!coordinate(31.2, 121.5, 5, now.addingTimeInterval(-16)), "stale coordinate")
        expect(IODashboardRules.speedKPH(metresPerSecond: 10, accuracy: 1, coordinateValid: true) == 36, "m/s converted to km/h")
        expect(IODashboardRules.speedKPH(metresPerSecond: 0, accuracy: 1, coordinateValid: true) == 0, "measured stationary speed remains zero")
        expect(IODashboardRules.speedKPH(metresPerSecond: -1, accuracy: 1, coordinateValid: true) == nil, "unknown speed is not zero")
        expect(IODashboardRules.speedKPH(metresPerSecond: 10, accuracy: -1, coordinateValid: true) == nil, "unknown speed accuracy")
        expect(IODashboardRules.speedKPH(metresPerSecond: 101, accuracy: 1, coordinateValid: true) == nil, "unreasonable speed")
        expect(IODashboardRules.speedKPH(metresPerSecond: 10, accuracy: 1, coordinateValid: false) == nil, "invalid fix blocks speed")
        expect(IODashboardRules.altitudeMetres(-430, verticalAccuracy: 5, coordinateValid: true) == -430, "valid below-sea-level altitude")
        expect(IODashboardRules.altitudeMetres(0, verticalAccuracy: -1, coordinateValid: true) == nil, "invalid altitude accuracy is not sea level")
        expect(IODashboardRules.altitudeMetres(.infinity, verticalAccuracy: 5, coordinateValid: true) == nil, "nonfinite altitude")
        expect(IODashboardRules.altitudeMetres(20, verticalAccuracy: 60, coordinateValid: true) == nil, "poor vertical accuracy")
        expect(IODashboardRules.temperatureCelsius(21, fetchedAt: now.addingTimeInterval(-600), now: now) == 21, "weather freshness boundary")
        expect(IODashboardRules.temperatureCelsius(21, fetchedAt: now.addingTimeInterval(-601), now: now) == nil, "stale weather hidden")
        expect(IODashboardRules.temperatureCelsius(90, fetchedAt: now, now: now) == nil, "invalid temperature hidden")
        expect(IODashboardRules.batteryPercent(nil) == nil, "missing battery is not fabricated")
        expect(IODashboardRules.batteryPercent(0) == 0, "actual empty battery is valid")
        expect(IODashboardRules.batteryPercent(101) == nil, "out of range battery rejected")
        print("IODashboard data validity and local-day filtering: \(checks) checks PASS")
    }
}
