import {
  cycleViewMode,
  getAutoLevel,
  getViewMode,
  loadModel,
  resetView,
  setAutoLevel,
  toggleAutoLevel,
} from "/static/viewer.js?v=20260513-level";

window.__pixal3dAppStarted = true;

const form = document.getElementById("generate-form");
const imageInput = document.getElementById("image-input");
const dropZone = document.getElementById("drop-zone");
const imagePreview = document.getElementById("image-preview");
const generateButton = document.getElementById("generate-button");
const downloadLink = document.getElementById("download-link");
const logOutput = document.getElementById("log-output");
const jobTitle = document.getElementById("job-title");
const jobStage = document.getElementById("job-stage");
const jobIdElement = document.getElementById("job-id");
const setupNote = document.getElementById("setup-note");
const viewModeButton = document.getElementById("view-mode");
const levelButton = document.getElementById("level-model");
const exportStatus = document.getElementById("export-status");
const advancedSettings = document.getElementById("advanced-settings");

let activeJobId = null;
let pollTimer = null;
let loadedResultUrl = null;
let loadedResultJobId = null;
let lastJob = null;
let engineReady = false;

const statusTimeoutMs = 15000;
const exportControlIds = ["decimation", "textureSize"];
const stepControlIds = ["ssSteps", "shapeSteps", "texSteps"];
const storedControlIds = [
  "seed",
  ...stepControlIds,
  ...exportControlIds,
  "attentionBackend",
  "maxTokens",
  "lowVram",
];
const settingsStorageKey = "pixal3d.local.settings.v1";

function setText(id, text, className = "") {
  const element = document.getElementById(id);
  if (!element) return;
  element.textContent = text;
  element.className = className;
}

function updateRangeValue(id) {
  const input = document.getElementById(id);
  const output = document.getElementById(`${id}Value`);
  output.textContent = input.value;
  input.addEventListener("input", () => {
    output.textContent = input.value;
    syncGenerateButtonState();
  });
}

function syncGenerateButtonState() {
  generateButton.disabled =
    !imageInput.files.length ||
    !engineReady ||
    Boolean(lastJob && isJobBusy(lastJob));
}

function renderViewMode(mode = getViewMode()) {
  viewModeButton.textContent = `Mode: ${mode.label}`;
  viewModeButton.title = mode.description;
}

function renderLevelButton(enabled = getAutoLevel()) {
  levelButton.textContent = `Level: ${enabled ? "On" : "Off"}`;
  levelButton.title = enabled
    ? "Auto-align the model support plane to the grid"
    : "Show the model with its original GLB orientation";
}

function restoreViewMode(modeId) {
  if (typeof modeId !== "string") {
    return;
  }

  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (getViewMode().id === modeId) {
      return;
    }
    cycleViewMode();
  }
}

