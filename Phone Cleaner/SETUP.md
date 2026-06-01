# DeepClean — Setup Instructions

## Run It FREE on Your iPhone Today

### Step 1: Create Xcode Project (5 minutes)

1. Open Xcode on a Mac (or MacInCloud.com if you don't have one)
2. File → New → Project → iOS → App
3. Set these options:
   - **Product Name:** DeepClean
   - **Bundle Identifier:** com.yourname.deepclean
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Minimum Deployments:** iOS 17.0
4. Save the project INSIDE the `DeepClean/` folder

### Step 2: Add Source Files

Drag all `.swift` files from the folder into Xcode's project navigator.
Keep the group structure:
```
DeepClean/
├── PhoneCleanerApp.swift
├── ContentView.swift
├── Models/
├── Core/
│   ├── Analyzers/
│   └── Clustering/
├── Features/
│   ├── Dashboard/
│   ├── Scan/
│   └── Review/
└── Design/
    └── Components/
```

### Step 3: Add Frameworks

In Xcode → Project Settings → Frameworks, Libraries, and Embedded Content:
- Vision.framework (already linked by default on iOS 17+)
- Photos.framework
- Contacts.framework
- Accelerate.framework
- AVFoundation.framework
- CryptoKit.framework

### Step 4: Set Signing (Free Apple ID)

1. Xcode → Signing & Capabilities
2. Team → Add Account → sign in with your Apple ID (FREE)
3. Xcode auto-creates a provisioning profile

### Step 5: Install on iPhone

1. Plug iPhone into Mac via USB
2. Trust the computer on iPhone when prompted
3. Select your iPhone in Xcode's device picker
4. Press ▶ Run
5. App installs and launches immediately

**Note with free Apple ID:** App expires after 7 days. Re-run from Xcode to refresh.
**With $99 Developer account:** App lasts 1 year.

---

## Free Cloud Build (No Mac Needed)

### Using GitHub Actions + AltStore

1. Push this folder to a GitHub repository
2. GitHub automatically builds the IPA on their Mac servers (FREE)
3. Download the `.ipa` from the Actions → Artifacts tab
4. Install AltServer on Windows: https://altstore.io
5. Install AltStore on iPhone via AltServer
6. Open AltStore on iPhone → My Apps → + → select the .ipa
7. App installs! AltStore refreshes it automatically every 7 days over WiFi

### Required Info.plist permissions (already set)
- `NSPhotoLibraryUsageDescription` — for photo scanning
- `NSContactsUsageDescription` — for contact duplicate detection

---

## Features Built

- Exact duplicate detection (SHA256 + EXIF fingerprint)
- AI visual similarity (Vision FeaturePrint embeddings)
- Apple aesthetics model (VNGenerateImageAestheticsScoresRequest — iOS 17)
- Sharpness scoring (Laplacian variance via Accelerate)
- Exposure scoring (histogram analysis)
- Face quality (eyes open, face sharpness)
- Junk shot detection (accidental, body-part, floor/ceiling shots)
- Screenshot + screen recording detection
- WhatsApp duplicate detection (cross-album)
- Video duplicate detection (frame fingerprinting)
- Accidental video clip detection (< 3 seconds)
- Burst sequence grouping
- Full review UI with side-by-side comparison
- Quality scores shown per photo
- Smart pre-selection of worst photos in each group
- All deletes go to Photos Trash (30-day recovery)
- iCloud-aware scanning
- Dark mode design system
