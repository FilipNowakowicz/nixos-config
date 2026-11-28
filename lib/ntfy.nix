# The self-hosted ntfy server on homeserver-gcp (#630): the facts its server
# config, every sender and the `main` subscriber share.
#
# Senders mark each message with a `source-<name>` tag. The subscriber on
# `main` maps it to a desktop app name and icon, so notifications read as coming
# from their source, and the quiet shell groups them per source. The second tag
# is an emoji shortcode, which the Android app shows in front of the title.
{
  hostRegistry ? import ./hosts.nix,
}:
let
  server = hostRegistry.homeserver-gcp;
in
rec {
  # nginx terminates TLS here, on tailscale0 only; lib/hosts.nix admits the
  # sources that may reach it.
  port = 2586;
  # ntfy itself listens on loopback; on-host senders post here directly, so a
  # broken nginx or certificate can't stop them.
  internalPort = 12586;

  # One topic for everything; the source tag tells messages apart.
  topic = "fleet";

  baseUrl = "https://${server.tailnetFQDN}:${toString port}";
  topicUrl = "${baseUrl}/${topic}";
  localTopicUrl = "http://127.0.0.1:${toString internalPort}/${topic}";

  sources = {
    homeserver = {
      appName = "Homeserver";
      icon = "network-server";
      emoji = "cloud";
    };
    builder = {
      appName = "Remote builder";
      icon = "system-software-update";
      emoji = "hammer_and_wrench";
    };
    backups = {
      appName = "Backups";
      icon = "drive-harddisk";
      emoji = "floppy_disk";
    };
    phone-backup = {
      appName = "Phone backup";
      icon = "phone";
      emoji = "iphone";
    };
    on-worker = {
      appName = "On-worker";
      icon = "utilities-terminal";
      emoji = "gear";
    };
    deploys = {
      appName = "Deploys";
      icon = "system-software-install";
      emoji = "rocket";
    };
    # Failures of main's own system units that aren't backups.
    system = {
      appName = "System";
      icon = "computer";
      emoji = "computer";
    };
  };

  # The X-Tags header value for a source.
  tags = source: "source-${source},${sources.${source}.emoji}";
}
