import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var siteURL: URL?
    @Published private(set) var workshopName: String?
    @Published var isBooting = true

    private let defaults = UserDefaults.standard

    init() {
        if let value = defaults.string(forKey: "site_url"), let url = URL(string: value) {
            siteURL = url
        }
        workshopName = defaults.string(forKey: "workshop_name")

        Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            isBooting = false
        }
    }

    func link(code: String, workshopName: String, siteURL: URL) {
        defaults.set(code, forKey: "link_code")
        defaults.set(workshopName, forKey: "workshop_name")
        defaults.set(siteURL.absoluteString, forKey: "site_url")
        self.workshopName = workshopName
        self.siteURL = siteURL
    }

    func unlink() {
        defaults.removeObject(forKey: "link_code")
        defaults.removeObject(forKey: "workshop_name")
        defaults.removeObject(forKey: "site_url")
        workshopName = nil
        siteURL = nil
    }
}
