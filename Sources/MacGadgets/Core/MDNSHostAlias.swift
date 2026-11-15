import Foundation
import CUSBBridge

/// Publishes a `<label>.local` mDNS A record pointing at loopback so that macOS Finder
/// lists the NFS mount as a named server under "Locations" (like `OrbStack` does)
/// instead of showing a bare `localhost` entry.
final class MDNSHostAlias {
    private var handle: CMDNSHandle?
    let label: String

    var hostName: String { "\(label).local" }

    init(label rawLabel: String) throws {
        let baseLabel = Self.sanitize(rawLabel)
        guard !baseLabel.isEmpty else { throw MDNSHostAliasError.invalidLabel }

        // mDNS name conflicts (another phone with the same model) are resolved by suffixing.
        var candidates: [String] = [baseLabel]
        for idx in 2...5 { candidates.append("\(baseLabel)-\(idx)") }

        var lastError: Int32 = 0
        for candidate in candidates {
            var err: Int32 = 0
            let loopback = UInt32(0x7F000001).bigEndian
            let created = candidate.withCString { cLabel in
                cmdns_register_host(cLabel, loopback, &err)
            }
            if let created, err == 0 {
                self.label = candidate
                self.handle = created
                return
            }
            lastError = err
            if err != -65548 { break } // only retry on kDNSServiceErr_NameConflict
        }
        throw MDNSHostAliasError.registrationFailed(lastError)
    }

    deinit {
        stop()
    }

    func stop() {
        if let handle {
            cmdns_unregister(handle)
            self.handle = nil
        }
    }

    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        var out = ""
        var lastWasDash = false
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) && scalar != "-" {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 50 { out = String(out.prefix(50)) }
        if out.first?.isNumber == true { out = "android-\(out)" }
        return out
    }
}

enum MDNSHostAliasError: Error, LocalizedError {
    case invalidLabel
    case registrationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "无法为设备生成有效的本地主机名"
        case .registrationFailed(let code):
            return "注册本地主机名失败 (mDNS 错误 \(code))"
        }
    }
}
