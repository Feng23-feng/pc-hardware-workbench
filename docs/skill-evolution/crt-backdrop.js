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
            <g class="dse-crt-scene-lines" data-crt-reveal transform="translate(-20 0)">
              <path class="dse-crt-gpu-shell" d="M304 178H968L1008 216V430L988 470H328L292 438V216Z"></path>
              <path class="dse-crt-gpu-panel" d="M312 198H958L986 228V418L970 450H340L314 426V228Z"></path>
              <path class="dse-crt-gpu-shell" d="M276 208V458H244V422H262V248H244V218Z"></path>
              <path class="dse-crt-gpu-detail" d="M274 234H322M274 416H326"></path>

              <path class="dse-crt-gpu-accent-fill" d="M370 190H486L502 204H386Z"></path>
              <path class="dse-crt-gpu-accent-fill" d="M538 190H654L670 204H554Z"></path>
              <path class="dse-crt-gpu-accent-fill" d="M704 190H850L880 210H730Z"></path>
              <path class="dse-crt-gpu-detail" d="M676 178 704 206M888 184H952L980 208"></path>
              <path class="dse-crt-gpu-detail" d="M920 212V230M934 212V230M948 212V230M962 212V230M976 212V230"></path>

              <path class="dse-crt-gpu-detail" d="M324 222H348L326 250H306Z"></path>
              <path class="dse-crt-gpu-detail" d="M498 204 532 234V264M724 204 752 232V260"></path>
              <path class="dse-crt-gpu-detail" d="M518 402 536 424H506M734 402 754 424H724"></path>
              <path class="dse-crt-gpu-metal" d="M766 226 810 198H870M932 198H968L990 220"></path>
              <path class="dse-crt-gpu-metal" d="M766 430 806 450H864M930 450H968L990 430"></path>

              <circle class="dse-crt-gpu-well" cx="410" cy="326" r="106"></circle>
              <circle class="dse-crt-gpu-ring" cx="410" cy="326" r="106"></circle>
              <circle class="dse-crt-gpu-detail" cx="410" cy="326" r="98"></circle>
              <circle class="dse-crt-gpu-well" cx="630" cy="326" r="106"></circle>
              <circle class="dse-crt-gpu-ring" cx="630" cy="326" r="106"></circle>
              <circle class="dse-crt-gpu-detail" cx="630" cy="326" r="98"></circle>
              <circle class="dse-crt-gpu-well" cx="862" cy="326" r="115"></circle>
              <circle class="dse-crt-gpu-ring dse-crt-gpu-metal" cx="862" cy="326" r="115"></circle>
              <circle class="dse-crt-gpu-ring" cx="862" cy="326" r="106"></circle>
              <circle class="dse-crt-gpu-detail" cx="862" cy="326" r="96"></circle>
              <use href="#dseCrtGpuFanRotor" transform="translate(410 326)"></use>
              <use href="#dseCrtGpuFanRotor" transform="translate(630 326)"></use>
              <use href="#dseCrtGpuFanRotor" transform="translate(862 326) scale(1.035)"></use>

              <path class="dse-crt-gpu-detail" d="M336 438V456M346 438V456M356 438V456M944 438V456M954 438V456M964 438V456"></path>
              <path class="dse-crt-gpu-accent-fill" d="M352 470H568V490H544V498H516V490H388V498H352Z"></path>
              <path class="dse-crt-gpu-detail" d="M532 470V490M586 470H628V480H586Z"></path>
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
      .setAttribute("d", createFanBlade(24, 96, 48, 4, 12));
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
