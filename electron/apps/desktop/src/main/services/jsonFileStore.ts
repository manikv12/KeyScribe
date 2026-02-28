import { app } from 'electron';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

export interface JsonFileStoreOptions<T> {
  fileName: string;
  defaultValue: T;
  normalize(value: unknown): T;
  userDataPath?: string;
  spacing?: number;
}

export class JsonFileStore<T> {
  private readonly fileName: string;
  private readonly userDataPath?: string;
  private readonly defaultValue: T;
  private readonly normalizeValue: (value: unknown) => T;
  private readonly spacing: number;

  private cache: T | null = null;
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(options: JsonFileStoreOptions<T>) {
    this.fileName = options.fileName;
    this.userDataPath = options.userDataPath;
    this.defaultValue = options.defaultValue;
    this.normalizeValue = options.normalize;
    this.spacing = options.spacing ?? 2;
  }

  getFilePath(): string {
    const userDataDirectory = this.userDataPath ?? app.getPath('userData');
    return join(userDataDirectory, this.fileName);
  }

  async get(): Promise<T> {
    if (this.cache !== null) {
      return this.clone(this.cache);
    }

    const loaded = await this.readFromDisk();
    this.cache = loaded;
    return this.clone(loaded);
  }

  async set(nextValue: T): Promise<T> {
    const normalized = this.normalizeValue(nextValue);
    this.cache = normalized;
    await this.enqueueWrite(normalized);
    return this.clone(normalized);
  }

  async update(updater: (current: T) => T): Promise<T> {
    const current = await this.get();
    const next = updater(current);
    return this.set(next);
  }

  async reset(): Promise<T> {
    return this.set(this.defaultValue);
  }

  private async readFromDisk(): Promise<T> {
    const fallbackValue = this.normalizeValue(this.defaultValue);

    try {
      const rawText = await readFile(this.getFilePath(), 'utf8');
      const parsed = JSON.parse(rawText) as unknown;
      return this.normalizeValue(parsed);
    } catch (error) {
      if (!canRecoverFromReadError(error)) {
        throw error;
      }

      await this.enqueueWrite(fallbackValue);
      return fallbackValue;
    }
  }

  private async enqueueWrite(nextValue: T): Promise<void> {
    const serialized = `${JSON.stringify(nextValue, null, this.spacing)}\n`;
    const destinationPath = this.getFilePath();

    this.writeQueue = this.writeQueue
      .catch(() => undefined)
      .then(async () => {
        await mkdir(dirname(destinationPath), { recursive: true });
        await writeFile(destinationPath, serialized, 'utf8');
      });

    await this.writeQueue;
  }

  private clone(value: T): T {
    return JSON.parse(JSON.stringify(value)) as T;
  }
}

function canRecoverFromReadError(error: unknown): boolean {
  if (isNodeError(error) && error.code === 'ENOENT') {
    return true;
  }

  return error instanceof SyntaxError;
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && 'code' in error;
}
