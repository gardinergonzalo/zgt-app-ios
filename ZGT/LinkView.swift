import SwiftUI

struct LinkView: View {
    @EnvironmentObject private var appState: AppState
    @State private var code = ""
    @State private var message = ""
    @State private var isWorking = false

    private let background = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    private let surface = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    private let border = Color(red: 56 / 255, green: 56 / 255, blue: 56 / 255)
    private let lime = Color(red: 234 / 255, green: 1, blue: 0)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("ZeozLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 108, height: 73)
                    .padding(.bottom, 28)

                Text("Vinculá tu taller")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Ingresá el código de vinculación de tu taller.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                TextField("ZGT-XXXX-XXXX", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .frame(height: 60)
                    .background(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onChange(of: code) { value in
                        let formatted = Self.formatCode(value)
                        if formatted != value {
                            code = formatted
                        }
                    }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(message == "Taller vinculado" ? .secondary : Color(red: 252 / 255, green: 165 / 255, blue: 165 / 255))
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }

                Button {
                    link()
                } label: {
                    Text(isWorking ? "Vinculando…" : "Vincular")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(lime)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isWorking)
                .padding(.top, 16)

                Text("ZGT · v0.1.6")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.38))
                    .padding(.top, 22)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .background(background.ignoresSafeArea())
    }

    private func link() {
        let value = code.uppercased()
        guard value.range(of: #"^ZGT-[A-Z0-9]{4}-[A-Z0-9]{4}$"#, options: .regularExpression) != nil else {
            message = "Revisá el formato del código."
            return
        }

        isWorking = true
        message = "Conectando con ZGT…"

        Task {
            do {
                let result = try await LinkResolver.resolve(code: value)
                message = "Taller vinculado"
                appState.link(code: value, workshopName: result.name, siteURL: result.siteURL)
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private static func formatCode(_ input: String) -> String {
        let raw = input.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(11)
        var result = ""
        for (index, character) in raw.enumerated() {
            if index == 3 || index == 7 { result.append("-") }
            result.append(character)
        }
        return result
    }
}
