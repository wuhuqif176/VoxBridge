export const nrIsSupported: () => boolean;
export const nrStart: () => boolean;
export const nrStop: () => void;
export const nrProcess: (chunk: ArrayBuffer) => ArrayBuffer;
export const nrSetBypass: (bypass: boolean) => void;
export const nrSetStrength: (tier: number) => void;
export const nrGetLastError: () => string;
