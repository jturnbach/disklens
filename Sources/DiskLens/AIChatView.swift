import SwiftUI
import AppKit

struct AIChatView: View {
    @EnvironmentObject var model: AppModel

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let p = model.aiProvider {
                ProviderLogoView(provider: p, size: 28, padding: 6)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                    )
            }

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
                    model.closeAIChat()
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

            // Pop-out / pop-in toggle. When docked, shows an "open in new
            // window" glyph; when floating, shows a "bring back" glyph.
            if model.chatPresentation == .docked {
                Button {
                    model.popOutAIChat()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in a separate window")
            } else if model.chatPresentation == .floating {
                Button {
                    model.popInAIChat()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dock back to main window")
            }

            Button {
                model.closeAIChat()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close assistant")
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
                        sendText(s)
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
                if let p = model.aiProvider {
                    ProviderLogoView(provider: p, size: 16, padding: 3)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.purple)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.purple.opacity(0.18)))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !m.content.isEmpty {
                    if m.role == .assistant {
                        // Assistant: render block-level markdown directly
                        // on the background — no bubble, no border.
                        MarkdownView(markdown: m.content)
                            .foregroundStyle(m.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // User: keep the accent-color pill on the right.
                        Text(m.content)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                    }
                }
                if m.role == .assistant && !m.suggestions.isEmpty {
                    SuggestionCardView(messageID: m.id,
                                       suggestions: m.suggestions)
                        .environmentObject(model)
                }
            }
            if m.role == .assistant { Spacer(minLength: 20) }
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

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 10) {
            if let p = model.aiProvider {
                ProviderLogoView(provider: p, size: 16, padding: 3)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.purple.opacity(0.18)))
            }
            // TimelineView(.animation) ticks at the display refresh rate,
            // so each dot pulses smoothly with a phase offset instead of
            // the old static dots. The sine wave gives the familiar
            // "typing…" bounce without needing repeating Animation state.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        let period: Double = 1.1
                        let offset = Double(i) * 0.18
                        let raw = (t + offset).truncatingRemainder(dividingBy: period) / period
                        let wave = 0.5 + 0.5 * sin(raw * 2 * .pi)
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(0.3 + 0.7 * wave)
                            .scaleEffect(0.85 + 0.3 * wave)
                    }
                }
            }
            .frame(width: 36, height: 12)
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
                TextField("Ask about your disk usage…",
                          text: $model.aiDraft,
                          axis: .vertical)
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
                    .onSubmit { sendText(model.aiDraft) }

                Button {
                    sendText(model.aiDraft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(
                            model.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.4)
                            : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.aiSending
                          || model.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.aiDraft = ""
        model.sendAIMessage(trimmed)
    }
}
