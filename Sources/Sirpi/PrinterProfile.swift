import Foundation

/// Build volumes of the Bambu Lab printers Sirpi can target. Used to size print-mode generations,
/// draw the plate in Prepare and keep print assets inside the volume.
struct PrinterProfile: Identifiable, Hashable {
    let id: String          // model name, as shown
    let x: Double, y: Double, z: Double
    var note: String = ""

    static let all: [PrinterProfile] = [
        .init(id: "P2S", x: 256, y: 256, z: 256),
        .init(id: "P1S", x: 256, y: 256, z: 256),
        .init(id: "P1P", x: 256, y: 256, z: 256),
        .init(id: "X1 Carbon", x: 256, y: 256, z: 256),
        .init(id: "X1E", x: 256, y: 256, z: 256),
        .init(id: "A1", x: 256, y: 256, z: 256),
        .init(id: "A1 mini", x: 180, y: 180, z: 180),
        .init(id: "H2D", x: 325, y: 320, z: 325, note: "single-nozzle volume"),
    ]

    static let key = "printerModel"
    static var current: PrinterProfile {
        let id = UserDefaults.standard.string(forKey: key) ?? "P2S"
        return all.first { $0.id == id } ?? all[0]
    }

    var volumeText: String { "\(Int(x)) × \(Int(y)) × \(Int(z)) mm" }
}
