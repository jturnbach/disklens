import SwiftUI
import AppKit

// Sign-in flow for the AI assistant. Three phases: provider picker, a
// sign-in handoff screen that opens the provider's key page in the user's
// default browser, and a key-paste step. We validate the key with a small
// ping before saving so typos are caught immediately.
struct AISetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case pick, signIn, pasteKey, testing }

    @State private var phase: Phase = .pick
    @State private var pickedProvider: AIProvider? = nil
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxHeight: .infinity)
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let p = pickedProvider {
                ProviderLogoView(provider: p, size: 32, padding: 7)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
    }

    private var title: String {
        switch phase {
        case .pick:     return "Connect an AI Assistant"
        case .signIn:   return "Sign in to \(pickedProvider?.displayName ?? "")"
        case .pasteKey: return "Finish connecting \(pickedProvider?.displayName ?? "")"
        case .testing:  return "Testing connection…"
        }
    }

    private var subtitle: String {
        switch phase {
        case .pick:
            return "Pick a provider. DiskLens will share your scan summary so it can recommend what to clean up."
        case .signIn:
            return "Click Sign In to open \(pickedProvider?.displayName ?? "") in your browser."
        case .pasteKey:
            return "Paste the key here. It's stored in your macOS Keychain."
        case .testing:
            return "One moment while we verify your key."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pick:     providerPicker
        case .signIn:   signInStep
        case .pasteKey: pasteKeyStep
        case .testing:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Verifying with \(pickedProvider?.displayName ?? "")…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Picker

    private var providerPicker: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(AIProvider.allCases) { p in
                        Button {
                            pickedProvider = p
                            modelName = p.defaultModel
                            apiKey = ""
                            errorText = nil
                            phase = .signIn
                        } label: {
                            providerCard(p)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            Divider()
            pickerFootnote
        }
    }

    private func providerCard(_ p: AIProvider) -> some View {
        // Cheap in-memory check — never read Keychain during SwiftUI render.
        let isConnected = (model.aiProvider == p) && model.aiConnected
        return HStack(spacing: 14) {
            ProviderLogoView(provider: p, size: 36, padding: 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.productName)
                        .font(.system(size: 14, weight: .semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(p.displayName)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                    if isConnected {
                        Text("Connected")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                    }
                }
                Text("Default model: \(p.defaultModel)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(p.accentColor.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var pickerFootnote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            Text("These providers don't offer OAuth for their developer APIs — only for their hosted products. DiskLens opens the provider's key page in your browser so you can sign in there and generate a key in one click, then paste it back here. The key stays local in your macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    // MARK: Sign-in step

    private var signInStep: some View {
        guard let p = pickedProvider else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 18) {
                ProviderLogoView(provider: p, size: 64, padding: 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in with \(p.productName)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Clicking sign in opens \(p.displayName)'s API key page in your browser. Sign in there, click \"Create new secret key\", copy it, and come back here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Brand-styled sign-in button.
                Button {
                    if let url = URL(string: p.apiKeyHelpURL) {
                        NSWorkspace.shared.open(url)
                    }
                    phase = .pasteKey
                } label: {
                    HStack(spacing: 12) {
                        ProviderLogoView(provider: p, size: 22, padding: 5,
                                         background: p != .xAI)
                        Text("Sign in with \(p.productName)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(brandTextColor(p))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(brandTextColor(p).opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(p.accentColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: p.accentColor.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button {
                    phase = .pasteKey
                } label: {
                    Text("I already have a key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)

                Spacer()

                HStack {
                    Button("Back") {
                        phase = .pick
                        pickedProvider = nil
                    }
                    .controlSize(.large)
                    Spacer()
                }
            }
            .padding(20)
        )
    }

    private func brandTextColor(_ p: AIProvider) -> Color {
        // All brand colors we use for the button are dark enough that white
        // text reads well.
        .white
    }

    // MARK: Paste key step

    private var pasteKeyStep: some View {
        guard let p = pickedProvider else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API KEY")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    SecureField(placeholder(for: p), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                    HStack(spacing: 6) {
                        Button {
                            if let str = NSPasteboard.general.string(forType: .string) {
                                apiKey = str.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label("Paste from Clipboard",
                                  systemImage: "doc.on.clipboard")
                        }
                        .controlSize(.small)
                        Button {
                            if let url = URL(string: p.apiKeyHelpURL) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open key page",
                                  systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    Picker("Model", selection: $modelName) {
                        ForEach(p.availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                if let err = errorText {
                    Text(err)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red.opacity(0.12))
                        )
                }

                Spacer()

                HStack {
                    Button("Back") {
                        phase = .signIn
                        errorText = nil
                    }
                    .controlSize(.large)
                    Spacer()
                    Button {
                        testAndSave(provider: p)
                    } label: {
                        Text("Connect")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(p.accentColor)
                    .disabled(apiKey.isEmpty)
                }
            }
            .padding(20)
        )
    }

    private func placeholder(for p: AIProvider) -> String {
        switch p {
        case .openAI:    return "sk-proj-…"
        case .anthropic: return "sk-ant-…"
        case .gemini:    return "AIza…"
        case .xAI:       return "xai-…"
        }
    }

    // MARK: Validate + save

    private func testAndSave(provider: AIProvider) {
        errorText = nil
        phase = .testing
        let key = apiKey
        let pickedModel = modelName.isEmpty ? provider.defaultModel : modelName
        let probe = AIClient(provider: provider, apiKey: key, model: pickedModel)
        let ping: [ChatMessage] = [
            ChatMessage(role: .user, content: "Reply with the single word: ok")
        ]
        Task {
            do {
                _ = try await probe.send(
                    system: "You are a connection test. Reply with one word.",
                    history: ping)
                await MainActor.run {
                    do {
                        try model.setAIProvider(provider,
                                                apiKey: key,
                                                model: pickedModel)
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                        phase = .pasteKey
                    }
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    phase = .pasteKey
                }
            }
        }
    }
}
