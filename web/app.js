(() => {
  "use strict";

  const root = document.documentElement;
  const toggle = document.getElementById("langToggle");
  const header = document.getElementById("siteHeader");
  const metaDescription = document.querySelector('meta[name="description"]');
  const ogTitle = document.querySelector('meta[property="og:title"]');
  const ogDescription = document.querySelector('meta[property="og:description"]');
  const ogLocale = document.querySelector('meta[property="og:locale"]');

  const copy = {
    zh: {
      title: "CCBar — AI CLI 用量统计 · macOS 菜单栏 / Windows 托盘",
      description:
        "CCBar 是本地优先的 AI CLI 用量统计工具：macOS 原生菜单栏、Windows 系统托盘，实时汇总 Claude Code、Codex、GLM 与 Trae 的 token、积分和费用。",
      ogDescription:
        "实时汇总 Claude Code、Codex、GLM 与 Trae 的 token、积分和费用，数据留在本地。macOS 与 Windows 双平台。",
      switchLabel: "Switch to English"
    },
    en: {
      title: "CCBar — AI usage on macOS and Windows",
      description:
        "CCBar tracks Claude Code, Codex, GLM and Trae usage — tokens, credits and cost — from your macOS menu bar or Windows system tray, with everything stored locally.",
      ogDescription:
        "Track Claude Code, Codex, GLM and Trae usage in real time on macOS and Windows — tokens, credits and cost, stored locally.",
      switchLabel: "切换到中文"
    }
  };

  function setLanguage(lang, persist) {
    const language = lang === "en" ? "en" : "zh";
    const strings = copy[language];

    root.dataset.lang = language;
    root.lang = language === "zh" ? "zh-CN" : "en";
    document.title = strings.title;

    if (metaDescription) metaDescription.setAttribute("content", strings.description);
    if (ogTitle) ogTitle.setAttribute("content", strings.title);
    if (ogDescription) ogDescription.setAttribute("content", strings.ogDescription);
    if (ogLocale) ogLocale.setAttribute("content", language === "zh" ? "zh_CN" : "en_US");

    if (toggle) {
      toggle.setAttribute("aria-pressed", language === "en" ? "true" : "false");
      toggle.setAttribute("aria-label", strings.switchLabel);
    }

    document.querySelectorAll("[data-alt-zh][data-alt-en]").forEach((image) => {
      const alt = image.getAttribute(language === "zh" ? "data-alt-zh" : "data-alt-en");
      if (alt) image.setAttribute("alt", alt);
    });

    if (persist) {
      try {
        localStorage.setItem("ccbar-lang", language);
      } catch (error) {
        /* storage can be unavailable in private browsing */
      }
    }
  }

  const queryLanguage = new URLSearchParams(window.location.search).get("lang");
  let savedLanguage = queryLanguage === "en" || queryLanguage === "zh" ? queryLanguage : "zh";
  if (!queryLanguage) {
    try {
      savedLanguage = localStorage.getItem("ccbar-lang") || "zh";
    } catch (error) {
      savedLanguage = "zh";
    }
  }
  setLanguage(savedLanguage, Boolean(queryLanguage));

  if (toggle) {
    toggle.addEventListener("click", () => {
      setLanguage(root.dataset.lang === "zh" ? "en" : "zh", true);
    });
  }

  function syncHeader() {
    if (!header) return;
    header.classList.toggle("is-scrolled", window.scrollY > 8);
  }

  syncHeader();
  window.addEventListener("scroll", syncHeader, { passive: true });

  const revealTargets = Array.from(
    document.querySelectorAll(
      ".feature-card, .source-card, .detail-item, .shot-stage, .download-panel, .windows-strip, .code-window, .release, .faq-grid details"
    )
  );

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduceMotion && "IntersectionObserver" in window) {
    const observer = new IntersectionObserver(
      (entries, currentObserver) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          currentObserver.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -7% 0px", threshold: 0.08 }
    );

    revealTargets.forEach((element, index) => {
      element.classList.add("reveal");
      element.style.transitionDelay = `${Math.min(index % 4, 3) * 45}ms`;
      observer.observe(element);
    });
  }

  const tabs = Array.from(document.querySelectorAll(".shot-tab"));
  const panels = Array.from(document.querySelectorAll("[data-shot-panel]"));

  function activateShot(name, focusTab) {
    tabs.forEach((tab) => {
      const selected = tab.dataset.shot === name;
      tab.setAttribute("aria-selected", selected ? "true" : "false");
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focusTab) tab.focus();
    });

    panels.forEach((panel) => {
      panel.hidden = panel.dataset.shotPanel !== name;
    });
  }

  if (tabs.length) {
    activateShot(tabs.find((tab) => tab.getAttribute("aria-selected") === "true")?.dataset.shot || "popover", false);

    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => activateShot(tab.dataset.shot, false));
      tab.addEventListener("keydown", (event) => {
        let nextIndex = null;
        if (event.key === "ArrowDown" || event.key === "ArrowRight") {
          nextIndex = (index + 1) % tabs.length;
        } else if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
          nextIndex = (index - 1 + tabs.length) % tabs.length;
        } else if (event.key === "Home") {
          nextIndex = 0;
        } else if (event.key === "End") {
          nextIndex = tabs.length - 1;
        }

        if (nextIndex === null) return;
        event.preventDefault();
        activateShot(tabs[nextIndex].dataset.shot, true);
      });
    });
  }

  const copyButton = document.getElementById("copyCode");
  if (copyButton) {
    const labels = {
      zh: copyButton.querySelector(".copy-label.zh"),
      en: copyButton.querySelector(".copy-label.en")
    };
    const originals = {
      zh: labels.zh ? labels.zh.textContent : "复制",
      en: labels.en ? labels.en.textContent : "Copy"
    };

    const markCopied = () => {
      if (labels.zh) labels.zh.textContent = "已复制";
      if (labels.en) labels.en.textContent = "Copied";
      window.setTimeout(() => {
        if (labels.zh) labels.zh.textContent = originals.zh;
        if (labels.en) labels.en.textContent = originals.en;
      }, 1600);
    };

    const fallbackCopy = (text) => {
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      let copied = false;
      try {
        copied = document.execCommand("copy");
      } catch (error) {
        copied = false;
      }
      document.body.removeChild(area);
      return copied;
    };

    copyButton.addEventListener("click", async () => {
      const text = copyButton.dataset.copy || "";
      let copied = false;
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch (error) {
        copied = fallbackCopy(text);
      }
      if (copied) markCopied();
    });
  }

  const year = document.getElementById("year");
  if (year) year.textContent = String(new Date().getFullYear());
})();
