import SmartWearCore
import SwiftUI

/// Tab "Thêm": quét, chọn nhiều, kết nối song song.
struct AddTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let m = app.manager
        let groups = grouped
        let count = groups.reduce(0) { $0 + $1.items.count }
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Thêm thiết bị").font(.largeTitle.weight(.bold))
                        Spacer()
                        GlassButton(title: m.isScanning ? "Dừng" : "Quét lại") {
                            if m.isScanning { m.stopScan() } else { m.startScan() }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(count)").font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("thiết bị ở gần").font(.title3).foregroundStyle(Palette.secondary)
                    }
                    HStack(spacing: 8) {
                        if m.isScanning { ProgressView().controlSize(.small).tint(.white) }
                        Text(m.isScanning ? "Đang tìm thiết bị gần đây…" : "Quét xong · chọn nhiều để kết nối cùng lúc")
                            .font(.subheadline).foregroundStyle(Palette.secondary)
                    }

                    ForEach(groups, id: \.title) { group in
                        SectionTitle(text: group.title, trailing: "\(group.items.count) thiết bị · có SDK")
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, d in
                                ScanRow(item: d)
                                if i < group.items.count - 1 { Divider().overlay(Palette.hairline).padding(.leading, 58) }
                            }
                        }
                        .card()
                    }

                    if m.ignoredCount > 0 {
                        Text("\(m.ignoredCount) thiết bị BLE khác không thuộc driver nào nên được ẩn. Thêm loại mới bằng một driver, giao diện tự sinh theo khả năng.")
                            .font(.footnote).foregroundStyle(Palette.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 180)
            }
            .scrollIndicators(.hidden)

            if !app.selectedForConnect.isEmpty {
                PrimaryButton(
                    title: "Kết nối song song \(app.selectedForConnect.count) thiết bị", symbol: "link"
                ) { app.connectSelected() }
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: app.selectedForConnect)
        .onAppear { if !m.isScanning { m.startScan() } }
    }

    private var grouped: [(title: String, items: [DiscoveredDevice])] {
        let m = app.manager
        return m.registry.drivers.compactMap { driver in
            let items = m.discoveredSorted.filter { $0.driverId == driver.id }
            return items.isEmpty ? nil : (driver.displayName, items)
        }
    }
}

struct ScanRow: View {
    @Environment(AppState.self) private var app
    let item: DiscoveredDevice

    var body: some View {
        let managed = app.manager.device(item.id)
        let busy = managed.map { $0.state != .disconnected } ?? false
        let selected = app.selectedForConnect.contains(item.id)
        HStack(spacing: 14) {
            Image(systemName: busy ? "checkmark.circle.fill" : (selected ? "checkmark.circle.fill" : "circle"))
                .font(.title2)
                .foregroundStyle(busy ? Palette.tertiary : (selected ? Color(hex: 0x0A84FF) : Palette.tertiary))
            Orb(color: app.color(item.id), size: 30, filled: busy)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.headline).lineLimit(1)
                Text(subtitle(managed)).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer()
            if item.scanned.rssi != 0 {
                Text("\(item.scanned.rssi)").font(.footnote.monospacedDigit()).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy else {
                if let managed { app.open(managed) }
                return
            }
            if selected { app.selectedForConnect.remove(item.id) } else { app.selectedForConnect.insert(item.id) }
        }
    }

    private func subtitle(_ managed: WearableDevice?) -> String {
        var parts = [item.match.kind.title]
        if let managed, managed.state != .disconnected { parts.append(managed.state.title) }
        else if item.scanned.systemConnected { parts.append("hệ thống đang nối") }
        if let mac = item.match.mac { parts.append(mac) }
        return parts.joined(separator: " · ")
    }
}
