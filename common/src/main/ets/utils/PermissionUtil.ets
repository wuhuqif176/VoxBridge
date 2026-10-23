import { abilityAccessCtrl, bundleManager, common, Permissions, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from './Logger';

export class PermissionUtil {
  static hasMicrophone(): boolean {
    try {
      const bundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = bundleInfo.appInfo.accessTokenId;
      const atManager = abilityAccessCtrl.createAtManager();
      const status = atManager.checkAccessTokenSync(tokenId, 'ohos.permission.MICROPHONE');
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return false;
    }
  }

  static async requestMicrophone(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = ['ohos.permission.MICROPHONE'];
      const result = await atManager.requestPermissionsFromUser(context, permissions);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        MicLogger.info('麦克风权限已授权');
        return true;
      }
      MicLogger.warn('麦克风权限被拒绝');
      return false;
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.error(`申请麦克风权限异常: code=${err.code} ${err.message}`);
      return false;
    }
  }

  static openAppPermissionSettings(context: common.UIAbilityContext): void {
    const want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      uri: 'application_info_entry',
      parameters: {
        'pushParams': 'com.example.harmonymic'
      }
    };
    context.startAbility(want).then(() => {
      MicLogger.info('已跳转应用设置页');
    }).catch((error: BusinessError) => {
      MicLogger.error(`跳转设置页失败: ${error.message}`);
    });
  }
}
