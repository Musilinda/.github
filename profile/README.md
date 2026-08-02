# Musilinda
A solfège-based music education platform that teaches pitch, intervals, scales, modes, chords, and ear training through interactive browser-based exercises and real-time AI pitch recognition.
Available on the [Apple App Store](https://apps.apple.com/us/app/musilinda/id6749832456)

---

## Repositories

| Repository | Description |
|---|---|
| [web](https://github.com/Musilinda/web.git) | Official landing page |
| [core](https://github.com/Musilinda/core) | Research — programmatic music notation generation and Whisper-based syllable classifier pipeline. |
| [app](https://github.com/Musilinda/app_musilinda) | Full-stack web app — interactive music lessons with on-device ONNX solfège recognition. |
| [capacitor](https://github.com/Musilinda/capacitor) | iOS native shell — Capacitor WebView with RevenueCat subscriptions and AdMob monetization. |
| [api](https://github.com/Musilinda/api) | Flask API - WhisperMultiHeadClassifier deep learning inference symbol-audio pairs. |
| [blog](https://github.com/Musilinda/blog) | Learning material with CMS |
---

## Documentation

- 📖 [Architecture](../ARCHITECTURAL_LANDSCAPE.md)
- 🤖 [Claude Instructions](../CLAUDE.md)

## Mission

Make music learning accessible by grounding in solfège — proven, ear-first interactive lessons that connect listening with understanding.

---

## Platform Overview

```
┌─────────────────────────────────────────────┐
│             app.musilinda.com               │
│         (React SPA + Express API)           │
│                                             │
│  Lessons: keys, modes, intervals, chords,   │
│  ear training, notation, chromatic solfege  │
│                                             │
│  AI: ONNX WhisperMultiHead in-browser       │
│  DB:  Neon PostgreSQL (Drizzle ORM)         │
└─────────────────────────────────────────────┘
              ^                  ^
              | WebView          | API
┌─────────────┴──────┐           |
│   iOS App          │           |
│   (Capacitor)      │     ┌─────┴──────────┐
│   RevenueCat       │     │  core          │
│   AdMob            │     │  ML training   │
└────────────────────┘     │  Notation gen  │
                           └────────────────┘
```

---

## Technology Highlights

- **Solfège AI** — A frozen Whisper-tiny encoder drives three classification heads (syllable / vowel / consonant) trained on recorded solfège samples and deployed as an ONNX model directly in the browser.
- **Programmatic notation** — Music score visuals are generated with `music21` + MuseScore 4 and exported as SVG/MusicXML for lessons and blog posts.
- **Cross-platform** — The web app is wrapped in a Capacitor iOS shell, giving a native App Store experience with RevenueCat subscriptions and AdMob advertising.

---


## Subscription Model

| Tier | Access |
|---|---|
| Free | Core concepts, selected lessons, ad-supported |
| Premium | All lessons, mode library, advanced ear training, ad-free |

Built and maintained by Stephan Vanwoezik [@trapadulli](https://github.com/trapadulli).
