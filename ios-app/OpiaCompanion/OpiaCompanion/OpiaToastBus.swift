//
//  OpiaToastBus.swift
//  OpiaCompanion
//
//  Phase D — global toast bus for short-lived feedback messages.
//  Any view can call OpiaToastBus.shared.show("..."); root ChatView observes + renders.
//

import SwiftUI
import Combine

@MainActor
final class OpiaToastBus: ObservableObject {
    static let shared = OpiaToastBus()
    @Published var message: String? = nil
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ msg: String, duration: TimeInterval = 1.5) {
        hideTask?.cancel()
        message = msg
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

struct OpiaToastOverlay: View {
    @ObservedObject private var bus = OpiaToastBus.shared

    var body: some View {
        VStack {
            Spacer()
            if let msg = bus.message {
                Text(msg)
                    .font(.opiaSerifAdaptive(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 80)
            }
        }
        .animation(.easeOut(duration: 0.18), value: bus.message)
        .allowsHitTesting(false)
    }
}