function readStoredSettings() {
  try {
    const raw = localStorage.getItem(settingsStorageKey);
    if (!raw) return {};

    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

let storedSettings = readStoredSettings();

function writeStoredSettings(nextSettings) {
  storedSettings = nextSettings;
  try {
    localStorage.setItem(settingsStorageKey, JSON.stringify(storedSettings));
  } catch {
    // Settings are convenience state only. The app should still work if storage is blocked.
  }
}

function updateStoredSettings(patch) {
  writeStoredSettings({ ...storedSettings, ...patch });
}

function storedControls() {
  return storedSettings.controls && typeof storedSettings.controls === "object"
    ? storedSettings.controls
    : {};
}

function hasStoredValue(source, key) {
  return Object.prototype.hasOwnProperty.call(source, key);
}

function controlValue(element) {
  if (element.type === "checkbox") {
    return element.checked;
  }

  return element.value;
}

function numberValueInRange(element, value) {
  if (value === "" || value === null || typeof value === "boolean") {
    return null;
  }

  const numericValue = Number(value);
  if (!Number.isFinite(numericValue)) {
    return null;
  }

  const min = element.min === "" ? -Infinity : Number(element.min);
  const max = element.max === "" ? Infinity : Number(element.max);
  if (numericValue < min || numericValue > max) {
    return null;
  }

  return String(numericValue);
}

function applyStoredControlValue(element, value) {
  if (element.type === "checkbox") {
    if (typeof value === "boolean") {
      element.checked = value;
    } else if (value === "true" || value === "false") {
      element.checked = value === "true";
    }
    return;
  }

  if (element.tagName === "SELECT") {
    const optionExists = Array.from(element.options).some((option) => option.value === String(value));
    if (optionExists) {
      element.value = String(value);
    }
    return;
  }

  if (element.type === "number" || element.type === "range") {
    const nextValue = numberValueInRange(element, value);
    if (nextValue !== null) {
      element.value = nextValue;
    }
    return;
  }

  if (typeof value === "string") {
    element.value = value;
  }
}

function persistControlSetting(element) {
  updateStoredSettings({
    controls: {
      ...storedControls(),
      [element.id]: controlValue(element),
    },
  });
}

function persistCurrentSettings() {
  const controls = {};
  storedControlIds.forEach((id) => {
    const element = document.getElementById(id);
    if (element) {
      controls[id] = controlValue(element);
    }
  });

  updateStoredSettings({
    controls,
    advancedOpen: Boolean(advancedSettings?.open),
    viewMode: getViewMode().id,
    autoLevel: getAutoLevel(),
  });
}

function restoreStoredSettings() {
  const controls = storedControls();
  storedControlIds.forEach((id) => {
    const element = document.getElementById(id);
    if (element && hasStoredValue(controls, id)) {
      applyStoredControlValue(element, controls[id]);
    }
  });

  restoreViewMode(storedSettings.viewMode);
  if (typeof storedSettings.autoLevel === "boolean") {
    setAutoLevel(storedSettings.autoLevel);
  }

  if (advancedSettings && typeof storedSettings.advancedOpen === "boolean") {
    advancedSettings.open = storedSettings.advancedOpen;
  }
}

function attachSettingsPersistence() {
  storedControlIds.forEach((id) => {
    const element = document.getElementById(id);
    if (!element) return;

    const eventName = element.type === "checkbox" || element.tagName === "SELECT" ? "change" : "input";
    element.addEventListener(eventName, () => persistControlSetting(element));
  });

  advancedSettings?.addEventListener("toggle", () => {
    updateStoredSettings({ advancedOpen: advancedSettings.open });
  });
}

function setDownloadUrl(url, enabled = true) {
  if (!url) {
    downloadLink.classList.add("disabled");
    downloadLink.removeAttribute("href");
    return;
  }

  downloadLink.href = url;
  downloadLink.classList.toggle("disabled", !enabled);
}

function setExportControlsDisabled(disabled) {
  exportControlIds.forEach((id) => {
    document.getElementById(id).disabled = disabled;
  });
}

function setExportStatus(text, className = "") {
  exportStatus.textContent = text;
  exportStatus.className = ["export-status", className].filter(Boolean).join(" ");
}

function formatExportParams(params) {
  if (!params) return "";
  const decimation = Number(params.decimation).toLocaleString();
  return `${decimation} vertices - ${params.textureSize}px texture`;
}

function engineDependencyProblems(status) {
  const dependencies = status.engine?.dependencies || {};
  const missing = Object.entries(dependencies)
    .filter(([key, value]) => !key.endsWith("Error") && value === false)
    .map(([key]) => key);
  const errors = Object.entries(dependencies)
    .filter(([key, value]) => key.endsWith("Error") && value)
    .map(([key, value]) => `${key.replace(/Error$/, "")}: ${value}`);

  return { missing, errors };
}

function engineStatusLabel(status) {
  if (!status.pixal3dRepo.exists) {
    return { text: "Pixal3D repo missing", className: "warn" };
  }
  if (!status.engine.pythonOk) {
    return { text: "Python env missing", className: "warn" };
  }
  if (!status.engine.runnerExists) {
    return { text: "Runner missing", className: "warn" };
  }
  if (status.engine.ready) {
    return { text: "Ready", className: "ok" };
  }

  const { missing, errors } = engineDependencyProblems(status);
  if (errors.length) {
    return { text: `${errors[0].split(":")[0]} failed`, className: "warn" };
  }
  if (missing.length) {
    return { text: `${missing.join(", ")} missing`, className: "warn" };
  }
  return { text: "Setup incomplete", className: "warn" };
}

function engineSetupNotes(status) {
  const notes = [];
  if (!status.pixal3dRepo.exists) {
    notes.push("Run START_PIXAL3D.bat to download vendor/Pixal3D.");
  }
  if (!status.engine.pythonOk) {
    notes.push("Run START_PIXAL3D.bat to create the Python environment.");
  }
  if (!status.engine.runnerExists) {
    notes.push("The local Pixal3D runner is missing from app/pixal3d_runner.py.");
  }

  const { missing, errors } = engineDependencyProblems(status);
  if (missing.length) {
    notes.push(`Missing engine dependencies: ${missing.join(", ")}.`);
  }
  if (errors.length) {
    notes.push(`Engine import check failed: ${errors[0]}.`);
  }
  if (!status.engine.ready) {
    notes.push("For full generation, run START_PIXAL3D.bat -Mode Full or scripts/setup-wsl-backend.ps1, then restart the UI.");
  }

  return notes;
}

function isJobBusy(job) {
  return job.status === "queued" || job.status === "running" || job.exportStatus === "exporting";
}

async function fetchJson(url, timeoutMs) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      const body = await response.text();
      throw new Error(body || `${response.status} ${response.statusText}`);
    }
    return await response.json();
  } finally {
    window.clearTimeout(timer);
  }
}

