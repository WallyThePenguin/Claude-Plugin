# Roblox Studio Claude Agent Plugin

An autonomous, multimodal AI development agent built natively for **Roblox Studio**. Powered by Claude with native tool-calling, a real-time vision feedback loop, and a 30+ tool development harness.

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────┐
│                     Roblox Studio                      │
│                                                        │
│   ┌────────────────────────────────────────────────┐   │
│   │              Claude Studio Plugin              │   │
│   │  (Luau Tool Engine, Rig Workbench, Evaluator)   │   │
│   └───────────────▲─────────────────▲──────────────┘   │
└───────────────────┼─────────────────┼──────────────────┘
                    │ HTTP (Tools)    │ HTTP (Captures)
                    ▼                 ▼
   ┌───────────────────────────┐   ┌───────────────────────────┐
   │        Local Proxy        │   │      Vision Sidecar       │
   │       (CLIProxyAPI)       │   │    (Viewport Observer)    │
   │      127.0.0.1:8317       │   │      127.0.0.1:8389       │
   └─────────────▲─────────────┘   └─────────────▲─────────────┘
                 │ Subscription OAuth            │ Local Disk Read
                 ▼                               ▼
      ┌─────────────────────┐       ┌─────────────────────────┐
      │  Anthropic Claude   │       │  Roblox Capture Storage │
      │      (Messages)     │       │ (%LOCALAPPDATA%\Roblox) │
      └─────────────────────┘       └─────────────────────────┘
```

---

## Key Highlights

- **Visual Verification Loop**: Instead of blind generation, the agent takes viewport screenshots via `CaptureService` and reads frames via a lightweight local Python sidecar (`127.0.0.1:8389`), inspecting its own creations and fixing placement or geometry mistakes before returning.
- **Skeleton & Motion Conversion Layer**: Bridges motion-diffusion outputs (such as NVIDIA Kimodo) to Roblox's rig hierarchy (R15/R6), eliminating broken joints and reducing animation errors by ~80% compared to raw direct joint mappings.
- **30+ Native Studio Tools**:
  - **World & Scene**: `Create`, `Place`, `DestroyInstance`, `Properties`, `Tree`, `RegionGuard`.
  - **Animation & Rigs**: `Animate`, `Ik` (Inverse Kinematics), `NativeRig`, `RigWorkbench`, `CameraRig`.
  - **Asset Creation**: Procedural mesh generation, texture persistence, and Gemini/TRELLIS 3D asset pipeline.
  - **Testing & Playtest**: `Playtest`, `PlayBridge`, `HotReload`, `RunLuau`, `HitValidator`.
  - **Agent Infrastructure**: Autonomous subagent delegation, cross-session memory, task tracking lists, and rubric evaluation.
- **Local Subscription Proxy (`CLIProxyAPI`)**: Connects directly to Claude subscription OAuth over loopback, avoiding expensive pay-per-token API metering.

---

## Repository Structure

```
├── src/               # Luau source code for the Roblox Studio Plugin
│   ├── Tools/         # 30+ modular agent tool implementations
│   ├── UI/            # Studio plugin dock widget and interface
│   ├── DevBridge.luau # Hot-reload bridge between editor and engine
│   ├── NativeRig.luau # Rig hierarchy and joint solvers
│   └── Main.luau      # Plugin lifecycle and message loop
├── proxy/             # Local Docker CLIProxyAPI setup for Anthropic OAuth
├── sidecar/           # Fast viewport screenshot bridge (Python standard library / EXE)
├── docs/              # In-depth architectural designs and feature specs
└── rokit.toml         # Rokit toolchain configuration (Aftman / Rojo / Selene / Stylua)
```

---

## Setup & Getting Started

### 1. Prerequisites
- [Roblox Studio](https://create.roblox.com/)
- [Docker Desktop](https://www.docker.com/) (for CLIProxyAPI)
- [Rokit](https://github.com/rojo-rbx/rokit) or [Rojo](https://rojo.space/) (for building the plugin `.rbxm`)
- Python 3.10+ (optional, pre-built sidecar `.exe` included)

---

### 2. Configure the Model Proxy
The plugin communicates with Claude through a loopback proxy authenticated with your Claude account:

```powershell
cd proxy

# 1. Generate inbound auth key and configuration
.\gen-key.ps1

# 2. Log in with your Claude account (opens browser OAuth verification)
.\login.ps1

# 3. Start the proxy container
docker compose up -d

# 4. Verify end-to-end communication
.\verify.ps1
```

---

### 3. Start the Vision Sidecar
The sidecar serves viewport screenshots captured by Studio to the plugin:

- **Option A (Pre-built binary)**: Double-click `sidecar/dist/StudioAgentSidecar.exe`.
- **Option B (From source)**:
  ```powershell
  cd sidecar
  .\run.ps1
  ```
The sidecar will begin listening on `http://127.0.0.1:8389`.

---

### 4. Build and Install the Plugin into Roblox Studio
Using Rojo and Rokit:

```powershell
# Install project tools
rokit install

# Build the plugin binary
rojo build -o "StudioAgent.rbxm"
```

Move `StudioAgent.rbxm` into your Roblox Studio plugins directory:
- `%LOCALAPPDATA%\Roblox\Plugins\`

Open Roblox Studio. The **Studio Agent** ribbon button and dock widget will appear. Paste the inbound proxy key generated from Step 2 into the settings tab, and the agent is ready to build!

---

## License
MIT
