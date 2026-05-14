//
//  EndpointResolver.swift
//  OpiaCompanion
//
//  Phase multi-server fallback (2026-05-11) — manage `OpiaServerConfig.endpoints`
//  health + active selection. Background tasks ping /health on each endpoint, the
//  first 200-OK is locked as active. Re-resolves on failure (markFailure() ≥3) or
//  every 60s tick.
//
//  All synchronous URL access through `OpiaServerConfig.serverURL` continues to
//  work — this resolver mutates the underlying `serverActiveIndex` so the next
//  read of `serverURL` returns the freshly-elected URL.
//

import SwiftUI
import Combine

@MainActor
final class EndpointResolver: ObservableObject {
    static let shared = EndpointResolver()

    enum Status: String, CaseIterable {
        case unknown
        case ok
        case down
    }

    @Published private(set) var statuses: [Status] = []
    @Published private(set) var lastResolvedAt: Date? = nil
    @Published private(set) var resolving: Bool = false
    @Published var activeIndex: Int = OpiaServerConfig.activeIndex

    private var failureCount: Int = 0
    private var pollTask: Task<Void, Never>? = nil
    private let healthTimeoutSec: TimeInterval = 8.0  // Tailscale DERP cold-start 可能 > 2s
    private let backgroundIntervalSec: UInt64 = 60_000_000_000  // 60s

    private init() {
        rebuildStatuses()
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.resolveOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.healthCheckAll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - State

    private func rebuildStatuses() {
        let n = OpiaServerConfig.endpoints.count
        if statuses.count != n {
            statuses = Array(repeating: .unknown, count: n)
        }
        activeIndex = OpiaServerConfig.activeIndex
    }

    /// Called from network-error sites to flag the active URL as flaky. After 3
    /// consecutive failures, the next request triggers a re-resolve.
    nonisolated func markFailure() {
        Task { @MainActor in
            self.failureCount += 1
            if self.failureCount >= 3 {
                self.failureCount = 0
                Task { await self.resolveOnce() }
            }
        }
    }

    nonisolated func markSuccess() {
        Task { @MainActor in
            self.failureCount = 0
        }
    }

    // MARK: - Resolve

    /// Try every endpoint in order; first to answer /health 200 wins.
    /// If every endpoint is down, leave the previous activeIndex (so user still
    /// sees the same "broken" UX rather than silent NaN).
    func resolveOnce() async {
        rebuildStatuses()
        let list = OpiaServerConfig.endpoints
        guard !list.isEmpty else {
            statuses = []
            return
        }
        resolving = true
        defer { resolving = false }
        for (idx, ep) in list.enumerated() {
            let ok = await ping(urlString: ep.url)
            await MainActor.run {
                if idx < self.statuses.count { self.statuses[idx] = ok ? .ok : .down }
            }
            if ok {
                OpiaServerConfig.setActiveIndex(idx)
                OpiaServerConfig.syncToAppGroup()
                self.activeIndex = idx
                self.lastResolvedAt = Date()
                return
            }
        }
        // Nothing answered — leave activeIndex alone but note timestamp so UI shows we tried.
        self.lastResolvedAt = Date()
    }

    /// Periodic background sweep — ping all, update status colours, but don't
    /// switch active away from a working server unless it's now down.
    func healthCheckAll() async {
        rebuildStatuses()
        let list = OpiaServerConfig.endpoints
        guard !list.isEmpty else {
            statuses = []
            return
        }
        var newStatuses: [Status] = []
        for ep in list {
            let ok = await ping(urlString: ep.url)
            newStatuses.append(ok ? .ok : .down)
        }
        await MainActor.run {
            self.statuses = newStatuses
            // If active is down but at least one other is up, switch.
            let active = OpiaServerConfig.activeIndex
            if active < newStatuses.count, newStatuses[active] == .down {
                if let firstOK = newStatuses.firstIndex(of: .ok) {
                    OpiaServerConfig.setActiveIndex(firstOK)
                    OpiaServerConfig.syncToAppGroup()
                    self.activeIndex = firstOK
                }
            }
            self.lastResolvedAt = Date()
        }
    }

    // MARK: - Mutations from settings UI

    /// Endpoints list changed (added / removed / reordered) — reset statuses + re-resolve.
    func endpointsDidChange() {
        rebuildStatuses()
        Task { await resolveOnce() }
    }

    /// User manually picks an active endpoint — verify reachable but accept regardless.
    func setActiveIndexManually(_ idx: Int) {
        let list = OpiaServerConfig.endpoints
        guard idx >= 0, idx < list.count else { return }
        OpiaServerConfig.setActiveIndex(idx)
        OpiaServerConfig.syncToAppGroup()
        activeIndex = idx
        Task { await healthCheckAll() }
    }

    // MARK: - HTTP

    private func ping(urlString: String) async -> Bool {
        guard let base = URL(string: urlString) else { return false }
        let url = base.appendingPathComponent("health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = healthTimeoutSec
        if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
