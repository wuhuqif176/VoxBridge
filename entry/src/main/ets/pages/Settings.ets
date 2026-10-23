import { bundleManager } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { curves, window } from '@kit.ArkUI';
import { ThemeService } from 'common';
import { StreamService } from '../services/StreamService';
import { Mat } from '../component/Materials';

@Component
export struct SettingsView {
  @StorageProp('probeText') probeText: string = '能力未探测';
  @StorageProp('probing') probing: boolean = false;
  @StorageProp('statLog') logText: string = '';
  @StorageProp('cfgKeepScreenOn') keepScreenOn: boolean = false;
  @StorageProp('cfgAutoRecover') autoRecover: boolean = true;
  @StorageProp('cfgAutoDowngrade') autoDowngrade: boolean = true;
  @State themeMode: number = 0;
  @State appVersion: string = '1.0.0';
  @State deviceList: audio.AudioDeviceDescriptors = [];
  @State selectedDeviceId: number = -1;
  @State expandAppearance: boolean = true;
  @State expandStreaming: boolean = true;
  @State expandDevice: boolean = true;
  @State expandDiagnostics: boolean = false;
  @State expandAbout: boolean = false;
  @StorageProp('cfgMaterialLevel') materialLevel: number = 1;
  @State topPad: number = 0;
  @State bottomPad: number = 0;
  private svc: StreamService = StreamService.getInstance();
  private foldCurve: curves.ICurve = curves.springMotion(0.4, 0.9);

  aboutToAppear(): void {
    this.themeMode = ThemeService.getInstance().getMode();
    this.loadVersion();
    this.refreshDevices();
    this.queryAvoidPads();
  }

  // 说明: 状态栏已隐藏，顶部以挖孔避让区、底部以导航/手势避让区为准补偿内容内边距。
  private queryAvoidPads(): void {
    const ui = this.getUIContext();
    const hostCtx = ui.getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    window.getLastWindow(hostCtx)
      .then((win: window.Window) => {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        this.topPad = Math.max(ui.px2vp(sys.topRect.height), ui.px2vp(cut.topRect.height));
        this.bottomPad = Math.max(ui.px2vp(sys.bottomRect.height), ui.px2vp(cut.bottomRect.height));
      })
      .catch((): void => {
        // 窗口获取失败时保持 0，由基础内边距兜底
      });
  }

