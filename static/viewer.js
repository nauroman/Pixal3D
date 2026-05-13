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
let autoLevelEnabled = true;

const WORLD_UP = new THREE.Vector3(0, 1, 0);
const MAX_AUTO_LEVEL_ANGLE = THREE.MathUtils.degToRad(55);
const MIN_AUTO_LEVEL_ANGLE = THREE.MathUtils.degToRad(1.5);

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

function collectModelVertices(object, maxVertices = 18000) {
  const vertices = [];
  const vertex = new THREE.Vector3();
  const meshes = [];
  let totalVertices = 0;

  object.updateWorldMatrix(true, true);
  object.traverse((child) => {
    const position = child.isMesh ? child.geometry?.attributes?.position : null;
    if (!position) return;

    meshes.push({ mesh: child, position });
    totalVertices += position.count;
  });

  const step = Math.max(1, Math.ceil(totalVertices / maxVertices));
  meshes.forEach(({ mesh, position }) => {
    for (let index = 0; index < position.count; index += step) {
      vertex.fromBufferAttribute(position, index).applyMatrix4(mesh.matrixWorld);
      vertices.push(vertex.clone());
    }
  });

  return vertices;
}

function solveLinear3(matrix, vector) {
  const rows = matrix.map((row, index) => [...row, vector[index]]);

  for (let pivot = 0; pivot < 3; pivot += 1) {
    let bestRow = pivot;
    for (let row = pivot + 1; row < 3; row += 1) {
      if (Math.abs(rows[row][pivot]) > Math.abs(rows[bestRow][pivot])) {
        bestRow = row;
      }
    }

    if (Math.abs(rows[bestRow][pivot]) < 1e-8) {
      return null;
    }

    if (bestRow !== pivot) {
      [rows[pivot], rows[bestRow]] = [rows[bestRow], rows[pivot]];
    }

    const divisor = rows[pivot][pivot];
    for (let column = pivot; column < 4; column += 1) {
      rows[pivot][column] /= divisor;
    }

    for (let row = 0; row < 3; row += 1) {
      if (row === pivot) continue;

      const factor = rows[row][pivot];
      for (let column = pivot; column < 4; column += 1) {
        rows[row][column] -= factor * rows[pivot][column];
      }
    }
  }

  return [rows[0][3], rows[1][3], rows[2][3]];
}

function supportPlaneNormal(vertices) {
  if (vertices.length < 24) return null;

  let minY = Infinity;
  let maxY = -Infinity;
  vertices.forEach((point) => {
    minY = Math.min(minY, point.y);
    maxY = Math.max(maxY, point.y);
  });

  const spanY = Math.max(maxY - minY, 0.001);
  const bottomLimit = minY + spanY * 0.16;
  let supportPoints = vertices.filter((point) => point.y <= bottomLimit);

  if (supportPoints.length < 24) {
    supportPoints = [...vertices]
      .sort((a, b) => a.y - b.y)
      .slice(0, Math.max(24, Math.floor(vertices.length * 0.12)));
  }

  let sumX = 0;
  let sumY = 0;
  let sumZ = 0;
  let sumXX = 0;
  let sumZZ = 0;
  let sumXZ = 0;
  let sumXY = 0;
  let sumZY = 0;

  supportPoints.forEach((point) => {
    sumX += point.x;
    sumY += point.y;
    sumZ += point.z;
    sumXX += point.x * point.x;
    sumZZ += point.z * point.z;
    sumXZ += point.x * point.z;
    sumXY += point.x * point.y;
    sumZY += point.z * point.y;
  });

  const solution = solveLinear3(
    [
      [sumXX, sumXZ, sumX],
      [sumXZ, sumZZ, sumZ],
      [sumX, sumZ, supportPoints.length],
    ],
    [sumXY, sumZY, sumY],
  );

  if (!solution) return null;

  const [slopeX, slopeZ] = solution;
  const normal = new THREE.Vector3(-slopeX, 1, -slopeZ).normalize();
  if (normal.y < 0) {
    normal.negate();
  }

  const angle = normal.angleTo(WORLD_UP);
  if (!Number.isFinite(angle) || angle < MIN_AUTO_LEVEL_ANGLE || angle > MAX_AUTO_LEVEL_ANGLE) {
    return null;
  }

  return normal;
}

function placeModelOnGrid() {
  if (!currentModel) return;

  currentModel.position.set(0, 0, 0);
  currentModel.quaternion.identity();
  currentModel.updateWorldMatrix(true, true);

  if (autoLevelEnabled) {
    const normal = supportPlaneNormal(collectModelVertices(currentModel));
    if (normal) {
      currentModel.quaternion.setFromUnitVectors(normal, WORLD_UP);
      currentModel.updateWorldMatrix(true, true);
    }
  }

  const box = new THREE.Box3().setFromObject(currentModel);
  const center = box.getCenter(new THREE.Vector3());
  currentModel.position.set(-center.x, -box.min.y, -center.z);
  currentModel.updateWorldMatrix(true, true);
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

  currentModel = new THREE.Group();
  currentModel.name = "Pixal3DPreviewRoot";
  currentModel.add(gltf.scene);
  prepareModelMaterials(currentModel);

  scene.add(currentModel);
  placeModelOnGrid();
  applyViewMode();

  const box = new THREE.Box3().setFromObject(currentModel);
  const size = box.getSize(new THREE.Vector3());
  const largest = Math.max(size.x, size.y, size.z, 0.001);
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

export function getAutoLevel() {
  return autoLevelEnabled;
}

export function setAutoLevel(enabled) {
  autoLevelEnabled = Boolean(enabled);
  placeModelOnGrid();
  return autoLevelEnabled;
}

export function toggleAutoLevel() {
  return setAutoLevel(!autoLevelEnabled);
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
