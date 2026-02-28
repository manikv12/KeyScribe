export const IPC_CHANNELS = {
  GET_APP_INFO: 'app:get-info',
  OPEN_SETTINGS_WINDOW: 'app:open-settings-window',
  RUNTIME_PING: 'runtime:ping',
  RUNTIME_GET_CAPABILITIES: 'runtime:get-capabilities',
  RUNTIME_START_DICTATION: 'runtime:start-dictation',
  RUNTIME_STOP_DICTATION: 'runtime:stop-dictation',
  RUNTIME_GET_STATUS: 'runtime:get-status',
  RUNTIME_INSERT_TEXT: 'runtime:insert-text',
  SETTINGS_GET: 'settings:get',
  SETTINGS_UPDATE_SHORTCUTS: 'settings:update-shortcuts',
  SETTINGS_UPDATE_SELECTED_MODEL: 'settings:update-selected-model',
  MODELS_LIST: 'models:list',
  MODELS_DOWNLOAD: 'models:download',
  TRANSCRIPT_HISTORY_LIST: 'transcript-history:list',
  TRANSCRIPT_HISTORY_CLEAR: 'transcript-history:clear'
} as const;

export type IpcChannel = (typeof IPC_CHANNELS)[keyof typeof IPC_CHANNELS];

export interface AppInfo {
  name: string;
  version: string;
  platform: string;
  isPackaged: boolean;
}

export interface OpenSettingsWindowResult {
  opened: true;
}

export interface RuntimePingResult {
  ok: boolean;
  timestampMs: number;
  sidecarConnected: boolean;
  message?: string;
}

export interface RuntimeCapabilities {
  appleSpeechAvailable: boolean;
  whisperAvailable: boolean;
  caretBoundsAvailable: boolean;
}

export interface RuntimeActionResult {
  ok: boolean;
  status: string;
  reason?: string;
}

export interface RuntimeStatusResult extends RuntimeActionResult {
  isDictating?: boolean;
}

export interface ShortcutConfig {
  startStopRecording: string;
  toggleMainWindow: string;
  openSettings: string;
}

export interface ModelCatalogItem {
  id: string;
  name: string;
  sizeMB: number;
  isDownloaded: boolean;
  isRecommended: boolean;
}

export type ModelDownloadStatus = 'idle' | 'downloading' | 'downloaded' | 'failed';

export interface ModelDownloadState {
  status: ModelDownloadStatus;
  progress: number;
  message?: string;
}

export type ModelDownloadStates = Record<string, ModelDownloadState>;

export interface SettingsModelConfig {
  selectedModelId: string;
}

export interface ModelCatalogSnapshot {
  models: ModelCatalogItem[];
  downloadStates: ModelDownloadStates;
  modelConfig: SettingsModelConfig;
}

export interface SettingsData {
  shortcuts: ShortcutConfig;
  modelConfig: SettingsModelConfig;
  modelDownloadStates: ModelDownloadStates;
}

export type ShortcutConfigPatch = Partial<ShortcutConfig>;
export type SettingsModelConfigPatch = Partial<SettingsModelConfig>;

export interface TranscriptHistoryEntry {
  id: string;
  createdAt: string;
  transcript: string;
}

export interface IpcInvokeRequestMap {
  [IPC_CHANNELS.GET_APP_INFO]: void;
  [IPC_CHANNELS.OPEN_SETTINGS_WINDOW]: void;
  [IPC_CHANNELS.RUNTIME_PING]: void;
  [IPC_CHANNELS.RUNTIME_GET_CAPABILITIES]: void;
  [IPC_CHANNELS.RUNTIME_START_DICTATION]: void;
  [IPC_CHANNELS.RUNTIME_STOP_DICTATION]: void;
  [IPC_CHANNELS.RUNTIME_GET_STATUS]: void;
  [IPC_CHANNELS.RUNTIME_INSERT_TEXT]: { text: string };
  [IPC_CHANNELS.SETTINGS_GET]: void;
  [IPC_CHANNELS.SETTINGS_UPDATE_SHORTCUTS]: ShortcutConfigPatch;
  [IPC_CHANNELS.SETTINGS_UPDATE_SELECTED_MODEL]: SettingsModelConfigPatch;
  [IPC_CHANNELS.MODELS_LIST]: void;
  [IPC_CHANNELS.MODELS_DOWNLOAD]: { modelId: string };
  [IPC_CHANNELS.TRANSCRIPT_HISTORY_LIST]: void;
  [IPC_CHANNELS.TRANSCRIPT_HISTORY_CLEAR]: void;
}

export interface IpcInvokeResponseMap {
  [IPC_CHANNELS.GET_APP_INFO]: AppInfo;
  [IPC_CHANNELS.OPEN_SETTINGS_WINDOW]: OpenSettingsWindowResult;
  [IPC_CHANNELS.RUNTIME_PING]: RuntimePingResult;
  [IPC_CHANNELS.RUNTIME_GET_CAPABILITIES]: RuntimeCapabilities;
  [IPC_CHANNELS.RUNTIME_START_DICTATION]: RuntimeActionResult;
  [IPC_CHANNELS.RUNTIME_STOP_DICTATION]: RuntimeActionResult;
  [IPC_CHANNELS.RUNTIME_GET_STATUS]: RuntimeStatusResult;
  [IPC_CHANNELS.RUNTIME_INSERT_TEXT]: RuntimeActionResult;
  [IPC_CHANNELS.SETTINGS_GET]: SettingsData;
  [IPC_CHANNELS.SETTINGS_UPDATE_SHORTCUTS]: SettingsData;
  [IPC_CHANNELS.SETTINGS_UPDATE_SELECTED_MODEL]: SettingsData;
  [IPC_CHANNELS.MODELS_LIST]: ModelCatalogSnapshot;
  [IPC_CHANNELS.MODELS_DOWNLOAD]: ModelDownloadState;
  [IPC_CHANNELS.TRANSCRIPT_HISTORY_LIST]: TranscriptHistoryEntry[];
  [IPC_CHANNELS.TRANSCRIPT_HISTORY_CLEAR]: void;
}

export interface DesktopBridge {
  getAppInfo(): Promise<AppInfo>;
  openSettingsWindow(): Promise<OpenSettingsWindowResult>;
  runtimePing(): Promise<RuntimePingResult>;
  getRuntimeCapabilities(): Promise<RuntimeCapabilities>;
  runtimeStartDictation(): Promise<RuntimeActionResult>;
  runtimeStopDictation(): Promise<RuntimeActionResult>;
  runtimeGetStatus(): Promise<RuntimeStatusResult>;
  runtimeInsertText(text: string): Promise<RuntimeActionResult>;
  settingsGet(): Promise<SettingsData>;
  settingsUpdateShortcuts(shortcuts: ShortcutConfigPatch): Promise<SettingsData>;
  settingsUpdateSelectedModel(selectedModelId: string): Promise<SettingsData>;
  modelsList(): Promise<ModelCatalogSnapshot>;
  modelsDownload(modelId: string): Promise<ModelDownloadState>;
  transcriptHistoryList(): Promise<TranscriptHistoryEntry[]>;
  transcriptHistoryClear(): Promise<void>;
}
