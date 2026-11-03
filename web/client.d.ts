export declare class TdLibClient {
  /** Resolves with TDLib's version once the worker has loaded it. */
  readonly ready: Promise<string>;
  createClientId(): number;
  send(clientId: number, request: string): void;
  receive(timeout: number): Promise<string | null>;
  execute(request: string): Promise<string | null>;
  setLogMessageHandler(
    maxVerbosityLevel: number,
    handler: ((verbosityLevel: number, message: string) => void) | null,
  ): void;
}

/** Binds the tdjson API to a Worker created from worker.mjs; fails every call if TDLib's version is not expectedVersion. */
export declare function attach(worker: Worker, expectedVersion?: string | null): TdLibClient;
