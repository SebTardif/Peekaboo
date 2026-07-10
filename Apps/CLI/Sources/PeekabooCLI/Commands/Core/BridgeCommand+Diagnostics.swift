import Foundation
import PeekabooAutomation
import PeekabooBridge
import Security

struct BridgeDiagnostics {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    @MainActor
    func run(runtimeOptions: CommandRuntimeOptions) async -> BridgeStatusReport {
        let environment = ProcessInfo.processInfo.environment
        let effectiveOptions = runtimeOptions.applyingEnvironmentOverrides(environment: environment)
        let configurationInput = PeekabooAutomation.ConfigurationManager.shared.getConfiguration()?.input
        let remoteSkipReason = Self.remoteSkipReason(
            runtimeOptions: effectiveOptions,
            environment: environment,
            configurationInput: configurationInput
        )

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: Self.currentTeamIdentifier(),
            processIdentifier: getpid(),
            hostname: Host.current().name
        )

        if let remoteSkipReason {
            let candidates = Self.diagnosticSocketPaths(
                runtimeOptions: effectiveOptions,
                environment: environment
            )
            self.logger.debug("Bridge status: remote skipped (\(remoteSkipReason))")
            return BridgeStatusReport(
                remoteSkipped: true,
                remoteSkipReason: remoteSkipReason,
                selected: .local(),
                candidates: candidates.map { BridgeCandidateReport(socketPath: $0, result: .skipped) },
                client: .init(identity: identity)
            )
        }

        let candidatePlan = await RuntimeHostResolver.remoteCandidatePlan(
            options: effectiveOptions,
            environment: environment
        )
        let runtimeCandidates = candidatePlan.candidates
        let candidates = Self.diagnosticSocketPaths(
            runtimeCandidateSocketPaths: runtimeCandidates.map(\.socketPath),
            hasExplicitSocket: candidatePlan.explicitSocket != nil
        )
        var runtimeCandidateByPath: [String: RuntimeHostResolver.ImplicitRemoteCandidate] = [:]
        for candidate in runtimeCandidates {
            let path = NSString(string: candidate.socketPath).standardizingPath
            if runtimeCandidateByPath[path] == nil {
                runtimeCandidateByPath[path] = candidate
            }
        }

        var results: [BridgeCandidateReport] = []
        var selected: BridgeSelectionReport?

        for socketPath in candidates {
            let client = PeekabooBridgeClient(socketPath: socketPath)
            do {
                let handshake = try await client.handshake(client: identity, requestedHost: nil)
                let report = BridgeHandshakeReport(from: handshake)
                self.logger.debug(
                    "Bridge status: handshake OK \(handshake.hostKind.rawValue) via \(socketPath)",
                    category: "Bridge"
                )
                results.append(.init(socketPath: socketPath, result: .success(report)))

                let candidatePath = NSString(string: socketPath).standardizingPath
                if selected == nil,
                   let runtimeCandidate = runtimeCandidateByPath[candidatePath] {
                    let validation = await RuntimeHostResolver.validateRemoteCandidate(
                        runtimeCandidate,
                        handshake: handshake,
                        options: effectiveOptions
                    )
                    if validation != nil {
                        selected = .remote(socketPath: socketPath, handshake: report)
                    }
                }
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                self.logger.debug(
                    "Bridge status: handshake error \(envelope.code.rawValue) via \(socketPath): \(envelope.message)",
                    category: "Bridge"
                )
                results.append(.init(socketPath: socketPath, result: .failure(.bridgeEnvelope(envelope))))
            } catch {
                self.logger.debug(
                    "Bridge status: handshake error via \(socketPath): \(String(describing: error))",
                    category: "Bridge"
                )
                results.append(.init(socketPath: socketPath, result: .failure(.other(error))))
            }
        }

        return BridgeStatusReport(
            remoteSkipped: false,
            remoteSkipReason: nil,
            selected: selected ?? .local(),
            candidates: results,
            client: .init(identity: identity)
        )
    }

    static func remoteSkipReason(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?
    ) -> String? {
        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: runtimeOptions,
            environment: environment,
            configurationInput: configurationInput,
            knownSnapshotInvalidationRemoteSocketPaths: []
        )
        guard case .local = decision else { return nil }

        if environment["PEEKABOO_NO_REMOTE"] != nil {
            return "PEEKABOO_NO_REMOTE"
        }
        if runtimeOptions.remoteIsolationRequested {
            return "--no-remote"
        }
        if RuntimeHostResolver.inputPolicyRequiresLocal(
            options: runtimeOptions,
            environment: environment,
            configurationInput: configurationInput
        ) {
            return "input strategy policy"
        }
        return "local runtime policy"
    }

    static func runtimeCandidateSocketPaths(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [String] {
        if let explicitPath = BridgeSocketResolver.explicitBridgeSocket(
            options: runtimeOptions,
            environment: environment
        ) {
            return [explicitPath]
        }

        let daemonPath = DaemonLaunchPolicy.daemonSocketPath(environment: environment)
        let buildScopedPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: daemonPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        )
        return RuntimeHostResolver.implicitRemoteCandidates(
            options: runtimeOptions,
            daemonSocketPath: daemonPath,
            buildScopedDaemonSocketPath: buildScopedPath,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        ).map(\.socketPath)
    }

    static func diagnosticSocketPaths(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [String] {
        let runtimePaths = self.runtimeCandidateSocketPaths(
            runtimeOptions: runtimeOptions,
            environment: environment,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        )
        return self.diagnosticSocketPaths(
            runtimeCandidateSocketPaths: runtimePaths,
            hasExplicitSocket: BridgeSocketResolver.explicitBridgeSocket(
                options: runtimeOptions,
                environment: environment
            ) != nil
        )
    }

    private static func diagnosticSocketPaths(
        runtimeCandidateSocketPaths runtimePaths: [String],
        hasExplicitSocket: Bool
    ) -> [String] {
        if hasExplicitSocket {
            return runtimePaths
        }
        let additionalPaths = [
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ]
        return runtimePaths + additionalPaths.filter { !runtimePaths.contains($0) }
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sCode = staticCode
        else { return nil }

        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(sCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
