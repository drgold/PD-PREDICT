# iOS Reference Source

This folder contains the iOS Swift source files for the PULSE-PD trial app.

## Files

- PDPREDICT242026.swift — Original PD PREDICT 3.0 (legacy)
- PDTracker_Patient.swift — PULSE-PD Trial Build (current)

## Active Trials

- PULSE-PD: 12-month RCT, nicotine patches in early Parkinson disease
- ASCEND-SVD: Vascular parkinsonism and vascular MCI pilot trial

## For Android Developers

See /docs/ for the architecture handoff document.
See /shared-schema/ for JSON payload examples.
See /scripts/ for the Google Apps Script webhook.

The Android app must produce identical AssessmentResult JSON to the iOS app.
HMAC-SHA256 signing scheme must match exactly — see handoff doc Section 4.2.
