<div align="center">

# MotoRig

### A physics-based raycast motorcycle chassis for Roblox

**Real tire, suspension and lean physics in one drop-in model.**

[![Release](https://img.shields.io/github/v/release/Hohojae7/MotoRig?label=release)](https://github.com/Hohojae7/MotoRig/releases/latest)
[![CI](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml/badge.svg)](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/github/license/Hohojae7/MotoRig)](LICENSE)

**[Download](https://github.com/Hohojae7/MotoRig/releases/latest) · [Report a bug](https://github.com/Hohojae7/MotoRig/issues)**

[Features](#-features) · [Installation](#-installation) · [Controls](#-controls) · [Configuration](#-configuration)

</div>

---

MotoRig is a motorcycle you can drop into any Roblox map and ride. Its motion comes from a physics model of the tires, suspension, engine and the rider's balance, solved every frame. Everything else it needs, from controls and cameras to the dashboard and engine sound, lives inside the same model.

## ✨ Features

- **Pacejka tires:** Magic Formula grip curves with combined slip, camber thrust and load sensitivity, so the bike slides when it runs out of grip
- **Raycast suspension:** spring-damper fork and swingarm set by ride frequency, with round tire profiles that roll over curbs and bumps
- **Real lean and countersteering:** the lean follows the bicycle roll equation, and the rider countersteers into every turn
- **Engine and 6-speed gearbox:** torque curve, centrifugal clutch, rev limiter, reverse, ABS and traction control
- **Engine sound:** recorded engine loops that follow rpm and throttle, a rev limiter you can hear, and exhaust pops when you lift off at high revs
- **Keyboard and touch:** with chase and helmet cameras and a dashboard
- **Drop-in:** one self-contained model; run several bikes, use StreamingEnabled, or fit your own body shell

<!-- GIF grid: two per row -->
<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/media/hero.gif" alt="Leaning left and right through a curve" width="100%"><br>
      <sub><b>Leaning and countersteering</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/media/shifting.gif" alt="Shifting up through the gears" width="100%"><br>
      <sub><b>Manual 6-speed gearbox</b></sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/media/helmet.gif" alt="Helmet view while leaning" width="100%"><br>
      <sub><b>Chase and helmet views</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/media/suspension.gif" alt="Riding over a speed bump" width="100%"><br>
      <sub><b>Suspension over bumps</b></sub>
    </td>
  </tr>
</table>

## 📦 Installation

<!-- TODO: add the Creator Store steps once issue #4 is done -->
1. Download `MotoRig.rbxm` from the [latest release](https://github.com/Hohojae7/MotoRig/releases/latest).
2. Drag it into Studio and place it in `Workspace` with the wheels on the ground. Copies work too.
3. Press **Play**, walk up to the bike and hold **E** to get on.
4. The ride starts in neutral. Press **RightShift** for 1st gear, then **W** to ride off.

> [!IMPORTANT]
> Do not scale the model. The physics uses its real dimensions.

## 🎮 Controls

| Action | Keyboard | Touch |
|---|---|---|
| Get on | Hold `E` | Hold the prompt |
| Throttle | `W` | THROTTLE |
| Brake (front and rear) | `S` | BRAKE |
| Rear brake | `B` | |
| Lean | `A` / `D` | Drag on the left side |
| Gear up | `LeftShift` | SHIFT UP |
| Gear down | `RightShift` | SHIFT DOWN |
| Neutral | `N` | NEUTRAL |
| Engine on / off | `F` | ENGINE |
| Get off | `Space` | GET OFF |

Gears go 1-N-2-3-4-5-6. To reverse, stop in neutral and hold the brake for a second until `R` shows. In reverse, the throttle stops the bike and then puts it in 1st.

### Camera

| Action | Keyboard and mouse | Touch |
|---|---|---|
| Look around | Drag with the right mouse button | Drag outside the lean area |
| Zoom | Mouse wheel or `I` / `O` | |
| Chase / helmet view | `V` | VIEW |
| Look back (hold) | `C` | BACK |

Zooming all the way in also gives the helmet view.

## 🔧 Configuration

Every setting lives in the `BikeConfig` ModuleScript inside the bike. Open it in Studio, change a value and press Play. Each bike has its own `BikeConfig`, so bikes in the same map can be set up differently.

These are the settings you are most likely to change:

| Setting | Default | What it does |
|---|---|---|
| `Sound.Enabled` | `true` | `false` turns the engine sound off |
| `Sound.Profile` | see `BikeConfig` | Which recorded engine plays, from the list in `Sound.Profiles` |
| `Camera.Enabled` | `true` | `false` leaves the camera to Roblox while riding |
| `Dashboard.Enabled` | `true` | `false` hides the meter and the control tiles |
| `Dashboard.SpeedUnit` | `"km/h"` | `"km/h"`, `"mph"` or `"studs/s"` |
| `Dashboard.RedZoneRPM` | `11000` | Where the meter's red zone starts and the gear turns red |
| `Dashboard.Hints` | `true` | `false` hides the control tiles at the bottom left |
| `Dashboard.TouchControls` | `true` | `false` hides the touch buttons, for maps with their own |
| `Mount.ActionText` | `"Ride"` | The action text on the ride prompt |
| `Mount.ObjectText` | `"MotoRig"` | The name on the ride prompt |
| `Engine.AutoStartOnMount` | `true` | Starts the engine when the rider gets on |
| `Engine.StopOnDismount` | `true` | Stops the engine when the rider gets off |
| `Diagnostics.Enabled` | `false` | `true` prints development info to the Output |

The rest of `BikeConfig` is the physics: mass, suspension, tires, engine and gears. Change one value at a time and ride after each change.

## 📄 License

MotoRig is licensed under the [Mozilla Public License 2.0](LICENSE).
