//
//  ConfirmEmailView.swift
//  Northbase
//

import SwiftUI

struct ConfirmEmailView: View {
    @ObservedObject var auth: AuthStore
    let email: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Icon
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 110, height: 110)
                    .overlay(
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.tint)
                    )
                    .padding(.bottom, 28)

                Text("Confirm your email")
                    .font(.title2).bold()
                    .padding(.bottom, 12)

                Text("We sent a confirmation link to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(email)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                Text("Tap the link in the email — the app will open automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 32)

                if let msg = auth.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(msg).multilineTextAlignment(.leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                }

                // Actions
                VStack(spacing: 10) {
                    Button {
                        Task { await auth.resendConfirmation(email: email) }
                    } label: {
                        ZStack {
                            if auth.isWorking {
                                ProgressView()
                            } else {
                                Text("Resend Email").frame(maxWidth: .infinity)
                            }
                        }
                        .appSecondaryButton()
                    }
                    .disabled(auth.isWorking)

                    Button {
                        auth.status = .signedOut
                    } label: {
                        Text("Back to Sign In").appPrimaryButton()
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