function statusFailureMessage(error) {
  if (error.name === "AbortError") {
    return "The UI loaded, but /api/status did not answer within 15 seconds. The backend may still be starting, hung in a CUDA/Python check, or stopped. Click Refresh status, or restart START_PIXAL3D.bat if it keeps timing out.";
  }
  if (String(error.message).toLowerCase().includes("failed to fetch")) {
    return "The UI loaded, but the status API is unreachable. The server may have stopped after serving this page. Restart START_PIXAL3D.bat.";
  }
  return `Status check failed: ${error.message}`;
}

async function loadResultIfReady(job) {
  if (job.status !== "complete" || job.exportStatus === "exporting" || !job.resultUrl) {
    return;
  }
  if (job.resultUrl === loadedResultUrl) {
    setDownloadUrl(job.resultUrl, job.exportStatus !== "failed");
    return;
  }

  const shouldResetView = job.id !== loadedResultJobId;
  await loadModel(job.resultUrl, { resetViewOnLoad: shouldResetView });
  loadedResultUrl = job.resultUrl;
  loadedResultJobId = job.id;
  setDownloadUrl(job.resultUrl, job.exportStatus !== "failed");
}

async function handleJobUpdate(job) {
  lastJob = job;
  renderJob(job);
  setExportControlsDisabled(isJobBusy(job));
  syncGenerateButtonState();
  if (job.exportStatus === "exporting") {
    setDownloadUrl(job.resultUrl || loadedResultUrl, false);
  } else {
    await loadResultIfReady(job);
  }
}

async function refreshStatus() {
  setText("server-status", "Checking...", "warn");
  setText("gpu-status", "Checking...");
  setText("model-status", "Checking...");
  setText("engine-status", "Checking...");
  setupNote.textContent = "";

  try {
    const status = await fetchJson("/api/status", statusTimeoutMs);
    setText("server-status", "Status API ready", "ok");

    if (status.gpu.available) {
      const memory = status.gpu.memoryMB ? `, ${Math.round(status.gpu.memoryMB / 1024)} GB` : "";
      setText("gpu-status", `${status.gpu.name}${memory}`, "ok");
    } else {
      setText("gpu-status", "Not found", "bad");
    }

    if (status.model.ready) {
      setText("model-status", `${status.model.sizeText}`, "ok");
    } else {
      setText("model-status", `${status.model.present}/${status.model.total} files`, "warn");
    }

    engineReady = Boolean(status.engine.ready);
    const engineLabel = engineStatusLabel(status);
    setText("engine-status", engineLabel.text, engineLabel.className);

    const notes = [];
    if (!status.wsl.available && status.wsl.needed) {
      notes.push("Official Pixal3D CUDA dependencies are Linux-first. WSL is not installed on this PC yet.");
    }
    if (!status.model.ready) {
      notes.push("Run scripts/download-models.ps1 to fetch Pixal3D weights before the first real generation.");
    }
    notes.push(...engineSetupNotes(status));
    if (!status.nodeModules.three) {
      notes.push("Run npm install so the local Three.js viewer can load without CDN.");
    }
    setupNote.textContent = notes.join(" ");
    syncGenerateButtonState();
  } catch (error) {
    engineReady = false;
    setText("server-status", "Status API failed", "bad");
    setText("gpu-status", "Not checked", "warn");
    setText("model-status", "Not checked", "warn");
    setText("engine-status", "Not checked", "warn");
    syncGenerateButtonState();
    setupNote.textContent = statusFailureMessage(error);
  }
}

