import SwiftUI
import AppKit

struct PrintViewport: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.printer
        if p.connection != .connected && p.lastReport == nil {
            PrinterSetupForm()
                .frame(maxWidth: 520)
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            JobView()
        }
    }
}

struct JobView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = app.printer.status
        let asset = app.library.assets.first { $0.fileStem == s.jobName }
        let active = s.isPrinting || s.isPaused
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 22) {
                Group {
                    if let a = asset, let img = NSImage(contentsOf: a.has(a.plateImageURL) ? a.plateImageURL : a.thumbURL) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: active ? "cube.fill" : "printer").font(.system(size: 72)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 340, height: 340)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(active ? "\(s.percent)%" : s.stateLabel).font(.system(size: 44, weight: .semibold, design: .monospaced))
                        Spacer()
                        if active { Text("\(formatDuration(Double(s.remainingMinutes) * 60)) left").font(.title3.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if active { ProgressView(value: Double(s.percent), total: 100).tint(Theme.accent) }
                    HStack {
                        if active { Text("Layer \(s.layer) of \(s.totalLayers)").monospacedDigit() }
                        else { Text(s.jobName.isEmpty ? "No job" : "Last job: \(asset?.shortTitle ?? s.jobName)") }
                        Spacer()
                        if let now = s.trayNow, let t = s.trays.first(where: { $0.id == now }), active {
                            Text("Printing with \(t.label) · \(t.type)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    if s.hmsCount > 0 || s.printError != 0 {
                        Label("The printer reports \(s.hmsCount) health message\(s.hmsCount == 1 ? "" : "s"). Check its screen.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                    if s.sdcard == false {
                        Label("No storage detected. LAN printing needs an SD card for the uploaded file.", systemImage: "sdcard")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .frame(width: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Image(systemName: "video")
                Text("Chamber camera")
                Button("Watch") { app.openCamera() }.buttonStyle(.glass)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            .padding(16)
        }
    }
}

struct PrintInspector: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.printer
        let s = p.status
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bambu Lab P2S").font(.headline)
                                Text(connectionText).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.isPaused {
                                Button { p.resume() } label: { Image(systemName: "play.fill") }.buttonStyle(.glass).help("Resume")
                            } else {
                                Button { p.pause() } label: { Image(systemName: "pause.fill") }.buttonStyle(.glass).help("Pause")
                                    .disabled(!s.isPrinting)
                            }
                            Button { app.confirmStopPrint = true } label: { Image(systemName: "stop.fill") }
                                .buttonStyle(.glass).tint(Theme.destructive).help("Stop print")
                                .disabled(!(s.isPrinting || s.isPaused))
                        }
                        Picker("Speed", selection: Binding(get: { s.speedLevel }, set: { p.setSpeed($0) })) {
                            Text("Silent").tag(1); Text("Standard").tag(2); Text("Sport").tag(3); Text("Ludicrous").tag(4)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(!s.isPrinting)
                    }
                    .padding(16)

                    if p.connection == .connected {
                        InspectorSection(title: "Temperatures") {
                            tempRow("flame", "Nozzle", s.nozzleTemp, s.nozzleTarget, presets: [0, 200, 210, 220, 230, 250, 270]) { p.setNozzle($0) }
                            tempRow("square.grid.3x3.bottomhalf.filled", "Bed", s.bedTemp, s.bedTarget, presets: [0, 35, 55, 60, 70, 90, 100]) { p.setBed($0) }
                            if let c = s.chamberTemp {
                                HStack {
                                    Image(systemName: "cube").foregroundStyle(.secondary).frame(width: 22)
                                    Text("Chamber")
                                    Spacer()
                                    Text("\(Int(c))°").font(.title3.monospacedDigit())
                                }
                            }
                        }

                        InspectorSection(title: "Chamber light", trailing: AnyView(
                            Toggle("", isOn: Binding(get: { s.chamberLight }, set: { p.setLight($0) })).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                        )) {
                            fanRow("Part fan", s.partFan, fan: 1)
                            fanRow("Aux fan", s.auxFan, fan: 2)
                            fanRow("Chamber fan", s.chamberFan, fan: 3)
                            HStack {
                                Button("Home axes") { p.home() }.disabled(s.isPrinting)
                                Button("Refresh") { p.pushAll() }
                            }
                            .buttonStyle(.glass)
                        }

                        if !s.trays.filter({ !$0.isExternal }).isEmpty {
                            InspectorSection(title: "AMS") {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                    ForEach(s.trays.filter { !$0.isExternal }) { t in
                                        let inUse = t.id == s.trayNow && (s.isPrinting || s.isPaused)
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack { Swatch(hex: t.colorHex, size: 18); Text("Slot \(t.slotId + 1)").fontWeight(.semibold) }
                                            Text("\(t.type)\(t.remain.map { $0 >= 0 ? " · \($0)%" : "" } ?? "")").foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(inUse ? Theme.accent.opacity(0.07) : Theme.cell))
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(inUse ? Theme.accent : .white.opacity(0.07)))
                                    }
                                }
                            }
                        }
                    } else {
                        InspectorSection(title: "Connection") {
                            PrinterSetupForm(compact: true)
                        }
                    }
                }
            }
            InspectorSection {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(p.log.suffix(3).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var connectionText: String {
        switch app.printer.connection {
        case .connected: app.printer.status.isPrinting ? "Printing over LAN" : "Connected over LAN"
        case .connecting: "Connecting"
        case .disconnected: "Not connected"
        case .failed(let why): why
        }
    }

    private func tempRow(_ icon: String, _ name: String, _ current: Double, _ target: Double, presets: [Int], set: @escaping (Int) -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(name)
            Spacer()
            Text("\(Int(current))°").font(.title3.monospacedDigit())
            Menu {
                ForEach(presets, id: \.self) { t in Button(t == 0 ? "Off" : "\(t)°") { set(t) } }
            } label: {
                Text(target > 0 ? "\(Int(target))°" : "Off").monospacedDigit()
            }
            .menuStyle(.button).buttonStyle(.glass).fixedSize()
        }
    }

    private func fanRow(_ name: String, _ value: Int, fan: Int) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach([0, 25, 50, 75, 100], id: \.self) { v in Button("\(v)%") { app.printer.setFan(fan, percent: v) } }
            } label: { Text("\(value)%").monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// IP / serial / access code entry with network discovery. Used in the Print stage and in Settings.
struct PrinterSetupForm: View {
    @Environment(AppModel.self) private var app
    var compact = false
    @AppStorage(SettingKey.printerIP) private var ip = ""
    @AppStorage(SettingKey.printerSerial) private var serial = ""
    @State private var code = ""

    var body: some View {
        let p = app.printer
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text("Connect your Bambu Lab P2S").font(.title2.weight(.semibold))
                Text("On the printer, open Settings, turn on LAN Only Mode and then Developer Mode. The access code is on the same screen; the serial number is under device info.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("IP address", text: $ip, prompt: Text("192.168.0.50"))
                TextField("Serial number", text: $serial, prompt: Text("22E8…"))
                SecureField("Access code", text: $code, prompt: Text("8 characters"))
            }
            .formStyle(.columns)
            HStack {
                Button {
                    if !code.isEmpty { p.accessCode = code.trimmingCharacters(in: .whitespaces) }
                    p.connect()
                } label: { Label("Connect", systemImage: "link") }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                .disabled(ip.isEmpty || serial.isEmpty || (code.isEmpty && p.accessCode.isEmpty))
                Button {
                    app.discovery.scan()
                } label: { Label(app.discovery.scanning ? "Searching…" : "Find on network", systemImage: "dot.radiowaves.left.and.right") }
                .buttonStyle(.glass)
                .disabled(app.discovery.scanning)
                if p.connection == .connecting { ProgressView().controlSize(.small) }
            }
            ForEach(app.discovery.found) { d in
                Button { ip = d.ip; serial = d.serial } label: {
                    Label("Use \(d.name) at \(d.ip)", systemImage: "printer")
                }
                .buttonStyle(.link)
            }
            if !app.discovery.scanning && app.discovery.found.isEmpty && app.discovery.didScanOnce {
                Text("No printer answered. Check that it is switched on and on the same Wi-Fi network as this Mac.").foregroundStyle(.secondary).font(.callout)
            }
            if case .failed(let why) = p.connection {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { code = p.accessCode }
    }
}
