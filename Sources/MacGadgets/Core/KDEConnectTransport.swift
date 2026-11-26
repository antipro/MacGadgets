import Darwin
import Foundation
import Security

// MARK: - TLS Socket Wrapper (BSD Socket + Security.SSLContext)

enum KDEConnectTLSError: Error, LocalizedError {
    case socketFailed(String)
    case connectFailed(String)
    case handshakeFailed(OSStatus)
    case peerCertificateMissing
    case peerCommonNameMismatch(expected: String, actual: String?)
    case peerCertificateUntrusted
    case ioFailed(OSStatus)
    case timeout

    var errorDescription: String? {
        switch self {
        case .socketFailed(let msg): return "Socket error: \(msg)"
        case .connectFailed(let msg): return "Connection failed: \(msg)"
        case .handshakeFailed(let status): return "TLS handshake failed (status \(status))"
        case .peerCertificateMissing: return "Peer did not present a TLS certificate"
        case .peerCommonNameMismatch(let expected, let actual):
            return "Peer certificate CN mismatch (expected \(expected), got \(actual ?? "nil"))"
        case .peerCertificateUntrusted: return "Peer certificate does not match paired device"
        case .ioFailed(let status): return "TLS I/O failed (status \(status))"
        case .timeout: return "Connection timed out"
        }
    }
}

final class KDEConnectTLSSocket {
    private let fd: Int32
    private var sslContext: SSLContext?
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false

    private(set) var peerCertificateDER: Data?

