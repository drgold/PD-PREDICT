//  PDTracker_Patient.swift
//  PULSE-PD Trial Build (Consolidated)
//  Updated with Camera Fixes

import SwiftUI
import CoreMotion
import AVFoundation
import Vision
import AudioToolbox
import Security
import UserNotifications
import UIKit
import CryptoKit
import QuartzCore
import HealthKit
import CoreVideo
import CoreLocation

// MARK: - Configuration
/// Google Apps Script web app URL for assessment ingest (Deploy → Web app → copy URL; must end with `/exec`).
/// Do **not** use the editor “Test deployment” URL ending in `/dev` — it is not for programmatic POST from the app.
/// Settings → Ingest Endpoint still overrides this via `pd_tracker_endpoint` in UserDefaults.
enum IngestEndpoint {
    static let googleAppsScriptDefault = "https://script.google.com/macros/s/AKfycbzW0jF_wbltZgicQnMrZcxa_qhfVtlhehDBjx4NZn9ukIKqenwE12NtKzmbXRa21YJC/exec"
    
    /// True only for a deployed **Web app** URL (`Deploy` → copy URL ending in `/exec`). Not a Sheet URL, not `/dev`, not the script editor.
    static func isPlausibleGoogleAppsScriptWebAppURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return false }
        guard host == "script.google.com" else { return false }
        guard s.contains("/macros/s/") else { return false }
        // Strip query/fragment for suffix check
        let pathPart = s.split(separator: "?").first.map(String.init) ?? s
        let noFrag = pathPart.split(separator: "#").first.map(String.init) ?? pathPart
        return noFrag.hasSuffix("/exec")
    }
    
    /// Maps `/dev` → `/exec`. If the string is clearly **not** a web app URL (e.g. pasted Google Sheet link), returns the built-in default so POST does not hit docs.google.com (HTTP 405 + HTML).
    static func normalizedIngestURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/dev") {
            s = String(s.dropLast(4)) + "/exec"
        }
        if isPlausibleGoogleAppsScriptWebAppURL(s) {
            return s
        }
        return googleAppsScriptDefault
    }
}

final class AppConfiguration {
    static let shared = AppConfiguration()
    private(set) var apiEndpoint: String
    
    private init() {
        let stored = UserDefaults.standard.string(forKey: "pd_tracker_endpoint") ?? ""
        let base = stored.isEmpty ? IngestEndpoint.googleAppsScriptDefault : stored
        self.apiEndpoint = IngestEndpoint.normalizedIngestURL(base)
        if self.apiEndpoint != base {
            UserDefaults.standard.set(self.apiEndpoint, forKey: "pd_tracker_endpoint")
        }
    }
    
    func updateEndpoint(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = IngestEndpoint.normalizedIngestURL(trimmed)
        apiEndpoint = normalized
        UserDefaults.standard.set(normalized, forKey: "pd_tracker_endpoint")
    }
}

// MARK: - Settings (Endpoint + HMAC Secret)
struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: String = AppConfiguration.shared.apiEndpoint
    @State private var hmacSecret: String = ""
    @State private var googleApiKey: String = (KeychainManager.shared.loadGoogleAPIKey() ?? "")
    @State private var saved = false
    @State private var ingestAlertMessage: String?
    @State private var showIngestAlert = false
    @State private var testingIngest = false
    @State private var sendingSampleRow = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Ingest Endpoint") {
                    TextField("Google Apps Script …/exec", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Must end with `/exec` (Deploy → Web app). `UserDefaults` key `pd_tracker_endpoint` overrides the built-in default when set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Text("Study ID used for sample row: \(vm.studyID.isEmpty ? "(empty — will use DIAGNOSTIC)" : vm.studyID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NetworkService.lastIngestLog)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Text("Queued uploads")
                        Spacer()
                        Text("\(NetworkService.shared.pendingUploadCount)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear queued uploads", role: .destructive) {
                        NetworkService.shared.clearPendingUploads()
                        ingestAlertMessage = "Cleared pending upload queue. New assessments will upload normally from now on."
                        showIngestAlert = true
                    }
                    Button {
                        testingIngest = true
                        NetworkService.shared.testIngestEndpoint { msg in
                            testingIngest = false
                            ingestAlertMessage = msg
                            showIngestAlert = true
                        }
                    } label: {
                        if testingIngest {
                            HStack { ProgressView(); Text("Testing…") }
                        } else {
                            Text("Test connection (ping JSON)")
                        }
                    }
                    .disabled(testingIngest || sendingSampleRow)
                    Button {
                        sendingSampleRow = true
                        NetworkService.shared.sendDiagnosticSampleAssessment(studyID: vm.studyID) { msg in
                            sendingSampleRow = false
                            ingestAlertMessage = msg
                            showIngestAlert = true
                        }
                    } label: {
                        if sendingSampleRow {
                            HStack { ProgressView(); Text("Sending…") }
                        } else {
                            Text("Push sample assessment row (Excel / Sheets)")
                        }
                    }
                    .disabled(testingIngest || sendingSampleRow)
                    Text("Uses the same JSON shape as real assessments (`AssessmentResult`). Check your Sheet for type **DiagnosticIngestTest**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("HMAC Secret (stored securely)") {
                    SecureField("Paste secret...", text: $hmacSecret)
                    Text("Leave empty unless your Apps Script verifies `X-Signature`. A wrong secret can make the script reject requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear saved HMAC secret", role: .destructive) {
                        KeychainManager.shared.deleteIngestToken()
                        hmacSecret = ""
                    }
                }
                Section("Google Maps API Key (stored securely)") {
                    SecureField("Paste Google API key…", text: $googleApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if saved {
                    Text("Saved").font(.caption).foregroundStyle(.green)
                }
                Button("Save") {
                    AppConfiguration.shared.updateEndpoint(endpoint)
                    endpoint = AppConfiguration.shared.apiEndpoint
                    if !hmacSecret.isEmpty {
                        _ = KeychainManager.shared.saveIngestToken(hmacSecret)
                    }
                    if !googleApiKey.isEmpty {
                        _ = KeychainManager.shared.saveGoogleAPIKey(googleApiKey)
                    }
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .alert("Ingest result", isPresented: $showIngestAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ingestAlertMessage ?? "")
            }
        }
    }
}
// MARK: - Data Models
struct AssessmentResult: Identifiable, Codable {
    let id: UUID
    let date: Date
    let studyID: String
    let assessmentType: String
    var data: [String: String]
    let notes: String?
}

struct ParticipantInfo: Codable {
    var id: String = ""
    var age: Int = 40
    var sex: String = "Female"
    var enrollmentDate: Date = Date()
    // Baseline fields
    var diagnosedPD: Bool? = nil
    var pdDiagnosisYear: String = ""
    var wifiReliability: String = ""
    var hasCellData: Bool? = nil
    var handedness: String = ""
    var baselineCaffeineMg: String = ""
    // Baseline mood/sleep/anxiety (0–10), set at onboarding or first month
    var baselineMood: Int? = nil
    var baselineSleep: Int? = nil
    var baselineAnxiety: Int? = nil
    // Nicotine arm/dose (optional)
    var isNicotineArm: Bool? = nil
    var nicotineDoseMg: Int? = nil
}

// MARK: - History Store
final class HistoryStore: ObservableObject {
    @Published private(set) var assessments: [AssessmentResult] = []
    private let key = "pd_tracker_assessments"
    
    init() { loadAssessments() }
    
    func save(_ assessment: AssessmentResult) {
        var current = loadFromDisk()
        current.insert(assessment, at: 0)
        if current.count > 500 { current.removeLast(current.count - 500) }
        saveToDisk(current)
        assessments = current
    }
    
    private func loadAssessments() { assessments = loadFromDisk() }
    
    private func loadFromDisk() -> [AssessmentResult] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AssessmentResult].self, from: data) else {
            return []
        }
        return decoded
    }
    
    private func saveToDisk(_ results: [AssessmentResult]) {
        if let encoded = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    func clearAll() {
        saveToDisk([])
        assessments = []
    }
}

// MARK: - Nicotine Dose View
struct NicotineDoseView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var tolerated: Bool = false
    @State private var sideEffectsNotes: String = ""
    @State private var started: Date = Date()
    
    private var currentDose: Int {
        vm.participant.nicotineDoseMg ?? 7
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Current dose: \(currentDose) mg")
                        .font(.headline)
                }
                Section("Tolerance check") {
                    Toggle("Tolerated (no significant nausea, dizziness)", isOn: $tolerated)
                    TextField("Optional notes", text: $sideEffectsNotes)
                }
                if currentDose == 7 && tolerated {
                    Section {
                        Button("Increase to 14 mg") {
                            escalateDose()
                        }
                        .buttonStyle(.borderedProminent)
                    } footer: {
                        Text("Only increase after confirming tolerance at 7 mg.")
                    }
                }
                Section {
                    Button("Save") {
                        saveCheck()
                    }
                }
            }
            .navigationTitle("Nicotine Dose")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { started = Date() }
    }
    
    private func saveCheck() {
        let end = Date()
        var data: [String:String] = [
            "dose_mg": "\(currentDose)",
            "tolerated": tolerated ? "true" : "false"
        ]
        if !sideEffectsNotes.isEmpty { data["notes"] = sideEffectsNotes }
        data.merge(deviceMeta(task: "Nicotine Dose", taskVersion: "1.0", start: started, end: end, studyID: vm.studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "Nicotine Dose", data: data, notes: tolerated ? "Tolerated" : "Not tolerated")
        vm.saveAssessment(res)
        if !tolerated {
            NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "nicotine_side_effects", urgency: "routine")
        }
        dismiss()
    }
    
    private func escalateDose() {
        let end = Date()
        let previous = currentDose
        vm.participant.nicotineDoseMg = 14
        var data: [String:String] = [
            "previous_dose_mg": "\(previous)",
            "new_dose_mg": "14",
            "tolerated": "true"
        ]
        if !sideEffectsNotes.isEmpty { data["notes"] = sideEffectsNotes }
        data.merge(deviceMeta(task: "Nicotine Dose", taskVersion: "1.0", start: started, end: end, studyID: vm.studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "Nicotine Dose", data: data, notes: "Dose increased to 14 mg")
        vm.saveAssessment(res)
        NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "nicotine_dose_increase", urgency: "routine")
        dismiss()
    }
}

// MARK: - Keychain Manager
final class KeychainManager {
    static let shared = KeychainManager()
    private let service = "com.pulsepd.trial"
    private init() {}
    
    func saveStudyID(_ id: String) -> Bool {
        let data = id.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "study_id",
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    // MARK: Google API Key
    func saveGoogleAPIKey(_ key: String) -> Bool {
        let data = key.data(using: .utf8)!
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "google_api_key",
            kSecValueData as String: data
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess
    }
    func loadGoogleAPIKey() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "google_api_key",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: Ingest HMAC secret
    func saveIngestToken(_ token: String) -> Bool {
        let data = token.data(using: .utf8)!
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ingest_token",
            kSecValueData as String: data
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess
    }
    func loadIngestToken() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ingest_token",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func loadStudyID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "study_id",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let id = String(data: data, encoding: .utf8) else { return nil }
        return id
    }
    
    func deleteStudyID() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "study_id"
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    func deleteIngestToken() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ingest_token"
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Notifications
enum NotificationPreferences {
    static let enabledKey = "pd_tracker_notifications_enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

final class ReminderManager {
    static let monthlyReminderId = "pulsepd.reminder"
    
    static func requestAuth(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { completion?(ok) }
        }
    }
    
    /// Call after enrollment when the user has opted in in Consent.
    static func applyUserPreferenceForMonthlyCheckIn() {
        guard NotificationPreferences.isEnabled else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [monthlyReminderId])
            return
        }
        requestAuth { _ in scheduleMonthly() }
    }
    
    static func scheduleMonthly() {
        let content = UNMutableNotificationContent()
        content.title = "PD Predict monthly check-in"
        content.body = "Please complete your assessments when you can."
        var comps = DateComponents()
        comps.hour = 10
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: monthlyReminderId, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - HealthKit
final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    
    private func availableReadTypes() -> Set<HKObjectType> {
        var set = Set<HKObjectType>()
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { set.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .walkingSpeed) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .walkingStepLength) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .numberOfTimesFallen) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .flightsClimbed) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) { set.insert(t) }
        return set
    }
    
    func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        guard isAvailable() else { completion(false, NSError(domain: "healthkit", code: 0, userInfo: [NSLocalizedDescriptionKey: "Health data not available"])) ; return }
        let types = availableReadTypes()
        guard !types.isEmpty else {
            completion(false, NSError(domain: "healthkit", code: 1, userInfo: [NSLocalizedDescriptionKey: "No supported Health types available on this device"]))
            return
        }
        store.requestAuthorization(toShare: nil, read: types, completion: completion)
    }
    
    func fetch30DaySummary(completion: @escaping ([String:String]) -> Void) {
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -30, to: end) ?? end.addingTimeInterval(-30*24*3600)
        var results: [String:String] = [:]
        let group = DispatchGroup()
        
        // Steps (sum)
        if let type = HKObjectType.quantityType(forIdentifier: .stepCount) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.count(), start: start, end: end) { sum in
                if let v = sum { results["steps_30d"] = String(format: "%.0f", v) }
                group.leave()
            }
        }
        // Resting HR (avg)
        if let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.count().unitDivided(by: HKUnit.minute()), start: start, end: end) { avg in
                if let v = avg { results["resting_hr_bpm_avg_30d"] = String(format: "%.1f", v) }
                group.leave()
            }
        }
        // HRV SDNN (avg)
        if let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.secondUnit(with: .milli), start: start, end: end) { avg in
                if let v = avg { results["hrv_sdnn_ms_avg_30d"] = String(format: "%.1f", v) }
                group.leave()
            }
        }
        // Sleep hours (sum)
        if let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            sumSleepHours(type: type, start: start, end: end) { hours in
                if let h = hours { results["sleep_hours_30d"] = String(format: "%.1f", h) }
                group.leave()
            }
        }
        // Distance walking/running (sum, m -> km)
        if let type = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.meter(), start: start, end: end) { sum in
                if let v = sum { results["distance_km_30d"] = String(format: "%.2f", v / 1000) }
                group.leave()
            }
        }
        // Walking speed (avg, m/s)
        if let type = HKObjectType.quantityType(forIdentifier: .walkingSpeed) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.meter().unitDivided(by: HKUnit.second()), start: start, end: end) { avg in
                if let v = avg { results["walking_speed_mps_avg_30d"] = String(format: "%.3f", v) }
                group.leave()
            }
        }
        // Walking step length (avg, m -> cm)
        if let type = HKObjectType.quantityType(forIdentifier: .walkingStepLength) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.meter(), start: start, end: end) { avg in
                if let v = avg { results["walking_step_length_cm_avg_30d"] = String(format: "%.1f", v * 100) }
                group.leave()
            }
        }
        // Walking asymmetry (avg, %)
        if let type = HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.percent(), start: start, end: end) { avg in
                if let v = avg { results["walking_asymmetry_pct_avg_30d"] = String(format: "%.1f", v) }
                group.leave()
            }
        }
        // Walking double support (avg, %)
        if let type = HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.percent(), start: start, end: end) { avg in
                if let v = avg { results["walking_double_support_pct_avg_30d"] = String(format: "%.1f", v) }
                group.leave()
            }
        }
        // Apple walking steadiness (avg, %)
        if let type = HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness) {
            group.enter()
            avgQuantity(type: type, unit: HKUnit.percent(), start: start, end: end) { avg in
                if let v = avg { results["walking_steadiness_pct_avg_30d"] = String(format: "%.1f", v) }
                group.leave()
            }
        }
        // Number of times fallen (sum, count)
        if let type = HKObjectType.quantityType(forIdentifier: .numberOfTimesFallen) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.count(), start: start, end: end) { sum in
                if let v = sum { results["falls_count_30d"] = String(format: "%.0f", v) }
                group.leave()
            }
        }
        // Flights climbed (sum, count)
        if let type = HKObjectType.quantityType(forIdentifier: .flightsClimbed) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.count(), start: start, end: end) { sum in
                if let v = sum { results["flights_climbed_30d"] = String(format: "%.0f", v) }
                group.leave()
            }
        }
        // Active energy burned (sum, kcal)
        if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.kilocalorie(), start: start, end: end) { sum in
                if let v = sum { results["active_calories_30d"] = String(format: "%.0f", v) }
                group.leave()
            }
        }
        // Apple exercise time (sum, min)
        if let type = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) {
            group.enter()
            sumQuantity(type: type, unit: HKUnit.minute(), start: start, end: end) { sum in
                if let v = sum { results["exercise_minutes_30d"] = String(format: "%.0f", v) }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            completion(results)
        }
    }
    
    private func sumQuantity(type: HKQuantityType, unit: HKUnit, start: Date, end: Date, completion: @escaping (Double?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
            let value = stats?.sumQuantity()?.doubleValue(for: unit)
            DispatchQueue.main.async { completion(value) }
        }
        store.execute(query)
    }
    private func avgQuantity(type: HKQuantityType, unit: HKUnit, start: Date, end: Date, completion: @escaping (Double?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
            let value = stats?.averageQuantity()?.doubleValue(for: unit)
            DispatchQueue.main.async { completion(value) }
        }
        store.execute(query)
    }
    private func sumSleepHours(type: HKCategoryType, start: Date, end: Date, completion: @escaping (Double?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            let total = samples?.compactMap { s -> Double? in
                guard let c = s as? HKCategorySample else { return nil }
                let dur = c.endDate.timeIntervalSince(c.startDate) / 3600.0
                // Count only "inBed" and "asleep" categories as sleep; sum all for simplicity
                return dur
            }.reduce(0, +) ?? 0
            DispatchQueue.main.async { completion(total) }
        }
        store.execute(query)
    }
}
// MARK: - Networking (Offline queue + flush)
/// Google Apps Script often responds with **302** redirects. `URLSession`’s default redirect handling can turn a POST into a GET and **drop the JSON body**, so rows never appear. This delegate keeps POST + body + auth headers on redirect.
final class IngestRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = IngestRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest,
              original.httpMethod == "POST",
              let body = original.httpBody, !body.isEmpty else {
            completionHandler(request)
            return
        }
        var redirected = request
        redirected.httpMethod = "POST"
        redirected.httpBody = body
        if let ct = original.value(forHTTPHeaderField: "Content-Type") {
            redirected.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        for h in ["X-Nonce", "X-Timestamp", "X-Signature"] {
            if let v = original.value(forHTTPHeaderField: h) {
                redirected.setValue(v, forHTTPHeaderField: h)
            }
        }
        completionHandler(redirected)
    }
}

final class NetworkService {
    static let shared = NetworkService()
    private let queueKey = "pd_upload_queue" // stores [Data]
    private let sentResultIDsKey = "pd_upload_sent_result_ids"
    private static let lastIngestLogKey = "pd_last_ingest_log"
    /// Serial queue so uploads never block the main thread (was causing 5–10s freezes after each assessment).
    private let uploadQueue = DispatchQueue(label: "com.pdpredict.ingest", qos: .utility)
    private var isFlushing = false
    private static let ingestURLSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        // Do NOT set httpCookieStorage = nil — GAS redirect chain needs session cookies
        // to route from script.google.com → scriptusercontent.com correctly.
        return URLSession(configuration: cfg, delegate: IngestRedirectDelegate.shared, delegateQueue: nil)
    }()
    private init() {}
    
    private func recordIngestResult(context: String, status: Int, data: Data?, error: Error?) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let okRange = 200..<300
        let ok = error == nil && okRange.contains(status)
        let bodySnippet = String(data: data ?? Data(), encoding: .utf8)?.replacingOccurrences(of: "\n", with: " ") ?? ""
        let trimmed = String(bodySnippet.prefix(500))
        let errStr = error.map { $0.localizedDescription } ?? ""
        let line = "\(ts) \(context) HTTP \(status) \(ok ? "OK" : "FAIL")\(errStr.isEmpty ? "" : " err=\(errStr)") \(trimmed.isEmpty ? "" : "body=\(trimmed)")"
        UserDefaults.standard.set(String(line.prefix(2000)), forKey: Self.lastIngestLogKey)
        #if DEBUG
        print("[ingest]", line)
        #endif
    }
    
    static var lastIngestLog: String {
        UserDefaults.standard.string(forKey: lastIngestLogKey) ?? "No uploads attempted yet."
    }
    
    var pendingUploadCount: Int {
        (UserDefaults.standard.array(forKey: queueKey) as? [Data])?.count ?? 0
    }
    
    /// POST a tiny JSON payload to verify deployment, URL, and (optional) HMAC. Check the alert and Apps Script **Executions** log.
    func testIngestEndpoint(completion: @escaping (String) -> Void) {
        let payload: [String: Any] = [
            "type": "pd_app_ping",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "endpoint": AppConfiguration.shared.apiEndpoint
        ]
        guard let url = URL(string: AppConfiguration.shared.apiEndpoint),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion("Invalid endpoint URL.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
            let nonce = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            var toSign = Data()
            toSign.append(Data(nonce.utf8))
            toSign.append(Data(ts.utf8))
            toSign.append(body)
            let sig = hmacSHA256Hex(key: token, data: toSign)
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Signature")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Self.ingestURLSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.recordIngestResult(context: "test_ping", status: code, data: data, error: err)
                let summary = "HTTP \(code)\n\(text.prefix(800))"
                completion(err != nil ? "\(summary)\n\nError: \(err!.localizedDescription)" : summary)
            }
        }.resume()
    }
    
    /// POSTs one **real-shaped** `AssessmentResult` (same JSON encoding as the upload queue) so your Apps Script / Sheet can be tested end-to-end. Does not add to the offline queue.
    func sendDiagnosticSampleAssessment(studyID: String, completion: @escaping (String) -> Void) {
        let sid = studyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = AssessmentResult(
            id: UUID(),
            date: Date(),
            studyID: sid.isEmpty ? "DIAGNOSTIC" : sid,
            assessmentType: "DiagnosticIngestTest",
            data: [
                "source": "ios_troubleshoot",
                "sent_at": ISO8601DateFormatter().string(from: Date())
            ],
            notes: "Manual API test row — safe to delete in Sheets."
        )
        guard let payload = Self.encodeForIngest(sample) else {
            completion("Could not encode sample assessment.")
            return
        }
        guard let url = URL(string: AppConfiguration.shared.apiEndpoint) else {
            completion("Invalid ingest URL in settings.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
            let nonce = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            var toSign = Data()
            toSign.append(Data(nonce.utf8))
            toSign.append(Data(ts.utf8))
            toSign.append(payload)
            let sig = hmacSHA256Hex(key: token, data: toSign)
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Signature")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        Self.ingestURLSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.recordIngestResult(context: "diagnostic_sample_assessment", status: code, data: data, error: err)
                var summary = "HTTP \(code)\n\(text.prefix(800))"
                if (200..<300).contains(code) {
                    summary += "\n\nLook for DiagnosticIngestTest in your spreadsheet (study_id: \(sid.isEmpty ? "DIAGNOSTIC" : sid))."
                }
                completion(err != nil ? "\(summary)\n\nError: \(err!.localizedDescription)" : summary)
            }
        }.resume()
    }
    
    private func hmacSHA256Hex(key: String, data: Data) -> String {
        let keyData = Data(key.utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData))
        return signature.map { String(format: "%02x", $0) }.joined()
    }
    
    private static func encodeForIngest(_ assessment: AssessmentResult) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(assessment)
    }
    
    private static func responseBodyIndicatesAccepted(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let ok = obj["ok"] as? Bool, ok { return true }
        if let deduped = obj["deduped"] as? Bool, deduped { return true }
        if let ignored = obj["ignored"] as? Bool, ignored { return true }
        return false
    }
    
    private func normalizedResultID(from payload: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let raw = (obj["result_id"] as? String) ?? (obj["id"] as? String) ?? ""
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }
    
    private func loadSentResultIDs() -> Set<String> {
        let arr = UserDefaults.standard.array(forKey: sentResultIDsKey) as? [String] ?? []
        return Set(arr)
    }
    
    private func saveSentResultIDs(_ ids: Set<String>) {
        // Keep footprint bounded in UserDefaults.
        let bounded = Array(ids.prefix(5000))
        UserDefaults.standard.set(bounded, forKey: sentResultIDsKey)
    }
    
    private func isAlreadyDelivered(_ payload: Data) -> Bool {
        guard let id = normalizedResultID(from: payload) else { return false }
        return loadSentResultIDs().contains(id)
    }
    
    private func markDelivered(_ payload: Data) {
        guard let id = normalizedResultID(from: payload) else { return }
        var ids = loadSentResultIDs()
        ids.insert(id)
        saveSentResultIDs(ids)
    }
    
    private func dedupeQueuePayloads(_ queue: [Data]) -> [Data] {
        var seenIDs = Set<String>()
        var seenPayloadHashes = Set<Int>()
        var deduped: [Data] = []
        deduped.reserveCapacity(queue.count)
        
        for payload in queue {
            if let id = normalizedResultID(from: payload) {
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)
            } else {
                let h = payload.hashValue
                if seenPayloadHashes.contains(h) { continue }
                seenPayloadHashes.insert(h)
            }
            deduped.append(payload)
        }
        return deduped
    }
    
    func enqueue(_ assessment: AssessmentResult) {
        uploadQueue.async { [weak self] in
            guard let self else { return }
            guard let payload = Self.encodeForIngest(assessment) else { return }
            if self.isAlreadyDelivered(payload) { return }
            var q = self.dedupeQueuePayloads(self.loadQueue())
            if let newID = self.normalizedResultID(from: payload),
               q.contains(where: { self.normalizedResultID(from: $0) == newID }) {
                return
            }
            q.append(payload)
            self.saveQueue(self.dedupeQueuePayloads(q))
            self.flush()
        }
    }
    
    /// Retries queued uploads (e.g. after failed network). Safe to call anytime.
    func flushPendingUploads() {
        uploadQueue.async { [weak self] in self?.flush() }
    }
    
    func flush() {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        var q = dedupeQueuePayloads(loadQueue())
        q.removeAll(where: { self.isAlreadyDelivered($0) })
        saveQueue(q)
        guard !q.isEmpty else { return }
        let endpoint = AppConfiguration.shared.apiEndpoint
        var remaining: [Data] = []
        
        while !q.isEmpty {
            let payload = q.removeFirst()
            // At-most-once semantics by result_id: once we attempt an assessment payload,
            // prevent it from being replayed on later task completions.
            markDelivered(payload)
            var req = URLRequest(url: URL(string: endpoint)!)
            req.httpMethod = "POST"
            // Signed headers (HMAC over nonce+timestamp+body)
            if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
                let nonce = UUID().uuidString
                let ts = String(Int(Date().timeIntervalSince1970))
                var toSign = Data()
                toSign.append(Data(nonce.utf8))
                toSign.append(Data(ts.utf8))
                toSign.append(payload)
                let sig = hmacSHA256Hex(key: token, data: toSign)
                req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
                req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
                req.setValue(sig, forHTTPHeaderField: "X-Signature")
            }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload
            
            let sem = DispatchSemaphore(value: 0)
            Self.ingestURLSession.dataTask(with: req) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let okStatus = (200..<400).contains(code)
                let bodyAccepted = Self.responseBodyIndicatesAccepted(data)
                // Some redirect/cookie edge-cases can surface a URLSession error even when
                // Apps Script already accepted the POST. Prefer server evidence over transport error.
                let ok = okStatus || bodyAccepted
                if !ok {
                    // Keep retry only for payloads without a stable result_id.
                    if self.normalizedResultID(from: payload) == nil {
                        remaining.append(payload)
                    }
                }
                self.recordIngestResult(context: "flush_assessment", status: code, data: data, error: err)
                sem.signal()
            }.resume()
            sem.wait()
        }
        saveQueue(dedupeQueuePayloads(remaining))
    }
    
    private func loadQueue() -> [Data] {
        (UserDefaults.standard.array(forKey: queueKey) as? [Data]) ?? []
    }
    private func saveQueue(_ q: [Data]) {
        UserDefaults.standard.set(q, forKey: queueKey)
    }
    
    /// Emergency control for stale/backlogged retries.
    func clearPendingUploads() {
        UserDefaults.standard.removeObject(forKey: queueKey)
        uploadQueue.async { [weak self] in
            self?.saveQueue([])
        }
    }
    
    // Minimal AE alert webhook (reuses same endpoint)
    func sendAEAlert(studyID: String, category: String) {
        let payload: [String: Any] = [
            "type": "ae_alert",
            "study_id": studyID,
            "category": category,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        var req = URLRequest(url: URL(string: AppConfiguration.shared.apiEndpoint)!)
        req.httpMethod = "POST"
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
            let nonce = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            var toSign = Data()
            toSign.append(Data(nonce.utf8))
            toSign.append(Data(ts.utf8))
            toSign.append(body)
            let sig = hmacSHA256Hex(key: token, data: toSign)
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Signature")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Self.ingestURLSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            self.recordIngestResult(context: "ae_alert", status: code, data: data, error: err)
        }.resume()
    }
    // AE alert with urgency
    func sendAEAlert(studyID: String, category: String, urgency: String) {
        let payload: [String: Any] = [
            "type": "ae_alert",
            "study_id": studyID,
            "category": category,
            "urgency": urgency,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        var req = URLRequest(url: URL(string: AppConfiguration.shared.apiEndpoint)!)
        req.httpMethod = "POST"
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
            let nonce = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            var toSign = Data()
            toSign.append(Data(nonce.utf8))
            toSign.append(Data(ts.utf8))
            toSign.append(body)
            let sig = hmacSHA256Hex(key: token, data: toSign)
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Signature")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Self.ingestURLSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            self.recordIngestResult(context: "ae_alert_urgent", status: code, data: data, error: err)
        }.resume()
    }
    
    /// One row per calendar month when motor + PRO + cognitive are all done (PULSE). Same Google Apps Script `doPost` as other events—extend script to handle `type: monthly_core_trio_complete`.
    func sendMonthlyCoreTrioComplete(studyID: String, trial: String, monthLabel: String) {
        let payload: [String: Any] = [
            "type": "monthly_core_trio_complete",
            "study_id": studyID,
            "trial": trial,
            "month": monthLabel,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        var req = URLRequest(url: URL(string: AppConfiguration.shared.apiEndpoint)!)
        req.httpMethod = "POST"
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if let token = KeychainManager.shared.loadIngestToken(), !token.isEmpty {
            let nonce = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            var toSign = Data()
            toSign.append(Data(nonce.utf8))
            toSign.append(Data(ts.utf8))
            toSign.append(body)
            let sig = hmacSHA256Hex(key: token, data: toSign)
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            req.setValue(sig, forHTTPHeaderField: "X-Signature")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Self.ingestURLSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            self.recordIngestResult(context: "monthly_core_trio", status: code, data: data, error: err)
        }.resume()
    }
}

