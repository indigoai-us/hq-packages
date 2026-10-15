/*! HQ Booking embed. One script for three modes:
 *
 *   Inline:        <div data-hq-booking="intro-call"></div>
 *   Popup button:  <button data-hq-booking="intro-call" data-hq-mode="popup-button">Book a call</button>
 *   Popup text:    <a href="https://APP/intro-call" data-hq-booking="intro-call" data-hq-mode="popup-text">Book a call</a>
 *   then:          <script src="https://APP/embed.js" async></script>
 *
 * data-hq-booking="" (empty) shows the company page. Optional attributes:
 * data-hq-name, data-hq-email (prefill), data-hq-params ("a_company=Acme&utm_source=site"),
 * data-hq-text (label when the script makes the button), data-hq-height (inline start height).
 * The script-made button reads --hqb-primary, --hqb-on-primary, --hqb-radius and --hqb-font from the host page.
 * The host page's own name, email, a_* and utm_* URL parameters are passed through.
 *
 * Events: the booking page posts {type:"hq-booking:booked", bookingId, eventType, start}
 * to this window, and this script also fires a "hq-booking:booked" DOM event on the
 * element and on document (event.detail holds the same fields).
 * JS API: HQBooking.open("intro-call", {name, email, params}), HQBooking.close(), HQBooking.init(root).
 */
