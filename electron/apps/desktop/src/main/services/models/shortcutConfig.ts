export interface ShortcutConfig {
  startStopRecording: string;
  toggleMainWindow: string;
  openSettings: string;
}

export const DEFAULT_SHORTCUT_CONFIG: Readonly<ShortcutConfig> = {
  startStopRecording: 'CommandOrControl+Shift+Space',
  toggleMainWindow: 'CommandOrControl+Shift+K',
  openSettings: 'CommandOrControl+,'
};

export function createDefaultShortcutConfig(): ShortcutConfig {
  return { ...DEFAULT_SHORTCUT_CONFIG };
}

export function normalizeShortcutConfig(value: unknown): ShortcutConfig {
  if (!isRecord(value)) {
    return createDefaultShortcutConfig();
  }

  return {
    startStopRecording: readShortcut(
      value.startStopRecording,
      DEFAULT_SHORTCUT_CONFIG.startStopRecording
    ),
    toggleMainWindow: readShortcut(
      value.toggleMainWindow,
      DEFAULT_SHORTCUT_CONFIG.toggleMainWindow
    ),
    openSettings: readShortcut(value.openSettings, DEFAULT_SHORTCUT_CONFIG.openSettings)
  };
}

function readShortcut(value: unknown, fallback: string): string {
  if (typeof value !== 'string') {
    return fallback;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
