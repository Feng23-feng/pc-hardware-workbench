(() => {
  const backdropId = "dse-crt-backdrop";
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const scanDuration = 2250;
  const pauseAfterScan = 20000;
  const pauseAfterInteraction = 25000;
  const sceneIndexByKey = {
    space: 0,
    gpu: 1,
    cpu: 2,
    fan: 3
  };
  let settleTimer;
  let sceneChangeTimer;
  let loopTimer;
  let interactionTimer;
  let interactionPaused = false;
  let hasScanned = false;
  let currentScene = 0;
  let backdrop;
  let scenes;

  function pointOnCircle(radius, angleDegrees) {
    const angle = angleDegrees * Math.PI / 180;
    return `${(Math.sin(angle) * radius).toFixed(2)} ${(-Math.cos(angle) * radius).toFixed(2)}`;
  }

  function createFanBlade(innerRadius, outerRadius, sweep, innerHalfWidth, outerHalfWidth) {
    const points = [];
    const radialSteps = 24;
    const arcSteps = 8;

    for (let index = 0; index <= radialSteps; index += 1) {
      const progress = index / radialSteps;
      const radius = innerRadius + (outerRadius - innerRadius) * progress;
      const centerAngle = sweep * Math.pow(progress, 1.2);
      const halfWidth = innerHalfWidth + (outerHalfWidth - innerHalfWidth) * Math.pow(progress, .82);
      points.push(pointOnCircle(radius, centerAngle - halfWidth));
    }

    for (let index = 1; index < arcSteps; index += 1) {
      const progress = index / arcSteps;
      points.push(pointOnCircle(outerRadius, sweep - outerHalfWidth + outerHalfWidth * 2 * progress));
    }

    for (let index = radialSteps; index >= 0; index -= 1) {
      const progress = index / radialSteps;
      const radius = innerRadius + (outerRadius - innerRadius) * progress;
      const centerAngle = sweep * Math.pow(progress, 1.2);
      const halfWidth = innerHalfWidth + (outerHalfWidth - innerHalfWidth) * Math.pow(progress, .82);
      points.push(pointOnCircle(radius, centerAngle + halfWidth));
    }

    for (let index = 1; index < arcSteps; index += 1) {
      const progress = index / arcSteps;
      points.push(pointOnCircle(innerRadius, innerHalfWidth - innerHalfWidth * 2 * progress));
    }

    return `M${points.join("L")}Z`;
  }

  function createMarkup() {
    return `
      <div class="dse-crt-grid">
        <svg viewBox="0 0 1024 620" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
          <defs>
            <radialGradient id="dseCrtFade" cx="50%" cy="46%" r="58%">
              <stop offset="0" stop-color="#080a0b" stop-opacity=".95"></stop>
              <stop offset=".48" stop-color="#080a0b" stop-opacity=".6"></stop>
              <stop offset="1" stop-color="#080a0b" stop-opacity="0"></stop>
            </radialGradient>
            <path id="dseCrtGpuFanBlade" class="dse-crt-fan-blade"></path>
            <g id="dseCrtGpuFanRotor">
              <use href="#dseCrtGpuFanBlade"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(51)"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(103)"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(154)"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(206)"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(257)"></use>
              <use href="#dseCrtGpuFanBlade" transform="rotate(309)"></use>
              <circle r="27"></circle>
              <circle class="dse-crt-rotor-cap" r="11"></circle>
            </g>
            <path id="dseCrtCaseFanBlade" class="dse-crt-fan-blade"></path>
            <g id="dseCrtCaseFanRotor">
              <use href="#dseCrtCaseFanBlade"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(51)"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(103)"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(154)"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(206)"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(257)"></use>
              <use href="#dseCrtCaseFanBlade" transform="rotate(309)"></use>
              <circle r="30"></circle>
              <circle class="dse-crt-rotor-cap" r="10"></circle>
            </g>
          </defs>

          <g class="dse-crt-scene is-active" data-scene="space">
            <g class="dse-crt-chart-lines" data-crt-reveal>
              <circle cx="760" cy="292" r="286"></circle>
              <circle cx="760" cy="292" r="220"></circle>
              <circle cx="760" cy="292" r="152"></circle>
              <circle cx="760" cy="292" r="84"></circle>
              <ellipse cx="760" cy="292" rx="286" ry="92"></ellipse>
              <ellipse cx="760" cy="292" rx="220" ry="286"></ellipse>
              <ellipse cx="760" cy="292" rx="152" ry="286"></ellipse>
              <ellipse cx="760" cy="292" rx="84" ry="286"></ellipse>
              <ellipse class="dse-crt-ecliptic" cx="760" cy="292" rx="320" ry="138" transform="rotate(-18 760 292)"></ellipse>
              <path d="M474 292H1046M760 6V578"></path>
              <path class="dse-crt-axis" d="M516 118 1004 466M516 466 1004 118"></path>
            </g>
            <g class="dse-crt-ticks" data-crt-reveal></g>
            <g class="dse-crt-nodes" data-crt-reveal></g>
          </g>

          <g class="dse-crt-scene" data-scene="gpu">
            <g class="dse-crt-scene-lines" data-crt-reveal transform="translate(58 0)">
              <path d="M318 180H982Q1010 180 1010 208V452Q1010 480 982 480H318Q290 480 290 452V208Q290 180 318 180Z"></path>
              <path d="M248 204V456H290M248 238H290M248 422H290"></path>
              <path d="M330 480H808V496H330Z"></path>
              <path d="M700 152H812V180M826 160H924V180"></path>
              <path d="M710 159V175M722 159V175M734 159V175M746 159V175M758 159V175M770 159V175M782 159V175M794 159V175"></path>
              <circle cx="402" cy="330" r="104"></circle>
              <circle cx="650" cy="330" r="104"></circle>
              <circle cx="898" cy="330" r="104"></circle>
              <circle cx="402" cy="330" r="97"></circle>
              <circle cx="650" cy="330" r="97"></circle>
              <circle cx="898" cy="330" r="97"></circle>
              <use href="#dseCrtGpuFanRotor" transform="translate(402 330)"></use>
              <use href="#dseCrtGpuFanRotor" transform="translate(650 330)"></use>
              <use href="#dseCrtGpuFanRotor" transform="translate(898 330)"></use>
            </g>
          </g>

          <g class="dse-crt-scene" data-scene="cpu">
            <g class="dse-crt-scene-lines" data-crt-reveal transform="translate(118 0)">
              <rect x="560" y="126" width="354" height="354" rx="22"></rect>
              <path class="dse-crt-amd-ihs" d="M609 154Q585 154 585 178V212H615V262H585V346H615V400H585Q585 434 609 458H643V428H693V458H781V428H831V458H865Q889 458 889 434V400H859V350H889V266H859V212H889V178Q889 154 865 154H831V184H781V154H693V184H643V154Z"></path>
              <path class="dse-crt-amd-inset" d="M615 165H639V194H699V165H775V194H835V165H859V205H848V266H878V349H848V408H859V422Q868 429 861 439H833V419H785V448H689V419H641V448H613Q605 440 613 430V408H628V350H601V266H628V205H615Z"></path>
              <path d="M574 142H596L574 164Z"></path>
              <circle class="dse-crt-amd-dimple" cx="617" cy="181" r="5"></circle>
            </g>
          </g>

          <g class="dse-crt-scene" data-scene="fan">
            <g class="dse-crt-scene-lines" data-crt-reveal transform="translate(112 0)">
              <rect x="574" y="86" width="400" height="400" rx="26"></rect>
              <circle cx="774" cy="286" r="176"></circle>
              <circle cx="774" cy="286" r="166"></circle>
              <circle cx="610" cy="122" r="10"></circle>
              <circle cx="938" cy="122" r="10"></circle>
              <circle cx="610" cy="450" r="10"></circle>
              <circle cx="938" cy="450" r="10"></circle>
              <path d="M591 141 629 103M919 141 957 103M591 431 629 469M919 431 957 469"></path>
              <use href="#dseCrtCaseFanRotor" transform="translate(774 286)"></use>
            </g>
          </g>

          <rect width="1024" height="620" fill="url(#dseCrtFade)" class="dse-crt-focus-mask"></rect>
        </svg>
      </div>
      <div class="dse-crt-raster"></div>
      <div class="dse-crt-scan-beam"></div>
      <div class="dse-crt-vignette"></div>
    `;
  }

  function populateSpaceScene() {
    const tickGroup = backdrop.querySelector(".dse-crt-ticks");
    const nodeGroup = backdrop.querySelector(".dse-crt-nodes");
    const centerX = 760;
    const centerY = 292;
    const radius = 286;

    for (let index = 0; index < 36; index += 1) {
      const angle = index * Math.PI / 18;
      const inner = radius - (index % 3 === 0 ? 12 : 7);
      const outer = radius + 4;
      const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
      line.setAttribute("x1", String(centerX + Math.cos(angle) * inner));
      line.setAttribute("y1", String(centerY + Math.sin(angle) * inner));
      line.setAttribute("x2", String(centerX + Math.cos(angle) * outer));
      line.setAttribute("y2", String(centerY + Math.sin(angle) * outer));
      tickGroup.appendChild(line);
    }

    const goldenAngle = Math.PI * (3 - Math.sqrt(5));
    for (let index = 1; index <= 82; index += 1) {
      const distance = radius * Math.sqrt(index / 83);
      const angle = index * goldenAngle;
      const node = document.createElementNS("http://www.w3.org/2000/svg", "circle");
      node.setAttribute("cx", String(centerX + Math.cos(angle) * distance));
      node.setAttribute("cy", String(centerY + Math.sin(angle) * distance));
      node.setAttribute("r", "1.25");
      nodeGroup.appendChild(node);
    }
  }

  function showScene(index) {
    scenes.forEach((scene, sceneIndex) => {
      scene.classList.toggle("is-active", sceneIndex === index);
    });
    currentScene = index;
    backdrop.dataset.scene = scenes[index].dataset.scene;
  }

  function clearCycleTimers() {
    window.clearTimeout(settleTimer);
    window.clearTimeout(sceneChangeTimer);
    window.clearTimeout(loopTimer);
  }

  function scheduleInteractionResume() {
    window.clearTimeout(interactionTimer);
    interactionTimer = window.setTimeout(() => {
      interactionPaused = false;
      if (!document.hidden && !reducedMotion.matches) startScan();
    }, pauseAfterInteraction);
  }

  function pauseForInteraction() {
    if (!backdrop || reducedMotion.matches) return;
    interactionPaused = true;
    clearCycleTimers();
    backdrop.classList.remove("is-scanning");
    scheduleInteractionResume();
  }

  function setSceneIntent(sceneKey) {
    if (!backdrop) return;
    const sceneIndex = sceneIndexByKey[sceneKey];
    if (Number.isInteger(sceneIndex)) {
      showScene(sceneIndex);
      pauseForInteraction();
      return;
    }
    interactionPaused = false;
    window.clearTimeout(interactionTimer);
    clearCycleTimers();
    if (!document.hidden && !reducedMotion.matches) {
      window.setTimeout(startScan, 500);
    }
  }

  function startScan() {
    if (
      hasScanned ||
      reducedMotion.matches ||
      interactionPaused ||
      document.hidden ||
      !backdrop
    ) {
      return;
    }

    hasScanned = true;
    clearCycleTimers();
    backdrop.classList.remove("is-scanning");
    backdrop.classList.add("is-replaying");
    void backdrop.offsetWidth;
    backdrop.classList.remove("is-replaying");
    backdrop.classList.add("is-scanning");

    settleTimer = window.setTimeout(() => {
      backdrop.classList.remove("is-scanning");
    }, scanDuration);
  }

  function init() {
    const root = document.getElementById("dse-root");
    if (!root || document.getElementById(backdropId)) return;

    backdrop = document.createElement("div");
    backdrop.id = backdropId;
    backdrop.setAttribute("aria-hidden", "true");
    backdrop.innerHTML = createMarkup();
    root.prepend(backdrop);

    document.getElementById("dseCrtGpuFanBlade")
      .setAttribute("d", createFanBlade(24, 93, 34, 5, 14));
    document.getElementById("dseCrtCaseFanBlade")
      .setAttribute("d", createFanBlade(32, 158, 36, 6, 16));

    populateSpaceScene();
    scenes = Array.from(backdrop.querySelectorAll(".dse-crt-scene"));
    showScene(0);

    const initialScene = document.documentElement.dataset.crtSceneIntent || "";
    const initialSceneIndex = sceneIndexByKey[initialScene];
    if (Number.isInteger(initialSceneIndex)) {
      showScene(initialSceneIndex);
      interactionPaused = true;
      scheduleInteractionResume();
    } else if (!reducedMotion.matches) {
      startScan();
    }

    document.getElementById("dse-root")?.addEventListener("pointerdown", event => {
      if (event.target.closest(".dse-shell")) pauseForInteraction();
    }, { passive: true });
    document.getElementById("dse-root")?.addEventListener("focusin", event => {
      if (event.target.closest(".dse-shell")) pauseForInteraction();
    });
    document.getElementById("dse-root")?.addEventListener("scroll", () => {
      if (!document.hidden) pauseForInteraction();
    }, { passive: true });
    window.addEventListener("pcwb:crt-scene-intent", event => {
      setSceneIntent(event.detail?.scene);
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        clearCycleTimers();
        backdrop.classList.remove("is-scanning");
      } else if (!reducedMotion.matches) {
        if (interactionPaused) scheduleInteractionResume();
        else startScan();
      }
    });

    reducedMotion.addEventListener?.("change", () => {
      clearCycleTimers();
      window.clearTimeout(interactionTimer);
      backdrop.classList.remove("is-scanning", "is-replaying");
      if (!reducedMotion.matches) {
        interactionPaused = false;
        startScan();
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