    init(fd: Int32) {
        self.fd = fd
        var noSigPipe: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    func close() {
        closeLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        let ctx = sslContext
        sslContext = nil
        closeLock.unlock()

        if !alreadyClosed {
            if let ctx {
                SSLClose(ctx)
            }
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    var closed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return isClosed
    }

    /// Reads a single `\n`-terminated line in plaintext (used before TLS upgrade).
    func readPlaintextLine(timeoutMs: Int32 = 5000, maxBytes: Int = 65536) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < maxBytes {
            if !waitReadable(timeoutMs: timeoutMs) {
                throw KDEConnectTLSError.timeout
            }
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n == 1 {
                if byte == 0x0A { // '\n'
                    if line.last == 0x0D { line.removeLast() }
                    return line
                }
                line.append(byte)
            } else if n == 0 {
                throw KDEConnectTLSError.socketFailed("EOF before newline")
            } else {
                if errno == EINTR { continue }
                throw KDEConnectTLSError.socketFailed(String(cString: strerror(errno)))
            }
        }
        throw KDEConnectTLSError.socketFailed("Plaintext line exceeded \(maxBytes) bytes")
    }

    func writePlaintext(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.send(fd, base.advanced(by: sent), rawBuf.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw KDEConnectTLSError.socketFailed(String(cString: strerror(errno)))
                }
            }
        }
    }

    /// Upgrades the connected socket to mutual TLS using `SSLContext`.
    func upgradeToTLS(
        side: SSLProtocolSide,
        localIdentity: SecIdentity,
        expectedDeviceId: String?,
        pinnedCertificateDER: Data?
    ) throws {
        guard let ctx = SSLCreateContext(nil, side, .streamType) else {
            throw KDEConnectTLSError.handshakeFailed(errSecAllocate)
        }

        SSLSetIOFuncs(ctx, sslReadCallback, sslWriteCallback)
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetProtocolVersionMax(ctx, .tlsProtocol12)

        let certArray = [localIdentity] as CFArray
        let setCertStatus = SSLSetCertificate(ctx, certArray)
        guard setCertStatus == errSecSuccess else {
            throw KDEConnectTLSError.handshakeFailed(setCertStatus)
        }

        if side == .serverSide {
            SSLSetClientSideAuthenticate(ctx, .alwaysAuthenticate)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        } else {
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        }

        self.sslContext = ctx

        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
            if status == errSSLPeerAuthCompleted {
                try verifyPeerCertificate(
                    ctx: ctx,
                    expectedDeviceId: expectedDeviceId,
                    pinnedCertificateDER: pinnedCertificateDER
                )
            } else if status == errSSLWouldBlock {
                if !waitReadable(timeoutMs: 10_000) {
                    throw KDEConnectTLSError.timeout
                }
            }
        } while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted

        guard status == errSecSuccess else {
            throw KDEConnectTLSError.handshakeFailed(status)
        }

        // Ensure we captured the peer certificate even if breakOn*Auth didn't fire.
        if peerCertificateDER == nil {
            try verifyPeerCertificate(
                ctx: ctx,
                expectedDeviceId: expectedDeviceId,
                pinnedCertificateDER: pinnedCertificateDER
            )
        }
    }

    private func verifyPeerCertificate(
        ctx: SSLContext,
        expectedDeviceId: String?,
        pinnedCertificateDER: Data?
    ) throws {
        var trust: SecTrust?
        let status = SSLCopyPeerTrust(ctx, &trust)
        guard status == errSecSuccess, let trust else {
            throw KDEConnectTLSError.peerCertificateMissing
        }

        let leafCert: SecCertificate?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first {
            leafCert = first
        } else {
            leafCert = SecTrustGetCertificateAtIndex(trust, 0)
        }

        guard let cert = leafCert else {
            throw KDEConnectTLSError.peerCertificateMissing
        }

        let certDER = SecCertificateCopyData(cert) as Data
        if let expectedDeviceId {
            let cn = KDEConnectCrypto.extractCommonName(from: cert)
            if cn != expectedDeviceId {
                throw KDEConnectTLSError.peerCommonNameMismatch(expected: expectedDeviceId, actual: cn)
            }
        }
        if let pinnedCertificateDER, certDER != pinnedCertificateDER {
            throw KDEConnectTLSError.peerCertificateUntrusted
        }
        self.peerCertificateDER = certDER
    }

    func readTLS(maxLength: Int = 16384) throws -> Data {
        guard let ctx = sslContext else {
            throw KDEConnectTLSError.ioFailed(errSecBadReq)
        }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            var buffered = 0
            SSLGetBufferedReadSize(ctx, &buffered)
            if buffered == 0 {
                if !waitReadable(timeoutMs: -1) {
                    return Data()
                }
            }
            var processed = 0
            let status = SSLRead(ctx, &buffer, maxLength, &processed)
            if processed > 0 {
                return Data(buffer[0..<processed])
            }
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                return Data()
            }
            if status == errSSLWouldBlock {
                continue
            }
            throw KDEConnectTLSError.ioFailed(status)
        }
    }

    func writeTLS(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let ctx = sslContext else {
            throw KDEConnectTLSError.ioFailed(errSecBadReq)
        }
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < rawBuf.count {
                var processed = 0
                let status = SSLWrite(ctx, base.advanced(by: offset), rawBuf.count - offset, &processed)
                offset += processed
                if status == errSecSuccess || status == errSSLWouldBlock {
                    continue
                }
                throw KDEConnectTLSError.ioFailed(status)
            }
        }
    }

    // MARK: - Low-level Socket I/O for SSLContext

    private func waitReadable(timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let rc = Darwin.poll(&pfd, 1, timeoutMs)
            if rc > 0 { return true }
            if rc < 0 && errno == EINTR { continue }
            return false
        }
    }

    fileprivate func sslRead(into buffer: UnsafeMutableRawPointer, length: UnsafeMutablePointer<Int>) -> OSStatus {
        let requested = length.pointee
        var totalRead = 0

        while totalRead < requested {
            let n = Darwin.recv(fd, buffer.advanced(by: totalRead), requested - totalRead, MSG_DONTWAIT)
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                length.pointee = totalRead
                return totalRead > 0 ? errSSLWouldBlock : errSSLClosedGraceful
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    length.pointee = totalRead
                    return errSSLWouldBlock
                }
                length.pointee = totalRead
                return errSSLClosedAbort
            }
        }
        length.pointee = totalRead
        return errSecSuccess
    }

    fileprivate func sslWrite(from buffer: UnsafeRawPointer, length: UnsafeMutablePointer<Int>) -> OSStatus {
        let requested = length.pointee
        var totalWritten = 0

        while totalWritten < requested {
            let n = Darwin.send(fd, buffer.advanced(by: totalWritten), requested - totalWritten, 0)
            if n > 0 {
                totalWritten += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                length.pointee = totalWritten
                return errSSLClosedAbort
            }
        }
        length.pointee = totalWritten
        return errSecSuccess
    }
}

