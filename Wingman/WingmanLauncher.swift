//
//  WingmanLauncher.swift
//  Wingman
//
//  The launcher: the one thing the model can do on the Mac itself. "open slack", "browse to
//  xceljet.com" and "pull up the forit support site" all become a call to `open_on_this_mac`,
//  which the app executes here without any network call. It opens an application found in the
//  Applications folders, or an http/https address in the default browser, and nothing else: no
//  file, no shell, no typing, no clicking. Neither needs a macOS permission: reading the
//  Applications folders and asking the workspace to open something prompt for nothing.
//

import AppKit
import Foundation

/// An application installed on this Mac, as the launcher found it in the Applications folders.
struct WingmanInstalledApplication: Sendable, Equatable {
    /// What the person and the model call it: `CFBundleDisplayName`, else `CFBundleName`, else
    /// the bundle's file name without ".app".
    let displayName: String
    /// The bundle's file name without ".app" ("Google Chrome" where the display name is
    /// "Chrome", say): a second name the matcher accepts.
    let folderName: String
    let bundleIdentifier: String?
    let bundleURL: URL

    /// The names the matcher compares against, in comparable form.
    var comparableNames: [String] {
        let names = [
            WingmanInstalledApplicationCatalog.comparableForm(of: displayName),
            WingmanInstalledApplicationCatalog.comparableForm(of: folderName),
        ]
        return Array(Set(names)).filter { !$0.isEmpty }
    }
}

/// The applications the launcher may open: scanned from the Applications folders, refreshed at
/// launch and when stale. Nothing outside these folders is ever launched.
struct WingmanInstalledApplicationCatalog: Sendable, Equatable {
    /// Where macOS keeps applications: the shared folder and its Utilities, Apple's own, and the
    /// person's private one. Nothing is scanned below these except Utilities.
    static let applicationFolders: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    /// The system prompt lists this many names at most; a Mac with more gets "and N more".
    static let maximumApplicationNamesInPrompt = 200

    let applications: [WingmanInstalledApplication]
    /// nil until the first scan has finished.
    let scannedAt: Date?

    static let empty = WingmanInstalledApplicationCatalog(applications: [], scannedAt: nil)

    func isDueForRescan(maximumAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let scannedAt else { return true }
        return now.timeIntervalSince(scannedAt) >= maximumAge
    }

