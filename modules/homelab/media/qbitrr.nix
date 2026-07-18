{ config, lib, pkgs, ... }:

let
  cfg = config.homelab;
  qbitrr = cfg.qbitrr;

  package = pkgs.python3Packages.buildPythonApplication rec {
    pname = "qbitrr";
    version = "5.12.7";
    format = "setuptools";

    src = pkgs.fetchFromGitHub {
      owner = "Feramance";
      repo = "qBitrr";
      rev = "v${version}";
      hash = "sha256-190A/8aLGRcCHnAZDe+qFmUk58IkTv7qxP6mmKJEbDw=";
    };

    nativeBuildInputs = [ pkgs.python3Packages.setuptools ];

    postPatch = ''
      substituteInPlace qBitrr/home_path.py \
        --replace-fail "from jaraco.docker import is_docker" "" \
        --replace-fail "if is_docker():" "if pathlib.Path('/.dockerenv').exists():"
    '';

    propagatedBuildInputs = with pkgs.python3Packages; [
      authlib
      bcrypt
      cachetools
      certifi
      colorama
      coloredlogs
      croniter
      environ-config
      ffmpeg-python
      flask
      packaging
      pathos
      peewee
      ping3
      pyarr
      qbittorrent-api
      requests
      tomlkit
      ujson
      waitress
      werkzeug
    ];

    doCheck = false;

    meta = {
      description = "Automated qBittorrent and Arr management";
      homepage = "https://github.com/Feramance/qBitrr";
      license = lib.licenses.mit;
      mainProgram = "qbitrr";
      platforms = lib.platforms.linux;
    };
  };

  renderedToml = pkgs.writeText "qbitrr-config-template.toml" ''
    [Settings]
    ConfigVersion = "5.8.8"
    ConsoleLevel = "INFO"
    Logging = true
    CompletedDownloadFolder = "${cfg.qbittorrent.downloadDir}/complete"
    FreeSpace = "-1"
    FreeSpaceFolder = "${cfg.qbittorrent.downloadDir}"
    AutoPauseResume = true
    NoInternetSleepTimer = 15
    LoopSleepTimer = ${toString qbitrr.loopSleepTimerSeconds}
    SearchLoopDelay = -1
    FailedCategory = "failed"
    RecheckCategory = "recheck"
    Tagless = false
    IgnoreTorrentsYoungerThan = 180
    PingURLS = ["one.one.one.one", "dns.google.com"]
    FFprobeAutoUpdate = false
    AutoUpdateEnabled = false
    AutoRestartProcesses = true
    MaxProcessRestarts = 5
    ProcessRestartWindow = 300
    ProcessRestartDelay = 5

    [WebUI]
    Host = "127.0.0.1"
    Port = ${toString qbitrr.webUiPort}
    Token = ""
    AuthDisabled = true
    BehindHttpsProxy = false
    UrlBase = ""
    LocalAuthEnabled = false
    OIDCEnabled = false
    Username = ""
    PasswordHash = ""
    RequireHttpsMetadata = true
    LiveArr = true
    GroupSonarr = true
    GroupLidarr = true
    Theme = "Dark"
    ViewDensity = "Comfortable"

    [qBit]
    Disabled = false
    Host = "127.0.0.1"
    Port = ${toString cfg.qbittorrent.webuiPort}
    UserName = "${qbitrr.qbittorrentUsername}"
    SkipTLSVerify = false
    ManagedCategories = []
    MatchSubcategories = false
    Trackers = []

    [qBit.CategorySeeding]
    DownloadRateLimitPerTorrent = -1
    UploadRateLimitPerTorrent = -1
    MaxUploadRatio = -1
    MaxSeedingTime = -1
    RemoveTorrent = -1
    HitAndRunMode = "disabled"
    MinSeedRatio = 1.0
    MinSeedingTimeDays = 0
    HitAndRunMinimumDownloadPercent = 10
    HitAndRunPartialSeedRatio = 1.0
    TrackerUpdateBuffer = 0
    StalledDelay = -1
    IgnoreTorrentsYoungerThan = 180

    [Sonarr]
    Managed = ${lib.boolToString cfg.sonarr.enable}
    URI = "${qbitrr.sonarrBaseUrl}"
    APIKey = "__SONARR_API_KEY__"
    SkipTLSVerify = false
    Category = "${qbitrr.sonarrCategory}"
    ReSearch = true
    importMode = "Auto"
    RssSyncTimer = 0
    RefreshDownloadsTimer = 5
    ArrErrorCodesToBlocklist = []

    [Sonarr.EntrySearch]
    SearchMissing = false
    AlsoSearchSpecials = false
    Unmonitored = false
    SearchLimit = 5
    SearchByYear = true
    SearchInReverse = false
    SearchRequestsEvery = 300
    DoUpgradeSearch = false
    QualityUnmetSearch = false
    CustomFormatUnmetSearch = false
    ForceMinimumCustomFormat = false
    SearchAgainOnSearchCompletion = false
    UseTempForMissing = false
    KeepTempProfile = false
    QualityProfileMappings = {}
    ForceResetTempProfiles = false
    TempProfileResetTimeoutMinutes = 0
    ProfileSwitchRetryAttempts = 3
    SearchBySeries = "smart"
    PrioritizeTodaysReleases = false

    [Sonarr.Torrent]
    CaseSensitiveMatches = false
    FolderExclusionRegex = ["\\bextras?\\b", "\\bfeaturettes?\\b", "\\bsamples?\\b", "\\bscreens?\\b"]
    FileNameExclusionRegex = ["\\bsample\\b", "\\btrailer\\b"]
    FileExtensionAllowlist = [".mp4", ".mkv", ".sub", ".ass", ".srt", ".!qB", ".parts"]
    AutoDelete = true
    IgnoreTorrentsYoungerThan = 180
    MaximumETA = -1
    MaximumDeletablePercentage = 0.99
    DoNotRemoveSlow = true
    StalledDelay = ${toString qbitrr.stalledDelayMinutes}
    ReSearchStalled = true
    Trackers = []

    [Sonarr.Torrent.SeedingMode]
    DownloadRateLimitPerTorrent = -1
    UploadRateLimitPerTorrent = -1
    MaxUploadRatio = -1
    MaxSeedingTime = -1
    RemoveTorrent = -1

    [Radarr]
    Managed = ${lib.boolToString cfg.radarr.enable}
    URI = "${qbitrr.radarrBaseUrl}"
    APIKey = "__RADARR_API_KEY__"
    SkipTLSVerify = false
    Category = "${qbitrr.radarrCategory}"
    ReSearch = true
    importMode = "Auto"
    RssSyncTimer = 0
    RefreshDownloadsTimer = 5
    ArrErrorCodesToBlocklist = []

    [Radarr.EntrySearch]
    SearchMissing = false
    SearchLimit = 5
    SearchByYear = true
    SearchInReverse = false
    SearchRequestsEvery = 300
    DoUpgradeSearch = false
    QualityUnmetSearch = false
    CustomFormatUnmetSearch = false
    ForceMinimumCustomFormat = false
    SearchAgainOnSearchCompletion = false
    UseTempForMissing = false
    KeepTempProfile = false
    QualityProfileMappings = {}
    ForceResetTempProfiles = false
    TempProfileResetTimeoutMinutes = 0
    ProfileSwitchRetryAttempts = 3

    [Radarr.Torrent]
    CaseSensitiveMatches = false
    FolderExclusionRegex = ["\\bextras?\\b", "\\bfeaturettes?\\b", "\\bsamples?\\b", "\\bscreens?\\b"]
    FileNameExclusionRegex = ["\\bsample\\b", "\\btrailer\\b"]
    FileExtensionAllowlist = [".mp4", ".mkv", ".sub", ".ass", ".srt", ".!qB", ".parts"]
    AutoDelete = true
    IgnoreTorrentsYoungerThan = 180
    MaximumETA = -1
    MaximumDeletablePercentage = 0.99
    DoNotRemoveSlow = true
    StalledDelay = ${toString qbitrr.stalledDelayMinutes}
    ReSearchStalled = true
    Trackers = []

    [Radarr.Torrent.SeedingMode]
    DownloadRateLimitPerTorrent = -1
    UploadRateLimitPerTorrent = -1
    MaxUploadRatio = -1
    MaxSeedingTime = -1
    RemoveTorrent = -1
  '';
