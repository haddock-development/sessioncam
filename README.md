# SessionCam

Eigener LiDAR-Session-Recorder (iPhone Pro, iOS 17+) — ersetzt Record3D.
Nimmt auf: RGB-Video (H.264) + LiDAR-Depth (Float32) + Kamera-Posen + Intrinsics,
direkt im Format der Indoor-Capture-Pipeline ("sessioncam-v1").

## Build (ohne Mac)

Push auf `main` -> GitHub Actions (macos-15): XcodeGen -> xcodebuild (unsigned)
-> Artefakt `SessionCam-ipa` (`.ipa`) im Run.

## Installieren aufs iPhone (ohne Dev-Account)

1. Artefakt von der letzten gruenen Action laden (Actions -> Build -> Artifacts)
2. PC: [Sideloadly](https://sideloadly.io) (Windows) oder [SideStore](https://sidestore.io)
3. IPA mit deiner normalen Apple ID signen + installieren
4. Zertifikat gilt 7 Tage -> woechentlich neu signieren (gleiche IPA, nur neu signieren)

## Bedienung

1. ORT + ZIMMER eintragen (Dateiname: `JAHR-MONAT-TAG_ORT_ZIMMER`)
2. START -> langsam gehen (Ziel 0,8-1,0 m/s; Anzeige ROT = zu schnell)
3. Pro Raum eine Session. Loop schliessen: zurueck zum Startpunkt, 2-3 s stehen
4. STOP -> "Session zippen" -> "ZIP teilen" (Dateien/iCloud)

## Datenformat (sessioncam-v1)

```
session/
  video.mp4        H.264, Sensor-Orientierung (landscape)
  poses.jsonl      pro Frame: i, t (rel. s), pose (row-major 4x4), fx fy cx cy, w h, depth
  intrinsics.json  (in poses.jsonl je Frame; Metadatei folgt)
  depth/NNNNNN.f32 Float32-LE, verlustfrei, Dims stehen in poses.jsonl
  meta.json        Geraet, Frames, Pfadlaenge, Dauer
```

Sessions liegen in Dateien -> Auf meinem iPhone -> SessionCam -> sessions/.
Pipeline: scripts/import_sessioncam.py -> cosmos_layout -> qc_report.py.

## Roadmap

- [x] Phase 1: Recording in Pipeline-Format
- [x] Phase 2: Live-Kamera-Vorschau, Tracking-Badge, Loop-Gap live, Pause/Resume, Raw-IMU, Confidence-Map, Session-Manager
- [ ] Phase 3: Live-QC-Gates (rotes Overlay > 1,2 m/s, Loop-Erinnerung, Coverage)
- [ ] Phase 4: RoomPlan-Grundriss + Web-Viewer (ersetzt Polycam/magicplan)