private func sslReadCallback(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let socket = Unmanaged<KDEConnectTLSSocket>.fromOpaque(connection).takeUnretainedValue()
    return socket.sslRead(into: data, length: dataLength)
}

private func sslWriteCallback(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let socket = Unmanaged<KDEConnectTLSSocket>.fromOpaque(connection).takeUnretainedValue()
    return socket.sslWrite(from: data, length: dataLength)
}

// MARK: - Device Link

final class KDEConnectLink {
    let deviceId: String
    let deviceName: String
    let deviceType: String
    let peerIP: String
    let peerCertificateDER: Data
    let fingerprintHex: String

    private let socket: KDEConnectTLSSocket
    private let readQueue: DispatchQueue
    var onPacket: ((KDEConnectPacket) -> Void)?
    var onDisconnect: (() -> Void)?

    init(
        deviceId: String,
        deviceName: String,
        deviceType: String,
        peerIP: String,
        peerCertificateDER: Data,
        socket: KDEConnectTLSSocket
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.peerIP = peerIP
        self.peerCertificateDER = peerCertificateDER
        self.fingerprintHex = KDEConnectCrypto.sha256Hex(of: peerCertificateDER)
        self.socket = socket
        self.readQueue = DispatchQueue(label: "com.macgadgets.kdeconnect.link.\(deviceId)")
    }

    func startReading() {
        readQueue.async { [weak self] in
            guard let self else { return }
            var lineBuffer = KDEConnectLineBuffer()
            while !self.socket.closed {
                do {
                    let chunk = try self.socket.readTLS()
                    if chunk.isEmpty {
                        break
                    }
                    let lines = lineBuffer.append(chunk)
                    for line in lines {
                        if let packet = try? KDEConnectPacket.decode(fromLineData: line) {
                            self.onPacket?(packet)
                        }
                    }
                } catch {
                    break
                }
            }
            self.socket.close()
            self.onDisconnect?()
        }
    }

    func send(_ packet: KDEConnectPacket) throws {
        let data = try packet.encode()
        try socket.writeTLS(data)
    }

    func close() {
        socket.close()
    }
}

// MARK: - LAN Transport (UDP Discovery + TCP/TLS Control + File Payload Transfer)

protocol KDEConnectTransportDelegate: AnyObject {
    func transport(_ transport: KDEConnectTransport, didConnect link: KDEConnectLink)
    func transport(_ transport: KDEConnectTransport, didDisconnect deviceId: String)
    func transport(_ transport: KDEConnectTransport, didReceivePacket packet: KDEConnectPacket, from link: KDEConnectLink)
}

final class KDEConnectTransport {
    weak var delegate: KDEConnectTransportDelegate?

    let localIdentity: KDEConnectLocalIdentity
    let identityStore: KDEConnectIdentityStore
    var localDeviceName: String

    private let stateQueue = DispatchQueue(label: "com.macgadgets.kdeconnect.transport.state")
    private let ioQueue = DispatchQueue(label: "com.macgadgets.kdeconnect.transport.io", attributes: .concurrent)

    private var udpFD: Int32 = -1
    private var tcpServerFD: Int32 = -1
    private var tcpPort: UInt16 = KDEConnectConstants.defaultPort
    private var isRunning = false

    private var links: [String: KDEConnectLink] = [:]
    private var connectingDeviceIds: Set<String> = []

    init(
        localIdentity: KDEConnectLocalIdentity,
        identityStore: KDEConnectIdentityStore,
        localDeviceName: String
    ) {
        self.localIdentity = localIdentity
        self.identityStore = identityStore
        self.localDeviceName = localDeviceName
    }

    deinit {
        stop()
    }