// MARK: - Location proximity helper (free: Apple geocoder + OSM Overpass)
enum GoogleMapsService {
    enum ServiceError: LocalizedError {
        case badURL
        case network(String)
        case geocodeDenied
        case geocodeNotFound
        case placesStatus(String)
        case noGolfCoursesFound

        var statusKey: String {
            switch self {
            case .badURL: return "bad_url"
            case .network: return "network_error"
            case .geocodeDenied: return "geocode_denied"
            case .geocodeNotFound: return "geocode_zero_results"
            case .placesStatus(let s): return "places_\(s.lowercased())"
            case .noGolfCoursesFound: return "places_zero_results"
            }
        }

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid location request URL."
            case .network(let message):
                return "Network error: \(message)"
            case .geocodeDenied:
                return "Address lookup denied by Apple geocoder."
            case .geocodeNotFound:
                return "Address not found. Try a more complete address."
            case .placesStatus(let status):
                return "Golf proximity lookup failed (\(status))."
            case .noGolfCoursesFound:
                return "No nearby golf course found for this location."
            }
        }
    }

    private struct OverpassResponse: Decodable {
        struct Element: Decodable {
            struct Center: Decodable { let lat: Double; let lon: Double }
            let lat: Double?
            let lon: Double?
            let center: Center?
            let tags: [String: String]?
        }
        let elements: [Element]
    }

    static func geocode(address: String, apiKey _: String, completion: @escaping (Result<(Double, Double), Error>) -> Void) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { placemarks, error in
            if let clErr = error as? CLError {
                switch clErr.code {
                case .geocodeFoundNoResult:
                    completion(.failure(ServiceError.geocodeNotFound))
                case .network:
                    completion(.failure(ServiceError.network(clErr.localizedDescription)))
                default:
                    completion(.failure(ServiceError.geocodeDenied))
                }
                return
            }
            if let error {
                completion(.failure(ServiceError.network(error.localizedDescription)))
                return
            }
            guard let loc = placemarks?.first?.location?.coordinate else {
                completion(.failure(ServiceError.geocodeNotFound))
                return
            }
            completion(.success((loc.latitude, loc.longitude)))
        }
    }

    static func nearestGolfCourse(lat: Double, lng: Double, apiKey _: String, completion: @escaping (Result<(String, Double), Error>) -> Void) {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
            completion(.failure(ServiceError.badURL)); return
        }

        let radiusMeters = 25000
        let query = """
        [out:json][timeout:20];
        (
          node["leisure"="golf_course"](around:\(radiusMeters),\(lat),\(lng));
          way["leisure"="golf_course"](around:\(radiusMeters),\(lat),\(lng));
          relation["leisure"="golf_course"](around:\(radiusMeters),\(lat),\(lng));
        );
        out center;
        """

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(query.utf8)

        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                completion(.failure(ServiceError.network(err.localizedDescription)))
                return
            }
            guard let data else {
                completion(.failure(ServiceError.network("Empty Overpass response")))
                return
            }
            guard let decoded = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
                completion(.failure(ServiceError.placesStatus("invalid_response")))
                return
            }

            var bestName = ""
            var bestKm = Double.greatestFiniteMagnitude

            for e in decoded.elements {
                let point: (Double, Double)?
                if let lat = e.lat, let lon = e.lon {
                    point = (lat, lon)
                } else if let c = e.center {
                    point = (c.lat, c.lon)
                } else {
                    point = nil
                }
                guard let p = point else { continue }
                let dKm = haversineKm(lat1: lat, lon1: lng, lat2: p.0, lon2: p.1)
                if dKm < bestKm {
                    bestKm = dKm
                    bestName = e.tags?["name"] ?? "Unnamed golf course"
                }
            }

            guard bestKm.isFinite else {
                completion(.failure(ServiceError.noGolfCoursesFound))
                return
            }
            completion(.success((bestName, bestKm)))
        }.resume()
    }

    private static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi/180) * cos(lat2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }
}

// MARK: - Export
enum ExportManager {
    static func exportAssessments(_ items: [AssessmentResult]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(items)
        let safeTs = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PULSE-PD_Export_\(safeTs).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
// MARK: - App State
final class AppViewModel: ObservableObject {
    @AppStorage("pd_tracker_consent") var consentGiven: Bool = false
    @Published var studyID: String = ""
    @Published var participant = ParticipantInfo()
    let historyStore = HistoryStore()
    @AppStorage("pd_trial") private var trialStored: String = "PULSE-PD"
    @AppStorage("needs_baseline") var needsBaseline: Bool = false
    @AppStorage("custom_motor") var customMotorTestsRaw: String = ""
    @AppStorage("custom_cognitive") var customCognitiveTestsRaw: String = ""
    // Daily quote storage
    @AppStorage("daily_quote_last_date") var lastQuoteDate: String = ""
    @AppStorage("daily_quote_text") var lastQuoteText: String = ""
    enum Trial: String, Codable, CaseIterable { case pulsePD = "PULSE-PD", ascendSVD = "ASCEND-SVD", personal = "Personal", custom = "Custom" }
    var trial: Trial {
        get { Trial(rawValue: trialStored) ?? .pulsePD }
        set { trialStored = newValue.rawValue }
    }
    
    static let allMotorTests = ["Blink Rate", "Reaction Time", "Tapping3", "Voice", "Tremor", "Balance"]
    static let allCognitiveTestIds = ["MCQ", "Stroop", "TrailMakingA", "TrailMakingB", "DigitSpan", "Flanker"]
    var customMotorTests: [String] { customMotorTestsRaw.isEmpty ? Self.allMotorTests : customMotorTestsRaw.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
    var customCognitiveTests: [String] { customCognitiveTestsRaw.isEmpty ? Self.allCognitiveTestIds : customCognitiveTestsRaw.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
    func setCustomMotorTests(_ ids: [String]) { customMotorTestsRaw = ids.joined(separator: ",") }
    func setCustomCognitiveTests(_ ids: [String]) { customCognitiveTestsRaw = ids.joined(separator: ",") }
    
    init() {
        if let id = KeychainManager.shared.loadStudyID(), !id.isEmpty, (id == "PERSONAL" || id == "CUSTOM" || (id.count >= 6 && id.count <= 10 && id.allSatisfy { $0.isNumber })) {
            self.studyID = id
            self.consentGiven = true
        }
    }
    
    func enroll(studyID: String) -> Bool {
        let trimmed = studyID.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 && trimmed.count <= 10, trimmed.allSatisfy({ $0.isNumber }) else { return false }
        if KeychainManager.shared.saveStudyID(trimmed) {
            self.studyID = trimmed
            self.consentGiven = true
            ReminderManager.applyUserPreferenceForMonthlyCheckIn()
            return true
        }
        return false
    }
    
    func enrollPersonal() {
        _ = KeychainManager.shared.saveStudyID("PERSONAL")
        studyID = "PERSONAL"
        consentGiven = true
        needsBaseline = false
        ReminderManager.applyUserPreferenceForMonthlyCheckIn()
    }
    
    func enrollCustom(studyID customID: String? = nil) {
        let id = (customID?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "CUSTOM"
        _ = KeychainManager.shared.saveStudyID(id)
        studyID = id
        consentGiven = true
        ReminderManager.applyUserPreferenceForMonthlyCheckIn()
    }
    
    func saveAssessment(_ assessment: AssessmentResult) {
        historyStore.save(assessment)
        if trial != .personal { NetworkService.shared.enqueue(assessment) }
    }
    
    func todayString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
    
    func pickDailyQuoteIfNeeded() -> String? {
        let today = todayString()
        if lastQuoteDate == today, !lastQuoteText.isEmpty { return nil }
        let q = QuoteManager.randomQuote()
        lastQuoteText = q
        lastQuoteDate = today
        return q
    }
    
    func resetEnrollment() {
        KeychainManager.shared.deleteStudyID()
        studyID = ""
        consentGiven = false
        participant = ParticipantInfo()
        historyStore.clearAll()
        NetworkService.shared.clearPendingUploads()
    }
}

// MARK: - Utilities / Common Metadata
func playChime() { AudioServicesPlaySystemSound(1005) }
func playShortChime() { AudioServicesPlaySystemSound(1104) }
func onMain(_ work: @escaping () -> Void) {
    Thread.isMainThread ? work() : DispatchQueue.main.async(execute: work)
}

func isValidStudyID(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 6 && trimmed.count <= 10 && trimmed.allSatisfy { $0.isNumber }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

func isCameraAvailableForBlink() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    #endif
}

func deviceMeta(task: String, taskVersion: String, start: Date, end: Date, studyID: String) -> [String: String] {
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    let model = UIDevice.current.model
    let ios = UIDevice.current.systemVersion
    let trial = UserDefaults.standard.string(forKey: "pd_trial") ?? "PULSE-PD"
    let iso = ISO8601DateFormatter()
    return [
        "study_id": studyID,
        "trial": trial,
        "app_version": appVersion,
        "build_number": build,
        "device_model": model,
        "ios_version": ios,
        "task_name": task,
        "task_version": taskVersion,
        "timestamp_start": iso.string(from: start),
        "timestamp_end": iso.string(from: end),
        "duration_sec": String(Int(end.timeIntervalSince(start)))
    ]
}

// MARK: - Story Generator (kept)
struct StoryGenerator {
    struct Story {
        let text: String
        let name: String
        let address: String
        let city: String
        let occupation: String
    }
    static let names1 = ["John Smith", "Sarah Johnson", "Michael Williams", "Emily Brown", "David Jones"]
    static let names2 = ["Lisa Garcia", "Robert Miller", "Jennifer Davis", "William Rodriguez", "Jessica Martinez"]
    static let addresses1 = ["42 Oak Street", "15 Maple Avenue", "88 Cedar Road", "23 Pine Lane", "67 Elm Drive"]
    static let addresses2 = ["91 Birch Court", "34 Willow Place", "56 Ash Way", "12 Cherry Street", "78 Walnut Avenue"]
    static let cities1 = ["Chicago", "Boston", "Seattle", "Denver", "Portland"]
    static let cities2 = ["Austin", "Phoenix", "Atlanta", "Dallas", "Miami"]
    static let jobs1 = ["teacher", "engineer", "nurse", "accountant", "lawyer"]
    static let jobs2 = ["artist", "chef", "architect", "dentist", "pharmacist"]
    
    static let storyTemplates: [(String, String, String, String, String) -> String] = [
        { name, address, city, occupation, firstName in "\(name) is a \(occupation) who lives at \(address) in \(city). Last week, \(firstName) went to the grocery store." },
        { name, address, city, occupation, firstName in "\(name), a \(occupation), lives at \(address) in \(city). Yesterday \(firstName) visited the doctor for a checkup." },
        { name, address, city, occupation, firstName in "\(name) is a \(occupation) who resides at \(address) in \(city). On Saturday, \(firstName) took a walk in the local park." },
        { name, address, city, occupation, firstName in "\(name) works as a \(occupation) and lives at \(address) in \(city). Last night, \(firstName) had dinner at a restaurant downtown." },
        { name, address, city, occupation, firstName in "\(name), a \(occupation) from \(address) in \(city), went to the public library yesterday. \(firstName) borrowed two books." },
        { name, address, city, occupation, firstName in "\(name) is a \(occupation) who lives at \(address) in \(city). This morning \(firstName) stopped at the coffee shop before work." },
        { name, address, city, occupation, firstName in "\(name), a \(occupation), resides at \(address) in \(city). On Monday, \(firstName) went to the gym for an hour." },
        { name, address, city, occupation, firstName in "\(name) is a \(occupation) who lives at \(address) in \(city). Last week \(firstName) picked up a prescription at the pharmacy." }
    ]
    
    static func generateRandomStory() -> Story {
        let allNames = names1 + names2
        let allAddresses = addresses1 + addresses2
        let allCities = cities1 + cities2
        let allJobs = jobs1 + jobs2
        let name = allNames.randomElement()!
        let address = allAddresses.randomElement()!
        let city = allCities.randomElement()!
        let occupation = allJobs.randomElement()!
        let firstName = name.components(separatedBy: " ").first!
        let story = storyTemplates.randomElement()!(name, address, city, occupation, firstName)
        return Story(text: story, name: name, address: address, city: city, occupation: occupation)
    }
}

// MARK: - Study Picker
struct StudySelectionView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Select Study") {
                    Button {
                        vm.trial = .pulsePD; dismiss()
                    } label: {
                        HStack { Text("PULSE-PD"); if vm.trial == .pulsePD { Spacer(); Image(systemName:"checkmark") } }
                    }
                    Button {
                        vm.trial = .ascendSVD; dismiss()
                    } label: {
                        HStack { Text("ASCEND-SVD"); if vm.trial == .ascendSVD { Spacer(); Image(systemName:"checkmark") } }
                    }
                    Button {
                        vm.trial = .personal; dismiss()
                    } label: {
                        HStack { Text("Personal (at-home use)"); if vm.trial == .personal { Spacer(); Image(systemName:"checkmark") } }
                    }
                    Button {
                        vm.trial = .custom; dismiss()
                    } label: {
                        HStack { Text("Custom"); if vm.trial == .custom { Spacer(); Image(systemName:"checkmark") } }
                    }
                }
                Section("About") {
                    Text("This app supports multiple studies. Your current selection customizes the assessment battery and data exports.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Study Selection")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - SVD Safety Screen
struct SVDSafetyView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bleeding = false
    @State private var headaches = false
    @State private var hypoglycemia = false
    @State private var falls = false
    @State private var vision = false
    @State private var abdominal = false
    @State private var notes = ""
    @State private var started = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section("Past month, did you experience any of the following?") {
                    Toggle("Bleeding (GI bleed, symptomatic hemorrhage)", isOn: $bleeding)
                    Toggle("Severe headaches", isOn: $headaches)
                    Toggle("Low blood sugar symptoms", isOn: $hypoglycemia)
                    Toggle("Falls", isOn: $falls)
                    Toggle("Vision changes", isOn: $vision)
                    Toggle("Abdominal pain", isOn: $abdominal)
                }
                Section("Notes (optional)") {
                    TextField("Add details…", text: $notes, axis: .vertical).lineLimit(2...4)
                }
                Button("Submit and View Report") { submit() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth:.infinity)
            }
            .navigationTitle("SVD Safety")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { started = Date() }
    }
    private func submit() {
        let end = Date()
        var data: [String:String] = [
            "bleeding": "\(bleeding)",
            "headaches": "\(headaches)",
            "hypoglycemia": "\(hypoglycemia)",
            "falls": "\(falls)",
            "vision_changes": "\(vision)",
            "abdominal_pain": "\(abdominal)"
        ]
        let trim = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trim.isEmpty { data["notes"] = trim }
        data.merge(deviceMeta(task: "SVD-Safety", taskVersion: "1.0", start: started, end: end, studyID: studyID)) { _, n in n }
        // Alert routing
        if bleeding { NetworkService.shared.sendAEAlert(studyID: studyID, category: "bleeding", urgency: "urgent") }
        if hypoglycemia { NetworkService.shared.sendAEAlert(studyID: studyID, category: "hypoglycemia", urgency: "urgent") }
        if vision { NetworkService.shared.sendAEAlert(studyID: studyID, category: "vision_changes", urgency: "urgent") }
        if abdominal { NetworkService.shared.sendAEAlert(studyID: studyID, category: "abdominal_pain", urgency: "urgent") }
        if headaches || falls { NetworkService.shared.sendAEAlert(studyID: studyID, category: headaches ? "headaches" : "falls", urgency: "routine") }
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "SVD-Safety", data: data, notes: nil)
        onComplete(res); dismiss()
    
    }
}
// MARK: - ASCEND-SVD Cognitive Battery
struct SVDCognitiveBatteryView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    @State private var step = 0
    @State private var started = Date()
    @State private var interim: [AssessmentResult] = []
    
    var body: some View {
        NavigationStack {
            VStack {
                if step == 0 {
                    StroopTestView(studyID: studyID, allowSkip: false) { r in next(with: r) }
                } else if step == 1 {
                    TrailMakingTestView(studyID: studyID, mode: .a, allowSkip: false) { r in next(with: r) }
                } else if step == 2 {
                    TrailMakingTestView(studyID: studyID, mode: .b, allowSkip: false) { r in next(with: r) }
                } else if step == 3 {
                    DigitSpanTestView(studyID: studyID, allowSkip: false) { r in next(with: r) }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName:"checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                        Text("Cognitive Battery Complete").font(.title3).fontWeight(.semibold)
                        Button("Done") { onComplete(summaryResult()) }.buttonStyle(.borderedProminent)
                    }.padding()
                }
            }
            .navigationTitle("ASCEND-SVD Cognitive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Cancel") { onComplete(summaryResult()) } } }
        }
        .onAppear { started = Date() }
    }
    
    private func next(with r: AssessmentResult) {
        interim.append(r); step += 1
    }
    private func summaryResult() -> AssessmentResult {
        let end = Date()
        var data: [String:String] = [
            "stroop_acc": interim.first(where: {$0.assessmentType=="Stroop"})?.data["accuracy"] ?? "",
            "stroop_mean_rt_ms": interim.first(where: {$0.assessmentType=="Stroop"})?.data["mean_rt_ms"] ?? "",
            "tmt_a_sec": interim.first(where: {$0.assessmentType=="TrailMakingA"})?.data["duration_sec"] ?? "",
            "tmt_a_errors": interim.first(where: {$0.assessmentType=="TrailMakingA"})?.data["errors"] ?? "",
            "tmt_b_sec": interim.first(where: {$0.assessmentType=="TrailMakingB"})?.data["duration_sec"] ?? "",
            "tmt_b_errors": interim.first(where: {$0.assessmentType=="TrailMakingB"})?.data["errors"] ?? "",
            "digitspan_forward": interim.first(where: {$0.assessmentType=="DigitSpan"})?.data["forward_max"] ?? "",
            "digitspan_backward": interim.first(where: {$0.assessmentType=="DigitSpan"})?.data["backward_max"] ?? ""
        ]
        data.merge(deviceMeta(task: "SVD-Cognitive", taskVersion: "1.0", start: started, end: end, studyID: studyID)) { _, n in n }
        return AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "SVD-Cognitive", data: data, notes: "Composite")
    }
}

// MARK: Stroop
struct StroopTestView: View {
    let studyID: String
    let allowSkip: Bool
    /// When false (e.g. embedded in full battery), only `onComplete` runs—no sheet dismiss.
    var dismissOnComplete: Bool = true
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    private let colors: [(String, Color)] = [("RED", .red), ("GREEN", .green), ("BLUE", .blue), ("YELLOW", .yellow)]
    /// Word shown, ink color, ink color name (tap target), congruent if word matches ink
    @State private var trials: [(label: String, ink: Color, inkName: String, congruent: Bool)] = []
    @State private var current = 0
    @State private var startTime = Date()
    @State private var taskStarted = Date()
    @State private var rts: [Double] = []
    @State private var correct = 0
    @State private var showIntro = true
    @State private var consecutiveWordInsteadOfInk = 0
    @State private var showWordReminderAlert = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Stroop").font(.largeTitle).fontWeight(.bold)
                if showIntro {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Instructions").font(.title2).fontWeight(.bold)
                    Text("You will see color WORDS printed in colored ink.")
                        .font(.title3)
                    Text("Tap the INK COLOR — ignore the WORD.")
                        .font(.title3).fontWeight(.semibold)
                    Text("Example: The word “BLUE” printed in RED ink → tap Red.")
                        .font(.body)
                }
                .padding(16)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(12)
                Button("Start") {
                    showIntro = false
                    generateTrials()
                    taskStarted = Date()
                    startTime = Date()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else if current < trials.count {
                let t = trials[current]
                Text(t.label)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(t.ink)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .cornerRadius(12)
                    .padding(.top, 20)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                     GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(colors, id:\.0) { c in
                        Button(action: { tapped(c.0) }) {
                            Text(c.0)
                                .font(.title2).fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .foregroundStyle(Color.white)
                                .background(Color.black)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white, lineWidth: 3)
                                )
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            } else {
                EmptyView()
            }
        }
        .padding()
        .onAppear { /* wait for Start */ }
        .toolbar {
            if allowSkip {
                ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } }
            }
        }
        .alert("Tap the ink color", isPresented: $showWordReminderAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("CHOOSE THE MATCHING COLOR, NOT THE MATCHING WORD. Tap the color of the ink you see, not what the letters spell.")
        }
        }
    }
    private func generateTrials() {
        var arr: [(String, Color, String, Bool)] = []
        for _ in 0..<30 {
            let word = colors.randomElement()!
            let ink = colors.randomElement()!
            arr.append((word.0, ink.1, ink.0, word.0 == ink.0))
        }
        trials = arr
    }
    private func tapped(_ answer: String) {
        let t = trials[current]
        let rt = Date().timeIntervalSince(startTime) * 1000.0
        rts.append(rt)
        let inkCorrect = answer == t.inkName
        if inkCorrect {
            correct += 1
            consecutiveWordInsteadOfInk = 0
        } else {
            let pickedWordNotInk = (answer == t.label && t.label != t.inkName)
            if pickedWordNotInk {
                consecutiveWordInsteadOfInk += 1
                if consecutiveWordInsteadOfInk > 2 {
                    showWordReminderAlert = true
                    consecutiveWordInsteadOfInk = 0
                }
            } else {
                consecutiveWordInsteadOfInk = 0
            }
        }
        current += 1
        startTime = Date()
        if current >= trials.count {
            finish()
        }
    }
    private func finish() {
        let end = Date()
        let acc = trials.isEmpty ? 0.0 : (Double(correct) / Double(trials.count))
        let mean = rts.isEmpty ? 0.0 : (rts.reduce(0,+)/Double(rts.count))
        var data:[String:String] = [
            "trials":"\(trials.count)",
            "accuracy": String(format:"%.2f", acc),
            "mean_rt_ms": String(format:"%.0f", mean)
        ]
        data.merge(deviceMeta(task:"Stroop", taskVersion:"1.0", start:taskStarted, end:end, studyID: studyID)) {_,n in n}
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Stroop", data: data, notes: nil)
        onComplete(res)
        if dismissOnComplete { dismiss() }
    }
}

// MARK: Trail Making (drag to connect)
struct TrailMakingTestView: View {
    enum Mode { case a, b }
    struct Node: Identifiable {
        let id: Int
        let label: String
        let position: CGPoint
    }
    let studyID: String
    let mode: Mode
    let allowSkip: Bool
    var dismissOnComplete: Bool = true
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var nodes: [Node] = []
    @State private var index = 0
    @State private var errors = 0
    @State private var started = Date()
    @State private var wrongHit: Set<Int> = []
    
    private let hitRadius: CGFloat = 36
    private let minSpacing: CGFloat = 64
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Trail Making \(mode == .a ? "A" : "B")").font(.title2).fontWeight(.bold)
                VStack(spacing: 6) {
                if mode == .a {
                    Text("Drag from 1 → 2 → … → 12").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Drag: 1 → A → 2 → B → … → 6 → F (alternating number, letter)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack {
                    // Draw lines between completed nodes
                    Path { path in
                        guard !nodes.isEmpty else { return }
                        if index > 0 {
                            let pts = (0..<index).map { nodes[$0].position }
                            if let first = pts.first {
                                path.move(to: first)
                                for p in pts.dropFirst() { path.addLine(to: p) }
                            }
                        }
                    }
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    
                    // Draw nodes
                    ForEach(Array(nodes.enumerated()), id:\.1.id) { (i, n) in
                        let isDone = i < index
                        ZStack {
                            Circle()
                                .fill(isDone ? Color.green.opacity(0.85) : Color.black)
                                .overlay(
                                    Circle()
                                        .stroke(Color.gray.opacity(0.6), lineWidth: 1.5)
                                )
                                .frame(width: 64, height: 64)
                            Text(n.label)
                                .font(.title2).fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                        .position(n.position)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    handleDrag(location: value.location, in: geo.size)
                })
                .onAppear {
                    started = Date()
                    syncNodesIfNeeded(geo.size, force: true)
                }
                .onChange(of: geo.size) { _, newSize in
                    syncNodesIfNeeded(newSize, force: false)
                }
            }
            .frame(height: 360)
        }
        .padding()
        .toolbar {
            if allowSkip {
                ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } }
            }
        }
        }
    }
    
    private func nextLabel() -> String? {
        guard index < nodes.count else { return nil }
        if mode == .a { return "\(index + 1)" }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").prefix(6).map { String($0) }
        _ = (1...6).map { "\($0)" }
        return index % 2 == 0 ? "\(index/2 + 1)" : letters[index/2]
    }
    
    private func expectedCount() -> Int { nodes.count }
    
    /// Regenerate layout when GeometryReader reports a valid size (avoids all nodes at `.zero` on first layout).
    private func syncNodesIfNeeded(_ size: CGSize, force: Bool) {
        guard index == 0 else { return }
        let inset: CGFloat = 40
        let minW = 2 * inset + 1
        let minH = 2 * inset + 1
        guard size.width >= minW, size.height >= minH else { return }
        let next = generateNodes(in: size)
        if next.isEmpty { return }
        if force || nodes.isEmpty || nodesAreDegenerate(nodes) || nodes.count != next.count {
            nodes = next
        }
    }
    
    private func nodesAreDegenerate(_ list: [Node]) -> Bool {
        guard list.count > 1 else { return true }
        if list.allSatisfy({ $0.position == .zero }) { return true }
        let distinct = Set(list.map { $0.position })
        return distinct.count < list.count
    }
    
    private func generateNodes(in size: CGSize) -> [Node] {
        // Build ordered labels
        let labels: [String]
        if mode == .a {
            labels = (1...12).map { "\($0)" }
        } else {
            let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").prefix(6).map { String($0) }
            var tmp: [String] = []
            for i in 0..<6 { tmp.append("\(i+1)"); tmp.append(letters[i]) }
            labels = tmp
        }
        let inset: CGFloat = 40
        let minW = 2 * inset + 1
        let minH = 2 * inset + 1
        guard size.width >= minW, size.height >= minH else { return [] }
        let w = size.width
        let h = size.height
        var placed: [CGPoint] = []
        let maxTries = 2000
        var tries = 0
        func isFar(_ p: CGPoint) -> Bool {
            placed.allSatisfy { hypot($0.x - p.x, $0.y - p.y) >= minSpacing }
        }
        while placed.count < labels.count && tries < maxTries {
            tries += 1
            let x = CGFloat.random(in: inset...(w - inset))
            let y = CGFloat.random(in: inset...(h - inset))
            let p = CGPoint(x: x, y: y)
            if isFar(p) { placed.append(p) }
        }
        if placed.count < labels.count {
            placed = []
            let cols = 4, rows = 3
            let denomX = CGFloat(max(cols - 1, 1))
            let denomY = CGFloat(max(rows - 1, 1))
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = inset + CGFloat(c) * ((w - 2 * inset) / denomX)
                    let y = inset + CGFloat(r) * ((h - 2 * inset) / denomY)
                    placed.append(CGPoint(x: x, y: y))
                }
            }
        }
        return labels.enumerated().map { Node(id: $0.offset, label: $0.element, position: placed[$0.offset]) }
    }
    
    private func handleDrag(location: CGPoint, in size: CGSize) {
        guard index < nodes.count else { return }
        let nextNode = nodes[index]
        let dNext = hypot(location.x - nextNode.position.x, location.y - nextNode.position.y)
        if dNext <= hitRadius {
            let gen = UIImpactFeedbackGenerator(style: .light); gen.impactOccurred()
            index += 1
            wrongHit.removeAll()
            if index >= expectedCount() {
                finish()
            }
            return
        }
        // Wrong contact detection (single count per node)
        if let wrongIdx = nodes.firstIndex(where: { iNode in
            let d = hypot(location.x - iNode.position.x, location.y - iNode.position.y)
            return d <= hitRadius && iNode.id != nextNode.id && !wrongHit.contains(iNode.id)
        }) {
            wrongHit.insert(nodes[wrongIdx].id)
            let gen = UINotificationFeedbackGenerator(); gen.notificationOccurred(.warning)
            errors += 1
        }
    }
    
    private func finish() {
        let end = Date()
        let dur = end.timeIntervalSince(started)
        var data = [
            "duration_sec": String(format:"%.1f", dur),
            "errors": "\(errors)"
        ]
        let type = mode == .a ? "TrailMakingA" : "TrailMakingB"
        data.merge(deviceMeta(task: type, taskVersion: "1.0", start: started, end: end, studyID: studyID)) {_,n in n}
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: type, data: data, notes: nil)
        onComplete(res)
        if dismissOnComplete { dismiss() }
    }
}

