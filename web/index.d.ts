/** Loads TDLib on this thread. The other exports work once it resolves. */
export default function initTdlib(options?: { onAbort?: (what: unknown) => void }): Promise<unknown>;

export function createClientId(): number;
export function send(clientId: number, request: string): void;
/** The next event of any client, or null. Never blocks: all of TDLib's work happens inside this call. */
export function receive(): string | null;
export function execute(request: string): string | null;
/** Seconds until TDLib's next timer. A hint: work TDLib queues for itself does not show in it. */
export function getTimeout(): number;
export function onSocketEvent(event: 'open' | 'message' | 'close' | 'error', callback: () => void): void;
export function setLogMessageHandler(
  maxVerbosityLevel: number,
  handler: ((verbosityLevel: number, message: string) => void) | null,
): void;

/** Emscripten's file system and its IndexedDB and Blob backends. */
export const FS: any;
export const IDBFS: any;
export const WORKERFS: any;
