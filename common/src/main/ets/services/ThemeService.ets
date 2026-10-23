import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { ThemeControl, CustomTheme } from '@kit.ArkUI';
import { MicLogger } from '../utils/Logger';

const PREF_NAME = 'harmonymic_settings';
const KEY_THEME_MODE = 'theme_mode';

export class ThemeService {
  private static instance: ThemeService | null = null;
  private appContext: common.ApplicationContext | null = null;
  private prefStore: preferences.Preferences | null = null;
  private mode: number = 0;
  onModeChanged: ((mode: number) => void) | null = null;

  static getInstance(): ThemeService {
    if (ThemeService.instance === null) {
      ThemeService.instance = new ThemeService();
    }
    return ThemeService.instance;
  }

  getMode(): number {
    return this.mode;
  }

  init(context: common.UIAbilityContext): void {
    this.appContext = context.getApplicationContext();
    this.applyBrandTheme();
    this.loadPersistedMode();
  }

  async setMode(mode: number): Promise<void> {
    if (mode < 0 || mode > 2) {
      return;
    }
    this.mode = mode;
    this.applyColorMode();
    this.notifyModeChanged();
    const store = this.prefStore;
    if (store !== null) {
      try {
        store.putSync(KEY_THEME_MODE, mode);
        await store.flush();
        MicLogger.info(`主题模式已保存: ${this.themeModeName(mode)}`);
      } catch (error) {
        const err = error as BusinessError;
        MicLogger.warn(`保存主题模式失败: ${err.message}`);
      }
    }
  }

  private loadPersistedMode(): void {
    const appContext = this.appContext;
    if (appContext === null) {
      return;
    }
    preferences.getPreferences(appContext, PREF_NAME).then((store: preferences.Preferences) => {
      this.prefStore = store;
      const stored = store.getSync(KEY_THEME_MODE, 0);
      this.mode = typeof stored === 'number' ? stored : 0;
      this.applyColorMode();
      this.notifyModeChanged();
      MicLogger.info(`主题模式已载入: ${this.themeModeName(this.mode)}`);
    }).catch((error: BusinessError) => {
      MicLogger.warn(`读取主题模式失败: ${error.message}`);
    });
  }

  private applyColorMode(): void {
    const appContext = this.appContext;
    if (appContext === null) {
      return;
    }
    try {
      if (this.mode === 1) {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (this.mode === 2) {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`设置颜色模式失败: ${err.message}`);
    }
  }

  private notifyModeChanged(): void {
    const cb = this.onModeChanged;
    if (cb !== null) {
      cb(this.mode);
    }
  }

  private applyBrandTheme(): void {
    const theme: CustomTheme = {
      colors: { brand: '#007DFF' },
      darkColors: { brand: '#3A9BFF' }
    };
    ThemeControl.setDefaultTheme(theme);
  }

  private themeModeName(mode: number): string {
    if (mode === 1) {
      return '浅色';
    }
    if (mode === 2) {
      return '深色';
    }
    return '跟随系统';
  }
}
