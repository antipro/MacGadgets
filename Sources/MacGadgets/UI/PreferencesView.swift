import SwiftUI

struct PreferencesView: View {
    @ObservedObject var keepAwake: KeepAwakeModule
    @ObservedObject var scrollReverser: ScrollReverserModule
    @ObservedObject var androidDrive: AndroidDriveModule
    @ObservedObject var kdeConnect: KDEConnectModule
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var launchAtLogin = LaunchAtLogin.shared.isEnabled
    @State private var loginError: String?

    var body: some View {
        // Reference l10n.selection so SwiftUI re-evaluates all localized strings on language change.
        let _ = l10n.selection

        Form {
            Section(L10n.tr("prefs.section.language")) {
                Picker(
                    L10n.tr("prefs.language.label"),
                    selection: Binding(
                        get: { l10n.selection },
                        set: { l10n.select($0) }
                    )
                ) {
                    Text(AppLanguage.system.nativeName)
                        .tag(AppLanguage.system)
                    Divider()
                    ForEach(AppLanguage.selectableLanguages) { lang in
                        Text(lang.nativeName)
                            .tag(lang)
                    }
                }
            }

            Section(L10n.tr("prefs.section.general")) {
                Toggle(
                    L10n.tr("footer.launch_at_login"),
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                try LaunchAtLogin.shared.setEnabled(newValue)
                                launchAtLogin = LaunchAtLogin.shared.isEnabled
                                loginError = nil
                            } catch {
                                launchAtLogin = LaunchAtLogin.shared.isEnabled
                                loginError = error.localizedDescription
                            }
                        }
                    )
                )

                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section(L10n.tr("prefs.section.gadgets")) {
                Toggle(
                    L10n.tr("keep_awake.title"),
                    isOn: $keepAwake.isModuleEnabled
                )
                .toggleStyle(.checkbox)

                Toggle(
                    L10n.tr("keep_awake.allow_display_sleep"),
                    isOn: $keepAwake.displayAllowedToSleep
                )
                .disabled(!keepAwake.isModuleEnabled)
                .padding(.leading, 20)

                Divider()

                Toggle(
                    L10n.tr("scroll.title"),
                    isOn: $scrollReverser.isModuleEnabled
                )
                .toggleStyle(.checkbox)

                Toggle(
                    L10n.tr("scroll.invert_horizontal"),
                    isOn: $scrollReverser.invertHorizontal
                )
                .disabled(!scrollReverser.isModuleEnabled)
                .padding(.leading, 20)

                Divider()

                Toggle(
                    L10n.tr("android.title"),
                    isOn: $androidDrive.isModuleEnabled
                )
                .toggleStyle(.checkbox)

                Toggle(
                    L10n.tr("android.auto_mount"),
                    isOn: $androidDrive.isAutoMountEnabled
                )
                .disabled(!androidDrive.isModuleEnabled)
                .padding(.leading, 20)

                Toggle(
                    L10n.tr("android.open_finder_on_mount"),
                    isOn: $androidDrive.openFinderOnMount
                )
                .disabled(!androidDrive.isModuleEnabled || !androidDrive.isAutoMountEnabled)
                .padding(.leading, 20)

                Divider()

                Toggle(
                    L10n.tr("kdeconnect.title"),
                    isOn: $kdeConnect.isEnabled
                )
                .toggleStyle(.checkbox)

                Toggle(
                    L10n.tr("kdeconnect.clipboard_sync"),
                    isOn: $kdeConnect.isClipboardSyncEnabled
                )
                .disabled(!kdeConnect.isEnabled)
                .padding(.leading, 20)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.layoutDirection, l10n.layoutDirection)
        .onAppear {
            launchAtLogin = LaunchAtLogin.shared.isEnabled
        }
    }
}
