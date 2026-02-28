import { JsonFileStore } from './jsonFileStore';
import {
  createDefaultShortcutConfig,
  normalizeShortcutConfig,
  type ShortcutConfig
} from './models/shortcutConfig';
import {
  createDefaultModelDownloadStates,
  createDefaultSettingsModelConfig,
  mergeModelDownloadStates,
  normalizeModelDownloadStates,
  normalizeSettingsModelConfig,
  type ModelDownloadState,
  type SettingsModelConfig
} from './models/modelConfig';

export interface SettingsData {
  shortcuts: ShortcutConfig;
  modelConfig: SettingsModelConfig;
  modelDownloadStates: Record<string, ModelDownloadState>;
}

export interface SettingsStoreOptions {
  fileName?: string;
  userDataPath?: string;
}

export interface SettingsPatch {
  shortcuts?: Partial<ShortcutConfig>;
  modelConfig?: Partial<SettingsModelConfig>;
  modelDownloadStates?: Record<string, Partial<ModelDownloadState>>;
}

export const DEFAULT_SETTINGS: Readonly<SettingsData> = {
  shortcuts: createDefaultShortcutConfig(),
  modelConfig: createDefaultSettingsModelConfig(),
  modelDownloadStates: createDefaultModelDownloadStates()
};

export function normalizeSettings(value: unknown): SettingsData {
  if (!isRecord(value)) {
    return {
      shortcuts: createDefaultShortcutConfig(),
      modelConfig: createDefaultSettingsModelConfig(),
      modelDownloadStates: createDefaultModelDownloadStates()
    };
  }

  return {
    shortcuts: normalizeShortcutConfig(value.shortcuts),
    modelConfig: normalizeSettingsModelConfig(value.modelConfig),
    modelDownloadStates: normalizeModelDownloadStates(value.modelDownloadStates)
  };
}

export class SettingsStore {
  private readonly store: JsonFileStore<SettingsData>;

  constructor(options: SettingsStoreOptions = {}) {
    this.store = new JsonFileStore<SettingsData>({
      fileName: options.fileName ?? 'settings.json',
      userDataPath: options.userDataPath,
      defaultValue: DEFAULT_SETTINGS,
      normalize: normalizeSettings
    });
  }

  getFilePath(): string {
    return this.store.getFilePath();
  }

  async get(): Promise<SettingsData> {
    return this.store.get();
  }

  async set(nextValue: SettingsData): Promise<SettingsData> {
    return this.store.set(nextValue);
  }

  async update(patch: SettingsPatch): Promise<SettingsData> {
    return this.store.update((current) => {
      const merged: SettingsData = {
        ...current,
        shortcuts: normalizeShortcutConfig({
          ...current.shortcuts,
          ...patch.shortcuts
        }),
        modelConfig: normalizeSettingsModelConfig({
          ...current.modelConfig,
          ...patch.modelConfig
        }),
        modelDownloadStates: mergeModelDownloadStates(
          current.modelDownloadStates,
          patch.modelDownloadStates
        )
      };

      return normalizeSettings(merged);
    });
  }

  async reset(): Promise<SettingsData> {
    return this.store.reset();
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