  private loadVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.appVersion = info.versionName;
      }
    } catch (error) {
      // 读取版本号失败时保留默认值
    }
  }

  private pickTheme(mode: number): void {
    if (this.themeMode === mode) {
      return;
    }
    this.themeMode = mode;
    ThemeService.getInstance().setMode(mode);
  }

  private pickMaterialLevel(level: number): void {
    if (this.materialLevel === level) {
      return;
    }
    this.svc.setMaterialLevel(level);
  }

  private matLevelLabel(): string {
    if (this.materialLevel === 0) {
      return '柔和';
    }
    if (this.materialLevel === 2) {
      return '浓郁';
    }
    return '标准';
  }

  private appearanceSummary(): string {
    return `${this.themeLabel()} · 光感${this.matLevelLabel()}`;
  }

  // 说明: 官方 FAQ 口径——卡片不在 systemMaterial 生效范围（仅标题栏/底部 TabBar/弹窗类），
  // 卡面玻璃感由背景模糊承载：柔和不模糊、标准薄模糊、浓郁厚模糊，半透明字面色叠在模糊之上。
  private matCardBlur(): BlurStyle {
    if (this.materialLevel === 0) {
      return BlurStyle.NONE;
    }
    if (this.materialLevel === 2) {
      return BlurStyle.COMPONENT_THICK;
    }
    return BlurStyle.COMPONENT_THIN;
  }

  // 说明: 卡面字面色随沉浸光感档位联动（柔和更实/浓郁更透），叠在背景模糊之上构成毛玻璃。
  private matCardColor(): Resource {
    if (this.materialLevel === 0) {
      return $r('app.color.mat_card_soft');
    }
    if (this.materialLevel === 2) {
      return $r('app.color.mat_card_rich');
    }
    return $r('app.color.mat_card');
  }

  private refreshDevices(): void {
    this.deviceList = this.svc.getInputDevices();
    const selected = this.svc.getSelectedInputDevice();
    if (selected !== null) {
      this.selectedDeviceId = selected.id;
    } else {
      this.selectedDeviceId = this.defaultMicDeviceId();
    }
  }

  private defaultMicDeviceId(): number {
    for (let i = 0; i < this.deviceList.length; i++) {
      if (this.deviceList[i].deviceType === audio.DeviceType.MIC) {
        return this.deviceList[i].id;
      }
    }
    return -1;
  }

  private themeLabel(): string {
    if (this.themeMode === 1) {
      return '浅色';
    }
    if (this.themeMode === 2) {
      return '深色';
    }
    return '跟随系统';
  }

  private streamingSummary(): string {
    return `常亮${this.keepScreenOn ? '开' : '关'} · 恢复${this.autoRecover ? '开' : '关'} · 降级${this.autoDowngrade ? '开' : '关'}`;
  }

  private selectedDeviceLabel(): string {
    for (let i = 0; i < this.deviceList.length; i++) {
      if (this.deviceList[i].id === this.selectedDeviceId) {
        return StreamService.inputDeviceLabel(this.deviceList[i]);
      }
    }
    return '手机麦克风';
  }

  private deviceRowSub(device: audio.AudioDeviceDescriptor): string {
    const base = StreamService.deviceTypeText(device.deviceType);
    return this.selectedDeviceId === device.id ? `${base} · 当前使用` : base;
  }

  private pickDevice(device: audio.AudioDeviceDescriptor): void {
    if (this.selectedDeviceId === device.id) {
      return;
    }
    this.selectedDeviceId = device.id;
    this.svc.selectInputDevice(device).then(() => {
      this.refreshDevices();
    });
  }

  // 说明: @Builder 参数仅传常量（模式值/文案），选中态在内部直接读取 this.themeMode，
  // 保证主题切换后勾选标记与高亮行即时刷新。

  @Builder
  ThemeRow(mode: number, label: string, subLabel: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(subLabel)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.themeMode === mode) {
        Circle({ width: 20, height: 20 })
          .fill($r('app.color.accent'))
      } else {
        Circle({ width: 20, height: 20 })
          .fill(Color.Transparent)
          .stroke($r('app.color.text_hint'))
          .strokeWidth(1.5)
      }
    }
    .width('100%')
    .height(50)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.themeMode === mode ? $r('app.color.accent_10') : Color.Transparent)
    .onClick(() => {
      this.pickTheme(mode);
    })
  }

  @Builder
  MaterialRow(level: number, label: string, subLabel: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(subLabel)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.materialLevel === level) {
        Circle({ width: 20, height: 20 })
          .fill($r('app.color.accent'))
      } else {
        Circle({ width: 20, height: 20 })
          .fill(Color.Transparent)
          .stroke($r('app.color.text_hint'))
          .strokeWidth(1.5)
      }
    }
    .width('100%')
    .height(50)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.materialLevel === level ? $r('app.color.accent_10') : Color.Transparent)
    .onClick(() => {
      this.pickMaterialLevel(level);
    })
  }

  @Builder
  AppearanceCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('外观')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.appearanceSummary())
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_hint'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.expandAppearance ? 90 : 0 })
          .animation({ curve: this.foldCurve })
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
          this.expandAppearance = !this.expandAppearance;
        });
      })

      if (this.expandAppearance) {
        Column({ space: 4 }) {
          this.ThemeRow(0, '跟随系统', '自动匹配系统深浅色')
          this.ThemeRow(1, '浅色', '始终使用浅色主题')
          this.ThemeRow(2, '深色', '始终使用深色主题')
          Divider()
            .color($r('app.color.divider'))
            .margin({ top: 6, bottom: 6 })
          this.MaterialRow(0, '柔和', '光感最轻，卡片底色更实')
          this.MaterialRow(1, '标准', '默认沉浸光感强度')
          this.MaterialRow(2, '浓郁', '光感最强，卡片更通透')
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  @Builder
  StreamingCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('直播与后台')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.streamingSummary())
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_hint'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.expandStreaming ? 90 : 0 })
          .animation({ curve: this.foldCurve })
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
          this.expandStreaming = !this.expandStreaming;
        });
      })

      if (this.expandStreaming) {
        Column({ space: 4 }) {
          Row() {
            Text('屏幕常亮')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.keepScreenOn })
              .selectedColor($r('app.color.accent'))
              .onChange((isOn: boolean) => {
                this.svc.setCfgKeepScreenOn(isOn);
              })
          }
          .width('100%')
          .height(50)
          .padding({ left: 10, right: 10 })

          Row() {
            Text('来电自动恢复')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoRecover })
              .selectedColor($r('app.color.accent'))
              .onChange((isOn: boolean) => {
                this.svc.setCfgAutoRecover(isOn);
              })
          }
          .width('100%')
          .height(50)
          .padding({ left: 10, right: 10 })

          Row() {
            Text('弱网自动降级')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoDowngrade })
              .selectedColor($r('app.color.accent'))
              .onChange((isOn: boolean) => {
                this.svc.setCfgAutoDowngrade(isOn);
              })
          }
          .width('100%')
          .height(50)
          .padding({ left: 10, right: 10 })
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  @Builder
  DeviceRow(device: audio.AudioDeviceDescriptor) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(StreamService.inputDeviceLabel(device))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(this.deviceRowSub(device))
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.selectedDeviceId === device.id) {
        Circle({ width: 20, height: 20 })
          .fill($r('app.color.accent'))
      } else {
        Circle({ width: 20, height: 20 })
          .fill(Color.Transparent)
          .stroke($r('app.color.text_hint'))
          .strokeWidth(1.5)
      }
    }
    .width('100%')
    .height(50)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.selectedDeviceId === device.id ? $r('app.color.accent_10') : Color.Transparent)
    .onClick(() => {
      this.pickDevice(device);
    })
  }

  @Builder
  FallbackDeviceRow() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('手机麦克风')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('内置 · 当前使用')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Circle({ width: 20, height: 20 })
        .fill($r('app.color.accent'))
    }
    .width('100%')
    .height(50)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor($r('app.color.accent_10'))
  }

  @Builder
  DeviceCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('麦克风设备')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`当前 · ${this.selectedDeviceLabel()}`)
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_hint'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.expandDevice ? 90 : 0 })
          .animation({ curve: this.foldCurve })
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
          this.expandDevice = !this.expandDevice;
        });
      })

      if (this.expandDevice) {
        Column({ space: 4 }) {
          if (this.deviceList.length === 0) {
            this.FallbackDeviceRow()
          } else {
            ForEach(this.deviceList, (device: audio.AudioDeviceDescriptor) => {
              this.DeviceRow(device)
            }, (device: audio.AudioDeviceDescriptor) => `${device.id}`)
          }

          Text('列表来自 AudioSessionManager · 选择后经 selectMediaInputDevice 生效')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 2 })
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  @Builder
  DiagnosticsCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('诊断')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.probeText)
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_hint'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.expandDiagnostics ? 90 : 0 })
          .animation({ curve: this.foldCurve })
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
          this.expandDiagnostics = !this.expandDiagnostics;
        });
      })

      if (this.expandDiagnostics) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('重新探测')
              .fontSize(13)
              .fontColor($r('app.color.accent'))
              .height(40)
              .padding({ left: 14, right: 14 })
              .borderRadius(20)
              .backgroundColor($r('app.color.btn_unselected_bg'))
              .opacity(this.probing ? 0.35 : 1)
              .onClick(() => {
                if (!this.probing) {
                  this.svc.probeNow();
                }
              })
          }
          .width('100%')
          .height(50)

          Text(this.probeText)
            .fontSize(12)
            .fontColor(this.probing ? $r('app.color.text_warn') : $r('app.color.text_secondary'))
            .width('100%')

          Text('运行日志')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4 })

          Scroll() {
            Column() {
              Text(this.logText.length > 0 ? this.logText : '暂无日志')
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .fontFamily('monospace')
                .textAlign(TextAlign.Start)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .height(120)
          .width('100%')
          .backgroundColor($r('app.color.log_bg'))
          .borderRadius(10)
          .padding(8)
          .scrollable(ScrollDirection.Vertical)
          .nestedScroll({
            scrollForward: NestedScrollMode.SELF_FIRST,
            scrollBackward: NestedScrollMode.SELF_FIRST
          })
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  @Builder
  AboutCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('关于')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`VoxBridge v${this.appVersion}`)
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_hint'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .rotate({ angle: this.expandAbout ? 90 : 0 })
          .animation({ curve: this.foldCurve })
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, (): void => {
          this.expandAbout = !this.expandAbout;
        });
      })

      if (this.expandAbout) {
        Text('手机 → PC 网络麦克风 · PCM over TCP · DeepFilterNet3 端侧降噪')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
          .transition(TransitionEffect.OPACITY.animation({ curve: this.foldCurve }))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(15)
    .backgroundBlurStyle(this.matCardBlur())
    .backgroundColor(this.matCardColor())
    .border({ width: 1, color: $r('app.color.mat_line') })
    .systemMaterial(Mat.card)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.AppearanceCard()
        this.StreamingCard()
        this.DeviceCard()
        this.DiagnosticsCard()
        this.AboutCard()
      }
      .width('100%')
      .constraintSize({ maxWidth: 500 })
      .padding({ left: 20, right: 20, top: this.topPad + 20, bottom: this.bottomPad + 100 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
  }
}
