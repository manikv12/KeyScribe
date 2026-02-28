import { randomUUID } from 'node:crypto';
import { JsonFileStore } from './jsonFileStore';

const DEFAULT_MAX_ENTRIES = 20;

export interface TranscriptHistoryEntry {
  id: string;
  createdAt: string;
  transcript: string;
}

export interface TranscriptHistoryEntryInput {
  id?: string;
  createdAt?: string | Date;
  transcript: string;
}

export interface TranscriptHistoryData {
  entries: TranscriptHistoryEntry[];
}

export interface TranscriptHistoryStoreOptions {
  fileName?: string;
  userDataPath?: string;
  maxEntries?: number;
}

export const DEFAULT_TRANSCRIPT_HISTORY: Readonly<TranscriptHistoryData> = {
  entries: []
};

export function normalizeTranscriptHistory(
  value: unknown,
  maxEntries: number = DEFAULT_MAX_ENTRIES
): TranscriptHistoryData {
  const cap = normalizeMaxEntries(maxEntries);
  if (!isRecord(value) || !Array.isArray(value.entries)) {
    return { entries: [] };
  }

  const normalizedEntries = value.entries
    .map((entry) => normalizeTranscriptEntry(entry))
    .filter((entry): entry is TranscriptHistoryEntry => entry !== null)
    .sort((left, right) => Date.parse(right.createdAt) - Date.parse(left.createdAt))
    .slice(0, cap);

  return {
    entries: normalizedEntries
  };
}

export class TranscriptHistoryStore {
  private readonly maxEntries: number;
  private readonly store: JsonFileStore<TranscriptHistoryData>;

  constructor(options: TranscriptHistoryStoreOptions = {}) {
    this.maxEntries = normalizeMaxEntries(options.maxEntries);

    this.store = new JsonFileStore<TranscriptHistoryData>({
      fileName: options.fileName ?? 'transcript-history.json',
      userDataPath: options.userDataPath,
      defaultValue: DEFAULT_TRANSCRIPT_HISTORY,
      normalize: (value) => normalizeTranscriptHistory(value, this.maxEntries)
    });
  }

  getFilePath(): string {
    return this.store.getFilePath();
  }

  async get(): Promise<TranscriptHistoryData> {
    return this.store.get();
  }

  async list(): Promise<TranscriptHistoryEntry[]> {
    const history = await this.store.get();
    return history.entries;
  }

  async add(input: TranscriptHistoryEntryInput): Promise<TranscriptHistoryEntry> {
    const nextEntry = createTranscriptHistoryEntry(input);

    await this.store.update((current) => ({
      entries: [nextEntry, ...current.entries.filter((entry) => entry.id !== nextEntry.id)].slice(
        0,
        this.maxEntries
      )
    }));

    return nextEntry;
  }

  async remove(id: string): Promise<boolean> {
    const normalizedId = id.trim();
    if (!normalizedId) {
      return false;
    }

    const current = await this.store.get();
    const nextEntries = current.entries.filter((entry) => entry.id !== normalizedId);
    if (nextEntries.length === current.entries.length) {
      return false;
    }

    await this.store.set({ entries: nextEntries });
    return true;
  }

  async clear(): Promise<void> {
    await this.store.set({ entries: [] });
  }
}

function createTranscriptHistoryEntry(input: TranscriptHistoryEntryInput): TranscriptHistoryEntry {
  const transcript = input.transcript.trim();
  if (transcript.length === 0) {
    throw new Error('Transcript history entry must include non-empty transcript text.');
  }

  return {
    id: normalizeNonEmptyString(input.id) ?? randomUUID(),
    createdAt: normalizeDateToIsoString(input.createdAt),
    transcript
  };
}

function normalizeTranscriptEntry(value: unknown): TranscriptHistoryEntry | null {
  if (!isRecord(value)) {
    return null;
  }

  const transcript = normalizeNonEmptyString(value.transcript);
  if (transcript === undefined) {
    return null;
  }

  return {
    id: normalizeNonEmptyString(value.id) ?? randomUUID(),
    createdAt: normalizeDateToIsoString(value.createdAt),
    transcript
  };
}

function normalizeDateToIsoString(value: unknown): string {
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return value.toISOString();
  }

  if (typeof value === 'string') {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) {
      return parsed.toISOString();
    }
  }

  return new Date().toISOString();
}

function normalizeNonEmptyString(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : undefined;
}

function normalizeMaxEntries(maxEntries: number | undefined): number {
  if (typeof maxEntries !== 'number' || !Number.isFinite(maxEntries)) {
    return DEFAULT_MAX_ENTRIES;
  }

  const rounded = Math.floor(maxEntries);
  return rounded > 0 ? rounded : DEFAULT_MAX_ENTRIES;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
