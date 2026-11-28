# The self-hosted ntfy server on homeserver-gcp (#630): the facts its server
# config, every sender and the `main` subscriber share.
#
# Senders mark each message with a `source-<name>` tag. The subscriber on
# `main` maps it to a desktop app name and a quiet-shell glyph (a Lucide icon
# under packages/quiet-shell/shell/assets/icons), so notifications read as coming
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
      glyph = "server";
      emoji = "cloud";
    };
    builder = {
      appName = "Remote builder";
      glyph = "hammer";
      emoji = "hammer_and_wrench";
    };
    backups = {
      appName = "Backups";
      glyph = "hard-drive";
      emoji = "floppy_disk";
    };
    phone-backup = {
      appName = "Phone backup";
      glyph = "smartphone";
      emoji = "iphone";
    };
    on-worker = {
      appName = "On-worker";
      glyph = "terminal";
      emoji = "gear";
    };
    agents = {
      appName = "Agents";
      glyph = "notebook-pen";
      emoji = "brain";
    };
    deploys = {
      appName = "Deploys";
      glyph = "rocket";
      emoji = "rocket";
    };
    # Failures of main's own system units that aren't backups.
    system = {
      appName = "System";
      glyph = "monitor";
      emoji = "computer";
    };
  };

  # The X-Tags header value for a source.
  tags = source: "source-${source},${sources.${source}.emoji}";
}
