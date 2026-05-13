import { cycleViewMode, getViewMode, loadModel, resetView } from "/static/viewer.js";

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
const exportStatus = document.getElementById("export-status");
const profileNote = document.getElementById("profile-note");

let activeJobId = null;
let pollTimer = null;
let loadedResultUrl = null;
let lastJob = null;

const exportControlIds = ["decimation", "textureSize"];
const stepControlIds = ["ssSteps", "shapeSteps", "texSteps"];

function setText(id, text, className = "") {
  const element = document.getElementById(id);
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

stepControlIds.forEach(updateRangeValue);

function generationProfileWarning() {
  const resolution = Number(document.getElementById("resolution").value);
  if (resolution !== 1536) {
    return "";
  }

  return "1536 is unstable on this CUDA setup. Use 1024, then re-export Decimation/Texture.";
}

function syncGenerateButtonState() {
  const warning = generationProfileWarning();
  profileNote.textContent = warning;
  profileNote.classList.toggle("warn", Boolean(warning));
  generateButton.disabled = !imageInput.files.length || Boolean(warning) || Boolean(lastJob && isJobBusy(lastJob));
}

function renderViewMode(mode = getViewMode()) {
  viewModeButton.textContent = `Mode: ${mode.label}`;
  viewModeButton.title = mode.description;
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
  return `${decimation} vertices · ${params.textureSize}px texture`;
}

function isJobBusy(job) {
  return job.status === "queued" || job.status === "running" || job.exportStatus === "exporting";
}

async function loadResultIfReady(job) {
  if (job.status !== "complete" || job.exportStatus === "exporting" || !job.resultUrl) {
    return;
  }
  if (job.resultUrl === loadedResultUrl) {
    setDownloadUrl(job.resultUrl, job.exportStatus !== "failed");
    return;
  }

  await loadModel(job.resultUrl);
  loadedResultUrl = job.resultUrl;
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
  try {
    const status = await fetch("/api/status").then((response) => response.json());

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

    const repoOk = status.pixal3dRepo.exists;
    const engineOk = status.engine.ready;
    setText("engine-status", repoOk && engineOk ? "CUDA deps ready" : "CUDA deps missing", repoOk && engineOk ? "ok" : "warn");

    const notes = [];
    if (!status.wsl.available && status.wsl.needed) {
      notes.push("Official Pixal3D CUDA dependencies are Linux-first. WSL is not installed on this PC yet.");
    }
    if (!status.model.ready) {
      notes.push("Run scripts/download-models.ps1 to fetch Pixal3D weights before the first real generation.");
    }
    if (!engineOk) {
      notes.push("Run scripts/setup-wsl-backend.ps1 and then scripts/launch-wsl.ps1 for real generation.");
    }
    if (!status.nodeModules.three) {
      notes.push("Run npm install so the local Three.js viewer can load without CDN.");
    }
    setupNote.textContent = notes.join(" ");
  } catch (error) {
    setupNote.textContent = `Status check failed: ${error.message}`;
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
document.getElementById("resolution").addEventListener("change", syncGenerateButtonState);
viewModeButton.addEventListener("click", () => renderViewMode(cycleViewMode()));

function formDataForJob() {
  const data = new FormData();
  data.append("image", imageInput.files[0]);
  [
    "seed",
    "resolution",
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
  if (generationProfileWarning()) {
    syncGenerateButtonState();
    return;
  }

  lastJob = null;
  loadedResultUrl = null;
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
  return `${job.stage || "Complete"} · ${duration}`;
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

renderViewMode();
syncGenerateButtonState();
refreshStatus();
