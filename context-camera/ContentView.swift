//
//  ContentView.swift
//  context-camera
//
//  Updated to use AVFoundation camera with sequential AI capture
//

import SwiftUI
import UIKit
import Foundation
import NaturalLanguage
import AVKit
import AVFoundation

#if canImport(Translation)
import Translation
#endif

struct ContentView: View {
    private enum FocusedControl: Hashable {
        case takePhoto
    }

    private enum OneShotAnalysisRequest {
        case caption(CaptionLength)
        case query(QueryPhotoPreset)
    }

    @StateObject private var contextManager = ContextManager.shared
    @State private var cameraController: CameraController?
    @State private var apiResponse = ""
    @State private var isAnalysisPending = false

    // UI state management
    @State private var showGreenFlash = false
    @State private var showMessage = false
    @State private var displayText = ""
    @State private var captureState: CaptureState = .ready
    @State private var showSettings = false

    // Sequential capture state
    @State private var isContinuousCapture = false
    @State private var isWaitingForShortcutCapture = false

    @State private var translationRequest: CaptionTranslationRequest?
    @AccessibilityFocusState private var focusedControl: FocusedControl?
    @AppStorage(CaptionLength.storageKey) private var oneShotCaptionLengthRawValue = CaptionLength.short.rawValue
    @AppStorage(ContinuousCaptureInterval.storageKey) private var continuousCaptureIntervalRawValue = ContinuousCaptureInterval.defaultInterval.rawValue
    @AppStorage(CaptionTranslationSettings.isEnabledStorageKey) private var isCaptionTranslationEnabled = false
    @AppStorage(CaptionTranslationSettings.targetLanguageStorageKey) private var selectedTranslationLanguageIdentifier = ""

    private var oneShotCaptionLength: CaptionLength {
        get { CaptionLength(rawValue: oneShotCaptionLengthRawValue) ?? .short }
        nonmutating set { oneShotCaptionLengthRawValue = newValue.rawValue }
    }

    private var continuousCaptureInterval: ContinuousCaptureInterval {
        ContinuousCaptureInterval(rawValue: continuousCaptureIntervalRawValue) ?? .defaultInterval
    }

    private var areOneShotActionsDisabled: Bool {
        isAnalysisPending || isContinuousCapture
    }

    func calculateBase64SizeInBytes(base64String: String) {
        let base64Length = base64String.count
        let sizeInBytes = (base64Length * 3) / 4
        let sizeInKiloBytes = sizeInBytes / 1024
        print("AI Analysis: Image size ~\(sizeInKiloBytes)KB")
    }

    func sendImageForAnalysis(imageData: Data, request: OneShotAnalysisRequest) {
        isAnalysisPending = true
        translationRequest = nil

        let base64String = imageData.base64EncodedString()
        calculateBase64SizeInBytes(base64String: base64String)

        let dataURL = "data:image/jpeg;base64,\(base64String)"

        switch request {
        case .caption(let captionLength):
            MoondreamService.shared.generateCaption(for: dataURL, length: captionLength) { result in
                DispatchQueue.main.async {
                    self.handleAnalysisResult(
                        result,
                        imageBase64: dataURL,
                        shouldAttemptTranslation: true
                    )
                }
            }
        case .query(let preset):
            MoondreamService.shared.queryImage(
                dataURL,
                question: preset.prompt,
                enforceSingleSentenceResponse: false
            ) { result in
                DispatchQueue.main.async {
                    self.handleAnalysisResult(
                        result,
                        imageBase64: dataURL,
                        shouldAttemptTranslation: false
                    )
                }
            }
        }
    }

    private func handleAnalysisResult(
        _ result: Result<String, MoondreamError>,
        imageBase64: String,
        shouldAttemptTranslation: Bool
    ) {
        switch result {
        case .success(let response):
            handleAnalysisSuccess(
                response,
                imageBase64: imageBase64,
                shouldAttemptTranslation: shouldAttemptTranslation
            )
        case .failure(let error):
            apiResponse = error.localizedDescription
            isAnalysisPending = false
            scheduleNextContinuousCaptureIfNeeded()
        }
    }

