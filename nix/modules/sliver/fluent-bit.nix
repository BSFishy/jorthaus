{
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  enabled = host.slivers.fluentBit.enable;
  victoriaLogsHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.victorialogs.enable) (builtins.attrValues hostInventory)
  );
  dataPath = "/var/lib/fluent-bit";
  victoriaLogsUri = "/insert/jsonline?_stream_fields=host,source,kubernetes_namespace,kubernetes_pod,kubernetes_container,stream,journal_unit,journal_identifier,journal_priority,journal_transport&_msg_field=message&_time_field=date";
  levelNormalizer = pkgs.writeText "fluent-bit-level.lua" ''
    local journalLevels = {
      ["0"] = "emerg", ["1"] = "alert", ["2"] = "critical", ["3"] = "error",
      ["4"] = "warning", ["5"] = "notice", ["6"] = "info", ["7"] = "debug",
    }
    local textLevels = {
      D = "debug", DEBUG = "debug", I = "info", INFO = "info",
      W = "warning", WARN = "warning", WARNING = "warning",
      E = "error", ERR = "error", ERROR = "error",
    }

    local function decode_quoted(value)
      local result, index = {}, 2
      while index < #value do
        local byte = string.sub(value, index, index)
        if byte ~= "\\" then
          table.insert(result, byte)
          index = index + 1
        else
          local escape = string.sub(value, index + 1, index + 1)
          local decoded = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }
          if escape == "u" then
            local codepoint = tonumber(string.sub(value, index + 2, index + 5), 16)
            if codepoint ~= nil and utf8 ~= nil and utf8.char ~= nil then
              table.insert(result, utf8.char(codepoint))
            else
              table.insert(result, "\\u" .. string.sub(value, index + 2, index + 5))
            end
            index = index + 6
          else
            table.insert(result, decoded[escape] or escape)
            index = index + 2
          end
        end
      end
      return table.concat(result)
    end

    local function decode_value(value, quoted)
      if quoted then return decode_quoted(value) end
      if value == "true" then return true end
      if value == "false" then return false end
      if value == "null" then return nil end
      local number = tonumber(value)
      return number ~= nil and number or value
    end

    local function parse_slog(message)
      local slog, index = {}, 1
      while index <= #message do
        local start = string.find(message, "%S", index)
        if start == nil then break end
        local equals = string.find(message, "=", start, true)
        if equals == nil then break end
        local key = string.sub(message, start, equals - 1)
        if string.find(key, "%s") ~= nil or key == "" then break end
        index = equals + 1
        local quoted = string.sub(message, index, index) == "\""
        local valueStart = index
        if quoted then
          index = index + 1
          while index <= #message do
            if string.sub(message, index, index) == "\\" then
              index = index + 2
            elseif string.sub(message, index, index) == "\"" then
              index = index + 1
              break
            else
              index = index + 1
            end
          end
        else
          local nextSpace = string.find(message, "%s", index)
          index = nextSpace or (#message + 1)
        end
        local value = string.sub(message, valueStart, index - 1)
        slog[key] = decode_value(value, quoted)
      end
      return slog["level"] ~= nil and slog or nil
    end

    function normalize_level(tag, timestamp, record)
      if record["level"] ~= nil then return 0, timestamp, record end

      local priority = record["PRIORITY"]
      if priority ~= nil then record["level"] = journalLevels[tostring(priority)] end

      local message = record["message"]
      if message ~= nil then
        local slog = parse_slog(message)
        if slog ~= nil then
          record["slog"] = slog
          if record["level"] == nil then record["level"] = textLevels[string.upper(slog["level"])] end
        end
      end

      if record["level"] == nil and message ~= nil then
        for _, pattern in ipairs({ "^%s*%[([A-Za-z]+)%]", "^%s*([DIWE])%d%d%d%d", "%[([A-Za-z]+)%]", "|%s*([A-Za-z]+)%s*|", "^%s*([A-Za-z]+)%s" }) do
          local prefix = string.match(message, pattern)
          local level = prefix and textLevels[string.upper(prefix)]
          if level ~= nil then record["level"] = level; break end
        end
      end
      return 1, timestamp, record
    end
  '';
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = lib.length victoriaLogsHosts == 3;
        message = "Fluent Bit requires exactly three enabled VictoriaLogs replicas.";
      }
    ];

    jorthaus.persistence.directories = [ dataPath ];

    systemd.tmpfiles.rules = [
      "d ${dataPath} 0750 root root -"
      "d ${dataPath}/cursors 0750 root root -"
      "d ${dataPath}/storage 0750 root root -"
    ];

    services.fluent-bit = {
      enable = true;
      graceLimit = 30;
      settings = {
        service = {
          flush = 1;
          grace = 30;
          log_level = "warn";
          parsers_file = "${pkgs.fluent-bit}/etc/fluent-bit/parsers.conf";
          "storage.path" = "${dataPath}/storage";
          "storage.sync" = "full";
          "storage.checksum" = true;
          "storage.backlog.mem_limit" = "128M";
          "storage.max_chunks_up" = 64;
        };
        parsers = [
          {
            name = "kubernetes-log-path";
            format = "regex";
            regex = "^/var/log/pods/(?<kubernetes_namespace>[^_]+)_(?<kubernetes_pod>[^_]+)_[^/]+/(?<kubernetes_container>[^/]+)/(?<kubernetes_restart_count>[0-9]+)\\.log$";
          }
        ];
        pipeline = {
          inputs = [
            {
              name = "systemd";
              tag = "journal.*";
              db = "${dataPath}/cursors/journal.db";
              "db.sync" = "full";
              read_from_tail = true;
              "mem_buf_limit" = "64M";
              "storage.type" = "filesystem";
            }
            {
              name = "tail";
              tag = "kubernetes.*";
              path = "/var/log/pods/*/*/*.log";
              parser = "cri";
              db = "${dataPath}/cursors/kubernetes.db";
              "db.sync" = "full";
              read_from_head = false;
              refresh_interval = 10;
              rotate_wait = 30;
              path_key = "log_file";
              "mem_buf_limit" = "64M";
              "storage.type" = "filesystem";
            }
          ];
          filters = [
            {
              name = "grep";
              match = "journal.*";
              exclude = "_SYSTEMD_UNIT fluent-bit.service";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "MESSAGE message";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "_SYSTEMD_UNIT journal_unit";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "SYSLOG_IDENTIFIER journal_identifier";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "PRIORITY journal_priority";
            }
            {
              name = "modify";
              match = "journal.*";
              copy = "_TRANSPORT journal_transport";
            }
            {
              name = "record_modifier";
              match = "journal.*";
              record = "host ${host.hostname}";
            }
            {
              name = "record_modifier";
              match = "journal.*";
              record = "source journald";
            }
            {
              name = "parser";
              match = "kubernetes.*";
              key_name = "log_file";
              parser = "kubernetes-log-path";
              reserve_data = true;
              preserve_key = true;
            }
            {
              name = "modify";
              match = "kubernetes.*";
              copy = "log message";
            }
            {
              name = "parser";
              match = "kubernetes.*";
              key_name = "message";
              parser = "json";
              reserve_data = true;
              preserve_key = true;
            }
            {
              name = "record_modifier";
              match = "kubernetes.*";
              record = "host ${host.hostname}";
            }
            {
              name = "record_modifier";
              match = "kubernetes.*";
              record = "source kubernetes";
            }
            {
              name = "lua";
              match = "*";
              script = levelNormalizer;
              call = "normalize_level";
            }
          ];
          outputs = map (peer: {
            name = "http";
            alias = "victorialogs-${peer.hostname}";
            match = "*";
            host = peer.ipam.ipv4.address;
            port = 9428;
            uri = victoriaLogsUri;
            format = "json_lines";
            json_date_key = "date";
            json_date_format = "iso8601";
            compress = "gzip";
            retry_limit = false;
            "storage.total_limit_size" = "10G";
            workers = 1;
          }) victoriaLogsHosts;
        };
      };
    };

    systemd.services.fluent-bit = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ dataPath ];
      preStart = ''
        mkdir -p ${dataPath}/cursors ${dataPath}/storage
        chmod 0750 ${dataPath} ${dataPath}/cursors ${dataPath}/storage
      '';
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "root";
        Group = "root";
        UMask = "0077";
        LimitNOFILE = 65536;
        MemoryHigh = "384M";
        MemoryMax = "512M";
      };
    };
  };
}
