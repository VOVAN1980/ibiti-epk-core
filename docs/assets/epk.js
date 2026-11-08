/* EPK site — shared behaviour: universe background, FX switch, reveal, tilt, typing terminal,
   mobile menu, and live numbers read straight from BSC Testnet. No libraries. */
(function () {
  "use strict";

  // ---------- where the public evidence lives (one fixed Git commit) ----------
  var EPK = window.EPK = window.EPK || {};
  EPK.REPO = "VOVAN1980/ibiti-epk-core";
  EPK.COMMIT = "bd3cf198a361d3bc7780806e9cdd54f2be1a0f59";
  EPK.COMMIT_GUARDS = "dfe6d0e0dbf4e803016f76d897e3e776576a33c8"; // evidence of the guard demo (docs/proof/guards.html)
  // free public BSC Testnet nodes, asked in this order (the next one only when a node has no answer; see docs/TESTNET_V2.md)
  EPK.NODES = ["https://bsc-testnet.bnbchain.org", "https://97.rpc.thirdweb.com", "https://bsc-testnet-rpc.publicnode.com"];
  EPK.EXPLORER = "https://testnet.bscscan.com";
  EPK.raw = function (path) { return "https://raw.githubusercontent.com/" + EPK.REPO + "/" + EPK.COMMIT + "/" + path; };

  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var store = {
    get: function (k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  };

  // ---------- universe background ----------
  var canvas = document.getElementById("universe");
  var fxOn = store.get("epk-fx") !== "off" && !reduced;
  var raf = null;
  if (canvas && canvas.getContext) {
    var ctx = canvas.getContext("2d"), W = 0, H = 0, nodes = [], mouse = { x: null, y: null, r: 200 };
    var Node = function () {
      this.x = Math.random() * W; this.y = Math.random() * H;
      this.vx = (Math.random() - 0.5) * 0.5; this.vy = (Math.random() - 0.5) * 0.5;
      this.s = Math.random() * 2 + 0.5; this.a = 0.3 + Math.random() * 0.2;
    };
    Node.prototype.step = function () {
      this.x += this.vx; this.y += this.vy;
      if (this.x < 0 || this.x > W) this.vx *= -1;
      if (this.y < 0 || this.y > H) this.vy *= -1;
      if (mouse.x !== null) {
        var dx = mouse.x - this.x, dy = mouse.y - this.y, d = Math.sqrt(dx * dx + dy * dy);
        if (d < mouse.r && d > 0) { var f = (mouse.r - d) / mouse.r * 3; this.x += dx / d * f; this.y += dy / d * f; }
      }
    };
    var resize = function () {
      W = canvas.width = window.innerWidth; H = canvas.height = window.innerHeight;
      nodes = []; var n = W < 768 ? 50 : 130;
      for (var i = 0; i < n; i++) nodes.push(new Node());
      if (!fxOn) ctx.clearRect(0, 0, W, H);
    };
    var frame = function () {
      ctx.clearRect(0, 0, W, H);
      for (var i = 0; i < nodes.length; i++) {
        var a = nodes[i]; a.step();
        ctx.fillStyle = "rgba(255,255,255," + a.a + ")";
        ctx.beginPath(); ctx.arc(a.x, a.y, a.s, 0, Math.PI * 2); ctx.fill();
        for (var j = i + 1; j < nodes.length; j++) {
          var b = nodes[j], dx = a.x - b.x, dy = a.y - b.y, d = Math.sqrt(dx * dx + dy * dy);
          if (d < 120) {
            ctx.strokeStyle = "rgba(100,150,255," + (0.15 * (1 - d / 120)) + ")"; ctx.lineWidth = 0.5;
            ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
          }
        }
        if (mouse.x !== null) {
          var mx = a.x - mouse.x, my = a.y - mouse.y, md = Math.sqrt(mx * mx + my * my);
          if (md < 150) {
            ctx.strokeStyle = "rgba(139,92,246," + (0.2 * (1 - md / 150)) + ")"; ctx.lineWidth = 0.8;
            ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(mouse.x, mouse.y); ctx.stroke();
          }
        }
      }
      raf = requestAnimationFrame(frame);
    };
    var start = function () { if (!raf && fxOn && !document.hidden) raf = requestAnimationFrame(frame); };
    var stop = function () { if (raf) cancelAnimationFrame(raf); raf = null; };
    window.addEventListener("resize", resize);
    window.addEventListener("mousemove", function (e) { mouse.x = e.clientX; mouse.y = e.clientY; });
    document.addEventListener("visibilitychange", function () { if (document.hidden) stop(); else start(); });
    resize(); start();

    EPK.setFx = function (on) {
      fxOn = on; store.set("epk-fx", on ? "on" : "off");
      if (on) start(); else { stop(); ctx.clearRect(0, 0, W, H); }
      document.querySelectorAll("[data-fx]").forEach(function (b) {
        b.classList.toggle("off", !on);
        b.innerHTML = '<span class="dot"></span>FX: ' + (on ? "ON" : "OFF");
        b.setAttribute("aria-pressed", on ? "true" : "false");
      });
    };
    document.querySelectorAll("[data-fx]").forEach(function (b) { b.addEventListener("click", function () { EPK.setFx(!fxOn); }); });
    EPK.setFx(fxOn);
  }

  // ---------- mobile menu ----------
  document.querySelectorAll("[data-menu]").forEach(function (b) {
    b.addEventListener("click", function () {
      var nav = b.closest(".nav"); var open = nav.classList.toggle("open"); b.setAttribute("aria-expanded", open ? "true" : "false");
    });
  });
  document.querySelectorAll(".nav-links a").forEach(function (a) {
    a.addEventListener("click", function () { var nav = a.closest(".nav"); if (nav) nav.classList.remove("open"); });
  });

  // ---------- reveal on scroll + typing terminal ----------
  var typeTerminal = function (el) {
    if (el.dataset.typed) return; el.dataset.typed = "1";
    var lines = el.querySelectorAll(".ln");
    lines.forEach(function (ln, i) { setTimeout(function () { ln.classList.add("on"); }, reduced ? 0 : 140 * i + 200); });
  };
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (!e.isIntersecting) return;
        e.target.classList.add("active");
        if (e.target.matches("[data-type]")) typeTerminal(e.target);
        io.unobserve(e.target);
      });
    }, { threshold: 0.12 });
    document.querySelectorAll(".reveal, [data-type]").forEach(function (el) { io.observe(el); });
  } else {
    document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("active"); });
    document.querySelectorAll("[data-type]").forEach(typeTerminal);
  }

  // ---------- 3D tilt (desktop only) ----------
  if (!reduced && window.matchMedia("(min-width: 900px) and (hover: hover)").matches) {
    document.querySelectorAll("[data-tilt]").forEach(function (c) {
      c.addEventListener("mousemove", function (e) {
        var r = c.getBoundingClientRect();
        c.style.transform = "perspective(1000px) rotateX(" + (-(e.clientY - r.top - r.height / 2) / 40) + "deg) rotateY(" + ((e.clientX - r.left - r.width / 2) / 40) + "deg)";
      });
      c.addEventListener("mouseleave", function () { c.style.transform = ""; });
    });
  }

  // ---------- count-up ----------
  EPK.countTo = function (el, to, fmt) {
    fmt = fmt || function (v) { return String(v); };
    if (reduced || to === 0) { el.textContent = fmt(to); return; }
    var t0 = performance.now(), ms = 1200;
    var tick = function (now) {
      var p = Math.min((now - t0) / ms, 1), e = 1 - Math.pow(1 - p, 3);
      el.textContent = fmt(Math.round(to * e)); if (p < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };

  // ---------- live numbers from BSC Testnet (home page) ----------
  var rpc = function (method, params, i) {
    i = i || 0;
    if (i >= EPK.NODES.length) return Promise.reject(new Error("no node answered " + method));
    var next = function () { return rpc(method, params, i + 1); };
    return fetch(EPK.NODES[i], { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: method, params: params }) })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j.error) return next(); // pruned history, a refused request, a rate limit: ask the next node
        if (j.result === null && method === "eth_getTransactionReceipt") return next(); // node dropped old txs
        return j.result;
      }, next);
  };
  var pad = function (a) { return "0x" + a.toLowerCase().replace(/^0x/, "").padStart(64, "0"); };
  var TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  var setSrc = function (id, live) {
    var s = document.querySelector('[data-src="' + id + '"]'); if (!s) return;
    s.classList.toggle("live", live);
    s.innerHTML = '<span class="dot"></span>' + (live ? "live from BSC Testnet" : "from the published evidence");
  };
  EPK.liveStats = function () {
    var box = document.querySelector("[data-live-stats]"); if (!box) return;
    fetch(EPK.raw("deployments/bsc-testnet/epk-v2-evidence.json"), { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (ev) {
        var vault = ev.contracts.vault.address, token = ev.contracts.token.address;
        var attacks = ev.transactions.filter(function (t) { return t.expect === "reverted"; });
        var w1 = ev.transactions.filter(function (t) { return t.step === "W1"; })[0];
        var w2 = ev.transactions.filter(function (t) { return t.step === "W2"; })[0];
        var el = function (k) { return box.querySelector('[data-stat="' + k + '"]'); };
        var fmtInt = function (v) { return Number(v).toLocaleString("en-US"); };

        // 1) attacks rejected on-chain (receipt status 0)
        Promise.all(attacks.map(function (t) { return rpc("eth_getTransactionReceipt", [t.tx]); }))
          .then(function (rs) {
            var n = rs.filter(function (r) { return r && parseInt(r.status, 16) === 0; }).length;
            el("attacks").dataset.total = attacks.length;
            EPK.countTo(el("attacks"), n, function (v) { return v + "/" + attacks.length; }); setSrc("attacks", true);
          }).catch(function () { el("attacks").textContent = attacks.length + "/" + attacks.length; setSrc("attacks", false); });

        // 2) eUSD that left the vault while the attacks ran (Transfer logs are kept for good)
        Promise.all((ev.attackWindows || []).map(function (aw) {
          return rpc("eth_getLogs", [{ address: token, fromBlock: "0x" + (aw.fromBlock + 1).toString(16), toBlock: "0x" + aw.toBlock.toString(16), topics: [TRANSFER, pad(vault)] }]);
        })).then(function (ls) {
          var moved = 0n; ls.forEach(function (l) { l.forEach(function (x) { moved += BigInt(x.data); }); });
          el("moved").textContent = (moved / 10n ** 18n).toString(); setSrc("moved", true);
        }).catch(function () { el("moved").textContent = "0"; setSrc("moved", false); });

        // 3) blocks between the thief's change and the Watchtower's cancel
        if (w1 && w2) Promise.all([rpc("eth_getTransactionReceipt", [w1.tx]), rpc("eth_getTransactionReceipt", [w2.tx])])
          .then(function (rs) { EPK.countTo(el("blocks"), parseInt(rs[1].blockNumber, 16) - parseInt(rs[0].blockNumber, 16)); setSrc("blocks", true); })
          .catch(function () { el("blocks").textContent = "4"; setSrc("blocks", false); });

        // 4) what is in the vault right now
        rpc("eth_call", [{ to: token, data: "0x70a08231" + pad(vault).slice(2) }, "latest"])
          .then(function (b) { EPK.countTo(el("balance"), Number(BigInt(b) / 10n ** 18n), fmtInt); setSrc("balance", true); })
          .catch(function () { el("balance").textContent = "9,940"; setSrc("balance", false); });
      })
      .catch(function () { /* evidence unreachable: the static numbers in the HTML stay */ });
  };
  EPK.liveStats();
})();
