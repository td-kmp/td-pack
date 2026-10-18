export declare function createClientId(): number;
export declare function send(clientId: number, request: string): void;
export declare function receive(timeout: number): Promise<string | null>;
export declare function execute(request: string): Promise<string | null>;
export declare function setLogMessageHandler(
  maxVerbosityLevel: number,
  handler: ((verbosityLevel: number, message: string) => void) | null,
): void;
