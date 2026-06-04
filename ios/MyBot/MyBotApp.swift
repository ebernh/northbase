//
//  MyBotApp.swift
//  Northbase
//
//  Created by Ethan Bernheim on 2/25/26.
//

import SwiftUI

@main
struct NorthbaseApp: App {
    @StateObject private var auth = AuthStore()
    @AppStorage("colorSchemePreference") private var colorSchemeRaw = 0

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch auth.status {
                case .loading:
                    LaunchView()
                case .signedOut:
                    LoginView(auth: auth)
                case .needsEmailConfirmation(let email):
                    ConfirmEmailView(auth: auth, email: email)
                case .signedIn:
                    FilesListView()
                        .environmentObject(auth)
                case .passwordResetEmailSent(let email):
                    ResetSentView(auth: auth, email: email)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: auth.status)
            .preferredColorScheme(preferredColorScheme)
            .task { auth.start() }
            .onOpenURL { url in
                Task { await auth.handleDeepLink(url: url) }
            }
        }
    }
}
