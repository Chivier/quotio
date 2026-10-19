//
//  AccountRecoveryHelpSheet.swift
//  QuotioPresentation
//
//  Explains how to repair an account whose credential is owned by another app or CLI.
//

import QuotioDomain
import SwiftUI

/// A credential discovered from Claude Code, Codex CLI, Copilot, Kiro, an IDE or a
/// CLIProxyAPI file is owned by that source. Quotio cannot repair it in place, and its own
/// login could authenticate whichever account is active in the browser and add an
/// unrelated duplicate, so the user is sent back to the real owner.
struct AccountRecoveryHelpSheet: View {
    let account: AccountRowData
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProviderIcon(provider: account.provider, size: 48)

            Text("providers.recoveryHelp.title".localized())
                .font(.title3.bold())

            Text(String(
                format: "providers.recoveryHelp.message".localized(),
                account.provider.displayName,
                account.source.displayName
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 380)

            HStack {
                Button("action.cancel".localized(), role: .cancel, action: onDismiss)
                Button("providers.recoveryHelp.refresh".localized(), action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 460)
    }
}
