// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import WebEngine
import UIKit

/// Child settings pages browsing actions
protocol BrowsingSettingsDelegate: AnyObject, SupportSettingsDelegate {
    @MainActor
    func pressedMailApp()

    @MainActor
    func pressedAutoPlay()
}

final class BrowsingSettingsViewController: SettingsTableViewController, FeatureFlaggable {
    weak var parentCoordinator: BrowsingSettingsDelegate?

    /// Keep the private theme override just for Settings, since this is also presented from the Site Menu.
    private let _shouldUsePrivateOverride: Bool
    override var shouldUsePrivateOverride: Bool { return _shouldUsePrivateOverride }
    override var shouldBeInPrivateTheme: Bool { return false }

    init(profile: Profile,
         windowUUID: WindowUUID,
         shouldUsePrivateOverride: Bool = true) {
        self._shouldUsePrivateOverride = shouldUsePrivateOverride
        super.init(style: .grouped, windowUUID: windowUUID)
        self.profile = profile
        self.title = .Settings.Browsing.Title
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(cellType: ThemedLearnMoreTableViewCell.self)
    }

    private func getDefaultBrowserSetting() -> [SettingSection] {
        let footerTitle = NSAttributedString(
            string: String.FirefoxHomepage.HomeTabBanner.EvergreenMessage.HomeTabBannerDescription)

        return [SettingSection(footerTitle: footerTitle,
                               children: [DefaultBrowserSetting(theme: currentTheme())])]
    }

    override func generateSettings() -> [SettingSection] {
        var settings = [SettingSection]()

        var linksSettings: [Setting] = [OpenWithSetting(settings: self, settingsDelegate: parentCoordinator)]
        var contentSection = [Setting]()
        if let profile {
            let theme = currentTheme()
            let offerToOpenCopiedLinksSettings = BoolSetting(
                prefs: profile.prefs,
                theme: theme,
                prefKey: PrefsKeys.ShowClipboardBar,
                defaultValue: false,
                titleText: .SettingsOfferClipboardBarTitle,
                statusText: String(format: .SettingsOfferClipboardBarStatus, AppName.shortName.rawValue)
            )

            let showLinksPreviewSettings = BoolSetting(
                prefs: profile.prefs,
                theme: theme,
                prefKey: PrefsKeys.ContextMenuShowLinkPreviews,
                defaultValue: true,
                titleText: .SettingsShowLinkPreviewsTitle,
                statusText: .SettingsShowLinkPreviewsStatus
            )

            linksSettings += [offerToOpenCopiedLinksSettings,
                              showLinksPreviewSettings]

            let blockOpeningExternalAppsSettings = BoolSetting(
                prefs: profile.prefs,
                theme: theme,
                prefKey: PrefsKeys.BlockOpeningExternalApps,
                defaultValue: false,
                titleText: .SettingsBlockOpeningExternalAppsTitle
            )

            let autoplaySetting = AutoplaySetting(theme: theme,
                                                  prefs: profile.prefs,
                                                  settingsDelegate: parentCoordinator)

            contentSection.append(autoplaySetting)
            if featureFlagsProvider.isEnabled(.adBlocker) {
                contentSection.append(AdBlockerSetting(
                    prefs: profile.prefs,
                    supportDelegate: parentCoordinator,
                    settingDidChange: { isEnabled in
                        if isEnabled {
                            Task {
                                await ContentBlocker.shared.reloadAdBlockerList()
                                ContentBlocker.shared.prefsChanged()
                            }
                        } else {
                            ContentBlocker.shared.prefsChanged()
                        }
                    }
                ))
            }
            if featureFlagsProvider.isEnabled(.backgroundAudio) {
                contentSection.append(BackgroundAudioSetting(prefs: profile.prefs))
            }
            contentSection += [
                BlockPopupSetting(prefs: profile.prefs),
                NoImageModeSetting(profile: profile),
                blockOpeningExternalAppsSettings
            ]
        }

        let contentSectionTitle = featureFlagsProvider.isEnabled(.adBlocker)
            ? String.Settings.Browsing.Content
            : String.Settings.Browsing.Media

        settings += [SettingSection(title: NSAttributedString(string: .Settings.Browsing.Links),
                                    children: linksSettings),
                     SettingSection(title: NSAttributedString(string: contentSectionTitle),
                                    children: contentSection)]

        settings.append(SettingSection(
            title: NSAttributedString(string: "Proxy"),
            children: [SOCKS5ProxySetting()]
        ))

        return settings
    }
}

@MainActor
private final class SOCKS5ProxySetting: Setting {
    override var accessoryType: UITableViewCell.AccessoryType { .disclosureIndicator }

    override var status: NSAttributedString? {
        let settings = SOCKS5ProxyManager.load()
        let label = settings.enabled ? "Enabled" : "Disabled"
        let server = settings.host.isEmpty ? "Not configured" : "\(settings.host):\(settings.port)"
        return NSAttributedString(string: "\(label) · \(server)")
    }

    init() {
        super.init(title: NSAttributedString(string: "SOCKS5 Proxy"))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let navigationController else { return }
        let saved = SOCKS5ProxyManager.load()
        let alert = UIAlertController(
            title: "SOCKS5 Proxy",
            message: "Proxy settings are saved on this device. Restart Firefox after changes. WebKit traffic only.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Host or IP address"
            field.text = saved.host
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Port (e.g. 1080)"
            field.text = String(saved.port)
            field.keyboardType = .numberPad
        }
        alert.addTextField { field in
            field.placeholder = "Username (optional)"
            field.text = saved.username
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Password (optional)"
            field.text = saved.password
            field.isSecureTextEntry = true
        }

        func save(enabled: Bool) {
            let fields = alert.textFields ?? []
            guard fields.count == 4,
                  let port = Int(fields[1].text ?? "") else {
                showError("Enter a valid numeric port.", navigationController: navigationController)
                return
            }

            let newSettings = SOCKS5ProxySettings(
                enabled: enabled,
                host: fields[0].text ?? "",
                port: port,
                username: fields[2].text ?? "",
                password: fields[3].text ?? ""
            )
            do {
                try SOCKS5ProxyManager.save(newSettings)
                (navigationController.topViewController as? BrowsingSettingsViewController)?
                    .tableView.reloadData()
                let confirmation = UIAlertController(
                    title: enabled ? "SOCKS5 enabled" : "SOCKS5 disabled",
                    message: "Saved locally. Restart Firefox for all tabs to use the new setting.",
                    preferredStyle: .alert
                )
                confirmation.addAction(UIAlertAction(title: "OK", style: .default))
                navigationController.present(confirmation, animated: true)
            } catch {
                showError(error.localizedDescription, navigationController: navigationController)
            }
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save Disabled", style: .default) { _ in save(enabled: false) })
        alert.addAction(UIAlertAction(title: "Save & Enable", style: .default) { _ in save(enabled: true) })
        navigationController.present(alert, animated: true)
    }

    private func showError(_ message: String, navigationController: UINavigationController) {
        let error = UIAlertController(title: "SOCKS5 Proxy", message: message, preferredStyle: .alert)
        error.addAction(UIAlertAction(title: "OK", style: .default))
        navigationController.present(error, animated: true)
    }
}