(function () {
  "use strict";
  var doc = typeof document !== "undefined" ? document : null;
  var win = typeof window !== "undefined" ? window : null;

  var PASS = /^(name|email|a_[A-Za-z0-9_-]+|utm_(source|medium|campaign|term|content))$/;

  function frameUrl(base, eventTypeId, mode, opts) {
    opts = opts || {};
    var path = eventTypeId ? "/" + encodeURIComponent(eventTypeId) : "/";
    var q = new URLSearchParams();
    if (opts.hostSearch) {
      new URLSearchParams(opts.hostSearch).forEach(function (v, k) {
        if (PASS.test(k)) q.set(k, v);
      });
    }
    if (opts.params) {
      new URLSearchParams(opts.params).forEach(function (v, k) {
        if (PASS.test(k) || k === "duration" || k === "date" || k === "tz" || k === "hour") q.set(k, v);
      });
    }
    if (opts.name) q.set("name", opts.name);
    if (opts.email) q.set("email", opts.email);
    q.set("embed", "1");
    q.set("mode", mode);
    if (opts.hostOrigin) q.set("embed_origin", opts.hostOrigin);
    return base + path + "?" + q.toString();
  }

  var api = { _frameUrl: frameUrl, version: "0.1.0" };
  if (!doc || !win) {
    if (typeof globalThis !== "undefined") globalThis.HQBooking = api;
    return;
  }
  if (win.HQBooking && win.HQBooking.version) return; // loaded twice

  var script = doc.currentScript;
  var base = (script && script.getAttribute("data-hq-base")) || (script && script.src ? new URL(script.src, location.href).origin : location.origin);
  var frames = [];
  var overlay = null;
  var lastFocus = null;
  var popupSource = null;

  function injectStyle() {
    if (doc.getElementById("hq-booking-embed-style")) return;
    var s = doc.createElement("style");
    s.id = "hq-booking-embed-style";
    s.textContent =
      ".hqb-frame{display:block;width:100%;border:0;min-height:320px;background:transparent;color-scheme:normal}" +
      ".hqb-overlay{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(17,17,17,.42);backdrop-filter:blur(2px)}" +
      ".hqb-dialog{position:relative;width:min(1040px,100%);height:min(760px,100%);background:#fff;border-radius:14px;box-shadow:0 24px 80px rgba(0,0,0,.25);overflow:hidden}" +
      ".hqb-dialog .hqb-frame{height:100%}" +
      ".hqb-close{position:absolute;top:10px;right:10px;z-index:1;width:36px;height:36px;border-radius:999px;border:1px solid rgba(0,0,0,.12);background:#fff;color:#1b1b1a;cursor:pointer;display:flex;align-items:center;justify-content:center}" +
      ".hqb-close:focus-visible{outline:2px solid #1b1b1a;outline-offset:2px}" +
      ".hqb-button{font:500 15px/1 var(--hqb-font,system-ui,-apple-system,sans-serif);padding:12px 18px;border-radius:var(--hqb-radius,10px);border:0;background:var(--hqb-primary,#1b1b1a);color:var(--hqb-on-primary,#fff);cursor:pointer}" +
      "@media (max-width:640px){.hqb-overlay{padding:0}.hqb-dialog{height:100%;border-radius:0}}";
    doc.head.appendChild(s);
  }

  function optsFrom(el) {
    return {
      name: el.getAttribute("data-hq-name") || "",
      email: el.getAttribute("data-hq-email") || "",
      params: el.getAttribute("data-hq-params") || "",
      hostSearch: location.search,
      hostOrigin: location.origin,
    };
  }

  function makeFrame(url, title) {
    var f = doc.createElement("iframe");
    f.className = "hqb-frame";
    f.src = url;
    f.title = title || "Book a time";
    f.setAttribute("loading", "lazy");
    f.setAttribute("allow", "clipboard-write");
    return f;
  }

  function mountInline(el) {
    var id = el.getAttribute("data-hq-booking") || "";
    var f = makeFrame(frameUrl(base, id, "inline", optsFrom(el)), el.getAttribute("data-hq-title"));
    f.style.height = (parseInt(el.getAttribute("data-hq-height"), 10) || 700) + "px";
    el.innerHTML = "";
    el.appendChild(f);
    frames.push({ frame: f, el: el });
  }

  function close() {
    if (!overlay) return;
    overlay.remove();
    overlay = null;
    popupSource = null;
    doc.documentElement.style.overflow = "";
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  function open(eventTypeId, opts, sourceEl) {
    injectStyle();
    close();
    opts = opts || {};
    lastFocus = doc.activeElement;
    popupSource = sourceEl || null;
    overlay = doc.createElement("div");
    overlay.className = "hqb-overlay";
    var dialog = doc.createElement("div");
    dialog.className = "hqb-dialog";
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-label", opts.title || "Book a time");
    var btn = doc.createElement("button");
    btn.type = "button";
    btn.className = "hqb-close";
    btn.setAttribute("aria-label", "Close");
    btn.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>';
    btn.addEventListener("click", close);
    var f = makeFrame(frameUrl(base, eventTypeId || "", opts.mode || "popup-button", { name: opts.name, email: opts.email, params: opts.params, hostSearch: location.search, hostOrigin: location.origin }), opts.title);
    f.removeAttribute("loading");
    dialog.appendChild(btn);
    dialog.appendChild(f);
    overlay.appendChild(dialog);
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay) close();
    });
    overlay.addEventListener("keydown", function (e) {
      if (e.key === "Escape") close();
      if (e.key === "Tab") {
        // Keep focus inside: the close button and the frame.
        if (e.shiftKey && doc.activeElement === btn) {
          e.preventDefault();
          f.focus();
        } else if (!e.shiftKey && doc.activeElement === f) {
          e.preventDefault();
          btn.focus();
        }
      }
    });
    doc.body.appendChild(overlay);
    doc.documentElement.style.overflow = "hidden";
    btn.focus();
    frames.push({ frame: f, el: sourceEl || doc.body, popup: true });
  }

  function mountPopup(el, mode) {
    var id = el.getAttribute("data-hq-booking") || "";
    var target = el;
    var tag = el.tagName.toLowerCase();
    if (mode === "popup-button" && tag !== "button" && tag !== "a") {
      injectStyle();
      target = doc.createElement("button");
      target.type = "button";
      target.className = "hqb-button";
      target.textContent = el.getAttribute("data-hq-text") || "Book a time";
      el.appendChild(target);
    }
    target.addEventListener("click", function (e) {
      if (e.metaKey || e.ctrlKey || e.shiftKey) return; // let a link open in a new tab
      e.preventDefault();
      var o = optsFrom(el);
      o.mode = mode;
      o.title = el.getAttribute("data-hq-title") || "";
      open(id, o, el);
    });
  }

  function init(root) {
    (root || doc).querySelectorAll("[data-hq-booking]").forEach(function (el) {
      if (el.getAttribute("data-hq-ready")) return;
      el.setAttribute("data-hq-ready", "1");
      var mode = el.getAttribute("data-hq-mode") || "inline";
      if (mode === "inline") {
        injectStyle();
        mountInline(el);
      } else if (mode === "popup-button" || mode === "popup-text") mountPopup(el, mode);
    });
  }

  function entryFor(source) {
    for (var i = 0; i < frames.length; i++) if (frames[i].frame.contentWindow === source) return frames[i];
    return null;
  }

  win.addEventListener("message", function (e) {
    if (e.origin !== base || !e.data || typeof e.data.type !== "string") return;
    var entry = entryFor(e.source);
    if (!entry) return;
    if (e.data.type === "hq-booking:resize" && typeof e.data.height === "number") {
      var h = Math.max(320, Math.min(4000, Math.ceil(e.data.height)));
      // A popup fits its content up to the window height (full screen on phones).
      if (entry.popup) {
        var dialog = entry.frame.parentNode;
        if (dialog && dialog.style && win.innerWidth > 640) dialog.style.height = Math.min(h, win.innerHeight - 48) + "px";
      } else entry.frame.style.height = h + "px";
    }
    if (e.data.type === "hq-booking:booked") {
      var detail = { bookingId: e.data.bookingId, eventType: e.data.eventType, start: e.data.start };
      var el = entry.el || popupSource;
      if (el && el.dispatchEvent) el.dispatchEvent(new CustomEvent("hq-booking:booked", { detail: detail, bubbles: true }));
      if (el !== doc) doc.dispatchEvent(new CustomEvent("hq-booking:booked", { detail: detail }));
      if (typeof e.data.redirectUrl === "string" && /^https?:\/\//.test(e.data.redirectUrl)) {
        setTimeout(function () {
          location.assign(e.data.redirectUrl);
        }, 1200);
      }
    }
  });

  api.init = init;
  api.open = function (eventTypeId, opts) {
    open(eventTypeId, opts || {}, null);
  };
  api.close = close;
  api.base = base;
  win.HQBooking = api;

  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", function () { init(); });
  else init();
})();
