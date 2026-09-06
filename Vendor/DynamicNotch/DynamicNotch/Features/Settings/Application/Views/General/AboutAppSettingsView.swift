//
//  AboutApp.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 3/6/26.
//

import SwiftUI

struct AboutAppSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var applicationSettings: ApplicationSettingsStore
    
    let onRequestInternetAccess: () -> Bool
    
    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        
        switch (version) {
        case let (version?):
            return "v\(version)"
        default:
            return "DynamicNotch"
        }
    }
    
    var body: some View {
        SettingsPageScrollView {
            if AppDelegate.embeddedInstance != nil {
                embeddedAbout
            } else {
                headerCard
                socialLinksCard
                contactMeCard
            }
        }
        .accessibilityIdentifier("settings.about.root")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if AppDelegate.embeddedInstance == nil {
                    Text(appVersionText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                }
            }
        }
    }
    
    private var embeddedAbout: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 42)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ALO").font(.title2.weight(.bold))
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("Notch features for your music, conversations, and everyday tools.")
                .foregroundStyle(.secondary)
            Divider()
            Text("Open-source credits").font(.headline)
            Text("ALO embeds DynamicNotch’s original views, animations, and feature engine by Evgeniy Petrukovich. DynamicNotch is distributed under GPL-3.0; its attribution and license are included with ALO.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("DynamicNotch source and license", destination: URL(string: "https://github.com/jackson-storm/DynamicNotch")!)
            Link("ALO source", destination: URL(string: "https://github.com/theShyamsindhia/ALO")!)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerCard: some View {
        VStack(spacing: 16) {
            NotchImage("logo")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .frame(width: 90, height: 90)
                .cornerRadius(20)
                .scaleEffect(0.9)
                .background(LinearGradient.logoGradient.blur(radius: 20))
                .padding(.top, 20)
            
            VStack(spacing: 8) {
                Text("DynamicNotch")
                    .font(.system(size: 20, weight: .bold))
                
                NotchText("settings.about.description")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 50)
            }
        }
    }
    
    private var socialLinksCard: some View {
        SettingsCard(spacing: 0, padding: 0) {
            SettingsUrlRowView(
                title: "settings.about.telegramChannel.title",
                description: "settings.about.telegramChannel.desc",
                imageName: "telegram",
                color: .clear,
                cornerRadius: 30,
                position: .first,
                url: "https://t.me/Dynamic_Notch",
                onRequestInternetAccess: onRequestInternetAccess
            )
            
            SettingsUrlRowView(
                title: "settings.about.github.title",
                description: "settings.about.github.desc",
                imageName: "gitHub",
                color: .clear,
                cornerRadius: 30,
                position: .middle,
                url: "https://github.com/jackson-storm/DynamicNotch",
                onRequestInternetAccess: onRequestInternetAccess
            )
            
            SettingsUrlRowView(
                title: "settings.about.website.title",
                description: "settings.about.website.desc",
                imageName: "simplifiedLogo",
                color: .clear,
                cornerRadius: 30,
                position: .last,
                url: "https://dynamicnotch.evgeniy-petrukovich.workers.dev",
                onRequestInternetAccess: onRequestInternetAccess
            )
        }
    }
    
    private var contactMeCard: some View {
        SettingsCard(title: "settings.about.card.contact", spacing: 0, padding: 0) {
            SettingsUrlRowView(
                title: "settings.about.telegramAccount.title",
                description: "settings.about.telegramAccount.desc",
                imageName: "telegram",
                color: .clear,
                cornerRadius: 30,
                position: .first,
                url: "https://t.me/id10101101",
                onRequestInternetAccess: onRequestInternetAccess
            )
            
            SettingsUrlRowView(
                title: "settings.about.email.title",
                description: "settings.about.email.desc",
                imageName: "email",
                color: .clear,
                cornerRadius: 30,
                position: .last,
                url: "mailto:evgeniy.petrukovich@icloud.com?subject=A%20question%20about%20DynamicNotch",
                onRequestInternetAccess: onRequestInternetAccess
            )
        }
    }
    
    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        openInternetURL(url)
    }
    
    private func openInternetURL(_ url: URL) {
        guard onRequestInternetAccess() else { return }
        openURL(url)
    }
}
