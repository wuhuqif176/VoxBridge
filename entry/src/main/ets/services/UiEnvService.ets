import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from 'common';

// 说明: 窗口环境单例（状态栏内容色 + 屏幕常亮）。F9 挂 KeepScreenOn 开关，F10 挂状态栏浅字与主题恢复。
export class UiEnvService {
  private static instance: UiEnvService | null = null;
  private win: window.Window | null = null;
  private pendingLight: boolean | null = null;

  static getInstance(): UiEnvService {
    if (UiEnvService.instance === null) {
      UiEnvService.instance = new UiEnvService();
    }
    return UiEnvService.instance;
  }

  init(context: common.UIAbilityContext): void {
    if (this.win !== null) {
      return;
    }
    window.getLastWindow(context)
      .then((mainWin: window.Window): void => {
        this.win = mainWin;
        const pending = this.pendingLight;
        if (pending !== null) {
          this.pendingLight = null;
          this.setSystemBarLightContent(pending);
        }
        this.hideSystemBar();
      })
      .catch((error: BusinessError): void => {
        MicLogger.warn(`UiEnvService 获取主窗口失败: ${error.message}`);
      });
  }

  async setSystemBarLightContent(light: boolean): Promise<void> {
    const win = this.win;
    if (win === null) {
      this.pendingLight = light;
      return;
    }
    const color = light ? '#FFFFFF' : '#000000';
    try {
      await win.setWindowSystemBarProperties({
        statusBarContentColor: color,
        navigationBarContentColor: color
      });
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`UiEnvService 状态栏设置失败: ${err.message}`);
    }
  }

  async setKeepScreenOn(on: boolean): Promise<void> {
    const win = this.win;
    if (win === null) {
      return;
    }
    try {
      await win.setWindowKeepScreenOn(on);
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`UiEnvService 屏幕常亮设置失败: ${err.message}`);
    }
  }

  // 说明: 隐藏状态栏实现全屏沉浸（保留底部导航栏）；顶部内容区可完整展示与交互。
  async hideSystemBar(): Promise<void> {
    const win = this.win;
    if (win === null) {
      return;
    }
    try {
      await win.setWindowSystemBarEnable(['navigation']);
      MicLogger.info('状态栏已隐藏（沉浸模式）');
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`UiEnvService 状态栏隐藏失败: ${err.message}`);
    }
  }
}
