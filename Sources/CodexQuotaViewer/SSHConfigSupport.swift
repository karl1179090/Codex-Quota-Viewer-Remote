import Foundation

func defaultSSHConfigURL(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh", isDirectory: true)
        .appendingPathComponent("config", isDirectory: false)
}

func loadSSHConfigHosts(
    configURL: URL = defaultSSHConfigURL(),
    fileManager: FileManager = .default
) -> [String] {
    guard fileManager.fileExists(atPath: configURL.path),
          let text = try? String(contentsOf: configURL, encoding: .utf8) else {
        return []
    }
    return parseSSHConfigHosts(text)
}

func parseSSHConfigHosts(_ text: String) -> [String] {
    var hosts: [String] = []
    var seen = Set<String>()

    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else {
            continue
        }

        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let keyword = fields.first,
              keyword.lowercased() == "host" else {
            continue
        }

        for host in fields.dropFirst() {
            guard isSelectableSSHHostPattern(host),
                  seen.insert(host).inserted else {
                continue
            }
            hosts.append(host)
        }
    }

    return hosts
}

private func isSelectableSSHHostPattern(_ host: String) -> Bool {
    guard !host.isEmpty,
          !host.hasPrefix("!"),
          !host.contains("*"),
          !host.contains("?") else {
        return false
    }
    return true
}
