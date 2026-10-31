(() => {
  const labelFor = (status) => status === "Ran" ? "Ran successfully" : status === "Failed" ? "Failed" : status === "Running" ? "Running..." : "Ready";
  const classFor = (status) => String(status || "Ready").toLowerCase();

  function renderFiles(row, files) {
    const container = row.parentElement.querySelector("[data-files-container]");
    if (!container || !files) return;
    container.querySelectorAll(".file-button").forEach((link) => link.remove());
    const add = (kind, path) => {
      const link = document.createElement("a");
      link.className = "button file-button";
      link.textContent = `${kind}: ${path}`;
      link.href = "/view?path=" + encodeURIComponent(path);
      container.appendChild(link);
    };
    (files.logs || []).forEach((path) => add("Log", path));
    (files.configs || []).forEach((path) => add("Config", path));
  }

  function renderReview(row, data) {
    const container = row.parentElement.querySelector("[data-review-container]");
    if (!container) return;
    container.replaceChildren();
    if (!data.backup_id) return;
    const link = document.createElement("a");
    link.className = "button secondary";
    link.href = `/meld/review/${encodeURIComponent(data.backup_id)}`;
    link.textContent = "Review Script Changes";
    container.appendChild(link);
  }

  async function refreshRow(row) {
    try {
      const response = await fetch(row.dataset.statusUrl, { cache: "no-store" });
      if (!response.ok) return;
      const data = await response.json();
      renderFiles(row, data.files);
      renderReview(row, data);
      const button = row.querySelector("[data-run-url]");
      const message = row.querySelector("[data-status-message]");
      const nextClass = classFor(data.status);
      if (button) {
        button.classList.remove("ready", "running", "ran", "failed");
        button.classList.add(nextClass);
        button.disabled = false;
      }
      const text = data.status === "Failed" && data.message ? data.message : labelFor(data.status);
      if (message && message.textContent.trim() !== text) {
        message.classList.remove("fade-in");
        message.classList.add("fade-out");
        window.setTimeout(() => {
          message.innerHTML = data.status === "Running" ? '<span class="spinner" aria-hidden="true"></span>Running...' : text;
          message.classList.remove("fade-out");
          message.classList.add("fade-in");
        }, 150);
      }
    } catch (_) { /* The page remains usable if one poll fails. */ }
  }

  document.querySelectorAll(".script-row[data-status-url]").forEach((row) => {
    const button = row.querySelector("[data-run-url]");
    if (!button) return;
    button.addEventListener("click", async () => {
      const message = row.querySelector("[data-status-message]");
      message.classList.add("fade-out");
      button.classList.remove("ready", "running", "ran", "failed");
      button.classList.add("running");
      button.disabled = false; // Duplicate launches are intentionally allowed.
      window.setTimeout(() => {
        message.innerHTML = '<span class="spinner" aria-hidden="true"></span>Running...';
        message.classList.remove("fade-out");
        message.classList.add("fade-in");
      }, 130);
      try {
        const response = await fetch(button.dataset.runUrl, { method: "POST", headers: { "X-Requested-With": "fetch" } });
        if (!response.ok) throw new Error("Could not launch script");
      } catch (_) {
        message.textContent = "Failed";
        message.classList.remove("fade-out");
        button.classList.remove("running");
        button.classList.add("failed");
      }
      refreshRow(row);
    });
    refreshRow(row);
  });

  const autoRow = document.querySelector("[data-auto-run]");
  if (autoRow) {
    const button = autoRow.querySelector("[data-auto-run-url]");
    const message = autoRow.querySelector("[data-status-message]");
    const pollAuto = async () => {
      try {
        const response = await fetch(autoRow.dataset.statusUrl, { cache: "no-store" });
        if (!response.ok) return;
        const data = await response.json();
        renderFiles(autoRow, data.files);
        message.textContent = data.status === "Failed" ? data.message : labelFor(data.status);
        if (data.status !== "Running") button.disabled = false;
      } catch (_) { /* Auto-run state remains available through normal task rows. */ }
    };
    button.addEventListener("click", async () => {
      button.disabled = true;
      message.textContent = "Starting...";
      try {
        const response = await fetch(button.dataset.autoRunUrl, { method: "POST", headers: { "X-Requested-With": "fetch" } });
        if (!response.ok) throw new Error("Could not start Auto-run");
        message.textContent = "Running...";
      } catch (_) {
        message.textContent = "Failed to start";
        button.disabled = false;
      }
      pollAuto();
    });
    pollAuto();
    window.setInterval(pollAuto, 900);
  }

  const serviceSelect = document.querySelector("[data-service-select]");
  if (serviceSelect) {
    const showSelectedService = () => {
      document.querySelectorAll("[data-service-script]").forEach((row) => {
        row.hidden = row.dataset.serviceScript !== serviceSelect.value;
      });
    };
    serviceSelect.addEventListener("change", showSelectedService);
    showSelectedService();
  }

  document.querySelectorAll("[data-script-visibility]").forEach((button) => {
    const id = button.dataset.scriptVisibility;
    const content = document.querySelector(`[data-script-content="${CSS.escape(id)}"]`);
    if (!content) return;
    const key = `cyberpatriot-hidden-script-${id}`;
    const applyVisibility = (hidden) => {
      content.hidden = hidden;
      button.textContent = hidden ? "Show scripts" : "Hide scripts";
      button.setAttribute("aria-expanded", String(!hidden));
    };
    let hidden = false;
    try { hidden = localStorage.getItem(key) === "true"; } catch (_) { /* Keep default visible if storage is unavailable. */ }
    applyVisibility(hidden);
    button.addEventListener("click", () => {
      hidden = !hidden;
      try { localStorage.setItem(key, String(hidden)); } catch (_) { /* Current-page toggle still works. */ }
      applyVisibility(hidden);
    });
  });

  window.setInterval(() => {
    document.querySelectorAll(".script-row[data-status-url]").forEach(refreshRow);
  }, 900);
})();
