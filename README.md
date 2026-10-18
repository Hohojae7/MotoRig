<!--
  README skeleton. Every "TODO" comment is a note for writing; comments are
  invisible on GitHub. Placeholder images (placehold.co) are replaced with the
  real GIFs and screenshots later.
-->

<div align="center">

<!-- TODO: optional logo above the title -->

# MotoRig

### A physics-based raycast motorcycle chassis for Roblox

<!-- TODO: one bold line that sells it, e.g. what makes riding feel real -->
**Drop one model into your map and ride.**

[![Release](https://img.shields.io/github/v/release/Hohojae7/MotoRig?label=release)](https://github.com/Hohojae7/MotoRig/releases/latest)
[![Creator Store](https://img.shields.io/badge/Creator%20Store-coming%20soon-lightgrey)](#-quick-start)
[![CI](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml/badge.svg)](https://github.com/Hohojae7/MotoRig/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/github/license/Hohojae7/MotoRig)](LICENSE)

**[Download](https://github.com/Hohojae7/MotoRig/releases/latest) · [Creator Store](#-quick-start) · [Demo place](#-quick-start) · [Report a bug](https://github.com/Hohojae7/MotoRig/issues)**

[Features](#-features) · [Quick start](#-quick-start) · [Controls](#-controls) · [Configuration](#-configuration) · [How it works](#-how-it-works) · [FAQ](#-faq)

<!-- TODO: hero.gif (S-curve, chase camera) -->
<img src="https://placehold.co/800x450?text=hero.gif" alt="MotoRig leaning through an S-curve" width="800">

</div>

---

<!-- TODO: 2-3 sentence intro. What MotoRig is, who it is for (map makers),
     and what is different from other Roblox vehicles. -->
_Intro paragraph._

## ✨ Features

<!-- TODO: 4-6 short bullets, the strongest first -->
- **Feature** - one line
- **Feature** - one line
- **Feature** - one line

<!-- GIF grid: two per row -->
<table>
  <tr>
    <td align="center" width="50%">
      <img src="https://placehold.co/400x225?text=mount.gif" alt="Getting on and riding off"><br>
      <sub><b>Hold E to ride</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="https://placehold.co/400x225?text=helmet.gif" alt="Helmet view through a curve"><br>
      <sub><b>Chase and helmet views</b></sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="https://placehold.co/400x225?text=suspension.gif" alt="Suspension soaking up a landing"><br>
      <sub><b>Real suspension and tires</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="https://placehold.co/400x225?text=shifting.gif" alt="Dashboard while shifting up"><br>
      <sub><b>Manual 6-speed gearbox</b></sub>
    </td>
  </tr>
</table>

## 🚀 Quick start

### Option 1: Download from Releases
<!-- TODO: steps. Download MotoRig.rbxm from the latest release, drag it into Studio -->
1. Step
2. Step

### Option 2: Creator Store
<!-- TODO: link once published (issue #4); Toolbox > Inventory steps like A-Chassis -->
_Coming with v1.0.0._

### Option 3: Build from source
<!-- TODO: for developers: aftman install, rojo build / rojo serve -->
```bash
aftman install
rojo build MotoRig.project.json -o MotoRig.rbxm
```

### Placing the bike
<!-- TODO: from src/README.luau SETUP: Workspace, wheels on the ground, copies OK -->
1. Step
2. Step

> [!IMPORTANT]
> Do not scale the model. The physics uses its real dimensions.

<!-- TODO: explorer.png (everything lives inside one model) -->
<img src="https://placehold.co/360x420?text=explorer.png" alt="MotoRig in the Explorer" width="360">

## 🎮 Controls

<!-- TODO: fill from src/README.luau CONTROLS -->
| Action | Keyboard | Gamepad | Touch |
|---|---|---|---|
| Throttle | `W` | `R2` | THROTTLE |
| Brake | `S` | `L2` | BRAKE |
| ... | | | |

### Camera
<!-- TODO: chase / helmet view, look around, look back, zoom -->
_Camera controls._

### Dashboard
<!-- TODO: what the meter shows (rpm, gear, speed, red zone) and the control tiles -->
<img src="https://placehold.co/800x450?text=dashboard.png" alt="Dashboard while riding" width="800">

### Phones and tablets
<!-- TODO: touch layout -->
<img src="https://placehold.co/800x370?text=touch.png" alt="Touch controls" width="800">

## 🔧 Configuration

<!-- TODO: how to open BikeConfig, then the common settings -->
| Setting | Default | Description |
|---|---|---|
| `Sound.Profile` | `"YamahaR1"` | Engine sound |
| `Dashboard.SpeedUnit` | `"km/h"` | `"km/h"`, `"mph"` or `"studs/s"` |
| ... | | |

> [!TIP]
> The physics values work together. Change one at a time and ride after each change.

## 🎨 Custom exterior

<!-- TODO: the Exterior model and its groups (Body, Steering, Fork, FrontWheel,
     RearWheel, Swingarm), the Axle and Pivot attachments. Screenshot after issue #5. -->
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

<!-- TODO: repository layout, tools, CI -->
```text
src/      Luau scripts
parts/    Bike parts
```

## 🧭 Roadmap

<!-- TODO: link the v1.0.0 milestone and open issues -->
- [ ] Item

## 🤝 Contributing

<!-- TODO: issues and pull requests welcome; run selene and stylua before a PR -->
_Text._

## 📄 License

MotoRig is licensed under the [Mozilla Public License 2.0](LICENSE).
