import Foundation

/// Lightweight lookup tables mirrored from EasyLPAC's MIT-licensed registries.
enum ESTKRegistry {
    static let manufacturers: [ESTKManufacturer] = load("eum-registry")
    static let certificateIssuers: [ESTKCertificateIssuer] = load("ci-registry")

    static func manufacturer(forEID eid: String) -> ESTKManufacturer? {
        manufacturers.first { eid.hasPrefix($0.eum) }
    }

    static func certificateIssuer(forKeyID keyID: String) -> ESTKCertificateIssuer? {
        certificateIssuers.first { keyID.lowercased().hasPrefix($0.keyID.lowercased()) }
    }

    private static func load<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return values
    }
}
