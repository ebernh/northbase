//
//  LoginView.swift
//  Northbase
//

import SwiftUI

// MARK: - Shared button style helpers (available across module)

extension View {
    func appPrimaryButton() -> some View {
        self
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(.tint)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    func appSecondaryButton() -> some View {
        self
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color(.secondarySystemBackground))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - LoginView

struct LoginView: View {
    @ObservedObject var auth: AuthStore
    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @Environment(\.colorScheme) private var colorScheme

    enum Mode { case signIn, signUp, forgotPassword }

    private var title: String {
        switch mode {
        case .signIn:         return "Sign In"
        case .signUp:         return "Create Account"
        case .forgotPassword: return "Reset Password"
        }
    }

    private var buttonLabel: String {
        switch mode {
        case .signIn:         return "Sign In"
        case .signUp:         return "Create Account"
        case .forgotPassword: return "Send Reset Email"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: Header
                VStack(spacing: 12) {
                    Image(colorScheme == .dark ? "NorthbaseLogoDark" : "NorthbaseLogoLight")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130)
                        .shadow(color: colorScheme == .light ? .black.opacity(0.08) : .clear,
                                radius: 8, x: 0, y: 4)

                    Text("Northbase")
                        .font(.largeTitle).bold()

                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 56)
                .padding(.bottom, 44)

                // MARK: Form
                VStack(spacing: 11) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if mode != .forgotPassword {
                        SecureField("Password", text: $password)
                            .padding(14)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let msg = auth.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(msg).multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Primary action
                    Button {
                        Task {
                            switch mode {
                            case .signIn:         await auth.signIn(email: email, password: password)
                            case .signUp:         await auth.signUp(email: email, password: password)
                            case .forgotPassword: await auth.sendPasswordReset(email: email)
                            }
                        }
                    } label: {
                        ZStack {
                            if auth.isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text(buttonLabel).frame(maxWidth: .infinity)
                            }
                        }
                        .appPrimaryButton()
                    }
                    .disabled(auth.isWorking)
                    .padding(.top, 4)
                }

                // MARK: Divider
                HStack {
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    Text("or").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
                .padding(.vertical, 24)

                // MARK: Secondary actions
                VStack(spacing: 10) {
                    if mode == .signIn {
                        Button {
                            mode = .signUp; auth.errorMessage = nil
                        } label: {
                            Text("Create Account").appSecondaryButton()
                        }

                        Button("Forgot Password?") {
                            mode = .forgotPassword; auth.errorMessage = nil
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    } else {
                        Button {
                            mode = .signIn; auth.errorMessage = nil
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.subheadline.weight(.semibold))
                                Text("Back to Sign In")
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
        .animation(.easeInOut(duration: 0.22), value: mode)
    }
}

// MARK: - ResetSentView

struct ResetSentView: View {
    @ObservedObject var auth: AuthStore
    let email: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 110, height: 110)
                    .overlay(
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 46))
                            .foregroundStyle(.tint)
                    )
                    .padding(.bottom, 28)

                Text("Check your email")
                    .font(.title2).bold()
                    .padding(.bottom, 12)

                Text("A password reset link was sent to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(email)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .padding(.bottom, 32)

                Button {
                    auth.status = .signedOut
                } label: {
                    Text("Back to Sign In").appPrimaryButton()
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
