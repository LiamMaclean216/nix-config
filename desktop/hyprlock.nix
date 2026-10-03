{
  config,
  pkgs,
  ...
}: let
  theme = import ./theme.nix;
  hyprlockSolar = pkgs.writeShellApplication {
    name = "hyprlock-solar";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.gnused
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}"
      cache_dir="$cache_root/hyprlock"
      cache_file="$cache_dir/solar-times.json"

      default_timezone="''${HYPRLOCK_SOLAR_DEFAULT_TZ:-America/Toronto}"
      default_city="''${HYPRLOCK_SOLAR_DEFAULT_CITY:-Toronto}"
      default_lat="''${HYPRLOCK_SOLAR_DEFAULT_LAT:-43.6532}"
      default_lon="''${HYPRLOCK_SOLAR_DEFAULT_LON:--79.3832}"

      detect_timezone() {
        if [ -n "''${TZ:-}" ]; then
          printf '%s\n' "$TZ"
          return 0
        fi

        local timezone
        timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
        if [ -n "$timezone" ] && [ "$timezone" != "n/a" ]; then
          printf '%s\n' "$timezone"
          return 0
        fi

        if [ -L /etc/localtime ]; then
          readlink /etc/localtime | sed 's#^.*/zoneinfo/##'
          return 0
        fi

        return 1
      }

      city_from_timezone() {
        printf '%s\n' "$1" | sed 's#^.*/##; s#_# #g'
      }

      format_time() {
        date -d "$1" '+%I:%M %p' | sed 's/^0//'
      }

      refresh() {
        local timezone city geo_json resolved_geo latitude longitude location response tmp_file status sunrise solar_noon sunset

        mkdir -p "$cache_dir"

        timezone="$(detect_timezone || true)"
        [ -n "$timezone" ] || timezone="$default_timezone"

        city="$(city_from_timezone "$timezone")"
        [ -n "$city" ] || city="$default_city"

        geo_json="$(curl --silent --show-error --fail --get \
          --data-urlencode "name=$city" \
          --data-urlencode "count=5" \
          --data-urlencode "language=en" \
          --data-urlencode "format=json" \
          "https://geocoding-api.open-meteo.com/v1/search" || true)"

        resolved_geo="$(printf '%s' "$geo_json" | jq -c --arg timezone "$timezone" '
          (.results // []) as $results
          | (($results | map(select(.timezone == $timezone))) + $results)[0] // {}
        ' 2>/dev/null || printf '{}')"

        latitude="$(printf '%s' "$resolved_geo" | jq -r '.latitude // empty' 2>/dev/null || true)"
        longitude="$(printf '%s' "$resolved_geo" | jq -r '.longitude // empty' 2>/dev/null || true)"

        if [ -z "$latitude" ] || [ -z "$longitude" ]; then
          timezone="$default_timezone"
          location="$default_city"
          latitude="$default_lat"
          longitude="$default_lon"
        else
          timezone="$(printf '%s' "$resolved_geo" | jq -r --arg fallback "$timezone" '.timezone // $fallback' 2>/dev/null || printf '%s' "$timezone")"
          location="$(printf '%s' "$resolved_geo" | jq -r '[.name, .admin1] | map(select(. != null and . != "")) | join(", ")' 2>/dev/null || true)"
          [ -n "$location" ] || location="$city"
        fi

        response="$(curl --silent --show-error --fail --get \
          --data-urlencode "lat=$latitude" \
          --data-urlencode "lng=$longitude" \
          --data-urlencode "formatted=0" \
          --data-urlencode "tzid=$timezone" \
          "https://api.sunrise-sunset.org/json")"

        status="$(printf '%s' "$response" | jq -r '.status // empty')"
        sunrise="$(printf '%s' "$response" | jq -r '.results.sunrise // empty')"
        solar_noon="$(printf '%s' "$response" | jq -r '.results.solar_noon // empty')"
        sunset="$(printf '%s' "$response" | jq -r '.results.sunset // empty')"

        if [ "$status" != "OK" ] || [ -z "$sunrise" ] || [ -z "$solar_noon" ] || [ -z "$sunset" ]; then
          return 1
        fi

        tmp_file="$(mktemp "$cache_dir/.solar-times.XXXXXX")"
        jq -n \
          --arg location "$location" \
          --arg timezone "$timezone" \
          --arg sunrise "$sunrise" \
          --arg solar_noon "$solar_noon" \
          --arg sunset "$sunset" \
          '{
            location: $location,
            timezone: $timezone,
            sunrise: $sunrise,
            solar_noon: $solar_noon,
            sunset: $sunset,
            updated_at: (now | todateiso8601)
          }' > "$tmp_file"

        mv "$tmp_file" "$cache_file"
      }

      ensure_cache() {
        if [ ! -s "$cache_file" ]; then
          refresh >/dev/null 2>&1 || true
          return 0
        fi

        if [ $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -ge 21600 ]; then
          refresh >/dev/null 2>&1 || true
        fi
      }

      print_value() {
        local field value

        field="$1"
        ensure_cache

        if [ ! -s "$cache_file" ]; then
          if [ "$field" = "location" ]; then
            printf '%s\n' "$default_city - $default_timezone"
          else
            printf '%s\n' '--:--'
          fi
          return 0
        fi

        case "$field" in
          sunrise|solar_noon|sunset)
            value="$(jq -r --arg field "$field" '.[$field] // empty' "$cache_file")"
            if [ -n "$value" ]; then
              format_time "$value"
            else
              printf '%s\n' '--:--'
            fi
            ;;
          location)
            value="$(jq -r '[.location, .timezone] | map(select(. != null and . != "")) | join(" - ")' "$cache_file")"
            if [ -n "$value" ]; then
              printf '%s\n' "$value"
            else
              printf '%s\n' "$default_city - $default_timezone"
            fi
            ;;
          *)
            printf '%s\n' '--:--'
            ;;
        esac
      }

      case "''${1:-}" in
        refresh)
          refresh
          ;;
        sunrise)
          print_value sunrise
          ;;
        noon|solar-noon|solar_noon)
          print_value solar_noon
          ;;
        sunset)
          print_value sunset
          ;;
        location)
          print_value location
          ;;
        *)
          printf '%s\n' 'usage: hyprlock-solar {refresh|sunrise|noon|sunset|location}' >&2
          exit 1
          ;;
      esac
    '';
  };

  hyprlockWindows = pkgs.writeShellApplication {
    name = "hyprlock-windows-reboot";
    runtimeInputs = [pkgs.systemd];
    text = ''
      exec systemctl reboot --boot-loader-entry=auto-windows
    '';
  };

  hyprlockConfig = builtins.replaceStrings
    (["@HYPRLOCK_SOLAR@" "@HYPRLOCK_WINDOWS@" "@HYPRLOCK_WINDOWS_ICON@" "@WALLPAPER@" "@radius@" "@font@" "@controlRadius@" "@fadeSpeed@"]
      ++ map (name: "@${name}@") (builtins.attrNames theme.colors))
    ([
      "${hyprlockSolar}/bin/hyprlock-solar"
      "${hyprlockWindows}/bin/hyprlock-windows-reboot"
      "${./wlogout/windows.png}"
      "${./background.webp}"
      (toString theme.radius)
      theme.font
      (toString theme.qt.controlRadius)
      (toString theme.fadeSpeed)
    ] ++ builtins.attrValues theme.colors)
    (builtins.readFile ./hyprlock.conf);
in {
  programs.hyprlock.enable = true;

  home.packages = [hyprlockSolar hyprlockWindows];

  home.file.".config/hypr/hyprlock.conf".text = hyprlockConfig;

  systemd.user.services.hyprlock-solar-times = {
    Unit = {
      Description = "Refresh hyprlock solar times";
      After = ["network-online.target"];
      Wants = ["network-online.target"];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${hyprlockSolar}/bin/hyprlock-solar refresh";
    };

    Install.WantedBy = ["default.target"];
  };

  systemd.user.timers.hyprlock-solar-times = {
    Unit.Description = "Refresh hyprlock solar times every six hours";

    Timer = {
      OnBootSec = "2m";
      OnUnitActiveSec = "6h";
      Persistent = true;
      Unit = "hyprlock-solar-times.service";
    };

    Install.WantedBy = ["timers.target"];
  };
}
