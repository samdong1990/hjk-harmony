# 接口大全 · HarmonyOS（HAP）移植工程

由 `接口大全-2.0.0.apk`（包名 `com.w2a.cx62`，versionCode 20）移植而来。

原版是一个**纯 WebView 套壳**：`MainActivity` 用 `WebViewAssetLoader` 把 `assets/index.html` 挂到
`https://appassets.androidplatform.net` 上加载，数据在 `assets/data.json`（1692 条接口 / 15 个分组），
持久化全部走 `localStorage`，dex 里没有 `addJavascriptInterface` —— H5 与原生零耦合。

所以移植到鸿蒙不需要重写业务逻辑：一个 ArkTS 页面 + `Web` 组件加载 rawfile 即可，原生侧只补
「外链用系统浏览器打开」「写系统剪贴板」两件事。

---

## 一、工程结构

```
接口大全-hap/
├── AppScope/
│   ├── app.json5                        bundleName=com.w2a.cx62，versionName=2.0.0
│   └── resources/base/media/app_icon.png  应用图标（取自 apk 的 ic_brand.png）
├── build-profile.json5                  单产品 default，compatibleSdkVersion 6.1.1(24)
├── hvigorfile.ts
├── hvigor/hvigor-config.json5
├── oh-package.json5
├── tools/
│   ├── index.orig.html                  原始 H5 页面（apk 里那份，未改动）
│   └── patch-html.js                    把 data.json 内联进页面，生成 rawfile/index.html
└── entry/
    ├── build-profile.json5
    ├── hvigorfile.ts
    ├── oh-package.json5
    └── src/main/
        ├── module.json5                 INTERNET / GET_NETWORK_INFO
        ├── ets/
        │   ├── entryability/EntryAbility.ets
        │   └── pages/Index.ets          Web 容器 + 原生桥 + 悬浮球
        └── resources/
            ├── base/element/{string,color}.json
            ├── base/media/startIcon.png
            ├── base/profile/main_pages.json
            └── rawfile/
                ├── index.html           ★ 已内联数据（373 KB）
                ├── data.json            数据源备份（改了它要重新生成 index.html）
                └── preset_bookmarks.json
```

---

## 二、怎么打包

### 方式 1：DevEco Studio（推荐）

1. `File → Open`，选本目录 `接口大全-hap`
2. 首次打开会提示同步，等 `Sync` 完成
3. 配签名：`File → Project Structure → Signing Configs` → 勾 **Automatically generate signature**
   （需要登录华为开发者账号，自动生成 `.p12/.cer/.p7b` 并回写到 `build-profile.json5`）
4. 连真机或开模拟器，点 ▶ 运行；或 `Build → Build Hap(s)/APP(s) → Build Hap(s)` 出包
5. 产物：`entry/build/default/outputs/default/entry-default-signed.hap`

### 方式 2：命令行

```bash
# Windows
hvigorw.bat assembleHap --mode project -p product=default -p buildMode=debug --no-daemon

# macOS / Linux
./hvigorw assembleHap --mode project -p product=default -p buildMode=debug --no-daemon
```

签名必须先在 DevEco 里配好（命令行不生成签名材料），否则只会出未签名包，装不上真机。

> 本工程 `build-profile.json5` 里 `signingConfigs` 是空的，**没有内置任何证书**，签名材料需要你自己生成。

---

## 三、改数据 / 改应用名

### 换接口数据

数据是**内联**在 `index.html` 里的（原因见下一节），所以：

```bash
# 1. 替换数据源
#    把新的 data.json 覆盖到 entry/src/main/resources/rawfile/data.json

# 2. 重新生成页面（Node 用 DevEco 自带的就行，无需 npm install）
node tools/patch-html.js

# 3. 重新打包
```

脚本是幂等的，每次都从 `tools/index.orig.html` 重新生成，可以反复跑。
`data.json` 结构：`{version, site, groups[], weights, rotate, items[]}`，原样沿用即可。

### 改应用名

- `AppScope/resources/base/element/string.json` → `app_name`
- `entry/src/main/resources/base/element/string.json` → `EntryAbility_label`

### 改包名

`AppScope/app.json5` → `bundleName`（当前沿用原包的 `com.w2a.cx62`，上架前建议换成自己的域名倒写）。

