/*
 * forge Cockpit overview — vanilla JS, no bundler. Runs inside Cockpit's
 * module iframe with the `cockpit` global provided by ../base1/cockpit.js.
 *
 * Design notes:
 *   - Every data source is a shell command executed via cockpit.spawn().
 *     Parsing happens client-side. Keeps the module a single RPM file tree
 *     with no backend daemon to install or port-manage.
 *   - Polling interval is deliberately slow (10s) — this is a dashboard,
 *     not a terminal. Operators who want live data open the relevant page.
 *   - All commands run with superuser: "try" so the module works for non-
 *     root Cockpit users who have pkexec rules; falls back gracefully when
 *     they don't.
 *   - No exceptions escape to the console. Each card owns its own failure
 *     state and renders "unavailable" rather than going blank.
 */

(function () {
    "use strict";

    const POLL_MS = 10_000;

    // ---------- tiny helpers ---------------------------------------------------
    const $  = (sel) => document.querySelector(sel);
    const $$ = (sel) => document.querySelectorAll(sel);

    /**
     * Run a shell command and return stdout as a string. Resolves to "" on
     * any error (the caller treats "" as "unavailable" uniformly). We choose
     * resolve-on-error over reject-on-error because any single failed probe
     * shouldn't abort the entire poll cycle.
     */
    function sh(argv) {
        return cockpit.spawn(argv, { superuser: "try", err: "message" })
            .then((out) => String(out || ""))
            .catch(() => "");
    }

    function setStatus(cardKind, status) {
        const dot = document.querySelector(`.card[data-kind="${cardKind}"] .status-dot`);
        if (dot) dot.dataset.status = status;
    }

    function setText(sel, value) {
        const el = typeof sel === "string" ? $(sel) : sel;
        if (el) el.textContent = value;
    }

    /** Bytes → human. Matches `zfs list`'s convention (1024-based) because
        that's where most of our numbers come from. */
    function humanBytes(bytes) {
        const b = Number(bytes);
        if (!Number.isFinite(b) || b <= 0) return "0 B";
        const units = ["B", "K", "M", "G", "T", "P"];
        let i = 0, n = b;
        while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
        return `${n.toFixed(n >= 100 ? 0 : 1)} ${units[i]}`;
    }

    function timeAgo(epoch) {
        if (!epoch) return "never";
        const diff = Math.floor(Date.now() / 1000) - Number(epoch);
        if (diff < 0) return "in future";
        if (diff < 60) return `${diff}s ago`;
        if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
        if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
        return `${Math.floor(diff / 86400)}d ago`;
    }

    // ---------- host header ----------------------------------------------------
    async function refreshHeader() {
        const [host, uptime, kernel] = await Promise.all([
            sh(["hostname", "-f"]),
            sh(["cat", "/proc/uptime"]),
            sh(["uname", "-r"]),
        ]);
        setText("#host-ident", host.trim() || "unknown host");
        const secs = parseFloat(uptime.split(" ")[0] || "0");
        if (secs > 0) {
            const d = Math.floor(secs / 86400);
            const h = Math.floor((secs % 86400) / 3600);
            const m = Math.floor((secs % 3600) / 60);
            setText("#uptime", `up ${d}d ${h}h ${m}m`);
        }
        setText("#kernel", kernel.trim() || "—");
    }

    // ---------- cluster --------------------------------------------------------
    async function refreshCluster() {
        const status = await sh(["pcs", "status", "--full"]);
        if (!status) {
            setText("#cluster-name", "not configured");
            setText("#cluster-nodes", "—");
            setText("#cluster-quorum", "—");
            setText("#cluster-fencing", "—");
            setText("#cluster-resources", "—");
            setStatus("cluster", "idle");
            return;
        }

        // pcs status is semi-structured text. A stable-ish regex surface is
        // enough; XML output (`--xml` on corosync quorumtool) is richer but
        // pcs has churned that output format several times.
        const name = (status.match(/Cluster name:\s*(\S+)/) || [])[1] || "—";
        const online = (status.match(/Online:\s*\[\s*([^\]]*)\]/) || [])[1] || "";
        const offline = (status.match(/OFFLINE:\s*\[\s*([^\]]*)\]/) || [])[1] || "";
        const quorum = /partition WITH quorum/i.test(status) ? "OK"
                     : /partition WITHOUT quorum/i.test(status) ? "LOST" : "—";

        const onlineCount = online.trim() ? online.trim().split(/\s+/).length : 0;
        const offlineCount = offline.trim() ? offline.trim().split(/\s+/).length : 0;
        const total = onlineCount + offlineCount;

        setText("#cluster-name", name);
        setText("#cluster-nodes", `${onlineCount} / ${total} online`);
        setText("#cluster-quorum", quorum);

        const stonith = await sh(["pcs", "property", "show", "stonith-enabled"]);
        const fencingOn = !/stonith-enabled:\s*false/i.test(stonith);
        setText("#cluster-fencing", fencingOn ? "enabled" : "DISABLED");

        const resources = (status.match(/^\s*\*\s+(\S+)\s+\(ocf::/gm) || []).length
                        + (status.match(/^\s*\*\s+(\S+)\s+\(stonith:/gm) || []).length;
        setText("#cluster-resources", String(resources));

        let s = "ok";
        if (offlineCount > 0 || quorum === "LOST") s = "warn";
        if (!fencingOn) s = s === "ok" ? "warn" : s;
        setStatus("cluster", s);
    }

    // ---------- storage (ZFS) --------------------------------------------------
    async function refreshStorage() {
        // -Hp = parseable, no headers, exact bytes.
        const raw = await sh(["zpool", "list", "-Hp", "-o", "name,size,alloc,free,health,frag,capacity"]);
        const container = $("#pool-list");
        container.innerHTML = "";

        if (!raw) {
            container.innerHTML = '<div class="empty">ZFS not available (install <code>zfs</code>).</div>';
            setStatus("storage", "idle");
        } else {
            let worstStatus = "ok";
            const lines = raw.trim().split("\n").filter(Boolean);
            if (lines.length === 0) {
                container.innerHTML = '<div class="empty">No zpools created yet.</div>';
                setStatus("storage", "idle");
            } else {
                for (const line of lines) {
                    const [name, size, alloc, _free, health, frag, cap] = line.split("\t");
                    const pct = Math.min(100, Number(cap) || 0);
                    const healthClass = health === "ONLINE" ? "ok"
                                      : health === "DEGRADED" ? "warn"
                                      : "err";
                    if (healthClass === "warn" && worstStatus === "ok") worstStatus = "warn";
                    if (healthClass === "err") worstStatus = "err";

                    const row = document.createElement("div");
                    row.className = "pool-row";
                    row.innerHTML = `
                        <div class="pool-head">
                            <span class="pool-name">${name}</span>
                            <span class="pool-health health-${healthClass}">${health}</span>
                        </div>
                        <div class="pool-meta">
                            <span>${humanBytes(alloc)} / ${humanBytes(size)}</span>
                            <span class="muted">frag ${frag || "0%"}</span>
                        </div>
                        <div class="progress"><div class="progress-fill" style="width:${pct}%"></div></div>
                    `;
                    container.appendChild(row);
                }
                setStatus("storage", worstStatus);
            }
        }

        // ARC utilization from /proc/spl/kstat/zfs/arcstats. "c_max" is the
        // configured cap; "size" is current consumption. Reading via cat so
        // we don't need superuser.
        const arc = await sh(["cat", "/proc/spl/kstat/zfs/arcstats"]);
        const m = (name) => {
            const hit = arc.match(new RegExp(`^${name}\\s+\\d+\\s+(\\d+)`, "m"));
            return hit ? Number(hit[1]) : 0;
        };
        const size = m("size"), cmax = m("c_max");
        if (cmax > 0) {
            setText("#arc-usage", `${humanBytes(size)} / ${humanBytes(cmax)}`);
            $("#arc-bar").style.width = `${Math.min(100, (size / cmax) * 100)}%`;
        } else {
            setText("#arc-usage", "—");
            $("#arc-bar").style.width = "0%";
        }
    }

    // ---------- backups (systemd timers) --------------------------------------
    async function refreshBackups() {
        const raw = await sh([
            "systemctl", "list-timers", "--all", "--no-pager",
            "--output=json",
            "sanoid.timer", "syncoid-*.timer", "forge-restic.timer",
        ]);
        const tbody = $("#timer-table tbody");
        tbody.innerHTML = "";

        let rows = [];
        try { rows = JSON.parse(raw || "[]"); } catch (_) { rows = []; }

        if (rows.length === 0) {
            tbody.innerHTML = '<tr><td colspan="3" class="empty">No backup timers active.</td></tr>';
            setStatus("backup", "idle");
            return;
        }

        // Derive status from the next fire time — stale (>25h since last fire
        // for hourly jobs, etc.) goes yellow; inactive goes red.
        let worst = "ok";
        for (const r of rows) {
            const tr = document.createElement("tr");
            const job = (r.unit || "").replace(/\.timer$/, "");
            const last = r.last ? timeAgo(Math.floor(Date.parse(r.last) / 1000)) : "never";
            const next = r.next && r.next !== "n/a" ? r.next.replace(/\s+[+-]\d{4}$/, "") : "—";
            tr.innerHTML = `<td>${job}</td><td>${last}</td><td class="muted">${next}</td>`;
            if (last === "never") worst = worst === "err" ? "err" : "warn";
            tbody.appendChild(tr);
        }
        setStatus("backup", worst);
    }

    // ---------- virtual machines ----------------------------------------------
    async function refreshVMs() {
        const all = (await sh(["virsh", "list", "--all", "--name"])).trim().split("\n").filter(Boolean);
        const running = (await sh(["virsh", "list", "--state-running", "--name"])).trim().split("\n").filter(Boolean);

        setText("#vm-count", `${running.length} / ${all.length}`);
        const ul = $("#vm-list");
        ul.innerHTML = "";
        if (all.length === 0) {
            ul.innerHTML = '<li class="empty">No VMs defined yet — <a href="/machines">create one →</a></li>';
            setStatus("vms", "idle");
            return;
        }
        for (const name of all.slice(0, 8)) {
            const isRunning = running.includes(name);
            const li = document.createElement("li");
            li.innerHTML = `<span class="vm-dot ${isRunning ? "on" : "off"}"></span>
                            <span class="vm-name">${name}</span>
                            <span class="vm-state muted">${isRunning ? "running" : "stopped"}</span>`;
            ul.appendChild(li);
        }
        if (all.length > 8) {
            const li = document.createElement("li");
            li.className = "more";
            li.innerHTML = `<a href="/machines">+${all.length - 8} more →</a>`;
            ul.appendChild(li);
        }
        setStatus("vms", running.length > 0 ? "ok" : "idle");
    }

    // ---------- main loop ------------------------------------------------------
    async function refreshAll() {
        // Run independent probes concurrently — keeps total poll latency at
        // the slowest single command instead of their sum.
        await Promise.allSettled([
            refreshHeader(),
            refreshCluster(),
            refreshStorage(),
            refreshBackups(),
            refreshVMs(),
        ]);
        setText("#refresh", `refreshed ${new Date().toLocaleTimeString()}`);
    }

    // Cockpit fires "visibilitychange" when the page is backgrounded; we
    // honor it to avoid hammering libvirt / zfs when nobody's looking.
    let timer = null;
    function startPolling() {
        refreshAll();
        if (timer) clearInterval(timer);
        timer = setInterval(refreshAll, POLL_MS);
    }
    function stopPolling() {
        if (timer) { clearInterval(timer); timer = null; }
    }

    document.addEventListener("visibilitychange", () => {
        document.hidden ? stopPolling() : startPolling();
    });

    // cockpit.transport.wait resolves once the bridge is up — gate the first
    // spawn on it so we don't race the iframe's initial handshake.
    cockpit.transport.wait(() => { startPolling(); });
})();
