# Unit tests for Alloy HCL generator logic.
{
  nixpkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  gen = import ../../lib/generators.nix { inherit lib; };

  failures = lib.runTests {
    testEmptyComponentList = {
      expr = gen.toAlloyHCL [ ];
      expected = "";
    };

    testEmptyComponentBody = {
      expr = gen.toAlloyHCL [
        {
          type = "prometheus.exporter.unix";
          label = "local";
          body = { };
        }
      ];
      expected = "prometheus.exporter.unix \"local\" {\n\n}";
    };

    testStringAttribute = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.write";
          label = "target";
          body = {
            url = "http://loki:3100";
          };
        }
      ];
      expected = "loki.write \"target\" {\n  url = \"http://loki:3100\"\n}";
    };

    testBoolAttribute = {
      expr = gen.toAlloyHCL [
        {
          type = "x";
          label = "y";
          body = {
            debug = false;
            enabled = true;
          };
        }
      ];
      expected = "x \"y\" {\n  debug = false\n  enabled = true\n}";
    };

    testStringEscaping = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.write";
          label = "escaped";
          body = {
            value = "say \"hi\" \\ path";
          };
        }
      ];
      expected = "loki.write \"escaped\" {\n  value = \"say \\\"hi\\\" \\\\ path\"\n}";
    };

    testNestedBlock = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.write";
          label = "target";
          body = {
            endpoint = gen.nestedBlock {
              url = "http://loki:3100";
            };
          };
        }
      ];
      expected = "loki.write \"target\" {\n  endpoint {\n    url = \"http://loki:3100\"\n  }\n}";
    };

    testRefInList = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.source.journal";
          label = "systemd";
          body = {
            forward_to = [ (gen.ref "loki.write.target.receiver") ];
          };
        }
      ];
      expected = "loki.source.journal \"systemd\" {\n  forward_to = [loki.write.target.receiver,]\n}";
    };

    testEmptyList = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.source.journal";
          label = "systemd";
          body = {
            relabel_rules = [ ];
          };
        }
      ];
      expected = "loki.source.journal \"systemd\" {\n  relabel_rules = []\n}";
    };

    testInlineObject = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.source.journal";
          label = "systemd";
          body = {
            labels = {
              job = "systemd-journal";
            };
          };
        }
      ];
      expected = "loki.source.journal \"systemd\" {\n  labels = {\n    job = \"systemd-journal\",\n  }\n}";
    };

    testListMultipleItems = {
      expr = gen.toAlloyHCL [
        {
          type = "x";
          label = "y";
          body = {
            tags = [
              "a"
              "b"
              "c"
            ];
          };
        }
      ];
      expected = "x \"y\" {\n  tags = [\"a\", \"b\", \"c\",]\n}";
    };

    testMultipleComponents = {
      expr = gen.toAlloyHCL [
        {
          type = "a";
          label = "1";
          body = {
            x = "1";
          };
        }
        {
          type = "b";
          label = "2";
          body = {
            y = "2";
          };
        }
      ];
      expected = "a \"1\" {\n  x = \"1\"\n}\n\nb \"2\" {\n  y = \"2\"\n}";
    };

    testDeepNestedBlock = {
      expr = gen.toAlloyHCL [
        {
          type = "loki.write";
          label = "target";
          body = {
            endpoint = gen.nestedBlock {
              basic_auth = gen.nestedBlock {
                password_file = "/run/secrets/pw";
                username = "user";
              };
              url = "http://loki";
            };
          };
        }
      ];
      expected = "loki.write \"target\" {\n  endpoint {\n    basic_auth {\n      password_file = \"/run/secrets/pw\"\n      username = \"user\"\n    }\n    url = \"http://loki\"\n  }\n}";
    };

    testNginxProxyLocationMinimal = {
      expr = gen.nginx.proxyLocation {
        target = "http://127.0.0.1:8222";
      };
      expected = {
        proxyPass = "http://127.0.0.1:8222";
      };
    };

    testNginxProxyLocationWithWebsocketsAndAuth = {
      expr = gen.nginx.proxyLocation {
        target = "http://127.0.0.1:3000";
        websockets = true;
        basicAuthFile = "/run/secrets/htpasswd";
        extraConfig = ''
          proxy_set_header X-Test true;
        '';
      };
      expected = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
        basicAuthFile = "/run/secrets/htpasswd";
        extraConfig = ''
          proxy_set_header X-Test true;
        '';
      };
    };

    testNginxProxyLocationExtraOptions = {
      expr = gen.nginx.proxyLocation {
        target = "http://127.0.0.1:9000";
        extraOptions = {
          recommendedProxySettings = true;
          proxyReadTimeout = "60s";
        };
      };
      expected = {
        proxyPass = "http://127.0.0.1:9000";
        recommendedProxySettings = true;
        proxyReadTimeout = "60s";
      };
    };

    testSystemdTimerWithJitter = {
      expr = gen.systemd.timer {
        schedule = "daily";
        jitter = "1h";
      };
      expected = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };

    testSystemdTimerEscapeHatch = {
      expr = gen.systemd.timer {
        schedule = "weekly";
        jitter = "2h";
        persistent = false;
        extraTimerConfig = {
          AccuracySec = "15m";
        };
      };
      expected = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = false;
          RandomizedDelaySec = "2h";
          AccuracySec = "15m";
        };
      };
    };

    testSystemdTimerWantedByOverride = {
      expr = gen.systemd.timer {
        schedule = "hourly";
        wantedBy = [ "custom.target" ];
      };
      expected = {
        wantedBy = [ "custom.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };
    };
  };
in
if failures == [ ] then
  pkgs.runCommand "lib-generators-tests" { } "touch $out"
else
  throw "lib/generators.nix tests failed:\n${lib.generators.toPretty { } failures}"
