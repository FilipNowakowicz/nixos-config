[
  {
    id = "config-dashboard-wave-1";
    title = "Homepage dashboard first pass";
    status = "done";
    priority = "p1";
    area = "platform";
    summary = "Replace the raw generated inventory with a single homeserver homepage: strong summary, first-class services, simpler machines, focused goals, and computed attention.";
    hosts = [
      "main"
      "vm"
    ];
    services = [ "inventory" ];
    blockedBy = [ ];
    unlocks = [
      "config-dashboard-wave-2"
      "config-dashboard-wave-3"
    ];
    docs = [
      "docs/goals.md"
    ];
  }
  {
    id = "gcp-homeserver";
    title = "GCP homeserver";
    status = "done";
    priority = "p1";
    area = "homeserver";
    summary = "Boot the homeserver configuration on GCE with Tailscale, Vaultwarden, LGTM stack, Nginx, and Restic backups to B2.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "tailscale"
      "vaultwarden"
      "nginx"
      "lgtm"
    ];
    blockedBy = [ ];
    unlocks = [
      "deploy-pipeline"
      "b2-backups"
      "homeserver-smoke-tests"
      "adguard"
      "lgtm-tuning"
    ];
    docs = [
      "docs/homeserver-goals.md"
      "hosts/homeserver-gcp/CLAUDE.md"
    ];
  }
  {
    id = "homeserver-smoke-tests";
    title = "Homeserver live smoke tests";
    status = "done";
    priority = "p2";
    area = "homeserver";
    summary = "Probe Vaultwarden, Grafana, and observability ingest paths so deployments catch broken routing, TLS, and auth wiring.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "nginx"
      "vaultwarden"
      "grafana"
      "smoke-tests"
    ];
    blockedBy = [ "gcp-homeserver" ];
    unlocks = [
      "deploy-pipeline"
      "secret-rotation"
    ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "deploy-pipeline";
    title = "Automated deploy pipeline";
    status = "later";
    priority = "p2";
    area = "deploy";
    summary = "Add a self-hosted Actions runner, extend smoke coverage, and automate homeserver-gcp then main deployment after passing checks.";
    hosts = [
      "homeserver-gcp"
      "main"
    ];
    services = [
      "deploy-rs"
      "github-actions"
      "smoke-tests"
    ];
    blockedBy = [
      "gcp-homeserver"
      "homeserver-smoke-tests"
    ];
    unlocks = [ "secret-rotation" ];
    docs = [
      "docs/goals.md"
      "docs/homeserver-goals.md"
    ];
  }
  {
    id = "b2-backups";
    title = "Backup verification and restore drill";
    status = "done";
    priority = "p2";
    area = "backup";
    summary = "Verify homeserver-gcp B2 backups with periodic checks and restore drills.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "restic"
      "b2"
    ];
    blockedBy = [
      "gcp-homeserver"
    ];
    unlocks = [
      "adguard"
      "gce-disk-snapshots"
    ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "vaultwarden-websocket";
    title = "Vaultwarden websocket notifications";
    status = "done";
    priority = "p2";
    area = "homeserver";
    summary = "Enable the Vaultwarden websocket notification path through Nginx so clients receive instant sync updates.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "vaultwarden"
      "nginx"
    ];
    blockedBy = [ "homeserver-smoke-tests" ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "adguard";
    title = "Local DNS and ad-blocking";
    status = "done";
    priority = "p2";
    area = "homeserver";
    summary = "Deploy AdGuard Home behind the homeserver and connect it to Tailscale MagicDNS for network-wide filtering.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "adguard"
      "tailscale"
    ];
    blockedBy = [
      "gcp-homeserver"
      "b2-backups"
      "lgtm-tuning"
    ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "lgtm-tuning";
    title = "LGTM tuning";
    status = "done";
    priority = "p2";
    area = "observability";
    summary = "Expand dashboards and alerts, then tune retention and cardinality for longer-running operation.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "lgtm"
      "grafana"
      "loki"
      "prometheus"
    ];
    blockedBy = [
      "gcp-homeserver"
      "homeserver-smoke-tests"
    ];
    unlocks = [
      "host-introspection"
      "adguard"
    ];
    docs = [
      "docs/goals.md"
      "docs/homeserver-goals.md"
    ];
  }
  {
    id = "gce-disk-snapshots";
    title = "GCE disk snapshots";
    status = "done";
    priority = "p2";
    area = "backup";
    summary = "Add short-retention managed snapshots for fast homeserver rollback alongside restic application backups.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "opentofu"
      "gcp"
    ];
    blockedBy = [ "b2-backups" ];
    unlocks = [ "adguard" ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "config-dashboard-wave-2";
    title = "Config dashboard wave 2";
    status = "later";
    priority = "p2";
    area = "platform";
    summary = "Add validation commands, dependency context, and richer host/service relationships to the dashboard.";
    hosts = [
      "main"
      "homeserver-gcp"
      "vm"
    ];
    services = [
      "inventory"
      "deploy-rs"
      "smoke-tests"
    ];
    blockedBy = [ "config-dashboard-wave-1" ];
    unlocks = [ ];
    docs = [
      "docs/goals.md"
    ];
  }
  {
    id = "config-dashboard-wave-3";
    title = "Config dashboard wave 3";
    status = "done";
    priority = "p3";
    area = "platform";
    summary = "Add closure-size, invariant, and validation-health signals so the dashboard can show drift and cost as well as structure.";
    hosts = [
      "main"
      "homeserver-gcp"
      "vm"
    ];
    services = [
      "inventory"
      "checks"
    ];
    blockedBy = [ "config-dashboard-wave-1" ];
    unlocks = [ ];
    docs = [
      "docs/goals.md"
    ];
  }
  {
    id = "host-introspection";
    title = "Host introspection to LGTM";
    status = "done";
    priority = "p3";
    area = "observability";
    summary = "Feed auditd, osquery, or lynis output into Loki so the observability stack proves its value beyond infra metrics.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "lgtm"
      "auditd"
      "osquery"
    ];
    blockedBy = [ "lgtm-tuning" ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "acl-drift-detection";
    title = "ACL drift detection";
    status = "done";
    priority = "p3";
    area = "security";
    summary = "Compare the rendered Tailscale ACL package against the live tailnet policy and fail CI on drift.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "tailscale"
      "github-actions"
    ];
    blockedBy = [ ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "vulnix-dashboard";
    title = "Vulnix CVE dashboard";
    status = "done";
    priority = "p3";
    area = "security";
    summary = "Schedule vulnix against the live closure, export results, and alert on new critical vulnerabilities.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "vulnix"
      "grafana"
      "mimir"
    ];
    blockedBy = [ "lgtm-tuning" ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "service-composition-dsl";
    title = "Service composition DSL";
    status = "later";
    priority = "p3";
    area = "platform";
    summary = "Create a declarative app module that auto-wires hardening, observability, backup, and port plumbing for new services.";
    hosts = [
      "homeserver-gcp"
    ];
    services = [
      "sandboxing"
      "restic"
      "lgtm"
    ];
    blockedBy = [ ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "typed-generators";
    title = "Expand typed generators";
    status = "later";
    priority = "p3";
    area = "platform";
    summary = "Extend the typed generator approach beyond Alloy and Grafana into other declarative domains such as nginx vhosts and timers.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "alloy"
      "grafana"
      "nginx"
    ];
    blockedBy = [ ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
  {
    id = "secret-rotation";
    title = "Secret rotation ritual";
    status = "later";
    priority = "p3";
    area = "security";
    summary = "Define a repeatable secret rotation checklist and expose age or rotation health through observability signals.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "sops"
      "age"
    ];
    blockedBy = [ "homeserver-smoke-tests" ];
    unlocks = [ ];
    docs = [
      "docs/goals.md"
      "docs/homeserver-goals.md"
    ];
  }
]
