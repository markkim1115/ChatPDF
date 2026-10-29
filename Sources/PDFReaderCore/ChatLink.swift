import Foundation

/// Never let model-generated links launch files or arbitrary application schemes.
public enum ChatLink: Equatable {
    case page(Int)
    case web(URL)

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return nil }
        switch parts.scheme?.lowercased() {
        case "http", "https":
            guard let host = parts.host, !host.isEmpty else { return nil }
            self = .web(url)
        case "pdfreader":
            guard parts.host == "page", parts.port == nil, parts.query == nil, parts.fragment == nil,
                  let page = Int(parts.path.dropFirst()), page > 0,
                  parts.path == "/\(page)" else { return nil }
            self = .page(page)
        default:
            return nil
        }
    }
}