function setImageFile(file) {
  if (!file) return;
  const url = URL.createObjectURL(file);
  imagePreview.src = url;
  dropZone.classList.add("has-image");
  syncGenerateButtonState();
}

imageInput.addEventListener("change", () => {
  setImageFile(imageInput.files[0]);
});

dropZone.addEventListener("dragover", (event) => {
  event.preventDefault();
  dropZone.classList.add("dragging");
});

dropZone.addEventListener("dragleave", () => {
  dropZone.classList.remove("dragging");
});

dropZone.addEventListener("drop", (event) => {
  event.preventDefault();
  dropZone.classList.remove("dragging");
  if (event.dataTransfer.files.length) {
    imageInput.files = event.dataTransfer.files;
    setImageFile(event.dataTransfer.files[0]);
  }
});

document.getElementById("refresh-status").addEventListener("click", refreshStatus);
document.getElementById("reset-view").addEventListener("click", resetView);
levelButton.addEventListener("click", () => {
  const enabled = toggleAutoLevel();
  renderLevelButton(enabled);
  updateStoredSettings({ autoLevel: enabled });
});
viewModeButton.addEventListener("click", () => {
  const mode = cycleViewMode();
  renderViewMode(mode);
  updateStoredSettings({ viewMode: mode.id });
});

function formDataForJob() {
  const data = new FormData();
  data.append("image", imageInput.files[0]);
  data.append("resolution", "1024");
  [
    "seed",
    "ssSteps",
    "shapeSteps",
    "texSteps",
    "decimation",
    "textureSize",
    "maxTokens",
    "attentionBackend",
  ].forEach((id) => data.append(id, document.getElementById(id).value));
  data.append("lowVram", document.getElementById("lowVram").checked ? "true" : "false");
  return data;
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!imageInput.files.length) return;

  lastJob = null;
  loadedResultUrl = null;
  loadedResultJobId = null;
  generateButton.disabled = true;
  setExportControlsDisabled(true);
  setDownloadUrl(null);
  setExportStatus("");
  jobTitle.textContent = "Pixal3D job running";
  jobStage.textContent = "Uploading image";
  logOutput.textContent = "";

  try {
    const response = await fetch("/api/jobs", { method: "POST", body: formDataForJob() });
    if (!response.ok) {
      throw new Error(await response.text());
    }
    const job = await response.json();
    activeJobId = job.id;
    jobIdElement.textContent = job.id.slice(0, 10);
    await handleJobUpdate(job);
    startPolling();
  } catch (error) {
    jobTitle.textContent = "Job failed to start";
    jobStage.textContent = error.message;
    syncGenerateButtonState();
    setExportControlsDisabled(false);
  }
});

function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    if (!activeJobId) return;
    let job;
    try {
      const response = await fetch(`/api/jobs/${activeJobId}`);
      if (!response.ok) {
        throw new Error(response.status === 404 ? "Job no longer exists on the server." : await response.text());
      }
      job = await response.json();
    } catch (error) {
      clearInterval(pollTimer);
      pollTimer = null;
      activeJobId = null;
      lastJob = null;
      jobTitle.textContent = "Job unavailable";
      jobStage.textContent = error.message;
      setExportStatus("Start a new generation to create a fresh export state.", "warn");
      generateButton.disabled = !imageInput.files.length;
      setExportControlsDisabled(false);
      return;
    }
    await handleJobUpdate(job);
    if (!isJobBusy(job) && (job.status === "complete" || job.status === "failed")) {
      clearInterval(pollTimer);
      pollTimer = null;
      generateButton.disabled = false;
      setExportControlsDisabled(false);
    }
  }, 1500);
}

