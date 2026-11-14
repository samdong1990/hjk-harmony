import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HjkApp';

/**
 * 注入到 H5 的原生桥，对应 index.html 里的 window.hjkNative。
 *
 * 原 Android 版是纯 WebView 套壳、没有 addJavascriptInterface，H5 与原生零耦合；
 * 鸿蒙这边只需要补两个能力：
 *   1. 外链用系统浏览器打开（WebView 里 target=_blank 没有新窗口，点了没反应）
 *   2. 写系统剪贴板（resource:// 下 isSecureContext 为 false，navigator.clipboard 不可用）
 *
 * 方法保持同步签名，避免 H5 侧还要处理 Promise。
 */
class HjkNativeBridge {
  private ctx: common.UIAbilityContext | undefined = undefined;

  setContext(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  /** 用系统浏览器打开 http(s) / mailto / tel 链接。 */
  openUrl(url: string): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined || url.length === 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'openUrl: %{public}s', url);
    try {
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      }).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'openUrl failed: %{public}d %{public}s', err.code, err.message);
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'openUrl throw: %{public}d %{public}s', e.code, e.message);
    }
  }

  /** 写系统剪贴板。 */
  copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'copyText failed: %{public}d %{public}s', err.code, err.message);
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'copyText throw: %{public}d %{public}s', e.code, e.message);
    }
  }
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: HjkNativeBridge = new HjkNativeBridge();
  /** 0~100，顶部细进度条 */
  @State loadProgress: number = 0;
  @State showProgress: boolean = true;
  /** rawfile 主文档加载失败时盖一层兜底页（Web 常驻，不销毁 controller） */
  @State loadFailed: boolean = false;
  private lastBackAt: number = 0;

  aboutToAppear(): void {
    this.bridge.setContext(getContext(this) as common.UIAbilityContext);
  }

  /**
   * 返回键：WebView 有历史就后退；已经在首屏则「再按一次退出」。
   * 原 apk 的 MainActivity 就是这套行为。
   */
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'accessBackward failed: %{public}s', JSON.stringify(err));
    }
    const now: number = Date.now();
    if (now - this.lastBackAt < 2000) {
      // 交给系统处理 → 退出应用
      return false;
    }
    this.lastBackAt = now;
    this.getUIContext().getPromptAction().showToast({ message: '再按一次退出', duration: 1500 });
    return true;
  }

  /** 清掉 H5 存在 localStorage 里的检测缓存，再整页重载。 */
  private clearCacheAndReload(): void {
    this.controller.runJavaScript(
      "try{localStorage.removeItem('hjk_check_cache_v2');" +
        "localStorage.removeItem('hjk_check_session_v1');}catch(e){}" +
        "location.reload();"
    ).catch((err: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'runJavaScript failed: %{public}d %{public}s', err.code, err.message);
    });
  }

  private scrollToTop(): void {
    this.controller.runJavaScript("window.scrollTo({top:0,behavior:'smooth'});")
      .catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'scrollToTop failed: %{public}d %{public}s', err.code, err.message);
      });
  }

  /**
   * 右下角悬浮球，替代原 apk 的原生悬浮球菜单。
   * H5 的 body 已经留了 90px 下边距，位置正好。
   */
  @Builder
  FloatingMenu() {
    Text('≡')
      .fontSize(22)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .width(46)
      .height(46)
      .borderRadius(23)
      .textAlign(TextAlign.Center)
      .backgroundColor('#D9E64A19')
      .shadow({ radius: 14, color: '#33000000', offsetY: 3 })
      .margin({ right: 14, bottom: 24 })
      .bindMenu([
        {
          value: '刷新页面',
          action: (): void => {
            this.controller.refresh();
          }
        },
        {
          value: '清除检测缓存并刷新',
          action: (): void => {
            this.clearCacheAndReload();
          }
        },
        {
          value: '回到顶部',
          action: (): void => {
            this.scrollToTop();
          }
        }
      ])
  }

  @Builder
  LoadFailedView() {
    Column({ space: 14 }) {
      Text('页面加载失败')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#171A1F')
      Text('内置页面没能加载，请重试或重新安装应用')
        .fontSize(13)
        .fontColor('#6B7280')
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Button('重新加载')
        .fontSize(14)
        .height(38)
        .padding({ left: 24, right: 24 })
        .backgroundColor('#E64A19')
        .fontColor(Color.White)
        .onClick((): void => {
          this.loadFailed = false;
          this.loadProgress = 0;
          this.showProgress = true;
          this.controller.refresh();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F4F5F7')
  }

  build() {
    Column() {
      if (this.showProgress) {
        Progress({ value: this.loadProgress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color('#E64A19')
          .backgroundColor('#F4F5F7')
      }

      Stack({ alignContent: Alignment.BottomEnd }) {
        Web({ src: $rawfile('index.html'), controller: this.controller })
          .width('100%')
          .height('100%')
          // H5 用 localStorage 存检测缓存、sessionStorage 判断新会话，必须开 DOM 存储
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .fileAccess(true)
          .imageAccess(true)
          // 赞助二维码、logo 都是 https 外链图
          .onlineImageAccess(true)
          .databaseAccess(true)
          // H5 检测接口时会用 http 地址探测，页面本身在 resource:// 下，放开混合内容
          .mixedMode(MixedMode.All)
          .geolocationAccess(false)
          .multiWindowAccess(false)
          .javaScriptProxy({
            object: this.bridge,
            name: 'hjkNative',
            methodList: ['openUrl', 'copyText'],
            controller: this.controller
          })
          .onPageBegin((): void => {
            this.loadFailed = false;
            this.showProgress = true;
          })
          .onProgressChange((event) => {
            this.loadProgress = event.newProgress;
            if (event.newProgress >= 100) {
              this.showProgress = false;
            }
          })
          .onErrorReceive((event: OnErrorReceiveEvent): void => {
            const err: WebResourceError = event.error;
            hilog.error(DOMAIN, TAG, 'resource error %{public}d %{public}s',
              err.getErrorCode(), err.getErrorInfo());
            // 只有主文档失败才盖兜底页；子资源（图片、探测请求）失败交给 H5 自己处理
            const reqUrl: string = event.request.getRequestUrl();
            if (reqUrl.indexOf('index.html') >= 0) {
              this.loadFailed = true;
            }
          })
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent): void => {
            const resp: WebResourceResponse = event.response;
            hilog.warn(DOMAIN, TAG, 'http error %{public}d %{public}s',
              resp.getResponseCode(), resp.getReasonMessage());
          })
          .onDownloadStart((event: OnDownloadStartEvent): void => {
            // H5 里带 download 属性的链接（对应原版 DownloadManager）统一交给系统浏览器，
            // 浏览器会自己下到「下载」目录，用户能直接在文件管理里找到。
            if (event.url.length > 0) {
              this.bridge.openUrl(event.url);
              this.getUIContext().getPromptAction().showToast({ message: '已交给浏览器下载', duration: 2000 });
            }
          })
          .onConsole((event: OnConsoleEvent): boolean => {
            const msg: ConsoleMessage = event.message;
            if (msg.getMessageLevel() === MessageLevel.Error) {
              const text: string = msg.getMessage();
              hilog.error(DOMAIN, TAG, '[js] %{public}s', text.substring(0, Math.min(text.length, 300)));
            }
            return false;
          })

        if (this.loadFailed) {
          this.LoadFailedView()
        }

        if (!this.loadFailed) {
          this.FloatingMenu()
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F5F7')
  }
}
