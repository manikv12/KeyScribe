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
