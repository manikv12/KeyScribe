import type { DesktopBridge } from '@keyscribe/shared-types';

declare global {
  interface Window {
    keyscribe: DesktopBridge;
  }
}

export {};
