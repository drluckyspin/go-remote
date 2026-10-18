// Browser compatibility layer injected by go-remote-ingress into every herdr-web-ui page served through BitBang.
// BitBang's iframe and proxy change browser behaviour that herdr-web-ui relies on, while go-remote cannot change
// either upstream project. This restores the scanned-link query, marks the app's same-origin writes for herdr's
// CSRF check, disables service-worker features that would register on bitba.ng, decorates the About page, and names
// the tab Go Remote.
(() => {
  "use strict";

  // BitBang's xhr-shim, which runs before this script, strips its /__device__/<session> prefix from the
  // address and drops the query with it, so the pairing code and the pane in a scanned link would never
  // reach the app. The navigation entry still holds the address the frame was loaded with.
  const [navigation] = performance.getEntriesByType("navigation");
  if (navigation && location.search === "") {
    try {
      const loaded = new URL(navigation.name);
      if (loaded.search !== "" && loaded.pathname.startsWith("/__device__/")) {
        history.replaceState(history.state, "", location.pathname + loaded.search + location.hash);
      }
    } catch {
      // an unreadable entry leaves the address as BitBang set it
    }
  }

  // herdr-web-ui sizes its shell to window.visualViewport, which is how it keeps the key bar and the prompt above a
  // phone's keyboard. iOS shrinks the visual viewport of the top-level page only, so inside BitBang's frame the
  // app saw a full-height screen and left the last lines under the keyboard. The frame is same-origin with
  // bitba.ng, so the app is given the parent's viewport, which does shrink. This runs before the app's own scripts.
  try {
    const outer = window.parent !== window ? window.parent.visualViewport : null;
    if (outer) Object.defineProperty(window, "visualViewport", { configurable: true, get: () => outer });
  } catch {
    // a parent that cannot be read leaves the app with its own viewport
  }

  const MUTATING = /^(?:POST|PUT|PATCH|DELETE)$/i;

  function sameOrigin(url) {
    try {
      return new URL(url, location.href).origin === location.origin;
    } catch {
      return false;
    }
  }

  // herdr-web-ui accepts a state-changing request without an Origin header only when it carries
  // x-herdr-machine. BitBang's proxy never forwards Origin, so the app's own requests say so here.
  // CSRF protection holds: another site cannot add a custom header to a request it sends here.
  const nativeFetch = window.fetch;
  window.fetch = function fetch(input, init) {
    const request = input instanceof Request ? input : null;
    const method = (init && init.method) || (request ? request.method : "GET");
    const url = request ? request.url : String(input);
    if (MUTATING.test(method) && sameOrigin(url)) {
      const headers = new Headers((init && init.headers) || (request ? request.headers : undefined));
      headers.set("x-herdr-machine", "1");
      init = Object.assign({}, init, { headers });
    }
    return nativeFetch.call(window, input, init);
  };

  const xhr = XMLHttpRequest.prototype;
  const nativeOpen = xhr.open;
  const nativeSend = xhr.send;
  xhr.open = function open(method, url, ...rest) {
    this.__goRemoteMutating = MUTATING.test(String(method)) && sameOrigin(String(url));
    return nativeOpen.call(this, method, url, ...rest);
  };
  xhr.send = function send(body) {
    if (this.__goRemoteMutating) {
      try {
        this.setRequestHeader("x-herdr-machine", "1");
      } catch {
        // the request was not opened; send reports that itself
      }
    }
    return nativeSend.call(this, body);
  };

  // The frame is same-origin with bitba.ng and controlled by BitBang's service worker. The app's own
  // registration (/sw.js, scope /) and push subscription would land on BitBang's, so both fail here
  // the way they do in a browser without service workers. Alerts come from ntfy instead.
  if ("serviceWorker" in navigator) {
    const container = navigator.serviceWorker;
    const unavailable = () =>
      Promise.reject(new DOMException("Service workers are unavailable over BitBang", "SecurityError"));
    const define = (name, descriptor) => {
      try {
        Object.defineProperty(container, name, Object.assign({ configurable: true }, descriptor));
      } catch {
        // a browser that refuses leaves the app to its own error handling
      }
    };
    define("register", { value: unavailable });
    define("getRegistration", { value: () => Promise.resolve(undefined) });
    define("getRegistrations", { value: () => Promise.resolve([]) });
    define("ready", { get: () => new Promise(() => {}) });
  }
  try {
    delete window.PushManager;
  } catch {
    // not configurable here; push still fails at registration
  }

  // The upstream About page exposes controls and telemetry that do not apply in this locked-down deployment. Replace
  // it with cards for the components that make go-remote work. The upstream sections are hidden by a stylesheet and
  // only read for their versions, never removed or edited: React owns them, and removing a node React rendered breaks
  // its next render. A stylesheet also beats the app's own `display` on them, which the `hidden` attribute does not.
  const VERSION = "__GO_REMOTE_VERSION__";

  const aboutStyle = document.createElement("style");
  // The app caps descriptions at 54ch to leave room for a control beside them; these rows have none.
  aboutStyle.textContent =
    "[data-go-remote-about] .settings-section:not(.go-remote-about) { display: none !important; }" +
    " .go-remote-about .settings-row-text > .settings-description { max-width: none; }";
  (document.head || document.documentElement).appendChild(aboutStyle);

  function aboutRow(label, detail, href, versionFrom) {
    const row = document.createElement("div");
    row.className = "settings-row";
    const copy = document.createElement("div");
    copy.className = "settings-row-text";
    const name = document.createElement("span");
    name.className = "settings-label";
    name.textContent = label;
    copy.appendChild(name);
    if (detail) {
      const note = document.createElement("span");
      note.className = "settings-description";
      note.textContent = detail;
      if (versionFrom) {
        const version = document.createElement("span");
        version.dataset.goRemoteVersion = versionFrom;
        note.appendChild(version);
      }
      copy.appendChild(note);
    }
    if (href) {
      const link = document.createElement("a");
      link.className = "settings-link";
      link.href = href;
      link.target = "_blank";
      link.rel = "noreferrer";
      link.textContent = new URL(href).host + new URL(href).pathname;
      copy.appendChild(link);
    }
    row.appendChild(copy);
    return row;
  }

  // The upstream sections render after their status requests answer, often after the cards are built, so versions
  // are filled in on every change. Each section's first hint says "Running <version>" in the app's language.
  function refreshVersions(container) {
    for (const span of container.querySelectorAll("[data-go-remote-version]")) {
      const hint = container.querySelector(span.dataset.goRemoteVersion + " .settings-hint");
      const match = hint?.textContent?.match(/\d+(?:\.\d+)+/);
      const text = match ? " Running v" + match[0] + "." : "";
      if (span.textContent !== text) span.textContent = text;
    }
  }

  function aboutSection(title, rows) {
    const section = document.createElement("section");
    section.className = "settings-section go-remote-about";
    const sectionTitle = document.createElement("h3");
    sectionTitle.textContent = title;
    const card = document.createElement("div");
    card.className = "settings-card";
    for (const [label, detail, href, versionFrom] of rows) card.appendChild(aboutRow(label, detail, href, versionFrom));
    section.append(sectionTitle, card);
    return section;
  }

  function decorateAbout(herdrAbout) {
    herdrAbout.dataset.goRemote = "";
    const container = herdrAbout.parentElement;
    const first = container?.querySelector(".settings-section");
    if (!container || !first) return;

    const version = /^\d/.test(VERSION) ? VERSION : "development build";
    first.before(
      aboutSection("Go Remote", [
        [
          "Go Remote",
          "Your coding agent session, securely on your phone. Version " + version + ".",
          "https://github.com/drluckyspin/go-remote",
        ],
        [
          "Built with",
          "go-remote would not be possible without the amazing work in herdr-web-ui, herdr, and BitBang. A huge thank you to all three projects.",
        ],
      ]),
      aboutSection("herdr web ui", [
        [
          "herdr web ui",
          "A browser and phone client for herdr.",
          "https://github.com/devswha/herdr-web-ui",
          ".settings-updates",
        ],
      ]),
      aboutSection("herdr", [
        [
          "herdr",
          "herdr manages all our coding agent session terminals.",
          "https://github.com/herdrdev/herdr",
          ".settings-herdr-update",
        ],
      ]),
      aboutSection("BitBang", [
        [
          "BitBang",
          "An encrypted peer-to-peer link that connects this workspace to your phone.",
          "https://github.com/RichLegrand/BitBang",
        ],
      ]),
    );
    container.dataset.goRemoteAbout = "";
  }

  // refreshVersions changes text only when it differs, so its own writes settle instead of feeding the observer.
  new MutationObserver(() => {
    const herdrAbout = document.querySelector(".settings-about:not([data-go-remote])");
    if (herdrAbout) decorateAbout(herdrAbout);
    for (const container of document.querySelectorAll("[data-go-remote-about]")) refreshVersions(container);
  }).observe(document.documentElement, { childList: true, subtree: true });

  // BitBang copies the frame's title to the tab once, when the frame loads, so the title must say Go Remote by then.
  // The app also writes "<name> · herdr" and "<file> · herdr web ui" later; those are renamed as they are set.
  const rebrand = (title) => title.replace(/(^|\s·\s)herdr(?: web ui)?$/, "$1Go Remote");
  const titleDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, "title");
  if (titleDescriptor && titleDescriptor.get && titleDescriptor.set) {
    try {
      Object.defineProperty(document, "title", {
        configurable: true,
        get: () => titleDescriptor.get.call(document),
        set: (value) => titleDescriptor.set.call(document, rebrand(String(value))),
      });
    } catch {
      // the parsed <title> is still renamed below
    }
  }
  new MutationObserver(() => {
    const title = document.title;
    if (rebrand(title) !== title) document.title = rebrand(title);
  }).observe(document.head || document.documentElement, { childList: true, subtree: true, characterData: true });

  // iOS zooms into a focused field whose text is under 16px, and only the parent page could stop it.
  const style = document.createElement("style");
  style.textContent = "@media (pointer: coarse) { input, textarea, select { font-size: max(16px, 1em) !important; } }";
  (document.head || document.documentElement).appendChild(style);
})();
