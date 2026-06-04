//
//  LaunchView.swift
//  Northbase
//

import SwiftUI

struct LaunchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation: Double = 0

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay(
                Image(colorScheme == .dark ? "NorthbaseLogoDark" : "NorthbaseLogoLight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220)
                    .shadow(color: colorScheme == .light ? .black.opacity(0.08) : .clear,
                            radius: 8, x: 0, y: 4)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            )
    }
}
