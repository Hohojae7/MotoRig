<!--
  README draft. Every "TODO" comment is a note for writing; comments are
  invisible on GitHub.
-->

<div align="center">

<!-- TODO: optional logo above the title -->

# MotoRig

### A physics-based raycast motorcycle chassis for Roblox

**Real tire, suspension and lean physics in one drop-in model.**

[![Release](https://img.shields.io/github/v/release/Hohojae7/MotoRig?label=release)](https://github.com/Hohojae7/MotoRig/releases/latest)
[![Creator Store](https://img.shields.io/badge/Creator%20Store-coming%20soon-lightgrey)](#-installation)
[![CI](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml/badge.svg)](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/github/license/Hohojae7/MotoRig)](LICENSE)

**[Download](https://github.com/Hohojae7/MotoRig/releases/latest) · [Creator Store](#-installation) · [Demo place](#-installation) · [Report a bug](https://github.com/Hohojae7/MotoRig/issues)**

[Features](#-features) · [Installation](#-installation) · [Controls](#-controls) · [Configuration](#-configuration) · [How it works](#-how-it-works) · [FAQ](#-faq)

</div>

---

MotoRig is a motorcycle you can drop into any Roblox map and ride. Its motion comes from a physics model of the tires, suspension, engine and the rider's balance, solved every frame. Everything else it needs, from controls and cameras to the dashboard and engine sound, lives inside the same model.

## ✨ Features

- **Pacejka tires:** Magic Formula grip curves with combined slip, camber thrust and load sensitivity, so the bike slides when it runs out of grip
- **Raycast suspension:** spring-damper fork and swingarm set by ride frequency, with round tire profiles that roll over curbs and bumps
- **Real lean and countersteering:** the lean follows the bicycle roll equation, and the rider countersteers into every turn
- **Engine and 6-speed gearbox:** torque curve, centrifugal clutch, rev limiter, reverse, ABS and traction control
- **Keyboard and touch:** with chase and helmet cameras and a dashboard
- **Drop-in:** one self-contained model; run several bikes, use StreamingEnabled, or fit your own body shell

<!-- GIF grid: two per row. TODO: final captions -->
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

### Dashboard

The meter at the bottom right shows rpm, gear and speed. The gear reads green in neutral, amber in reverse and red in the red zone (from 11,000 rpm), the cue to shift up. ABS and traction control have their own lights.

The tiles at the bottom left show the controls. The one the bike needs next lights up in blue: start the engine, leave neutral or shift up.

### Phones and tablets

Touch controls replace the tiles on phones and tablets. Your left thumb leans by dragging left or right and shifts with the buttons above; your right thumb holds the throttle or the brake. Engine, neutral, view, look back and get off sit along the top, and the meter moves to the top right.

## 🔧 Configuration

<!-- TODO: how to open BikeConfig, then the game settings only: sound,
     camera, dashboard, speed unit, hints, touch controls, ride prompt text,
     engine start and stop. Physics values go to "Tuning the physics". -->
| Setting | Default | Description |
|---|---|---|
| `Sound.Profile` | `"YamahaR1"` | Engine sound |
| `Dashboard.SpeedUnit` | `"km/h"` | `"km/h"`, `"mph"` or `"studs/s"` |
| ... | | |

## 🎨 Custom exterior

<!-- TODO: one sentence: MotoRig ships as a bare frame; a body shell is a Model
     named Exterior inside the bike and does not change the physics.
     Say whether the shells below are included or only examples. -->
<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/media/exterior-1.png" alt="MotoRig with a sport-bike shell" width="100%">
    </td>
    <td align="center" width="50%">
      <img src="docs/media/exterior-2.png" alt="MotoRig with another sport-bike shell" width="100%">
    </td>
  </tr>
</table>
<p align="center"><sub><b>Same chassis, two different shells</b></sub></p>

<!-- TODO: the groups inside Exterior and the Axle and Pivot attachments -->
| Group | Moves with |
|---|---|
| `Body` | the frame |
| ... | |

## 🔬 How it works

<!-- TODO: one paragraph overview: one rigid chassis, raycast wheels, what is
     solved every physics frame. Keep each subsection short: one sentence,
     one equation, one sentence on what it means in game. -->

### Tire contact
<!-- TODO: torus tire swept by spherecasts -->
_Text._

### Suspension
<!-- TODO: spring-damper from ride frequency and damping ratio -->
```math
F_n = \frac{F_\text{spring}}{\hat{a} \cdot \hat{n}}
```

### Tires
<!-- TODO: Pacejka Magic Formula, combined slip, camber thrust, relaxation length -->
```math
F(x) = D \sin\!\Big(C \arctan\big(Bx - E\,(Bx - \arctan Bx)\big)\Big)
```

### Lean and countersteering
<!-- TODO: bicycle roll equation, steady-turn relation -->
```math
I\,\ddot{\varphi} = m g h \sin\varphi - m h\,a_\text{lat}\cos\varphi + M_\text{gyro}
```
```math
\frac{\tan\delta}{\tan\varphi} = \frac{L\,g}{v^2}
```

### Air drag
```math
F_d = \tfrac{1}{2}\,\rho\,C_d\,A\,v^2
```

### Engine, clutch and brakes
<!-- TODO: torque curve, centrifugal clutch, rev limiter, ABS -->
_Text._

### Tuning the physics
<!-- TODO: the physics groups in BikeConfig (mass, suspension, tires, engine,
     gears), what each one changes in the ride -->
| Group | What it changes |
|---|---|
| ... | |

> [!TIP]
> The physics values work together. Change one at a time and ride after each change.

## 🌍 Using it in your map

<!-- TODO: from src/README.luau IN A MAP: several bikes, StreamingEnabled,
     gravity and wind, parking brake, Shift Lock -->
- Point
- Point

## 🚧 Known limitations

<!-- TODO: falling over is not modeled, steps higher than the axle act like a
     wall, the body shell does not collide -->
- Limitation
- Limitation

## ❓ FAQ

<details>
<summary><b>Question?</b></summary>

<!-- TODO: answer -->
Answer.

</details>

<details>
<summary><b>Something does not work. Where do I look?</b></summary>

<!-- TODO: from src/README.luau TROUBLESHOOTING: Output warnings and the
     BikeServerStatus / BikeControllerStatus attributes -->
Answer.

</details>

## 💻 Development

### Building from source
<!-- TODO: Aftman installs the pinned tools; rojo build makes the model,
     rojo serve syncs into Studio -->
```bash
aftman install
rojo build MotoRig.project.json -o MotoRig.rbxm
```

### Repository layout
<!-- TODO: what each folder and project file is -->
```text
src/      Luau scripts
parts/    Bike parts
```

### Checks
<!-- TODO: selene, stylua and what CI checks on every pull request -->
_Text._

## 🧭 Roadmap

<!-- TODO: link the v1.0.0 milestone and open issues -->
- [ ] Item

## 🤝 Contributing

<!-- TODO: issues and pull requests welcome; run selene and stylua before a PR -->
_Text._

## 📄 License

MotoRig is licensed under the [Mozilla Public License 2.0](LICENSE).
