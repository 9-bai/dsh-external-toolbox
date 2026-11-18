/**
 * dsh-external-toolbox — browser half.
 *
 * The floating card (and the translation) live in the PowerShell helper, so the
 * DSH window never has to be open. The browser-side job is the "提问" hand-off:
 * when the card reports an ask intent, open a NEW session and quote the captured
 * text into that session's composer.
 *
 * Hand-written module: no build step, no imports beyond the runtime's own
 * allowlist (react), and the loader id must equal the package name.
 */
window.__ModuleLoader__.load({
  id: "dsh-external-toolbox",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    const react = require("react");

    const LATEST_ROUTE = "/toolbox/latest";
    const BEAT_ROUTE = "/toolbox/beat";
    const POLL_MS = 800;
    /** Give the freshly started session a moment to mount its composer. */
    const DRAFT_DELAY_MS = 350;

    /** Quote every line so the composer renders it as a block quote. */
    function toQuote(text) {
      return String(text)
        .split("\n")
        .map((line) => (line === "" ? ">" : "> " + line))
        .join("\n");
    }

    /** Fire-and-forget diagnostics: the host logs these lines. */
    function beat(kind, id) {
      try {
        const url = BEAT_ROUTE + "?kind=" + encodeURIComponent(kind) + "&id=" + encodeURIComponent(id || "");
        fetch(url, { cache: "no-store" }).catch(() => {});
      } catch {
        /* diagnostics only */
      }
    }

    /**
     * One poller per document: the overlay seat can re-mount the component, and a
     * fresh interval on every mount would multiply the fetch rate.
     */
    const bridge = {
      started: false,
      handled: "",
      /** Quote waiting to be written into the composer of the new session. */
      pending: "",
      /** Client navigation service, captured in apply(). */
      navigation: null,
    };

    function startNewSession() {
      const navigation = bridge.navigation;
      if (navigation !== null && navigation !== undefined && typeof navigation.startSession === "function") {
        navigation.startSession();
        return true;
      }
      // Fallback: the app routes sessions; going back to the root view is the
      // same landing page the sidebar's "new session" opens.
      try {
        if (/^\/session/.test(location.pathname)) {
          history.pushState({}, "", "/");
          window.dispatchEvent(new PopStateEvent("popstate"));
          return true;
        }
      } catch {
        /* history is unavailable; fall through */
      }
      return false;
    }

    function writeDraft(actions, text) {
      if (actions === null || actions === undefined) return false;
      if (typeof actions.setDraft !== "function") return false;
      actions.setDraft(text + "\n\n");
      return true;
    }

    /**
     * Invisible session-scoped seat: the composer overlay is the only place that
     * receives `inputActions`, which is what writing a draft requires.
     */
    function ToolboxBridge({ inputActions, sessionId }) {
      const actionsRef = react.useRef(inputActions);
      actionsRef.current = inputActions;

      // A quote that was waiting for "some session" is written into whichever
      // session this seat is now mounted for — after an ask the component
      // re-mounts for the freshly started session.
      react.useEffect(() => {
        if (bridge.pending === "") return undefined;
        const timer = setTimeout(() => {
          const text = bridge.pending;
          bridge.pending = "";
          writeDraft(actionsRef.current, text);
        }, DRAFT_DELAY_MS);
        return () => clearTimeout(timer);
      }, [sessionId]);

      react.useEffect(() => {
        let stopped = false;
        let inFlight = false;

        const tick = async () => {
          if (stopped || inFlight) return;
          inFlight = true;
          try {
            const response = await fetch(LATEST_ROUTE, {
              headers: { accept: "application/json" },
              cache: "no-store",
            });
            if (!response.ok) return;
            const data = await response.json();
            if (stopped || data === null || typeof data !== "object") return;
            if (data.intent !== "ask" || typeof data.id !== "string" || data.id === "") return;
            if (data.id === bridge.handled) return;
            bridge.handled = data.id;
            const text = typeof data.text === "string" ? data.text.trim() : "";
            if (text === "") return;
            const quote = toQuote(text);
            beat("ask", data.id);
            // Prefer a brand-new session; fall back to the current composer when
            // the navigation service is unavailable.
            bridge.pending = quote;
            if (startNewSession()) return;
            bridge.pending = "";
            writeDraft(actionsRef.current, quote);
          } catch {
            /* the host may be restarting; the next tick retries */
          } finally {
            inFlight = false;
          }
        };

        if (bridge.started) {
          return undefined;
        }
        bridge.started = true;
        beat("mount", "");
        const timer = setInterval(tick, POLL_MS);
        return () => {
          stopped = true;
          bridge.started = false;
          clearInterval(timer);
        };
      }, []);

      return null;
    }

    // Only the slot service is declared: an unavailable name in this list keeps
    // the whole browser module from activating. Navigation is looked up
    // opportunistically in apply() instead.
    const inject = ["slots"];

    // Candidate service names for "open a new session"; the probe in apply()
    // reports which ones exist so the real name can be pinned down in one pass.
    var CANDIDATES = [
      "uiWorkspace",
      "navigation",
      "navigator",
      "router",
      "shell",
      "layout",
      "workspace",
      "sessions",
      "sessionActions",
      "sessionNavigation",
      "uiNavigation",
      "app",
    ];

    var METHODS = ["startSession", "createSession", "newSession", "openSession", "start"];

    function probeServices(ctx) {
      var parts = [];
      try {
        parts.push("path=" + location.pathname + location.search);
      } catch (error) {
        parts.push("path=?");
      }
      for (var i = 0; i < CANDIDATES.length; i += 1) {
        var name = CANDIDATES[i];
        var service;
        try {
          service = ctx.get(name);
        } catch (error) {
          parts.push(name + "=threw");
          continue;
        }
        if (service === undefined || service === null) {
          parts.push(name + "=-");
          continue;
        }
        var found = [];
        for (var j = 0; j < METHODS.length; j += 1) {
          if (typeof service[METHODS[j]] === "function") {
            found.push(METHODS[j]);
          }
        }
        parts.push(name + "=" + (found.length === 0 ? "obj" : found.join("+")));
        // @deepseek-ai/dsh-client-ui-workspace registers itself as `uiWorkspace`
        // and owns startSession(); older/other builds may expose `navigation`.
        if (
          (name === "uiWorkspace" || name === "navigation") &&
          typeof service.startSession === "function" &&
          bridge.navigation === null
        ) {
          bridge.navigation = service;
        }
      }
      // Best effort: a Context may expose its registry; listing it would settle
      // the service name question in one restart.
      try {
        var root = ctx.root || ctx;
        var registry = root.registry || root.registries;
        if (registry && typeof registry === "object") {
          var keys = Object.keys(registry);
          parts.push("reg=" + keys.slice(0, 40).join(","));
        } else {
          parts.push("reg=none");
        }
      } catch (error) {
        parts.push("reg=threw");
      }
      return parts.join(" ");
    }

    function apply(ctx) {
      try {
        var probe = "none";
        try {
          probe = probeServices(ctx);
        } catch (error) {
          probe = "probe threw:" + String(error && error.message);
        }
        beat("apply", probe);
        ctx.slots.inject("conversation.input.overlay", () =>
          ctx.slots.register(
            {
              name: "conversation.input.overlay",
              id: "external-toolbox-bridge",
              order: 5,
            },
            ToolboxBridge,
          ),
        );
      } catch (error) {
        console.error("dsh-external-toolbox: activation failed", error);
        throw error;
      }
    }

    exports.apply = apply;
    exports.inject = inject;

    return module.exports;
  },
});
