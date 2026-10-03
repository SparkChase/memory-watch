# Design

The user is working at a Mac in other applications, glancing at the menu bar when a slowdown begins. The native interface follows system light/dark appearance, as confirmed by the user, and uses restrained semantic color.

- One 400 × 680 pt popover, with scrollable content, overview / incidents / settings segmented navigation, persistent Activity Monitor and overflow actions.
- SF system font, native controls and system window background; no decorative motion or external assets.
- Status labels pair words and symbols with color. User-facing secondary text uses primary text at 68% opacity.
- Colors originate in OKLCH: healthy light `0.45 0.12 140`, dark `0.80 0.14 140`; warning light `0.47 0.10 70`, dark `0.82 0.14 80`; critical light `0.49 0.18 25`, dark `0.76 0.14 25`. Convert to sRGB only at the AppKit boundary.
- Mono-spaced digits for changing values. Long process names truncate in the middle and expose the full name and PID on hover.
- Unknown data remains unknown. History starts empty; chart gaps preserve sleep and stopped intervals.
