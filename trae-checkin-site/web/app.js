(() => {
  "use strict";

  const STORAGE_KEY = "trae-checkin-lang";
  const html = document.documentElement;
  const toggle = document.getElementById("lang-toggle");

  const copy = {
    zh: {
      title: "Trae 签到 — 每天自动签到领积分 · macOS / Windows",
      description:
        "Trae 签到是本地优先的 Trae 每日自动签到工具：自动发现本机账号，起始时间后随机分钟签到，展示今日积分、会话与余额。macOS 菜单栏与 Windows 托盘双平台。",
      toggleLabel: "Switch to English",
      toggleText: "EN",
    },
    en: {
      title: "Trae Check-in — Daily auto check-in for credits · macOS / Windows",
      description:
        "A local-first daily check-in utility for Trae: finds your accounts automatically, checks in at a random minute after your start hour, and shows today's credits, sessions and balance. Menu bar on macOS, tray on Windows.",
      toggleLabel: "切换到中文",
      toggleText: "中文",
    },
  };

  const metaDescription = document.querySelector('meta[name="description"]');
  const ogTitle = document.querySelector('meta[property="og:title"]');
  const ogDescription = document.querySelector('meta[property="og:description"]');
  const ogLocale = document.querySelector('meta[property="og:locale"]');

  const applyLanguage = (lang, persist) => {
    const next = lang === "en" ? "en" : "zh";
    const text = copy[next];

    html.dataset.lang = next;
    html.lang = next === "zh" ? "zh-CN" : "en";

    if (document.title !== text.title) document.title = text.title;
    if (metaDescription) metaDescription.setAttribute("content", text.description);
    if (ogTitle) ogTitle.setAttribute("content", text.title);
    if (ogDescription) ogDescription.setAttribute("content", text.description);
    if (ogLocale) ogLocale.setAttribute("content", next === "zh" ? "zh_CN" : "en_US");

    if (toggle) {
      toggle.textContent = text.toggleText;
      toggle.setAttribute("aria-label", text.toggleLabel);
      toggle.setAttribute("lang", next === "zh" ? "en" : "zh-CN");
    }

    document.querySelectorAll("img[data-alt-zh][data-alt-en]").forEach((img) => {
      const alt = img.getAttribute(next === "zh" ? "data-alt-zh" : "data-alt-en");
      if (alt) img.setAttribute("alt", alt);
    });

    if (persist) {
      try {
        localStorage.setItem(STORAGE_KEY, next);
      } catch (_) {
        /* storage may be unavailable in private mode */
      }
    }
  };

  let stored = null;
  try {
    stored = localStorage.getItem(STORAGE_KEY);
  } catch (_) {
    stored = null;
  }

  applyLanguage(stored === "en" ? "en" : "zh", false);

  if (toggle) {
    toggle.addEventListener("click", () => {
      applyLanguage(html.dataset.lang === "zh" ? "en" : "zh", true);
    });
  }

  const year = document.getElementById("year");
  if (year) year.textContent = String(new Date().getFullYear());

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const revealItems = document.querySelectorAll(".reveal");

  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealItems.forEach((item) => item.classList.add("is-visible"));
  } else {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );
    revealItems.forEach((item) => observer.observe(item));
  }
})();
