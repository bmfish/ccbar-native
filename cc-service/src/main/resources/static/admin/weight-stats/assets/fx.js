(function () {
  'use strict';

  // 漂浮粒子
  var box = document.getElementById('sparks');
  if (box) {
    var palette = ['var(--accent)', 'var(--accent3)', 'var(--accent2)', '#FF4D8D'];
    for (var i = 0; i < 34; i++) {
      var s = document.createElement('i');
      s.className = 'spark';
      var size = (1 + Math.random() * 2.4).toFixed(1);
      s.style.width = size + 'px';
      s.style.height = size + 'px';
      s.style.left = (Math.random() * 100).toFixed(2) + '%';
      s.style.animationDuration = (12 + Math.random() * 20).toFixed(1) + 's';
      s.style.animationDelay = (-Math.random() * 34).toFixed(1) + 's';
      var color = palette[i % palette.length];
      s.style.background = color;
      s.style.boxShadow = '0 0 10px ' + color;
      box.appendChild(s);
    }
    for (var j = 0; j < 2; j++) {
      var sh = document.createElement('span');
      sh.className = 'shoot';
      sh.style.animationDelay = (j * 5.5) + 's';
      sh.style.animationDuration = (10 + j * 2.5) + 's';
      box.appendChild(sh);
    }
  }

  // 顶部滚动进度
  var bar = document.getElementById('scrollBar');
  function update() {
    if (!bar) return;
    var h = document.documentElement.scrollHeight - window.innerHeight;
    var p = h > 0 ? Math.min(1, Math.max(0, window.scrollY / h)) : 0;
    bar.style.width = (p * 100).toFixed(2) + '%';
  }
  window.addEventListener('scroll', update, { passive: true });
  window.addEventListener('resize', update);
  update();
})();