// MARK: Digit Span (forward/backward max)
struct DigitSpanTestView: View {
    let studyID: String
    let allowSkip: Bool
    var dismissOnComplete: Bool = true
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase = "forward"
    @State private var currentSeq:[Int] = []
    @State private var input:String = ""
    @State private var forwardMax = 0
    @State private var backwardMax = 0
    @State private var started = Date()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Digit Span (\(phase))").font(.title2).fontWeight(.bold)
                if !currentSeq.isEmpty {
                Text(currentSeq.map(String.init).joined(separator:" ")).font(.title3).monospacedDigit()
                TextField("Repeat the sequence", text: $input).textFieldStyle(.roundedBorder)
                Button("Submit and View Report") { submit() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { started = Date(); nextSequence() }
        .toolbar {
            if allowSkip {
                ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } }
            }
        }
        }
    }
    private func nextSequence() {
        let len = (phase == "forward" ? max(forwardMax, 2) : max(backwardMax, 2)) + 1
        currentSeq = (0..<len).map { _ in Int.random(in: 0...9) }
        input = ""
    }
    private func submit() {
        let target = phase == "forward" ? currentSeq : currentSeq.reversed()
        let ans = input.trimmingCharacters(in: .whitespaces).compactMap { Int(String($0)) }
        if ans == target {
            if phase == "forward" { forwardMax = max(forwardMax, currentSeq.count) }
            else { backwardMax = max(backwardMax, currentSeq.count) }
            if phase == "forward" && forwardMax >= 7 { phase = "backward" }
            else if phase == "backward" && backwardMax >= 6 { finish() }
            nextSequence()
        } else {
            // one failure ends that direction
            if phase == "forward" { phase = "backward" } else { finish() }
            nextSequence()
        }
    }
    private func finish() {
        let end = Date()
        var data = [
            "forward_max": "\(forwardMax)",
            "backward_max": "\(backwardMax)"
        ]
        data.merge(deviceMeta(task: "DigitSpan", taskVersion: "1.0", start: started, end: end, studyID: studyID)) {_,n in n}
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "DigitSpan", data: data, notes: nil)
        onComplete(res)
        if dismissOnComplete { dismiss() }
    }
}
// MARK: Flanker
struct FlankerTestView: View {
    let studyID: String
    let allowSkip: Bool
    var dismissOnComplete: Bool = true
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    private let leftArrow = "\u{2190}"
    private let rightArrow = "\u{2192}"
    @State private var trials: [(centerLeft: Bool, congruent: Bool)] = []
    @State private var current = 0
    @State private var startTime = Date()
    @State private var taskStarted = Date()
    @State private var rts: [Double] = []
    @State private var correct = 0
    @State private var correctCongruent = 0
    @State private var correctIncongruent = 0
    @State private var showIntro = true
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Flanker").font(.largeTitle).fontWeight(.bold)
                if showIntro {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Instructions").font(.title2).fontWeight(.bold)
                    Text("You will see a row of 5 arrows.")
                        .font(.title3)
                    Text("Tap LEFT or RIGHT based on the direction of the CENTER arrow only.")
                        .font(.title3).fontWeight(.semibold)
                    Text("Ignore the flanking arrows on the sides.")
                        .font(.body)
                }
                .padding(16)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(12)
                Button("Start") {
                    showIntro = false
                    generateTrials()
                    taskStarted = Date()
                    startTime = Date()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else if current < trials.count {
                let t = trials[current]
                let display = displayString(centerLeft: t.centerLeft, congruent: t.congruent)
                Text(display)
                    .font(.system(size: 48, weight: .bold))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .cornerRadius(12)
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                HStack(spacing: 16) {
                    Button(action: { tapped(true) }) {
                        Text(leftArrow)
                            .font(.system(size: 36, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .foregroundStyle(.white)
                            .background(Color.black)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 3))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    Button(action: { tapped(false) }) {
                        Text(rightArrow)
                            .font(.system(size: 36, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .foregroundStyle(.white)
                            .background(Color.black)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 3))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            } else {
                EmptyView()
            }
        }
        .padding()
        .onAppear { }
        .toolbar {
            if allowSkip {
                ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } }
            }
        }
        }
    }
    
    private func displayString(centerLeft: Bool, congruent: Bool) -> String {
        if congruent {
            return centerLeft ? String(repeating: leftArrow, count: 5) : String(repeating: rightArrow, count: 5)
        } else {
            if centerLeft {
                return rightArrow + rightArrow + leftArrow + rightArrow + rightArrow
            } else {
                return leftArrow + leftArrow + rightArrow + leftArrow + leftArrow
            }
        }
    }
    
    private func generateTrials() {
        var arr: [(Bool, Bool)] = []
        for _ in 0..<12 { arr.append((Bool.random(), true)) }
        for _ in 0..<12 { arr.append((Bool.random(), false)) }
        trials = arr.shuffled()
    }
    
    private func tapped(_ answerLeft: Bool) {
        let t = trials[current]
        let rt = Date().timeIntervalSince(startTime) * 1000.0
        rts.append(rt)
        let isCorrect = (answerLeft == t.centerLeft)
        if isCorrect { correct += 1 }
        if t.congruent && isCorrect { correctCongruent += 1 }
        else if !t.congruent && isCorrect { correctIncongruent += 1 }
        current += 1
        startTime = Date()
        if current >= trials.count {
            finish()
        }
    }
    
    private func finish() {
        let end = Date()
        let acc = trials.isEmpty ? 0.0 : (Double(correct) / Double(trials.count))
        let mean = rts.isEmpty ? 0.0 : (rts.reduce(0, +) / Double(rts.count))
        let congruentTotal = trials.filter { $0.congruent }.count
        let incongruentTotal = trials.filter { !$0.congruent }.count
        let congruentAcc = congruentTotal > 0 ? Double(correctCongruent) / Double(congruentTotal) : 0.0
        let incongruentAcc = incongruentTotal > 0 ? Double(correctIncongruent) / Double(incongruentTotal) : 0.0
        var data: [String: String] = [
            "trials": "\(trials.count)",
            "accuracy": String(format: "%.2f", acc),
            "mean_rt_ms": String(format: "%.0f", mean),
            "congruent_accuracy": String(format: "%.2f", congruentAcc),
            "incongruent_accuracy": String(format: "%.2f", incongruentAcc)
        ]
        data.merge(deviceMeta(task: "Flanker", taskVersion: "1.0", start: taskStarted, end: end, studyID: studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Flanker", data: data, notes: nil)
        onComplete(res)
        if dismissOnComplete { dismiss() }
    }
}

// MARK: - Root View
struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    
    var body: some View {
        Group {
            if vm.consentGiven && (!vm.studyID.isEmpty || vm.trial == .personal) {
                HomeView()
            } else {
                EnrollmentStartView(vm: vm)
            }
        }
        .environmentObject(vm)
    }
}

// MARK: - Consent View (lightweight; replace with IRB eConsent if needed)
struct EnrollmentStartView: View {
    @ObservedObject var vm: AppViewModel
    @State private var selected: AppViewModel.Trial
    @State private var showConsent = false
    @State private var showConfig = false
    init(vm: AppViewModel) {
        self.vm = vm
        _selected = State(initialValue: vm.trial)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Select Study").font(.title2).fontWeight(.bold).padding(.top, 40)
                VStack(spacing: 12) {
                    Button {
                        selected = .pulsePD
                    } label: {
                        HStack {
                            Image(systemName: selected == .pulsePD ? "largecircle.fill.circle" : "circle")
                            Text("PULSE-PD")
                            Spacer()
                        }
                    }.buttonStyle(.bordered)
                    Button {
                        selected = .ascendSVD
                    } label: {
                        HStack {
                            Image(systemName: selected == .ascendSVD ? "largecircle.fill.circle" : "circle")
                            Text("ASCEND-SVD")
                            Spacer()
                        }
                    }.buttonStyle(.bordered)
                    Button {
                        selected = .personal
                    } label: {
                        HStack {
                            Image(systemName: selected == .personal ? "largecircle.fill.circle" : "circle")
                            Text("Personal (at-home use)")
                            Spacer()
                        }
                    }.buttonStyle(.bordered)
                    Button {
                        selected = .custom
                    } label: {
                        HStack {
                            Image(systemName: selected == .custom ? "largecircle.fill.circle" : "circle")
                            Text("Custom")
                            Spacer()
                        }
                    }.buttonStyle(.bordered)
                }.padding(.horizontal)
                
                Button("Continue") {
                    vm.trial = selected
                    if selected == .custom {
                        showConfig = true
                    } else {
                        showConsent = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                Spacer()
            }
            .navigationTitle("Welcome")
            .sheet(isPresented: $showConsent) { ConsentView(vm: vm) }
            .sheet(isPresented: $showConfig) {
                TrialConfigurationView(vm: vm) {
                    showConfig = false
                    showConsent = true
                }
            }
        }
    }
}

struct TrialConfigurationView: View {
    @ObservedObject var vm: AppViewModel
    var onComplete: () -> Void
    @State private var selectedMotor: Set<String> = Set(AppViewModel.allMotorTests)
    @State private var selectedCognitive: Set<String> = Set(AppViewModel.allCognitiveTestIds)
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Motor Tests") {
                    ForEach(AppViewModel.allMotorTests, id: \.self) { id in
                        Toggle(id, isOn: Binding(
                            get: { selectedMotor.contains(id) },
                            set: { if $0 { selectedMotor.insert(id) } else { selectedMotor.remove(id) } }
                        ))
                    }
                }
                Section("Cognitive Tests") {
                    ForEach(AppViewModel.allCognitiveTestIds, id: \.self) { id in
                        Toggle(id, isOn: Binding(
                            get: { selectedCognitive.contains(id) },
                            set: { if $0 { selectedCognitive.insert(id) } else { selectedCognitive.remove(id) } }
                        ))
                    }
                }
                Section {
                    Button("Save & Continue") {
                        vm.setCustomMotorTests(Array(selectedMotor))
                        vm.setCustomCognitiveTests(Array(selectedCognitive))
                        vm.trial = .custom
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Configure Assessment")
        }
    }
}

struct ConsentView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pd_tracker_notifications_enabled") private var notificationsEnabled = false
    @State private var accepted = false
    @State private var participantID = ""
    @State private var showBaseline = false
    @State private var errorMessage: String = ""
    
    private var isPersonal: Bool { vm.trial == .personal }
    private var isCustom: Bool { vm.trial == .custom }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    enrollmentDisclaimerCard
                    if isPersonal {
                        personalContent
                    } else if isCustom {
                        customContent
                    } else {
                        studyContent
                    }
                }
                .padding()
            }
            .navigationTitle("Enrollment & Consent")
        }
    }
    
    /// Shown for every enrollment path: what sensors/data may be used + optional notification opt-in.
    private var enrollmentDisclaimerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before you start").font(.headline)
            Text("Some tasks use the camera (blink / tremor), microphone (voice), and motion sensors (tremor, gait, balance). If you import Apple Health or air quality, the app will ask for Health and approximate location only when you start those flows. Video is processed on-device; the app does not save photos or videos to your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $notificationsEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assessment reminders").font(.subheadline)
                    Text("Optional local notifications (for example a morning check-in). You can turn this off anytime in Settings → PD Predict → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: notificationsEnabled) { _, on in
                if on {
                    ReminderManager.requestAuth()
                } else {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [ReminderManager.monthlyReminderId])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var personalContent: some View {
        Group {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.top, 40)
            Text("Personal (at-home use)")
                .font(.title)
                .fontWeight(.bold)
            Text("Your data stays on your device. No research study enrollment required.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Start Personal Use") {
                vm.enrollPersonal()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 16)
        }
    }
    
    private var customContent: some View {
        Group {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.top, 40)
            Text("Custom Assessment Battery")
                .font(.title)
                .fontWeight(.bold)
            Text("Configure your own assessment battery. You may enter an optional Study ID for data tracking, or use \"CUSTOM\" if you prefer.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            TextField("Study ID (optional)", text: $participantID)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .autocapitalization(.none)
                .padding(.horizontal)
            Button("Continue to assessments") {
                dismissKeyboard()
                vm.enrollCustom(studyID: participantID.isEmpty ? nil : participantID)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
    
    private var studyContent: some View {
        Group {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.top, 40)
            
            Text("Welcome to \(vm.trial.rawValue)")
                .font(.title)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 16) {
                Text("About This Study").font(.headline)
                if vm.trial == .pulsePD {
                            Text("PULSE-PD is a pilot study at your site (about 6 months) focused on early or prodromal Parkinson disease, including smartphone movement and symptom measures.")
                        Text("Study care").font(.headline).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Participants may be randomly assigned to daily low-dose nicotine patch use or to no study medication; details come from your study team.", systemImage: "cross.case.fill")
                            Label("In-person visits and prescribing follow your study team—not this app.", systemImage: "building.columns.fill")
                            Label("Monthly app sessions are typically about 10–15 minutes. Complete the tasks your site assigns.", systemImage: "calendar")
                        }.font(.subheadline)
                        Text("Monthly tracking in the app").font(.headline).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Motor tests (tapping ×3, tremor, gait, blink)", systemImage: "figure.walk")
                            Label("Symptom questionnaires", systemImage: "list.clipboard")
                            Label("Safety check for side effects", systemImage: "exclamationmark.shield.fill")
                        }.font(.subheadline)
                        } else {
                            Text("ASCEND-SVD is a 6-month pilot at your site for cerebral small vessel disease: clinician-directed best medical management plus daily app-guided breathing, posture, and cognitive exercises (aligned nasal smile / memory routine), with monthly check-ins. The study is open-label and single-group—not a placebo-controlled trial.")
                            Text("Study care").font(.headline).padding(.top, 8)
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Aspirin use, B12 or diet recommendations, labs, and visit schedule follow your study team—not this app.", systemImage: "cross.case.fill")
                                Label("You may be asked to complete short daily routines in the app (often about 10–20 minutes) and monthly motor, cognitive, and safety tasks.", systemImage: "iphone")
                                Label("Follow the schedule and tasks your site assigns.", systemImage: "calendar")
                            }.font(.subheadline)
                            Text("Monthly tracking in the app").font(.headline).padding(.top, 8)
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Motor tests (tapping, tremor, gait, blink, voice, balance, reaction time)", systemImage: "figure.walk")
                                Label("Cognitive battery (processing speed, executive function, working memory, attention)", systemImage: "brain.head.profile")
                                Label("Safety screen (topics per your study protocol)", systemImage: "exclamationmark.shield.fill")
                            }.font(.subheadline)
                        }
                        Text("In-app text is a short summary. Your study site’s IRB-approved consent and protocol documents are the official reference for treatment, risks, and procedures.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        Text("Important:").font(.headline).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Participation is voluntary, and you may withdraw at any time.")
                            Text("• Report serious side effects immediately.")
                            Text("• No photos or videos are stored; numeric data only.")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                    
                    VStack(spacing: 16) {
                        TextField("Study ID (6–10 digits)", text: $participantID)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .autocapitalization(.none)
                            .onChange(of: participantID) { _ in
                                if !errorMessage.isEmpty { errorMessage = "" }
                            }
                    HStack {
                        Button("Generate demo ID") {
                            participantID = generateDemoStudyID()
                            let gen = UIImpactFeedbackGenerator(style: .light); gen.impactOccurred()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                        if !errorMessage.isEmpty {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                        
                        Toggle(isOn: $accepted) {
                            Text("I understand this is a research study and agree to complete monthly assessments and report side effects.")
                                .font(.subheadline)
                        }
                        Button("Enroll in Study") {
                            dismissKeyboard()
                            if isValidStudyID(participantID) && vm.enroll(studyID: participantID) {
                                vm.consentGiven = true
                                showBaseline = true
                                let gen = UINotificationFeedbackGenerator(); gen.notificationOccurred(.success)
                            } else {
                                let gen = UINotificationFeedbackGenerator(); gen.notificationOccurred(.error)
                                errorMessage = "Please enter a 6–10 digit Study ID."
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!accepted || !isValidStudyID(participantID))
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
        }
    }
    
    private func generateDemoStudyID() -> String {
        String(Int.random(in: 100000...999999))
    }
}

// MARK: - Home View
struct HomeView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var showDemographics = false
    @State private var showNonMotor = false
    @State private var showPRO = false
    @State private var showMotor = false
    @State private var showCognitive = false
    @State private var showDose = false
    @State private var showResetConfirm = false
    @State private var showStudyPicker = false
    @State private var showSafety = false
    @State private var showHealth = false
    @State private var showQuote = false
    @State private var quoteText: String = ""
    @State private var showMedTracker = false
    @State private var showMonthlyPulseTrioCompleteAlert = false
    @State private var showSettings = false
    @State private var exportItem: ExportItem?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("Hello!").font(.title).fontWeight(.bold)
                        Text("Study ID: \(vm.studyID)").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(vm.historyStore.assessments.count) assessments completed").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text("Current Study: \(vm.trial.rawValue)").font(.caption).foregroundStyle(.secondary)
                            Button("Switch") { showStudyPicker = true }.font(.caption)
                        }
                    }.padding(.top, 20)
                    
                    if vm.trial != .personal {
                    // Monthly completion (PULSE uses weighted %; adherence reminder below 66%)
                    let summary = monthlySummary()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("This month").font(.headline)
                            Spacer()
                            Text("\(summary.percent)% complete").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(summary.percent), total: 100)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.lines, id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    }
                    
                    VStack(spacing: 16) {
                        let hasDemographics = vm.historyStore.assessments.contains { $0.assessmentType == "Demographics" }
                        if !hasDemographics {
                        AssessmentCard(title: "Demographics", icon: "person.fill", color: .blue, description: "Update your information") { showDemographics = true }
                        }
                        if vm.trial == .personal {
                            AssessmentCard(title: "Medication & Symptoms", icon: "pills.fill", color: .purple, description: "Log meds, on/off/dyskinesia through the day") { showMedTracker = true }
                        } else if vm.trial == .pulsePD {
                            AssessmentCard(title: "Non-Motor Symptoms", icon: "list.bullet.clipboard.fill", color: .purple, description: "Daily symptoms") { showNonMotor = true }
                        } else if vm.trial == .ascendSVD {
                            let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
                            let safetyDoneThisMonth = vm.historyStore.assessments.contains { $0.assessmentType == "SVD-Safety" && $0.date >= monthStart }
                            if !safetyDoneThisMonth {
                                AssessmentCard(title: "Safety Check", icon: "exclamationmark.shield.fill", color: .purple, description: "Monthly safety screen") { showSafety = true }
                            }
                        }
                        AssessmentCard(title: "Patient-Reported Outcomes", icon: "slider.horizontal.3", color: .pink, description: "Past 7 days symptom severity") { showPRO = true }
                        AssessmentCard(title: "Motor Assessment", icon: "figure.walk", color: .green, description: (vm.trial == .personal || vm.trial == .custom) ? "Pick a single movement test" : "Full motor sequence") { showMotor = true }
                        AssessmentCard(title: "Cognitive Tests", icon: "brain.head.profile", color: .orange, description: cognitiveAssessmentCardDescription()) { showCognitive = true }
                        if (vm.participant.isNicotineArm ?? false) {
                            AssessmentCard(title: "Nicotine Dose", icon: "pills.fill", color: .teal, description: "Check tolerance / adjust dose") { showDose = true }
                        }
                        AssessmentCard(title: "Health Data (Apple Health)", icon: "heart.text.square.fill", color: .pink, description: "Connect and import last 30 days") { showHealth = true }
                    }
                    .padding()
                }
            }
            .navigationTitle("Assessments")
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(vm)
            }
            .sheet(isPresented: $showStudyPicker) { StudySelectionView().environmentObject(vm) }
            .sheet(isPresented: $showDemographics) { DemographicsView() }
            .sheet(isPresented: $showNonMotor) { if vm.trial == .pulsePD { NonMotorView() } }
            .sheet(isPresented: $showMedTracker) { PersonalMedTrackerView(studyID: vm.studyID).environmentObject(vm) }
            .sheet(isPresented: $showPRO) {
                PROView(studyID: vm.studyID) { res in vm.saveAssessment(res) }
                    .environmentObject(vm)
            }
            .sheet(isPresented: $showMotor) { MotorFlowView() }
            .sheet(isPresented: $showCognitive) {
                let allowOneOff = vm.trial == .personal || vm.trial == .custom
                if vm.trial == .ascendSVD {
                    AscendCognitiveMenuView(studyID: vm.studyID, allowSkip: allowOneOff, allowOneOff: allowOneOff, onComplete: { res in vm.saveAssessment(res) }, onBatteryComplete: {
                        showCognitive = false
                    })
                } else {
                    PulseCognitiveMenuView(studyID: vm.studyID, allowSkip: allowOneOff, allowOneOff: allowOneOff, onComplete: { res in vm.saveAssessment(res) }, onBatteryComplete: {
                        showCognitive = false
                    })
                }
            }
            .sheet(isPresented: $showDose) { NicotineDoseView().environmentObject(vm) }
            .sheet(isPresented: $showSafety) { SVDSafetyView(studyID: vm.studyID) { res in vm.saveAssessment(res) } }
            .sheet(isPresented: $showHealth) { HealthKitImportView(studyID: vm.studyID) { res in vm.saveAssessment(res) } }
            .sheet(isPresented: $showQuote) { DailyQuoteSheet(text: quoteText) }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings and API troubleshooting")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        exportAssessmentsJSON()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export assessments JSON")
                    Button("Reset demo") { showResetConfirm = true }
                }
            }
            .confirmationDialog("Reset enrollment?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset enrollment and clear data", role: .destructive) { vm.resetEnrollment() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will clear the Study ID and all saved assessments.")
            }
            .alert("All monthly assessments complete", isPresented: $showMonthlyPulseTrioCompleteAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You’ve completed motor, PRO, and cognitive assessments for this month. Data sync runs in the background to your study spreadsheet when configured.")
            }
            .alert("Export failed", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
        .onChange(of: vm.historyStore.assessments.count) { _, _ in
            evaluatePulseMonthlyCoreTrioIfNeeded()
        }
        .onAppear {
            let s = monthlySummary()
            scheduleAdherenceReminderIfNeeded(percent: s.percent)
            if vm.consentGiven, !vm.studyID.isEmpty, let q = vm.pickDailyQuoteIfNeeded() {
                quoteText = q
                showQuote = true
            }
            evaluatePulseMonthlyCoreTrioIfNeeded()
        }
    }
    
    private func exportAssessmentsJSON() {
        do {
            let url = try ExportManager.exportAssessments(vm.historyStore.assessments)
            exportItem = ExportItem(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }
    
    private func cognitiveAssessmentCardDescription() -> String {
        switch vm.trial {
        case .ascendSVD: return "Stroop → Flanker → Trails → Digit Span (full battery)"
        case .pulsePD: return "Story, Stroop, Flanker, Trails (full battery)"
        case .personal, .custom: return "Pick a single cognitive test"
        }
    }
    
    /// Motor (any motor battery module) + PRO + cognitive (any) for the current month — PULSE-PD.
    private func pulseMonthlyCoreTrioSatisfied() -> Bool {
        guard vm.trial == .pulsePD else { return false }
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let items = vm.historyStore.assessments.filter { $0.date >= start }
        func has(_ t: String) -> Bool { items.contains { $0.assessmentType == t } }
        let motor = has("Tapping3") || has("Gait") || has("Balance") || has("Blink Rate") || has("Voice") || has("Reaction Time")
            || items.contains { $0.assessmentType == "Tremor" }
        let pro = has("PRO")
        let cog = has("Cognitive") || has("Stroop") || has("TrailMakingA") || has("TrailMakingB") || has("Flanker")
        return motor && pro && cog
    }
    
    private func pulseMonthlyCoreTrioDefaultsKey() -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: Date())
        return "pulse_core_trio_notified_\(c.year ?? 0)_\(c.month ?? 0)"
    }
    
    private func evaluatePulseMonthlyCoreTrioIfNeeded() {
        guard vm.trial == .pulsePD, vm.trial != .personal else { return }
        guard pulseMonthlyCoreTrioSatisfied() else { return }
        let key = pulseMonthlyCoreTrioDefaultsKey()
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: Date())
        let monthLabel = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        NetworkService.shared.sendMonthlyCoreTrioComplete(studyID: vm.studyID, trial: vm.trial.rawValue, monthLabel: monthLabel)
        NetworkService.shared.flushPendingUploads()
        UIAccessibility.post(notification: .announcement, argument: "All monthly assessments complete.")
        showMonthlyPulseTrioCompleteAlert = true
    }
    
    private func monthlySummary() -> (percent: Int, lines: [String]) {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let items = vm.historyStore.assessments.filter { $0.date >= start }
        func has(_ type: String) -> Bool { items.contains { $0.assessmentType == type } }
        // Modules
        let tapping = has("Tapping3")
        let tremorR = items.contains { $0.assessmentType == "Tremor" && $0.data["side"] == "Right" }
        let tremorL = items.contains { $0.assessmentType == "Tremor" && $0.data["side"] == "Left" }
        let gait = has("Gait")
        let balance = has("Balance")
        let blink = has("Blink Rate")
        let voice = has("Voice")
        let reaction = has("Reaction Time")
        let nonmotor = has("Non-Motor")
        let pro = has("PRO")
        let memory = has("Cognitive")
        let stroop = has("Stroop")
        let trailsA = has("TrailMakingA")
        let trailsB = has("TrailMakingB")
        _ = has("SVD-Cognitive")
        let svdSafety = has("SVD-Safety")
        let modules: [(String, Bool)]
        let total: Double
        if vm.trial == .personal {
            let medTracker = has("MedTracker")
            let cognitiveAny = has("Cognitive") || has("Stroop") || has("TrailMakingA") || has("TrailMakingB") || has("DigitSpan")
            modules = [
                ("Med Tracker", medTracker),
                ("Cognitive", cognitiveAny),
                ("PRO", pro)
            ]
            total = Double(modules.count)
        } else if vm.trial == .ascendSVD {
            let cogAny = has("Stroop") || has("TrailMakingA") || has("TrailMakingB") || has("DigitSpan")
            modules = [
                ("Tapping", tapping),
                ("Tremor R", tremorR),
                ("Tremor L", tremorL),
                ("Gait", gait),
                ("Balance", balance),
                ("Blink", blink),
                ("Voice", voice),
                ("Reaction", reaction),
                ("Cognitive", cogAny),
                ("Safety", svdSafety),
                ("PRO", pro)
            ]
            total = Double(modules.count)
        } else {
            // PULSE-PD: weighted completion — Non-Motor 8%, PRO 8%, motor modules 40% total (5% each × 8),
            // cognitive tasks 40% total (8% each × 5), Apple Health import 4%.
            let flanker = has("Flanker")
            let healthKitDone = has("HealthKit")
            let wNonMotor = 8.0
            let wPRO = 8.0
            let wHealth = 4.0
            let wMotorEach = 40.0 / 8.0
            let wCogEach = 40.0 / 5.0
            let motorFlags = [tapping, tremorR, tremorL, gait, balance, blink, voice, reaction]
            let cogFlags = [memory, stroop, flanker, trailsA, trailsB]
            var earned = 0.0
            if nonmotor { earned += wNonMotor }
            if pro { earned += wPRO }
            if healthKitDone { earned += wHealth }
            earned += Double(motorFlags.filter { $0 }.count) * wMotorEach
            earned += Double(cogFlags.filter { $0 }.count) * wCogEach
            let pctPulse = min(100, Int(round(earned)))
            let linesPulse: [String] = [
                "Non-Motor (8%): \(nonmotor ? "✓" : "•")",
                "PRO (8%): \(pro ? "✓" : "•")",
                "Tapping (5%): \(tapping ? "✓" : "•")",
                "Tremor R (5%): \(tremorR ? "✓" : "•")",
                "Tremor L (5%): \(tremorL ? "✓" : "•")",
                "Gait (5%): \(gait ? "✓" : "•")",
                "Balance (5%): \(balance ? "✓" : "•")",
                "Blink (5%): \(blink ? "✓" : "•")",
                "Voice (5%): \(voice ? "✓" : "•")",
                "Reaction (5%): \(reaction ? "✓" : "•")",
                "Story / memory (8%): \(memory ? "✓" : "•")",
                "Stroop (8%): \(stroop ? "✓" : "•")",
                "Flanker (8%): \(flanker ? "✓" : "•")",
                "Trail A (8%): \(trailsA ? "✓" : "•")",
                "Trail B (8%): \(trailsB ? "✓" : "•")",
                "Apple Health (4%): \(healthKitDone ? "✓" : "•")"
            ]
            return (pctPulse, linesPulse)
        }
        let completed = Double(modules.filter { $0.1 }.count)
        let pct = Int((completed / total) * 100.0)
        let lines = modules.map { "\($0.0): \($0.1 ? "✓" : "•")" }
        return (pct, lines)
    }
    
    private func scheduleAdherenceReminderIfNeeded(percent: Int) {
        if vm.trial == .personal { return }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        let key = "adherence_reminder_\(comps.year ?? 0)_\(comps.month ?? 0)"
        let adherenceThreshold = vm.trial == .pulsePD ? 66 : 65
        if percent < adherenceThreshold && !UserDefaults.standard.bool(forKey: key) {
            // schedule a reminder in 24 hours
            let content = UNMutableNotificationContent()
            content.title = "Monthly check-in"
            content.body = "Please complete your monthly assessments."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 24*60*60, repeats: false)
            let req = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req)
            UserDefaults.standard.set(true, forKey: key)
            if percent < 50 {
                NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "adherence_contact", urgency: "routine")
            }
        }
    }
}

struct AssessmentCard: View {
    let title: String
    let icon: String
    let color: Color
    let description: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(color)
                    .frame(width: 60, height: 60)
                    .background(color.opacity(0.1))
                    .cornerRadius(12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.05), radius: 8)
        }
    }
}

// MARK: - Daily Quotes
enum QuoteManager {
    static let quotes: [String] = [
        "I don't have any choice whether or not I have Parkinson's, but surrounding that non-choice is a million other choices that I can make. — Michael J. Fox",
        "Nothing comes from doing nothing. — William Shakespeare",
        "Every day may not be good, but there's something good in every day. — Alice Morse Earle",
        "Find joy in each day! — PD community wisdom",
        "You are not alone. — PD peer support",
        "No matter what science can do for people living with Parkinson's, we must prepare our brain and body to face all difficulties. — Nikolas Koukoulakis",
        "I am careful not to confuse excellence with perfection. — Michael J. Fox",
        "I see possibilities in everything. — Michael J. Fox",
        "We must accept finite disappointment, but never lose infinite hope. — Martin Luther King Jr.",
        "The best way out is always through. — Robert Frost",
        "Healing is not linear. — Unknown",
        "Above all, do not lose your desire to walk. Every day, I walk myself into a state of well‑being. — Søren Kierkegaard",
        "One small positive thought in the morning can change your whole day. — Dalai Lama",
        "You don't have to see the whole staircase, just take the first step. — Martin Luther King Jr.",
        "The journey of a thousand miles begins with a single step. — Lao Tzu",
        "Progress, not perfection. — Unknown",
        "Small daily improvements are the key to staggering long‑term results. — James Clear",
        "Gratitude turns what we have into enough. — Aesop",
        "Fall seven times, stand up eight. — Japanese proverb",
        "Strength does not come from the body. It comes from the will. — Unknown",
        "I am not what happened to me. I am what I choose to become. — Carl Jung",
        "Courage doesn't always roar… sometimes it's the quiet voice that says, 'I will try again tomorrow.' — Mary Anne Radmacher",
        "Believe you can and you're halfway there. — Theodore Roosevelt",
        "Don't imagine the worst. If you imagine the worst and it happens, you've lived it twice. — Michael J. Fox",
        "With gratitude, optimism is sustainable. — Michael J. Fox",
        "When the cure for Parkinson's is found—and it will be—it will be because of all of us, working together. — Michael J. Fox",
        "The best preparation for tomorrow is doing your best today. — H. Jackson Brown Jr.",
        "It always seems impossible until it's done. — Nelson Mandela",
        "Keep going. Everything you need will come to you at the perfect time. — Unknown",
        "The comeback is always stronger than the setback. — Unknown",
        "Difficult roads often lead to beautiful destinations. — Zig Ziglar",
        "What lies behind us and what lies before us are tiny matters compared to what lies within us. — Ralph Waldo Emerson",
        "Life is 10% what happens to you and 90% how you react to it. — Charles R. Swindoll",
        "Kites rise highest against the wind, not with it. — Winston Churchill",
        "The oak fought the wind and was broken, the willow bent and survived. — Robert Jordan",
        "A river cuts through rock not because of its power, but because of its persistence. — Jim Watkins"
    ]
    static func randomQuote() -> String {
        quotes.randomElement() ?? "Find joy in each day!"
    }
}

