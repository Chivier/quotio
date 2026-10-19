//
//  GrokConnectionSheet.swift
//  QuotioPresentation
//
//  Grok has no Quotio-managed login: the Grok CLI owns the credential, and Quotio
//  only reads it. This sheet explains how to sign in there and then refreshes.
//

import QuotioDomain
import SwiftUI

struct GrokConnectionSheet: View {
    /// Returns true when a Grok login was found after refreshing.
    let onRefresh: () async throws -> Bool
    let onDismiss: () -> Void

    @Environment(PasteboardScreenModel.self) private var pasteboard
    @State private var isRefreshing = false
    @State private var loginNotFound = false
    @State private var errorMessage: String?
    @State private var copied = false

    private static let loginCommand = "grok login"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProviderIcon(provider: .grok, size: 40)
                Text("grok.connect.title".localized())
                    .font(.title2.bold())
            }

            Text("grok.connect.instructions".localized())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(Self.loginCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    pasteboard.copy(Self.loginCommand)
                    copied = true
                } label: {
                    Label(
                        (copied ? "oauth.copied" : "grok.connect.copyCommand").localized(),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if let installURL = URL(string: "https://github.com/xai-org/grok-build") {
                Link("grok.connect.install".localized(), destination: installURL)
            }

            Text("grok.connect.scope".localized())
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loginNotFound {
                Label("grok.connect.notFound".localized(), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("action.cancel".localized(), role: .cancel, action: onDismiss)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button("grok.connect.refresh".localized()) {
                    refresh()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    private func refresh() {
        isRefreshing = true
        loginNotFound = false
        errorMessage = nil
        Task {
            defer { isRefreshing = false }
            do {
                if try await onRefresh() {
                    onDismiss()
                } else {
                    loginNotFound = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