    func start() throws {
        var shouldStart = false
        stateQueue.sync {
            if !isRunning {
                isRunning = true
                shouldStart = true
            }
        }
        guard shouldStart else { return }

        do {
            let (serverFD, boundTCPPort) = try Self.bindTCPListener(in: KDEConnectConstants.defaultPort...KDEConnectConstants.udpPortRange.upperBound)
            self.tcpServerFD = serverFD
            self.tcpPort = boundTCPPort

            let udpSocketFD = try Self.bindUDPListener(in: KDEConnectConstants.defaultPort...KDEConnectConstants.udpPortRange.upperBound)
            self.udpFD = udpSocketFD

            startTCPAcceptLoop(serverFD: serverFD)
            startUDPDiscoveryLoop(udpFD: udpSocketFD)
            broadcastIdentity()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        var linksToClose: [KDEConnectLink] = []
        var udpToClose: Int32 = -1
        var tcpToClose: Int32 = -1

        stateQueue.sync {
            guard isRunning else { return }
            isRunning = false
            linksToClose = Array(links.values)
            links.removeAll()
            connectingDeviceIds.removeAll()
            udpToClose = udpFD
            udpFD = -1
            tcpToClose = tcpServerFD
            tcpServerFD = -1
        }

        if udpToClose >= 0 {
            Darwin.shutdown(udpToClose, SHUT_RDWR)
            Darwin.close(udpToClose)
        }
        if tcpToClose >= 0 {
            Darwin.shutdown(tcpToClose, SHUT_RDWR)
            Darwin.close(tcpToClose)
        }
        linksToClose.forEach { $0.close() }
    }

    func activeLink(for deviceId: String) -> KDEConnectLink? {
        stateQueue.sync { links[deviceId] }
    }

    func broadcastIdentity(toSpecificIP targetIP: String? = nil) {
        let packet = KDEConnectPacket.identity(
            deviceId: localIdentity.deviceId,
            deviceName: localDeviceName,
            tcpPort: tcpPort
        )
        guard let data = try? packet.encode() else { return }

        ioQueue.async { [weak self] in
            guard self != nil else { return }
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }

            var broadcast: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

            let targets: [String]
            if let targetIP {
                targets = [targetIP]
            } else {
                var list = Self.interfaceBroadcastAddresses()
                if !list.contains("255.255.255.255") {
                    list.append("255.255.255.255")
                }
                targets = list
            }

            for ip in targets {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = KDEConnectConstants.defaultPort.bigEndian
                if Darwin.inet_pton(AF_INET, ip, &addr.sin_addr) == 1 {
                    data.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        withUnsafePointer(to: &addr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                _ = Darwin.sendto(fd, base, rawBuf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - UDP Discovery Loop

    private func startUDPDiscoveryLoop(udpFD: Int32) {
        ioQueue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            while let self, self.isRunningFlag() {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.recvfrom(udpFD, &buffer, buffer.count, 0, saPtr, &srcLen)
                    }
                }
                if n <= 0 {
                    if errno == EINTR { continue }
                    break
                }

                let data = Data(buffer[0..<n])
                let peerIP = Self.ipString(from: srcAddr.sin_addr)
                self.handleUDPPacket(data, fromIP: peerIP)
            }
        }
    }

    private func handleUDPPacket(_ data: Data, fromIP peerIP: String) {
        let trimmed = data.last == 0x0A ? data.dropLast() : data[...]
        guard let packet = try? KDEConnectPacket.decode(fromLineData: Data(trimmed)),
              packet.type == KDEConnectPacketType.identity,
              let deviceId = packet.deviceId,
              deviceId != localIdentity.deviceId,
              let peerTCPPort = packet.tcpPort else {
            return
        }

        let shouldConnect: Bool = stateQueue.sync {
            guard isRunning else { return false }
            if links[deviceId] != nil || connectingDeviceIds.contains(deviceId) {
                return false
            }
            connectingDeviceIds.insert(deviceId)
            return true
        }
        guard shouldConnect else { return }

        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.sync {
                    _ = self.connectingDeviceIds.remove(deviceId)
                }
            }
            self.connectOutgoing(
                deviceId: deviceId,
                deviceName: packet.deviceName ?? "Android Device",
                deviceType: packet.deviceType ?? "phone",
                peerIP: peerIP,
                port: peerTCPPort
            )
        }
    }

    private func connectOutgoing(
        deviceId: String,
        deviceName: String,
        deviceType: String,
        peerIP: String,
        port: UInt16
    ) {
        do {
            let fd = try Self.connectTCP(host: peerIP, port: port, timeoutSeconds: 5)
            let tlsSocket = KDEConnectTLSSocket(fd: fd)
            do {
                let idPacket = KDEConnectPacket.identity(
                    deviceId: localIdentity.deviceId,
                    deviceName: localDeviceName,
                    tcpPort: tcpPort
                )
                try tlsSocket.writePlaintext(try idPacket.encode())

                // KDE Connect TCP client acts as TLS Server.
                let trusted = identityStore.trustedDevice(for: deviceId)
                try tlsSocket.upgradeToTLS(
                    side: .serverSide,
                    localIdentity: localIdentity.identity,
                    expectedDeviceId: deviceId,
                    pinnedCertificateDER: trusted?.certificateDER
                )

                guard let peerCertDER = tlsSocket.peerCertificateDER else {
                    tlsSocket.close()
                    return
                }
                registerLink(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    deviceType: deviceType,
                    peerIP: peerIP,
                    peerCertDER: peerCertDER,
                    socket: tlsSocket
                )
            } catch {
                tlsSocket.close()
            }
        } catch {
            // Peer unreachable or refused
        }
    }

    // MARK: - TCP Accept Loop

    private func startTCPAcceptLoop(serverFD: Int32) {
        ioQueue.async { [weak self] in
            while let self, self.isRunningFlag() {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.accept(serverFD, saPtr, &addrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }

                let peerIP = Self.ipString(from: clientAddr.sin_addr)
                self.ioQueue.async {
                    self.handleIncomingTCP(clientFD: clientFD, peerIP: peerIP)
                }
            }
        }
    }

    private func handleIncomingTCP(clientFD: Int32, peerIP: String) {
        let tlsSocket = KDEConnectTLSSocket(fd: clientFD)
        do {
            let line = try tlsSocket.readPlaintextLine(timeoutMs: 5000)
            let idPacket = try KDEConnectPacket.decode(fromLineData: line)
            guard idPacket.type == KDEConnectPacketType.identity,
                  let deviceId = idPacket.deviceId,
                  deviceId != localIdentity.deviceId,
                  (idPacket.protocolVersion ?? 0) >= KDEConnectConstants.protocolVersion else {
                tlsSocket.close()
                return
            }

            // KDE Connect TCP server acts as TLS Client.
            let trusted = identityStore.trustedDevice(for: deviceId)
            try tlsSocket.upgradeToTLS(
                side: .clientSide,
                localIdentity: localIdentity.identity,
                expectedDeviceId: deviceId,
                pinnedCertificateDER: trusted?.certificateDER
            )

            guard let peerCertDER = tlsSocket.peerCertificateDER else {
                tlsSocket.close()
                return
            }

            registerLink(
                deviceId: deviceId,
                deviceName: idPacket.deviceName ?? "Android Device",
                deviceType: idPacket.deviceType ?? "phone",
                peerIP: peerIP,
                peerCertDER: peerCertDER,
                socket: tlsSocket
            )
        } catch {
            tlsSocket.close()
        }
    }

    private func registerLink(
        deviceId: String,
        deviceName: String,
        deviceType: String,
        peerIP: String,
        peerCertDER: Data,
        socket: KDEConnectTLSSocket
    ) {
        let link = KDEConnectLink(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: deviceType,
            peerIP: peerIP,
            peerCertificateDER: peerCertDER,
            socket: socket
        )

        link.onPacket = { [weak self, weak link] packet in
            guard let self, let link else { return }
            self.delegate?.transport(self, didReceivePacket: packet, from: link)
        }
        link.onDisconnect = { [weak self, weak link] in
            guard let self, let link else { return }
            var removed = false
            self.stateQueue.sync {
                if self.links[deviceId] === link {
                    self.links.removeValue(forKey: deviceId)
                    removed = true
                }
            }
            if removed {
                self.delegate?.transport(self, didDisconnect: deviceId)
            }
        }

        let previousLink: KDEConnectLink? = stateQueue.sync {
            guard isRunning else { return nil }
            let prev = links[deviceId]
            links[deviceId] = link
            return prev
        }

        guard isRunningFlag() else {
            link.close()
            return
        }

        previousLink?.onDisconnect = nil
        previousLink?.close()

        delegate?.transport(self, didConnect: link)
        link.startReading()
    }

    private func isRunningFlag() -> Bool {
        stateQueue.sync { isRunning }
    }

    // MARK: - File Payload Transfer

    func sendFile(
        to link: KDEConnectLink,
        fileURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let (listenerFD, port) = try Self.bindTCPListener(in: KDEConnectConstants.transferPortRange)
        defer {
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }

        let sharePacket = KDEConnectPacket.shareFile(
            filename: fileURL.lastPathComponent,
            size: fileSize,
            port: port
        )
        try link.send(sharePacket)

        var pfd = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        let pollRC = Darwin.poll(&pfd, 1, 30_000)
        guard pollRC > 0 else {
            throw KDEConnectTLSError.timeout
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.accept(listenerFD, saPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else {
            throw KDEConnectTLSError.socketFailed("accept failed")
        }

        let tlsSocket = KDEConnectTLSSocket(fd: clientFD)
        defer { tlsSocket.close() }

        try tlsSocket.upgradeToTLS(
            side: .serverSide,
            localIdentity: localIdentity.identity,
            expectedDeviceId: link.deviceId,
            pinnedCertificateDER: link.peerCertificateDER
        )

        var totalSent: Int64 = 0
        let chunkSize = 65_536
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try tlsSocket.writeTLS(chunk)
            totalSent += Int64(chunk.count)
            progress(totalSent, fileSize)
        }
    }

    func receiveFile(
        from link: KDEConnectLink,
        port: UInt16,
        expectedSize: Int64?,
        destinationURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) throws {
        let fd = try Self.connectTCP(host: link.peerIP, port: port, timeoutSeconds: 10)
        let tlsSocket = KDEConnectTLSSocket(fd: fd)
        defer { tlsSocket.close() }

        try tlsSocket.upgradeToTLS(
            side: .clientSide,
            localIdentity: localIdentity.identity,
            expectedDeviceId: link.deviceId,
            pinnedCertificateDER: link.peerCertificateDER
        )

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        let targetTotal = expectedSize ?? 0
        while true {
            if let expectedSize, expectedSize >= 0, received >= expectedSize {
                break
            }
            let chunk = try tlsSocket.readTLS(maxLength: 65_536)
            if chunk.isEmpty {
                break
            }
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)
            progress(received, targetTotal)
        }
    }

    // MARK: - POSIX Socket Helpers

    private static func bindTCPListener(in range: ClosedRange<UInt16>) throws -> (Int32, UInt16) {
        for port in range {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var reuse: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 && Darwin.listen(fd, 16) == 0 {
                return (fd, port)
            }
            Darwin.close(fd)
        }
        throw KDEConnectTLSError.socketFailed("Unable to bind TCP port in \(range)")
    }

    private static func bindUDPListener(in range: ClosedRange<UInt16>) throws -> Int32 {
        for port in range {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }

            var reuse: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 {
                return fd
            }
            Darwin.close(fd)
        }
        throw KDEConnectTLSError.socketFailed("Unable to bind UDP discovery port in \(range)")
    }

