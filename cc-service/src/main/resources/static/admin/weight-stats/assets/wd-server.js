// 管理后台数据接线：拉取真实体重记录（health_sample）覆盖 data.js 快照。
// 用同步 XHR 保证脚本顺序（data.js → wd-server.js → live.js），
// 任何失败（未登录/网络/解析）都静默回退到快照数据。
(function () {
  'use strict';
  // 个人目标体重（kg）。null = 用 data.js 快照里的 targetKg；要换目标在这里改。
  var TARGET_KG = null;
  try {
    var token = localStorage.getItem('cc_admin_token');
    if (!token) return;

    var records = [];
    var page = 1;
    var size = 100;
    var total = 0;
    do {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', '/api/admin/health/records?page=' + page + '&size=' + size, false);
      xhr.setRequestHeader('Authorization', 'Bearer ' + token);
      xhr.send(null);
      if (xhr.status !== 200) return;
      var data = JSON.parse(xhr.responseText);
      total = data.total || 0;
      var rows = data.records || [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (r.kind !== 'weight' || r.value == null) continue;
        records.push([fmtLocal(r.recordedAt), r.value]);
      }
      page += 1;
    } while (records.length < total && page < 60);

    if (!records.length) return;
    records.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });

    var WD = window.WD = window.WD || {};
    WD.records = records;
    WD.meta = WD.meta || {};
    WD.meta.count = total;
    WD.meta.source = 'server';
    WD.meta.exportedAt = fmtLocal(new Date().toISOString());
    WD.summary = WD.summary || {};
    if (TARGET_KG) WD.summary.targetKg = TARGET_KG;
    // summary.targetKg 与 meta.heightCM 是个人常量，保留 data.js 快照里的值
  } catch (e) {
    /* 静默回退快照 */
  }

  // "2026-11-10T23:53:00Z" / Jackson 数组 → 本地 "YYYY-MM-DDTHH:MM"（live.js 的 parseLocal 口径）
  function fmtLocal(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return String(iso || '').slice(0, 16);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
         + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
})();