struct DailyQuoteSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("PD Quotes").font(.title2).fontWeight(.bold)
                Text("“\(text)”")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
                Button("Continue") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Inspiration")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Demographics View
struct DemographicsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var age: Int
    @State private var sex: String
    
    init() {
        let vm = AppViewModel()
        _age = State(initialValue: vm.participant.age)
        _sex = State(initialValue: vm.participant.sex)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    HStack {
                        Text("Age"); Spacer()
                        Stepper(value: $age, in: 18...100) { Text("\(age)") }.fixedSize()
                    }
                    Picker("Sex", selection: $sex) {
                        Text("Female").tag("Female"); Text("Male").tag("Male")
                    }.pickerStyle(.segmented)
                }
                Button("Save") {
                    vm.participant.age = age
                    vm.participant.sex = sex
                    let now = Date()
                    var data = ["age": "\(age)", "sex": sex]
                    data.merge(deviceMeta(task: "Demographics", taskVersion: "1.0", start: now, end: now, studyID: vm.studyID)) { _, n in n }
                    let result = AssessmentResult(id: UUID(), date: now, studyID: vm.studyID, assessmentType: "Demographics", data: data, notes: nil)
                    vm.saveAssessment(result)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Demographics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Baseline View (PD history, connectivity, handedness, caffeine)
struct BaselineView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosedPD: Bool = false
    @State private var pdDiagnosisYear: String = ""
    @State private var hasWifi: String = "reliable"
    @State private var hasCellData: Bool = true
    @State private var handedness: String = "right"
    @State private var isNicotineArm: Bool = false
    @State private var nicotineDose: Int = 7
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Parkinson Disease History") {
                    Toggle("Have you been diagnosed with parkinson disease by a doctor?", isOn: $diagnosedPD)
                    if diagnosedPD {
                        TextField("Year of diagnosis", text: $pdDiagnosisYear)
                            .keyboardType(.numberPad)
                    }
                }
                Section("Home Connectivity") {
                    Picker("Reliable Wi‑Fi at home?", selection: $hasWifi) {
                        Text("Reliable most days").tag("reliable")
                        Text("Often slow/unreliable").tag("unreliable")
                        Text("No Wi‑Fi at home").tag("none")
                    }
                    Toggle("Cellular data available", isOn: $hasCellData)
                }
                Section("Handedness") {
                    Picker("Primary hand", selection: $handedness) {
                        Text("Right").tag("right")
                        Text("Left").tag("left")
                        Text("Both / Ambidextrous").tag("both")
                    }
                }
                Section("Study Arm (optional)") {
                    Toggle("Nicotine arm participant", isOn: $isNicotineArm)
                    if isNicotineArm {
                        Picker("Starting dose", selection: $nicotineDose) {
                            Text("7 mg").tag(7)
                            Text("14 mg").tag(14)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Button("Save Baseline") { saveBaseline() }
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Baseline")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
    private func saveBaseline() {
        vm.participant.diagnosedPD = diagnosedPD
        vm.participant.pdDiagnosisYear = pdDiagnosisYear
        vm.participant.wifiReliability = hasWifi
        vm.participant.hasCellData = hasCellData
        vm.participant.handedness = handedness
        vm.participant.isNicotineArm = isNicotineArm
        if isNicotineArm { vm.participant.nicotineDoseMg = nicotineDose }
        // Baseline flags removed
        // Incident PD tracker (coordinator backend metric)
        if diagnosedPD {
            let key = "incident_pd_count"
            let count = UserDefaults.standard.integer(forKey: key) + 1
            UserDefaults.standard.set(count, forKey: key)
            if count >= 40 {
                NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "incident_pd_cap_reached", urgency: "urgent")
            } else {
                NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "incident_pd", urgency: "routine")
            }
        }
        let now = Date()
        var data: [String:String] = [
            "diagnosed_pd": "\(diagnosedPD)",
            "pd_dx_year": pdDiagnosisYear,
            "wifi": hasWifi,
            "cell_data": "\(hasCellData)",
            "handedness": handedness
        ]
        data.merge(deviceMeta(task: "Baseline", taskVersion: "1.0", start: now, end: now, studyID: vm.studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: now, studyID: vm.studyID, assessmentType: "Baseline", data: data, notes: "Baseline onboarding")
        vm.saveAssessment(res)
        dismiss()
    }
}
// MARK: - Non-Motor View
struct NonMotorView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var address: String = ""
    @State private var geoLat: Double?
    @State private var geoLng: Double?
    @State private var nearestGolfName: String = ""
    @State private var nearestGolfDistanceKm: Double?
    @State private var isLocating = false
    @State private var geoAlert: String?
    @State private var golfLookupStatus: String = "not_started"
    
    @State private var smellWorse = false
    @State private var smellSeverity = 0
    @State private var constipation = false
    @State private var constipationSeverity = 0
    @State private var dreamEnactment = false
    @State private var rbdSeverity = 0
    @State private var dizziness = false
    @State private var dizzinessSeverity = 0
    @State private var exposure = false
    @State private var familyHistory = false
    @State private var geneMutation = false
    @State private var smoking = false
    @State private var exercise = false
    @State private var sleepQuality: Int = 2
    @State private var moodRating: Int = 2
    @State private var anxietyRating: Int = 0
    @State private var medChanged: Bool = false
    @State private var medChangeNotes: String = ""
    @State private var onPDMeds: Bool = false
    @State private var lastDoseHours: Int = 0
    @State private var notes: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Please answer about symptoms you may have experienced.").font(.subheadline).foregroundStyle(.secondary) }
                Section("Symptoms") {
                    Toggle("Is your sense of smell and taste decreased or absent?", isOn: $smellWorse)
                    if smellWorse {
                        Picker("Severity", selection: $smellSeverity) {
                            Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                        }.pickerStyle(.segmented)
                    }
                    Toggle("Do you have fewer than 7 bowel movements per week?", isOn: $constipation)
                    if constipation {
                        Picker("Severity", selection: $constipationSeverity) {
                            Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                        }.pickerStyle(.segmented)
                    }
                    Toggle("Do you sometimes act out dreams? (Movements, talking, falling out of bed)?", isOn: $dreamEnactment)
                    if dreamEnactment {
                        Picker("Severity", selection: $rbdSeverity) {
                            Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                        }.pickerStyle(.segmented)
                    }
                    Toggle("Do you feel faint when you stand up quickly?", isOn: $dizziness)
                    if dizziness {
                        Picker("Severity", selection: $dizzinessSeverity) {
                            Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3)
                        }.pickerStyle(.segmented)
                    }
                }
                Section("History") {
                    Toggle("Do you have a history of environmental/occupational exposure to glyphosate/Roundup,Agent Orange, other herbicide/pesticide exposure; or worked in welding/shipbuilding/aerospace/solvent-exposed settings?", isOn: $exposure)
                    Toggle("Do you have a parent, sibling, or child with clinical diagnosis of Parkinson's disease?", isOn: $familyHistory)
                    Toggle("Do you have a Known PD-related gene mutation (eg: PARKIN, GBA1, PINK1, SNCA, LRRK2)?", isOn: $geneMutation)
                }
                Section("Location (optional)") {
                    TextField("Home address (for proximity estimate)", text: $address, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        lookupProximity()
                    } label: {
                        if isLocating {
                            HStack { ProgressView(); Text("Computing proximity…") }
                        } else {
                            Text("Compute proximity to nearest golf course")
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLocating)
                    if let km = nearestGolfDistanceKm, !nearestGolfName.isEmpty {
                        Text(String(format: "Nearest: %@ (%.2f km)", nearestGolfName, km))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = geoAlert {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    if !golfLookupStatus.isEmpty && golfLookupStatus != "not_started" {
                        Text("Lookup status: \(golfLookupStatus)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Lifestyle") {
                    Toggle("Have you smoked cigarettes daily >5 years?", isOn: $smoking)
                    Toggle("Do you exercise at least three times per week?", isOn: $exercise)
                }
                Section("Monthly Mood / Sleep / Anxiety (0–10)") {
                    Stepper("Mood: \(moodRating)", value: $moodRating, in: 0...10)
                    Stepper("Sleep Quality: \(sleepQuality)", value: $sleepQuality, in: 0...10)
                    Stepper("Anxiety: \(anxietyRating)", value: $anxietyRating, in: 0...10)
                }
                Section("Medications") {
                    Toggle("Currently taking PD medication?", isOn: $onPDMeds)
                    if onPDMeds {
                        Stepper("Last dose: \(lastDoseHours) hour\(lastDoseHours == 1 ? "" : "s") ago", value: $lastDoseHours, in: 0...48)
                    }
                    Toggle("Any medication changes since last month?", isOn: $medChanged)
                    if medChanged {
                        TextField("Briefly describe changes (drug, dose, timing)", text: $medChangeNotes, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
                Section("Parkinson disease diagnosis") {
                    Toggle("Diagnosed with Parkinson disease by a doctor?", isOn: Binding(get: {
                        vm.participant.diagnosedPD ?? false
                    }, set: { newVal in
                        vm.participant.diagnosedPD = newVal
                    }))
                    if vm.participant.diagnosedPD ?? false {
                        TextField("Year of diagnosis", text: Binding(get: {
                            vm.participant.pdDiagnosisYear
                        }, set: { vm.participant.pdDiagnosisYear = $0 }))
                        .keyboardType(.numberPad)
                    }
                }
                Section("Other notes (optional)") {
                    TextField("Add any other symptoms or comments…", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    EmptyView()
                }
                Button("Submit") {
                    let start = Date(); let end = Date()
                    var data: [String: String] = [
                        "smell": "\(smellWorse)",
                        "constipation": "\(constipation)",
                        "rbd": "\(dreamEnactment)",
                        "dizziness": "\(dizziness)",
                        "exposure": "\(exposure)",
                        "familyHistory": "\(familyHistory)",
                        "gene": "\(geneMutation)",
                        "smoking": "\(smoking)",
                        "exercise": "\(exercise)"
                    ]
                    if smellWorse { data["smell_severity"] = "\(smellSeverity)" }
                    if constipation { data["constipation_severity"] = "\(constipationSeverity)" }
                    if dreamEnactment { data["rbd_severity"] = "\(rbdSeverity)" }
                    if dizziness { data["dizziness_severity"] = "\(dizzinessSeverity)" }
                    data["sleep_quality"] = "\(sleepQuality)"
                    data["mood"] = "\(moodRating)"
                    data["anxiety"] = "\(anxietyRating)"
                    data["on_pd_meds"] = "\(onPDMeds)"
                    if onPDMeds { data["last_dose_hours"] = "\(lastDoseHours)" }
                    data["med_changed"] = "\(medChanged)"
                    let medTrim = medChangeNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if medChanged && !medTrim.isEmpty { data["med_change_notes"] = medTrim }
                    let addrTrim = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !addrTrim.isEmpty {
                        data["address"] = addrTrim
                        data["golf_lookup_status"] = golfLookupStatus
                    }
                    if let lat = geoLat, let lng = geoLng {
                        data["geo_lat"] = String(format: "%.6f", lat)
                        data["geo_lng"] = String(format: "%.6f", lng)
                    }
                    if let km = nearestGolfDistanceKm, !nearestGolfName.isEmpty {
                        data["nearest_golf_km"] = String(format: "%.2f", km)
                        data["nearest_golf_name"] = nearestGolfName
                    }
                    if let dx = vm.participant.diagnosedPD {
                        data["diagnosed_pd"] = "\(dx)"
                        let yr = vm.participant.pdDiagnosisYear.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !yr.isEmpty { data["pd_dx_year"] = yr }
                    }
                    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { data["notes"] = trimmed }
                    // Baseline capture (first time) and safety rule (>=4 change)
                    if vm.participant.baselineMood == nil { vm.participant.baselineMood = moodRating }
                    if vm.participant.baselineSleep == nil { vm.participant.baselineSleep = sleepQuality }
                    if vm.participant.baselineAnxiety == nil { vm.participant.baselineAnxiety = anxietyRating }
                    var msaAlert = false
                    if let bm = vm.participant.baselineMood,
                       let bs = vm.participant.baselineSleep,
                       let ba = vm.participant.baselineAnxiety {
                        if abs(moodRating - bm) >= 4 ||
                           abs(sleepQuality - bs) >= 4 ||
                           abs(anxietyRating - ba) >= 4 {
                            msaAlert = true
                            NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: "msa_change_gt4")
                        }
                    }
                    data["msa_alert"] = "\(msaAlert)"
                    data.merge(deviceMeta(task: "Non-Motor", taskVersion: "1.0", start: start, end: end, studyID: vm.studyID)) { _, n in n }
                    let result = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "Non-Motor", data: data, notes: nil)
                    playChime(); vm.saveAssessment(result); dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Non-Motor Symptoms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - NonMotor (Geocoding helpers)
extension NonMotorView {
    private func lookupProximity() {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else {
            golfLookupStatus = "missing_address"
            geoAlert = "Enter an address first."
            return
        }
        isLocating = true
        geoAlert = nil
        nearestGolfName = ""
        nearestGolfDistanceKm = nil
        golfLookupStatus = "geocoding"
        GoogleMapsService.geocode(address: addr, apiKey: "") { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.isLocating = false
                    if let svc = err as? GoogleMapsService.ServiceError {
                        self.golfLookupStatus = svc.statusKey
                    } else {
                        self.golfLookupStatus = "geocode_error"
                    }
                    self.geoAlert = err.localizedDescription
                case .success(let (lat, lng)):
                    self.geoLat = lat
                    self.geoLng = lng
                    self.golfLookupStatus = "places_lookup"
                    GoogleMapsService.nearestGolfCourse(lat: lat, lng: lng, apiKey: "") { r2 in
                        DispatchQueue.main.async {
                            self.isLocating = false
                            switch r2 {
                            case .failure(let e2):
                                if let svc = e2 as? GoogleMapsService.ServiceError {
                                    self.golfLookupStatus = svc.statusKey
                                } else {
                                    self.golfLookupStatus = "places_error"
                                }
                                self.geoAlert = e2.localizedDescription
                            case .success(let (name, km)):
                                self.nearestGolfName = name
                                self.nearestGolfDistanceKm = km
                                self.golfLookupStatus = "ok"
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Patient-Reported Outcomes (PRO)

// MARK: - Personal Medication Tracker
struct PersonalMedTrackerView: View {
    let studyID: String
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date()
    @State private var showLogSheet = false
    @State private var calendarReady = false
    @State private var sharePDFData: Data? = nil
    @State private var showShare = false
    @State private var exportRangeDays: Int = 3
    @State private var chartRangeDays: Int = 1

    private var entriesForSelectedDate: [AssessmentResult] {
        let cal = Calendar.current
        return vm.historyStore.assessments
            .filter { $0.assessmentType == "MedTracker" && cal.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    private func entriesForChartRange(days: Int, from date: Date) -> [AssessmentResult] {
        let cal = Calendar.current
        guard let rangeStart = cal.date(byAdding: .day, value: -(days - 1), to: date) else { return [] }
        let startOfRange = cal.startOfDay(for: rangeStart)
        let endOfDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) ?? date
        return vm.historyStore.assessments
            .filter { $0.assessmentType == "MedTracker" && $0.date >= startOfRange && $0.date < endOfDate }
            .sorted { $0.date < $1.date }
    }

    private var chartStartDate: Date {
        let cal = Calendar.current
        switch chartRangeDays {
        case 1: return cal.startOfDay(for: selectedDate)
        case 7: return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: selectedDate)) ?? selectedDate
        case 30: return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: selectedDate)) ?? selectedDate
        default: return cal.date(byAdding: .day, value: -(chartRangeDays - 1), to: cal.startOfDay(for: selectedDate)) ?? selectedDate
        }
    }

    private var chartLabel: String {
        switch chartRangeDays {
        case 1: return "Symptom chart (1 day)"
        case 7: return "Symptom chart (past 7 days)"
        case 30: return "Symptom chart (past 30 days)"
        default: return "Symptom chart (past \(chartRangeDays) days)"
        }
    }

    private func entriesForExportRange(days: Int) -> [AssessmentResult] {
        return entriesForChartRange(days: days, from: Date())
    }

    private func exportRangeStart(days: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -(days - 1), to: Date()).map { cal.startOfDay(for: $0) } ?? Date()
    }

    var body: some View {
        return NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chartLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        MedTrackerSymptomChartView(
                            entries: entriesForChartRange(days: chartRangeDays, from: selectedDate),
                            rangeStart: chartStartDate,
                            dayCount: chartRangeDays,
                            selectedDate: $selectedDate,
                            chartRangeDays: $chartRangeDays,
                            onSave: { date, state in
                                let cal = Calendar.current
                                let dayStart = cal.startOfDay(for: date)
                                let entryDate = cal.date(byAdding: .hour, value: 12, to: dayStart) ?? date
                                var data: [String: String] = ["state": state]
                                data.merge(deviceMeta(task: "MedTracker", taskVersion: "2.0", start: Date(), end: entryDate, studyID: studyID)) { _, n in n }
                                let res = AssessmentResult(id: UUID(), date: entryDate, studyID: studyID, assessmentType: "MedTracker", data: data, notes: nil)
                                vm.saveAssessment(res)
                            },
                            onDayTapped: { tappedDate in selectedDate = tappedDate; chartRangeDays = 1 }
                        )
                    }

                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entries for selected date")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(entriesForSelectedDate) { entry in
                            MedTrackerEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("PDF export range:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(exportRangeDays) days")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        Text("Pinch to expand or contract")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .gesture(
                        MagnificationGesture()
                            .onEnded { value in
                                let newDays = Int(Double(exportRangeDays) * Double(value))
                                exportRangeDays = min(30, max(1, newDays))
                            }
                    )

                    HStack(spacing: 12) {
                        Button("Log now") { showLogSheet = true }
                            .buttonStyle(.borderedProminent)
                        Button("Share with doctor") {
                            if let data = generateMedTrackerPDF() {
                                sharePDFData = data
                                showShare = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Medication Diary")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { calendarReady = true } }
        .onChange(of: selectedDate) { _, _ in if calendarReady { showLogSheet = true } }
        .sheet(isPresented: $showLogSheet) {
            MedTrackerLogEntrySheet(studyID: studyID, initialDate: selectedDate) { res in
                vm.saveAssessment(res)
            }
            .environmentObject(vm)
        }
        .sheet(isPresented: $showShare) {
            if let data = sharePDFData {
                ShareSheet(items: [TemporaryFileData(data: data, suggestedName: "Medication-Diary.pdf")])
            }
        }
    }

    private func generateMedTrackerPDF() -> Data? {
        let scale: CGFloat = 2
        let baseW: CGFloat = 850
        let baseH: CGFloat = 1100
        let rangeEntries = entriesForExportRange(days: exportRangeDays)
        let rangeStart = exportRangeStart(days: exportRangeDays)
        let reportView = MedTrackerDoctorReportView(entries: rangeEntries, date: selectedDate, weekEntries: rangeEntries, weekStart: rangeStart, dayCount: exportRangeDays)
            .frame(width: baseW, height: baseH)
        let imageRenderer = ImageRenderer(content: reportView)
        imageRenderer.scale = scale
        guard let uiImage = imageRenderer.uiImage else { return nil }
        let pageRect = CGRect(x: 0, y: 0, width: baseW, height: baseH)
        let format = UIGraphicsPDFRendererFormat()
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            uiImage.draw(in: pageRect)
        }
    }
}



private struct ChartRangeMagnificationModifier: ViewModifier {
    var chartRangeDays: Binding<Int>?
    func body(content: Content) -> some View {
        if let binding = chartRangeDays {
            content.gesture(
                MagnificationGesture()
                    .onEnded { value in
                        let current = binding.wrappedValue
                        let cycle = [1, 7, 30]
                        let idx = cycle.firstIndex(of: current) ?? 0
                        if value < 1 {
                            let newIdx = min(idx + 1, cycle.count - 1)
                            binding.wrappedValue = cycle[newIdx]
                        } else if value > 1 {
                            let newIdx = max(idx - 1, 0)
                            binding.wrappedValue = cycle[newIdx]
                        }
                    }
            )
        } else {
            content
        }
    }
}

private struct MedTrackerSymptomChartView: View {
    let entries: [AssessmentResult]
    let rangeStart: Date
    var dayCount: Int = 7
    var selectedDate: Binding<Date>? = nil
    var chartRangeDays: Binding<Int>? = nil
    var onSave: ((Date, String) -> Void)? = nil
    var onDayTapped: ((Date) -> Void)? = nil

    private func stateValue(for entry: AssessmentResult) -> Double {
        func extractState(_ s: String?) -> String? {
            guard let s = s, !s.isEmpty else { return nil }
            return s.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let state = extractState(entry.data["state"])
            ?? extractState(entry.data["morning_state"])
            ?? extractState(entry.data["midday_state"])
            ?? extractState(entry.data["afternoon_state"])
            ?? extractState(entry.data["evening_state"])
        guard let s = state else { return 0 }
        if s.contains("good on") || s.contains("goodon") { return 1 }
        if s.contains("dyskinesia") { return 2 }
        return 0  // Off
    }

    private var dayLabels: [(day: Date, label: String)] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE M/d"
        return (0..<dayCount).compactMap { i -> (Date, String)? in
            guard let d = cal.date(byAdding: .day, value: i, to: rangeStart) else { return nil }
            return (d, fmt.string(from: d))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padL: CGFloat = 50
            let padR: CGFloat = 16
            let padT: CGFloat = 24
            let padB: CGFloat = 36
            let chartW = max(1, w - padL - padR)
            let chartH = max(1, h - padT - padB)

            ZStack(alignment: .topLeading) {
                // Y axis labels
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dyskinesia").font(.caption2).foregroundStyle(.yellow)
                    Spacer()
                    Text("Good On").font(.caption2).foregroundStyle(.green)
                    Spacer()
                    Text("Off").font(.caption2).foregroundStyle(.red)
                }
                .frame(width: padL - 8, height: chartH)
                .padding(.top, padT)

                // Chart area
                Canvas { ctx, size in
                    let yForVal: (Double) -> CGFloat = { val in
                        padT + chartH * (1 - CGFloat(val) / 2)
                    }
                    let weekDuration = Double(dayCount) * 24 * 3600.0
                    let xForDate: (Date) -> CGFloat = { date in
                        let fraction = (date.timeIntervalSince1970 - rangeStart.timeIntervalSince1970) / weekDuration
                        return padL + chartW * CGFloat(min(1, max(0, fraction)))
                    }

                    // Horizontal grid lines
                    for (val, col) in [(0.0, Color.red), (1.0, Color.green), (2.0, Color.yellow)] {
                        let y = yForVal(val)
                        var p = Path()
                        p.move(to: CGPoint(x: padL, y: y))
                        p.addLine(to: CGPoint(x: padL + chartW, y: y))
                        ctx.stroke(p, with: .color(col.opacity(0.5)), lineWidth: 1)
                    }

                    // Stepped line
                    let sortedEntries = entries.sorted { $0.date < $1.date }
                    if !sortedEntries.isEmpty {
                        var lastX = padL
                        var lastY = yForVal(stateValue(for: sortedEntries.first!))
                        for entry in sortedEntries {
                            let val = stateValue(for: entry)
                            let newY = yForVal(val)
                            let x = xForDate(entry.date)
                            var p = Path()
                            p.move(to: CGPoint(x: lastX, y: lastY))
                            p.addLine(to: CGPoint(x: x, y: lastY))
                            p.addLine(to: CGPoint(x: x, y: newY))
                            let col: Color = val >= 2 ? .yellow : (val >= 1 ? .green : .red)
                            ctx.stroke(p, with: .color(col), lineWidth: 2)
                            lastX = x
                            lastY = newY
                        }
                        var p = Path()
                        p.move(to: CGPoint(x: lastX, y: lastY))
                        p.addLine(to: CGPoint(x: padL + chartW, y: lastY))
                        let val = stateValue(for: sortedEntries.last!)
                        let col: Color = val >= 2 ? .yellow : (val >= 1 ? .green : .red)
                        ctx.stroke(p, with: .color(col), lineWidth: 2)
                    }

                    // Points
                    for entry in entries {
                        let x = xForDate(entry.date)
                        let y = yForVal(stateValue(for: entry))
                        let val = stateValue(for: entry)
                        let col: Color = val >= 2 ? .yellow : (val >= 1 ? .green : .red)
                        let circle = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                        ctx.fill(circle, with: .color(col))
                        ctx.stroke(circle, with: .color(col), lineWidth: 1)
                    }
                }
                .frame(width: w, height: h)

                // X axis labels
                HStack(spacing: 0) {
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, item in
                        Text(item.label)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, padL)
                .padding(.trailing, padR)
                .frame(height: padB)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Draggable overlay when onSave != nil and dayCount == 1
                if onSave != nil, dayCount == 1 {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: chartW, height: chartH)
                        .padding(.leading, padL)
                        .padding(.top, padT)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard let onSave = onSave else { return }
                                    let y = value.location.y
                                    let val = 2 * Double(1 - min(1, max(0, y / chartH)))
                                    let stateStr = val < 0.5 ? "Off" : (val < 1.5 ? "Good On" : "Dyskinesia")
                                    let cal = Calendar.current
                                    let dayStart = cal.startOfDay(for: rangeStart)
                                    onSave(dayStart, stateStr)
                                }
                        )
                }

                // Tappable day columns when onDayTapped != nil and dayCount > 1
                if onDayTapped != nil, dayCount > 1 {
                    HStack(spacing: 0) {
                        ForEach(Array(dayLabels.enumerated()), id: \.offset) { i, item in
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity)
                                .onTapGesture { onDayTapped?(item.day) }
                        }
                    }
                    .padding(.leading, padL)
                    .padding(.trailing, padR)
                    .frame(height: chartH + padT + padB)
                    .padding(.top, 0)
                }
            }
        }
        .frame(height: 180)
        .modifier(ChartRangeMagnificationModifier(chartRangeDays: chartRangeDays))
    }
}

private struct MedTrackerEntryRow: View {
    let entry: AssessmentResult

    private var stateStr: String {
        if let s = entry.data["state"], !s.isEmpty { return s }
        let parts: [String] = [
            entry.data["morning_state"].map { "AM: \($0)" },
            entry.data["midday_state"].map { "Mid: \($0)" },
            entry.data["afternoon_state"].map { "PM: \($0)" },
            entry.data["evening_state"].map { "Eve: \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " | ")
    }

    private var stateColor: Color {
        let s = stateStr.lowercased()
        if s.contains("dyskinesia") { return .yellow }
        if s.contains("good on") || s.contains("goodon") { return .green }
        return .red
    }

    private var medsStr: String {
        if let mwd = entry.data["meds_with_doses"], !mwd.isEmpty { return mwd }
        var list: [String] = []
        if let m = entry.data["meds_taken"], !m.isEmpty { list.append(m) }
        if let o = entry.data["other_meds"], !o.isEmpty { list.append(o) }
        return list.joined(separator: "; ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, style: .time)
                    .font(.subheadline.monospacedDigit())
                Text(stateStr)
                    .font(.subheadline)
                    .foregroundStyle(stateColor)
            }
            if !medsStr.isEmpty {
                Text(medsStr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MedTrackerLogEntrySheet: View {
    let studyID: String
    var initialDate: Date = Date()
    let onSave: (AssessmentResult) -> Void
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum MedState: String, CaseIterable { case off = "Off"; case goodOn = "Good On"; case dyskinesia = "Dyskinesia" }
    @State private var state: MedState = .off
    @State private var meds: Set<String> = []
    @State private var medStrength: [String: String] = [:]
    @State private var medQuantity: [String: String] = [:]
    @State private var otherMeds: String = ""
    @State private var entryDateTime: Date = Date()

    private let presetMeds = ["Sinemet", "Amantadine", "Rytary", "Stalevo", "Comtan", "Rasagiline", "Ropinirole", "Mirapex", "Nourianz", "Artane", "Apokyn", "Gocovri", "Other"]

    private let strengthOptions: [String: [String]] = [
        "Sinemet": ["25-100 mg", "50-200 mg", "25-250 mg", "10-100 mg"],
        "Rytary": ["48.75/195 mg", "23.75/95 mg", "36.25/145 mg", "61.25/245 mg"],
        "Stalevo": ["25-100-200", "12.5/50/200", "37.5/150/200"],
        "Amantadine": ["100 mg"],
        "Comtan": ["200 mg"],
        "Rasagiline": ["0.5 mg", "1 mg"],
        "Ropinirole": ["0.25 mg", "0.5 mg", "1 mg", "2 mg", "3 mg"],
        "Mirapex": ["0.25 mg", "0.5 mg", "1 mg", "2 mg", "3 mg"],
        "Nourianz": ["20 mg"],
        "Artane": ["2 mg", "5 mg"],
        "Apokyn": ["2 mg", "3 mg", "4 mg", "5 mg", "6 mg"],
        "Gocovri": ["137 mg", "274 mg"],
    ]
    private let quantityOptions: [String: [String]] = [
        "Sinemet": ["1 tab", "2 tabs", "3 tabs"],
        "Rytary": ["1 cap", "2 caps", "3 caps"],
        "Stalevo": ["1 tab", "2 tabs", "3 tabs"],
        "Amantadine": ["1 tab", "2 tabs", "3 tabs"],
        "Comtan": ["1 tab", "2 tabs", "3 tabs"],
        "Rasagiline": ["1 tab", "2 tabs", "3 tabs"],
        "Ropinirole": ["1 tab", "2 tabs", "3 tabs"],
        "Mirapex": ["1 tab", "2 tabs", "3 tabs"],
        "Nourianz": ["1 tab"],
        "Artane": ["1 tab", "2 tabs", "3 tabs"],
        "Apokyn": ["1 inj", "2 inj", "3 inj"],
        "Gocovri": ["1 cap", "2 caps"],
    ]

    private func eightAM(on date: Date) -> Date {
        Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: date) ?? date
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date & Time") {
                    DatePicker("Entry time", selection: $entryDateTime, in: (Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date())...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                Section("State") {
                    Picker("", selection: $state) {
                        ForEach(MedState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Medications Taken") {
                    ForEach(presetMeds, id: \.self) { med in
                        Toggle(med, isOn: Binding(get: { meds.contains(med) }, set: { on in
                            if on {
                                meds.insert(med)
                                if let sOpts = strengthOptions[med], let sFirst = sOpts.first {
                                    medStrength[med] = sFirst
                                }
                                if let qOpts = quantityOptions[med], let qFirst = qOpts.first {
                                    medQuantity[med] = qFirst
                                }
                            } else {
                                meds.remove(med)
                                medStrength.removeValue(forKey: med)
                                medQuantity.removeValue(forKey: med)
                            }
                        }))
                        if med != "Other", meds.contains(med) {
                            if let sOpts = strengthOptions[med] {
                                Picker("Strength", selection: Binding(get: { medStrength[med] ?? sOpts.first ?? "" }, set: { medStrength[med] = $0 })) {
                                    ForEach(sOpts, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                            if let qOpts = quantityOptions[med] {
                                Picker("Quantity", selection: Binding(get: { medQuantity[med] ?? qOpts.first ?? "" }, set: { medQuantity[med] = $0 })) {
                                    ForEach(qOpts, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                    if meds.contains("Other") {
                        TextField("Other medications", text: $otherMeds)
                    }
                }
                Section {
                    Button("Save") {
                        let start = Date()
                        let end = entryDateTime
                        var data: [String: String] = [
                            "state": state.rawValue,
                            "meds_taken": meds.filter { $0 != "Other" }.sorted().joined(separator: ", ")
                        ]
                        let medsWithDosesParts = meds.filter { $0 != "Other" }.sorted().compactMap { med -> String? in
                            guard let strength = medStrength[med], !strength.isEmpty, let quantity = medQuantity[med], !quantity.isEmpty else { return nil }
                            return med + ": " + strength + " × " + quantity
                        }
                        if !medsWithDosesParts.isEmpty {
                            data["meds_with_doses"] = medsWithDosesParts.joined(separator: "; ")
                        }
                        let otherTrim = otherMeds.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !otherTrim.isEmpty { data["other_meds"] = otherTrim }
                        data.merge(deviceMeta(task: "MedTracker", taskVersion: "2.0", start: start, end: end, studyID: studyID)) { _, n in n }
                        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "MedTracker", data: data, notes: nil)
                        onSave(res)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .onAppear { entryDateTime = eightAM(on: initialDate) }
            .navigationTitle("Log Entry")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct MedTrackerDoctorReportView: View {
    let entries: [AssessmentResult]
    let date: Date
    var weekEntries: [AssessmentResult]? = nil
    var weekStart: Date? = nil
    var dayCount: Int = 7

    private func stateStr(for entry: AssessmentResult) -> String {
        if let s = entry.data["state"], !s.isEmpty { return s }
        let parts: [String] = [
            entry.data["morning_state"].map { "AM: \($0)" },
            entry.data["midday_state"].map { "Mid: \($0)" },
            entry.data["afternoon_state"].map { "PM: \($0)" },
            entry.data["evening_state"].map { "Eve: \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " | ")
    }

    private var hasDoseColumn: Bool {
        entries.contains { ($0.data["meds_with_doses"] ?? "").isEmpty == false }
    }

    private func medsStr(for entry: AssessmentResult) -> String {
        if let mwd = entry.data["meds_with_doses"], !mwd.isEmpty { return mwd }
        var list: [String] = []
        if let m = entry.data["meds_taken"], !m.isEmpty { list.append(m) }
        if let o = entry.data["other_meds"], !o.isEmpty { list.append(o) }
        return list.joined(separator: "; ")
    }

    private func doseStr(for entry: AssessmentResult) -> String {
        guard let mwd = entry.data["meds_with_doses"], !mwd.isEmpty else { return "—" }
        let parts = mwd.split(separator: ";").map { s in
            let trimmed = String(s).trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":") {
                return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return parts.joined(separator: "; ")
    }

    var body: some View {
        let cal = Calendar.current
        let rangeStart = weekStart ?? cal.date(byAdding: .day, value: -dayCount, to: Date()).map { cal.startOfDay(for: $0) } ?? Date()

        return VStack(alignment: .leading, spacing: 16) {
            Text("Medication & Symptom Diary")
                .font(.title2)
                .fontWeight(.bold)
            Text(date, style: .date)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let weekEntries = weekEntries, !weekEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Symptom chart (past \(dayCount) days)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    MedTrackerSymptomChartView(entries: weekEntries, rangeStart: rangeStart, dayCount: dayCount)
                }
            }

            if entries.isEmpty {
                Text("No entries for this period")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Time").frame(width: 80, alignment: .leading).font(.caption.weight(.semibold))
                    Text("State").frame(width: 100, alignment: .leading).font(.caption.weight(.semibold))
                    Text("Medications").frame(maxWidth: .infinity, alignment: .leading).font(.caption.weight(.semibold))
                    if hasDoseColumn {
                        Text("Dose").frame(width: 120, alignment: .leading).font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))

                ForEach(entries) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date, style: .time)
                            .frame(width: 80, alignment: .leading)
                            .font(.caption)
                        Text(stateStr(for: entry))
                            .frame(width: 100, alignment: .leading)
                            .font(.caption)
                        Text(medsStr(for: entry))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if hasDoseColumn {
                            Text(doseStr(for: entry))
                                .frame(width: 120, alignment: .leading)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PROView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: AppViewModel
    @State private var showWheel = false
    @State private var showReport = false
    @State private var sharePDFData: Data? = nil
    @State private var showShare = false
    @State private var slowness: Double = 5
    @State private var constipation: Double = 5
    @State private var walking: Double = 5
    @State private var freezingGait: Double = 5
    @State private var falling: Double = 5
    @State private var risingFromSeated: Double = 5
    @State private var adl: Double = 5 // dressing/eating/grooming
    @State private var motivation: Double = 5
    @State private var handwritingTyping: Double = 5
    @State private var depression: Double = 5
    @State private var lossOfInterest: Double = 5
    @State private var anxiety: Double = 5
    @State private var fatigue: Double = 5
    @State private var dyskinesia: Double = 5
    @State private var tremor: Double = 5
    @State private var balance: Double = 5
    @State private var temperatureControl: Double = 5
    @State private var dizzyOnStanding: Double = 5
    @State private var visualDisturbance: Double = 5
    @State private var insomnia: Double = 5
    @State private var remSleepBehavior: Double = 5
    @State private var restlessLeg: Double = 5
    @State private var muscleCramping: Double = 5
    @State private var speech: Double = 5
    @State private var drooling: Double = 5
    @State private var stoopedPosture: Double = 5
    @State private var memoryForgetfulness: Double = 5
    @State private var comprehension: Double = 5
    @State private var senseOfSmell: Double = 5
    @State private var medicationSideEffects: Double = 5
    @State private var sexualDysfunction: Double = 5
    @State private var urinarySymptoms: Double = 5
    @State private var hallucinations: Double = 5
    @State private var nausea: Double = 5
    @State private var daytimeSleepiness: Double = 5
    @State private var touchedSlowness = false
    @State private var touchedConstipation = false
    @State private var touchedWalking = false
    @State private var touchedFreezingGait = false
    @State private var touchedFalling = false
    @State private var touchedRising = false
    @State private var touchedADL = false
    @State private var touchedMotivation = false
    @State private var touchedHandwriting = false
    @State private var touchedDepression = false
    @State private var touchedLossOfInterest = false
    @State private var touchedAnxiety = false
    @State private var touchedFatigue = false
    @State private var touchedDyskinesia = false
    @State private var touchedTremor = false
    @State private var touchedBalance = false
    @State private var touchedTemperature = false
    @State private var touchedDizzyOnStanding = false
    @State private var touchedVisualDisturbance = false
    @State private var touchedInsomnia = false
    @State private var touchedREM = false
    @State private var touchedRestlessLeg = false
    @State private var touchedMuscleCramping = false
    @State private var touchedSpeech = false
    @State private var touchedDrooling = false
    @State private var touchedStoopedPosture = false
    @State private var touchedMemory = false
    @State private var touchedComprehension = false
    @State private var touchedSmell = false
    @State private var touchedMedicationSideEffects = false
    @State private var touchedSexualDysfunction = false
    @State private var touchedUrinarySymptoms = false
    @State private var touchedHallucinations = false
    @State private var touchedNausea = false
    @State private var touchedDaytimeSleepiness = false
    @State private var started = Date()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Patient-Reported Outcomes")
                        .font(.title2).fontWeight(.bold)
                    Text("Please rate the severity of your symptoms over the past 7 days, on average. Slide according to how severe and how disabling they are. Please complete all the fields in order to be able to submit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    proSlider(title: "General slowness",
                              value: $slowness,
                              onTouch: { touchedSlowness = true },
                              leftPrompt: "Move with ease",
                              rightPrompt: "Very slow")
                    
                    proSlider(title: "Bowel habits",
                              value: $constipation,
                              onTouch: { touchedConstipation = true },
                              leftPrompt: "Regular daily bowel movements",
                              rightPrompt: "Severe constipation")
                    
                    proSlider(title: "Walking & mobility",
                              value: $walking,
                              onTouch: { touchedWalking = true },
                              leftPrompt: "I move freely with ease",
                              rightPrompt: "Unable to walk")
                    
                    proSlider(title: "Freezing when walking",
                              value: $freezingGait,
                              onTouch: { touchedFreezingGait = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe debilitating")
                    
                    proSlider(title: "Falling",
                              value: $falling,
                              onTouch: { touchedFalling = true },
                              leftPrompt: "Never",
                              rightPrompt: "Daily")
                    
                    proSlider(title: "Standing up from chair",
                              value: $risingFromSeated,
                              onTouch: { touchedRising = true },
                              leftPrompt: "With ease",
                              rightPrompt: "Unable to stand without help")
                    
                    proSlider(title: "Daily tasks (dressing/eating/grooming)",
                              value: $adl,
                              onTouch: { touchedADL = true },
                              leftPrompt: "With ease",
                              rightPrompt: "Need a lot of help")
                    
                    proSlider(title: "Drive / initiative",
                              value: $motivation,
                              onTouch: { touchedMotivation = true },
                              leftPrompt: "Engaged, active",
                              rightPrompt: "Withdrawn, detached or isolated")
                    
                    proSlider(title: "Hand use (writing/typing)",
                              value: $handwritingTyping,
                              onTouch: { touchedHandwriting = true },
                              leftPrompt: "Great with ease",
                              rightPrompt: "Completely illegible")
                    
                    proSlider(title: "Low mood",
                              value: $depression,
                              onTouch: { touchedDepression = true },
                              leftPrompt: "Mentally healthy",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Loss of interest (apathy)",
                              value: $lossOfInterest,
                              onTouch: { touchedLossOfInterest = true },
                              leftPrompt: "Active, engaged",
                              rightPrompt: "Severely withdrawn")
                    
                    proSlider(title: "Anxiety",
                              value: $anxiety,
                              onTouch: { touchedAnxiety = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Fatigue",
                              value: $fatigue,
                              onTouch: { touchedFatigue = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Involuntary movements (dyskinesia)",
                              value: $dyskinesia,
                              onTouch: { touchedDyskinesia = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe debilitating")
                    
                    proSlider(title: "Tremor",
                              value: $tremor,
                              onTouch: { touchedTremor = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe debilitating")
                    
                    proSlider(title: "Balance",
                              value: $balance,
                              onTouch: { touchedBalance = true },
                              leftPrompt: "Sturdy, steady",
                              rightPrompt: "Lose balance spontaneously")
                    
                    proSlider(title: "Temperature control issues (cold hands/feet or sweating)",
                              value: $temperatureControl,
                              onTouch: { touchedTemperature = true },
                              leftPrompt: "No problem",
                              rightPrompt: "Severe dysregulation")
                    
                    proSlider(title: "Dizzy on standing",
                              value: $dizzyOnStanding,
                              onTouch: { touchedDizzyOnStanding = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Visual disturbance",
                              value: $visualDisturbance,
                              onTouch: { touchedVisualDisturbance = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Insomnia (trouble sleeping)",
                              value: $insomnia,
                              onTouch: { touchedInsomnia = true },
                              leftPrompt: "Not a problem",
                              rightPrompt: "Severe problem")
                    
                    proSlider(title: "Acting out dreams (REM sleep behavior)",
                              value: $remSleepBehavior,
                              onTouch: { touchedREM = true },
                              leftPrompt: "None",
                              rightPrompt: "Yelling, kicking, interfering with sleep")
                    
                    proSlider(title: "Restless legs (urge to move)",
                              value: $restlessLeg,
                              onTouch: { touchedRestlessLeg = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Muscle cramping / pain",
                              value: $muscleCramping,
                              onTouch: { touchedMuscleCramping = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Speech",
                              value: $speech,
                              onTouch: { touchedSpeech = true },
                              leftPrompt: "Normal",
                              rightPrompt: "Not understandable most of the time")
                    
                    proSlider(title: "Drooling",
                              value: $drooling,
                              onTouch: { touchedDrooling = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Stooped posture",
                              value: $stoopedPosture,
                              onTouch: { touchedStoopedPosture = true },
                              leftPrompt: "Stand tall",
                              rightPrompt: "Severely stooped")
                    
                    proSlider(title: "Memory / forgetfulness",
                              value: $memoryForgetfulness,
                              onTouch: { touchedMemory = true },
                              leftPrompt: "Sharp",
                              rightPrompt: "Severe lapses")
                    
                    proSlider(title: "Comprehension",
                              value: $comprehension,
                              onTouch: { touchedComprehension = true },
                              leftPrompt: "Sharp",
                              rightPrompt: "Frequent confusion")
                    
                    proSlider(title: "Sense of smell",
                              value: $senseOfSmell,
                              onTouch: { touchedSmell = true },
                              leftPrompt: "No problem",
                              rightPrompt: "I can't smell a thing")
                    
                    proSlider(title: "Medication side effects",
                              value: $medicationSideEffects,
                              onTouch: { touchedMedicationSideEffects = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Sexual dysfunction (loss of libido, erectile dysfunction, difficulty with orgasm)",
                              value: $sexualDysfunction,
                              onTouch: { touchedSexualDysfunction = true },
                              leftPrompt: "Healthy",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Urinary symptoms (Dribbling, urgency, incontinence)",
                              value: $urinarySymptoms,
                              onTouch: { touchedUrinarySymptoms = true },
                              leftPrompt: "Healthy",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Hallucinations (seeing things that aren't there)",
                              value: $hallucinations,
                              onTouch: { touchedHallucinations = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Nausea",
                              value: $nausea,
                              onTouch: { touchedNausea = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    proSlider(title: "Daytime sleepiness",
                              value: $daytimeSleepiness,
                              onTouch: { touchedDaytimeSleepiness = true },
                              leftPrompt: "None",
                              rightPrompt: "Severe")
                    
                    VStack(alignment: .leading, spacing: 8) {
                Text("Cumulative score = Sum of all variables (0–10 each)").font(.footnote).foregroundStyle(.secondary)
                        Text("\(cumulativeScore)")
                            .font(.title3).fontWeight(.bold)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(12)
                    
                    NavigationLink("View PRO Trend") {
                        PROTrendView()
                            .environmentObject(vm)
                    }
                    .buttonStyle(.bordered)
                    
                    // Note: visualization removed per request; sliders only
                    
                    HStack(spacing: 12) {
                        Button("View Report") { showReport = true }
                            .buttonStyle(.bordered)
                        Button("Save PDF") {
                            if let data = generateReportPDF() {
                                sharePDFData = data
                                showShare = true
                            }
                        }
                            .buttonStyle(.borderedProminent)
                    }
                    
                    Button("Submit and View Report") { submit() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .disabled(false)
                }
                .padding()
            }
            .navigationTitle("PRO")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .onAppear { started = Date() }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                PROReportView().environmentObject(vm)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Save PDF") {
                                if let data = generateReportPDF() {
                                    sharePDFData = data
                                    showReport = false
                                    showShare = true
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("View Trend") {
                                PROTrendView().environmentObject(vm)
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showReport = false }
                        }
                    }
            }
            .environmentObject(vm)
        }
        .sheet(isPresented: $showShare) {
            if let data = sharePDFData {
                ShareSheet(items: [TemporaryFileData(data: data, suggestedName: "PRO-Report.pdf")])
            }
        }
    }
    
    private var allTouched: Bool {
        touchedSlowness &&
        touchedConstipation &&
        touchedWalking &&
        touchedFreezingGait &&
        touchedFalling &&
        touchedRising &&
        touchedADL &&
        touchedMotivation &&
        touchedHandwriting &&
        touchedDepression &&
        touchedLossOfInterest &&
        touchedAnxiety &&
        touchedFatigue &&
        touchedDyskinesia &&
        touchedTremor &&
        touchedBalance &&
        touchedTemperature &&
        touchedDizzyOnStanding &&
        touchedVisualDisturbance &&
        touchedInsomnia &&
        touchedREM &&
        touchedRestlessLeg &&
        touchedMuscleCramping &&
        touchedSpeech &&
        touchedDrooling &&
        touchedStoopedPosture &&
        touchedMemory &&
        touchedComprehension &&
        touchedSmell &&
        touchedMedicationSideEffects &&
        touchedSexualDysfunction &&
        touchedUrinarySymptoms &&
        touchedHallucinations &&
        touchedNausea &&
        touchedDaytimeSleepiness
    }
    
    private var cumulativeScore: Int {
        let values: [Double] = [
            slowness, constipation, walking, freezingGait, falling, risingFromSeated, adl, motivation,
            handwritingTyping, depression, lossOfInterest, anxiety, fatigue, dyskinesia, tremor, balance,
            temperatureControl, dizzyOnStanding, visualDisturbance, insomnia, remSleepBehavior, restlessLeg,
            muscleCramping, speech, drooling, stoopedPosture, memoryForgetfulness, comprehension, senseOfSmell,
            medicationSideEffects, sexualDysfunction, urinarySymptoms, hallucinations, nausea, daytimeSleepiness
        ]
        return values.map { Int($0) }.reduce(0, +)
    }
    
    private func symptomItems() -> [(String, Double)] {
        // Ordered to match the provided example (clockwise from top)
        [
            ("Slowness", slowness),
            ("Const", constipation),
            ("Walking", walking),
            ("Freeze", freezingGait),
            ("Rising", risingFromSeated),
            ("Dress", adl),
            ("Motiv", motivation),
            ("Writing", handwritingTyping),
            ("Depress", depression),
            ("Interest", lossOfInterest),
            ("Nausea", nausea),
            ("Anxiety", anxiety),
            ("Fatigue", fatigue),
            ("Sleepy", daytimeSleepiness),
            ("Dysk", dyskinesia),
            ("Tremor", tremor),
            ("Balance", balance),
            ("Dizzy", dizzyOnStanding),
            ("Visual", visualDisturbance),
            ("Insomnia", insomnia),
            ("RBD", remSleepBehavior),
            ("RL", restlessLeg),
            ("Pain", muscleCramping),
            ("Speech", speech),
            ("Drool", drooling),
            ("Stoop", stoopedPosture),
            ("Memory", memoryForgetfulness),
            ("Comp", comprehension),
            ("Smell", senseOfSmell),
            ("Sexual", sexualDysfunction),
            ("Urinary", urinarySymptoms),
            ("Halluc", hallucinations),
            ("Falls", falling),
            ("Temp", temperatureControl),
            ("MSE", medicationSideEffects)
        ]
    }
    
    private func mosaicItems() -> [(String, Double)] {
        // New wording; values are 0–100 and will be scaled in the mosaic legend as 0–10
        return [
            ("Movement ease", slowness * 10),
            ("Hand control", handwritingTyping * 10),
            ("Getting up", risingFromSeated * 10),
            ("Walking steadiness", walking * 10),
            ("Freezing episodes", freezingGait * 10),
            ("Fine motor tasks", adl * 10),
            ("Voice clarity", speech * 10),
            ("Saliva control", drooling * 10),
            ("Body discomfort", muscleCramping * 10),
            ("Muscle tightness", muscleCramping * 10),
            ("Sleep quality", insomnia * 10),
            ("Dream enactment", remSleepBehavior * 10),
            ("Restless legs", restlessLeg * 10),
            ("Daytime drowsiness", daytimeSleepiness * 10),
            ("Low mood", depression * 10),
            ("Worry / tension", anxiety * 10),
            ("Drive / initiative", motivation * 10),
            ("Thinking clarity", comprehension * 10),
            ("Word-finding", handwritingTyping * 10),
            ("Memory slips", memoryForgetfulness * 10),
            ("Lightheaded on standing", dizzyOnStanding * 10),
            ("Temperature control", temperatureControl * 10),
            ("Bowel regularity", constipation * 10),
            ("Bladder control", urinarySymptoms * 10),
            ("Sexual function", sexualDysfunction * 10),
            ("Visual misperception", visualDisturbance * 10),
            ("Smell / taste change", senseOfSmell * 10)
        ]
    }
    
    @ViewBuilder
    private func proSlider(title: String,
                           value: Binding<Double>,
                           onTouch: @escaping () -> Void,
                           leftPrompt: String,
                           rightPrompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                Text(leftPrompt).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(rightPrompt).font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...10, step: 1, onEditingChanged: { _ in onTouch() })
                .tint(.teal)
            HStack {
                Text("0").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.caption).monospacedDigit()
                Spacer()
                Text("10").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func submit() {
        let end = Date()
        var data: [String:String] = [
            "slowness_0_100": "\(Int(slowness * 10))",
            "constipation_0_100": "\(Int(constipation * 10))",
            "walking_0_100": "\(Int(walking * 10))",
            "freezing_of_gait_0_100": "\(Int(freezingGait * 10))",
            "falling_0_100": "\(Int(falling * 10))",
            "rising_from_seated_0_100": "\(Int(risingFromSeated * 10))",
            "dressing_eating_grooming_0_100": "\(Int(adl * 10))",
            "motivation_initiative_0_100": "\(Int(motivation * 10))",
            "handwriting_typing_0_100": "\(Int(handwritingTyping * 10))",
            "depression_0_100": "\(Int(depression * 10))",
            "loss_of_interest_0_100": "\(Int(lossOfInterest * 10))",
            "anxiety_0_100": "\(Int(anxiety * 10))"
        ]
        data["fatigue_0_100"] = "\(Int(fatigue * 10))"
        data["dyskinesia_0_100"] = "\(Int(dyskinesia * 10))"
        data["tremor_0_100"] = "\(Int(tremor * 10))"
        data["balance_0_100"] = "\(Int(balance * 10))"
        data["temperature_control_0_100"] = "\(Int(temperatureControl * 10))"
        data["dizzy_on_standing_0_100"] = "\(Int(dizzyOnStanding * 10))"
        data["visual_disturbance_0_100"] = "\(Int(visualDisturbance * 10))"
        data["insomnia_0_100"] = "\(Int(insomnia * 10))"
        data["rem_sleep_behavior_0_100"] = "\(Int(remSleepBehavior * 10))"
        data["restless_leg_0_100"] = "\(Int(restlessLeg * 10))"
        data["muscle_cramping_0_100"] = "\(Int(muscleCramping * 10))"
        data["speech_0_100"] = "\(Int(speech * 10))"
        data["drooling_0_100"] = "\(Int(drooling * 10))"
        data["stooped_posture_0_100"] = "\(Int(stoopedPosture * 10))"
        data["memory_forgetfulness_0_100"] = "\(Int(memoryForgetfulness * 10))"
        data["comprehension_0_100"] = "\(Int(comprehension * 10))"
        data["sense_of_smell_0_100"] = "\(Int(senseOfSmell * 10))"
        data["medication_side_effects_0_100"] = "\(Int(medicationSideEffects))"
        data["sexual_dysfunction_0_100"] = "\(Int(sexualDysfunction))"
        data["urinary_symptoms_0_100"] = "\(Int(urinarySymptoms))"
        data["hallucinations_0_100"] = "\(Int(hallucinations))"
        data["nausea_0_100"] = "\(Int(nausea))"
        data["daytime_sleepiness_0_100"] = "\(Int(daytimeSleepiness))"
        data["pro_cumulative_score"] = "\(cumulativeScore)"
        data.merge(deviceMeta(task: "PRO", taskVersion: "1.0", start: started, end: end, studyID: studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "PRO", data: data, notes: nil)
        onComplete(res)
        showReport = true
    }
    
    // MARK: PDF Export (ImageRenderer for reliable rendering)
    private func generateReportPDF() -> Data? {
        let reportView = PROReportView(forPDFExport: true)
            .environmentObject(vm)
            .frame(width: 850, height: 2000)
        let imageRenderer = ImageRenderer(content: reportView)
        imageRenderer.scale = 2.0
        guard let image = imageRenderer.uiImage else { return nil }
        let pageRect = CGRect(x: 0, y: 0, width: 850, height: 2000)
        let format = UIGraphicsPDFRendererFormat()
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            image.draw(in: pageRect)
        }
    }
}

// MARK: - PRO Radar (Symptom Wheel)
struct PRORadarView: View {
    let items: [(String, Double)] // label, 0-100
    var minorRingCount: Int = 16
    var majorRingValues: [Int] = [25, 50, 75, 100]
    var startAngleDegrees: Double = -90
    var accentColor: Color = .teal
    
    var body: some View {
        GeometryReader { geo in
            let n = max(items.count, 1)
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width/2, y: geo.size.height/2)
            let radius = size/2 - 28
            let startAngle = startAngleDegrees * .pi / 180.0
            
            ZStack {
                // Minor rings
                ForEach(1...minorRingCount, id:\.self) { ring in
                    let r = radius * CGFloat(ring) / CGFloat(minorRingCount)
                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .frame(width: r*2, height: r*2)
                        .position(center)
                }
                // Major rings
                ForEach(majorRingValues, id:\.self) { v in
                    let r = radius * CGFloat(Double(v) / 100.0)
                    Circle()
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: r*2, height: r*2)
                        .position(center)
                }
                // Spokes
                ForEach(0..<n, id:\.self) { i in
                    Path { path in
                        path.move(to: center)
                        let angle = startAngle + (2*Double.pi * Double(i)/Double(n))
                        let end = CGPoint(
                            x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius
                        )
                        path.addLine(to: end)
                    }
                    .stroke(i % 5 == 0 ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: i % 5 == 0 ? 1.5 : 1, dash: i % 5 == 0 ? [] : [2, 3]))
                }
                // Polygon area
                Path { path in
                    for i in 0..<n {
                        let value = max(0, min(100, items[i].1))
                        let r = radius * CGFloat(value / 100.0)
                        let angle = startAngle + (2*Double.pi * Double(i)/Double(n))
                        let p = CGPoint(
                            x: center.x + cos(angle) * r,
                            y: center.y + sin(angle) * r
                        )
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                }
                .fill(
                    RadialGradient(colors: [accentColor.opacity(0.35), accentColor.opacity(0.06)],
                                   center: .center, startRadius: 0, endRadius: radius)
                )
                
                Path { path in
                    for i in 0..<n {
                        let value = max(0, min(100, items[i].1))
                        let r = radius * CGFloat(value / 100.0)
                        let angle = startAngle + (2*Double.pi * Double(i)/Double(n))
                        let p = CGPoint(
                            x: center.x + cos(angle) * r,
                            y: center.y + sin(angle) * r
                        )
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                }
                .stroke(accentColor.opacity(0.9), lineWidth: 2.5)
                
                // Radial tick labels along right axis (distinct from reference)
                ForEach([0,25,50,75,100], id:\.self) { tick in
                    let r = radius * CGFloat(Double(tick) / 100.0)
                    let p = CGPoint(x: center.x + r, y: center.y)
                    Text("\(tick)")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .position(CGPoint(x: p.x, y: p.y - 10))
                }
                
                // Axis labels
                ForEach(Array(items.enumerated()), id:\.offset) { (i, item) in
                    let angle = startAngle + (2*Double.pi * Double(i)/Double(items.count))
                    let labelR = radius + 18
                    let p = CGPoint(
                        x: center.x + cos(angle) * labelR,
                        y: center.y + sin(angle) * labelR
                    )
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                        .position(p)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - PRO Mosaic (distinct visualization)
struct PROMosaicView: View {
    let items: [(String, Double)] // label, 0–100
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(items.enumerated()), id:\.offset) { _, it in
                let color = Color(hue: 0.65 - (min(max(it.1,0),100)/100.0) * 0.25, saturation: 0.7, brightness: 0.9)
                VStack(alignment: .leading, spacing: 6) {
                    Text(it.0).font(.caption).lineLimit(2)
                    Rectangle().fill(color).frame(height: 6).cornerRadius(3)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }
        }
    }
}

// MARK: - PRO 3D Bars (PDF symptom overview)
struct PROBars3DView: View {
    let items: [(String, Double)] // label, 0–100
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sorted = Array(items.sorted { $0.1 > $1.1 }.prefix(10))
            let barW = max(12, (w - 24) / CGFloat(max(sorted.count,1)))
            let depth: CGFloat = 6
            ZStack {
                // Baseline
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 22))
                    p.addLine(to: CGPoint(x: w, y: h - 22))
                }.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                
                ForEach(Array(sorted.enumerated()), id:\.offset) { idx, item in
                    let x = 12 + CGFloat(idx) * barW
                    let value = CGFloat(min(max(item.1, 0), 100)) / 100.0
                    let barH = (h - 40) * value
                    let baseY = h - 22
                    let color = Color(hue: 0.65 - Double(value) * 0.25, saturation: 0.7, brightness: 0.9)
                    
                    // 3D faces
                    // Front
                    Path { p in
                        p.addRoundedRect(in: CGRect(x: x, y: baseY - barH, width: barW * 0.7, height: barH), cornerSize: CGSize(width: 3, height: 3))
                    }.fill(color)
                    // Top
                    Path { p in
                        p.move(to: CGPoint(x: x, y: baseY - barH))
                        p.addLine(to: CGPoint(x: x + depth, y: baseY - barH - depth))
                        p.addLine(to: CGPoint(x: x + barW*0.7 + depth, y: baseY - barH - depth))
                        p.addLine(to: CGPoint(x: x + barW*0.7, y: baseY - barH))
                        p.closeSubpath()
                    }.fill(color.opacity(0.8))
                    // Side
                    Path { p in
                        p.move(to: CGPoint(x: x + barW*0.7, y: baseY))
                        p.addLine(to: CGPoint(x: x + barW*0.7 + depth, y: baseY - depth))
                        p.addLine(to: CGPoint(x: x + barW*0.7 + depth, y: baseY - barH - depth))
                        p.addLine(to: CGPoint(x: x + barW*0.7, y: baseY - barH))
                        p.closeSubpath()
                    }.fill(color.opacity(0.6))
                    
                    // Label
                    let label = item.0
                    Text(label)
                        .font(.caption2)
                        .lineLimit(2)
                        .frame(width: barW*0.9)
                        .position(x: x + barW*0.35, y: h - 8)
                }
            }
        }
    }
}

// MARK: - PRO Trend (Quality bands + time series)
struct PROTrendView: View {
    @EnvironmentObject private var vm: AppViewModel
    
    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
    }
    
    private var points: [Point] {
        let items = vm.historyStore.assessments
            .filter { $0.assessmentType == "PRO" }
            .sorted { $0.date < $1.date }
        return items.compactMap { a in
            if let s = a.data["pro_cumulative_score"], let v = Int(s) {
                return Point(date: a.date, value: v)
            } else {
                // Fallback: sum any *_0_100 fields
                let sum = a.data.filter { $0.key.hasSuffix("_0_100") }
                    .compactMap { Int($0.value) }
                    .reduce(0, +)
                return sum > 0 ? Point(date: a.date, value: sum) : nil
            }
        }
    }
    
    private var yMax: Double {
        let maxV = Double(points.map { $0.value }.max() ?? 0)
        return max(1500, ceil((maxV + 100) / 100) * 100)
    }
    
    private var bands: [(range: ClosedRange<Double>, color: Color, label: String)] {
        // Colors adjusted to be distinct from the screenshot
        let minimal = (0.0...600.0, Color.cyan.opacity(0.16), "Low burden")
        let moderate = (600.0...900.0, Color.indigo.opacity(0.14), "Moderate")
        let elevated = (900.0...1200.0, Color.purple.opacity(0.14), "Elevated")
        let severe = (1200.0...yMax, Color.gray.opacity(0.12), "Severe")
        return [minimal, moderate, elevated, severe]
            .map { (range: $0.0, color: $0.1, label: $0.2) }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Change in PRO Over Time")
                .font(.title2).fontWeight(.bold)
            GeometryReader { geo in
                let inset: CGFloat = 40
                let labelHeight: CGFloat = 24
                let plot = CGRect(x: inset,
                                  y: 8,
                                  width: geo.size.width - inset - inset,
                                  height: geo.size.height - 16 - labelHeight)
                
                ZStack {
                    // Background bands
                    ForEach(bands.indices, id:\.self) { i in
                        let b = bands[i]
                        let y1 = yToScreen(b.range.lowerBound, plot: plot)
                        let y2 = yToScreen(b.range.upperBound, plot: plot)
                        let rect = CGRect(x: plot.minX, y: y2, width: plot.width, height: y1 - y2)
                        Path { path in
                            path.addRect(rect)
                        }
                            .fill(b.color)
                        // Right-side labels centered in each band
                        Text(b.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .position(x: plot.maxX + 28, y: (y1 + y2) / 2)
                    }
                    
                    // Horizontal gridlines every 300
                    ForEach(stride(from: 0, through: Int(yMax), by: 300).map { $0 }, id:\.self) { val in
                        let y = yToScreen(Double(val), plot: plot)
                        Path { path in
                            path.move(to: CGPoint(x: plot.minX, y: y))
                            path.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4,4]))
                        Text("\(val)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .position(x: plot.minX - 18, y: y)
                    }
                    
                    // X-axis date labels
                    ForEach(Array(xAxisDateTicks(plot: plot).enumerated()), id: \.offset) { _, tick in
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .position(x: tick.xPosition, y: plot.maxY + labelHeight / 2)
                    }
                    
                    // Time-series path
                    if points.count >= 1 {
                        let xs = xPositions(plot: plot)
                        Path { path in
                            for (i, p) in points.enumerated() {
                                let x = xs[i]
                                let y = yToScreen(Double(p.value), plot: plot)
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.accentColor, lineWidth: 2)
                        
                        // Points
                        ForEach(Array(points.enumerated()), id:\.element.id) { (idx, p) in
                            let x = xPositions(plot: plot)[idx]
                            let y = yToScreen(Double(p.value), plot: plot)
                            Circle()
                                .fill(idx == points.count - 1 ? Color.accentColor : Color.accentColor.opacity(0.6))
                                .frame(width: 6, height: 6)
                                .position(x: x, y: y)
                        }
                    }
                }
            }
            .frame(height: 280)
            .padding(.horizontal)
            
            if let last = points.last {
                Text("Latest: \(last.value) on \(shortDate(last.date))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No PRO entries yet").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
    
    private func shortDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: date)
    }
    
    private func yToScreen(_ value: Double, plot: CGRect) -> CGFloat {
        let clamped = min(max(value, 0), yMax)
        // y=0 at bottom, yMax at top
        let t = clamped / yMax
        return plot.maxY - CGFloat(t) * plot.height
    }
    
    private func dateToX(_ date: Date, plot: CGRect) -> CGFloat {
        guard points.count > 1 else {
            return plot.minX + plot.width * 0.5
        }
        let minD = points.first!.date.timeIntervalSince1970
        let maxD = points.last!.date.timeIntervalSince1970
        let span = max(maxD - minD, 1)
        let t = (date.timeIntervalSince1970 - minD) / span
        if points.count <= 3 {
            let paddedT = 0.05 + t * 0.9
            return plot.minX + CGFloat(paddedT) * plot.width
        }
        return plot.minX + CGFloat(t) * plot.width
    }
    
    private func xPositions(plot: CGRect) -> [CGFloat] {
        guard points.count > 1 else {
            return [plot.minX + plot.width * 0.5]
        }
        let minD = points.first!.date.timeIntervalSince1970
        let maxD = points.last!.date.timeIntervalSince1970
        let span = max(maxD - minD, 1)
        let usePadding = points.count <= 3
        return points.map { p in
            let t = (p.date.timeIntervalSince1970 - minD) / span
            let paddedT = usePadding ? (0.05 + t * 0.9) : t
            return plot.minX + CGFloat(paddedT) * plot.width
        }
    }
    
    private func xAxisDateTicks(plot: CGRect) -> [(date: Date, xPosition: CGFloat, label: String)] {
        guard !points.isEmpty else { return [] }
        let minDate = points.first!.date
        let maxDate = points.last!.date
        let spanSeconds = max(maxDate.timeIntervalSince(minDate), 1)
        let spanDays = spanSeconds / 86400
        
        func formatDate(_ d: Date, format: String) -> String {
            let df = DateFormatter()
            df.dateFormat = format
            return df.string(from: d)
        }
        
        var tickDates: [Date] = []
        
        if points.count <= 2 {
            tickDates = [minDate, maxDate]
            if points.count == 1 {
                tickDates = [minDate]
            } else if spanDays > 0.5 {
                let mid = Date(timeIntervalSince1970: (minDate.timeIntervalSince1970 + maxDate.timeIntervalSince1970) / 2)
                tickDates = [minDate, mid, maxDate]
            }
        } else if spanDays < 7 {
            let nTicks = min(5, max(2, Int(spanDays) + 1))
            let step = spanSeconds / Double(max(nTicks - 1, 1))
            for i in 0..<nTicks {
                tickDates.append(Date(timeIntervalSince1970: minDate.timeIntervalSince1970 + step * Double(i)))
            }
        } else if spanDays <= 60 {
            let nTicks = min(8, max(5, Int(spanDays / 7) + 1))
            let step = spanSeconds / Double(max(nTicks - 1, 1))
            for i in 0..<nTicks {
                tickDates.append(Date(timeIntervalSince1970: minDate.timeIntervalSince1970 + step * Double(i)))
            }
        } else if spanDays <= 365 {
            let nTicks = min(8, max(6, Int(spanDays / 60) + 1))
            let step = spanSeconds / Double(max(nTicks - 1, 1))
            for i in 0..<nTicks {
                tickDates.append(Date(timeIntervalSince1970: minDate.timeIntervalSince1970 + step * Double(i)))
            }
        } else {
            let nTicks = min(10, max(6, Int(spanDays / 90) + 1))
            let step = spanSeconds / Double(max(nTicks - 1, 1))
            for i in 0..<nTicks {
                tickDates.append(Date(timeIntervalSince1970: minDate.timeIntervalSince1970 + step * Double(i)))
            }
        }
        
        let format: String
        if spanDays < 7 { format = "M/d" }
        else if spanDays <= 60 { format = "M/d" }
        else if spanDays <= 365 { format = "MMM yyyy" }
        else { format = "MMM yy" }
        
        return tickDates.map { d in
            (date: d, xPosition: dateToX(d, plot: plot), label: formatDate(d, format: format))
        }
    }
}

// MARK: - PRO Report (View + PDF content)
struct PROReportView: View {
    @EnvironmentObject private var vm: AppViewModel
    var forPDFExport: Bool = false
    
    private var latestPRO: AssessmentResult? {
        vm.historyStore.assessments.first { $0.assessmentType == "PRO" }
    }
    private var latestScore: Int {
        if let s = latestPRO?.data["pro_cumulative_score"], let v = Int(s) { return v }
        let sum = latestPRO?.data.filter { $0.key.hasSuffix("_0_100") }.compactMap { Int($0.value) }.reduce(0, +) ?? 0
        return sum
    }
    private var yearsSinceDxText: String {
        let yearStr = vm.participant.pdDiagnosisYear
        if let y = Int(yearStr), y > 1900 {
            let yrs = max(0, Calendar.current.component(.year, from: Date()) - y)
            return "\(yrs) years"
        }
        return "No diagnosis"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Clean header
            VStack(spacing: 12) {
                Text("PRO Symptom Report")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 20) {
                    Label(shortDate(Date()), systemImage: "calendar")
                    Label("Study ID: \(vm.studyID)", systemImage: "person.text.rectangle")
                    Label("Total: \(latestScore)", systemImage: "number")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemBackground))
            
            // Main content: Radar + Domain cards (VStack for PDF so full content renders)
            Group {
                if forPDFExport {
                    reportContent.padding(16)
                } else {
                    ScrollView { reportContent.padding(16) }
                }
            }
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
    }
    
    @ViewBuilder
    private var reportContent: some View {
        VStack(spacing: 24) {
            if !domainRadarItems().isEmpty {
                VStack(spacing: 12) {
                    Text("Symptom Domains (0 = healthy, 100 = severe)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PRORadarView(items: domainRadarItems(), accentColor: .teal)
                        .frame(height: 320)
                        .padding(.horizontal, 8)
                }
                .padding(.vertical, 16)
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
            LazyVStack(spacing: 16) {
                ForEach(domainSections(), id: \.name) { section in
                    PRODomainCardView(section: section)
                }
            }
            PROTrendView().environmentObject(vm)
                .frame(height: 200)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            Text("© 2026 Henry Ford Health")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
    }
    
    private func shortDate(_ d: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; return df.string(from: d)
    }
    
    // Domain mapping: symptom key -> domain
    private static let domainMapping: [(String, String)] = [
        ("slowness_0_100", "Motor"), ("tremor_0_100", "Motor"), ("dyskinesia_0_100", "Motor"),
        ("handwriting_typing_0_100", "Motor"), ("balance_0_100", "Motor"), ("stooped_posture_0_100", "Motor"),
        ("drooling_0_100", "Motor"), ("muscle_cramping_0_100", "Motor"), ("rising_from_seated_0_100", "Motor"),
        ("dressing_eating_grooming_0_100", "Motor"), ("speech_0_100", "Motor"),
        ("walking_0_100", "Gait"), ("freezing_of_gait_0_100", "Gait"), ("falling_0_100", "Gait"),
        ("memory_forgetfulness_0_100", "Cognitive"), ("comprehension_0_100", "Cognitive"),
        ("sense_of_smell_0_100", "Cognitive"),
        ("depression_0_100", "Mood"), ("anxiety_0_100", "Mood"), ("motivation_initiative_0_100", "Mood"),
        ("loss_of_interest_0_100", "Mood"), ("fatigue_0_100", "Mood"),
        ("insomnia_0_100", "Sleep"), ("rem_sleep_behavior_0_100", "Sleep"),
        ("restless_leg_0_100", "Sleep"), ("daytime_sleepiness_0_100", "Sleep"),
        ("urinary_symptoms_0_100", "Genitourinary"), ("sexual_dysfunction_0_100", "Genitourinary"),
        ("temperature_control_0_100", "Autonomic"), ("dizzy_on_standing_0_100", "Autonomic"),
        ("constipation_0_100", "Autonomic"), ("nausea_0_100", "Autonomic"),
        ("medication_side_effects_0_100", "Autonomic"), ("visual_disturbance_0_100", "Autonomic"),
        ("hallucinations_0_100", "Autonomic")
    ]
    
    private static let symptomDisplayNames: [String: String] = [
        "slowness_0_100": "Slowness", "tremor_0_100": "Tremor", "dyskinesia_0_100": "Dyskinesia",
        "handwriting_typing_0_100": "Handwriting/typing", "balance_0_100": "Balance",
        "stooped_posture_0_100": "Stooped posture", "drooling_0_100": "Drooling",
        "muscle_cramping_0_100": "Muscle cramping", "rising_from_seated_0_100": "Rising from seated",
        "dressing_eating_grooming_0_100": "Dressing, eating, grooming", "speech_0_100": "Speech",
        "walking_0_100": "Walking", "freezing_of_gait_0_100": "Freezing of gait", "falling_0_100": "Falling",
        "memory_forgetfulness_0_100": "Memory/forgetfulness", "comprehension_0_100": "Comprehension",
        "sense_of_smell_0_100": "Sense of smell", "depression_0_100": "Depression",
        "anxiety_0_100": "Anxiety", "motivation_initiative_0_100": "Motivation/initiative",
        "loss_of_interest_0_100": "Loss of interest", "fatigue_0_100": "Fatigue",
        "insomnia_0_100": "Insomnia", "rem_sleep_behavior_0_100": "REM sleep behavior",
        "restless_leg_0_100": "Restless legs", "daytime_sleepiness_0_100": "Daytime sleepiness",
        "urinary_symptoms_0_100": "Urinary symptoms", "sexual_dysfunction_0_100": "Sexual dysfunction",
        "temperature_control_0_100": "Temperature control", "dizzy_on_standing_0_100": "Dizzy on standing",
        "constipation_0_100": "Constipation", "nausea_0_100": "Nausea",
        "medication_side_effects_0_100": "Medication side effects",
        "visual_disturbance_0_100": "Visual disturbance", "hallucinations_0_100": "Hallucinations"
    ]
    
    private static let domainOrder = ["Motor", "Gait", "Cognitive", "Mood", "Sleep", "Genitourinary", "Autonomic"]
    
    static func domainColor(_ name: String) -> Color {
        switch name {
        case "Motor": return Color.blue
        case "Gait": return Color.green
        case "Cognitive": return Color.purple
        case "Mood": return Color.orange
        case "Sleep": return Color.indigo
        case "Genitourinary": return Color.pink
        case "Autonomic": return Color.teal
        default: return Color.gray
        }
    }
    
    private func domainRadarItems() -> [(String, Double)] {
        guard let a = latestPRO else { return [] }
        var domainSums: [String: (sum: Double, count: Int)] = [:]
        for (key, domain) in Self.domainMapping {
            if let s = a.data[key], let v = Double(s) {
                var cur = domainSums[domain] ?? (0, 0)
                cur.sum += v
                cur.count += 1
                domainSums[domain] = cur
            }
        }
        return Self.domainOrder.compactMap { name in
            guard let cur = domainSums[name], cur.count > 0 else { return nil }
            let avg = cur.sum / Double(cur.count)
            return (name, min(100, max(0, avg)))
        }
    }
    
    struct DomainSection: Identifiable {
        let id = UUID()
        let name: String
        let averageScore: Double
        let symptoms: [(String, Int)]
    }
    
    private func domainSections() -> [DomainSection] {
        guard let a = latestPRO else { return [] }
        var byDomain: [String: [(String, Int)]] = [:]
        for (key, domain) in Self.domainMapping {
            if let s = a.data[key], let v = Int(s) {
                let display = Self.symptomDisplayNames[key] ?? key
                byDomain[domain, default: []].append((display, v))
            }
        }
        return Self.domainOrder.compactMap { name in
            guard let syms = byDomain[name], !syms.isEmpty else { return nil }
            let avg = Double(syms.map { $0.1 }.reduce(0, +)) / Double(syms.count)
            return DomainSection(name: name, averageScore: avg, symptoms: syms)
        }
    }
}

// MARK: - PRO Domain Card
private struct PRODomainCardView: View {
    let section: PROReportView.DomainSection
    
    var body: some View {
        let color = PROReportView.domainColor(section.name)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.name)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                Text("Avg: \(Int(round(section.averageScore)))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.symptoms, id: \.0) { (name, value) in
                    HStack {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(value)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(16)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }
}

// MARK: - HealthKit Import View
struct HealthKitImportView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: String = "Not connected"
    @State private var importing = false
    @State private var lastImported: [String:String] = [:]
    
    private static let keyLabels: [String: String] = [
        "steps_30d": "Steps",
        "sleep_hours_30d": "Sleep (hrs)",
        "resting_hr_bpm_avg_30d": "Resting HR (bpm)",
        "hrv_sdnn_ms_avg_30d": "HRV SDNN (ms)",
        "distance_km_30d": "Distance (km)",
        "walking_speed_mps_avg_30d": "Walking Speed (m/s)",
        "walking_step_length_cm_avg_30d": "Step Length (cm)",
        "walking_asymmetry_pct_avg_30d": "Walking Asymmetry (%)",
        "walking_double_support_pct_avg_30d": "Double Support (%)",
        "walking_steadiness_pct_avg_30d": "Walking Steadiness (%)",
        "falls_count_30d": "Falls",
        "flights_climbed_30d": "Flights Climbed",
        "active_calories_30d": "Active Calories",
        "exercise_minutes_30d": "Exercise (min)"
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Apple Health").font(.title2).fontWeight(.bold)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
                if importing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Importing…")
                    }
                } else {
                    Button("Connect & Import last 30 days") {
                        startImport()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !lastImported.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest summary:").font(.headline)
                        ForEach(lastImported.keys.sorted(), id:\.self) { k in
                            Text("\(Self.keyLabels[k] ?? k): \(lastImported[k] ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Health Data")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
    
    private func startImport() {
        guard HealthKitManager.shared.isAvailable() else {
            status = "Health data not available on this device (HealthKit not supported in Simulator)."
            return
        }
        importing = true
        HealthKitManager.shared.requestAuthorization { ok, err in
            DispatchQueue.main.async {
                if !ok {
                    self.status = "Authorization failed: \(err?.localizedDescription ?? "Unknown")"
                    self.importing = false
                    return
                }
                self.status = "Authorized"
                HealthKitManager.shared.fetch30DaySummary { dict in
                    self.lastImported = dict
                    self.importing = false
                    let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                    var data = dict
                    data.merge(deviceMeta(task: "HealthKit", taskVersion: "1.0", start: start, end: Date(), studyID: studyID)) { _, n in n }
                    let res = AssessmentResult(id: UUID(), date: Date(), studyID: studyID, assessmentType: "HealthKit", data: data, notes: "30-day summary")
                    onComplete(res)
                }
            }
        }
    }
}

private struct PROTableView: View {
    let items: [(String, Int)]
    var body: some View {
        let left = Array(items.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element })
        let right = Array(items.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element })
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(left.indices, id:\.self) { i in
                    row(left[i])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(right.indices, id:\.self) { i in
                    row(right[i])
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
    private func row(_ item: (String, Int)) -> some View {
        HStack {
            Text(item.0).font(.caption)
            Spacer()
            Text("\(item.1)").font(.caption).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Share helpers

final class TemporaryFileData: NSObject, UIActivityItemSource {
    let data: Data
    let suggestedName: String
    private let fileURL: URL
    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try? data.write(to: url, options: .atomic)
        self.fileURL = url
    }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        fileURL
    }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        fileURL
    }
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        suggestedName
    }
    deinit {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - AE Safety Sheet
struct AESheet: View {
    var onSubmit: (_ selectedSymptoms: [String]) -> Void
    @State private var selectedSymptoms: Set<String> = []
    private let options = ["Chest pain", "Palpitations", "Rash", "Severe insomnia", "Other"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Select all symptoms that occurred since the last month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Symptoms") {
                    ForEach(options, id: \.self) { option in
                        Toggle(option, isOn: Binding(
                            get: { selectedSymptoms.contains(option) },
                            set: { isOn in
                                if isOn { selectedSymptoms.insert(option) }
                                else { selectedSymptoms.remove(option) }
                            }
                        ))
                    }
                }
            }
            .navigationTitle("Safety Check")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("None") { selectedSymptoms.removeAll() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit") { onSubmit(Array(selectedSymptoms).sorted()) }
                }
            }
        }
    }
}

// MARK: - Motor Flow View (now includes AE step at end)
private struct MotorOneOffKey: Identifiable, Hashable {
    let id: String
}

/// PULSE-PD & ASCEND-SVD: run the full motor sequence. Personal & Custom: pick a single test.
struct MotorFlowView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentTest = 0
    @State private var results: [AssessmentResult] = []
    @State private var isTransitioning = false
    @State private var showAE = false
    @State private var activeOneOffMotor: MotorOneOffKey?
    
    private var useOneOffMotor: Bool {
        vm.trial == .personal || vm.trial == .custom
    }
    
    /// One-off list: Personal uses the six core modules; Custom uses the full list (minus Gait/Balance if HealthKit is active).
    private var oneOffMotorTests: [String] {
        if vm.trial == .personal {
            return ["Blink Rate", "Voice", "Reaction Time", "Tapping3", "TremorR", "TremorL"]
        }
        let full = ["Blink Rate", "Reaction Time", "Tapping3", "Voice", "TremorR", "TremorL", "Gait", "Balance"]
        let healthKitActive = vm.historyStore.assessments.contains { $0.assessmentType == "HealthKit" }
        if healthKitActive {
            return full.filter { $0 != "Gait" && $0 != "Balance" }
        }
        return full
    }
    
    /// Study arms: full sequence, excluding Gait/Balance when HealthKit import is present.
    private var sequentialMotorTests: [String] {
        let full = ["Blink Rate", "Reaction Time", "Tapping3", "Voice", "TremorR", "TremorL", "Gait", "Balance"]
        let healthKitActive = vm.historyStore.assessments.contains { $0.assessmentType == "HealthKit" }
        if healthKitActive {
            return full.filter { $0 != "Gait" && $0 != "Balance" }
        }
        return full
    }
    
    var body: some View {
        Group {
            if useOneOffMotor {
                oneOffMotorMenu
            } else {
                sequentialMotorFlow
            }
        }
    }
    
    private var oneOffMotorMenu: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose one movement test to run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(oneOffMotorTests, id: \.self) { key in
                    Button {
                        activeOneOffMotor = MotorOneOffKey(id: key)
                    } label: {
                        Text(key)
                    }
                }
            }
            .navigationTitle("Motor Assessment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
            .fullScreenCover(item: $activeOneOffMotor) { item in
                NavigationStack {
                    motorSubview(for: item.id, onComplete: handleOneOffCompletion)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") { activeOneOffMotor = nil }
                            }
                        }
                }
            }
        }
    }
    
    private var sequentialMotorFlow: some View {
        NavigationStack {
            VStack {
                if isTransitioning {
                    VStack(spacing: 20) { ProgressView(); Text("Loading next test...").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if currentTest < sequentialMotorTests.count {
                    VStack(spacing: 16) {
                        Text("Test \(currentTest + 1) of \(sequentialMotorTests.count)").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(currentTest), total: Double(sequentialMotorTests.count)).padding(.horizontal)
                        motorSubview(for: sequentialMotorTests[currentTest], onComplete: handleCompletion)
                    }
                } else {
                    completionView
                }
            }
            .sheet(isPresented: Binding(
                get: { showAE && vm.trial != .personal },
                set: { if !$0 { showAE = false } }
            )) {
                AESheet { selectedSymptoms in
                    let urgentSet: Set<String> = ["Chest pain", "Palpitations", "Severe insomnia", "Severe anxiety"]
                    for symptom in selectedSymptoms {
                        let urgency = urgentSet.contains(symptom) ? "urgent" : "routine"
                        NetworkService.shared.sendAEAlert(studyID: vm.studyID, category: symptom, urgency: urgency)
                    }
                    dismiss()
                }
            }
            .navigationTitle("Motor Assessment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Exit") { dismiss() } }
            }
        }
    }
    
    private func handleOneOffCompletion(_ result: AssessmentResult) {
        vm.saveAssessment(result)
        activeOneOffMotor = nil
    }
    
    @ViewBuilder
    private func motorSubview(for key: String, onComplete: @escaping (AssessmentResult) -> Void) -> some View {
        switch key {
        case "Tapping3":
            TappingBatteryView(studyID: vm.studyID, onComplete: onComplete)
        case "TremorR":
            TremorTestView(studyID: vm.studyID, side: .right, onComplete: onComplete)
        case "TremorL":
            TremorTestView(studyID: vm.studyID, side: .left, onComplete: onComplete)
        case "Gait":
            GaitTestView(studyID: vm.studyID, onComplete: onComplete)
        case "Balance":
            BalanceTestView(studyID: vm.studyID, onComplete: onComplete)
        case "Voice":
            VoiceTestView(studyID: vm.studyID, onComplete: onComplete)
        case "Blink Rate":
            BlinkTestView_Vision(studyID: vm.studyID, onComplete: onComplete)
        case "Reaction Time":
            ReactionTimeTestView(studyID: vm.studyID, onComplete: onComplete)
        default:
            EmptyView()
        }
    }
    
    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("All Tests Complete!").font(.title2).fontWeight(.semibold)
            Text("\(results.count) motor assessments saved").foregroundStyle(.secondary)
            Button("Continue to Safety Check") { showAE = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private func handleCompletion(_ result: AssessmentResult) {
        guard !isTransitioning else { return }
        results.append(result); vm.saveAssessment(result)
        isTransitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            currentTest += 1; isTransitioning = false
        }
    }
}

// MARK: - Cognitive View (unchanged metrics + metadata)
struct CognitiveView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentPhase = 0
    @State private var story: StoryGenerator.Story
    @State private var responses: [String: String] = [:]
    @State private var distractorSelections: [Int] = []
    @State private var startTime = Date()
    
    let correctSequence = [93, 86, 79, 72, 65]
    let allNumbers = [93, 86, 79, 72, 65, 90, 83, 76, 69, 62]
    
    init() { _story = State(initialValue: StoryGenerator.generateRandomStory()) }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(Array(0..<3), id: \.self) { index in
                        Circle().fill(index == currentPhase ? Color.blue : Color.gray.opacity(0.3)).frame(width: 12, height: 12)
                    }
                }.padding(.top)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch currentPhase {
                        case 0: storyPhase
                        case 1: distractorPhase
                        case 2: recallPhase
                        default: EmptyView()
                        }
                    }.padding()
                }
                Spacer()
                HStack(spacing: 16) {
                    if currentPhase < 2 {
                        Button("Next") { currentPhase += 1 }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    } else {
                        Button("Finish") { submit() }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                            .disabled(!recallComplete)
                    }
                }.padding()
            }
            .navigationTitle("Memory Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
    
    private var storyPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Please read this story carefully. You'll be asked about it later.").font(.subheadline).foregroundStyle(.secondary)
            Text(story.text).font(.title3).padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1)).cornerRadius(12)
            Text("Take your time to memorize the details.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var distractorPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Count backwards from 100 by 7").font(.headline)
            Text("Tap the numbers in order:").font(.subheadline).foregroundStyle(.secondary)
            Text("100 → 93 → 86 → 79 → 72 → 65").font(.caption).foregroundStyle(.secondary).padding(.bottom)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                ForEach(allNumbers.shuffled(), id: \.self) { number in
                    Button {
                        selectNumber(number)
                    } label: {
                        Text("\(number)").font(.title3).fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding()
                            .background(distractorSelections.contains(number) ? Color.green.opacity(0.2) : Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    }.disabled(distractorSelections.contains(number))
                }
            }
            if !distractorSelections.isEmpty {
                Text("Your sequence: \(distractorSelections.map(String.init).joined(separator: " → "))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var recallPhase: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Now answer these questions about the story:").font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                QuestionField(question: "Full name?", answer: binding(for: "name"))
                QuestionField(question: "Street address?", answer: binding(for: "address"))
                QuestionField(question: "City?", answer: binding(for: "city"))
                QuestionField(question: "Occupation?", answer: binding(for: "occupation"))
            }
        }
    }
    private func binding(for key: String) -> Binding<String> {
        Binding(get: { responses[key] ?? "" }, set: { responses[key] = $0 })
    }
    private var recallComplete: Bool {
        ["name", "address", "city", "occupation"].allSatisfy { !responses[$0, default: ""].isEmpty }
    }
    private func selectNumber(_ number: Int) { distractorSelections.append(number) }
    private func submit() {
        let end = Date()
        var score = 0
        if responses["name", default: ""].lowercased() == story.name.lowercased() { score += 1 }
        if responses["address", default: ""].lowercased() == story.address.lowercased() { score += 1 }
        if responses["city", default: ""].lowercased() == story.city.lowercased() { score += 1 }
        if responses["occupation", default: ""].lowercased() == story.occupation.lowercased() { score += 1 }
        var data = responses
        data["score"] = "\(score)"
        data["duration"] = "\(Int(end.timeIntervalSince(startTime)))"
        data["distractor"] = distractorSelections.map(String.init).joined(separator: ",")
        data["story"] = story.text
        data.merge(deviceMeta(task: "Cognitive", taskVersion: "1.0", start: startTime, end: end, studyID: vm.studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "Cognitive", data: data, notes: "Score: \(score)/4")
        playChime(); vm.saveAssessment(result); dismiss()
    }
}

// MARK: - Pulse-PD Cognitive (Multiple Choice)
struct PulseCognitiveMCQView: View {
    let studyID: String
    let allowSkip: Bool
    var dismissOnComplete: Bool = true
    let onComplete: (AssessmentResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var story = StoryGenerator.generateRandomStory()
    @State private var step = 0 // 0=story, 1+ = questions
    @State private var current = 0
    @State private var selections: [Int?] = Array(repeating: nil, count: 5)
    @State private var started = Date()
    
    private struct MCQ {
        let prompt: String
        let options: [String]
        let correct: Int
    }
    
    @State private var questions: [MCQ] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if step == 0 {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Please read this short story. You'll answer questions about it next.")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(story.text)
                            .font(.title3)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(12)
                    }
                    .padding()
                    Button("Begin Questions") { withAnimation { step = 1 } }
                        .buttonStyle(.borderedProminent)
                        .font(.title3)
                } else {
                    let q = questions[current]
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Question \(current+1) of \(questions.count)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(q.prompt)
                                .font(.largeTitle)
                                .fontWeight(.semibold)
                                .minimumScaleFactor(0.75)
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(q.options.enumerated()), id:\.offset) { idx, opt in
                                Button {
                                    selections[current] = idx
                                } label: {
                                    HStack(alignment: .top, spacing: 14) {
                                        Image(systemName: selections[current] == idx ? "largecircle.fill.circle" : "circle")
                                            .font(.title)
                                            .frame(width: 36, alignment: .center)
                                        Text(opt)
                                            .font(.title2)
                                            .fontWeight(.medium)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 14)
                                    .padding(.horizontal, 12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                }
                            }
                            HStack {
                                if current > 0 {
                                    Button("Back") { current -= 1 }.buttonStyle(.bordered).font(.title3)
                                }
                                Spacer()
                                if current < questions.count - 1 {
                                    Button("Next") { current += 1 }.buttonStyle(.borderedProminent).disabled(selections[current] == nil).font(.title3)
                                } else {
                                    Button("Finish") { finish() }.buttonStyle(.borderedProminent).disabled(selections[current] == nil).font(.title3)
                                }
                            }.padding(.top, 8)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Cognitive (MCQ)")
            .toolbar {
                if allowSkip {
                    ToolbarItem(placement: .topBarLeading) { Button("Skip") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
        .onAppear {
            started = Date()
            if questions.isEmpty {
                generateQuestions()
            }
        }
    }
    
    private func finish() {
        let end = Date()
        let qs = questions
        var score = 0
        for i in 0..<qs.count {
            if selections[i] == qs[i].correct { score += 1 }
        }
        var data: [String:String] = [
            "score": "\(score)",
            "total": "\(qs.count)",
            "story": story.text
        ]
        for i in 0..<qs.count {
            data["q\(i+1)_sel"] = selections[i].map { "\( $0 )" } ?? ""
            data["q\(i+1)_correct"] = "\(qs[i].correct)"
        }
        data.merge(deviceMeta(task: "Cognitive", taskVersion: "mcq-1.0", start: started, end: end, studyID: studyID)) { _, n in n }
        let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Cognitive", data: data, notes: "MCQ score \(score)/\(qs.count)")
        onComplete(res)
        if dismissOnComplete { dismiss() }
    }
    
    private func randomNames() -> [String] { (StoryGenerator.names1 + StoryGenerator.names2).shuffled() }
    private func randomAddresses() -> [String] { (StoryGenerator.addresses1 + StoryGenerator.addresses2).shuffled() }
    private func randomCities() -> [String] { (StoryGenerator.cities1 + StoryGenerator.cities2).shuffled() }
    private func randomJobs() -> [String] { (StoryGenerator.jobs1 + StoryGenerator.jobs2).shuffled() }
    
    private func shuffledOptions(correct: String, pool: [String]) -> (options: [String], correctIndex: Int) {
        var opts = Set<String>([correct])
        for item in pool where opts.count < 4 { opts.insert(item) }
        var arr = Array(opts).shuffled()
        if !arr.contains(correct) { arr[0] = correct; arr.shuffle() }
        let idx = arr.firstIndex(of: correct) ?? 0
        return (arr, idx)
    }
    
    private func generateQuestions() {
        // Build once per session so choices don't reshuffle on state changes
        let nameOpts = shuffledOptions(correct: story.name, pool: randomNames())
        let addrOpts = shuffledOptions(correct: story.address, pool: randomAddresses())
        let cityOpts = shuffledOptions(correct: story.city, pool: randomCities())
        let jobOpts = shuffledOptions(correct: story.occupation, pool: randomJobs())
        let gistOpts = [
            "A person, their job, and where they live",
            "A weather report",
            "Instructions for baking",
            "A sports recap"
        ]
        questions = [
            MCQ(prompt: "What was the person's full name?", options: nameOpts.options, correct: nameOpts.correctIndex),
            MCQ(prompt: "What is the street address?", options: addrOpts.options, correct: addrOpts.correctIndex),
            MCQ(prompt: "Which city do they live in?", options: cityOpts.options, correct: cityOpts.correctIndex),
            MCQ(prompt: "What is their occupation?", options: jobOpts.options, correct: jobOpts.correctIndex),
            MCQ(prompt: "What was the story generally about?", options: gistOpts, correct: 0)
        ]
    }
}

// MARK: - Pulse-PD Cognitive Menu (MCQ, Stroop, Trails)
/// Runs MCQ → Stroop → Flanker → Trails A → Trails B in order without returning to the menu between tests.
struct PulseCognitiveBatteryView: View {
    let studyID: String
    let onEachResult: (AssessmentResult) -> Void
    /// Called after Trail B result is saved (last step of the ordered battery).
    var onBatteryComplete: (() -> Void)? = nil
    @State private var step = 0
    
    var body: some View {
        Group {
            switch step {
            case 0:
                PulseCognitiveMCQView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 1 }
            case 1:
                StroopTestView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 2 }
            case 2:
                FlankerTestView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 3 }
            case 3:
                TrailMakingTestView(studyID: studyID, mode: .a, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 4 }
            case 4:
                TrailMakingTestView(studyID: studyID, mode: .b, allowSkip: false, dismissOnComplete: false) { r in
                    onEachResult(r)
                    onBatteryComplete?()
                }
            default:
                EmptyView()
            }
        }
    }
}

struct PulseCognitiveMenuView: View {
    let studyID: String
    let allowSkip: Bool
    /// Personal / Custom: pick one test. PULSE-PD: full battery only.
    var allowOneOff: Bool = false
    let onComplete: (AssessmentResult) -> Void
    var onBatteryComplete: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showBattery = false
    @State private var showMCQ = false
    @State private var showStroop = false
    @State private var showTrailsA = false
    @State private var showTrailsB = false
    @State private var showFlanker = false
    
    var body: some View {
        NavigationStack {
            List {
                if !allowOneOff {
                    Section {
                        Button { showBattery = true } label: {
                            HStack {
                                Image(systemName: "list.number")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Run all tests in order")
                                    Text("Story questions → Stroop → Flanker → Trail A → Trail B")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if allowOneOff {
                    Section("Choose a test") {
                    Button { showMCQ = true } label: {
                        HStack { Image(systemName:"text.book.closed"); Text("Story Questions (Multiple Choice)") ; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showStroop = true } label: {
                        HStack { Image(systemName:"textformat"); Text("Stroop (ink color)") ; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showFlanker = true } label: {
                        HStack { Image(systemName:"arrow.left.and.right"); Text("Flanker (arrows)") ; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showTrailsA = true } label: {
                        HStack { Image(systemName:"1.circle"); Text("Trail Making A (1→12)") ; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showTrailsB = true } label: {
                        HStack { Image(systemName:"a.circle"); Text("Trail Making B (1→A→2→B)") ; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    }
                }
            }
            .navigationTitle("Cognitive Tests")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .fullScreenCover(isPresented: $showBattery) {
                PulseCognitiveBatteryView(studyID: studyID, onEachResult: onComplete, onBatteryComplete: {
                    showBattery = false
                    onBatteryComplete?()
                })
            }
            .sheet(isPresented: $showMCQ) {
                PulseCognitiveMCQView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showStroop) {
                StroopTestView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showFlanker) {
                FlankerTestView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showTrailsA) {
                TrailMakingTestView(studyID: studyID, mode: .a, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showTrailsB) {
                TrailMakingTestView(studyID: studyID, mode: .b, allowSkip: allowSkip) { res in onComplete(res) }
            }
        }
    }
}

// MARK: - ASCEND-SVD Cognitive Battery
/// Stroop → Flanker → Trail A → Trail B → Digit Span (study arms); Personal/Custom use the menu only.
struct AscendCognitiveBatteryView: View {
    let studyID: String
    let onEachResult: (AssessmentResult) -> Void
    var onBatteryComplete: (() -> Void)? = nil
    @State private var step = 0
    
    var body: some View {
        Group {
            switch step {
            case 0:
                StroopTestView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 1 }
            case 1:
                FlankerTestView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 2 }
            case 2:
                TrailMakingTestView(studyID: studyID, mode: .a, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 3 }
            case 3:
                TrailMakingTestView(studyID: studyID, mode: .b, allowSkip: false, dismissOnComplete: false) { r in onEachResult(r); step = 4 }
            case 4:
                DigitSpanTestView(studyID: studyID, allowSkip: false, dismissOnComplete: false) { r in
                    onEachResult(r)
                    onBatteryComplete?()
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - ASCEND-SVD Cognitive Menu (Stroop, Trails, Digit Span)
struct AscendCognitiveMenuView: View {
    let studyID: String
    let allowSkip: Bool
    /// Personal / Custom: pick one test. ASCEND-SVD: full battery only.
    var allowOneOff: Bool = false
    let onComplete: (AssessmentResult) -> Void
    var onBatteryComplete: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showBattery = false
    @State private var showStroop = false
    @State private var showTrailsA = false
    @State private var showTrailsB = false
    @State private var showDigitSpan = false
    @State private var showFlanker = false
    
    var body: some View {
        NavigationStack {
            List {
                if !allowOneOff {
                    Section {
                        Button { showBattery = true } label: {
                            HStack {
                                Image(systemName: "list.number")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Run all tests in order")
                                    Text("Stroop → Flanker → Trail A → Trail B → Digit Span")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if allowOneOff {
                    Section("Choose a test") {
                    Button { showStroop = true } label: {
                        HStack { Image(systemName:"textformat"); Text("Stroop (ink color)"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showFlanker = true } label: {
                        HStack { Image(systemName:"arrow.left.and.right"); Text("Flanker (arrows)"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showTrailsA = true } label: {
                        HStack { Image(systemName:"1.circle"); Text("Trail Making A (1→12)"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showTrailsB = true } label: {
                        HStack { Image(systemName:"a.circle"); Text("Trail Making B (1→A→2→B)"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    Button { showDigitSpan = true } label: {
                        HStack { Image(systemName:"123.rectangle"); Text("Digit Span"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.tertiary) }
                    }
                    }
                }
            }
            .navigationTitle("Cognitive Tests")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .fullScreenCover(isPresented: $showBattery) {
                AscendCognitiveBatteryView(studyID: studyID, onEachResult: onComplete, onBatteryComplete: {
                    showBattery = false
                    onBatteryComplete?()
                })
            }
            .sheet(isPresented: $showStroop) {
                StroopTestView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showFlanker) {
                FlankerTestView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showTrailsA) {
                TrailMakingTestView(studyID: studyID, mode: .a, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showTrailsB) {
                TrailMakingTestView(studyID: studyID, mode: .b, allowSkip: allowSkip) { res in onComplete(res) }
            }
            .sheet(isPresented: $showDigitSpan) {
                DigitSpanTestView(studyID: studyID, allowSkip: allowSkip) { res in onComplete(res) }
            }
        }
    }
}
struct QuestionField: View {
    let question: String
    @Binding var answer: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(.subheadline).fontWeight(.medium)
            TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - UPDRS Menu + Parts
struct UPDRSMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPart: Int?
    var body: some View {
        NavigationStack {
            List {
                Button { selectedPart = 1 } label: { navRow("Part 1: Non-Motor Experiences", "Daily life experiences") }
                Button { selectedPart = 2 } label: { navRow("Part 2: Motor Experiences", "Daily activities") }
                Button { selectedPart = 4 } label: { navRow("Part 4: Motor Complications", "Medication effects") }
            }
            .navigationTitle("UPDRS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedPart) { part in
                if part == 1 { UPDRS1View() }
                else if part == 2 { UPDRS2View() }
                else { UPDRS4View() }
            }
        }
    }
    private func navRow(_ title: String, _ subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }
}
extension Int: @retroactive Identifiable { public var id: Int { self } }

struct UPDRS1View: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var responses: [String: Int] = [:]
    let questions = [
        ("Cognitive Impairment","..."),("Hallucinations","..."),("Depressed Mood","..."),("Anxious Mood","..."),
        ("Apathy","..."),("Sleep Problems","..."),("Daytime Sleepiness","..."),("Pain","..."),
        ("Urinary Problems","..."),("Constipation","..."),("Light-headedness","..."),("Fatigue","...")
    ]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Rate each item from 0-4 based on the past 7 days.").font(.caption).foregroundStyle(.secondary)
                    Text("0=Normal  1=Slight  2=Mild  3=Moderate  4=Severe").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(questions.enumerated()), id: \.offset) { _, item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.0).font(.headline)
                            Text(item.1).font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: binding(for: item.0)) { ForEach(0...4, id:\.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                    }
                }
                Button("Submit and View Report") { submit() }
                    .disabled(!isComplete)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth:.infinity)
            }
            .navigationTitle("UPDRS Part 1")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
    private func binding(for key: String) -> Binding<Int> {
        Binding(get: { responses[key] ?? 0 }, set: { responses[key] = $0 })
    }
    private var isComplete: Bool { questions.allSatisfy { responses[$0.0] != nil } }
    private func submit() {
        let end = Date()
        let total = responses.values.reduce(0, +)
        var data = responses.mapValues { String($0) }
        data["total"] = "\(total)"
        data.merge(deviceMeta(task: "UPDRS-1", taskVersion: "1.0", start: end, end: end, studyID: vm.studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "UPDRS-1", data: data, notes: "Total: \(total)")
        playChime(); vm.saveAssessment(result); dismiss()
    }
}

struct UPDRS2View: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var responses: [String: Int] = [:]
    let questions = [
        ("Speech","..."),("Saliva/Drooling","..."),("Chewing/Swallowing","..."),("Eating","..."),
        ("Dressing","..."),("Hygiene","..."),("Handwriting","..."),("Hobbies","..."),
        ("Turning in Bed","..."),("Tremor","..."),("Getting Out of Bed","..."),("Walking/Balance","..."),("Freezing","...")
    ]
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Rate 0-4 based on past 7 days.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(questions.enumerated()), id: \.offset) { _, item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) { Text(item.0).font(.headline); Text(item.1).font(.caption).foregroundStyle(.secondary) }
                        Picker("", selection: binding(for: item.0)) { ForEach(0...4, id:\.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                    }
                }
                Button("Submit and View Report") { submit() }
                    .disabled(!isComplete)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth:.infinity)
            }
            .navigationTitle("UPDRS Part 2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
    private func binding(for key: String) -> Binding<Int> {
        Binding(get: { responses[key] ?? 0 }, set: { responses[key] = $0 })
    }
    private var isComplete: Bool { questions.allSatisfy { responses[$0.0] != nil } }
    private func submit() {
        let end = Date()
        let total = responses.values.reduce(0, +)
        var data = responses.mapValues { String($0) }
        data["total"] = "\(total)"
        data.merge(deviceMeta(task: "UPDRS-2", taskVersion: "1.0", start: end, end: end, studyID: vm.studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "UPDRS-2", data: data, notes: "Total: \(total)")
        playChime(); vm.saveAssessment(result); dismiss()
    }
}

struct UPDRS4View: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var responses: [String: Int] = [:]
    let questions = [
        ("Time with Dyskinesias","..."),("Impact of Dyskinesias","..."),("Time in OFF","..."),
        ("Impact of Fluctuations","..."),("Complexity of Fluctuations","..."),("Painful Dystonia","...")
    ]
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Rate complications from the past 7 days.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(questions.enumerated()), id: \.offset) { _, item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) { Text(item.0).font(.headline); Text(item.1).font(.caption).foregroundStyle(.secondary) }
                        Picker("", selection: binding(for: item.0)) { ForEach(0...4, id:\.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                    }
                }
                Button("Submit and View Report") { submit() }
                    .disabled(!isComplete)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth:.infinity)
            }
            .navigationTitle("UPDRS Part 4")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
    private func binding(for key: String) -> Binding<Int> {
        Binding(get: { responses[key] ?? 0 }, set: { responses[key] = $0 })
    }
    private var isComplete: Bool { questions.allSatisfy { responses[$0.0] != nil } }
    private func submit() {
        let end = Date()
        let total = responses.values.reduce(0, +)
        var data = responses.mapValues { String($0) }
        data["total"] = "\(total)"
        data.merge(deviceMeta(task: "UPDRS-4", taskVersion: "1.0", start: end, end: end, studyID: vm.studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: vm.studyID, assessmentType: "UPDRS-4", data: data, notes: "Total: \(total)")
        playChime(); vm.saveAssessment(result); dismiss()
    }
}

// MARK: - Motor Tests

// Tapping (single trial)
struct TappingTestView: View {
    @EnvironmentObject private var vm: AppViewModel
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    @State private var tapCount = 0
    @State private var countdown = 10
    @State private var running = false
    @State private var timer: Timer?
    @State private var startTime: Date?
    @State private var preCountdown: Int = 0
    @State private var tapTimestamps: [Date] = []
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "hand.tap.fill").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Finger Tapping").font(.title2).fontWeight(.bold)
            Text("Tap anywhere as fast as you can for 10 seconds").multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            Text("\(countdown)s").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
            Text("Taps: \(tapCount)").font(.title.monospacedDigit())
            Spacer()
            if !running {
                Button("Start") { start() }.buttonStyle(.borderedProminent).font(.title3)
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            if running && preCountdown == 0 {
                tapCount += 1
                tapTimestamps.append(Date())
            }
        }
        .overlay(alignment: .center) {
            if preCountdown > 0 {
                VStack(spacing: 8) {
                    Text("Get ready…").font(.headline)
                    Text("\(preCountdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding()
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !self.running { self.start() } } }
    }
    
    private func start() {
        if running { return }
        tapCount = 0; countdown = 10; preCountdown = 3; running = true; tapTimestamps.removeAll()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.preCountdown > 0 { self.preCountdown -= 1 } else {
                t.invalidate(); self.beginTiming()
            }
        }
    }
    private func beginTiming() {
        startTime = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if self.countdown > 0 { self.countdown -= 1 } else { self.finish() }
        }
    }
    private func finish() {
        timer?.invalidate(); running = false
        let tps = Double(tapCount) / 10.0
        let end = Date(); let start = startTime ?? end
        // Inter-tap interval stats (ms)
        var itiMs: [Double] = []
        if tapTimestamps.count >= 2 {
            for i in 1..<tapTimestamps.count {
                itiMs.append(tapTimestamps[i].timeIntervalSince(tapTimestamps[i-1]) * 1000.0)
            }
        }
        let meanITI = itiMs.isEmpty ? 0.0 : (itiMs.reduce(0,+) / Double(itiMs.count))
        let sdITI: Double = {
            guard !itiMs.isEmpty else { return 0.0 }
            let m = meanITI
            let v = itiMs.map { ($0 - m)*($0 - m) }.reduce(0,+) / Double(itiMs.count)
            return sqrt(v)
        }()
        let cvITI = meanITI > 0 ? (sdITI / meanITI) : 0.0
        var data = [
            "tapsPerSecond": String(format: "%.2f", tps),
            "totalTaps": "\(tapCount)",
            "iti_mean_ms": String(format: "%.1f", meanITI),
            "iti_sd_ms": String(format: "%.1f", sdITI),
            "iti_cv": String(format: "%.3f", cvITI)
        ]
        data.merge(deviceMeta(task: "Tapping", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Tapping", data: data, notes: String(format: "%.2f taps/sec", tps))
        playChime(); onComplete(result)
    }
}

// Tapping Battery (3 trials + avg)
struct TappingBatteryView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    @State private var trial = 1
    @State private var tps: [Double] = []
    @State private var started: Date = Date()
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Trial \(trial) of 3").font(.headline)
            TappingTestView(studyID: studyID) { r in
                let d = Double(r.data["tapsPerSecond"] ?? "0") ?? 0
                tps.append(d)
                if trial < 3 {
                    trial += 1
                } else {
                    let end = Date()
                    let avg = tps.reduce(0,+) / Double(tps.count)
                    var m: [String:String] = [
                        "avg_tps": String(format:"%.2f", avg),
                        "trial1_tps": String(format:"%.2f", tps[safe:0] ?? 0),
                        "trial2_tps": String(format:"%.2f", tps[safe:1] ?? 0),
                        "trial3_tps": String(format:"%.2f", tps[safe:2] ?? 0)
                    ]
                    m.merge(deviceMeta(task: "Tapping3", taskVersion: "1.0", start: started, end: end, studyID: studyID)) { _, n in n }
                    let res = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Tapping3", data: m, notes: String(format:"avg %.2f tps", avg))
                    onComplete(res)
                }
            }
        }
        .onAppear { started = Date() }
    }
}

// Tremor Test (Right/Left)
enum Hand: String, Codable { case right = "Right", left = "Left" }

struct TremorWaveformView: View {
    let samples: [Double]
    
    private func makePath(in size: CGSize) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let w = size.width
        let h = size.height
        let midY = h / 2
        let mean = samples.reduce(0, +) / Double(samples.count)
        let centered: [Double] = samples.map { $0 - mean }
        let maxAmp = centered.map(abs).max() ?? 1e-6
        let scaleY: CGFloat = maxAmp > 0 ? CGFloat((midY - 4) / maxAmp) : 1.0
        let step = centered.count > 400 ? max(1, centered.count / 400) : 1
        let count = centered.count
        let xDivisor = CGFloat(max(count - 1, 1))
        var first = true
        for i in stride(from: 0, to: count, by: step) {
            let x = w * CGFloat(i) / xDivisor
            let yVal = centered[i]
            let y = midY - CGFloat(yVal) * scaleY
            let pt = CGPoint(x: x, y: y)
            if first {
                path.move(to: pt)
                first = false
            } else {
                path.addLine(to: pt)
            }
        }
        return path
    }
    
    var body: some View {
        GeometryReader { geo in
            makePath(in: geo.size)
                .stroke(Color.cyan.opacity(0.9), lineWidth: 2)
        }
    }
}

struct TremorTestView: View {
    @EnvironmentObject private var vm: AppViewModel
    let studyID: String
    let side: Hand
    let onComplete: (AssessmentResult) -> Void
    
    private let motion = CMMotionManager()
    @State private var samples: [Double] = []
    @State private var displayAmp: Double = 0
    @State private var displayFreq: Double = 0
    @State private var secondsLeft = 10
    @State private var running = false
    @State private var timer: Timer?
    @State private var started: Date?
    @State private var preCountdown: Int = 0
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Tremor Assessment (\(side.rawValue))").font(.title2).fontWeight(.bold)
            Text("Hold phone in the palm of the outstretched \(side.rawValue.lowercased()) arm for 10 seconds. Hold with outstretched hand if tremor is severe. You will hear a chime when the task is complete.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("\(secondsLeft)s").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
            if running && !samples.isEmpty {
                TremorWaveformView(samples: samples)
                    .frame(height: 120)
                VStack(spacing: 4) {
                    Text("Amplitude: \(String(format: "%.4f", displayAmp)) g").font(.subheadline.monospacedDigit())
                    Text("Frequency: \(String(format: "%.2f", displayFreq)) Hz").font(.subheadline.monospacedDigit())
                }
            }
            Spacer()
            if !running { Button("Start") { start() }.buttonStyle(.borderedProminent).font(.title3) }
        }
        .padding()
        .overlay {
            if preCountdown > 0 {
                VStack(spacing: 8) {
                    Text("Get ready…").font(.headline)
                    Text("\(preCountdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding()
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    
    private func start() {
        if running { return }
        samples.removeAll(); displayAmp = 0; displayFreq = 0; secondsLeft = 10; preCountdown = 3; running = true
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.preCountdown > 0 { self.preCountdown -= 1 } else {
                t.invalidate(); self.beginSampling()
            }
        }
    }
    private func beginSampling() {
        started = Date()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.01
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if let dm = self.motion.deviceMotion {
                let ua = dm.userAcceleration
                let mag = sqrt(ua.x * ua.x + ua.y * ua.y + ua.z * ua.z)
                self.samples.append(abs(mag))
            }
            if self.samples.count % 100 == 0 && !self.samples.isEmpty {
                let s = self.samples
                let sr = 100.0
                let mean = s.isEmpty ? 0.0 : (s.reduce(0, +) / Double(s.count))
                let centered = s.map { $0 - mean }
                let rms = centered.isEmpty ? 0.0 : sqrt(centered.reduce(0.0) { $0 + $1 * $1 } / Double(centered.count))
                let minHz = 3.0, maxHz = 12.0
                let minLag = Int(sr / maxHz)
                let maxLag = max(Int(sr / minHz), minLag + 1)
                var bestLag = 0
                var bestCorr = -Double.infinity
                if centered.count > maxLag {
                    for lag in minLag...maxLag {
                        var num = 0.0, den0 = 0.0, den1 = 0.0
                        let upper = centered.count - lag
                        if upper <= 1 { continue }
                        for n in 0..<upper {
                            let a = centered[n], b = centered[n + lag]
                            num += a * b; den0 += a * a; den1 += b * b
                        }
                        let denom = sqrt(den0 * den1) + 1e-12
                        let corr = num / denom
                        if corr > bestCorr {
                            bestCorr = corr; bestLag = lag
                        }
                    }
                }
                let freqHz = bestLag > 0 ? (sr / Double(bestLag)) : 0.0
                DispatchQueue.main.async {
                    self.displayAmp = rms
                    self.displayFreq = freqHz
                }
                if self.secondsLeft > 0 { self.secondsLeft -= 1 } else { self.finish() }
            }
        }
    }
    private func finish() {
        timer?.invalidate(); motion.stopDeviceMotionUpdates(); running = false
        let end = Date(); let start = started ?? end
        let detected = samples.max() ?? 0 > 0.05
        // Compute tremor amplitude and dominant frequency
        let sr = 100.0 // 0.01s interval
        let mean = samples.isEmpty ? 0.0 : (samples.reduce(0, +) / Double(samples.count))
        let centered = samples.map { $0 - mean }
        let rms = centered.isEmpty ? 0.0 : sqrt(centered.reduce(0.0) { $0 + $1 * $1 } / Double(centered.count))
        let peakToPeak = (samples.max() ?? 0.0) - (samples.min() ?? 0.0)
        let minHz = 3.0, maxHz = 12.0
        let minLag = Int(sr / maxHz)
        let maxLag = max(Int(sr / minHz), minLag + 1)
        var bestLag = 0
        var bestCorr = -Double.infinity
        if centered.count > maxLag {
            for lag in minLag...maxLag {
                var num = 0.0, den0 = 0.0, den1 = 0.0
                let upper = centered.count - lag
                if upper <= 1 { continue }
                for n in 0..<upper {
                    let a = centered[n], b = centered[n + lag]
                    num += a * b; den0 += a * a; den1 += b * b
                }
                let denom = sqrt(den0 * den1) + 1e-12
                let corr = num / denom
                if corr > bestCorr {
                    bestCorr = corr; bestLag = lag
                }
            }
        }
        let freqHz = bestLag > 0 ? (sr / Double(bestLag)) : 0.0
        
        var data = ["detected": "\(detected)", "samples": "\(samples.count)", "side": side.rawValue]
        data["amp_rms_g"] = String(format: "%.5f", rms)
        data["amp_pp_g"] = String(format: "%.5f", peakToPeak)
        data["freq_hz"] = String(format: "%.3f", freqHz)
        if !vm.participant.handedness.isEmpty { data["handedness"] = vm.participant.handedness }
        data.merge(deviceMeta(task: "Tremor", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Tremor", data: data, notes: detected ? "Tremor detected (\(side.rawValue))" : "No tremor (\(side.rawValue))")
        playChime(); onComplete(result)
    }
}

// Gait Test
struct GaitTestView: View {
    @EnvironmentObject private var vm: AppViewModel
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    private let pedometer = CMPedometer()
    @State private var steps = 0
    @State private var secondsLeft = 15
    @State private var running = false
    @State private var timer: Timer?
    @State private var started: Date?
    @State private var preCountdown: Int = 0
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "figure.walk").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Gait Assessment").font(.title2).fontWeight(.bold)
            Text("Walk normally for 15 seconds holding your phone in your hand or in a pocket. It will chime when the task is complete.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("\(secondsLeft)s").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
            Text("Steps: \(steps)").font(.title.monospacedDigit())
            Spacer()
            if !running { Button("Start") { start() }.buttonStyle(.borderedProminent).font(.title3) }
        }
        .padding()
        .overlay {
            if preCountdown > 0 {
                VStack(spacing: 8) {
                    Text("Get ready…").font(.headline)
                    Text("\(preCountdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding()
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !self.running { self.start() } } }
    }
    
    private func start() {
        if running { return }
        steps = 0; secondsLeft = 15; preCountdown = 3; running = true
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.preCountdown > 0 { self.preCountdown -= 1 } else {
                t.invalidate(); self.beginGait()
            }
        }
    }
    private func beginGait() {
        started = Date()
        guard CMPedometer.isStepCountingAvailable() else { finish(); return }
        pedometer.startUpdates(from: Date()) { data, _ in
            if let data = data, self.running { onMain { if self.running { self.steps = data.numberOfSteps.intValue } } }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if self.secondsLeft > 0 { self.secondsLeft -= 1 } else { self.finish() }
        }
    }
    private func finish() {
        timer?.invalidate(); pedometer.stopUpdates(); running = false
        let end = Date(); let start = started ?? end
        let cadence = (Double(steps) / 15.0) * 60.0
        var data = ["cadence": String(format: "%.0f", cadence), "steps": "\(steps)"]
        if !vm.participant.handedness.isEmpty { data["handedness"] = vm.participant.handedness }
        data.merge(deviceMeta(task: "Gait", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Gait", data: data, notes: String(format: "%.0f steps/min", cadence))
        playChime(); onComplete(result)
    }
}

// MARK: - Voice Test (10s loudness with pitch)
struct VoiceTestView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    private let engine = AVAudioEngine()
    @State private var secondsLeft = 10
    @State private var running = false
    @State private var preCountdown = 0
    @State private var timer: Timer?
    @State private var started: Date?
    @State private var currentDb: Double = -80.0
    @State private var peakDb: Double = -80.0
    @State private var sumDb: Double = 0.0
    @State private var numFrames: Int = 0
    @State private var micDenied = false
    @State private var sampleRate: Double = 44100.0
    @State private var voicedSamples: Int = 0
    @State private var pitchesHz: [Double] = []
    private let voiceDbThreshold: Double = -45.0
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform").font(.system(size: 60)).foregroundStyle(.blue)
            Text("Voice Sample").font(.title2).fontWeight(.bold)
            Text("Say Ahhh or count 1–20 for 10 seconds. No audio is stored; only loudness metrics are saved.").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            Text("\(secondsLeft)s").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
            VStack(spacing: 4) {
                Text(String(format: "Current: %.1f dB", currentDb)).font(.headline)
                Text(String(format: "Peak: %.1f dB", peakDb)).font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max((currentDb + 80) / 80.0, 0), 1.0)).tint(.green).frame(width: 240)
            Spacer()
            if !running {
                if micDenied {
                    Text("Microphone access required").foregroundStyle(.red)
                }
                Button("Start") { start() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .overlay {
            if preCountdown > 0 {
                VStack(spacing: 8) {
                    Text("Get ready…").font(.headline)
                    Text("\(preCountdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding()
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onDisappear { cleanup() }
    }
    
    private func start() {
        if running { return }
        requestMic { granted in
            if !granted {
                micDenied = true
                return
            }
            self.preCountdown = 3
            self.running = true
            self.secondsLeft = 10
            self.peakDb = -80.0
            self.sumDb = 0.0
            self.numFrames = 0
            self.voicedSamples = 0
            self.pitchesHz.removeAll()
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
                if self.preCountdown > 0 { self.preCountdown -= 1 } else {
                    t.invalidate(); self.begin()
                }
            }
        }
    }
    private func begin() {
        started = Date()
        if !configureAudioSession() {
            micDenied = true
            running = false
            preCountdown = 0
            return
        }
        startEngine()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.secondsLeft > 0 { self.secondsLeft -= 1 } else { t.invalidate(); self.finish() }
        }
    }
    private func configureAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }
    private func startEngine() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        self.sampleRate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let channel = ch[0]
            let count = Int(buffer.frameLength)
            var sumSquares: Float = 0
            var peak: Float = 0
            for i in 0..<count {
                let v = channel[i]
                sumSquares += v * v
                peak = max(peak, abs(v))
            }
            let rms = sqrt(sumSquares / Float(max(count,1)))
            let db = 20.0 * log10(Double(max(rms, 1e-7)))
            let peakDbSample = 20.0 * log10(Double(max(peak, 1e-7)))
            var pitch: Double?
            if db > self.voiceDbThreshold {
                pitch = self.estimatePitchHz(samples: channel, count: count, sampleRate: self.sampleRate)
            }
            DispatchQueue.main.async {
                self.currentDb = db
                self.peakDb = max(self.peakDb, peakDbSample)
                self.sumDb += db
                self.numFrames += 1
                if db > self.voiceDbThreshold {
                    self.voicedSamples += count
                    if let p = pitch, p.isFinite, p > 50, p < 400 {
                        self.pitchesHz.append(p)
                    }
                }
            }
        }
        do {
            try engine.start()
        } catch {
            micDenied = true
        }
    }
    private func cleanup() {
        timer?.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        running = false
        preCountdown = 0
    }
    private func finish() {
        cleanup()
        let end = Date(); let start = started ?? end
        let avgDb = numFrames > 0 ? (sumDb / Double(numFrames)) : -80.0
        let voicedSec = Double(voicedSamples) / max(sampleRate, 1.0)
        let meanPitch: Double = {
            guard !pitchesHz.isEmpty else { return 0.0 }
            return pitchesHz.reduce(0,+) / Double(pitchesHz.count)
        }()
        let sdPitch: Double = {
            guard !pitchesHz.isEmpty else { return 0.0 }
            let m = meanPitch
            let v = pitchesHz.map { ($0-m)*($0-m) }.reduce(0,+) / Double(pitchesHz.count)
            return sqrt(v)
        }()
        var data = [
            "loudness_avg_db": String(format: "%.1f", avgDb),
            "loudness_peak_db": String(format: "%.1f", peakDb),
            "voiced_seconds": String(format: "%.1f", voicedSec),
            "pitch_mean_hz": String(format: "%.1f", meanPitch),
            "pitch_sd_hz": String(format: "%.1f", sdPitch)
        ]
        data.merge(deviceMeta(task: "Voice", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Voice", data: data, notes: "10s loudness")
        playChime(); onComplete(result)
    }
    private func requestMic(_ completion: @escaping (Bool)->Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            DispatchQueue.main.async { completion(true) }
        case .denied:
            DispatchQueue.main.async { completion(false) }
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }
    private func estimatePitchHz(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Double? {
        // simple autocorrelation over limited lag range (70–300 Hz)
        let minLag = max(1, Int(sampleRate / 300.0))
        let maxLag = min(count - 1, Int(sampleRate / 70.0))
        if maxLag <= minLag { return nil }
        var bestLag = minLag
        var bestVal: Double = -Double.infinity
        // remove DC
        var mean: Double = 0
        if count > 0 {
            var sum: Double = 0
            for i in 0..<count { sum += Double(samples[i]) }
            mean = sum / Double(count)
        }
        // energy for normalization
        var energy: Double = 0
        for i in 0..<count {
            let x = Double(samples[i]) - mean
            energy += x*x
        }
        if energy <= 0 { return nil }
        for lag in minLag...maxLag {
            var acc: Double = 0
            let N = count - lag
            if N <= 0 { break }
            for i in 0..<N {
                let x1 = Double(samples[i]) - mean
                let x2 = Double(samples[i+lag]) - mean
                acc += x1 * x2
            }
            let norm = acc / Double(N)
            if norm > bestVal {
                bestVal = norm
                bestLag = lag
            }
        }
        if bestVal <= 0 { return nil }
        return sampleRate / Double(bestLag)
    }
}

// MARK: - Reaction Time Test (visual stimulus)
struct ReactionTimeTestView: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    @State private var trial = 1
    @State private var showingCue = false
    @State private var canTap = false
    @State private var startTime: Date?
    @State private var rts: [Double] = [] // ms
    @State private var message: String = "When the screen turns green, tap as fast as you can."
    @State private var running = false
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Reaction Time").font(.title2).fontWeight(.bold)
            Text("Trial \(min(trial,5)) of 5").font(.subheadline).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Rectangle()
                .fill(showingCue ? Color.green : Color.gray.opacity(0.2))
                .frame(height: 220)
                .cornerRadius(16)
                .overlay(Text(showingCue ? "TAP!" : "Wait…").font(.largeTitle).fontWeight(.bold))
                .onTapGesture { tapped() }
            Spacer()
            if !running {
                Button("Start") { startTrial() }.buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { running = false; reset() }.buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    private func reset() {
        trial = 1; rts.removeAll(); showingCue = false; canTap = false; message = "When the screen turns green, tap as fast as you can."
    }
    private func startTrial() {
        running = true; showingCue = false; canTap = false
        let delay = Double.random(in: 1.2...3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard running else { return }
            self.showingCue = true
            self.canTap = true
            self.startTime = Date()
        }
    }
    private func tapped() {
        guard running else { return }
        if canTap, let s = startTime {
            let rt = Date().timeIntervalSince(s) * 1000.0
            rts.append(rt)
            showingCue = false; canTap = false
            if trial < 5 {
                trial += 1
                message = String(format: "RT: %.0f ms. Get ready for the next trial.", rt)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { startTrial() }
            } else {
                finish()
            }
        } else {
            // premature tap
            message = "Too early! Wait for green."
        }
    }
    private func finish() {
        running = false
        let mean = rts.isEmpty ? 0.0 : rts.reduce(0,+)/Double(rts.count)
        let sd: Double = {
            guard !rts.isEmpty else { return 0.0 }
            let m = mean
            let v = rts.map { ($0-m)*($0-m) }.reduce(0,+)/Double(rts.count)
            return sqrt(v)
        }()
        let median: Double = {
            let s = rts.sorted()
            guard !s.isEmpty else { return 0.0 }
            let mid = s.count/2
            return s.count % 2 == 0 ? (s[mid-1]+s[mid])/2.0 : s[mid]
        }()
        let end = Date(); let start = end
        var data: [String:String] = [
            "rt_mean_ms": String(format: "%.0f", mean),
            "rt_sd_ms": String(format: "%.0f", sd),
            "rt_median_ms": String(format: "%.0f", median),
            "rt_trials_ms": rts.map { String(format: "%.0f", $0) }.joined(separator: ",")
        ]
        data.merge(deviceMeta(task: "Reaction Time", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Reaction Time", data: data, notes: String(format: "mean %.0f ms", mean))
        playChime(); onComplete(result)
        reset()
    }
}

// MARK: - Vision-Based Blink Detection (FIXED)
final class VisionBlinkDetector: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onBlink: () -> Void = {}
    var onROI: (_ rectNormalized: CGRect?, _ good: Bool) -> Void = { _, _ in }
    /// Smoothed 0…1 scene brightness (higher = more light). Updated on capture queue, published on main.
    @Published var sceneBrightness: Double = 1.0
    /// True when lighting is too low for reliable blink detection (hysteresis; avoids flicker).
    @Published var isLowLight: Bool = false
    
    private let request = VNDetectFaceLandmarksRequest()
    private let seqHandler = VNSequenceRequestHandler()
    @Published var frameCount: Int = 0
    @Published var thresholdPx: Double = 113.0
    
    private var eyeHeightHistory: [Double] = []
    private let historySize = 2
    
    private var isCalibrating = false
    private var calibHeights: [Double] = []
    private var baselineOpenHeight: Double = 20.0
    
    private var wasBelow = false
    private var lastBlinkTime: CFTimeInterval = 0
    private let minBlinkGapMs: Double = 60
    
    private var imageWidth: CGFloat = 1920
    private var imageHeight: CGFloat = 1080
    
    @Published var debugHeight: Double = 0.0
    @Published var debugThreshold: Double = 0.0
    @Published var debugState: String = "—"
    
    private var brightnessFrameSkip = 0
    private var smoothedBrightness: Double = 0.5
    private var lowLightStreak = 0
    private var goodLightStreak = 0
    /// Hysteresis + streaks tracked on capture queue (mirrors `isLowLight` on main).
    private var lowLightActive = false
    /// Below this (after smoothing) we consider lighting too low for reliable face/eye tracking.
    private let lowLightEnter: Double = 0.14
    private let lowLightExit: Double = 0.22
    private let brightnessSampleEvery = 4
    
    func beginCalibration() {
        isCalibrating = true
        calibHeights.removeAll()
        eyeHeightHistory.removeAll()
        baselineOpenHeight = 20.0
        wasBelow = false
        lastBlinkTime = 0
    }
    
    func endCalibration() {
        if !calibHeights.isEmpty {
            let sorted = calibHeights.sorted()
            let topStart = sorted.count / 4
            let topHeights = Array(sorted[topStart...])
            baselineOpenHeight = topHeights.reduce(0.0, +) / Double(topHeights.count)
            baselineOpenHeight = max(10.0, baselineOpenHeight)
        }
        isCalibrating = false
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        brightnessFrameSkip += 1
        if brightnessFrameSkip >= brightnessSampleEvery {
            brightnessFrameSkip = 0
            let raw = Self.averageLuminanceBGRA(pixelBuffer)
            smoothedBrightness = 0.75 * smoothedBrightness + 0.25 * raw
            if smoothedBrightness < lowLightEnter {
                lowLightStreak += 1
                goodLightStreak = 0
            } else if smoothedBrightness > lowLightExit {
                goodLightStreak += 1
                lowLightStreak = 0
            } else {
                lowLightStreak = 0
                goodLightStreak = 0
            }
            if !lowLightActive, lowLightStreak >= 6 { lowLightActive = true }
            if lowLightActive, goodLightStreak >= 8 { lowLightActive = false }
            let bright = smoothedBrightness
            let active = lowLightActive
            DispatchQueue.main.async {
                self.sceneBrightness = bright
                if self.isLowLight != active { self.isLowLight = active }
            }
        }
        DispatchQueue.main.async { self.frameCount += 1 }
        imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        do { try seqHandler.perform([request], on: pixelBuffer, orientation: .leftMirrored) } catch { return }
        guard let results = request.results,
              let face = results.first,
              let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else {
            DispatchQueue.main.async { self.onROI(nil, false); self.debugState = "No face detected" }
            return
        }
        let bbox = face.boundingBox
        let center = CGPoint(x: bbox.midX, y: bbox.midY)
        let sizeOk = (bbox.width > 0.20 && bbox.width < 0.70) && (bbox.height > 0.20 && bbox.height < 0.70)
        let centerOk = abs(center.x - 0.5) < 0.20 && abs(center.y - 0.5) < 0.20
        DispatchQueue.main.async { self.onROI(bbox, sizeOk && centerOk) }
        
        let leftHeight = calculateEyeHeight(leftEye, imageHeight: imageHeight)
        let rightHeight = calculateEyeHeight(rightEye, imageHeight: imageHeight)
        let avgHeight = (leftHeight + rightHeight) / 2.0
        eyeHeightHistory.append(avgHeight)
        if eyeHeightHistory.count > historySize { eyeHeightHistory.removeFirst() }
        // Average the last few values for responsiveness
        let smoothedHeight = eyeHeightHistory.reduce(0.0, +) / Double(max(eyeHeightHistory.count, 1))
        let now = CACurrentMediaTime()
        
        if isCalibrating {
            calibHeights.append(smoothedHeight)
            DispatchQueue.main.async {
                self.debugHeight = smoothedHeight
                self.debugThreshold = self.baselineOpenHeight
                self.debugState = "Calibrating (\(self.calibHeights.count) samples)"
            }
            return
        }
        // Use a fixed absolute threshold (px) per request to increase sensitivity
        // Simple absolute threshold logic:
        // CLOSED if eye height < thresholdPx; OPEN if >= thresholdPx.
        let currentThresh = thresholdPx
        if smoothedHeight < currentThresh {
            if !wasBelow {
                wasBelow = true
                DispatchQueue.main.async { self.debugState = "CLOSED" }
            }
        } else {
            if wasBelow {
                let gapMs = (now - lastBlinkTime) * 1000.0
                if gapMs >= minBlinkGapMs {
                    lastBlinkTime = now
                    DispatchQueue.main.async {
                        self.onBlink()
                        self.debugState = "BLINK! ✓"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if self.debugState == "BLINK! ✓" { self.debugState = "Open" }
                    }
                }
                wasBelow = false
            } else {
                DispatchQueue.main.async { self.debugState = "Open" }
            }
        }
        DispatchQueue.main.async {
            self.debugHeight = smoothedHeight
            self.debugThreshold = currentThresh
        }
    }
    
    private func calculateEyeHeight(_ eye: VNFaceLandmarkRegion2D, imageHeight: CGFloat) -> Double {
        let points = eye.normalizedPoints
        guard points.count >= 6 else { return 0.0 }
        let topPoint = points[2]
        let bottomPoint = points[5]
        let topY = topPoint.y * Double(imageHeight)
        let bottomY = bottomPoint.y * Double(imageHeight)
        return abs(topY - bottomY)
    }
    
    /// Mean relative luminance 0…1 from BGRA buffer (sparse sample for speed).
    private static func averageLuminanceBGRA(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.35 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var n = 0.0
        let step = max(48, min(width, height) / 12)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let o = y * bytesPerRow + x * 4
                let b = Double(ptr[o])
                let g = Double(ptr[o + 1])
                let r = Double(ptr[o + 2])
                let luma = 0.0722 * b + 0.7152 * g + 0.2126 * r
                sum += luma
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return 0.35 }
        return min(1.0, max(0.0, sum / (255.0 * n)))
    }
}

// MARK: - Camera Pipeline (FIXED)
final class CameraPipeline: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "pd.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var isRunning: Bool = false
    @Published var inputsCount: Int = 0
    @Published var outputsCount: Int = 0
    @Published var authStatus: String = "unknown"
    private var currentPosition: AVCaptureDevice.Position = .front
    
    func configurePreviewLayerIfNeeded(_ setLayer: (AVCaptureVideoPreviewLayer) -> Void) {
        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            previewLayer = layer
            setLayer(layer)
        }
    }
    
    func start(detector: AVCaptureVideoDataOutputSampleBufferDelegate, position: AVCaptureDevice.Position = .front, completion: @escaping (Bool) -> Void) {
        currentPosition = position
        
        // Update auth status for debugging
        DispatchQueue.main.async {
            self.authStatus = {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: return "authorized"
                case .denied: return "denied"
                case .restricted: return "restricted"
                case .notDetermined: return "notDetermined"
                @unknown default: return "unknown"
                }
            }()
        }
        
        checkCameraPermission { granted in
            guard granted else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            self.captureQueue.async {
                self.session.beginConfiguration()
                
                // Try high preset first, fall back to VGA if needed
                if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                } else if self.session.canSetSessionPreset(.vga640x480) {
                    self.session.sessionPreset = .vga640x480
                }
                
                // Remove existing inputs/outputs
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                
                // Add camera input
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                    print("❌ No camera device found for position: \(position)")
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }
                
                guard let input = try? AVCaptureDeviceInput(device: device) else {
                    print("❌ Failed to create camera input")
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }
                
                guard self.session.canAddInput(input) else {
                    print("❌ Cannot add camera input to session")
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }
                
                self.session.addInput(input)
                print("✅ Camera input added")
                
                // Configure output
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.setSampleBufferDelegate(detector, queue: self.captureQueue)
                
                guard self.session.canAddOutput(self.output) else {
                    print("❌ Cannot add video output to session")
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        completion(false)
                    }
                    return
                }
                
                self.session.addOutput(self.output)
                print("✅ Video output added")
                
                // Configure connection
                if let connection = self.output.connection(with: .video) {
                    connection.isVideoMirrored = (position == .front)
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                
                self.session.commitConfiguration()
                
                // Start session and wait a moment for it to actually start
                self.session.startRunning()
                
                // Give the session time to start (important!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let inputsCnt = self.session.inputs.count
                    let outputsCnt = self.session.outputs.count
                    let running = self.session.isRunning
                    
                    self.inputsCount = inputsCnt
                    self.outputsCount = outputsCnt
                    self.isRunning = running
                    
                    let success = running && inputsCnt > 0 && outputsCnt > 0
                    print("📹 Camera status - Running: \(running), Inputs: \(inputsCnt), Outputs: \(outputsCnt)")
                    
                    completion(success)
                }
            }
        }
    }
    
    func stop() {
        captureQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
    }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }
    
    private func checkCameraPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { completion($0) }
        default: completion(false)
        }
    }
    
    func previewLayerRef() -> AVCaptureVideoPreviewLayer? { previewLayer }
}

// MARK: - Preview View (FIXED)
struct PreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black  // Add background color
        layer.frame = v.bounds
        layer.videoGravity = .resizeAspectFill  // Ensure this is set
        if let conn = layer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        v.layer.addSublayer(layer)
        return v
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update on main thread
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.frame = uiView.bounds
            CATransaction.commit()
            
            if let conn = self.layer.connection, conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
    }
}

struct EyeBoxOverlay: View {
    let normalizedRect: CGRect?
    let isGood: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let rect = normalizedRect {
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let drawX = (1.0 - (rect.minX + rect.width)) * width
                    let drawY = (1.0 - (rect.minY + rect.height)) * height
                    let drawW = rect.width * width
                    let drawH = rect.height * height
                    let color: Color = isGood ? .green : .yellow
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color, lineWidth: 3)
                        .frame(width: drawW, height: drawH)
                        .position(x: drawX + drawW/2, y: drawY + drawH/2)
                        .shadow(radius: 2, x: 0, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                        .frame(width: min(geometry.size.width, 260), height: min(geometry.size.height, 260) * 0.8)
                        .overlay(
                            Text("Center your face").font(.caption).foregroundStyle(.secondary)
                                .padding(6).background(.thinMaterial, in: Capsule()).padding(.top, 8),
                            alignment: .top
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Blink Test View (FIXED)
struct BlinkTestView_Vision: View {
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    @StateObject private var detector = VisionBlinkDetector()
    @StateObject private var pipeline = CameraPipeline()
    
    @State private var blinkCount = 0
    @State private var secondsLeft = 30
    @State private var timer: Timer?
    @State private var running = false
    @State private var calibrating = false
    @State private var calibrationCountdown = 3
    @State private var previewLayer: AVCaptureVideoPreviewLayer?
    @State private var faceROI: CGRect?
    @State private var roiGood = false
    @State private var cameraError = false
    @State private var cameraReady = false
    @State private var started: Date?
    @State private var showLowLightAlert = false
    @State private var showStartDespiteLowLightConfirm = false
    @State private var previousLowLight = false
    
    var body: some View {
        ZStack {
            if let layer = previewLayer {
                PreviewView(layer: layer).ignoresSafeArea()
                EyeBoxOverlay(normalizedRect: faceROI, isGood: roiGood).ignoresSafeArea()
            } else { Color.black.ignoresSafeArea() }
            
            VStack {
                if cameraReady && detector.isLowLight && !cameraError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "light.max.trianglebadge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lighting is low")
                                .font(.subheadline).fontWeight(.semibold)
                            Text("Move to a brighter area (near a window or turn on more lights) so your face is evenly lit.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                Spacer()
                VStack(spacing: 12) {
                    if cameraError {
                        VStack(spacing: 8) {
                            Text("⚠️ Camera unavailable").foregroundStyle(.red).font(.headline)
                            Text("This device or environment doesn't support camera capture.").font(.caption).foregroundStyle(.secondary)
                            Button("Skip Test") { skipAsUnavailable(reason: "camera_unavailable") }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if !cameraReady {
                        ProgressView(); Text("Starting camera...").font(.caption)
                    } else if calibrating {
                        VStack(spacing: 8) {
                            Text("Calibrating...").font(.headline)
                            Text("Keep eyes WIDE OPEN with face positioned so green box is visible").font(.caption).foregroundStyle(.secondary)
                            Text("\(calibrationCountdown)").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        }.padding().background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else if running {
                        VStack(spacing: 12) {
                            Text("Blink normally").font(.headline)
                            HStack(spacing: 30) {
                                VStack { Text("\(secondsLeft)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit(); Text("seconds").font(.caption2) }
                                VStack { Text("\(blinkCount)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(blinkCount > 0 ? .green : .orange); Text("blinks").font(.caption2) }
                            }
                        }.padding().background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "eye.fill").font(.largeTitle)
                            Text("Blink Rate Test").font(.title3).fontWeight(.semibold)
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Use bright, even lighting on your face (daylight or indoor lamps).", systemImage: "sun.max.fill")
                                Label("Remove glasses and sunglasses—reflections and tint can block eye tracking.", systemImage: "eyeglasses")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Text("Position your face in the frame until the box turns green.").font(.caption2).foregroundStyle(.tertiary)
                            Button("Start Test") { requestStartCalibration() }.buttonStyle(.borderedProminent).disabled(!cameraReady)
                        }.padding().background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(.bottom, 40)
            }
        }
        .onAppear { setupCamera() }
        .onDisappear { cleanup() }
        .onChange(of: detector.isLowLight) { _, nowLow in
            guard cameraReady, !cameraError else { return }
            if nowLow && !previousLowLight {
                if calibrating || running {
                    showLowLightAlert = true
                }
            }
            previousLowLight = nowLow
        }
        .alert("Improve lighting", isPresented: $showLowLightAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The scene looks dark. Move to a brighter spot, face a window or lamp, and take off glasses or sunglasses. Poor light can make blink counts unreliable.")
        }
        .confirmationDialog("Lighting still looks low", isPresented: $showStartDespiteLowLightConfirm, titleVisibility: .visible) {
            Button("Start anyway") { startCalibration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For accurate results, use brighter light and remove glasses or sunglasses. You can still start if needed.")
        }
    }
    
    private func requestStartCalibration() {
        if detector.isLowLight {
            showStartDespiteLowLightConfirm = true
        } else {
            startCalibration()
        }
    }
    
    private func setupCamera() {
        // Guard unsupported environments (e.g., Simulator or no front camera)
        if !isCameraAvailableForBlink() {
            DispatchQueue.main.async {
                self.cameraReady = false
                self.cameraError = true
            }
            return
        }
        detector.onBlink = {
            if self.running {
                self.blinkCount += 1; playShortChime()
                let generator = UIImpactFeedbackGenerator(style: .medium); generator.impactOccurred()
            }
        }
        detector.onROI = { rect, good in self.faceROI = rect; self.roiGood = good }
        pipeline.configurePreviewLayerIfNeeded { layer in DispatchQueue.main.async { self.previewLayer = layer } }
        pipeline.start(detector: detector, position: .front) { success in
            DispatchQueue.main.async {
                self.cameraReady = success
                self.cameraError = !success
            }
        }
    }
    private func startCalibration() {
        calibrating = true; calibrationCountdown = 3; detector.beginCalibration()
        var countdown = 3; timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            countdown -= 1; self.calibrationCountdown = countdown
            if countdown <= 0 {
                t.invalidate(); detector.endCalibration(); self.calibrating = false; self.startTest()
            }
        }
    }
    private func startTest() {
        blinkCount = 0; secondsLeft = 30; running = true; started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.secondsLeft > 0 { self.secondsLeft -= 1 } else { t.invalidate(); self.finish() }
        }
    }
    private func finish() {
        running = false; let end = Date(); let start = started ?? end
        let rate = (Double(blinkCount) / 30.0) * 60.0
        cleanup()
        var data = ["blinksPerMinute": String(format: "%.1f", rate), "totalBlinks": "\(blinkCount)"]
        data.merge(deviceMeta(task: "Blink Rate", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Blink Rate", data: data, notes: String(format: "%.1f blinks/min", rate))
        playChime(); onComplete(result)
    }
    private func cleanup() {
        timer?.invalidate(); pipeline.stop(); running = false; calibrating = false
    }
    private func skipAsUnavailable(reason: String) {
        let end = Date(); let start = end
        var data = [
            "blinksPerMinute": "0.0",
            "totalBlinks": "0",
            "unavailable": "true",
            "reason": reason
        ]
        data.merge(deviceMeta(task: "Blink Rate", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Blink Rate", data: data, notes: "Skipped (camera unavailable)")
        onComplete(result)
    }
}

// Balance / Sway Test (stand still 15s)
struct BalanceTestView: View {
    @EnvironmentObject private var vm: AppViewModel
    let studyID: String
    let onComplete: (AssessmentResult) -> Void
    
    private let motion = CMMotionManager()
    @State private var secondsLeft = 15
    @State private var running = false
    @State private var timer: Timer?
    @State private var prepTimer: Timer?
    @State private var started: Date?
    @State private var preCountdown: Int = 0
    @State private var mags: [Double] = []
    @State private var ax: [Double] = []
    @State private var ay: [Double] = []
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.stand").font(.system(size: 60)).foregroundStyle(.blue)
            Text("Balance Test").font(.title2).fontWeight(.bold)
            Text("Stand still with the phone in a pocket or held against your chest for 15 seconds.").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            if preCountdown > 0 {
                Text("\(preCountdown)").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Get ready…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("\(secondsLeft)s").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Spacer()
            if !running { Button("Start") { start() }.buttonStyle(.borderedProminent) }
        }
        .padding()
        .overlay {
            if preCountdown > 0 {
                VStack(spacing: 8) {
                    Text("Get ready…").font(.headline)
                    Text("\(preCountdown)").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding()
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    
    private func start() {
        if running { return }
        running = true; secondsLeft = 15; preCountdown = 3
        mags.removeAll(); ax.removeAll(); ay.removeAll()
        prepTimer?.invalidate()
        prepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            if self.preCountdown > 0 { self.preCountdown -= 1 } else {
                t.invalidate()
                self.prepTimer = nil
                self.beginSway()
            }
        }
    }
    private func beginSway() {
        started = Date()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.02 // 50 Hz
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            if let dm = self.motion.deviceMotion {
                let u = dm.userAcceleration
                let m = sqrt(u.x*u.x + u.y*u.y + u.z*u.z)
                self.mags.append(m)
                self.ax.append(u.x); self.ay.append(u.y)
            }
            let elapsed = Date().timeIntervalSince(self.started ?? Date())
            let remaining = max(0, Int(ceil(15.0 - elapsed)))
            if remaining != self.secondsLeft {
                self.secondsLeft = remaining
            }
            if elapsed >= 15.0 {
                t.invalidate(); self.finish()
            }
        }
    }
    private func finish() {
        prepTimer?.invalidate()
        prepTimer = nil
        timer?.invalidate()
        motion.stopDeviceMotionUpdates()
        running = false
        secondsLeft = 0
        let end = Date(); let start = started ?? end
        func mean(_ arr: [Double]) -> Double { arr.isEmpty ? 0.0 : arr.reduce(0,+)/Double(arr.count) }
        func std(_ arr: [Double]) -> Double {
            guard !arr.isEmpty else { return 0.0 }
            let m = mean(arr); let v = arr.map { ($0-m)*($0-m) }.reduce(0,+)/Double(arr.count); return sqrt(v)
        }
        let rms = std(mags) // approximate sway magnitude
        let stdX = std(ax)
        let stdY = std(ay)
        var data = [
            "sway_rms": String(format: "%.4f", rms),
            "sway_std_x": String(format: "%.4f", stdX),
            "sway_std_y": String(format: "%.4f", stdY)
        ]
        if !vm.participant.handedness.isEmpty { data["handedness"] = vm.participant.handedness }
        data.merge(deviceMeta(task: "Balance", taskVersion: "1.0", start: start, end: end, studyID: studyID)) { _, n in n }
        let result = AssessmentResult(id: UUID(), date: end, studyID: studyID, assessmentType: "Balance", data: data, notes: "Balance sway")
        playChime(); onComplete(result)
    }
}

// MARK: - Helpers
extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
