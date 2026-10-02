import Foundation

struct WorkshopLink: Decodable {
    let ok: Bool
    let workshop_name: String?
    let site_url: String?
    let message: String?
}

enum LinkResolverError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "No pudimos conectar con ZGT. Revisá tu conexión e intentá nuevamente."
        case .rejected(let message):
            return message
        case .insecureURL:
            return "La URL del taller no es segura."
        }
    }
}

enum LinkResolver {
    static let endpoint = URL(string: "https://central.zeoz.com.ar/wp-json/gtc/v1/app/resolve")!

    static func resolve(code: String) async throws -> (name: String, siteURL: URL) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LinkResolverError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(WorkshopLink.self, from: data)
        guard http.statusCode == 200, decoded.ok else {
            throw LinkResolverError.rejected(decoded.message ?? "El código de vinculación no es válido.")
        }

        guard let rawSite = decoded.site_url?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              var components = URLComponents(string: rawSite),
              components.scheme?.lowercased() == "https" else {
            throw LinkResolverError.insecureURL
        }

        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let siteURL = components.url else {
            throw LinkResolverError.insecureURL
        }

        return (decoded.workshop_name ?? "Taller", siteURL)
    }
}
