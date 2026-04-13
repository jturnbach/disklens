import SwiftUI
import AppKit

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var volumes: [AppModel.VolumeInfo] = []
    @State private var hasFDA: Bool = Permissions.hasFullDiskAccess()
    @State private var fdaCheckTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionsSection
                    Divider()
                    scanOptionsSection
                    Divider()
                    aiFooter
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            volumes = model.mountedVolumes()
            // Re-poll FDA status periodically so the user sees the check
            // flip to green the moment they grant it in System Settings.
            fdaCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let v = Permissions.hasFullDiskAccess()
                if v != hasFDA { hasFDA = v }
            }
        }
        .onDisappear {
            fdaCheckTimer?.invalidate()
            fdaCheckTimer = nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            iconBadge
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to DiskLens")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Visualize what's eating your disk space.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.10, blue: 0.32),
                        Color(red: 0.10, green: 0.12, blue: 0.20)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISK ACCESS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hasFDA ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(hasFDA ? Color.green : Color.orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(hasFDA
                         ? "Full Disk Access is granted"
                         : "Full Disk Access is not granted")
                        .font(.system(size: 13, weight: .semibold))
                    Text(hasFDA
                         ? "DiskLens can scan everything without per-folder permission prompts."
                         : "Without Full Disk Access, macOS will prompt you to allow each protected folder (Documents, Desktop, Downloads, etc.) the first time DiskLens reads it. Granting Full Disk Access once skips all of those prompts.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !hasFDA {
                HStack(spacing: 8) {
                    Button {
                        Permissions.openFullDiskAccessSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape.fill")
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)

                    Text("Drag DiskLens.app into the list, then toggle it on.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 38)
            }
        }
    }

    private var aiFooter: some View {
        HStack(spacing: 8) {
            if model.aiConnected, let p = model.aiProvider {
                ProviderLogoView(provider: p, size: 14, padding: 3)
                Text("Signed in to \(p.productName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change") { model.showAISetup = true }
                    .controlSize(.small)
                    .buttonStyle(.link)
                Button("Sign out") { model.disconnectAI() }
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Optional: connect an AI assistant for cleanup advice")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect AI…") { model.showAISetup = true }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
    }

    private var scanOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE WHAT TO SCAN")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            scanCard(
                icon: "house.fill",
                tint: .accentColor,
                title: "Home Folder",
                subtitle: NSString(string: NSHomeDirectory()).abbreviatingWithTildeInPath,
                action: {
                    model.startScan(url: FileManager.default.homeDirectoryForCurrentUser)
                })

            scanCard(
                icon: "folder.fill",
                tint: .blue,
                title: "Choose a Folder…",
                subtitle: "Pick any directory on your Mac",
                action: { model.chooseAndScan() })

            if !volumes.isEmpty {
                Text("DISKS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .padding(.top, 4)

                ForEach(volumes) { v in
                    let used = v.totalBytes - v.freeBytes
                    let usage = v.totalBytes > 0
                        ? Double(used) / Double(v.totalBytes)
                        : 0
                    scanCard(
                        icon: v.isRemovable ? "externaldrive.fill" : "internaldrive.fill",
                        tint: v.isRemovable ? .orange : .purple,
                        title: v.name,
                        subtitle: "\(ByteFormatter.string(used)) used of \(ByteFormatter.string(v.totalBytes))",
                        progress: usage,
                        action: { model.startScan(url: v.id) })
                }
            }
        }
    }

    @ViewBuilder
    private func scanCard(icon: String,
                          tint: Color,
                          title: String,
                          subtitle: String,
                          progress: Double? = nil,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.18))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let p = progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 3)
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(tint)
                                    .frame(width: max(2, geo.size.width * p),
                                           height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
