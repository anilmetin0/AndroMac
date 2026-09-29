const root = document.documentElement;
const tr = root.lang === "tr";

// Scroll reveals. The inline script in <head> adds .rv; this marks that the observer took over.
const targets = document.querySelectorAll("[data-reveal]");
if (root.classList.contains("rv")) {
  root.dataset.revealReady = "1";
  for (const group of document.querySelectorAll("[data-stagger]")) {
    group.querySelectorAll(":scope > [data-reveal]").forEach((el, i) => el.style.setProperty("--i", i));
  }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      io.unobserve(e.target);
    }
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
  targets.forEach((el) => io.observe(el));
}

// Copy the Homebrew commands
for (const btn of document.querySelectorAll("[data-copy]")) {
  const label = btn.querySelector(".lbl");
  btn.addEventListener("click", async () => {
    const text = document.getElementById(btn.dataset.copy).textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
      btn.classList.add("done");
      label.textContent = tr ? "Kopyalandı" : "Copied";
    } catch {
      label.textContent = tr ? "Kopyalanamadı, metni seçip kopyala" : "Copy failed, select the text";
    }
    clearTimeout(btn.t);
    btn.t = setTimeout(() => {
      btn.classList.remove("done");
      label.textContent = btn.dataset.label;
    }, 2200);
  });
}

// Point download links at the latest release assets
fetch("https://api.github.com/repos/anilmetin0/AndroMac/releases/latest")
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((release) => {
    const find = (suffix) => release.assets.find((a) => a.name.endsWith(suffix));
    const assets = { dmg: find("-macOS-arm64.dmg"), apk: find("-android.apk") };
    for (const a of document.querySelectorAll("[data-asset]")) {
      const asset = assets[a.dataset.asset];
      if (asset) a.href = asset.browser_download_url;
    }
    const version = release.tag_name.replace(/^v/, "");
    for (const el of document.querySelectorAll("[data-version]")) el.textContent = version;
  })
  .catch(() => {});

// "What's new": the first versioned section of the changelog, bold leads only
const changes = document.getElementById("changes");
if (changes) {
  fetch("https://raw.githubusercontent.com/anilmetin0/AndroMac/main/" + (tr ? "CHANGELOG.tr.md" : "CHANGELOG.md"))
    .then((r) => (r.ok ? r.text() : Promise.reject()))
    .then((md) => {
      const release = md.split(/^## /m).find((s) => /^\d+\.\d+\.\d+/.test(s));
      if (!release) return;
      const [, version, date] = release.match(/^([\d.]+)(?:\s+-\s+(\d{4}-\d{2}-\d{2}))?/);
      const list = changes.querySelector(".changes");
      for (const part of release.split(/^### /m).slice(1)) {
        const title = part.slice(0, part.indexOf("\n")).trim();
        // Bullets may wrap onto indented lines; join them first
        const items = part.split(/\n- /).slice(1).map((b) => {
          const text = b.replace(/\s+/g, " ").trim();
          const bold = text.match(/^\*\*(.+?)\*\*/);
          return bold ? bold[1] : (text.match(/^.*?[.!?](?=\s|$)/)?.[0] ?? text);
        });
        if (!items.length) continue;
        const div = document.createElement("div");
        const h = document.createElement("h3");
        h.textContent = title;
        const ul = document.createElement("ul");
        for (const item of items) {
          const li = document.createElement("li");
          li.textContent = item.replace(/\*\*|`/g, "");
          ul.append(li);
        }
        div.append(h, ul);
        list.append(div);
      }
      if (!list.children.length) return;
      changes.querySelector("[data-changes-version]").textContent = version;
      if (date) {
        const d = new Date(date + "T12:00:00");
        const el = changes.querySelector(".date");
        el.textContent = (tr ? "Yayın tarihi: " : "Released ") + d.toLocaleDateString(root.lang, { day: "numeric", month: "long", year: "numeric" });
        el.hidden = false;
      }
      changes.hidden = false;
    })
    .catch(() => {});
}

// Star count next to the GitHub link; the link works without it.
fetch("https://api.github.com/repos/anilmetin0/AndroMac")
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((repo) => {
    const box = document.querySelector(".stars");
    if (!box || typeof repo.stargazers_count !== "number") return;
    box.querySelector("[data-stars]").textContent = repo.stargazers_count.toLocaleString(document.documentElement.lang);
    box.hidden = false;
  })
  .catch(() => {});

// Theme switch; the choice is remembered, otherwise the system setting applies.
document.querySelector(".theme")?.addEventListener("click", () => {
  const next = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try { localStorage.setItem("theme", next); } catch {}
});

// Name of the current nightly build inside the nightly panel.
fetch("https://api.github.com/repos/anilmetin0/AndroMac/releases/tags/nightly")
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((release) => {
    const box = document.querySelector(".nightly-name");
    const name = release.name?.replace(/^AndroMac nightly\s*/i, "");
    if (!box || !name) return;
    box.querySelector("[data-nightly]").textContent = name;
    box.hidden = false;
  })
  .catch(() => {});
