// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Network
import Security
import WebKit

@MainActor
public struct WKWebViewParameters {
    /// A boolean value customizable with a user preference indicating whether JavaScript can
    /// open windows without user interaction.
    var blockPopups: Bool

    /// A boolean value indicating if we have a persitent webview data store.
    var isPrivate: Bool

    /// The type of pull refresh that is going to be instantiated and displayed by the webview.
    var pullRefreshType: EnginePullRefreshViewType

    /// A value indicating the user preference for audio visual media types
    var autoPlay: WKAudiovisualMediaTypes

    /// FXIOS-11986  - Allow Client to pass down it's own scheme handler for now, this will be internal later on
    var schemeHandler: SchemeHandler

    public init(blockPopups: Bool,
                isPrivate: Bool,
                autoPlay: WKAudiovisualMediaTypes,
                schemeHandler: SchemeHandler,
                pullRefreshType: EnginePullRefreshViewType = UIRefreshControl.self) {
        self.blockPopups = blockPopups
        self.isPrivate = isPrivate
        self.autoPlay = autoPlay
        self.schemeHandler = schemeHandler
        self.pullRefreshType = pullRefreshType
    }

    /// Default internal Webview parameters initializer for WebEngine reader mode purpose
    init() {
        self.blockPopups = false
        self.isPrivate = false
        self.autoPlay = .all
        self.schemeHandler = WKInternalSchemeHandler()
        self.pullRefreshType = UIRefreshControl.self
    }
}


@MainActor
public struct SOCKS5ProxySettings: Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(enabled: Bool = false,
                host: String = "",
                port: Int = 1080,
                username: String = "",
                password: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var isValid: Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanHost.isEmpty && (1...65535).contains(port)
            && (username.isEmpty == password.isEmpty)
    }
}

@MainActor
public enum SOCKS5ProxyManager {
    private static let defaults = UserDefaults.standard
    private static let prefix = "local.socks5Proxy."
    private static let service = "org.mozilla.firefox.local-socks5"
    private static let account = "proxy-password"

    public static func load() -> SOCKS5ProxySettings {
        return SOCKS5ProxySettings(
            enabled: defaults.bool(forKey: prefix + "enabled"),
            host: defaults.string(forKey: prefix + "host") ?? "",
            port: defaults.object(forKey: prefix + "port") as? Int ?? 1080,
            username: defaults.string(forKey: prefix + "username") ?? "",
            password: loadPassword()
        )
    }

    public static func save(_ settings: SOCKS5ProxySettings) throws {
        guard !settings.enabled || settings.isValid else {
            throw SOCKS5ProxyError.invalidConfiguration
        }
        try storePassword(settings.password)
        defaults.set(settings.host.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: prefix + "host")
        defaults.set(settings.port, forKey: prefix + "port")
        defaults.set(settings.username, forKey: prefix + "username")
        defaults.set(settings.enabled, forKey: prefix + "enabled")
        DefaultWKEngineConfigurationProvider.refreshProxyConfiguration(force: true)
    }

    private static func passwordQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func loadPassword() -> String {
        var query = passwordQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return ""
        }
        return password
    }

    private static func storePassword(_ password: String) throws {
        let query = passwordQuery()
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SOCKS5ProxyError.keychain(status)
            }
            return
        }

        let data = Data(password.utf8)
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SOCKS5ProxyError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw SOCKS5ProxyError.keychain(status)
        }
    }
}

public enum SOCKS5ProxyError: LocalizedError {
    case invalidConfiguration
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Enter a valid host, port (1–65535), and both username/password or neither."
        case .keychain(let status):
            return "Could not save the proxy password in Keychain (OSStatus: \(status))."
        }
    }
}

/// Provider to get a configured `WKEngineConfiguration`
/// Only one configuration provider per application should exists.
@MainActor
public protocol WKEngineConfigurationProvider {
    func createConfiguration(parameters: WKWebViewParameters) -> WKEngineConfiguration
    func endPrivateBrowsingSession()
}

/// FXIOS-11986 - This will be internal when the WebEngine is fully integrated in Firefox iOS
public struct DefaultWKEngineConfigurationProvider: WKEngineConfigurationProvider {
    private static var nonPersistentStore = WKWebsiteDataStore.nonPersistent()
    private static let defaultStore = WKWebsiteDataStore.default()
    private static let defaultDataDetectorTypes: WKDataDetectorTypes = [.phoneNumber]
    private let configuration: WKWebViewConfiguration
    private static var lastAppliedProxySettings: SOCKS5ProxySettings?

    public init(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        self.configuration = configuration
    }

    public static func refreshProxyConfiguration(force: Bool = false) {
        guard #available(iOS 17.0, *) else { return }

        let settings = SOCKS5ProxyManager.load()
        guard force || lastAppliedProxySettings != settings else { return }
        lastAppliedProxySettings = settings

        let stores = [defaultStore, nonPersistentStore]
        guard settings.enabled && settings.isValid else {
            stores.forEach { $0.proxyConfigurations = [] }
            return
        }

        let host = NWEndpoint.Host(settings.host.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.allowFailover = false
        if !settings.username.isEmpty {
            proxy.applyCredential(username: settings.username, password: settings.password)
        }
        stores.forEach { $0.proxyConfigurations = [proxy] }
    }

    public func createConfiguration(parameters: WKWebViewParameters) -> WKEngineConfiguration {
        Self.refreshProxyConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !parameters.blockPopups
        configuration.mediaTypesRequiringUserActionForPlayback = parameters.autoPlay
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = DefaultWKEngineConfigurationProvider.defaultDataDetectorTypes

        // TODO: FXIOS-8086 - Evaluate if ignoresViewportScaleLimits is still needed
        // We do this to go against the configuration of the <meta name="viewport">
        // tag to behave the same way as Safari :-(
        configuration.ignoresViewportScaleLimits = true

        // Since our app creates multiple web views, we assign the same WKWebsiteDataStore object to web views that
        // may safely share cookies.
        // The cookie store should only be created once, otherwise we can loose them. See FXIOS-11833
        configuration.websiteDataStore = parameters.isPrivate
            ? Self.nonPersistentStore
            : Self.defaultStore

        // Popup WKWebViewConfiguration can have the scheme already registered thus registering again
        // leads to crash
        if configuration.urlSchemeHandler(forURLScheme: parameters.schemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(parameters.schemeHandler,
                                              forURLScheme: parameters.schemeHandler.scheme)
        }

        return DefaultEngineConfiguration(webViewConfiguration: configuration)
    }

    public func endPrivateBrowsingSession() {
        Self.nonPersistentStore = .nonPersistent()
        Self.lastAppliedProxySettings = nil
    }
}
