(function () {
  'use strict';

  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var accent3 = style.getPropertyValue('--accent3').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();
  var scale1 = style.getPropertyValue('--scale1').trim();
  var scale2 = style.getPropertyValue('--scale2').trim();
  var scale3 = style.getPropertyValue('--scale3').trim();
  var scale4 = style.getPropertyValue('--scale4').trim();

  function barFill(hex) {
    return new echarts.graphic.LinearGradient(0, 0, 0, 1, [
      { offset: 0, color: hex },
      { offset: 1, color: hex + '2E' }
    ]);
  }

  var WD = window.WD;
  if (!WD) return;

  // ---------- 工具 ----------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function keyOf(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); x.setHours(0, 0, 0, 0); return x; }
  function mean(a) { return a.reduce(function (s, v) { return s + v; }, 0) / a.length; }
  function fmtMD(d) { return (d.getMonth() + 1) + '月' + d.getDate() + '日'; }
  function fmtMDShort(d) { return (d.getMonth() + 1) + '/' + d.getDate(); }
  function parseLocal(s) {
    var a = s.split('T'), dp = a[0].split('-'), tp = a[1].split(':');
    return new Date(+dp[0], +dp[1] - 1, +dp[2], +tp[0], +tp[1]);
  }

  // ---------- 数据整理 ----------
  var recs = WD.records.map(function (r) { return { t: parseLocal(r[0]), kg: r[1] }; });
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

  // 7 日滚动均值（按自然日，缺记录的日子跳过）
  daily.forEach(function (d) {
    var s = 0, n = 0;
    for (var i = 0; i < 7; i++) {
      var q = byDay[keyOf(addDays(d.t, -i))];
      if (q) { s += q.kg; n++; }
    }
    d.r = n ? s / n : null;
  });

  var axisLabel = { color: muted, fontSize: 11 };
  var splitLine = { lineStyle: { color: rule, type: 'dashed' } };
  var tooltipBase = {
    trigger: 'axis',
    appendToBody: true,
    backgroundColor: bg2,
    borderColor: rule,
    borderWidth: 1,
    padding: [8, 10],
    textStyle: { color: ink, fontSize: 12 },
    axisPointer: { type: 'line', lineStyle: { color: rule } }
  };
  var tipDate = 'font-size:11px;color:' + muted + ';margin-bottom:3px;';

  // ---------- 0. Hero 迷你走势 ----------
  var heroChart = echarts.init(document.getElementById('chart-hero'), null, { renderer: 'svg' });
  (function () {
    var ds = daily.filter(function (d) { return d.t >= addDays(last.t, -89); });
    if (!ds.length) return;
    var data = ds.map(function (d) { return [d.t.getTime(), +(d.kg * 2).toFixed(1)]; });
    var vals = ds.map(function (d) { return d.kg * 2; });
    var lo = Math.floor(Math.min.apply(null, vals) - 0.6);
    var hi = Math.ceil(Math.max.apply(null, vals) + 0.6);

    heroChart.setOption({
      animation: true, animationDuration: 1300, animationEasing: 'cubicOut',
      grid: { left: 2, right: 2, top: 24, bottom: 2 },
      xAxis: { type: 'time', show: false, min: ds[0].t.getTime(), max: last.t.getTime() },
      yAxis: { type: 'value', show: false, min: lo, max: hi },
      tooltip: { show: false },
      series: [{
        type: 'line', data: data, symbol: 'none', smooth: true,
        lineStyle: { width: 2.2, color: accent2, shadowBlur: 12, shadowColor: accent2 + '66' },
        areaStyle: {
          color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
            { offset: 0, color: accent2 + '38' },
            { offset: 1, color: accent2 + '00' }
          ])
        },
        markPoint: {
          symbol: 'circle', symbolSize: 8,
          itemStyle: { color: accent, shadowBlur: 16, shadowColor: accent },
          label: { show: false },
          data: [{ coord: data[data.length - 1] }]
        }
      }]
    });
  })();

  // ---------- 1. 体重走势 ----------
  var trendChart = echarts.init(document.getElementById('chart-trend'), null, { renderer: 'svg' });
  var rangeButtons = document.querySelectorAll('#rangeSeg button');
  var TARGET_JIN = WD.summary.targetKg * 2;

  function renderTrend(range) {
    var start = range === 'all' ? daily[0].t : addDays(last.t, -(parseInt(range, 10) - 1));
    var ds = daily.filter(function (d) { return d.t >= start; });
    var raw = ds.map(function (d) { return [d.t.getTime(), +(d.kg * 2).toFixed(1)]; });
    var r7 = ds.filter(function (d) { return d.r != null; })
               .map(function (d) { return [d.t.getTime(), +(d.r * 2).toFixed(1)]; });
    var vals = ds.map(function (d) { return d.kg * 2; });
    var spanDays = Math.round((last.t - start) / 86400000) + 1;
    var minV = Math.min.apply(null, vals), maxV = Math.max.apply(null, vals);
    // 让目标线始终落在可视区间内
    var yMin = Math.floor(Math.min(minV, TARGET_JIN) - 0.5);
    var yMax = Math.ceil(Math.max(maxV, TARGET_JIN) + 0.8);
    document.getElementById('trendMeta').textContent =
      (range === 'all' ? '全部' : '近 ' + range + ' 天') + ' · ' +
      minV.toFixed(1) + '–' + maxV.toFixed(1) + ' 斤 · ' + ds.length + ' 天有记录';

    trendChart.setOption({
      animation: true, animationDuration: 1150, animationEasing: 'cubicOut',
      grid: { left: 46, right: 16, top: 38, bottom: 34 },
      legend: {
        top: 2, right: 0, itemWidth: 16, itemHeight: 3,
        textStyle: { color: muted, fontSize: 11 },
        data: ['每日均值', '7 日均线']
      },
      tooltip: Object.assign({}, tooltipBase, {
        formatter: function (ps) {
          if (!ps || !ps.length) return '';
          var d = new Date(ps[0].value[0]);
          var out = '<div style="' + tipDate + '">' + fmtMD(d) + '</div>';
          ps.forEach(function (p) {
            if (p.value[1] == null) return;
            var jin = p.value[1];
            out += '<div style="display:flex;align-items:center;gap:10px;font-size:12.5px;line-height:1.9">' +
                   p.marker + '<span style="color:' + muted + '">' + p.seriesName + '</span>' +
                   '<b style="margin-left:auto;color:' + ink + '">' + jin.toFixed(1) + ' 斤</b></div>';
          });
          return out;
        }
      }),
      xAxis: {
        type: 'time',
        min: start.getTime(),
        max: last.t.getTime(),
        axisLine: { lineStyle: { color: rule } },
        axisTick: { show: false },
        axisLabel: {
          color: muted, fontSize: 11, hideOverlap: true,
          formatter: function (v) {
            var d = new Date(v);
            return spanDays > 240 ? d.getFullYear() + '/' + (d.getMonth() + 1)
                                  : (d.getMonth() + 1) + '/' + d.getDate();
          }
        },
        splitLine: { show: false }
      },
      yAxis: {
        type: 'value', min: yMin, max: yMax, name: '斤',
        nameTextStyle: { color: muted, fontSize: 10 },
        axisLine: { show: false }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 11, formatter: function (v) { return v.toFixed(0); } },
        splitLine: splitLine
      },
      series: [
        {
          name: '每日均值', type: 'line', data: raw, symbol: 'none', z: 2,
          lineStyle: { width: 1.4, color: accent, opacity: 0.7 },
          itemStyle: { color: accent }
        },
        {
          name: '7 日均线', type: 'line', data: r7, symbol: 'none', smooth: true, z: 3,
          lineStyle: { width: 3, color: accent2, shadowBlur: 14, shadowColor: accent2 + '66' },
          itemStyle: { color: accent2 },
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: accent2 + '33' },
              { offset: 1, color: accent2 + '00' }
            ])
          },
          markLine: {
            silent: true, symbol: 'none',
            lineStyle: { color: muted, type: 'dashed', width: 1 },
            label: { color: muted, fontSize: 10, formatter: '目标 199.4 斤', position: 'insideEndTop' },
            data: [{ yAxis: TARGET_JIN }]
          }
        }
      ]
    });
  }

  rangeButtons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      rangeButtons.forEach(function (b) { b.classList.remove('active'); });
      btn.classList.add('active');
      renderTrend(btn.getAttribute('data-range'));
    });
  });
  renderTrend('90');

  // ---------- 2. 近 30 天偏差 ----------
  var devChart = echarts.init(document.getElementById('chart-dev'), null, { renderer: 'svg' });
  (function () {
    var ds = daily.filter(function (d) { return d.t >= addDays(last.t, -29); });
    var avg = mean(ds.map(function (d) { return d.kg; }));
    var labels = ds.map(function (d) { return fmtMDShort(d.t); });
    var data = ds.map(function (d) {
      var v = +((d.kg - avg) * 2).toFixed(1);
      return {
        value: v,
        itemStyle: {
          color: v > 0 ? barFill(accent) : barFill(accent2),
          opacity: 0.9,
          borderRadius: v > 0 ? [3, 3, 0, 0] : [0, 0, 3, 3],
          shadowBlur: 12,
          shadowColor: (v > 0 ? accent : accent2) + '55'
        }
      };
    });

    devChart.setOption({
      animation: true, animationDuration: 1150, animationEasing: 'cubicOut',
      grid: { left: 40, right: 10, top: 20, bottom: 28 },
      tooltip: Object.assign({}, tooltipBase, {
        formatter: function (ps) {
          var i = ps[0].dataIndex, d = ds[i];
          var v = (d.kg - avg) * 2;
          return '<div style="' + tipDate + '">' + fmtMD(d.t) + '</div>' +
                 '<div style="font-size:12.5px">当日 <b>' + (d.kg * 2).toFixed(1) + ' 斤</b></div>' +
                 '<div style="font-size:12px;color:' + muted + '">30 日均值 ' + (avg * 2).toFixed(1) +
                 ' 斤 · ' + (v >= 0 ? '高 ' : '低 ') + Math.abs(v).toFixed(1) + ' 斤</div>';
        }
      }),
      xAxis: {
        type: 'category', data: labels,
        axisLine: { lineStyle: { color: rule } }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10, interval: 'auto', hideOverlap: true }
      },
      yAxis: {
        type: 'value', name: '斤',
        nameTextStyle: { color: muted, fontSize: 10 },
        axisLine: { show: false }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10 },
        splitLine: splitLine
      },
      series: [{
        type: 'bar', data: data, barCategoryGap: '32%',
        animationDelay: function (idx) { return idx * 45; },
        markLine: {
          silent: true, symbol: 'none',
          lineStyle: { color: rule, width: 1 },
          label: { show: false }, data: [{ yAxis: 0 }]
        }
      }]
    });
  })();

  // ---------- 3. 最近 7 周周均 ----------
  var weekChart = echarts.init(document.getElementById('chart-week'), null, { renderer: 'svg' });
  (function () {
    var buckets = {};
    daily.forEach(function (d) {
      var ws = new Date(d.t);
      ws.setDate(ws.getDate() - ((ws.getDay() + 6) % 7));
      ws.setHours(0, 0, 0, 0);
      var k = ws.getTime();
      (buckets[k] = buckets[k] || []).push(d.kg);
    });
    var keys = Object.keys(buckets).map(Number).sort(function (a, b) { return a - b; }).slice(-7);
    var labels = keys.map(function (k, i) {
      if (i === keys.length - 1) return '本周';
      var d = new Date(k);
      return (d.getMonth() + 1) + '/' + d.getDate();
    });
    var vals = keys.map(function (k) { return +(mean(buckets[k]) * 2).toFixed(1); });
    var counts = keys.map(function (k) { return buckets[k].length; });
    var overall = mean(vals);
    var lo = Math.floor((Math.min.apply(null, vals) - 1) * 10) / 10;
    var hi = Math.ceil((Math.max.apply(null, vals) + 1) * 10) / 10;

    weekChart.setOption({
      animation: true, animationDuration: 1150, animationEasing: 'cubicOut',
      grid: { left: 42, right: 10, top: 28, bottom: 26 },
      tooltip: Object.assign({}, tooltipBase, {
        formatter: function (ps) {
          var i = ps[0].dataIndex;
          var d = new Date(keys[i]);
          var delta = i > 0 ? vals[i] - vals[i - 1] : null;
          return '<div style="' + tipDate + '">' +
                 (i === keys.length - 1 ? '本周至今' : (d.getMonth() + 1) + '月' + d.getDate() + '日 当周') +
                 ' · ' + counts[i] + ' 天</div>' +
                 '<div style="font-size:12.5px">周均 <b>' + vals[i].toFixed(1) + ' 斤</b></div>' +
                 (delta == null ? '' : '<div style="font-size:12px;color:' + muted + '">较上周 ' +
                   (delta >= 0 ? '+' : '−') + Math.abs(delta).toFixed(1) + ' 斤</div>');
        }
      }),
      xAxis: {
        type: 'category', data: labels,
        axisLine: { lineStyle: { color: rule } }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10, hideOverlap: true }
      },
      yAxis: {
        type: 'value', min: lo, max: hi, name: '斤',
        nameTextStyle: { color: muted, fontSize: 10 },
        axisLine: { show: false }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10 },
        splitLine: splitLine
      },
      series: [{
        type: 'bar', barCategoryGap: '38%',
        animationDelay: function (idx) { return idx * 45; },
        data: vals.map(function (v, i) {
          var isNow = i === keys.length - 1;
          return {
            value: v,
            itemStyle: {
              color: barFill(isNow ? accent2 : accent),
              opacity: isNow ? 1 : 0.62,
              borderRadius: [4, 4, 0, 0],
              shadowBlur: 10,
              shadowColor: (isNow ? accent2 : accent) + '44'
            }
          };
        }),
        label: {
          show: true, position: 'top', color: muted, fontSize: 10,
          formatter: function (p) { return p.value == null ? '' : p.value.toFixed(1); }
        },
        markLine: {
          silent: true, symbol: 'none',
          lineStyle: { color: muted, type: 'dashed', width: 1 },
          label: { color: muted, fontSize: 9, formatter: '7 周均值 ' + overall.toFixed(1), position: 'insideEndTop' },
          data: [{ yAxis: overall }]
        }
      }]
    });
  })();

  // ---------- 4. 月度趋势 ----------
  var monthChart = echarts.init(document.getElementById('chart-monthly'), null, { renderer: 'svg' });
  (function () {
    var mm = {};
    daily.forEach(function (d) {
      var k = d.t.getFullYear() + '-' + pad(d.t.getMonth() + 1);
      (mm[k] = mm[k] || []).push(d.kg);
    });
    var keys = Object.keys(mm).sort().slice(-18);
    var labels = keys.map(function (k) { var p = k.split('-'); return p[0].slice(2) + '/' + p[1]; });
    var vals = keys.map(function (k) { return +(mean(mm[k]) * 2).toFixed(1); });
    var lo = Math.floor(Math.min.apply(null, vals) - 1);
    var hi = Math.ceil(Math.max.apply(null, vals) + 1);

    monthChart.setOption({
      animation: true, animationDuration: 1150, animationEasing: 'cubicOut',
      grid: { left: 42, right: 8, top: 26, bottom: 26 },
      tooltip: Object.assign({}, tooltipBase, {
        formatter: function (ps) {
          var i = ps[0].dataIndex;
          return '<div style="' + tipDate + '">' + keys[i] + ' · ' + mm[keys[i]].length + ' 天</div>' +
                 '<div style="font-size:12.5px">月均 <b>' + vals[i].toFixed(1) + ' 斤</b></div>';
        }
      }),
      xAxis: {
        type: 'category', data: labels,
        axisLine: { lineStyle: { color: rule } }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 9, interval: 'auto', hideOverlap: true }
      },
      yAxis: {
        type: 'value', min: lo, max: hi, name: '斤',
        nameTextStyle: { color: muted, fontSize: 10 },
        axisLine: { show: false }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10 },
        splitLine: splitLine
      },
      series: [{
        type: 'bar', barCategoryGap: '26%',
        animationDelay: function (idx) { return idx * 45; },
        data: vals.map(function (v, i) {
          return {
            value: v,
            itemStyle: {
              color: barFill(accent),
              opacity: i === vals.length - 1 ? 1 : 0.5,
              borderRadius: [4, 4, 0, 0]
            }
          };
        }),
        label: {
          show: true, position: 'top', color: muted, fontSize: 8,
          formatter: function (p) { return p.value.toFixed(0); }
        }
      }]
    });
  })();

  // ---------- 5. 记录日历 ----------
  var heatChart = echarts.init(document.getElementById('chart-heat'), null, { renderer: 'svg' });
  (function () {
    var end = new Date(last.t);
    // 对齐到本周一，再往前退 11 周，正好 12 列
    var endMonday = addDays(end, -((end.getDay() + 6) % 7));
    var startMonday = addDays(endMonday, -77);
    var weeks = [];
    for (var w = new Date(startMonday); w <= endMonday; w = addDays(w, 7)) weeks.push(new Date(w));

    var xData = weeks.map(fmtMDShort);
    var yData = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    var cells = [];
    weeks.forEach(function (w, wi) {
      for (var di = 0; di < 7; di++) {
        var dt = addDays(w, di);
        if (dt > end) continue;
        var q = byDay[keyOf(dt)];
        if (q) cells.push([wi, di, +(q.kg * 2).toFixed(1)]);
      }
    });
    var vals = cells.map(function (c) { return c[2]; });
    var lo = Math.floor(Math.min.apply(null, vals));
    var hi = Math.ceil(Math.max.apply(null, vals));

    function hexMix(a, b, t) {
      function rgb(s) {
        return [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
      }
      var A = rgb(a), B = rgb(b);
      return 'rgb(' + A.map(function (v, i) { return Math.round(v + (B[i] - v) * t); }).join(',') + ')';
    }
    function heatColor(v) {
      var t = (v - lo) / Math.max(1, hi - lo);
      t = Math.max(0, Math.min(1, t));
      if (t < 0.4) return hexMix(scale1, scale2, t / 0.4);
      if (t < 0.75) return hexMix(scale2, scale4, (t - 0.4) / 0.35);
      return hexMix(scale4, scale3, (t - 0.75) / 0.25);
    }
    var colored = cells.map(function (c) {
      return { value: c, itemStyle: { color: heatColor(c[2]) } };
    });

    // 铺满 12×7 的底色，未记录或未来日期也显示为暗格
    var baseCells = [];
    weeks.forEach(function (w, wi) {
      for (var di = 0; di < 7; di++) baseCells.push([wi, di, 0]);
    });
    var el = document.getElementById('chart-heat');
    var cellW = (el.clientWidth || 640) / xData.length;

    heatChart.setOption({
      animation: true, animationDuration: 1150, animationEasing: 'cubicOut',
      grid: { left: 36, right: 6, top: 12, bottom: 34 },
      tooltip: {
        appendToBody: true, backgroundColor: bg2, borderColor: rule, borderWidth: 1,
        padding: [8, 10], textStyle: { color: ink, fontSize: 12 },
        formatter: function (p) {
          var w = weeks[p.value[0]];
          var d = addDays(w, p.value[1]);
          return '<div style="' + tipDate + '">' + fmtMD(d) + '</div>' +
                 '<div style="font-size:12.5px">日均 <b>' + p.value[2].toFixed(1) + ' 斤</b></div>';
        }
      },
      xAxis: {
        type: 'category', data: xData,
        axisLine: { lineStyle: { color: rule } }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 9, interval: 0, hideOverlap: true },
        splitArea: { show: false }
      },
      yAxis: {
        type: 'category', data: yData, inverse: true,
        axisLine: { show: false }, axisTick: { show: false },
        axisLabel: { color: muted, fontSize: 10 },
        splitArea: { show: false }
      },
      series: [
        {
          type: 'heatmap', data: baseCells, silent: true, z: 1,
          itemStyle: { color: 'rgba(255,255,255,.03)', borderColor: bg2, borderWidth: 2, borderRadius: 4 }
        },
        {
          type: 'heatmap', data: colored, z: 2,
          label: {
            show: cellW > 44, color: ink, fontSize: 8,
            formatter: function (p) { return p.value[2].toFixed(0); }
          },
          itemStyle: { borderColor: bg2, borderWidth: 2, borderRadius: 4 }
        }
      ]
    });
  })();

  // ---------- 自适应 ----------
  window.addEventListener('resize', function () {
    heroChart.resize();
    trendChart.resize();
    devChart.resize();
    weekChart.resize();
    monthChart.resize();
    heatChart.resize();
  });

  // ---------- 入场动画 ----------
  (function () {
    var items = document.querySelectorAll('.kpi, .card, .insight');
    if (!items.length) return;
    if (!('IntersectionObserver' in window)) return;
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.08 });
    Array.prototype.forEach.call(items, function (el, i) {
      el.classList.add('reveal');
      el.style.transitionDelay = Math.min(i * 55, 420) + 'ms';
      io.observe(el);
    });
    // 兜底：避免动画未触发导致内容不可见
    window.setTimeout(function () {
      Array.prototype.forEach.call(items, function (el) { el.classList.add('in'); });
    }, 1600);
  })();
})();
