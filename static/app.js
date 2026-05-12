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

let activeJobId = null;
let pollTimer = null;

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
  });
}

["ssSteps", "shapeSteps", "texSteps"].forEach(updateRangeValue);

function renderViewMode(mode = getViewMode()) {
  viewModeButton.textContent = `Mode: ${mode.label}`;
  viewModeButton.title = mode.description;
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
  generateButton.disabled = false;
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

  generateButton.disabled = true;
  downloadLink.classList.add("disabled");
  downloadLink.removeAttribute("href");
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
    renderJob(job);
    startPolling();
  } catch (error) {
    jobTitle.textContent = "Job failed to start";
    jobStage.textContent = error.message;
    generateButton.disabled = false;
  }
});

function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    if (!activeJobId) return;
    const job = await fetch(`/api/jobs/${activeJobId}`).then((response) => response.json());
    renderJob(job);
    if (job.status === "complete" || job.status === "failed") {
      clearInterval(pollTimer);
      pollTimer = null;
      generateButton.disabled = false;
      if (job.status === "complete" && job.resultUrl) {
        await loadModel(job.resultUrl);
        downloadLink.href = job.resultUrl;
        downloadLink.classList.remove("disabled");
      }
    }
  }, 1500);
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
  jobTitle.textContent = job.status === "complete" ? "Model ready" : `Job ${job.status}`;
  jobStage.textContent = job.status === "complete" ? completeStageText(job) : job.stage;
  logOutput.textContent = job.log.length ? job.log.join("\n") : "Starting...";
  logOutput.scrollTop = logOutput.scrollHeight;
}

renderViewMode();
refreshStatus();
