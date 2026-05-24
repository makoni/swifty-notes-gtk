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
