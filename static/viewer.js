import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

const canvas = document.getElementById("viewer-canvas");
const viewerElement = document.getElementById("viewer");

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0a0c0f);

const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 1000);
camera.position.set(2.5, 1.8, 2.8);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.target.set(0, 0, 0);

const hemi = new THREE.HemisphereLight(0xffffff, 0x1a1d24, 1.8);
scene.add(hemi);

const key = new THREE.DirectionalLight(0xffffff, 2.3);
key.position.set(3.5, 5, 4);
scene.add(key);

const fill = new THREE.DirectionalLight(0x88b7ff, 0.8);
fill.position.set(-4, 2, -3);
scene.add(fill);

const grid = new THREE.GridHelper(4, 24, 0x42505e, 0x242b33);
grid.position.y = -0.01;
scene.add(grid);

const VIEW_MODES = [
  {
    id: "wireframe",
    label: "Wire",
    description: "Wireframe model without texture",
  },
  {
    id: "solid",
    label: "Solid",
    description: "Solid model without texture",
  },
  {
    id: "textured",
    label: "Textured",
    description: "Solid model with texture",
  },
];

let viewModeIndex = VIEW_MODES.findIndex((mode) => mode.id === "textured");
let currentModel = null;

function resizeRenderer() {
  const rect = canvas.parentElement.getBoundingClientRect();
  const width = Math.max(1, Math.floor(rect.width));
  const height = Math.max(1, Math.floor(rect.height));
  const needsResize = canvas.width !== Math.floor(width * renderer.getPixelRatio()) ||
    canvas.height !== Math.floor(height * renderer.getPixelRatio());
  if (needsResize) {
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
}

function materialsFor(material) {
  return Array.isArray(material) ? material : [material];
}

function disposeMaterial(material, seenMaterials, seenTextures) {
  materialsFor(material).forEach((entry) => {
    if (!entry || seenMaterials.has(entry)) return;

    seenMaterials.add(entry);
    Object.values(entry).forEach((value) => {
      if (value && value.isTexture && !seenTextures.has(value)) {
        seenTextures.add(value);
        value.dispose();
      }
    });
    entry.dispose();
  });
}

function disposeObject(object) {
  const seenMaterials = new Set();
  const seenTextures = new Set();

  object.traverse((child) => {
    if (child.geometry) child.geometry.dispose();
    if (child.material) {
      disposeMaterial(child.material, seenMaterials, seenTextures);
    }
    if (child.userData.viewerOriginalMaterial) {
      disposeMaterial(child.userData.viewerOriginalMaterial, seenMaterials, seenTextures);
    }
    if (child.userData.viewerMaterials) {
      disposeMaterial(child.userData.viewerMaterials.wireframe, seenMaterials, seenTextures);
      disposeMaterial(child.userData.viewerMaterials.solid, seenMaterials, seenTextures);
    }
  });
}

function materialColor(material) {
  const source = materialsFor(material).find((entry) => entry && entry.color);
  return source ? source.color.clone() : new THREE.Color(0xb9c3cf);
}

function makeViewerMaterials(originalMaterial) {
  return {
    wireframe: new THREE.MeshBasicMaterial({
      color: 0xd8e7f2,
      wireframe: true,
    }),
    solid: new THREE.MeshStandardMaterial({
      color: materialColor(originalMaterial),
      roughness: 0.85,
      metalness: 0.04,
    }),
  };
}

function prepareModelMaterials(object) {
  object.traverse((child) => {
    if (!child.isMesh || !child.material) return;

    child.userData.viewerOriginalMaterial = child.material;
    child.userData.viewerMaterials = makeViewerMaterials(child.material);
  });
}

function applyViewMode() {
  if (!currentModel) return;

  const modeId = VIEW_MODES[viewModeIndex].id;
  currentModel.traverse((child) => {
    if (!child.isMesh || !child.userData.viewerOriginalMaterial) return;

    if (modeId === "textured") {
      child.material = child.userData.viewerOriginalMaterial;
    } else {
      child.material = child.userData.viewerMaterials[modeId];
    }
  });
}

export async function loadModel(url, { resetViewOnLoad = true } = {}) {
  const loader = new GLTFLoader();
  const gltf = await loader.loadAsync(url);

  if (currentModel) {
    scene.remove(currentModel);
    disposeObject(currentModel);
  }

  currentModel = gltf.scene;
  prepareModelMaterials(currentModel);

  const box = new THREE.Box3().setFromObject(currentModel);
  const center = box.getCenter(new THREE.Vector3());
  const size = box.getSize(new THREE.Vector3());
  const largest = Math.max(size.x, size.y, size.z, 0.001);

  currentModel.position.sub(center);
  scene.add(currentModel);
  applyViewMode();

  const distance = largest * 2.2;
  camera.near = Math.max(0.001, largest / 1000);
  camera.far = Math.max(1000, largest * 20);
  camera.updateProjectionMatrix();
  if (resetViewOnLoad) {
    camera.position.set(distance, distance * 0.72, distance);
    controls.target.set(0, 0, 0);
  }
  controls.update();
  viewerElement.classList.add("has-model");
}

export function getViewMode() {
  return VIEW_MODES[viewModeIndex];
}

export function cycleViewMode() {
  viewModeIndex = (viewModeIndex + 1) % VIEW_MODES.length;
  applyViewMode();
  return getViewMode();
}

export function resetView() {
  if (!currentModel) {
    camera.position.set(2.5, 1.8, 2.8);
  } else {
    const box = new THREE.Box3().setFromObject(currentModel);
    const size = box.getSize(new THREE.Vector3());
    const largest = Math.max(size.x, size.y, size.z, 0.001);
    const distance = largest * 2.2;
    camera.position.set(distance, distance * 0.72, distance);
  }
  controls.target.set(0, 0, 0);
  controls.update();
}

function animate() {
  resizeRenderer();
  controls.update();
  renderer.render(scene, camera);
  requestAnimationFrame(animate);
}

animate();
