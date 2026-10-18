export declare const module: unknown;

export declare function createClientId(): number;
export declare function send(clientId: number, request: string): void;
export declare function receive(): string | null;
export declare function execute(request: string): string | null;
export declare function getTimeout(): number;
export declare function setLogMessageHandler(
  maxVerbosityLevel: number,
  handler: ((verbosityLevel: number, message: string) => void) | null,
): void;

export declare function setWakeUpHandler(handler: (() => void) | null): void;

export declare const FS: any;
export declare const IDBFS: any;
