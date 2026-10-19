import SmartWearCore
import SwiftUI

/// Bố cục Find My: trường tín hiệu nửa trên, sheet kéo được nửa dưới, thanh tab kính nổi.
struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height
            let collapsed = full * 0.58
            let expanded = full * 0.9
            let base = app.sheetExpanded ? expanded : collapsed
            let height = min(full * 0.96, max(full * 0.3, base - drag))
            ZStack(alignment: .bottom) {
                AmbientBackground()
                VStack(spacing: 0) {
                    header
                    SignalField()
                        .frame(height: max(120, full - collapsed - 56))
                        .opacity(app.sheetExpanded ? 0.35 : 1)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                sheet(height: height, full: full, collapsed: collapsed, expanded: expanded)

                TabBar()
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) - 4)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .onAppear {
            app.manager.start()
            let demo = UserDefaults.standard.integer(forKey: "nearbyDemo")
            if demo > 0 {
                app.nearby.showDemo(count: demo, only: UserDefaults.standard.string(forKey: "nearbyDemoOnly"))
                if UserDefaults.standard.bool(forKey: "screenshot") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // chờ WebGL dựng mô hình
                        _ = ScreenCapture.save("nearby")
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.nearby.start(app.manager) } else if phase == .background { app.nearby.stop(app.manager) }
        }
        .task { if scenePhase == .active { app.nearby.start(app.manager) } }
        .sheet(isPresented: Binding(get: { app.nearby.isPresented }, set: { if !$0 { app.nearby.dismissAll(snoozing: true) } })) {
            NearbySheet()
                .environment(app)
                .presentationDetents([.height(530)])
                .presentationCornerRadius(38)
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: Binding(
            get: { app.diagnosticsDevice != nil },
            set: { if !$0 { app.diagnosticsDeviceId = nil } }
        )) {
            if let d = app.diagnosticsDevice {
                DiagnosticsView(device: d).environment(app)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { app.camera.device != nil },
            set: { if !$0 { app.camera.close() } }
        )) {
            RemoteCameraView(camera: app.camera)
        }
        .alert("Đang tìm điện thoại", isPresented: Binding(
            get: { app.findPhone.ringing != nil },
            set: { if !$0 { app.findPhone.stop() } }
        )) {
            Button("Đã tìm thấy") { app.findPhone.stop() }
        } message: {
            Text("\(app.findPhone.ringing ?? "Thiết bị") đang tìm điện thoại này.")
        }
        .alert("Thiết bị vẫn bị iPhone giữ", isPresented: Binding(
            get: { app.forgetNotice != nil },
            set: { if !$0 { app.forgetNotice = nil } }
        )) {
            Button("Mở Cài đặt") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text(app.forgetNotice ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trường tín hiệu").font(.headline)
                Text(bluetoothNote).font(.footnote).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if app.manager.isScanning {
                ProgressView().tint(.white)
            }
            if DemoData.isOn { DemoBadge() }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
    }

    private var bluetoothNote: String {
        if DemoData.isOn { return "số đo thật đã ghi lại · máy ảo không có Bluetooth" }
        switch app.manager.bluetoothState {
        case .poweredOn: return "càng gần tâm, tín hiệu càng mạnh"
        case .poweredOff: return "Bluetooth đang tắt"
        case .unauthorized: return "Chưa cho phép Bluetooth (Cài đặt → SmartWear Lab)"
        case .unsupported: return "Máy không hỗ trợ BLE"
        default: return "đang khởi động Bluetooth…"
        }
    }

    private func sheet(height: CGFloat, full: CGFloat, collapsed: CGFloat, expanded: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Tay nắm: kéo lên/xuống để đổi độ cao sheet.
            Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 5)
                .padding(.top, 8).padding(.bottom, 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($drag) { v, s, _ in s = v.translation.height }
                        .onEnded { v in
                            let projected = (app.sheetExpanded ? expanded : collapsed) - v.predictedEndTranslation.height
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                app.sheetExpanded = projected > (collapsed + expanded) / 2
                            }
                        }
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { app.sheetExpanded.toggle() }
                }

            Group {
                switch app.tab {
                case .devices:
                    if let d = app.selectedDevice {
                        DeviceDetailView(device: d)
                    } else {
                        DevicesTab()
                    }
                case .add: AddTab()
                case .feasibility: FeasibilityTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .glass(UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous))
        .padding(.horizontal, 6)
    }
}

struct TabBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.snappy) {
                            if tab == .devices, app.tab == .devices { app.closeDetail() }
                            app.tab = tab
                            if tab == .add, !app.manager.isScanning { app.manager.startScan() }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold))
                            Text(tab.title).font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(app.tab == tab ? .white : Palette.secondary)
                        .frame(width: 96, height: 52)
                        .background {
                            if app.tab == tab { Capsule().fill(.white.opacity(0.14)) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .glassCapsule(interactive: false)
        }
    }
}