async function requestReexportFromControls() {
  if (!activeJobId || !lastJob || lastJob.status !== "complete" || !lastJob.hasExportState) {
    return;
  }
  if (lastJob.exportStatus === "exporting") {
    return;
  }

  const decimation = document.getElementById("decimation").value;
  const textureSize = document.getElementById("textureSize").value;
  if (
    String(lastJob.params.decimation) === decimation &&
    String(lastJob.params.textureSize) === textureSize
  ) {
    return;
  }

  const data = new FormData();
  data.append("decimation", decimation);
  data.append("textureSize", textureSize);

  generateButton.disabled = true;
  setExportControlsDisabled(true);
  setDownloadUrl(lastJob.resultUrl || loadedResultUrl, false);
  setExportStatus("Starting export...", "warn");

  try {
    const response = await fetch(`/api/jobs/${activeJobId}/exports`, { method: "POST", body: data });
    if (!response.ok) {
      throw new Error(await response.text());
    }
    const job = await response.json();
    await handleJobUpdate(job);
    if (isJobBusy(job)) {
      startPolling();
    } else {
      generateButton.disabled = false;
      setExportControlsDisabled(false);
    }
  } catch (error) {
    setExportStatus(`Export failed: ${error.message}`, "bad");
    generateButton.disabled = false;
    setExportControlsDisabled(false);
    setDownloadUrl(loadedResultUrl, Boolean(loadedResultUrl));
  }
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return null;

  const totalSeconds = Math.round(seconds);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const remainingSeconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}h ${minutes}m ${remainingSeconds}s`;
  }
  if (minutes > 0) {
    return `${minutes}m ${remainingSeconds}s`;
  }
  return `${remainingSeconds}s`;
}

function completeStageText(job) {
  const startedAt = Number(job.startedAt ?? job.createdAt);
  const finishedAt = Number(job.finishedAt);
  const duration = formatDuration(finishedAt - startedAt);

  if (!duration) {
    return job.stage || "Complete";
  }
  return `${job.stage || "Complete"} - ${duration}`;
}

function renderJob(job) {
  if (job.exportStatus === "exporting") {
    jobTitle.textContent = "Updating export";
    jobStage.textContent = job.exportStage || "Rebuilding GLB";
    setExportStatus(`Exporting ${formatExportParams(job.pendingExport || job.params)}`, "warn");
  } else if (job.exportStatus === "failed") {
    jobTitle.textContent = "Export failed";
    jobStage.textContent = job.exportStage || "Previous GLB is still loaded.";
    setExportStatus("Export failed. Previous GLB is still loaded.", "bad");
  } else if (job.status === "failed") {
    jobTitle.textContent = "Job failed";
    jobStage.textContent = job.failureReason || job.stage || "Generation failed";
    setExportStatus("No GLB was created for this run.", "bad");
  } else {
    jobTitle.textContent = job.status === "complete" ? "Model ready" : `Job ${job.status}`;
    jobStage.textContent = job.status === "complete" ? completeStageText(job) : job.stage;
    if (job.status === "complete") {
      setExportStatus(`Current export: ${formatExportParams(job.params)}`, "ok");
    }
  }
  logOutput.textContent = job.log.length ? job.log.join("\n") : "Starting...";
  logOutput.scrollTop = logOutput.scrollHeight;
}

exportControlIds.forEach((id) => {
  document.getElementById(id).addEventListener("change", requestReexportFromControls);
});

restoreStoredSettings();
stepControlIds.forEach(updateRangeValue);
attachSettingsPersistence();
persistCurrentSettings();
renderViewMode();
renderLevelButton();
syncGenerateButtonState();
refreshStatus();