    private func handleAnalysisSuccess(
        _ response: String,
        imageBase64: String,
        shouldAttemptTranslation: Bool
    ) {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedResponse.isEmpty else {
            apiResponse = ""
            isAnalysisPending = false
            scheduleNextContinuousCaptureIfNeeded()
            return
        }

        if shouldAttemptTranslation {
            #if canImport(Translation)
            let targetLanguageIdentifier = selectedTranslationLanguageIdentifier.nilIfEmpty

            if CaptionTranslationSupport.shouldAttemptTranslation(
                for: trimmedResponse,
                isTranslationEnabled: isCaptionTranslationEnabled,
                targetLanguageIdentifier: targetLanguageIdentifier
            ), let targetLanguageIdentifier {
                translationRequest = CaptionTranslationRequest(
                    sourceText: trimmedResponse,
                    targetLanguageIdentifier: targetLanguageIdentifier
                )
            } else {
                presentAnalysisResponse(trimmedResponse)
            }
            #else
            presentAnalysisResponse(trimmedResponse)
            #endif
        } else {
            presentAnalysisResponse(trimmedResponse)
        }

        ContextManager.shared.checkForContexts(imageBase64: imageBase64) { action in
            DispatchQueue.main.async {
                if let action = action {
                    self.triggerActionUI(actionText: action.actionText)
                }
            }
        }

        scheduleNextContinuousCaptureIfNeeded()
    }

    private func presentAnalysisResponse(_ response: String) {
        apiResponse = response
        announceCaptionForAccessibility(response)
        isAnalysisPending = false
        translationRequest = nil
    }

