//
//  SlashCommandPopover.swift
//  OpiaCompanion
//
//  Phase A — pure UI slash command autocomplete for ChatView input bar.
//  Spec: ots_chat_slash_command_popover_phase_a_20260511.md
//
//  Phase A 不连 server, 不做 control plane routing — 选中后只是把 command 填入 draft,
//  Send 走普通 /chat/send. Phase B 才接 routing.
//

import SwiftUI

struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    let name: String           // "/new"
    let description: String    // "新建 session"
    let usage: String?         // "/switch <sid>"

    /// What to insert into draft when selected. For commands with args (e.g. "/switch <sid>")
    /// insert just the command + trailing space, leaving cursor after for user to type args.
    var insertion: String {
        if let usage = usage, usage.contains("<") {
            return name + " "
        }
        return name + " "
    }
}

extension SlashCommand {
    static let allCommands: [SlashCommand] = [
        .init(name: "/new",     description: "新建 session",                usage: "/new"),
        .init(name: "/stop",    description: "中断当前回复",                 usage: "/stop"),
        .init(name: "/list",    description: "列出所有 session",             usage: "/list"),
        .init(name: "/switch",  description: "切换到指定 session",           usage: "/switch <sid>"),
        .init(name: "/clear",   description: "清空本地消息",                 usage: "/clear"),
        .init(name: "/help",    description: "显示所有命令",                 usage: "/help"),
        .init(name: "/compact", description: "压缩 chain 历史 (forge-reload)", usage: "/compact"),
    ]

    /// Filter `allCommands` based on a draft string starting with "/".
    /// Returns empty if the draft doesn't qualify (no leading slash, in middle of word, etc.).
    /// "/" alone shows everything; "/cl" filters to prefix matches.
    static func filtered(for draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/") else { return [] }
        // Only match before first whitespace (so "/switch sess1" no longer triggers list)
        let firstSpaceIdx = draft.firstIndex(where: { $0.isWhitespace })
        let head = firstSpaceIdx.map { String(draft[..<$0]) } ?? draft
        // If the user already typed a complete command + space, popover should be gone.
        if firstSpaceIdx != nil { return [] }
        if head == "/" { return allCommands }
        let lower = head.lowercased()
        return allCommands.filter { $0.name.lowercased().hasPrefix(lower) }
    }
}

struct SlashCommandPopover: View {
    let commands: [SlashCommand]
    @Binding var highlightIndex: Int
    let onSelect: (SlashCommand) -> Void

    private let rowHeight: CGFloat = 36
    private let maxVisibleRows: Int = 6

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                    row(cmd, isHighlighted: idx == highlightIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(cmd) }
                }
            }
        }
        .frame(maxHeight: rowHeight * CGFloat(min(commands.count, maxVisibleRows)) + 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.opiaCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.opiaAssistant.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func row(_ cmd: SlashCommand, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(cmd.name)
                .font(.opiaSerifAdaptive(size: 14, weight: .medium))
                .foregroundStyle(Color.opiaAccent)
            Text(cmd.description)
                .font(.system(size: 12))
                .foregroundStyle(Color.opiaTextDim)
                .lineLimit(1)
            Spacer()
            if let usage = cmd.usage, usage.contains("<") {
                Text(usage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.opiaTextDim.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: rowHeight)
        .background(isHighlighted ? Color.opiaAccent.opacity(0.15) : Color.clear)
    }
}