---

## 四、为什么要把 data.json 内联

原版靠 `WebViewAssetLoader` 起了一个虚拟 https 站点，页面里 `fetch('data.json')` 能正常拿到数据。

鸿蒙的 `Web({ src: $rawfile('index.html') })` 加载后页面在 `resource://rawfile/` 协议下，
`fetch()` 本地文件不可靠（协议不支持 / 被 CORS 拦），会直接落到页面自带的
「请确认 data.json 与 index.html 在同一目录，且通过本地服务器访问」错误页。

所以 `tools/patch-html.js` 把 json 变成 `window.__HJK_DATA__ = {...}` 内联进页面，
并把末尾的 `fetch(DATA_URL)` 改成「有内联数据就直接用」。JSON 里的 `<` 全部转成 `\u003c`，
避免字符串里出现 `</script>` 把脚本块提前闭合。

代价是 `index.html` 从 67 KB 变成 373 KB，对启动速度没有可感知影响。

---

## 五、原生能力对照

| 原 Android 实现 | 鸿蒙实现 | 位置 |
| --- | --- | --- |
| `WebViewAssetLoader` 加载 `assets/index.html` | `Web({ src: $rawfile('index.html') })` | `Index.ets` |
| `fetch('data.json')` | 内联 `window.__HJK_DATA__` | `tools/patch-html.js` |
| `domStorageEnabled` | `.domStorageAccess(true)` | `Index.ets` |
| `DownloadListener` + `DownloadManager` | `.onDownloadStart()` → 交给系统浏览器下载 | `Index.ets` |
| `Intent(ACTION_VIEW)` 打开外链 | `hjkNative.openUrl()` → `startAbility(viewData)` | `Index.ets` + H5 点击拦截 |
| `ClipboardManager` | `hjkNative.copyText()` → `pasteboard` | `Index.ets` |
| 返回键「再按一次退出」 | `onBackPress()` + 2 秒内双击判定 | `Index.ets` |
| 原生悬浮球菜单 | 右下角悬浮球 + `bindMenu`（刷新 / 清缓存刷新 / 回到顶部） | `Index.ets` |
| `SharedPreferences` 存书签/配置 | H5 自己的 `localStorage`（已开 DOM 存储） | — |

H5 侧只改了 3 处（都在 `patch-html.js` 里可查）：
1. 注入 `window.__HJK_DATA__` + 外链点击拦截
2. 数据加载优先用内联数据
3. `copyText()` 优先走原生剪贴板

---

## 六、和原版的差异

- **书签/收藏**：原版是原生 `SharedPreferences` + 书签对话框。鸿蒙这边没有复刻 —— 应用本身是
  单页本地数据，没有「当前网址」概念，收藏意义不大。H5 自己的检测缓存照常存在 `localStorage`。
- **分享到微信/QQ**：原版靠 `Intent` 分享链接，同样因为没有「当前网址」而省略。
  页面里点具体接口的外链会用系统浏览器打开，浏览器里可以自行分享。
- **下载**：原版用 `DownloadManager` 下到公共下载目录；鸿蒙这边 `onDownloadStart` 触发后转交系统浏览器，
  由浏览器下到「下载」目录，效果等价。
- **深色模式**：H5 自带 `prefers-color-scheme: dark` 适配，跟随系统；ArkUI 那层只有加载时的背景色固定浅色。

---

## 七、已知注意点

- **接口检测需要联网**：H5 会对每个接口发 `no-cors` 探测请求，部分接口带 `http://`，
  所以 `mixedMode(MixedMode.All)` 必须保留，否则检测全挂。
- **CORS 代理**：H5 内置 `api.allorigins.win` / `api.codetabs.com` 两个公共代理做兜底探测，
  这两个服务偶尔抽风属于原版行为，不是移植引入的问题。
- **赞助二维码**是外链图 `https://0.wudaozhe.net/vip/zsm.jpg`，离线时显示占位图。
- 本工程**没有**在真机上跑过（构建环境无 HarmonyOS SDK），首次打开如果 `index.html` 白屏，
  先看 `hdc hilog | grep HjkApp` 里的 `resource error` 日志。