    private func announceCaptionForAccessibility(_ caption: String) {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: caption)
    }

    private func triggerActionUI(actionText: String) {
        displayText = actionText

        withAnimation(.easeInOut(duration: 0.5)) {
            showGreenFlash = true
            showMessage = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.5)) {
                showGreenFlash = false
                showMessage = false
            }
        }
    }

    private func startContinuousCapture() {
        guard !isContinuousCapture else { return }

        isContinuousCapture = true
        captureState = .capturing
        captureImageForAnalysis(request: .caption(.short))

        print("Started continuous sequential capture")
    }

    private func stopContinuousCapture() {
        isContinuousCapture = false
        captureState = .ready

        print("Stopped continuous capture")
    }

    private func takeSinglePhoto() {
        guard !isContinuousCapture else { return }
        captureImageForAnalysis(request: .caption(oneShotCaptionLength))
    }

    private func takePresetPhoto(_ preset: QueryPhotoPreset) {
        guard !isContinuousCapture else { return }
        captureImageForAnalysis(request: .query(preset))
    }

    private func scheduleShortcutCaptureIfNeeded() {
        guard ShortcutLaunchManager.hasPendingCaptureRequest() else { return }
        guard !isWaitingForShortcutCapture else { return }

        isWaitingForShortcutCapture = true
        attemptShortcutCapture(remainingRetries: 20)
    }

    private func attemptShortcutCapture(remainingRetries: Int) {
        guard ShortcutLaunchManager.hasPendingCaptureRequest() else {
            isWaitingForShortcutCapture = false
            return
        }

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            ShortcutLaunchManager.consumePendingCaptureRequest()
            apiResponse = "Camera access is required to describe the scene."
            isWaitingForShortcutCapture = false
            return
        }

        guard !isContinuousCapture, !isAnalysisPending else {
            retryShortcutCapture(remainingRetries: remainingRetries)
            return
        }

        guard let cameraController, cameraController.isReady else {
            retryShortcutCapture(remainingRetries: remainingRetries)
            return
        }

        ShortcutLaunchManager.consumePendingCaptureRequest()
        isWaitingForShortcutCapture = false
        takeSinglePhoto()
    }

    private func retryShortcutCapture(remainingRetries: Int) {
        guard remainingRetries > 0 else {
            ShortcutLaunchManager.consumePendingCaptureRequest()
            apiResponse = "Camera is still getting ready. Please try again."
            isWaitingForShortcutCapture = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.attemptShortcutCapture(remainingRetries: remainingRetries - 1)
        }
    }

    private func scheduleNextContinuousCaptureIfNeeded() {
        guard isContinuousCapture else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + continuousCaptureInterval.timeInterval) {
            guard self.isContinuousCapture else { return }
            self.captureImageForAnalysis(request: .caption(.short))
        }
    }

    private func handleHardwareCaptureEvent(_ event: AVCaptureEvent) {
        guard event.phase == .ended else { return }
        takeSinglePhoto()
    }

    private func captureImageForAnalysis(request: OneShotAnalysisRequest) {
        guard !isAnalysisPending else {
            print("Skipping capture - analysis still pending")
            return
        }

        cameraController?.capturePhoto { imageData in
            DispatchQueue.main.async {
                if let imageData = imageData {
                    self.sendImageForAnalysis(imageData: imageData, request: request)
                } else {
                    print("Failed to capture image")
                    self.scheduleNextContinuousCaptureIfNeeded()
                }
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cameraPreview

            if showGreenFlash {
                Color.green.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showMessage {
                VStack {
                    Text(displayText)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(15)
                }
                .zIndex(2)
                .transition(.scale.combined(with: .opacity))
            }

            Button(action: {
                showSettings = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                    Text("Settings")
                        .font(.headline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
            }
            .disabled(areOneShotActionsDisabled)
            .opacity(areOneShotActionsDisabled ? 0.6 : 1.0)
            .padding(.top, 24)
            .padding(.trailing, 20)
            .zIndex(3)

            VStack {
                Spacer()

                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        if !apiResponse.isEmpty {
                            Text(apiResponse)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                .lineLimit(3)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: {
                            takeSinglePhoto()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.fill")
                                    .font(.title3)
                                Text("Take Photo")
                                    .font(.headline)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                        }
                        .disabled(areOneShotActionsDisabled)
                        .opacity(areOneShotActionsDisabled ? 0.6 : 1.0)
                        .accessibilityLabel("Take Photo")
                        .accessibilityFocused($focusedControl, equals: .takePhoto)

                        Button(action: {
                            if isContinuousCapture {
                                stopContinuousCapture()
                            } else {
                                startContinuousCapture()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: isContinuousCapture ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                                Text(isContinuousCapture ? "Stop" : "Start Continuous Mode")
                                    .font(.headline)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                        }
                        .accessibilityLabel(isContinuousCapture ? "Stop" : "Start Continuous Mode")
                    }

                    HStack(spacing: 12) {
                        ForEach(QueryPhotoPreset.allCases) { preset in
                            Button(action: {
                                takePresetPhoto(preset)
                            }) {
                                VStack(spacing: 6) {
                                    Image(systemName: preset.systemImageName)
                                        .font(.title3)
                                    Text(preset.title)
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 14)
                                .foregroundColor(.white)
                                .background(Color.black.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .disabled(areOneShotActionsDisabled)
                            .opacity(areOneShotActionsDisabled ? 0.6 : 1.0)
                            .accessibilityLabel(preset.title)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }

            captionTranslationView
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(
                selectedCaptionLengthRawValue: $oneShotCaptionLengthRawValue,
                continuousCaptureIntervalRawValue: $continuousCaptureIntervalRawValue,
                isCaptionTranslationEnabled: $isCaptionTranslationEnabled,
                selectedTranslationLanguageIdentifier: $selectedTranslationLanguageIdentifier
            )
        }
        .onAppear {
            if UIAccessibility.isVoiceOverRunning {
                DispatchQueue.main.async {
                    focusedControl = .takePhoto
                }
            }

            scheduleShortcutCaptureIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            scheduleShortcutCaptureIfNeeded()
        }
        .onDisappear {
            stopContinuousCapture()
        }
    }

    @ViewBuilder
    private var cameraPreview: some View {
        let preview = CameraCaptureView(cameraView: $cameraController, captureState: $captureState)
            .edgesIgnoringSafeArea(.all)

        if #available(iOS 26.0, *) {
            preview.onCameraCaptureEvent(isEnabled: !isAnalysisPending && !isContinuousCapture) { event in
                handleHardwareCaptureEvent(event)
            }
        } else {
            preview
        }
    }

    @ViewBuilder
    private var captionTranslationView: some View {
        #if canImport(Translation)
        if let request = translationRequest {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(request.configuration) { session in
                    do {
                        let response = try await session.translate(request.sourceText)
                        await MainActor.run {
                            guard translationRequest?.id == request.id else { return }
                            let translatedCaption = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                            presentAnalysisResponse(translatedCaption.isEmpty ? request.sourceText : translatedCaption)
                        }
                    } catch {
                        await MainActor.run {
                            guard translationRequest?.id == request.id else { return }
                            presentAnalysisResponse(request.sourceText)
                        }
                    }
                }
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCaptionLengthRawValue: String
    @Binding var continuousCaptureIntervalRawValue: Double
    @Binding var isCaptionTranslationEnabled: Bool
    @Binding var selectedTranslationLanguageIdentifier: String

    #if canImport(Translation)
    @StateObject private var translationLanguageStore = TranslationLanguageStore()
    #endif

    private var selectedCaptionLength: Binding<CaptionLength> {
        Binding(
            get: { CaptionLength(rawValue: selectedCaptionLengthRawValue) ?? .short },
            set: { selectedCaptionLengthRawValue = $0.rawValue }
        )
    }

    private var selectedContinuousCaptureInterval: Binding<ContinuousCaptureInterval> {
        Binding(
            get: { ContinuousCaptureInterval(rawValue: continuousCaptureIntervalRawValue) ?? .defaultInterval },
            set: { continuousCaptureIntervalRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Take Photo") {
                    Picker("Caption Length", selection: selectedCaptionLength) {
                        ForEach(CaptionLength.allCases) { length in
                            Text(length.displayName).tag(length)
                        }
                    }

                    Text("This setting applies to Take Photo only. Continuous mode uses the short caption style.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Continuous Mode") {
                    Picker("Capture Frequency", selection: selectedContinuousCaptureInterval) {
                        ForEach(ContinuousCaptureInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }

                    Text("Choose how often Continuous Mode takes a picture. Each completed result is announced when available.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                translationSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            #if canImport(Translation)
            .task {
                await translationLanguageStore.loadLanguages()
                refreshSelectedLanguageIfNeeded()
            }
            #endif
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        #if canImport(Translation)
        Section("Translation") {
            Toggle("Enable Translation", isOn: $isCaptionTranslationEnabled)
                .disabled(!translationLanguageStore.hasAvailableLanguages)

            if translationLanguageStore.isLoading {
                LabeledContent("Target Language") {
                    Text("Loading available languages...")
                        .foregroundColor(.secondary)
                }
            } else if let errorMessage = translationLanguageStore.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if translationLanguageStore.availableLanguages.isEmpty {
                Text("No translation languages are currently available on this device.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Picker("Target Language", selection: $selectedTranslationLanguageIdentifier) {
                    Text("Choose a language").tag("")

                    ForEach(translationLanguageStore.availableLanguages) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
                .disabled(!isCaptionTranslationEnabled)
            }

            Text("Translate captions into the language you choose below.")
                .font(.footnote)
                .foregroundColor(.secondary)

            Text("Only languages available from Apple Translation are shown.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        #else
        Section("Translation") {
            Text("Translation is unavailable on this device.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        #endif
    }

    #if canImport(Translation)
    private func refreshSelectedLanguageIfNeeded() {
        guard !translationLanguageStore.isLoading else { return }

        if translationLanguageStore.availableLanguages.isEmpty {
            selectedTranslationLanguageIdentifier = ""
            isCaptionTranslationEnabled = false
            return
        }

        if selectedTranslationLanguageIdentifier.isEmpty {
            return
        }

        let selectedLanguageStillAvailable = translationLanguageStore.availableLanguages.contains {
            $0.identifier == selectedTranslationLanguageIdentifier
        }

        if !selectedLanguageStillAvailable {
            selectedTranslationLanguageIdentifier = ""
        }
    }
    #endif
}

#if canImport(Translation)
private struct CaptionTranslationRequest: Equatable {
    let id = UUID()
    let sourceText: String
    let targetLanguageIdentifier: String

    var configuration: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: targetLanguageIdentifier)
        )
    }
}
#endif

enum CaptionTranslationSupport {
    static func shouldAttemptTranslation(
        for caption: String,
        isTranslationEnabled: Bool,
        targetLanguageIdentifier: String?
    ) -> Bool {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCaption.isEmpty else { return false }
        guard isTranslationEnabled else { return false }
        guard let targetLanguageIdentifier, !targetLanguageIdentifier.isEmpty else { return false }

        let targetCode = Locale(identifier: targetLanguageIdentifier).language.languageCode?.identifier.lowercased()
        let sourceCode = Locale(identifier: NLLanguageRecognizer.dominantLanguage(for: trimmedCaption)?.rawValue ?? "").language.languageCode?.identifier.lowercased()

        return targetCode != nil && targetCode != sourceCode
    }
}

private enum CaptionTranslationSettings {
    static let isEnabledStorageKey = "captionTranslationEnabled"
    static let targetLanguageStorageKey = "captionTranslationTargetLanguage"
}

private enum ContinuousCaptureInterval: Double, CaseIterable, Identifiable {
    case oneSecond = 1
    case twoSeconds = 2
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    static let storageKey = "continuousCaptureInterval"
    static let defaultInterval: Self = .threeSeconds

    var id: Double { rawValue }

    var timeInterval: TimeInterval { rawValue }

    var displayName: String {
        switch self {
        case .oneSecond:
            return "1 second"
        case .twoSeconds:
            return "2 seconds"
        case .threeSeconds:
            return "3 seconds"
        case .fiveSeconds:
            return "5 seconds"
        case .tenSeconds:
            return "10 seconds"
        case .thirtySeconds:
            return "30 seconds"
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        }
    }
}

private enum QueryPhotoPreset: String, CaseIterable, Identifiable {
    case product
    case dish
    case shortText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .product:
            return "Product"
        case .dish:
            return "Dish"
        case .shortText:
            return "Short Text"
        }
    }

    var prompt: String {
        switch self {
        case .product:
            return "Describe the main product in this image, including its brand, model, and primary function"
        case .dish:
            return "Describe the layout of the food on the plate or tray. Use clock positions or spatial terms"
        case .shortText:
            return "Extract all alphanumeric codes and text visible in the image, such as labels like 'A', '3-2', or '62k'"
        }
    }

    var systemImageName: String {
        switch self {
        case .product:
            return "shippingbox.fill"
        case .dish:
            return "fork.knife.circle.fill"
        case .shortText:
            return "text.magnifyingglass"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#if canImport(Translation)
@MainActor
private final class TranslationLanguageStore: ObservableObject {
    @Published private(set) var availableLanguages: [TranslationLanguageOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    var hasAvailableLanguages: Bool {
        !availableLanguages.isEmpty
    }

    func loadLanguages() async {
        guard availableLanguages.isEmpty, !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let supportedLanguages = try await LanguageAvailability().supportedLanguages
            availableLanguages = supportedLanguages
                .map(TranslationLanguageOption.init)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            errorMessage = "Unable to load translation languages right now."
            availableLanguages = []
        }

        isLoading = false
    }
}

private struct TranslationLanguageOption: Identifiable, Equatable {
    let language: Locale.Language

    var id: String { identifier }

    var identifier: String {
        if !language.maximalIdentifier.isEmpty {
            return language.maximalIdentifier
        }

        if !language.minimalIdentifier.isEmpty {
            return language.minimalIdentifier
        }

        return String(describing: language)
    }

    var displayName: String {
        if let localizedName = Locale.current.localizedString(forIdentifier: identifier), !localizedName.isEmpty {
            return localizedName
        }

        return identifier
    }
}
#endif

struct AlwaysShowScrollIndicators: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                UIScrollView.appearance().showsVerticalScrollIndicator = true
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
