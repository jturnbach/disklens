import SwiftUI
import AppKit

// Inline "cleanup suggestions" card rendered under an assistant message.
// Batches all suggestions from one AI response into a single stack with a
// summary header plus per-row Delete / Skip / Reveal actions.
struct SuggestionCardView: View {
    @EnvironmentObject var model: AppModel
    let messageID: UUID
    let suggestions: [CleanupSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            VStack(spacing: 0) {
                ForEach(suggestions) { sug in
                    row(sug)
                    if sug.id != suggestions.last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.8)
        )
    }

    // MARK: Header

    private var header: some View {
        let pending = suggestions.filter { $0.status == .pending && $0.isResolved }
        let totalBytes = pending.reduce(Int64(0)) { $0 + $1.resolvedSize }
        let deleted = suggestions.filter { $0.status == .deleted }
        let skipped = suggestions.filter { $0.status == .skipped }

        return HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup Suggestions")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 4) {
                    if pending.count > 0 {
                        Text("\(pending.count) pending · \(ByteFormatter.string(totalBytes))")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    if !deleted.isEmpty {
                        Text("· \(deleted.count) deleted")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.green)
                    }
                    if !skipped.isEmpty {
                        Text("· \(skipped.count) skipped")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if !pending.isEmpty {
                Button {
                    model.skipAllPendingSuggestions(messageID: messageID)
                } label: {
                    Text("Skip All")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    model.trashAllPendingSuggestions(messageID: messageID)
                } label: {
                    Label("Delete All", systemImage: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ sug: CleanupSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rowIcon(sug)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(for: sug))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(
                            sug.status == .skipped || sug.status == .deleted
                                ? Color.secondary
                                : Color.primary)
                        .strikethrough(sug.status == .deleted
                                       || sug.status == .skipped,
                                       color: .secondary)
                    confidenceBadge(sug.confidence)
                    statusBadge(sug)
                    Spacer()
                    if sug.isResolved {
                        Text(ByteFormatter.string(sug.resolvedSize))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(NSString(string: sug.nodeRef?.path ?? sug.path)
                        .abbreviatingWithTildeInPath)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !sug.reason.isEmpty {
                    Text(sug.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let msg) = sug.status {
                    Text("Failed: \(msg)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                    if canRetryAsAdmin(sug) {
                        failedActionRow(sug)
                    }
                }
                if sug.status == .pending {
                    actionRow(sug)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rowIcon(_ sug: CleanupSuggestion) -> some View {
        if let ref = sug.nodeRef {
            let img = NSWorkspace.shared.icon(forFile: ref.path)
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func confidenceBadge(_ c: CleanupSuggestion.Confidence) -> some View {
        let color: Color = {
            switch c {
            case .safe:         return .green
            case .probablySafe: return .yellow
            case .verifyFirst:  return .orange
            }
        }()
        Text(c.displayLabel)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    @ViewBuilder
    private func statusBadge(_ sug: CleanupSuggestion) -> some View {
        switch sug.status {
        case .pending:
            EmptyView()
        case .deleted:
            Text("Deleted")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.green.opacity(0.18)))
        case .skipped:
            Text("Skipped")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
        case .failed:
            Text("Failed")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.red.opacity(0.18)))
        }
    }

    @ViewBuilder
    private func actionRow(_ sug: CleanupSuggestion) -> some View {
        HStack(spacing: 6) {
            if sug.isResolved {
                Button {
                    model.revealSuggestion(messageID: messageID,
                                           suggestionID: sug.id)
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal in Finder")

                Button {
                    model.skipSuggestion(messageID: messageID,
                                         suggestionID: sug.id)
                } label: {
                    Text("Skip")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.trashSuggestion(messageID: messageID,
                                          suggestionID: sug.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                Text("Not found in current scan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    model.skipSuggestion(messageID: messageID,
                                         suggestionID: sug.id)
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private func displayName(for sug: CleanupSuggestion) -> String {
        let p = sug.nodeRef?.path ?? sug.path
        return (p as NSString).lastPathComponent
    }

    // Only offer admin retry when the failure looks like a permission
    // issue and the node is still in the scan.
    private func canRetryAsAdmin(_ sug: CleanupSuggestion) -> Bool {
        guard case .failed(let msg) = sug.status else { return false }
        guard sug.isResolved else { return false }
        let lowered = msg.lowercased()
        return lowered.contains("permission")
            || lowered.contains("administrator")
            || lowered.contains("not permitted")
            || lowered.contains("privilege")
            || lowered.contains("access")
    }

    @ViewBuilder
    private func failedActionRow(_ sug: CleanupSuggestion) -> some View {
        HStack(spacing: 6) {
            Button {
                model.skipSuggestion(messageID: messageID,
                                     suggestionID: sug.id)
            } label: {
                Text("Dismiss")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                model.trashSuggestionAsAdmin(messageID: messageID,
                                              suggestionID: sug.id)
            } label: {
                Label("Retry as Admin", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .help("Prompt for your admin password and retry with elevated privileges")
        }
        .padding(.top, 4)
    }
}
