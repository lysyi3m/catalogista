import DiscogsKit
import SwiftUI

/// First run: validate a Personal Access Token, save it in the Keychain, then start the first sync.
struct SetupView: View {
    var onSignedIn: () -> Void = {}

    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme

    @State private var token = ""
    @FocusState private var isFieldFocused: Bool
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case validating
        case failed(String)
    }

    private static let tokenSettingsURL = URL(string: "https://www.discogs.com/settings/developers")!
    private var ink: Color {
        colorScheme == .dark ? Color(red: 0.92, green: 0.95, blue: 1) : brandNavy
    }
    private let brandNavy = Color(red: 0.07, green: 0.16, blue: 0.27)
    private var blue: Color {
        colorScheme == .dark ? Color(red: 0.39, green: 0.62, blue: 1) : Color(red: 0.16, green: 0.40, blue: 0.84)
    }
    private let orange = Color(red: 0.98, green: 0.37, blue: 0.22)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    if geometry.size.width >= 800 {
                        HStack(alignment: .center, spacing: 72) {
                            welcome(compact: false)
                                .frame(maxWidth: 440, alignment: .leading)
                            connectionPanel
                                .frame(width: 320)
                        }
                        .frame(maxWidth: 920)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(520, geometry.size.height - 100))
                    } else {
                        VStack(spacing: 36) {
                            welcome(compact: true)
                            connectionPanel
                                .frame(maxWidth: 400)
                        }
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - 130))
                    }
                    footer
                }
                .padding(.horizontal, geometry.size.width >= 800 ? 48 : 24)
                .padding(.bottom, 22)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.11, blue: 0.17), Color(red: 0.12, green: 0.16, blue: 0.24)]
                    : [Color(red: 0.96, green: 0.97, blue: 0.98), Color(red: 0.91, green: 0.94, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private func welcome(compact: Bool) -> some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 18 : 24) {
            if !compact {
                recordArtwork
                    .padding(.bottom, 12)
            }

            VStack(alignment: compact ? .center : .leading, spacing: 12) {
                Text("Welcome to\nCatalogista")
                    .font(.system(size: compact ? 34 : 46, weight: .bold, design: .rounded))
                    .tracking(-1.6)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(compact ? .center : .leading)

                Text("Your Discogs collection, beautifully organized on this device")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(ink.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(compact ? .center : .leading)
            }
        }
        .padding(.top, compact ? 48 : 0)
    }

    private var recordArtwork: some View {
        WelcomeArtwork(navy: brandNavy, blue: blue, orange: orange)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to Discogs")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ink)
                Text("Sync your collection to this device.")
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                SecureField("Personal Access Token", text: $token)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .disabled(isValidating)
                    .onSubmit(validate)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    #endif
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(
                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.65),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isFieldFocused ? blue.opacity(0.7) : ink.opacity(0.15),
                                lineWidth: isFieldFocused ? 1.5 : 0.5
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { if !isValidating { isFieldFocused = true } }

                Button(action: validate) {
                    ZStack {
                        Text("Connect").opacity(isValidating ? 0 : 1)
                        if isValidating { ProgressView().controlSize(.small) }
                    }
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .controlSize(.large)
                .tint(blue)
                .disabled(trimmedToken.isEmpty || isValidating)
            }

            if case .failed(let message) = phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 12) {
                Link(destination: Self.tokenSettingsURL) {
                    HStack(spacing: 5) {
                        Text("Get a token on Discogs")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.medium))
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(blue)

                Label("Stored securely in this device’s Keychain", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            Text(DiscogsNotice.affiliation)
                .multilineTextAlignment(.center)
            Link("Privacy Policy", destination: AppLinks.privacyPolicy)
        }
        .font(.caption2)
        .foregroundStyle(ink.opacity(0.55))
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidating: Bool { phase == .validating }

    private func validate() {
        guard !trimmedToken.isEmpty else { return }
        phase = .validating
        Task {
            do {
                try await services.signIn(token: trimmedToken)
                token = ""
                phase = .idle
                onSignedIn()
            } catch {
                phase = .failed(message(for: error))
            }
        }
    }

    private func message(for error: any Error) -> String {
        guard let discogsError = error as? DiscogsError else { return error.localizedDescription }
        if discogsError.isUnauthorized { return "Discogs did not accept this token. Check it and try again." }
        if discogsError.isOffline { return "No connection to Discogs." }
        return discogsError.localizedDescription
    }
}

private struct WelcomeArtwork: View {
    let navy: Color
    let blue: Color
    let orange: Color

    var body: some View {
        artwork
            .frame(width: 360, height: 210)
            .accessibilityHidden(true)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(navy)
                .frame(width: 154, height: 154)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(blue)
                        .frame(width: 134, height: 134)
                        .offset(x: 33, y: 38)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .rotationEffect(.degrees(-10))
                .offset(x: -83, y: 10)

            RoundedRectangle(cornerRadius: 24)
                .fill(orange)
                .frame(width: 154, height: 154)
                .overlay {
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 88, height: 88)
                }
                .rotationEffect(.degrees(9))
                .offset(x: 78, y: -12)

            RoundedRectangle(cornerRadius: 24)
                .fill(navy)
                .frame(width: 164, height: 164)
                .overlay {
                    ZStack {
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [Color.white, Color(red: 0.65, green: 0.76, blue: 0.89), .white, Color(red: 0.53, green: 0.68, blue: 0.84), .white],
                                    center: .center
                                )
                            )
                            .frame(width: 136, height: 136)
                        Circle()
                            .fill(navy)
                            .frame(width: 36, height: 36)
                        Circle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 7, height: 7)
                    }
                }
                .shadow(color: navy.opacity(0.24), radius: 24, y: 16)
        }
    }
}
