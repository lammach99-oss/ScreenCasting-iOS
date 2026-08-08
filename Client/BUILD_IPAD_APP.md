# iPadCasting - Xcode Build & Physical iPad Deployment Guide

This guide walks you through compiling and sideloading the **iPadCasting** Swift/Metal client application onto your physical iPad using Xcode on macOS.

## R3 public CI artifact and local Windows signing

The public workflow can be dispatched with `build_unsigned_ipa=true` to build
and validate an unsigned physical-iPad IPA. Download the
`ScreenCasting-iPad-unsigned` artifact from the completed GitHub Actions run
and move the IPA to the Windows PC used for local signing.

Use the user's local 3uTools workflow with their own Apple ID/free provisioning
and intended iPad, then install the resulting locally signed IPA. Free
provisioning may require periodic re-signing. Do not put Apple ID, iCloud, or
3uTools credentials in this repository or GitHub Actions; 3uTools is external
local tooling and is not run by CI. The GitHub artifact is unsigned, and
physical iPad qualification remains NOT RUN / DEFERRED.

---

## 📋 Prerequisites
1. **Mac Computer** running macOS Sonoma / Sequoia with **Xcode 15+** installed.
2. **Physical iPad** (iPad Pro M1/M2/M4/M5 recommended for native 120Hz ProMotion support).
3. **USB-C Data Cable** (USB4, Thunderbolt 3/4, or high-speed USB 3.1 cable).
4. **Apple ID** (Free Personal Developer Account is sufficient).

---

## 🛠️ Step-by-Step Xcode Deployment Instructions

### Step 1: Copy Source Files to Mac
Copy the `Client/` folder containing the Swift and Metal source files onto your Mac desktop:
- `iPadZeroLagDisplayApp.swift`
- `ContentView.swift`
- `MetalView.swift`
- `PencilTouchView.swift`
- `Renderer.swift`
- `Shaders.metal`
- `DecoderManager.swift`
- `NetworkManager.swift`
- `Info.plist`

---

### Step 2: Create New Xcode Project
1. Launch **Xcode** on your Mac.
2. Select **File > New > Project...**
3. Under the **iOS** tab, select **App** and click **Next**.
4. Configure Project Options:
   - **Product Name**: `iPadCasting`
   - **Team**: Select your Apple ID / Personal Team
   - **Organization Identifier**: `com.iPadZeroLagDisplay`
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
5. Choose a destination folder on your Mac and click **Create**.

---

### Step 3: Add Source Files to Xcode
1. In Xcode's Left Sidebar (**Project Navigator**), delete the default `ContentView.swift` and `iPadCastingApp.swift` files created by the template (Move to Trash).
2. Drag and drop all 9 files from the copied `Client/` folder directly into your Xcode Project Navigator:
   - `iPadZeroLagDisplayApp.swift`
   - `ContentView.swift`
   - `MetalView.swift`
   - `PencilTouchView.swift`
   - `Renderer.swift`
   - `Shaders.metal`
   - `DecoderManager.swift`
   - `NetworkManager.swift`
   - `Info.plist`
3. In the popup options dialog:
   - Check **Copy items if needed**.
   - Select **Create groups**.
   - Check **Add to targets: iPadCasting**.
   - Click **Finish**.

---

### Step 4: Configure Project Info.plist & Target Settings
1. Select the top-level **iPadCasting** project node in Project Navigator.
2. Go to **Signing & Capabilities**:
   - Ensure **Automatically manage signing** is checked.
   - Select your **Team** (Free Apple ID account).
3. Go to **General** tab:
   - Under **Supported Destinations**, ensure **iPad** is listed.
   - Set **Minimum Deployments** to **iOS 17.0** or later.
4. Under **Info** tab:
   - Set **Custom iOS Target Properties > Key Privacy - Local Network Usage Description** to:
     `"iPadCasting requires local network access to stream 120Hz zero-lag video from your Windows host over USB."`
   - `CADisableMinimumFrameDurationOnPhone: YES` — Required for 120Hz ProMotion rendering on iPad Pro. This key is already included in the provided `Info.plist`.

---

### Step 5: Connect iPad & Sideload App
1. Connect your physical iPad to your Mac using the USB-C cable.
2. If prompted on iPad, tap **Trust This Computer** and enter your iPad passcode.
3. In Xcode's top toolbar, click the device selector dropdown (next to `iPadCasting >`) and select your **Physical iPad** (e.g. `Alex's iPad Pro`).
4. Click the **Play / Run Button** (`⌘ + R`) or press **Cmd + R**.
5. Xcode will compile the Metal shaders and Swift code, package the application, and install it on your iPad.

---

### Step 6: Trust Developer Certificate on iPad (First Time Only)
When launching the app for the first time on your iPad:
1. Open **Settings** on your iPad.
2. Navigate to **General > VPN & Device Management**.
3. Under **Developer App**, tap your Apple ID email.
4. Tap **Trust "[Your Apple ID]"** and confirm.
5. Tap the **iPadCasting** app icon on your iPad home screen to launch!

---

## ⚡ Connecting to Windows Host
1. Connect your iPad to your Windows PC using the USB-C cable.
2. Launch `iPadCasting.exe` on your Windows PC.
3. Click **Enable Virtual Monitor** in the Windows app.
4. Select **120 Hz** (or `120 Hz (CRU Override)`).
5. Click **Start Streaming to iPad**!
