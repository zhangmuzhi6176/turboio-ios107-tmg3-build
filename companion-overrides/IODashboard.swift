import Foundation

// Shared by the phone UI and offline tests. No transport or synthetic readings.
enum IODashboardRules {
    static func fresh(_ timestamp: Date, now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && maximumAge.isFinite && maximumAge >= 0 && (0...maximumAge).contains(age)
    }

    static func dueToday(dueAt: Date?, completed: Bool, archivedAt: Date?, now: Date, calendar: Calendar) -> Bool {
        guard !completed, archivedAt == nil, let dueAt,
              dueAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { return false }
        return calendar.isDate(dueAt, inSameDayAs: now)
    }

    static func validCoordinate(latitude: Double, longitude: Double, horizontalAccuracy: Double,
                                timestamp: Date, now: Date) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && horizontalAccuracy.isFinite && (0...50).contains(horizontalAccuracy)
            && fresh(timestamp, now: now, maximumAge: 15)
    }

    static func speedKPH(metresPerSecond: Double, accuracy: Double, coordinateValid: Bool) -> Double? {
        guard coordinateValid, metresPerSecond.isFinite, (0...100).contains(metresPerSecond),
              accuracy.isFinite, (0...10).contains(accuracy) else { return nil }
        return metresPerSecond * 3.6
    }

    static func altitudeMetres(_ altitude: Double, verticalAccuracy: Double, coordinateValid: Bool) -> Double? {
        guard coordinateValid, altitude.isFinite, (-500...10_000).contains(altitude),
              verticalAccuracy.isFinite, (0...50).contains(verticalAccuracy) else { return nil }
        return altitude
    }

    static func temperatureCelsius(_ temperature: Double, fetchedAt: Date, now: Date) -> Double? {
        guard temperature.isFinite, (-80...60).contains(temperature),
              fresh(fetchedAt, now: now, maximumAge: 600) else { return nil }
        return temperature
    }

    static func batteryPercent(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}

#if !IO_DASHBOARD_LOGIC_TEST
import SwiftUI
import Combine
import CoreLocation

@MainActor
final class IODashboardLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var sample: CLLocation?
    @Published private(set) var updating = false
    @Published private(set) var status = "尚未启用手机定位"
    private let manager = CLLocationManager()
    private var requestedByUser = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = true
    }

    func request() {
        requestedByUser = true
        guard CLLocationManager.locationServicesEnabled() else {
            stop(); status = "手机定位服务未开启"; return
        }
        authorizeOrStart()
    }

    private func authorizeOrStart() {
        guard requestedByUser else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "等待定位授权"
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            updating = true
            status = "正在获取手机速度和海拔"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            stop(); status = "定位未授权；可在 iPhone 设置中允许"
        @unknown default:
            stop(); status = "定位权限状态不可用"
        }
    }

    func stop() {
        requestedByUser = false
        manager.stopUpdatingLocation()
        updating = false
        sample = nil
        status = "手机定位已停止"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorizeOrStart() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requestedByUser, updating,
              let latest = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        if let sample, latest.timestamp < sample.timestamp { return }
        let now = Date()
        guard Self.coordinateValid(latest, now: now) else {
            sample = nil; status = "定位暂不准确，等待有效数据"; return
        }
        sample = latest
        status = "已收到手机定位；超过 15 秒的数据不显示为当前值"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requestedByUser else { return }
        if (error as? CLError)?.code == .denied {
            stop(); status = "定位权限已关闭"
        } else {
            status = "暂时无法定位，等待新的有效数据"
        }
    }

    static func coordinateValid(_ sample: CLLocation, now: Date) -> Bool {
        IODashboardRules.validCoordinate(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude,
                                        horizontalAccuracy: sample.horizontalAccuracy, timestamp: sample.timestamp, now: now)
    }

    func speed(now: Date) -> Double? {
        guard let sample else { return nil }
        return IODashboardRules.speedKPH(metresPerSecond: sample.speed, accuracy: sample.speedAccuracy,
                                        coordinateValid: Self.coordinateValid(sample, now: now))
    }

    func altitude(now: Date) -> Double? {
        guard let sample else { return nil }
        return IODashboardRules.altitudeMetres(sample.altitude, verticalAccuracy: sample.verticalAccuracy,
                                             coordinateValid: Self.coordinateValid(sample, now: now))
    }
}

