# Moodpaper

**Your photos, your Vibes.**

Moodpaper is a free, open-source macOS menu bar app that changes your desktop wallpaper throughout the day using your own photos. Assign images to parts of the day, group those assignments into named Vibes, and switch your desktop's personality in one click.

Moodpaper is a direct download, not a Mac App Store product. It has no account, paywall, subscription, Premium tier, or in-app purchase. An optional Buy Me a Coffee link supports development without unlocking features.

Moodpaper ships no wallpaper library. It does include a nine-image starter set, one photograph per time slot, so a brand new install has something on screen before you import anything. Those nine become your first Vibe during the welcome, and you can rename or delete that Vibe like any other.

## Features

- **Your photos:** Import individual images, drag in files, or load an entire folder into a Vibe. Moodpaper copies supported images into its sandboxed Application Support folder.
- **Nine time slots:** Deep Night, Dawn, Sunrise, Morning, Midday, Afternoon, Golden Hour, Dusk, and Evening.
- **Throughout the day:** Give each Vibe a shared set of photos that can play at any hour, then assign favorites to a time of day when you want them.
- **Named Vibes:** Name your first Vibe during the welcome, then create, rename, duplicate, delete, activate, and customize complete wallpaper collections. New Vibes flow directly into wallpaper import. Each Vibe has its own How Often setting.
- **A welcome that sets your desktop:** Scrub a dial across the day to watch the light change, name what you see, and your real desktop changes once before the window closes. Replay it anytime from Settings.
- **Automatic scheduling:** Move through the day using configurable time slots and local sunrise and sunset timing.
- **Safe empty slots:** A time of day uses its own images when available, falls back to photos that play throughout the day, and holds the current wallpaper only when both are empty.
- **Resilient weather display:** Refresh local weather at launch, after wake and app activation, and on demand without letting weather choose your wallpaper. Moodpaper keeps a recent successful reading visible during temporary provider failures and retries automatically.
- **Focus Mode:** Optionally use calendar access to apply your Focus wallpapers during meetings.
- **Multiple displays and Spaces:** Keep wallpaper behavior consistent across connected displays and macOS Spaces.
- **Local history and controls:** Review recent changes, pause rotation, and use keyboard shortcuts. Skip shows a transition state and updates the cards only after macOS confirms the connected displays.

## Privacy

Your photos, Vibes, preferences, history, and diagnostics stay on your Mac. Moodpaper has no account system, backend, advertising SDK, or transmitted analytics. When Device Location is enabled and authorized, location coordinates are sent to Apple WeatherKit or, if WeatherKit fails, Open-Meteo to retrieve local weather. Location and calendar access are optional and controlled through macOS privacy settings.

## Requirements

- macOS 14 Sonoma or later
- Location permission for local sunrise, sunset, and weather information
- Calendar permission only when Focus Mode is enabled

## Install

1. Download the latest notarized DMG from the [GitHub Releases page](https://github.com/FuturisticXx/Moodpaper/releases/latest).
2. Open the disk image and drag Moodpaper into Applications.
3. Open Moodpaper. The signed and notarized release should pass Gatekeeper without a security bypass.

Each release publishes a SHA-256 checksum next to the DMG. Verify with `shasum -a 256 -c Moodpaper-<version>.dmg.sha256`. The previous public release is [v1.0.0](https://github.com/FuturisticXx/Moodpaper/releases/tag/v1.0.0).

## Development

### Prerequisites

- macOS 14 or later
- Xcode 15 or later
- An Apple Developer team for capabilities and local signing

### Build and test

1. Open `Moodpaper.xcodeproj` in Xcode.
2. Select your development team in Signing & Capabilities.
3. Build and run the `Moodpaper` scheme.

The command-line test suite is:

```sh
xcodebuild \
  -project Moodpaper.xcodeproj \
  -scheme Moodpaper \
  -configuration Debug \
  test
```

The first build under a new developer team may require `-allowProvisioningUpdates` so Xcode can configure the app's capabilities.

### Maintainer release process

`scripts/release_build.sh` runs tests, archives and exports the app with Developer ID signing, creates the DMG, submits it for notarization, staples the ticket, and checks Gatekeeper. It requires the maintainer's Developer ID certificate and a local `notarytool` keychain profile named `Moodpaper`.

Never publish or replace a release without the maintainer's explicit approval.

## Project structure

```text
MoodPaper/
├── .gitignore
├── LICENSE                      # MIT License
├── README.md
├── Moodpaper/                    # SwiftUI and AppKit application source
├── MoodpaperTests/               # Unit and release-readiness tests
├── Moodpaper.xcodeproj/          # Xcode project and shared scheme
└── scripts/
    ├── exportOptions.plist        # Developer ID export configuration
    └── release_build.sh           # Developer ID and notarization pipeline
```

## Contributing

Issues and focused pull requests are welcome. Keep changes small, preserve the native macOS experience, and include tests or verification evidence for behavior changes.

## Support

Moodpaper is free. If it is useful to you, you can optionally [buy the developer a coffee](https://buymeacoffee.com/2damaxdevelopement).

## License

Moodpaper is available under the [MIT License](LICENSE).
