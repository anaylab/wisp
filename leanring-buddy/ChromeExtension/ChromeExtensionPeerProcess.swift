//
//  ChromeExtensionPeerProcess.swift
//  leanring-buddy
//
//  Finds which app opened a loopback connection to the extension bridge, so a
//  connection from Chrome Canary or Arc isn't mistaken for Chrome.
//
//  Why not just trust the extension: it can only report a
//  `navigator.userAgentData` brand, and Chrome's Beta/Dev/Canary channels all
//  say "Google Chrome" while Arc and Vivaldi report no brand of their own. The
//  socket itself is the reliable witness: the bridge knows the peer's port,
//  the kernel knows which process holds the other end, and walking that
//  process's parents reaches the browser app (Chrome's network service runs in
//  a helper process whose parent is the browser).
//
//  Uses libproc for the same reads `lsof` makes, only over descendants of
//  regular apps, which a non-sandboxed app may do for the user's own
//  processes. Runs off the main actor; takes a few milliseconds.
//

import AppKit
import Darwin
import Foundation

nonisolated struct ChromeExtensionPeerApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let applicationName: String?
}

nonisolated enum ChromeExtensionPeerProcess {
    /// The regular app that owns the far end of a loopback TCP connection to
    /// `listeningPort`, or nil when it can't be found.
    static func owningApplication(peerPort: UInt16, listeningPort: UInt16) async -> ChromeExtensionPeerApplication? {
        let regularApplications = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .map { (processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier ?? "", applicationName: $0.localizedName) }
        }
        return await Task.detached(priority: .userInitiated) { () -> ChromeExtensionPeerApplication? in
            let regularApplicationsByProcessIdentifier = Dictionary(
                regularApplications.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let parentProcessIdentifierByProcessIdentifier = allParentProcessIdentifiers()
            let ownProcessIdentifier = getpid()

            // Only descendants of regular apps (and those apps) can be a
            // browser's network process; scanning just them keeps this cheap.
            let candidateProcessIdentifiers = parentProcessIdentifierByProcessIdentifier.keys.filter { processIdentifier in
                processIdentifier != ownProcessIdentifier
                    && owningRegularApplication(
                        of: processIdentifier,
                        parents: parentProcessIdentifierByProcessIdentifier,
                        regularApplicationProcessIdentifiers: Set(regularApplicationsByProcessIdentifier.keys)
                    ) != nil
            }
            for candidateProcessIdentifier in candidateProcessIdentifiers
            where processHoldsTCPSocket(candidateProcessIdentifier, localPort: peerPort, remotePort: listeningPort) {
                guard let applicationProcessIdentifier = owningRegularApplication(
                    of: candidateProcessIdentifier,
                    parents: parentProcessIdentifierByProcessIdentifier,
                    regularApplicationProcessIdentifiers: Set(regularApplicationsByProcessIdentifier.keys)
                ), let application = regularApplicationsByProcessIdentifier[applicationProcessIdentifier] else { continue }
                return ChromeExtensionPeerApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName
                )
            }
            return nil
        }.value
    }

    // MARK: - libproc reads

    private static func allParentProcessIdentifiers() -> [pid_t: pid_t] {
        let processCountEstimate = proc_listallpids(nil, 0)
        guard processCountEstimate > 0 else { return [:] }
        var processIdentifiers = [pid_t](repeating: 0, count: Int(processCountEstimate) + 64)
        let listedCount = proc_listallpids(&processIdentifiers, Int32(processIdentifiers.count * MemoryLayout<pid_t>.size))
        guard listedCount > 0 else { return [:] }

        var parentProcessIdentifierByProcessIdentifier: [pid_t: pid_t] = [:]
        for processIdentifier in processIdentifiers.prefix(Int(listedCount)) where processIdentifier > 0 {
            var processInformation = proc_bsdinfo()
            let readSize = proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &processInformation, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard readSize == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            parentProcessIdentifierByProcessIdentifier[processIdentifier] = pid_t(processInformation.pbi_ppid)
        }
        return parentProcessIdentifierByProcessIdentifier
    }

    /// The nearest ancestor (or the process itself) that is a regular app.
    private static func owningRegularApplication(
        of processIdentifier: pid_t,
        parents: [pid_t: pid_t],
        regularApplicationProcessIdentifiers: Set<pid_t>
    ) -> pid_t? {
        var currentProcessIdentifier = processIdentifier
        // A process tree is shallow; the cap only guards against a cycle in a
        // racy snapshot.
        for _ in 0..<32 {
            if regularApplicationProcessIdentifiers.contains(currentProcessIdentifier) { return currentProcessIdentifier }
            guard let parentProcessIdentifier = parents[currentProcessIdentifier],
                  parentProcessIdentifier > 1,
                  parentProcessIdentifier != currentProcessIdentifier else { return nil }
            currentProcessIdentifier = parentProcessIdentifier
        }
        return nil
    }

    private static func processHoldsTCPSocket(_ processIdentifier: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool {
        let bufferSize = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return false }
        let descriptorCapacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorCapacity)
        let filledSize = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, &fileDescriptors, bufferSize)
        guard filledSize > 0 else { return false }
        let filledDescriptorCount = Int(filledSize) / MemoryLayout<proc_fdinfo>.size

        for fileDescriptor in fileDescriptors.prefix(filledDescriptorCount)
        where fileDescriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInformation = socket_fdinfo()
            let socketReadSize = proc_pidfdinfo(
                processIdentifier,
                fileDescriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socketInformation,
                Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard socketReadSize == Int32(MemoryLayout<socket_fdinfo>.size),
                  socketInformation.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let internetSocket = socketInformation.psi.soi_proto.pri_tcp.tcpsi_ini
            // Ports are stored in network byte order in the low 16 bits.
            let socketLocalPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: internetSocket.insi_lport))
            let socketRemotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: internetSocket.insi_fport))
            if socketLocalPort == localPort && socketRemotePort == remotePort { return true }
        }
        return false
    }
}
