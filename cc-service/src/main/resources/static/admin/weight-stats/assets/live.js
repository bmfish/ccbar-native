(function () {
  'use strict';

  var WD = window.WD;
  if (!WD || !WD.records || !WD.records.length) return;

  // ---------- 工具 ----------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function keyOf(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); x.setHours(0, 0, 0, 0); return x; }
  function mean(a) { return a.reduce(function (s, v) { return s + v; }, 0) / a.length; }
  function parseLocal(s) {
    var a = s.split('T'), dp = a[0].split('-'), tp = a[1].split(':');
    return new Date(+dp[0], +dp[1] - 1, +dp[2], +tp[0], +tp[1]);
  }
  function fmtYMD(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function fmtYMDHM(d) { return fmtYMD(d) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function fmtMD(d) { return (d.getMonth() + 1) + '月' + d.getDate() + '日'; }
  function num(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','); }
  function set(id, text) { var el = document.getElementById(id); if (el) el.textContent = text; }
  function setHTML(id, html) { var el = document.getElementById(id); if (el) el.innerHTML = html; }
  function setClass(id, cls) { var el = document.getElementById(id); if (el) el.className = cls; }
  function countUp(id, target, decimals, duration) {
    var el = document.getElementById(id);
    if (!el) return;
    var finalText = target.toFixed(decimals);
    // 不可见时 rAF 会被节流：先把最终值写上，动画只是锦上添花
    if (!window.requestAnimationFrame || document.hidden) {
      el.textContent = finalText;
      return;
    }
    var from = parseFloat(String(el.textContent).replace(/[^\d.\-]/g, ''));
    if (isNaN(from)) from = target;
    el.textContent = finalText;
    var start = null;
    function step(ts) {
      if (start == null) start = ts;
      var p = Math.min(1, (ts - start) / duration);
      var e = 1 - Math.pow(1 - p, 3);
      el.textContent = (from + (target - from) * e).toFixed(decimals);
      if (p < 1 && !document.hidden) requestAnimationFrame(step);
      else el.textContent = finalText;
    }
    requestAnimationFrame(step);
  }

  // ---------- 数据整理 ----------
  var recs = WD.records.map(function (r) { return { t: parseLocal(r[0]), kg: r[1] }; })
    .filter(function (r) { return r.kg > 30 && r.kg < 300; })
    .sort(function (a, b) { return a.t - b.t; });
  if (!recs.length) return;

  var byDayRaw = {};
  recs.forEach(function (r) {
    var k = keyOf(r.t);
    (byDayRaw[k] = byDayRaw[k] || []).push(r.kg);
  });
  var daily = Object.keys(byDayRaw).sort().map(function (k) {
    var p = k.split('-');
    return { k: k, t: new Date(+p[0], +p[1] - 1, +p[2], 12, 0), kg: mean(byDayRaw[k]) };
  });
  var byDay = {};
  daily.forEach(function (d) { byDay[d.k] = d; });
  var last = daily[daily.length - 1];
  var latest = recs[recs.length - 1];
  var targetKg = (WD.summary && WD.summary.targetKg) || 99.7;
  var height = (WD.meta && WD.meta.heightCM) || 173;
  var bmi = latest.kg / Math.pow(height / 100, 2);

  function windowDays(n, offset) {
    var end = addDays(last.t, -n * (offset || 0) + 1);
    var start = addDays(end, -n);
    return daily.filter(function (d) { return d.t >= start && d.t < end; });
  }
  function avgKg(ds) { return ds.length ? mean(ds.map(function (d) { return d.kg; })) : null; }
  function signedJin(kg) { return (kg >= 0 ? '+' : '−') + Math.abs(kg * 2).toFixed(1) + ' 斤'; }

  var win = {};
  [7, 30, 90].forEach(function (n) {
    var cur = windowDays(n, 0), prev = windowDays(n, 1);
    var c = avgKg(cur), p = avgKg(prev);
    win[n] = { cur: cur, prev: prev, c: c, p: p, delta: (c != null && p != null) ? c - p : null };
  });

  // ---------- 页脚 ----------
  set('insightCount', '基于 ' + num(recs.length) + ' 条记录的统计结果');

  // ---------- Hero ----------
  countUp('heroNum', latest.kg * 2, 1, 900);
  set('heroSub', latest.kg.toFixed(2) + ' kg · ' + fmtYMDHM(latest.t));

  if (win[30].delta != null) {
    setHTML('chip30', '<i class="c1"></i>近 30 天 ' + signedJin(win[30].delta));
  }
  if (win[7].delta != null) {
    setHTML('chip7', '<i class="c2"></i>近 7 天 ' + signedJin(win[7].delta));
  }

  // 周均与平台判断
  function weekStart(d) {
    var x = new Date(d);
    x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
    x.setHours(0, 0, 0, 0);
    return x;
  }
  var weekMap = {};
  daily.forEach(function (d) {
    var k = weekStart(d.t).getTime();
    (weekMap[k] = weekMap[k] || []).push(d.kg);
  });
  var weekKeys = Object.keys(weekMap).map(Number).sort(function (a, b) { return a - b; });
  var weekVals = weekKeys.map(function (k) { return mean(weekMap[k]); });
  var recentWeeks = weekVals.slice(-12);

  var flatWeeks = 0;
  if (recentWeeks.length >= 2) {
    var base = mean(recentWeeks.slice(-3));
    for (var i = recentWeeks.length - 1; i >= 0; i--) {
      if (Math.abs(recentWeeks[i] - base) <= 0.6) flatWeeks++;
      else break;
    }
    set('chipState', flatWeeks >= 2 ? '平台期 · 横盘 ' + flatWeeks + ' 周' : '波动期');
  }

  // 页头信息
  var mastParts = [];
  if (win[30].delta != null) mastParts.push('近 30 天 ' + signedJin(win[30].delta));
  mastParts.push(flatWeeks >= 2 ? '平台期第 ' + flatWeeks + ' 周' : '波动期');
  set('mastSub', mastParts.join(' · '));
  set('syncTime', (latest.t.getMonth() + 1) + '-' + pad(latest.t.getDate()) + ' ' +
      pad(latest.t.getHours()) + ':' + pad(latest.t.getMinutes()));
  var coverHeader = Math.round(daily.filter(function (d) { return d.t >= addDays(last.t, -119); }).length / 120 * 100);
  set('syncMeta', num(recs.length) + ' 条记录 · 近 120 天覆盖 ' + coverHeader + '%');
  var heatDays = daily.filter(function (d) { return d.t >= addDays(last.t, -83); }).length;
  set('heatMeta', '有记录 ' + heatDays + ' 天 / 84 天');

  // 目标进度：从近 12 个月月均峰值算起
  var monthMap = {};
  daily.forEach(function (d) {
    var k = d.t.getFullYear() + '-' + pad(d.t.getMonth() + 1);
    (monthMap[k] = monthMap[k] || []).push(d.kg);
  });
  var yearAgo = addDays(last.t, -364);
  var peakKeys = Object.keys(monthMap).filter(function (k) {
    var p = k.split('-');
    return new Date(+p[0], +p[1] - 1, 1) >= yearAgo;
  });
  if (!peakKeys.length) peakKeys = Object.keys(monthMap);
  peakKeys.sort(function (a, b) { return mean(monthMap[a]) - mean(monthMap[b]); });
  var peakKey = peakKeys[peakKeys.length - 1];
  var peak = mean(monthMap[peakKey]);
  if (peak <= latest.kg) peak = latest.kg + 0.01;
  var achieved = latest.kg <= targetKg;   // 体重已到/低于目标
  var progress = achieved ? 1 : (peak - latest.kg) / (peak - targetKg);
  progress = Math.max(0.02, Math.min(0.98, progress));
  countUp('ringPct', achieved ? 100 : Math.round(progress * 100), 0, 1100);
  var ring = document.getElementById('ringProgress');
  if (ring) ring.setAttribute('stroke-dashoffset', (439.8 * (1 - progress)).toFixed(1));
  setHTML('ringCap', achieved
    ? '当前已低于目标 <b>' + ((targetKg - latest.kg) * 2).toFixed(1) + ' 斤</b> 🎉'
    : '从峰值 <b>' + (peak * 2).toFixed(1) + ' 斤</b> 算<br>已减 <b>' +
      ((peak - latest.kg) * 2).toFixed(1) + ' 斤</b> / 共 ' + ((peak - targetKg) * 2).toFixed(1) + ' 斤');

  // ---------- 里程碑 ----------
  var yearPrefix = last.t.getFullYear() + '-';
  var yearKeys = Object.keys(monthMap).filter(function (k) { return k.indexOf(yearPrefix) === 0; });
  if (!yearKeys.length) yearKeys = Object.keys(monthMap);
  yearKeys.sort(function (a, b) { return mean(monthMap[a]) - mean(monthMap[b]); });
  var lowKey = yearKeys[0];
  var lowKg = mean(monthMap[lowKey]);
  var gapNow = (latest.kg - targetKg) * 2;

  set('milePeak', (peak * 2).toFixed(1));
  set('milePeakDate', peakKey);
  set('milePeakSub', peakKeys.length < Object.keys(monthMap).length ? '近 12 个月最高月均' : '历史最高月均');
  set('mileLow', (lowKg * 2).toFixed(1));
  set('mileLowDate', lowKey);
  set('mileLowSub', '比峰值 ' + signedJin(lowKg - peak));
  set('mileNow', (latest.kg * 2).toFixed(1));
  set('mileNowDate', (latest.t.getMonth() + 1) + '-' + pad(latest.t.getDate()));
  set('mileNowSub', '较低点 ' + signedJin(latest.kg - lowKg));
  set('mileTarget', (targetKg * 2).toFixed(1));
  set('mileTargetSub', gapNow > 0 ? '还差 ' + gapNow.toFixed(1) + ' 斤'
                                  : '已低于目标 ' + (-gapNow).toFixed(1) + ' 斤');

  // ---------- 记录习惯 ----------
  var streakNow = 0;
  for (var si = 0; si < 3650; si++) {
    if (byDay[keyOf(addDays(last.t, -si))]) streakNow++;
    else break;
  }
  var bestRun = 0, run = 0;
  for (var di = 0; di < daily.length; di++) {
    if (di > 0 && Math.round((daily[di].t - daily[di - 1].t) / 86400000) === 1) run++;
    else run = 1;
    if (run > bestRun) bestRun = run;
  }
  var coverDays = daily.filter(function (d) { return d.t >= addDays(last.t, -29); }).length;
  set('streakNow', String(streakNow));
  set('streakBest', String(bestRun));
  set('cover30', String(coverDays));
  var strip = document.getElementById('dayStrip');
  if (strip) {
    var stripHTML = '';
    for (var pi = 29; pi >= 0; pi--) {
      var pd = addDays(last.t, -pi);
      var has = !!byDay[keyOf(pd)];
      stripHTML += '<i class="' + (has ? 'on' : '') + (pi === 0 ? ' today' : '') +
                   '" title="' + fmtMD(pd) + (has ? ' · 有记录' : ' · 未记录') + '"></i>';
    }
    strip.innerHTML = stripHTML;
  }

  // ---------- KPI ----------
  countUp('kpi7', win[7].c * 2, 1, 900);
  countUp('kpi30', win[30].c * 2, 1, 900);
  set('kpiBmi', bmi.toFixed(1));
  var gapJin = (latest.kg - targetKg) * 2;
  countUp('kpiGap', Math.max(0, gapJin), 1, 900);

  if (win[7].delta != null) {
    set('kpi7Sub', '较前 7 天 ' + signedJin(win[7].delta) + ' · ' + win[7].cur.length + '/7 天有记录');
    setClass('kpi7Sub', 'kpi-sub ' + (win[7].delta > 0 ? 'up' : (win[7].delta < 0 ? 'down' : 'flat')));
  }
  if (win[30].delta != null) {
    set('kpi30Sub', '较前 30 天 ' + signedJin(win[30].delta) + ' · ' + win[30].cur.length + '/30 天有记录');
    setClass('kpi30Sub', 'kpi-sub ' + (win[30].delta > 0 ? 'up' : (win[30].delta < 0 ? 'down' : 'flat')));
  }
  set('kpiBmiSub', '身高 ' + Math.round(height) + ' cm · ' +
    (bmi < 24 ? '正常区间' : (bmi < 28 ? '超重区间' : '肥胖区间')));
  set('kpiGapSub', gapJin > 0
    ? '目标 ' + (targetKg * 2).toFixed(1) + ' 斤（' + targetKg.toFixed(1) + ' kg）'
    : '已低于目标 ' + (-gapJin).toFixed(1) + ' 斤 · 达成 🎉');

  // ---------- 关键结论 ----------
  // 01 趋势
  if (recentWeeks.length >= 3) {
    var mn = Math.min.apply(null, recentWeeks), mx = Math.max.apply(null, recentWeeks);
    var last3 = recentWeeks.slice(-3).map(function (v) { return v.toFixed(1); }).join(' → ');
    setHTML('insight1',
      '最近 12 周的周均落在 <b>' + mn.toFixed(1) + '–' + mx.toFixed(1) + ' kg</b>。最近三周 ' +
      last3 + '，<b>没有继续恶化</b>，也没有重新下降。');
  }

  // 02 波动
  var best = null;
  daily.forEach(function (d) {
    if (d.t < addDays(last.t, -29)) return;
    var d2 = byDay[keyOf(addDays(d.t, -2))];
    if (!d2) return;
    var rise = d.kg - d2.kg;
    if (!best || rise > best.rise) best = { a: d2, b: d, rise: rise };
  });
  if (best && best.rise > 0.2) {
    set('insightTitle2', '短期跳涨主要是水分');
    setHTML('insight2',
      fmtMD(best.a.t) + ' 的 <b>' + best.a.kg.toFixed(2) + ' kg</b> 到 ' + fmtMD(best.b.t) + ' 的 <b>' +
      best.b.kg.toFixed(2) + ' kg</b>，两天涨 <b>' + best.rise.toFixed(2) + ' kg</b>（' +
      (best.rise * 2).toFixed(1) + ' 斤）。两天内不可能长这么多脂肪，更可能是盐分、碳水与进食带来的水分波动。');
  } else {
    set('insightTitle2', '短期波动不大');
    setHTML('insight2', '近 30 天没有出现两天超过 0.2 kg 的跳涨，<b>波动控制得不错</b>。继续固定早晨称重即可。');
  }

  // 03 周内节奏
  var names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  var sums = [0, 0, 0, 0, 0, 0, 0], counts = [0, 0, 0, 0, 0, 0, 0];
  daily.forEach(function (d) {
    if (d.t < addDays(last.t, -59)) return;
    var idx = (d.t.getDay() + 6) % 7;
    sums[idx] += d.kg; counts[idx]++;
  });
  var wdVals = sums.map(function (s, i) { return counts[i] ? s / counts[i] : null; });
  var valid = wdVals.map(function (v, i) { return { v: v, i: i }; }).filter(function (x) { return x.v != null; });
  if (valid.length >= 3) {
    valid.sort(function (a, b) { return b.v - a.v; });
    var hi = valid[0], lo = valid[valid.length - 1];
    var gap = hi.v - lo.v;
    set('insightTitle3', hi.i >= 5 ? '周末是主要风险窗口' : '周内节奏有差异');
    setHTML('insight3',
      '近 60 天 <b>' + names[hi.i] + '</b> 最重（' + hi.v.toFixed(1) + ' kg），<b>' + names[lo.i] +
      '</b> 最轻（' + lo.v.toFixed(1) + ' kg），相差 <b>' + gap.toFixed(1) + ' kg</b>。' +
      (hi.i >= 5 ? '周一通常会回落，真正的增量多发生在周末外食。' : '建议关注当天饮食和称重时间是否一致。'));
  }

  // 04 测量噪声
  var morning = [], evening = [];
  recs.forEach(function (r) {
    if (r.t < addDays(last.t, -89)) return;
    var h = r.t.getHours();
    if (h >= 4 && h < 12) morning.push(r.kg);
    if (h >= 17 || h < 4) evening.push(r.kg);
  });
  var jumps = [];
  for (var k = 1; k < daily.length; k++) {
    if (daily[k].t >= addDays(last.t, -89) &&
        Math.round((daily[k].t - daily[k - 1].t) / 86400000) === 1) {
      jumps.push(Math.abs(daily[k].kg - daily[k - 1].kg));
    }
  }
  var parts = [];
  if (morning.length && evening.length) {
    parts.push('近 90 天早晨均值 <b>' + mean(morning).toFixed(2) + ' kg</b>、晚间 <b>' +
               mean(evening).toFixed(2) + ' kg</b>，<b>早晚差 ' +
               (mean(evening) - mean(morning)).toFixed(2) + ' kg</b>');
  }
  if (jumps.length) {
    parts.push('相邻日平均跳动 <b>' + mean(jumps).toFixed(2) + ' kg</b>');
  }
  if (parts.length) {
    set('insightTitle4', '单次读数噪声很大');
    setHTML('insight4', parts.join('；') + '。判断趋势只看 <b>7 日均值</b>，别被单日 ±1 kg 带跑。');
  }

  // 05 记录频率
  var last120 = daily.filter(function (d) { return d.t >= addDays(last.t, -119); }).length;
  var cover = Math.round(last120 / 120 * 100);
  set('insightTitle5', cover >= 80 ? '记录很稳定' : '记录间隔偏大');
  setHTML('insight5',
    '近 120 天有 <b>' + last120 + ' 天</b>有记录（' + cover + '%）。' +
    (cover >= 80 ? '连续性不错，趋势判断比较可靠。' : '缺口会让均值失真，建议每天早晨固定时间称一次。'));

  // 06 目标
  var gapKg = latest.kg - targetKg;
  var pts = win[90].cur;
  var rate = null; // kg/周（正数=下降）
  if (pts.length >= 5) {
    var n = pts.length, sx = 0, sy = 0, sxx = 0, sxy = 0;
    pts.forEach(function (d, idx) {
      var x = idx, y = d.kg;
      sx += x; sy += y; sxx += x * x; sxy += x * y;
    });
    var den = n * sxx - sx * sx;
    if (den !== 0) {
      var slopePerDay = (n * sxy - sx * sy) / den;
      rate = -slopePerDay * 7;
    }
  }
  if (rate != null && rate > 0.05) {
    var weeks = gapKg / rate;
    set('insightTitle6', '还差 ' + (gapKg * 2).toFixed(1) + ' 斤，约 ' + Math.ceil(weeks) + ' 周');
    setHTML('insight6',
      '距 ' + (targetKg * 2).toFixed(1) + ' 斤（' + targetKg.toFixed(1) + ' kg）还差 <b>' +
      gapKg.toFixed(2) + ' kg（' + (gapKg * 2).toFixed(1) + ' 斤）</b>。按近 90 天 <b>−' +
      rate.toFixed(2) + ' kg/周</b>的节奏，约 <b>' + Math.ceil(weeks) + ' 周</b>可以到。');
  } else {
    set('insightTitle6', '还差 ' + (gapKg * 2).toFixed(1) + ' 斤，趋势不够');
    setHTML('insight6',
      '距 ' + (targetKg * 2).toFixed(1) + ' 斤（' + targetKg.toFixed(1) + ' kg）还差 <b>' +
      gapKg.toFixed(2) + ' kg（' + (gapKg * 2).toFixed(1) + ' 斤）</b>。近 90 天速率约 0，按当前趋势到不了；' +
      '需要重新制造每周约 −0.5 kg 的缺口，约 <b>' + Math.ceil(gapKg / 0.5) + ' 周</b>可以回到目标。');
  }
})();
