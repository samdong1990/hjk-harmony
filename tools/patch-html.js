#!/usr/bin/env node
/**
 * 把 data.json 内联进 index.html，生成鸿蒙 Web 组件可用的单文件页面。
 *
 * 为什么需要这一步：
 *   原 Android 版用 WebViewAssetLoader 起了一个 https://appassets.androidplatform.net 的虚拟站点，
 *   页面里的 fetch('data.json') 能正常拿到数据。
 *   鸿蒙的 Web 组件用 $rawfile('index.html') 加载时页面在 resource://rawfile/ 下，
 *   fetch 本地 json 不可靠（协议不支持 / CORS），所以直接把数据内联成 window.__HJK_DATA__。
 *
 * 用法（工程根目录下执行，Node 用 DevEco Studio 自带的即可）：
 *   node tools/patch-html.js
 *
 * 幂等：每次都从 tools/index.orig.html（原始页面）重新生成，可反复执行。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RAW_DIR = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile');
const ORIG_HTML = path.join(__dirname, 'index.orig.html');
const DATA_JSON = path.join(RAW_DIR, 'data.json');
const OUT_HTML = path.join(RAW_DIR, 'index.html');

function fail(msg) {
  console.error('[patch-html] ' + msg);
  process.exit(1);
}

if (!fs.existsSync(ORIG_HTML)) fail('缺少 tools/index.orig.html');
if (!fs.existsSync(DATA_JSON)) fail('缺少 entry/src/main/resources/rawfile/data.json');

let html = fs.readFileSync(ORIG_HTML, 'utf8');
const data = JSON.parse(fs.readFileSync(DATA_JSON, 'utf8'));

// ---------- 1. 内联数据 + 外链拦截层 ----------
const rawJson = JSON.stringify(data)
  // 防止 JSON 字符串里出现 </script> 提前闭合脚本块
  .replace(/</g, '\\u003c')
  .replace(/\u2028/g, '\\u2028')
  .replace(/\u2029/g, '\\u2029');

const INJECT = `</script>

<script>
/* ==========================================================================
   鸿蒙 HAP 移植层（由 tools/patch-html.js 注入，原页面无此段）
   1) 内联 data.json —— Web 组件在 resource://rawfile/ 下无法 fetch 本地 json
   2) 外链统一交给原生用系统浏览器打开（避免 target=_blank 在 WebView 里无响应）
   ========================================================================== */
window.__HJK_DATA__ = ${rawJson};

(function () {
  'use strict';

  /* 外链拦截：http(s) / mailto / tel 一律走系统浏览器 */
  document.addEventListener('click', function (ev) {
    var el = ev.target;
    while (el && el !== document) {
      if (el.tagName === 'A' && el.getAttribute) {
        var href = el.getAttribute('href') || '';
        if (/^(https?:|mailto:|tel:)/i.test(href) && !el.hasAttribute('download')) {
          ev.preventDefault();
          ev.stopPropagation();
          if (window.hjkNative && typeof window.hjkNative.openUrl === 'function') {
            window.hjkNative.openUrl(href);
          } else {
            window.open(href, '_self');
          }
          return;
        }
        break;
      }
      el = el.parentNode;
    }
  }, true);

  /* 兜底：任何 window.open 也转给原生 */
  var rawOpen = window.open;
  window.open = function (url) {
    if (url && /^(https?:|mailto:|tel:)/i.test(url) &&
        window.hjkNative && typeof window.hjkNative.openUrl === 'function') {
      window.hjkNative.openUrl(url);
      return null;
    }
    return rawOpen ? rawOpen.apply(window, arguments) : null;
  };
})();
</script>

<script>
(function () {
  'use strict';

  var DATA_URL = 'data.json';`;

const ANCHOR_A = `</script>

<script>
(function () {
  'use strict';

  var DATA_URL = 'data.json';`;

if (html.split(ANCHOR_A).length - 1 !== 1) {
  fail('锚点 A 不唯一，原始页面可能已被改动，请核对 tools/index.orig.html');
}
html = html.replace(ANCHOR_A, INJECT);

// ---------- 2. 数据加载：优先用内联数据 ----------
const ANCHOR_B = `  fetch(DATA_URL, { cache: 'no-store' })
    .then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + r.statusText);
      return r.json();
    })
    .then(apply)
    .catch(showLoadError);
})();`;

const NEW_B = `  if (window.__HJK_DATA__) {
    /* 鸿蒙 HAP：数据已内联，直接应用 */
    try {
      apply(window.__HJK_DATA__);
    } catch (e) {
      showLoadError(e);
    }
  } else {
    fetch(DATA_URL, { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + r.statusText);
        return r.json();
      })
      .then(apply)
      .catch(showLoadError);
  }
})();`;

if (html.split(ANCHOR_B).length - 1 !== 1) {
  fail('锚点 B 不唯一，原始页面可能已被改动，请核对 tools/index.orig.html');
}
html = html.replace(ANCHOR_B, NEW_B);

// ---------- 3. 复制：优先走原生剪贴板 ----------
const ANCHOR_C = `    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done).catch(fallback);
    else fallback();`;

const NEW_C = `    /* 鸿蒙 HAP：优先用原生剪贴板（resource:// 下 isSecureContext 为 false，execCommand 不可靠） */
    if (window.hjkNative && typeof window.hjkNative.copyText === 'function') {
      try {
        window.hjkNative.copyText(text);
        done();
        return;
      } catch (err) {}
    }
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done).catch(fallback);
    else fallback();`;

if (html.split(ANCHOR_C).length - 1 !== 1) {
  fail('锚点 C 不唯一，原始页面可能已被改动，请核对 tools/index.orig.html');
}
html = html.replace(ANCHOR_C, NEW_C);

// ---------- 输出 ----------
fs.writeFileSync(OUT_HTML, html, 'utf8');
console.log('[patch-html] 已生成 ' + path.relative(ROOT, OUT_HTML));
console.log('  原始页面  ' + Buffer.byteLength(fs.readFileSync(ORIG_HTML)) + ' B');
console.log('  内联数据  ' + Buffer.byteLength(rawJson) + ' B（' + data.items.length + ' 条接口 / ' +
  data.groups.length + ' 个分组）');
console.log('  输出页面  ' + Buffer.byteLength(html) + ' B');
