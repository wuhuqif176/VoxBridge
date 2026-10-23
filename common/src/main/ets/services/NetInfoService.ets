import { connection } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MicLogger } from '../utils/Logger';

// 说明: 网络快照（F4 口径）：online=是否有默认网络；bearer ∈ wifi/cellular/ethernet/unknown；
// quality ∈ good/fair/weak（优/中/弱徽章）。netOnline/netBearer/netQuality AppStorage 写入由 StreamService 消费回调完成。
export interface NetSnapshot {
  online: boolean;
  bearer: string;
  quality: string;
}

// 说明: 网络质量评分（connect.html 规格2）：WiFi 按 RSSI（≥-60 优 / ≥-75 中 / 更差 弱）；
// 以太网稳定评优；蜂窝无信号强度来源保守评中；读不到信息时保守评中。
// 队列水位/丢弃率融合在 StreamService（F4/3），本类只负责 net 侧观测。
export class NetInfoService {
  private static instance: NetInfoService | null = null;
  private static readonly WIFI_RSSI_GOOD: number = -60;
  private static readonly WIFI_RSSI_WEAK: number = -75;
  private static readonly POLL_INTERVAL_MS: number = 5000;

  private netConn: connection.NetConnection | null = null;
  private listener: (snapshot: NetSnapshot) => void = (): void => {};
  private pollTimer: number = -1;
  private lastSnapshot: NetSnapshot | null = null;

  static getInstance(): NetInfoService {
    if (NetInfoService.instance === null) {
      NetInfoService.instance = new NetInfoService();
    }
    return NetInfoService.instance;
  }

  async getLocalIp(): Promise<string> {
    try {
      const netHandle = await connection.getDefaultNet();
      const properties = await connection.getConnectionProperties(netHandle);
      const address = this.pickAddress(properties);
      if (address !== null) {
        MicLogger.info(`本机网络地址: ${address}`);
      }
      return address !== null ? address : '未连接网络';
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`获取本机网络信息失败: ${err.message}`);
      return '未连接网络';
    }
  }

  // 说明: 订阅网络状态（事件 + 5s RSSI 轮询双驱动，快照变化才回调），重复调用只换 listener 不会重复建连。
  startWatch(listener: (snapshot: NetSnapshot) => void): void {
    this.listener = listener;
    if (this.netConn === null) {
      this.netConn = connection.createNetConnection();
      this.netConn.on('netAvailable', (): void => {
        this.probeAndReport();
      });
      this.netConn.on('netLost', (): void => {
        this.reportOffline();
      });
      this.netConn.on('netUnavailable', (): void => {
        this.reportOffline();
      });
      this.netConn.on('netCapabilitiesChange', (): void => {
        this.probeAndReport();
      });
      this.netConn.register((error: BusinessError): void => {
        if (error) {
          MicLogger.warn(`网络监听注册失败: ${error.message}`);
        }
      });
      this.pollTimer = setInterval((): void => {
        this.probeAndReport();
      }, NetInfoService.POLL_INTERVAL_MS);
    }
    this.probeAndReport();
  }

  stopWatch(): void {
    this.listener = (): void => {};
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    const conn = this.netConn;
    if (conn !== null) {
      conn.unregister((error: BusinessError): void => {
        if (error) {
          MicLogger.warn(`网络监听注销失败: ${error.message}`);
        }
      });
      this.netConn = null;
    }
    this.lastSnapshot = null;
  }

  private async probeAndReport(): Promise<void> {
    const snapshot = await this.probe();
    this.report(snapshot);
  }

  private async probe(): Promise<NetSnapshot> {
    try {
      const netHandle = await connection.getDefaultNet();
      const capabilities = await connection.getNetCapabilities(netHandle);
      const bearer = this.bearerName(capabilities.bearerTypes);
      const quality = await this.rateQuality(bearer);
      return { online: true, bearer: bearer, quality: quality };
    } catch (error) {
      const err = error as BusinessError;
      MicLogger.warn(`网络探测失败: ${err.message}`);
      return { online: false, bearer: 'unknown', quality: 'weak' };
    }
  }

  private bearerName(bearerTypes: Array<connection.NetBearType>): string {
    for (let i = 0; i < bearerTypes.length; i++) {
      const bearer = bearerTypes[i];
      if (bearer === connection.NetBearType.BEARER_WIFI) {
        return 'wifi';
      }
      if (bearer === connection.NetBearType.BEARER_CELLULAR) {
        return 'cellular';
      }
      if (bearer === connection.NetBearType.BEARER_ETHERNET) {
        return 'ethernet';
      }
    }
    return 'unknown';
  }

  private async rateQuality(bearer: string): Promise<string> {
    if (bearer === 'wifi') {
      try {
        const linkedInfo = await wifiManager.getLinkedInfo();
        if (linkedInfo.rssi >= NetInfoService.WIFI_RSSI_GOOD) {
          return 'good';
        }
        if (linkedInfo.rssi >= NetInfoService.WIFI_RSSI_WEAK) {
          return 'fair';
        }
        return 'weak';
      } catch (error) {
        return 'fair';
      }
    }
    if (bearer === 'ethernet') {
      return 'good';
    }
    return 'fair';
  }

  private reportOffline(): void {
    this.report({ online: false, bearer: 'unknown', quality: 'weak' });
  }

  private report(snapshot: NetSnapshot): void {
    const last = this.lastSnapshot;
    if (last !== null && last.online === snapshot.online && last.bearer === snapshot.bearer &&
      last.quality === snapshot.quality) {
      return;
    }
    this.lastSnapshot = snapshot;
    MicLogger.info(`网络状态: online=${snapshot.online} bearer=${snapshot.bearer} quality=${snapshot.quality}`);
    this.listener(snapshot);
  }

  private pickAddress(properties: connection.ConnectionProperties): string | null {
    const linkAddresses = properties.linkAddresses;
    let ipv6: string | null = null;
    for (let i = 0; i < linkAddresses.length; i++) {
      const address = linkAddresses[i].address.address;
      if (address.includes('.')) {
        return address;
      }
      if (ipv6 === null && address.includes(':')) {
        ipv6 = address;
      }
    }
    return ipv6;
  }
}
