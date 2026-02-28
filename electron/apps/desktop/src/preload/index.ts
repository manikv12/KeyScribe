import { contextBridge, ipcRenderer } from 'electron';
import { IPC_CHANNELS } from '../shared/ipcChannels';
import type {
  DesktopBridge,
  IpcInvokeRequestMap,
  IpcInvokeResponseMap
} from '@keyscribe/shared-types';

function invoke<K extends keyof IpcInvokeRequestMap>(
  channel: K,
  payload?: IpcInvokeRequestMap[K]
): Promise<IpcInvokeResponseMap[K]> {
  return ipcRenderer.invoke(channel, payload) as Promise<IpcInvokeResponseMap[K]>;
}

const bridge: DesktopBridge = {
  getAppInfo: () => invoke(IPC_CHANNELS.GET_APP_INFO),
  openSettingsWindow: () => invoke(IPC_CHANNELS.OPEN_SETTINGS_WINDOW),
  runtimePing: () => invoke(IPC_CHANNELS.RUNTIME_PING),
  getRuntimeCapabilities: () => invoke(IPC_CHANNELS.RUNTIME_GET_CAPABILITIES),
  runtimeStartDictation: () => invoke(IPC_CHANNELS.RUNTIME_START_DICTATION),
  runtimeStopDictation: () => invoke(IPC_CHANNELS.RUNTIME_STOP_DICTATION),
  runtimeGetStatus: () => invoke(IPC_CHANNELS.RUNTIME_GET_STATUS),
  runtimeInsertText: (text: string) => invoke(IPC_CHANNELS.RUNTIME_INSERT_TEXT, { text }),
  settingsGet: () => invoke(IPC_CHANNELS.SETTINGS_GET),
  settingsUpdateShortcuts: (shortcuts) =>
    invoke(IPC_CHANNELS.SETTINGS_UPDATE_SHORTCUTS, shortcuts),
  settingsUpdateSelectedModel: (selectedModelId: string) =>
    invoke(IPC_CHANNELS.SETTINGS_UPDATE_SELECTED_MODEL, { selectedModelId }),
  modelsList: () => invoke(IPC_CHANNELS.MODELS_LIST),
  modelsDownload: (modelId: string) => invoke(IPC_CHANNELS.MODELS_DOWNLOAD, { modelId }),
  transcriptHistoryList: () => invoke(IPC_CHANNELS.TRANSCRIPT_HISTORY_LIST),
  transcriptHistoryClear: () => invoke(IPC_CHANNELS.TRANSCRIPT_HISTORY_CLEAR)
};

contextBridge.exposeInMainWorld('keyscribe', bridge);
