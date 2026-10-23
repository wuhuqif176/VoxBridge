import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0206;
const TAG = 'HarmonyMic';

export class MicLogger {
  private static lines: string[] = [];
  private static readonly MAX_LINES: number = 300;

  static debug(message: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', message);
    MicLogger.append('D', message);
  }

  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    MicLogger.append('I', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
    MicLogger.append('W', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
    MicLogger.append('E', message);
  }

  static getRecentText(): string {
    return MicLogger.lines.join('\n');
  }

  static clear(): void {
    MicLogger.lines = [];
  }

  private static append(level: string, message: string): void {
    const now = new Date();
    const stamp = `${MicLogger.pad(now.getHours())}:${MicLogger.pad(now.getMinutes())}:${MicLogger.pad(now.getSeconds())}`;
    MicLogger.lines.push(`[${stamp}][${level}] ${message}`);
    if (MicLogger.lines.length > MicLogger.MAX_LINES) {
      MicLogger.lines.splice(0, MicLogger.lines.length - MicLogger.MAX_LINES);
    }
  }

  private static pad(value: number): string {
    if (value < 10) {
      return `0${value}`;
    }
    return `${value}`;
  }
}