    /// Reads every ".app" bundle directly inside the given folders. Synchronous and file-bound,
    /// so callers run it off the main thread.
    static func scan(
        folders: [URL] = applicationFolders,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> WingmanInstalledApplicationCatalog {
        var applicationsByPath: [String: WingmanInstalledApplication] = [:]
        for folder in folders {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                let bundleURL = entry.standardizedFileURL
                let bundle = Bundle(url: bundleURL)
                let infoDictionary = bundle?.infoDictionary ?? [:]
                let folderName = bundleURL.deletingPathExtension().lastPathComponent
                let displayName = nonEmpty(infoDictionary["CFBundleDisplayName"] as? String)
                    ?? nonEmpty(infoDictionary["CFBundleName"] as? String)
                    ?? folderName
                applicationsByPath[bundleURL.path] = WingmanInstalledApplication(
                    displayName: displayName,
                    folderName: folderName,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    bundleURL: bundleURL
                )
            }
        }
        let sortedApplications = applicationsByPath.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return WingmanInstalledApplicationCatalog(applications: sortedApplications, scannedAt: now)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// Lower-case, without a trailing ".app", with every run of punctuation or whitespace
    /// collapsed to one space: "Google Chrome.app" and "google-chrome" compare equal.
    static func comparableForm(of name: String) -> String {
        var trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.lowercased().hasSuffix(".app") {
            trimmedName = String(trimmedName.dropLast(4))
        }
        let lettersDigitsAndSpaces = trimmedName.lowercased().map { character -> String in
            character.isLetter || character.isNumber ? String(character) : " "
        }.joined()
        return lettersDigitsAndSpaces.split(separator: " ").joined(separator: " ")
    }

    /// The installed application a spoken name means, or nil. Exact name first, then the name
    /// with spaces removed ("vs code"), then an installed name that contains every spoken word as
    /// a whole word ("chrome" for "Google Chrome", "teams" for "Microsoft Teams"), then a name
    /// that starts with what was said. Among several, the shortest name wins, so "chrome" picks
    /// "Google Chrome" over "Google Chrome Canary".
    func application(matchingSpokenName spokenName: String) -> WingmanInstalledApplication? {
        let wantedName = Self.comparableForm(of: spokenName)
        guard !wantedName.isEmpty else { return nil }
        let wantedNameWithoutSpaces = wantedName.replacingOccurrences(of: " ", with: "")
        let wantedWords = wantedName.split(separator: " ").map(String.init)

        if let exactMatch = applications.first(where: { $0.comparableNames.contains(wantedName) }) {
            return exactMatch
        }
        if let compactMatch = applications.first(where: { application in
            application.comparableNames.contains { $0.replacingOccurrences(of: " ", with: "") == wantedNameWithoutSpaces }
        }) {
            return compactMatch
        }
        let wholeWordMatches = applications.filter { application in
            application.comparableNames.contains { installedName in
                let installedWords = Set(installedName.split(separator: " ").map(String.init))
                return wantedWords.allSatisfy { installedWords.contains($0) }
            }
        }
        if let shortestWholeWordMatch = Self.shortestNamed(wholeWordMatches) {
            return shortestWholeWordMatch
        }
        guard wantedName.count >= 3 else { return nil }
        let prefixMatches = applications.filter { application in
            application.comparableNames.contains { $0.hasPrefix(wantedName) }
        }
        return Self.shortestNamed(prefixMatches)
    }

    private static func shortestNamed(_ candidates: [WingmanInstalledApplication]) -> WingmanInstalledApplication? {
        candidates.min { $0.displayName.count < $1.displayName.count }
    }

    /// Up to five installed names sharing a word or a prefix with what was said, for the model to
    /// offer back ("did you mean…"). Empty when nothing is close.
    func namesClose(toSpokenName spokenName: String, limit: Int = 5) -> [String] {
        let wantedWords = Set(Self.comparableForm(of: spokenName).split(separator: " ").map(String.init))
        guard !wantedWords.isEmpty else { return [] }
        let closeApplications = applications.filter { application in
            application.comparableNames.contains { installedName in
                let installedWords = installedName.split(separator: " ").map(String.init)
                return installedWords.contains { installedWord in
                    wantedWords.contains { wantedWord in
                        installedWord == wantedWord
                            || (wantedWord.count >= 3 && installedWord.hasPrefix(wantedWord))
                            || (installedWord.count >= 3 && wantedWord.hasPrefix(installedWord))
                    }
                }
            }
        }
        return Array(closeApplications.prefix(limit).map(\.displayName))
    }

    /// The installed names for the system prompt, or an empty string before the first scan.
    func systemPromptSection() -> String {
        guard !applications.isEmpty else { return "" }
        let listedNames = applications.prefix(Self.maximumApplicationNamesInPrompt).map(\.displayName)
        var section = "\ninstalled applications on this mac (the names open_on_this_mac accepts): " + listedNames.joined(separator: ", ")
        let unlistedCount = applications.count - listedNames.count
        if unlistedCount > 0 {
            section += ", and \(unlistedCount) more"
        }
        return section
    }
}

/// What the model asked the launcher to open: exactly one of an application or a web address.
enum WingmanLauncherRequest: Equatable {
    case application(spokenName: String)
    case website(spokenAddress: String)

    static let applicationArgumentKey = "application"
    static let websiteArgumentKey = "website"