in
{
  options.homelab.qbitrr = {
    enable = lib.mkEnableOption "qBitrr on the media host";

    loopSleepTimerSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Delay between qBitrr processing loops, in seconds.";
    };

    stalledDelayMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 720;
      description = "How long Arr-category torrents may stay stalled before qBitrr removes and re-searches them.";
    };

    webUiPort = lib.mkOption {
      type = lib.types.port;
      default = 6969;
      description = "Local-only qBitrr Web UI port.";
    };

    sonarrBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.sonarr.port}";
      description = "Base URL for the local Sonarr instance.";
    };

    radarrBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.radarr.port}";
      description = "Base URL for the local Radarr instance.";
    };

    sonarrCategory = lib.mkOption {
      type = lib.types.str;
      default = "sonarr";
      description = "qBittorrent category name managed for Sonarr downloads.";
    };

    radarrCategory = lib.mkOption {
      type = lib.types.str;
      default = "radarr";
      description = "qBittorrent category name managed for Radarr downloads.";
    };

    sonarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = cfg.recyclarr.sonarrApiKeyFile;
      description = "Path to a file containing the Sonarr API key qBitrr should use.";
    };

    radarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = cfg.recyclarr.radarrApiKeyFile;
      description = "Path to a file containing the Radarr API key qBitrr should use.";
    };

    qbittorrentUsername = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Username qBitrr should use when talking to qBittorrent.";
    };

    qbittorrentPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional file containing the qBittorrent password; leave null when localhost auth bypass is enabled.";
    };
  };

  config = lib.mkIf qbitrr.enable {
    assertions = [
      {
        assertion = cfg.qbittorrent.enable;
        message = "homelab.qbitrr.enable requires homelab.qbittorrent.enable = true.";
      }
      {
        assertion = cfg.sonarr.enable;
        message = "homelab.qbitrr.enable requires homelab.sonarr.enable = true.";
      }
      {
        assertion = cfg.radarr.enable;
        message = "homelab.qbitrr.enable requires homelab.radarr.enable = true.";
      }
      {
        assertion = qbitrr.sonarrApiKeyFile != null;
        message = "homelab.qbitrr.sonarrApiKeyFile must be set when homelab.qbitrr.enable = true.";
      }
      {
        assertion = qbitrr.radarrApiKeyFile != null;
        message = "homelab.qbitrr.radarrApiKeyFile must be set when homelab.qbitrr.enable = true.";
      }
    ];

    systemd.services.qbitrr = {
      description = "qBitrr torrent manager";
      after = [
        "network-online.target"
        "qbittorrent.service"
        "sonarr.service"
        "radarr.service"
      ] ++ lib.optionals cfg.piaVpn.enable [ "pia-vpn.service" ];
      wants = [ "network-online.target" ];
      requires = [
        "qbittorrent.service"
        "sonarr.service"
        "radarr.service"
      ] ++ lib.optionals cfg.piaVpn.enable [ "pia-vpn.service" ];
      wantedBy = [ "multi-user.target" ];
      preStart = ''
        install -d -m 0750 -o qbittorrent -g media /var/lib/qbitrr
        install -d -m 0750 -o qbittorrent -g media /var/lib/qbitrr/.config
        install -d -m 0750 -o qbittorrent -g media /var/lib/qbitrr/.config/qBitManager
        cp ${renderedToml} /var/lib/qbitrr/.config/config.toml
        ${pkgs.python3}/bin/python - <<'PY'
from pathlib import Path
path = Path('/var/lib/qbitrr/.config/config.toml')
text = path.read_text()
text = text.replace('__SONARR_API_KEY__', Path('${qbitrr.sonarrApiKeyFile}').read_text().strip())
text = text.replace('__RADARR_API_KEY__', Path('${qbitrr.radarrApiKeyFile}').read_text().strip())
${lib.optionalString (qbitrr.qbittorrentPasswordFile != null) ''
text = text.replace('UserName = "${qbitrr.qbittorrentUsername}"\n', 'UserName = "${qbitrr.qbittorrentUsername}"\nPassword = "' + Path('${qbitrr.qbittorrentPasswordFile}').read_text().strip() + '"\n', 1)
''}
path.write_text(text)
PY
        chown -R qbittorrent:media /var/lib/qbitrr
        chmod 0640 /var/lib/qbitrr/.config/config.toml
      '';
      serviceConfig = {
        PermissionsStartOnly = true;
        User = "qbittorrent";
        Group = "media";
        WorkingDirectory = "/var/lib/qbitrr";
        StateDirectory = "qbitrr";
        Environment = [
          "HOME=/var/lib/qbitrr"
          "XDG_CONFIG_HOME=/var/lib/qbitrr/.config"
        ];
        ExecStart = lib.getExe package;
        Restart = "always";
        RestartSec = 15;
      };
    };
  };
}
