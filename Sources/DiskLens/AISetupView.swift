import SwiftUI
import AppKit

// Sheet for connecting an AI provider. Two phases: provider picker, then a
// per-provider key entry form. On save, we test the key with a tiny ping
// before we persist it, so the user finds out about typos immediately.
struct AISetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickedProvider: AIProvider? = nil
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var isTesting: Bool = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxHeight: .infinity)
        }
        .frame(width: 540, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.purple)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.purple.opacity(0.18))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(pickedProvider == nil
                     ? "Connect an AI Assistant"
                     : "Connect to \(pickedProvider!.displayName)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(pickedProvider == nil
                     ? "Pick a provider — DiskLens will share your scan with it so it can recommend what to clean up."
                     : "Paste your \(pickedProvider!.displayName) API key. It is stored in your macOS Keychain.")
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

    @ViewBuilder
    private var content: some View {
        if let provider = pickedProvider {
            keyForm(provider: provider)
        } else {
            providerPicker
        }
    }

    private var providerPicker: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(AIProvider.allCases) { p in
                    Button {
                        pickedProvider = p
                        apiKey = Keychain.load(account: p.keychainAccount) ?? ""
                        modelName = p.defaultModel
                        errorText = nil
                    } label: {
                        providerCard(p)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }

    private func providerCard(_ p: AIProvider) -> some View {
        let isConnected = Keychain.load(account: p.keychainAccount) != nil
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(p.accentColor.opacity(0.18))
                Image(systemName: p.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(p.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(p.productName)
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
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func keyForm(provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API KEY")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                Link(destination: URL(string: provider.apiKeyHelpURL)!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Get a key from \(provider.displayName)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Picker("Model", selection: $modelName) {
                    ForEach(provider.availableModels, id: \.self) { m in
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
                    pickedProvider = nil
                    errorText = nil
                }
                .controlSize(.large)
                Spacer()
                Button {
                    testAndSave(provider: provider)
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || isTesting)
            }
        }
        .padding(18)
    }

    private func testAndSave(provider: AIProvider) {
        errorText = nil
        isTesting = true
        let key = apiKey
        let pickedModel = modelName.isEmpty ? provider.defaultModel : modelName
        let probe = AIClient(provider: provider, apiKey: key, model: pickedModel)
        let ping: [ChatMessage] = [
            ChatMessage(role: .user,
                        content: "Reply with the single word: ok")
        ]
        Task {
            do {
                _ = try await probe.send(
                    system: "You are a connection test. Reply with one word.",
                    history: ping)
                await MainActor.run {
                    do {
                        try model.setAIProvider(provider, apiKey: key, model: pickedModel)
                        isTesting = false
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
}