struct IODashboardView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var weather: QWeatherDashboard
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var location = IODashboardLocation()
    @State private var batteryObservedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            dashboard(now: context.date)
        }
        .navigationTitle("仪表盘")
        .onReceive(features.$battery.dropFirst()) { value in
            batteryObservedAt = IODashboardRules.batteryPercent(value) == nil ? nil : Date()
        }
        .onChange(of: scenePhase) { phase in
            // Permission sheets temporarily make the scene inactive. Do not
            // cancel the user's pending authorization while that sheet is up.
            if phase == .background { location.stop() }
        }
        .onDisappear { location.stop(); batteryObservedAt = nil }
    }

    private func dashboard(now: Date) -> some View {
        List {
            Section {
                Text(now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityIdentifier("dashboard-time")
                Text(now, format: .dateTime.year().month().day().weekday())
                Text("iPhone 系统时间 · \(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
            }
            Section("天气与眼镜") {
                weatherRows(now: now)
                batteryRow(now: now)
            }
            Section {
                metric("运动速度", value: location.speed(now: now).map { String(format: "%.1f km/h", $0) } ?? "未获取",
                       detail: locationDetail(now: now), identifier: "dashboard-speed")
                metric("海拔", value: location.altitude(now: now).map { String(format: "%.0f m", $0) } ?? "未获取",
                       detail: locationDetail(now: now), identifier: "dashboard-altitude")
                Button(location.updating ? "停止手机定位" : "启用手机定位") {
                    if location.updating { location.stop() } else { location.request() }
                }.accessibilityIdentifier("dashboard-location-toggle")
                Text(location.status).font(.caption).foregroundStyle(.secondary)
            } header: { Text("运动数据") } footer: {
                Text("来源是随身 iPhone。仅本页前台采集，离开或锁屏后停止；无效精度和过期数据不填成 0。")
            }
            todoSection(now: now)
            Section {
                Text("这是手机仪表盘。本页不会安装、排序或更新眼镜卡片。")
                    .font(.caption).foregroundStyle(.secondary)
                if store.demoMode {
                    Text("当前为演示模式，天气、电量和待办示例未作为真实数据展示。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }.accessibilityIdentifier("io-dashboard")
    }

    @ViewBuilder private func weatherRows(now: Date) -> some View {
        if !store.demoMode, let snapshot = weather.snapshot {
            let temperature = IODashboardRules.temperatureCelsius(snapshot.temperature, fetchedAt: snapshot.fetchedAt, now: now)
            let fresh = temperature != nil
            let source = "和风天气 · \(weather.configuration.location) · 获取 \(stamp(snapshot.fetchedAt))\(fresh ? "" : " · 已过期或无效")"
            metric("天气", value: fresh && !snapshot.condition.isEmpty ? snapshot.condition : "未获取",
                   detail: source, identifier: "dashboard-weather")
            metric("温度", value: temperature.map { String(format: "%.1f °C", $0) } ?? "未获取",
                   detail: source, identifier: "dashboard-temperature")
            if !snapshot.attributions.isEmpty {
                Text(snapshot.attributions.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            metric("天气", value: "未获取", detail: "来源：已配置的和风天气；尚无接收数据", identifier: "dashboard-weather")
            metric("温度", value: "未获取", detail: "本页只读取已有天气，不自动请求或发送", identifier: "dashboard-temperature")
        }
    }

    private func batteryRow(now: Date) -> some View {
        let percent = store.demoMode || !runtime.ready ? nil : IODashboardRules.batteryPercent(features.battery)
        let stale = batteryObservedAt.map { !IODashboardRules.fresh($0, now: now, maximumAge: 120) } ?? false
        let value = percent.map { stale ? "已过期" : "\($0)%" } ?? "未获取"
        let detail: String
        if let percent, let observed = batteryObservedAt {
            detail = "眼镜回报 · 本页收到于 \(stamp(observed))\(stale ? " · 上次 \(percent)%" : "")"
        } else if percent != nil {
            detail = "眼镜缓存回报 · 接收时间未记录"
        } else {
            detail = runtime.ready ? "眼镜设备回报 · 尚无有效电量" : "眼镜未连接 · 尚无当前电量"
        }
        return metric("眼镜电量", value: value, detail: detail, identifier: "dashboard-battery")
    }

    private func todoSection(now: Date) -> some View {
        let rows = store.demoMode ? [] : store.todos.filter {
            IODashboardRules.dueToday(dueAt: $0.dueAt, completed: $0.completed, archivedAt: $0.archivedAt,
                                     now: now, calendar: .current)
        }.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        let undated = store.demoMode ? 0 : store.todos.filter { !$0.completed && $0.archivedAt == nil && $0.dueAt == nil }.count
        return Section {
            if rows.isEmpty { Text("暂无已明确安排在今天的未完成待办").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                    Text(todoSource(row)).font(.caption).foregroundStyle(.secondary)
                    if let due = row.dueAt {
                        Text(row.reminderDueComponents.flatMap { SystemReminderSnapshot.dateOnlyLabel($0) }
                             ?? "计划 \(due.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if undated > 0 { Text("另有 \(undated) 条未标日期的未完成待办，未计入今天。").font(.caption).foregroundStyle(.secondary) }
            NavigationLink("从 iPhone 提醒事项导入") { ReminderImportView() }
                .accessibilityIdentifier("dashboard-import-reminders")
        } header: { Text("今日待办 · \(rows.count)") } footer: {
            Text("按手机日期和明确的计划日期筛选。提醒事项仅在你授权后读取、选择后导入，不持续同步；本页不读取雷鸟云待办。")
        }
    }

    private func todoSource(_ row: LocalTodo) -> String {
        if row.reminderSourceID != nil {
            return "iPhone 提醒事项导入快照" + (row.reminderImportedAt.map { " · 导入 \(stamp($0))" } ?? " · 导入时间未记录")
        }
        return row.wireID != nil ? "本机待办 · 已关联眼镜 ID，非云同步证明" : "本机待办"
    }

    private func locationDetail(now: Date) -> String {
        guard let sample = location.sample else { return "来源：iPhone 定位 · 尚无有效数据" }
        let fresh = IODashboardLocation.coordinateValid(sample, now: now)
        return "iPhone 定位 · \(stamp(sample.timestamp))\(fresh ? "" : " · 已过期或无效")"
    }

    private func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .standard) }

    private func metric(_ title: String, value: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value).font(.headline).monospacedDigit().multilineTextAlignment(.trailing)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier(identifier)
    }
}
#endif
