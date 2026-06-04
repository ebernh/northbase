//
//  AuthStore.swift
//  Northbase
//

import Foundation
import Supabase

enum AuthStatus: Equatable {
    case loading
    case signedOut
    case signedIn
    case needsEmailConfirmation(email: String)
    case passwordResetEmailSent(email: String)
}

@MainActor
final class AuthStore: ObservableObject {
    @Published var status: AuthStatus = .loading
    @Published var errorMessage: String?
    @Published var isWorking = false

    func start() {
        Task {
            for await state in supabase.auth.authStateChanges {
                switch state.event {
                case .initialSession:
                    if let s = state.session, !s.isExpired {
                        status = .signedIn       // fresh token → show app immediately
                    } else if state.session == nil {
                        status = .signedOut      // no session at all → show login
                    }
                    // expired session: stay .loading, await .tokenRefreshed or .signedOut
                case .signedIn, .tokenRefreshed:
                    status = .signedIn
                case .signedOut:
                    status = .signedOut
                default:
                    break
                }
            }
        }
    }

    func signIn(email: String, password: String) async {
        await run { try await supabase.auth.signIn(email: email, password: password) }
        // status driven by authStateChanges stream
    }

    func signUp(email: String, password: String) async {
        let email = email
        await run {
            _ = try await supabase.auth.signUp(
                email: email,
                password: password,
                redirectTo: URL(string: "https://northbase-website.vercel.app/verified")
            )
            self.status = .needsEmailConfirmation(email: email)
        }
    }

    func sendPasswordReset(email: String) async {
        let email = email
        await run {
            try await supabase.auth.resetPasswordForEmail(email)
            self.status = .passwordResetEmailSent(email: email)
        }
    }

    func resendConfirmation(email: String) async {
        await run { try await supabase.auth.resend(email: email, type: .signup) }
    }

    func signOut() async {
        await run { try await supabase.auth.signOut() }
    }

    func deleteAccount() async {
        await run {
            // Capture user ID now — still signed in at this point
            let uid = supabase.auth.currentUser?.id.uuidString

            // 1. Delete account via edge function (throws on failure)
            try await supabase.functions.invoke("delete-user")

            // 2. Clear this user's local cache subtree
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            if let uid {
                try? FileManager.default.removeItem(
                    at: base
                        .appendingPathComponent("UserCaches")
                        .appendingPathComponent(uid))
            }

            // 3. Sign out — triggers authStateChanges → .signedOut → LoginView
            try await supabase.auth.signOut()
        }
    }

    func handleDeepLink(url: URL) async {
        do {
            try await supabase.auth.session(from: url)
            // authStateChanges stream fires .signedIn → status updates automatically
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func run(_ block: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        do { try await block() }
        catch { errorMessage = error.localizedDescription }
        isWorking = false
    }
}
