{ config, lib, ... }:

let
  cfg = config.homelab;
  recyclarr = cfg.recyclarr;
in
{
  options.homelab.recyclarr = {
    enable = lib.mkEnableOption "Recyclarr on the media host";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd calendar expression for the Recyclarr sync timer.";
    };

    sonarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing the Sonarr API key for Recyclarr.";
    };

    radarrApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing the Radarr API key for Recyclarr.";
    };

    sonarrBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.sonarr.port}";
      description = "Base URL Recyclarr should use for the local Sonarr instance.";
    };

    radarrBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.radarr.port}";
      description = "Base URL Recyclarr should use for the local Radarr instance.";
    };
  };

  config = lib.mkIf recyclarr.enable {
    assertions = [
      {
        assertion = cfg.sonarr.enable;
        message = "homelab.recyclarr.enable requires homelab.sonarr.enable = true.";
      }
      {
        assertion = cfg.radarr.enable;
        message = "homelab.recyclarr.enable requires homelab.radarr.enable = true.";
      }
      {
        assertion = recyclarr.sonarrApiKeyFile != null;
        message = "homelab.recyclarr.sonarrApiKeyFile must be set when homelab.recyclarr.enable = true.";
      }
      {
        assertion = recyclarr.radarrApiKeyFile != null;
        message = "homelab.recyclarr.radarrApiKeyFile must be set when homelab.recyclarr.enable = true.";
      }
    ];

    services.recyclarr = {
      enable = true;
      schedule = recyclarr.schedule;
      configuration = {
        sonarr = {
          sonarr-4k = {
            base_url = recyclarr.sonarrBaseUrl;
            api_key._secret = toString recyclarr.sonarrApiKeyFile;
            delete_old_custom_formats = true;
            replace_existing_custom_formats = true;

            quality_definition.type = "series";
            quality_profiles = [
              {
                trash_id = "dfa5eaae7894077ad6449169b6eb03e0"; # WEB-2160p (Alternative)
                reset_unmatched_scores.enabled = true;
              }
            ];

            custom_format_groups.add = [
              {
                trash_id = "e3f37512790f00d0e89e54fe5e790d1c"; # [Optional] Golden Rule UHD
                select = [
                  "9b64dff695c2115facf1b6ea59c9bd07" # x265 (no HDR/DV)
                ];
              }
              {
                trash_id = "85fae4a2294965b75710ef2989c850eb"; # [Streaming Services] HD/UHD boost
                select = [
                  "218e93e5702f44a68ad9e3c6ba87d2f0" # HD Streaming Boost
                  "43b3cf48cb385cd3eac608ee6bca7f09" # UHD Streaming Boost
                ];
              }
              {
                trash_id = "59c3af66780d08332fdc64e68297098f"; # [Unwanted] Unwanted Formats
                select = [
                  "15a05bc7c1a36e2b57fd628f8977e2fc" # AV1
                  "32b367365729d530ca1c124a0b180c64" # Bad Dual Groups
                  "85c61753df5da1fb2aab6f2a47426b09" # BR-DISK
                  "6f808933a71bd9666531610cb8c059cc" # BR-DISK (BTN)
                  "fbcb31d8dabd2a319072b84fc0b7249c" # Extras
                  "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
                  "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
                  "82d40da2bc6923f41e14394075dd4b03" # No-RlsGroup
                  "e1a997ddb54e3ecbfe06341ad323c458" # Obfuscated
                  "1b3994c551cbb92a2c781af061f4ab44" # Scene
                  "23297a736ca77c0fc8e70f8edd7ee56c" # Upscaled
                ];
              }
              { trash_id = "d920fd959d220306888f40b6f38e1578"; } # [Optional] Season Packs
              {
                trash_id = "f4a0410a1df109a66d6e47dcadcce014"; # [Optional] Miscellaneous
                select = [
                  "d7c747094a7c65f4c2de083c24899e8b" # FreeLeech
                ];
              }
            ];

            custom_formats = [
              {
                trash_ids = [
                  "418f50b10f1907201b6cfdf881f467b7" # Anime Dual Audio
                ];
                assign_scores_to = [
                  {
                    trash_id = "dfa5eaae7894077ad6449169b6eb03e0"; # WEB-2160p (Alternative)
                    score = 101;
                  }
                ];
              }
              {
                trash_ids = [
                  "9c14d194486c4014d422adc64092d794" # Dubs Only
                ];
                assign_scores_to = [
                  {
                    trash_id = "dfa5eaae7894077ad6449169b6eb03e0"; # WEB-2160p (Alternative)
                    score = 100;
                  }
                ];
              }
            ];

            media_naming = {
              series = "jellyfin-tvdb";
              season = "default";
              episodes = {
                rename = true;
                standard = "default";
                daily = "default";
                anime = "default";
              };
            };
          };
        };

        radarr = {
          radarr-4k = {
            base_url = recyclarr.radarrBaseUrl;
            api_key._secret = toString recyclarr.radarrApiKeyFile;
            delete_old_custom_formats = true;
            replace_existing_custom_formats = true;

            quality_definition.type = "movie";
            quality_profiles = [
              {
                trash_id = "64fb5f9858489bdac2af690e27c8f42f"; # UHD Bluray + WEB
                reset_unmatched_scores.enabled = true;
              }
            ];

            custom_format_groups.add = [
              {
                trash_id = "ff204bbcecdd487d1cefcefdbf0c278d"; # [Optional] Golden Rule UHD
                select = [
                  "839bea857ed2c0a8e084f3cbdbd65ecb" # x265 (no HDR/DV)
                ];
              }
              {
                trash_id = "a3ac6af01d78e4f21fcb75f601ac96df"; # [Unwanted] Unwanted Formats
                select = [
                  "b8cd450cbfa689c0259a01d9e29ba3d6" # 3D
                  "cae4ca30163749b891686f95532519bd" # AV1
                  "b6832f586342ef70d9c128d40c07b872" # Bad Dual Groups
                  "cc444569854e9de0b084ab2b8b1532b2" # Black and White Editions
                  "ed38b889b31be83fda192888e2286d83" # BR-DISK
                  "0a3f082873eb454bde444150b70253cc" # Extras
                  "e6886871085226c3da1830830146846c" # Generated Dynamic HDR
                  "90a6f9a284dff5103f6346090e6280c8" # LQ
                  "e204b80c87be9497a8a6eaff48f72905" # LQ (Release Title)
                  "ae9b7c9ebde1f3bd336a8cbd1ec4c5e5" # No-RlsGroup
                  "7357cf5161efbf8c4d5d0c30b4815ee2" # Obfuscated
                  "f537cf427b64c38c8e36298f657e4828" # Scene
                  "bfd8eb01832d646a0a89c4deb46f8564" # Upscaled
                ];
              }
              {
                trash_id = "f4f1474b963b24cf983455743aa9906c"; # [Optional] Movie Versions
                select = [
                  "eca37840c13c6ef2dd0262b141a5482f" # 4K Remaster
                  "e0c07d59beb37348e975a930d5e50319" # Criterion Collection
                  "0f12c086e289cf966fa5948eac571f44" # Hybrid
                  "eecf3a857724171f968a66cb5719e152" # IMAX
                  "9f6cbff8cfe4ebbc1bde14c7b7bec0de" # IMAX Enhanced
                  "9d27d9d2181838f76dee150882bdc58c" # Masters of Cinema
                  "570bc9ebecd92723d2d21500f4be314c" # Remaster
                  "957d0f44b592285f26449575e8b1167e" # Special Edition
                ];
              }
              {
                trash_id = "9337080378236ce4c0b183e35790d2a7"; # [Optional] Miscellaneous
                select = [
                  "0d91270a7255a1e388fa85e959f359d8" # FreeLeech
                ];
              }
            ];

            media_naming = {
              folder = "jellyfin-tmdb";
              movie = {
                rename = true;
                standard = "jellyfin-tmdb";
              };
            };
          };
        };
      };
    };

    systemd.services.recyclarr = {
      after = [ "sonarr.service" "radarr.service" ];
      wants = [ "sonarr.service" "radarr.service" ];
    };
  };
}
