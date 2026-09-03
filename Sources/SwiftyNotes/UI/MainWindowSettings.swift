import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func updateAppSettings(_ settings: AppSettings) throws -> AppSettings {
        let defaultDirectory = NotesRepository.fallbackNotesDirectory()
        let normalizedSettings = settings.normalized(defaultDirectory: defaultDirectory)
        let targetDirectory = normalizedSettings.resolvedNotesDirectory(defaultDirectory: defaultDirectory)
        let currentDirectory = repository.notesDirectoryURL.standardizedFileURL

        if targetDirectory != currentDirectory {
            _ = try changeNotesDirectory(to: targetDirectory, targetSettings: normalizedSettings)
            return appSettings
        }

        try appSettingsStore.save(normalizedSettings)
        applyRuntimeSettings(normalizedSettings)
        return appSettings
    }

    func applyRuntimeSettings(_ settings: AppSettings, shouldRefreshPreview: Bool = true) {
        let languageChanged = settings.appLanguage != appSettings.appLanguage
        appSettings = settings
        editor.applySettings(settings)
        autosaveDelay = autosaveDelayOverride ?? .seconds(settings.autosaveDelaySeconds)

        let styleManager = StyleManager.default
        styleManager.colorScheme = settings.appearanceMode.styleManagerColorScheme
        editor.applyAutomaticStyleScheme(styleManager: styleManager)
        activeSettingsWindow?.update(
            settings: settings,
            currentNotesDirectory: repository.notesDirectoryURL,
            defaultNotesDirectory: NotesRepository.fallbackNotesDirectory(),
        )

        applyOutlineTweaks(settings)

        if languageChanged {
            // Deferred to the next main-loop turn, and that is load-bearing.
            //
            // A language change arrives from inside a settings widget's own
            // signal emission: the language ComboRow sets `selected`, which
            // emits `notify::selected` synchronously, which lands here.
            // Retranslating rebuilds that row's model — the option names are
            // translated — and GTK goes on using the old model as it unwinds
            // out of `adw_combo_row_set_selected`. That is a use-after-free,
            // and it crashed the app on every switch: `Bad pointer
            // dereference` in libgobject with the setter still on the stack.
            //
            // Letting the emission finish first costs nothing visible: the
            // whole fan-out happens before the next frame.
            //
            // Retranslating repeats the preview refresh, so the one below is
            // skipped rather than rendering the same note twice.
            deferredUIActionScheduler { [weak self] in
                guard let self else { return }
                applyLanguage(appSettings.appLanguage)
                retranslate()
                activeSettingsWindow?.retranslate()
                onLanguageChanged()
            }
            return
        }

        guard shouldRefreshPreview else { return }
        refreshPreview()
    }

    private func applyOutlineTweaks(_ settings: AppSettings) {
        outlineSidebar.applyTweaks(
            density: settings.outlineDensity,
            treeLines: settings.outlineTreeLines,
            dragHandles: settings.outlineDragHandles,
        )
        breadcrumb.root.visible = settings.outlineBreadcrumbVisible
    }
}

private extension AppearanceMode {
    var styleManagerColorScheme: AdwColorScheme {
        switch self {
        case .system:
            .default
        case .light:
            .forceLight
        case .dark:
            .forceDark
        }
    }
}
