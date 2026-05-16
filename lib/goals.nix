[
  {
    id = "tailscale-aware-grafana-sso";
    title = "Tailscale-aware Grafana SSO";
    status = "done";
    priority = "p2";
    area = "security";
    summary = "Replace Grafana local admin login with tailnet identity after the proxy and break-glass story are clear.";
    hosts = [ "homeserver-gcp" ];
    services = [
      "tailscale"
      "grafana"
      "nginx"
    ];
    blockedBy = [ ];
    unlocks = [ ];
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
    ];
    services = [
      "inventory"
      "deploy-rs"
      "smoke-tests"
    ];
    blockedBy = [ ];
    unlocks = [ ];
    docs = [
      "docs/goals.md"
    ];
  }
  {
    id = "service-composition-dsl";
    title = "Service composition DSL";
    status = "deferred";
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
    status = "done";
    priority = "p3";
    area = "platform";
    summary = "Extend the typed generator approach with narrow helpers for repeated nginx proxy locations and systemd timers.";
    hosts = [
      "main"
      "homeserver-gcp"
    ];
    services = [
      "alloy"
      "grafana"
      "nginx"
      "systemd"
    ];
    blockedBy = [ ];
    unlocks = [ ];
    docs = [ "docs/homeserver-goals.md" ];
  }
]
