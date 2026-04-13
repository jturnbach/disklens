import SwiftUI
import AppKit

struct AIChatView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .frame(width: 640, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((model.aiProvider?.accentColor ?? .gray).opacity(0.18))
                Image(systemName: model.aiProvider?.symbol ?? "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.aiProvider?.accentColor ?? .gray)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("DiskLens Assistant")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                if let p = model.aiProvider {
                    Text("\(p.displayName) · \(model.aiModel)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button {
                    model.clearAIChat()
                } label: {
                    Label("Clear conversation", systemImage: "trash")
                }
                Button {
                    model.showAISetup = true
                } label: {
                    Label("Change provider…", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button(role: .destructive) {
                    model.disconnectAI()
                    dismiss()
                } label: {
                    Label("Disconnect", systemImage: "minus.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    // MARK: Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.aiMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.aiMessages) { m in
                            messageBubble(m)
                                .id(m.id)
                        }
                    }
                    if model.aiSending {
                        typingIndicator
                            .id("typing")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.aiMessages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: model.aiSending) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if model.aiSending {
                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
            } else if let last = model.aiMessages.last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.purple.opacity(0.7))
                .padding(.top, 30)
            Text("Ask about your disk")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("The assistant has the full scan summary — top folders, top files, file types, and your current selection.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        send(s)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.purple)
                            Text(s)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var suggestions: [String] {
        [
            "What's taking up the most space?",
            "What's safe for me to delete?",
            "Are there any caches I can clean up?",
            "Why is my Library folder so large?"
        ]
    }

    @ViewBuilder
    private func messageBubble(_ m: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if m.role == .user { Spacer(minLength: 40) }
            if m.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.purple.opacity(0.18))
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                renderedContent(m)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(bubbleColor(m))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            }
            if m.role == .assistant { Spacer(minLength: 40) }
            if m.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.accentColor)
                    )
            }
        }
    }

    @ViewBuilder
    private func renderedContent(_ m: ChatMessage) -> some View {
        if m.role == .assistant {
            // SwiftUI renders Markdown in Text initialized from
            // AttributedString — gives bold paths, bullets, links for free.
            if let attr = try? AttributedString(
                markdown: m.content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attr)
                    .font(.system(size: 12.5, design: .default))
                    .foregroundStyle(m.isError ? Color.red : Color.primary)
            } else {
                Text(m.content)
                    .font(.system(size: 12.5))
                    .foregroundStyle(m.isError ? Color.red : Color.primary)
            }
        } else {
            Text(m.content)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
        }
    }

    private func bubbleColor(_ m: ChatMessage) -> Color {
        if m.isError { return Color.red.opacity(0.18) }
        switch m.role {
        case .user:      return Color.accentColor
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        case .system:    return Color.gray.opacity(0.2)
        }
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.purple)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.opacity(0.18)))
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(0.5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            Spacer()
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your disk usage…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                    .onSubmit { send(draft) }

                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.4)
                            : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.aiSending
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("Sends scan summary (top folders, top files, type breakdown) to \(model.aiProvider?.displayName ?? "the provider"). No file contents.")
                    .font(.system(size: 9, weight: .regular))
            }
            .foregroundStyle(.tertiary)
            .padding(.bottom, 10)
            .padding(.horizontal, 14)
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        model.sendAIMessage(trimmed)
    }
}