    /// nil when the input names neither or both.
    static func parse(toolInput: [String: Any]) -> WingmanLauncherRequest? {
        let applicationName = trimmedNonEmpty(toolInput[applicationArgumentKey] as? String)
        let websiteAddress = trimmedNonEmpty(toolInput[websiteArgumentKey] as? String)
        switch (applicationName, websiteAddress) {
        case (let applicationName?, nil):
            return .application(spokenName: applicationName)
        case (nil, let websiteAddress?):
            return .website(spokenAddress: websiteAddress)
        default:
            return nil
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

enum WingmanLauncher {
    static let toolName = "open_on_this_mac"

    /// The tool definition the model sees. It is not a gateway tool: it is always offered,
    /// `WingmanToolCatalog` never sees it, and `perform` runs it on the Mac.
    static let modelToolDefinition: [String: Any] = [
        "name": toolName,
        "description": "Open something on this Mac for the person: an installed application by name, or a web address in the default browser. Pass exactly one of application or website. Use it whenever they ask to open, launch, start, browse to, go to or pull up an app or a site. It only opens; it never types, clicks, signs in or opens a file.",
        "input_schema": [
            "type": "object",
            "properties": [
                WingmanLauncherRequest.applicationArgumentKey: [
                    "type": "string",
                    "description": "The installed application to open, by its name as listed in the system prompt (e.g. \"Slack\", \"Google Chrome\").",
                ],
                WingmanLauncherRequest.websiteArgumentKey: [
                    "type": "string",
                    "description": "The web address to open in the default browser: a bare site like \"xceljet.com\" or a full http/https url.",
                ],
            ],
        ],
    ]

    /// The prompt rules for opening things, plus the installed names. Appended to the system
    /// prompt every turn.
    static func systemPromptSection(installedApplications: WingmanInstalledApplicationCatalog) -> String {
        let rules = """


        opening things on this mac:
        you can open an installed application or a web address for the person with open_on_this_mac. "open slack", "launch xcode", "browse to xceljet.com", "go to the forit support site" and "pull up google" all mean call it, then confirm in a few words what opened. an application must be one of the installed names listed below: pass the closest one, and if nothing is close pass what they said and the tool will say it is not installed, so you can offer the names it suggests. a web address is http or https only; pass a bare site name like "xceljet.com" and the tool adds https. when they name a forit or client system rather than an address, use the address they said or one a tool returned; if you only know it from memory, open it and say the address out loud so a wrong guess is caught. the tool only opens things; it never types, clicks or signs in, and it never opens a file.
        """
        return rules + installedApplications.systemPromptSection()
    }

    /// A web address the launcher will open: http or https only, no sign-in details, a host with a
    /// dot in it (or localhost). A bare site name gets `https://`; "xceljet dot com" as speech
    /// transcribes it becomes "xceljet.com".
    static func websiteURL(fromSpokenAddress spokenAddress: String) -> URL? {
        var address = spokenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        address = address.replacingOccurrences(of: " dot ", with: ".", options: [.caseInsensitive])
        guard !address.isEmpty, address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let addressWithScheme = address.range(of: "://") == nil ? "https://" + address : address
        guard let components = URLComponents(string: addressWithScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              host.contains(".") || host.lowercased() == "localhost",
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }

    struct Outcome: Equatable {
        /// What the model is told, as the tool result.
        let resultText: String
        let isError: Bool
        /// A stable label for the Mac log (`tool_failed`), never the name or address.
        let analyticsOutcomeLabel: String
    }

    /// Opens what the model asked for. Runs on the main actor because the workspace calls do.
    @MainActor
    static func perform(
        toolInput: [String: Any],
        installedApplications: WingmanInstalledApplicationCatalog,
        workspace: NSWorkspace = .shared
    ) async -> Outcome {
        guard let request = WingmanLauncherRequest.parse(toolInput: toolInput) else {
            return Outcome(
                resultText: "\(toolName) needs exactly one of \(WingmanLauncherRequest.applicationArgumentKey) or \(WingmanLauncherRequest.websiteArgumentKey).",
                isError: true,
                analyticsOutcomeLabel: "malformed_request"
            )
        }
        switch request {
        case .application(let spokenName):
            guard let application = installedApplications.application(matchingSpokenName: spokenName) else {
                let closeNames = installedApplications.namesClose(toSpokenName: spokenName)
                let suggestion = closeNames.isEmpty
                    ? ""
                    : " Installed names close to it: \(closeNames.joined(separator: ", "))."
                return Outcome(
                    resultText: "No application named \"\(spokenName)\" is installed on this Mac.\(suggestion)",
                    isError: true,
                    analyticsOutcomeLabel: "application_not_installed"
                )
            }
            do {
                _ = try await workspace.openApplication(at: application.bundleURL, configuration: NSWorkspace.OpenConfiguration())
                return Outcome(resultText: "Opened \(application.displayName).", isError: false, analyticsOutcomeLabel: "opened_application")
            } catch {
                return Outcome(
                    resultText: "\(application.displayName) could not be opened: \(error.localizedDescription)",
                    isError: true,
                    analyticsOutcomeLabel: "open_failed"
                )
            }
        case .website(let spokenAddress):
            guard let websiteURL = websiteURL(fromSpokenAddress: spokenAddress) else {
                return Outcome(
                    resultText: "\"\(spokenAddress)\" is not a web address Wingman opens: only http and https addresses, with no sign-in details in them.",
                    isError: true,
                    analyticsOutcomeLabel: "address_refused"
                )
            }
            guard workspace.open(websiteURL) else {
                return Outcome(
                    resultText: "The default browser did not open \(websiteURL.absoluteString).",
                    isError: true,
                    analyticsOutcomeLabel: "open_failed"
                )
            }
            return Outcome(
                resultText: "Opened \(websiteURL.absoluteString) in the default browser. Tell the person which site opened.",
                isError: false,
                analyticsOutcomeLabel: "opened_website"
            )
        }
    }
}
