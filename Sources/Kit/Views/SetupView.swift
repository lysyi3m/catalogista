import DiscogsKit
import SwiftUI

/// First run: take a Personal Access Token, prove it works against `/oauth/identity`, store it in
/// the Keychain, then hand off to the initial sync.
///
/// The token is the only thing standing between a fresh install and a working collection, so the
/// screen explains where to get one rather than presenting an empty field.
struct SetupView: View {
    /// Called once a token has been validated and saved, so the collection can do its first sync.
    var onSignedIn: () -> Void = {}

    @Environment(AppServices.self) private var services

    @State private var token = ""
    @FocusState private var isFieldFocused: Bool
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case validating
        case failed(String)
    }

    private static let tokenSettingsURL = URL(string: "https://www.discogs.com/settings/developers")!

    var body: some View {
        #if os(iOS)
        // A tall phone: branding in the upper half, the controls within thumb reach. Centring a
        // small block in the middle of an iPhone wastes the screen and reads as unfinished.
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            branding
            Spacer(minLength: 32)
            form
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .animation(.default, value: phase)
        #else
        VStack(spacing: 28) {
            branding
            form
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .animation(.default, value: phase)
        #endif
    }

    private var branding: some View {
        VStack(spacing: 14) {
            // Outline, not filled: the filled symbol renders as a grey disc with a dot and reads
            // as an eye rather than a record.
            Image(systemName: "record.circle")
                .font(.system(size: iconSize, weight: .ultraLight))
                .foregroundStyle(.primary)

            VStack(spacing: 6) {
                Text("Welcome to Catalogista")
                    .font(titleFont)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                Text("Your Discogs collection, on this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var form: some View {
        VStack(spacing: 12) {
            // Styled by hand rather than with `.roundedBorder`, which ignores control size: next
            // to a large prominent button it renders as a short thin box, and the two read as
            // unrelated controls instead of one input pair.
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
                .padding(.horizontal, 16)
                .frame(height: fieldHeight)
                .background(.quaternary.opacity(0.5), in: .capsule)
                // A hand-styled field has no focus ring of its own; without one there is no sign
                // the field is ready for typing.
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isFieldFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                            lineWidth: isFieldFocused ? 2 : 0.5
                        )
                }
                .animation(.easeOut(duration: 0.12), value: isFieldFocused)
                // A plain field only accepts taps on the text itself, leaving most of the drawn
                // capsule dead to touch. Focus is taken explicitly so the whole capsule works.
                .contentShape(.capsule)
                .onTapGesture { isFieldFocused = true }

            Button(action: validate) {
                // A fixed-size label keeps the button from resizing when the spinner replaces
                // the text.
                ZStack {
                    Text("Connect").fontWeight(.semibold).opacity(isValidating ? 0 : 1)
                    if isValidating { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: fieldHeight)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(trimmedToken.isEmpty || isValidating)

            if case .failed(let message) = phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            VStack(spacing: 6) {
                Link(destination: Self.tokenSettingsURL) {
                    Text("Generate a token on Discogs")
                }
                .font(.footnote.weight(.medium))

                Text("Stored in the Keychain on this device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text(DiscogsNotice.affiliation)
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        76
        #else
        60
        #endif
    }

    private var titleFont: Font {
        #if os(iOS)
        .largeTitle.weight(.bold)
        #else
        .title.weight(.semibold)
        #endif
    }

    /// One height for the field and the button, so they read as a pair.
    private var fieldHeight: CGFloat { 46 }

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

    /// A rejected token and an unreachable network look the same in a raw error string, and the
    /// fix for each is different.
    private func message(for error: any Error) -> String {
        guard let discogsError = error as? DiscogsError else { return error.localizedDescription }
        if discogsError.isUnauthorized {
            return "Discogs didn't accept that token."
        }
        if discogsError.isOffline {
            return "No connection to Discogs."
        }
        return discogsError.localizedDescription
    }
}