    private static func connectTCP(host: String, port: UInt16, timeoutSeconds: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw KDEConnectTLSError.socketFailed(String(cString: strerror(errno)))
        }

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard Darwin.inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw KDEConnectTLSError.connectFailed("Invalid IP address \(host)")
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if rc != 0 && errno != EINPROGRESS {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw KDEConnectTLSError.connectFailed(err)
        }

        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollRC = Darwin.poll(&pfd, 1, Int32(timeoutSeconds * 1000))
            if pollRC <= 0 {
                Darwin.close(fd)
                throw KDEConnectTLSError.timeout
            }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
            if soError != 0 {
                Darwin.close(fd)
                throw KDEConnectTLSError.connectFailed(String(cString: strerror(soError)))
            }
        }

        _ = Darwin.fcntl(fd, F_SETFL, flags)
        return fd
    }

    private static func ipString(from addr: in_addr) -> String {
        var mutableAddr = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return Darwin.inet_ntop(AF_INET, &mutableAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            .map { String(cString: $0) } ?? "0.0.0.0"
    }

    private static func interfaceBroadcastAddresses() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard Darwin.getifaddrs(&addrs) == 0, let first = addrs else {
            return []
        }
        defer { Darwin.freeifaddrs(first) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               (flags & IFF_BROADCAST) != 0,
               let dst = current.pointee.ifa_dstaddr,
               dst.pointee.sa_family == sa_family_t(AF_INET) {
                let sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ip = ipString(from: sin.sin_addr)
                if !result.contains(ip) {
                    result.append(ip)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return result
    }
}
