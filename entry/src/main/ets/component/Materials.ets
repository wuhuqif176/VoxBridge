import { uiMaterial } from '@kit.ArkUI';

// 说明: 沉浸式系统材质实例集中管理（创建开销较高，全局复用，勿在组件内散布 new）。
// 口径: connect.html 规格3/7（卡片 ULTRA_THIN+交互形变、页签栏加反色）、live.html 规格3（VizCard THIN）、规格6（sheet/toast）。
// 光感强度: applyLevel(0 柔和/1 标准/2 浓郁) 按档重建全部实例——ImmersiveStyle 厚度映射
// （柔和=材质更轻，浓郁=材质更厚；API 26 无数值强度参数，档位即强度）。
// dock 栏: 浅色底上超薄材质对比度不足，仅浅色主题按档加厚一档（THIN/REGULAR/THICK），
// 深色保持 baseStyle 不加厚；setBarTheme 由宿主页（Connect）启动/主题切换时调用，
// 重建后由宿主页自身状态变化（themeMode/@StorageProp）驱动重渲染读新实例。
export class Mat {
  static card: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN, interactive: true });
  static bar: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true,
      colorInvert: true,
      lightEffect: { color: Color.White }
    });
  static sheet: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  static toast: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
  static viz: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
  static control: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN, interactive: true });

  private static baseStyle(level: number): uiMaterial.ImmersiveStyle {
    return level === 2 ? uiMaterial.ImmersiveStyle.THIN : uiMaterial.ImmersiveStyle.ULTRA_THIN;
  }

  // 说明: dock 栏厚度随主题——浅色底对比度低加厚一档，深色底材质本就清晰保持 baseStyle。
  private static barStyle(level: number, dark: boolean): uiMaterial.ImmersiveStyle {
    if (dark) {
      return Mat.baseStyle(level);
    }
    if (level === 0) {
      return uiMaterial.ImmersiveStyle.THIN;
    }
    if (level === 2) {
      return uiMaterial.ImmersiveStyle.THICK;
    }
    return uiMaterial.ImmersiveStyle.REGULAR;
  }

  private static auxStyle(level: number): uiMaterial.ImmersiveStyle {
    if (level === 0) {
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
    if (level === 2) {
      return uiMaterial.ImmersiveStyle.REGULAR;
    }
    return uiMaterial.ImmersiveStyle.THIN;
  }

  private static sheetStyle(level: number): uiMaterial.ImmersiveStyle {
    return level === 0 ? uiMaterial.ImmersiveStyle.THICK : uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }

  private static level: number = 1;
  private static barDark: boolean = false;

  private static rebuildBar(): void {
    Mat.bar = new uiMaterial.ImmersiveMaterial({
      style: Mat.barStyle(Mat.level, Mat.barDark),
      interactive: true,
      colorInvert: true,
      lightEffect: { color: Color.White }
    });
  }

  static applyLevel(level: number): void {
    const clamped = Math.max(0, Math.min(2, Math.round(level)));
    Mat.level = clamped;
    Mat.card = new uiMaterial.ImmersiveMaterial({ style: Mat.baseStyle(clamped), interactive: true });
    Mat.rebuildBar();
    Mat.sheet = new uiMaterial.ImmersiveMaterial({ style: Mat.sheetStyle(clamped) });
    Mat.toast = new uiMaterial.ImmersiveMaterial({ style: Mat.auxStyle(clamped) });
    Mat.viz = new uiMaterial.ImmersiveMaterial({ style: Mat.auxStyle(clamped) });
    Mat.control = new uiMaterial.ImmersiveMaterial({ style: Mat.auxStyle(clamped), interactive: true });
  }

  // 说明: 主题切换时仅重建 dock 栏材质（其余材质官方渲染自适配明暗）；同主题早退防抖。
  static setBarTheme(dark: boolean): void {
    if (Mat.barDark === dark) {
      return;
    }
    Mat.barDark = dark;
    Mat.rebuildBar();
  }
}
