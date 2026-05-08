{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
}:
let
  repoBaseUrl = "https://github.com/FilipNowakowicz/NixOS";
  docsBaseUrl = "${repoBaseUrl}/blob/main";
  invariants = import ../lib/invariants.nix { inherit lib pkgs; };

  hostHealth =
    name: cfg:
    let
      commonAssertions = [
        {
          name = "has stateVersion";
          check = c: c.system.stateVersion != null;
        }
        {
          name = "SSH hosts enforce hardened fail2ban";
          check =
            c:
            let
              violations = lib.filter (msg: msg != "") [
                (lib.optionalString (!c.services.fail2ban.enable) "services.fail2ban.enable must be true")
                (lib.optionalString (c.services.fail2ban.maxretry > 3) "services.fail2ban.maxretry must be <= 3")
                (lib.optionalString (
                  c.services.fail2ban.bantime != "30m"
                ) "services.fail2ban.bantime must be \"30m\"")
                (lib.optionalString (
                  !c.services.fail2ban."bantime-increment".enable
                ) "services.fail2ban.bantime-increment.enable must be true")
                (lib.optionalString (
                  c.services.fail2ban."bantime-increment".maxtime == null
                ) "services.fail2ban.bantime-increment.maxtime must be set")
              ];
            in
            if !c.services.openssh.enable then true else violations == [ ];
        }
        {
          name = "observability client uses canonical ingest username";
          check =
            c:
            let
              clientProfile = c.profiles.observability-client or { };
              obsProfile = c.profiles.observability or { };
              ingestAuth = obsProfile.ingestAuth or { };
              clientEnabled = clientProfile.enable or false;
              username = ingestAuth.username or "telemetry";
            in
            !clientEnabled || username == "telemetry";
        }
      ];

      hostSpecificAssertions =
        if name == "main" then
          [
            {
              name = "main SSH stays tailnet-only";
              check =
                c:
                c.services.openssh.enable
                && !c.services.openssh.openFirewall
                && c.services.tailscale.enable
                && c.services.tailscale.openFirewall;
            }
            {
              name = "main USBGuard stays deny-default";
              check =
                c:
                let
                  rules = c.services.usbguard.rules or "";
                in
                c.services.usbguard.enable && lib.hasInfix "allow id " rules && lib.hasInfix "reject" rules;
            }
            {
              name = "main local backup covers critical paths";
              check =
                c:
                let
                  backup = c.services.restic.backups.local or null;
                in
                backup != null
                &&
                  (backup.paths or [ ]) == [
                    "/home/user/.ssh"
                    "/home/user/.gnupg"
                    "/home/user/nix"
                  ]
                && (backup.passwordFile or "") != ""
                && lib.hasPrefix "/run/secrets/" (backup.passwordFile or "")
                && backup.initialize
                && (backup.timerConfig.OnCalendar or null) == "daily";
            }
          ]
        else if name == "vm" then
          [
            {
              name = "passwordless sudo enabled";
              check = c: !c.security.sudo.wheelNeedsPassword;
            }
          ]
        else if name == "homeserver-gcp" then
          [
            {
              name = "no passwordless sudo";
              check = c: c.security.sudo.wheelNeedsPassword;
            }
            {
              name = "firewall enabled";
              check = c: c.networking.firewall.enable;
            }
            {
              name = "SSH and HTTPS are not globally open";
              check =
                c:
                !(lib.any (port: builtins.elem port (c.networking.firewall.allowedTCPPorts or [ ])) [
                  22
                  443
                ]);
            }
            {
              name = "SSH and HTTPS stay Tailscale-only";
              check =
                c:
                let
                  interfaces = c.networking.firewall.interfaces or { };
                  tailscaleNetwork = interfaces.tailscale0.allowedTCPPorts or [ ];
                in
                builtins.all (port: builtins.elem port tailscaleNetwork) [
                  22
                  443
                ];
            }
          ]
        else
          [ ];

      results = invariants.evaluateAssertions (
        commonAssertions
        ++ hostSpecificAssertions
        ++ invariants.mkRegistryAssertions name hostRegistry.${name}
      ) cfg.config;
      failed = lib.filter (result: !result.passed) results;
    in
    {
      invariantResults = results;
      invariantPassed = builtins.length results - builtins.length failed;
      invariantFailed = builtins.length failed;
      invariantStatus = if failed == [ ] then "pass" else "warn";
    };

  extractHost =
    name: cfg:
    let
      meta = hostRegistry.${name};
      c = cfg.config;
      health = hostHealth name cfg;
      resticBackups = c.services.restic.backups or { };
      tailscaleFirewall = (c.networking.firewall.interfaces or { }).tailscale0 or { };
    in
    {
      inherit name;
      inherit (meta) system;
      inherit (meta) status;
      closurePath = builtins.unsafeDiscardStringContext (toString c.system.build.toplevel);
      inherit (c.system) stateVersion;
      tailscaleTag = meta.tailscale.tag or null;
      tailnetFQDN = meta.tailnetFQDN or null;
      ip = meta.ip or null;
      deployable = meta ? deploy;
      backupClass = meta.backup.class or null;
      homeManagerRole = meta.homeManager.role or null;
      homeManagerProfiles = meta.homeManager.profiles or [ ];
      impermanence = (c.environment.persistence or { }) != { };
      openTCPPorts = c.networking.firewall.allowedTCPPorts or [ ];
      openUDPPorts = c.networking.firewall.allowedUDPPorts or [ ];
      tailscaleTCPPorts = tailscaleFirewall.allowedTCPPorts or [ ];
      tailscaleUDPPorts = tailscaleFirewall.allowedUDPPorts or [ ];
      resticBackups = lib.mapAttrsToList (backupName: backup: {
        name = backupName;
        repository = backup.repository or null;
        paths = backup.paths or [ ];
        timer = backup.timerConfig.OnCalendar or null;
        initialize = backup.initialize or false;
      }) resticBackups;
      profiles = {
        desktop = c.programs.hyprland.enable or false;
        security = c.services.fail2ban.enable or false;
        observability = c.profiles.observability.enable or false;
        observabilityClient = c.profiles.observability-client.enable or false;
      };
      services = {
        openssh = c.services.openssh.enable;
        tailscale = c.services.tailscale.enable;
        firewall = c.networking.firewall.enable;
        fail2ban = c.services.fail2ban.enable;
        vaultwarden = c.services.vaultwarden.enable or false;
        syncthing = c.services.syncthing.enable or false;
        nginx = c.services.nginx.enable or false;
        adguard = c.services.adguardhome.enable or false;
        grafana = c.services.grafana.enable or false;
        loki = c.services.loki.enable or false;
        mimir = c.services.mimir.enable or false;
        tempo = c.services.tempo.enable or false;
        restic = resticBackups != { };
        hyprland = c.programs.hyprland.enable or false;
        observabilityStack = c.profiles.observability.enable or false;
        observabilityClient = c.profiles.observability-client.enable or false;
        usbguard = c.services.usbguard.enable or false;
        lanzaboote = c.boot.lanzaboote.enable or false;
      };
      inherit health;
    };

  goalsData = map (
    goal:
    goal
    // {
      docs = map (path: {
        inherit path;
        url = "${docsBaseUrl}/${path}";
      }) (goal.docs or [ ]);
    }
  ) (import ../lib/goals.nix);

  hostsData = lib.mapAttrsToList extractHost allNixosConfigs;

  hostSpec = builtins.concatStringsSep "\n" (
    map (host: "${host.name}\t${host.closurePath}") hostsData
  );

  dataJson = builtins.toJSON {
    hosts = hostsData;
    goals = goalsData;
    repository = repoBaseUrl;
  };

  html = ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Homeserver Dashboard</title>
      <style>
        :root {
          --bg: #10120f;
          --ink: #f3efe3;
          --muted: #a9a08c;
          --faint: #746d60;
          --panel: rgba(31, 34, 28, 0.78);
          --panel-strong: rgba(42, 45, 37, 0.92);
          --line: rgba(217, 197, 150, 0.18);
          --line-strong: rgba(217, 197, 150, 0.34);
          --green: #9bcf77;
          --gold: #e0b15b;
          --orange: #d77f4f;
          --red: #dd6a5f;
          --cyan: #74b7b0;
          --blue: #8fb3d9;
          --shadow: 0 24px 70px rgba(0, 0, 0, 0.36);
        }

        * { box-sizing: border-box; }

        body {
          margin: 0;
          min-height: 100vh;
          color: var(--ink);
          background:
            radial-gradient(circle at 18% 0%, rgba(224, 177, 91, 0.18), transparent 31rem),
            radial-gradient(circle at 88% 8%, rgba(116, 183, 176, 0.14), transparent 28rem),
            linear-gradient(135deg, #161811 0%, #10120f 45%, #1c1813 100%);
          font-family: "Aptos", "Segoe UI", sans-serif;
          line-height: 1.5;
        }

        body::before {
          content: "";
          position: fixed;
          inset: 0;
          pointer-events: none;
          opacity: 0.22;
          background-image:
            linear-gradient(rgba(255, 255, 255, 0.035) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255, 255, 255, 0.03) 1px, transparent 1px);
          background-size: 52px 52px;
          mask-image: linear-gradient(to bottom, black, transparent 78%);
        }

        a { color: inherit; }

        .shell {
          width: min(1420px, calc(100vw - 40px));
          margin: 0 auto;
          padding: 32px 0 44px;
          position: relative;
        }

        .hero {
          display: grid;
          grid-template-columns: minmax(0, 1.25fr) minmax(330px, 0.75fr);
          gap: 18px;
          align-items: stretch;
          margin-bottom: 18px;
        }

        .hero-main,
        .panel,
        .service-card,
        .machine-card,
        .goal-card,
        .health-card {
          border: 1px solid var(--line);
          background: linear-gradient(180deg, var(--panel-strong), var(--panel));
          box-shadow: var(--shadow);
          backdrop-filter: blur(14px);
        }

        .hero-main {
          min-height: 320px;
          border-radius: 30px;
          padding: 32px;
          position: relative;
          overflow: hidden;
        }

        .hero-main::after {
          content: "";
          position: absolute;
          width: 280px;
          height: 280px;
          right: -80px;
          top: -100px;
          border-radius: 999px;
          border: 1px solid rgba(224, 177, 91, 0.32);
          background: radial-gradient(circle, rgba(224, 177, 91, 0.16), transparent 62%);
        }

        .eyebrow {
          color: var(--gold);
          font-family: "IBM Plex Mono", "Cascadia Code", monospace;
          font-size: 0.74rem;
          letter-spacing: 0.15em;
          text-transform: uppercase;
          margin-bottom: 16px;
        }

        h1 {
          margin: 0;
          max-width: 820px;
          font-size: clamp(2.7rem, 7vw, 6.3rem);
          line-height: 0.86;
          letter-spacing: -0.08em;
        }

        .lede {
          max-width: 760px;
          margin: 22px 0 0;
          color: var(--muted);
          font-size: 1.02rem;
        }

        .hero-actions {
          display: flex;
          flex-wrap: wrap;
          gap: 10px;
          margin-top: 26px;
        }

        .action {
          display: inline-flex;
          align-items: center;
          gap: 8px;
          min-height: 38px;
          padding: 8px 13px;
          border-radius: 999px;
          border: 1px solid var(--line-strong);
          background: rgba(16, 18, 15, 0.42);
          color: var(--ink);
          text-decoration: none;
          font-size: 0.86rem;
        }

        .action.primary {
          background: var(--gold);
          border-color: rgba(224, 177, 91, 0.8);
          color: #21180d;
          font-weight: 700;
        }

        .hero-side {
          display: grid;
          gap: 12px;
        }

        .status-tile {
          border-radius: 24px;
          padding: 18px;
          border: 1px solid var(--line);
          background: rgba(16, 18, 15, 0.58);
        }

        .tile-label {
          color: var(--muted);
          font-size: 0.74rem;
          letter-spacing: 0.1em;
          text-transform: uppercase;
        }

        .tile-value {
          display: block;
          margin-top: 7px;
          font-size: 2rem;
          font-weight: 800;
          letter-spacing: -0.05em;
        }

        .tile-note {
          color: var(--muted);
          font-size: 0.84rem;
          margin-top: 4px;
        }

        .grid-2 {
          display: grid;
          grid-template-columns: minmax(0, 0.8fr) minmax(0, 1.2fr);
          gap: 18px;
          margin-bottom: 18px;
        }

        .section {
          margin-top: 18px;
        }

        .section-header {
          display: flex;
          align-items: end;
          justify-content: space-between;
          gap: 16px;
          margin: 0 2px 12px;
        }

        .section-title {
          margin: 0;
          font-size: 1rem;
          letter-spacing: 0.06em;
          text-transform: uppercase;
        }

        .section-copy {
          margin: 3px 0 0;
          color: var(--muted);
          font-size: 0.88rem;
        }

        .panel {
          border-radius: 24px;
          padding: 20px;
        }

        .signal-list {
          display: grid;
          gap: 10px;
        }

        .signal {
          border: 1px solid rgba(217, 197, 150, 0.15);
          background: rgba(16, 18, 15, 0.45);
          border-radius: 18px;
          padding: 13px;
        }

        .signal.warn { border-left: 4px solid var(--gold); }
        .signal.bad { border-left: 4px solid var(--red); }
        .signal.good { border-left: 4px solid var(--green); }

        .signal-title {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          font-weight: 750;
        }

        .signal-detail {
          margin-top: 5px;
          color: var(--muted);
          font-size: 0.86rem;
        }

        .services-grid {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 14px;
        }

        .service-card {
          min-height: 210px;
          border-radius: 24px;
          padding: 20px;
          position: relative;
          overflow: hidden;
        }

        .service-card::before {
          content: "";
          position: absolute;
          inset: 0;
          background: linear-gradient(135deg, var(--accent), transparent 38%);
          opacity: 0.13;
          pointer-events: none;
        }

        .service-top {
          display: flex;
          justify-content: space-between;
          gap: 12px;
          align-items: flex-start;
          position: relative;
        }

        .service-name {
          font-size: 1.18rem;
          font-weight: 850;
          letter-spacing: -0.03em;
        }

        .pill {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          width: fit-content;
          padding: 3px 9px;
          border-radius: 999px;
          border: 1px solid currentColor;
          font-family: "IBM Plex Mono", "Cascadia Code", monospace;
          font-size: 0.7rem;
          line-height: 1.3;
          text-transform: uppercase;
          letter-spacing: 0.06em;
        }

        .pill.good { color: var(--green); }
        .pill.warn { color: var(--gold); }
        .pill.off { color: var(--faint); }
        .pill.info { color: var(--cyan); }
        .pill.bad { color: var(--red); }

        .service-desc {
          color: var(--muted);
          margin: 14px 0 0;
          font-size: 0.9rem;
          position: relative;
        }

        .meta-line {
          display: flex;
          flex-wrap: wrap;
          gap: 7px;
          margin-top: 14px;
          position: relative;
        }

        .chip {
          display: inline-flex;
          border-radius: 999px;
          border: 1px solid rgba(217, 197, 150, 0.18);
          background: rgba(16, 18, 15, 0.42);
          color: var(--muted);
          padding: 3px 8px;
          font-size: 0.76rem;
        }

        .card-links {
          display: flex;
          flex-wrap: wrap;
          gap: 9px;
          margin-top: 17px;
          position: relative;
        }

        .card-link {
          color: var(--ink);
          text-decoration: none;
          font-size: 0.84rem;
          border-bottom: 1px solid rgba(243, 239, 227, 0.35);
        }

        .machines-grid {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 14px;
        }

        .machine-card,
        .goal-card,
        .health-card {
          border-radius: 22px;
          padding: 18px;
        }

        .machine-head,
        .goal-head,
        .health-head {
          display: flex;
          justify-content: space-between;
          gap: 12px;
          align-items: flex-start;
          margin-bottom: 12px;
        }

        .machine-name,
        .goal-title,
        .health-name {
          font-weight: 850;
          letter-spacing: -0.02em;
        }

        .rows {
          display: grid;
          gap: 8px;
        }

        .row {
          display: flex;
          justify-content: space-between;
          gap: 14px;
          border-top: 1px solid rgba(217, 197, 150, 0.12);
          padding-top: 8px;
          color: var(--muted);
          font-size: 0.84rem;
        }

        .row strong {
          color: var(--ink);
          font-weight: 650;
          text-align: right;
          overflow-wrap: anywhere;
        }

        .goals-layout {
          display: grid;
          grid-template-columns: minmax(0, 1fr) minmax(280px, 0.35fr);
          gap: 14px;
        }

        .goal-list {
          display: grid;
          gap: 10px;
        }

        .goal-card {
          box-shadow: none;
          background: rgba(16, 18, 15, 0.42);
        }

        .goal-summary {
          color: var(--muted);
          font-size: 0.9rem;
        }

        .health-grid {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 14px;
        }

        .command {
          display: block;
          margin-top: 10px;
          padding: 8px 10px;
          border-radius: 12px;
          border: 1px solid rgba(217, 197, 150, 0.15);
          background: rgba(0, 0, 0, 0.22);
          color: var(--muted);
          font-family: "IBM Plex Mono", "Cascadia Code", monospace;
          font-size: 0.74rem;
          overflow-wrap: anywhere;
        }

        footer {
          margin: 28px 2px 0;
          color: var(--faint);
          font-size: 0.82rem;
        }

        @media (max-width: 1080px) {
          .hero,
          .grid-2,
          .goals-layout {
            grid-template-columns: 1fr;
          }

          .services-grid,
          .machines-grid,
          .health-grid {
            grid-template-columns: repeat(2, minmax(0, 1fr));
          }
        }

        @media (max-width: 720px) {
          .shell {
            width: min(100vw - 24px, 1420px);
            padding-top: 12px;
          }

          .hero-main,
          .panel,
          .service-card,
          .machine-card,
          .goal-card,
          .health-card {
            border-radius: 18px;
          }

          .hero-main {
            padding: 22px;
            min-height: auto;
          }

          .services-grid,
          .machines-grid,
          .health-grid {
            grid-template-columns: 1fr;
          }

          .section-header {
            align-items: flex-start;
            flex-direction: column;
          }
        }
      </style>
    </head>
    <body>
      <main class="shell">
        <section class="hero">
          <div class="hero-main">
            <div class="eyebrow">Generated from flake evaluation</div>
            <h1>Home infra, one screen.</h1>
            <p class="lede" id="heroCopy"></p>
            <div class="hero-actions" id="heroActions"></div>
          </div>
          <div class="hero-side" id="summaryTiles"></div>
        </section>

        <section class="grid-2">
          <div class="panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Attention</h2>
                <p class="section-copy">Computed from evaluated host config. No live mutations, no secret telemetry.</p>
              </div>
            </div>
            <div class="signal-list" id="attentionList"></div>
          </div>
          <div class="panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Quick Actions</h2>
                <p class="section-copy">Safe links, hosted live status, and local validation commands.</p>
              </div>
            </div>
            <div class="signal-list" id="liveStatus"></div>
            <div id="quickActions"></div>
          </div>
        </section>

        <section class="section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Services</h2>
              <p class="section-copy">The homepage layer: what exists, where it lives, and how exposed it is.</p>
            </div>
          </div>
          <div class="services-grid" id="servicesGrid"></div>
        </section>

        <section class="section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Machines</h2>
              <p class="section-copy">Small-fleet view. No filter wall; legacy/lab hosts are visible but de-emphasized.</p>
            </div>
          </div>
          <div class="machines-grid" id="machinesGrid"></div>
        </section>

        <section class="section goals-layout">
          <div class="panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Roadmap</h2>
                <p class="section-copy">Focused goals only. Completed work is summarized, not turned into a kanban archive.</p>
              </div>
            </div>
            <div class="goal-list" id="goalList"></div>
          </div>
          <aside class="panel" id="goalSummary"></aside>
        </section>

        <section class="section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Build & Invariants</h2>
              <p class="section-copy">Static evaluation signals. Use Grafana for runtime graphs and alert history.</p>
            </div>
          </div>
          <div class="health-grid" id="healthGrid"></div>
        </section>

        <footer id="footer"></footer>
      </main>

      <script src="wave3-data.js"></script>
      <script>
        const data = ${dataJson};
        const hosts = data.hosts;
        const goals = data.goals;
        const wave3Data = window.__WAVE3_DATA__ || { hosts: { } };
        const hostByName = Object.fromEntries(hosts.map(host => [host.name, host]));
        const homeserver = hostByName["homeserver-gcp"];
        const mainHost = hostByName["main"];
        const repoUrl = data.repository;

        const labels = {
          openssh: "SSH",
          tailscale: "Tailscale",
          firewall: "Firewall",
          fail2ban: "fail2ban",
          vaultwarden: "Vaultwarden",
          syncthing: "Syncthing",
          nginx: "Nginx",
          adguard: "AdGuard Home",
          grafana: "Grafana",
          loki: "Loki",
          mimir: "Mimir",
          tempo: "Tempo",
          restic: "Restic",
          hyprland: "Hyprland",
          observabilityStack: "LGTM",
          observabilityClient: "Telemetry client",
          usbguard: "USBGuard",
          lanzaboote: "Secure Boot",
        };

        const statusTone = {
          active: "good",
          "legacy-supported": "warn",
          inactive: "off",
        };

        function el(tag, cls, text) {
          const node = document.createElement(tag);
          if (cls) node.className = cls;
          if (text !== undefined) node.textContent = text;
          return node;
        }

        function link(label, href, cls) {
          const a = el("a", cls || "card-link", label);
          a.href = href;
          a.target = "_blank";
          a.rel = "noreferrer";
          return a;
        }

        function humanBytes(bytes) {
          if (bytes == null) return "unknown";
          if (bytes < 1024) return String(bytes) + " B";
          const units = ["KiB", "MiB", "GiB", "TiB"];
          let value = bytes / 1024;
          let unit = "KiB";
          for (const next of units.slice(1)) {
            if (value < 1024) break;
            value = value / 1024;
            unit = next;
          }
          return value.toFixed(value >= 10 ? 0 : 1) + " " + unit;
        }

        function wave3For(hostName) {
          return wave3Data.hosts?.[hostName] ?? null;
        }

        function healthCounts(host) {
          const results = host.health?.invariantResults ?? [];
          const failedResults = results.filter(result => !result.passed);
          return {
            total: results.length,
            passed: results.length - failedResults.length,
            failed: failedResults.length,
            failedResults,
            status: failedResults.length === 0 ? "pass" : "warn",
          };
        }

        function securityGaps(host) {
          const gaps = [];
          if (host.services.openssh && !host.services.fail2ban) gaps.push("SSH without fail2ban");
          if (host.services.openssh && !host.services.firewall) gaps.push("SSH without firewall");
          if (host.services.tailscale && !host.services.firewall) gaps.push("Tailscale without firewall");
          if (host.name !== "vm" && host.profiles.desktop && !host.services.usbguard) gaps.push("Desktop without USBGuard");
          return gaps;
        }

        function hostCommand(host) {
          return "nix build '.#nixosConfigurations." + host.name + ".config.system.build.toplevel'";
        }

        function deployCommand(host) {
          if (host.name === "main") return "nh os switch --hostname main .";
          if (host.deployable) return "deploy '.#" + host.name + "'";
          return null;
        }

        function buildSummaryTiles() {
          const activeHosts = hosts.filter(host => host.status === "active").length;
          const criticalBackups = hosts.filter(host => host.backupClass === "critical").length;
          const exposedPublicPorts = hosts.reduce((sum, host) => sum + host.openTCPPorts.length + host.openUDPPorts.length, 0);
          const failingHosts = hosts.filter(host => healthCounts(host).failed > 0).length;
          const enabledServices = new Set();
          for (const host of hosts) {
            for (const [name, enabled] of Object.entries(host.services)) {
              if (enabled) enabledServices.add(name);
            }
          }

          const tiles = [
            [activeHosts + "/" + hosts.length, "active machines", homeserver?.tailnetFQDN || "tailnet-only homeserver"],
            [enabledServices.size, "service types", "Vaultwarden, LGTM, DNS, backups, Tailscale"],
            [criticalBackups, "critical backup host", "Restic/B2 plus provider snapshots"],
            [failingHosts, "hosts with failed invariants", exposedPublicPorts === 0 ? "public firewall stays closed" : exposedPublicPorts + " public port entries"],
          ];

          const container = document.getElementById("summaryTiles");
          container.innerHTML = "";
          for (const [value, label, note] of tiles) {
            const tile = el("article", "status-tile");
            tile.appendChild(el("div", "tile-label", label));
            tile.appendChild(el("strong", "tile-value", String(value)));
            tile.appendChild(el("div", "tile-note", note));
            container.appendChild(tile);
          }
        }

        function buildHero() {
          const hostNames = hosts.map(host => host.name).join(", ");
          document.getElementById("heroCopy").textContent =
            "A generated homepage for " + hostNames + ". Static flake inventory gives it structure; when hosted on homeserver-gcp it layers in read-only live status.";

          const actions = document.getElementById("heroActions");
          actions.innerHTML = "";
          if (homeserver?.tailnetFQDN && homeserver.services.vaultwarden) {
            actions.appendChild(link("Vaultwarden", "https://" + homeserver.tailnetFQDN + "/", "action primary"));
          }
          if (homeserver?.tailnetFQDN) {
            actions.appendChild(link("Hosted homepage", "https://" + homeserver.tailnetFQDN + "/home/", "action"));
          }
          actions.appendChild(link("Repo", repoUrl, "action"));
          actions.appendChild(link("Homeserver docs", repoUrl + "/blob/main/docs/homeserver-goals.md", "action"));
        }

        function attentionItems() {
          const items = [];
          for (const host of hosts) {
            const health = healthCounts(host);
            for (const result of health.failedResults) {
              items.push({
                tone: "bad",
                host: host.name,
                title: "Invariant failed",
                detail: result.name,
              });
            }
            for (const gap of securityGaps(host)) {
              items.push({
                tone: "warn",
                host: host.name,
                title: "Security gap",
                detail: gap,
              });
            }
            if (host.backupClass === "critical" && host.resticBackups.length === 0) {
              items.push({
                tone: "bad",
                host: host.name,
                title: "Critical backup metadata without restic job",
                detail: "Registry marks this host critical, but no restic backup is evaluated.",
              });
            }
          }

          if (items.length === 0) {
            items.push({
              tone: "good",
              host: "fleet",
              title: "No generated attention items",
              detail: "Static invariants and obvious security checks pass in this evaluation.",
            });
          }
          return items;
        }

        function buildAttention() {
          const container = document.getElementById("attentionList");
          container.innerHTML = "";
          for (const item of attentionItems().slice(0, 6)) {
            const node = el("article", "signal " + item.tone);
            const head = el("div", "signal-title");
            head.appendChild(el("span", null, item.title));
            head.appendChild(el("span", "pill " + (item.tone === "bad" ? "bad" : item.tone), item.host));
            node.appendChild(head);
            node.appendChild(el("div", "signal-detail", item.detail));
            container.appendChild(node);
          }
        }

        function formatAge(seconds) {
          if (seconds == null || Number.isNaN(seconds)) return "unknown";
          if (seconds < 90) return Math.max(0, Math.round(seconds)) + "s ago";
          if (seconds < 7200) return Math.round(seconds / 60) + "m ago";
          if (seconds < 172800) return Math.round(seconds / 3600) + "h ago";
          return Math.round(seconds / 86400) + "d ago";
        }

        function serviceTone(state) {
          if (state === "active") return "good";
          if (state === "inactive") return "warn";
          return "off";
        }

        function renderLiveStatus(status) {
          const container = document.getElementById("liveStatus");
          container.innerHTML = "";

          const failedCount = status.failedUnits?.length || 0;
          const serviceEntries = Object.entries(status.services || {});
          const activeServices = serviceEntries.filter(([, state]) => state === "active").length;

          const summary = el("article", "signal " + (failedCount ? "bad" : "good"));
          const summaryHead = el("div", "signal-title");
          summaryHead.appendChild(el("span", null, "Live status"));
          summaryHead.appendChild(el("span", "pill " + (failedCount ? "bad" : "good"), failedCount ? failedCount + " failed" : "healthy"));
          summary.appendChild(summaryHead);
          summary.appendChild(el("div", "signal-detail", "Generated by " + status.host + " " + formatAge(Math.floor(Date.now() / 1000) - status.generatedAt) + ". " + activeServices + "/" + serviceEntries.length + " tracked services active."));
          container.appendChild(summary);

          const services = el("article", "signal");
          services.appendChild(el("div", "signal-title", "Runtime services"));
          const serviceChips = el("div", "meta-line");
          for (const [name, state] of serviceEntries) {
            serviceChips.appendChild(el("span", "pill " + serviceTone(state), name + ": " + state));
          }
          services.appendChild(serviceChips);
          container.appendChild(services);

          const metrics = status.metrics || {};
          const backup = el("article", "signal " + (metrics.resticBackupAgeSeconds != null && metrics.resticBackupAgeSeconds < 36 * 3600 ? "good" : "warn"));
          backup.appendChild(el("div", "signal-title", "Backup and audit freshness"));
          backup.appendChild(el("div", "signal-detail", "Backup " + formatAge(metrics.resticBackupAgeSeconds) + " · restic check " + formatAge(metrics.resticCheckAgeSeconds) + " · Lynis " + formatAge(metrics.lynisAgeSeconds) + " · Vulnix " + formatAge(metrics.vulnixAgeSeconds)));
          const metricChips = el("div", "meta-line");
          if (metrics.lynisHardeningIndex != null) metricChips.appendChild(el("span", "chip", "Lynis " + metrics.lynisHardeningIndex));
          if (metrics.lynisWarningsTotal != null) metricChips.appendChild(el("span", "chip", metrics.lynisWarningsTotal + " Lynis warnings"));
          if (metrics.vulnixCveTotal != null) metricChips.appendChild(el("span", "chip", metrics.vulnixCveTotal + " CVEs"));
          backup.appendChild(metricChips);
          container.appendChild(backup);
        }

        function renderLiveUnavailable() {
          const container = document.getElementById("liveStatus");
          container.innerHTML = "";
          const node = el("article", "signal warn");
          const head = el("div", "signal-title");
          head.appendChild(el("span", null, "Live status unavailable"));
          head.appendChild(el("span", "pill warn", "static mode"));
          node.appendChild(head);
          node.appendChild(el("div", "signal-detail", "Open the hosted copy at /home/ on homeserver-gcp to load status.json. Local file previews use static flake data only."));
          container.appendChild(node);
        }

        function loadLiveStatus() {
          fetch("status.json", { cache: "no-store" })
            .then(response => {
              if (!response.ok) throw new Error("status unavailable");
              return response.json();
            })
            .then(renderLiveStatus)
            .catch(renderLiveUnavailable);
        }

        function buildQuickActions() {
          const container = document.getElementById("quickActions");
          container.innerHTML = "";
          const list = el("div", "signal-list");
          const packageBuild = el("article", "signal good");
          packageBuild.appendChild(el("div", "signal-title", "Build homepage"));
          packageBuild.appendChild(el("code", "command", "nix build '.#packages.x86_64-linux.inventory'"));
          packageBuild.appendChild(el("code", "command", "rsync -a --delete --rsync-path='sudo rsync' result/ user@homeserver-gcp.tail90fc7a.ts.net:/var/lib/homepage/public/"));
          packageBuild.appendChild(el("code", "command", "ssh user@homeserver-gcp.tail90fc7a.ts.net 'sudo systemctl start homepage-status.service'"));
          list.appendChild(packageBuild);

          for (const host of hosts.filter(host => host.status === "active")) {
            const card = el("article", "signal");
            const head = el("div", "signal-title");
            head.appendChild(el("span", null, "Validate " + host.name));
            head.appendChild(el("span", "pill info", host.system));
            card.appendChild(head);
            card.appendChild(el("code", "command", hostCommand(host)));
            const deploy = deployCommand(host);
            if (deploy) card.appendChild(el("code", "command", deploy));
            list.appendChild(card);
          }
          container.appendChild(list);
        }

        function serviceCatalog() {
          const fqdn = homeserver?.tailnetFQDN;
          const grafanaUrl = fqdn ? "https://" + fqdn + "/grafana/" : null;
          const vaultwardenUrl = fqdn ? "https://" + fqdn + "/" : null;
          const adguardUrl = fqdn ? "http://" + fqdn + ":3001/" : null;
          const b2 = homeserver?.resticBackups.find(backup => backup.name === "b2");

          return [
            {
              name: "Vaultwarden",
              host: homeserver,
              enabled: homeserver?.services.vaultwarden,
              tone: "good",
              accent: "#e0b15b",
              summary: "Password vault behind the homeserver reverse proxy. The homepage only links to it; no vault telemetry is surfaced here.",
              chips: ["Tailscale HTTPS", "Nginx", "no signups"],
              links: vaultwardenUrl ? [["Open vault", vaultwardenUrl]] : [],
            },
            {
              name: "Grafana / LGTM",
              host: homeserver,
              enabled: homeserver?.services.observabilityStack,
              tone: "good",
              accent: "#74b7b0",
              summary: "Metrics, logs, traces, backup health, CVEs, and security audit signals. The homepage consumes summaries so Grafana is only a fallback.",
              chips: ["Grafana", "Loki", "Mimir", "Tempo"],
              links: grafanaUrl ? [["Grafana fallback", grafanaUrl]] : [],
            },
            {
              name: "AdGuard Home",
              host: homeserver,
              enabled: homeserver?.services.adguard,
              tone: "good",
              accent: "#9bcf77",
              summary: "Tailnet DNS and filtering. DNS/UI ports are exposed on tailscale0, not the public firewall.",
              chips: ["TCP/UDP 53", "UI 3001", "MagicDNS target"],
              links: adguardUrl ? [["Open UI", adguardUrl]] : [],
            },
            {
              name: "Backups",
              host: homeserver,
              enabled: !!b2,
              tone: "good",
              accent: "#8fb3d9",
              summary: "Restic backs up Vaultwarden, Grafana, and AdGuard state to Backblaze B2 with critical retention policy.",
              chips: b2 ? ["job " + b2.name, (b2.paths.length || 0) + " paths", b2.timer || "timer"] : ["not configured"],
              links: [[ "Restore drill", repoUrl + "/blob/main/docs/restore-drill.md" ]],
            },
            {
              name: "GCE Snapshots",
              host: homeserver,
              enabled: !!homeserver,
              tone: "info",
              accent: "#d77f4f",
              summary: "Provider-local daily boot disk rollback points configured in OpenTofu. They complement restic; they are not the backup source of truth.",
              chips: ["infra/main.tf", "daily", "7 day default"],
              links: [[ "Operations notes", repoUrl + "/blob/main/docs/operations.md" ]],
            },
            {
              name: "Tailnet Edge",
              host: homeserver,
              enabled: homeserver?.services.tailscale && homeserver?.services.nginx,
              tone: "good",
              accent: "#b793d1",
              summary: "Tailscale certs, nginx routing, SSH, HTTPS, DNS, and AdGuard UI stay scoped to tailnet access.",
              chips: [
                "tag " + (homeserver?.tailscaleTag || "server"),
                "TCP " + (homeserver?.tailscaleTCPPorts || []).join(","),
                "UDP " + (homeserver?.tailscaleUDPPorts || []).join(","),
              ],
              links: [[ "Host docs", repoUrl + "/blob/main/hosts/homeserver-gcp/CLAUDE.md" ]],
            },
          ];
        }

        function buildServices() {
          const grid = document.getElementById("servicesGrid");
          grid.innerHTML = "";
          for (const service of serviceCatalog()) {
            const card = el("article", "service-card");
            card.style.setProperty("--accent", service.accent);
            const top = el("div", "service-top");
            top.appendChild(el("div", "service-name", service.name));
            top.appendChild(el("span", "pill " + (service.enabled ? service.tone : "off"), service.enabled ? "configured" : "off"));
            card.appendChild(top);
            card.appendChild(el("p", "service-desc", service.summary));

            const chips = el("div", "meta-line");
            for (const chip of service.chips.filter(Boolean)) chips.appendChild(el("span", "chip", chip));
            card.appendChild(chips);

            if (service.links.length) {
              const links = el("div", "card-links");
              for (const [label, href] of service.links) links.appendChild(link(label, href));
              card.appendChild(links);
            }

            grid.appendChild(card);
          }
        }

        function buildMachines() {
          const grid = document.getElementById("machinesGrid");
          grid.innerHTML = "";
          const ordered = [...hosts].sort((a, b) => {
            const statusRank = status => status === "active" ? 0 : status === "legacy-supported" ? 1 : 2;
            return statusRank(a.status) - statusRank(b.status) || a.name.localeCompare(b.name);
          });

          for (const host of ordered) {
            const health = healthCounts(host);
            const card = el("article", "machine-card");
            const head = el("div", "machine-head");
            head.appendChild(el("div", "machine-name", host.name));
            head.appendChild(el("span", "pill " + (statusTone[host.status] || "off"), host.status));
            card.appendChild(head);

            const rows = el("div", "rows");
            const activeServices = Object.entries(host.services)
              .filter(([, enabled]) => enabled)
              .map(([name]) => labels[name] || name);
            const backup = host.resticBackups.length ? host.resticBackups.map(item => item.name).join(", ") : "none";
            const closure = humanBytes(wave3For(host.name)?.closureSizeBytes ?? null);
            const ports = host.openTCPPorts.length || host.openUDPPorts.length
              ? "public " + host.openTCPPorts.concat(host.openUDPPorts).join(",")
              : "public closed";
            const tailnet = host.tailscaleTCPPorts.length || host.tailscaleUDPPorts.length
              ? "tailnet " + host.tailscaleTCPPorts.concat(host.tailscaleUDPPorts).join(",")
              : host.services.tailscale ? "tailnet client" : "off";
            const rowData = [
              ["Role", host.homeManagerRole || (host.profiles.desktop ? "desktop" : "server")],
              ["Services", activeServices.slice(0, 5).join(", ") || "none"],
              ["Network", ports + "; " + tailnet],
              ["Backups", host.backupClass ? host.backupClass + " / " + backup : backup],
              ["Build", closure + "; " + health.passed + "/" + health.total + " checks"],
            ];
            for (const [key, value] of rowData) {
              const row = el("div", "row");
              row.appendChild(el("span", null, key));
              row.appendChild(el("strong", null, value));
              rows.appendChild(row);
            }
            card.appendChild(rows);
            grid.appendChild(card);
          }
        }

        function buildGoals() {
          const active = goals
            .filter(goal => goal.status !== "done")
            .sort((a, b) => {
              const rank = { now: 0, next: 1, blocked: 2, later: 3 };
              return (rank[a.status] ?? 9) - (rank[b.status] ?? 9) || a.title.localeCompare(b.title);
            });
          const visible = active.slice(0, 6);
          const list = document.getElementById("goalList");
          list.innerHTML = "";

          if (!visible.length) {
            const card = el("article", "goal-card");
            card.appendChild(el("div", "goal-title", "No active roadmap items"));
            card.appendChild(el("div", "goal-summary", "All tracked goals are marked done in lib/goals.nix."));
            list.appendChild(card);
          }

          for (const goal of visible) {
            const card = el("article", "goal-card");
            const head = el("div", "goal-head");
            head.appendChild(el("div", "goal-title", goal.title));
            head.appendChild(el("span", "pill " + (goal.status === "now" ? "good" : goal.status === "blocked" ? "bad" : "info"), goal.status));
            card.appendChild(head);
            card.appendChild(el("div", "goal-summary", goal.summary));

            const chips = el("div", "meta-line");
            chips.appendChild(el("span", "chip", goal.area));
            chips.appendChild(el("span", "chip", goal.priority));
            for (const host of (goal.hosts || []).slice(0, 3)) chips.appendChild(el("span", "chip", host));
            card.appendChild(chips);

            if ((goal.docs || []).length) {
              const links = el("div", "card-links");
              for (const doc of goal.docs.slice(0, 2)) links.appendChild(link(doc.path, doc.url));
              card.appendChild(links);
            }
            list.appendChild(card);
          }

          const done = goals.filter(goal => goal.status === "done").length;
          const now = goals.filter(goal => goal.status === "now").length;
          const next = goals.filter(goal => goal.status === "next").length;
          const later = goals.filter(goal => goal.status === "later").length;
          const panel = document.getElementById("goalSummary");
          panel.innerHTML = "";
          panel.appendChild(el("h2", "section-title", "Goal Shape"));
          panel.appendChild(el("p", "section-copy", "The homepage shows active direction only; dependency graphs and long-form sequencing stay in docs."));
          const rows = el("div", "rows");
          for (const [key, value] of [["Now", now], ["Next", next], ["Later", later], ["Done", done]]) {
            const row = el("div", "row");
            row.appendChild(el("span", null, key));
            row.appendChild(el("strong", null, String(value)));
            rows.appendChild(row);
          }
          panel.appendChild(rows);
          const links = el("div", "card-links");
          links.appendChild(link("Project goals", repoUrl + "/blob/main/docs/goals.md"));
          links.appendChild(link("Homeserver goals", repoUrl + "/blob/main/docs/homeserver-goals.md"));
          panel.appendChild(links);
        }

        function buildHealth() {
          const grid = document.getElementById("healthGrid");
          grid.innerHTML = "";
          for (const host of hosts) {
            const health = healthCounts(host);
            const card = el("article", "health-card");
            const head = el("div", "health-head");
            head.appendChild(el("div", "health-name", host.name));
            head.appendChild(el("span", "pill " + (health.failed ? "bad" : "good"), health.failed ? health.failed + " fail" : "pass"));
            card.appendChild(head);

            const rows = el("div", "rows");
            const dataRows = [
              ["Closure", humanBytes(wave3For(host.name)?.closureSizeBytes ?? null)],
              ["State version", host.stateVersion],
              ["Invariants", health.passed + "/" + health.total],
              ["System", host.system],
            ];
            for (const [key, value] of dataRows) {
              const row = el("div", "row");
              row.appendChild(el("span", null, key));
              row.appendChild(el("strong", null, value));
              rows.appendChild(row);
            }
            card.appendChild(rows);

            if (health.failedResults.length) {
              const chips = el("div", "meta-line");
              for (const result of health.failedResults.slice(0, 4)) chips.appendChild(el("span", "chip", result.name));
              card.appendChild(chips);
            }
            grid.appendChild(card);
          }
        }

        function buildFooter() {
          const totalClosure = hosts.reduce((sum, host) => sum + (wave3For(host.name)?.closureSizeBytes ?? 0), 0);
          document.getElementById("footer").textContent =
            "Generated by packages/inventory.nix • " + hosts.length + " hosts • " + goals.length + " goals • total closure " + humanBytes(totalClosure) + " • " + repoUrl;
        }

        buildHero();
        buildSummaryTiles();
        buildAttention();
        loadLiveStatus();
        buildQuickActions();
        buildServices();
        buildMachines();
        buildGoals();
        buildHealth();
        buildFooter();
      </script>
    </body>
    </html>
  '';
in
pkgs.runCommand "inventory"
  {
    nativeBuildInputs = [ pkgs.nix ];
    passAsFile = [
      "html"
      "hostSpec"
    ];
    inherit html;
    inherit hostSpec;
  }
  ''
    mkdir -p $out
    {
      echo 'window.__WAVE3_DATA__ = { hosts: {'
      while IFS=$'\t' read -r hostName closurePath || [ -n "$hostName" ]; do
        [ -n "$hostName" ] || continue
        if closureInfo="$(nix path-info -S "$closurePath" 2>/dev/null)"; then
          closureBytes="$(printf '%s\n' "$closureInfo" | awk '{print $2}')"
          echo "  \"''${hostName}\": { \"closureSizeBytes\": ''${closureBytes} },"
        else
          echo "  \"''${hostName}\": { \"closureSizeBytes\": null },"
        fi
      done < "$hostSpecPath"
      echo '} };'
    } > "$out/wave3-data.js"
    cp "$htmlPath" "$out/index.html"
  ''
