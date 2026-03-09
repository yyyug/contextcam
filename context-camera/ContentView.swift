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

#if canImport(Translation)
import Translation
#endif

struct ContentView: View {
    private enum FocusedControl: Hashable {
        case takePhoto
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

    @State private var translationRequest: CaptionTranslationRequest?
    @AccessibilityFocusState private var focusedControl: FocusedControl?
    @AppStorage(CaptionLength.storageKey) private var oneShotCaptionLengthRawValue = CaptionLength.short.rawValue
    @AppStorage(CaptionTranslationSettings.isEnabledStorageKey) private var isCaptionTranslationEnabled = false
    @AppStorage(CaptionTranslationSettings.targetLanguageStorageKey) private var selectedTranslationLanguageIdentifier = ""

    private var oneShotCaptionLength: CaptionLength {
        get { CaptionLength(rawValue: oneShotCaptionLengthRawValue) ?? .short }
        nonmutating set { oneShotCaptionLengthRawValue = newValue.rawValue }
    }

    func calculateBase64SizeInBytes(base64String: String) {
        let base64Length = base64String.count
        let sizeInBytes = (base64Length * 3) / 4
        let sizeInKiloBytes = sizeInBytes / 1024
        print("AI Analysis: Image size ~\(sizeInKiloBytes)KB")
    }

    func sendImageForCaption(imageData: Data, captionLength: CaptionLength) {
        isAnalysisPending = true

        let base64String = imageData.base64EncodedString()
        calculateBase64SizeInBytes(base64String: base64String)

        let dataURL = "data:image/jpeg;base64,\(base64String)"

        MoondreamService.shared.generateCaption(for: dataURL, length: captionLength) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let caption):
                    self.handleCaptionSuccess(caption)

                    ContextManager.shared.checkForContexts(imageBase64: dataURL) { action in
                        DispatchQueue.main.async {
                            if let action = action {
                                self.triggerActionUI(actionText: action.actionText)
                            }
                        }
                    }

                    if self.isContinuousCapture {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.captureImageForAnalysis(captionLength: .short)
                        }
                    }

                case .failure(let error):
                    self.apiResponse = error.localizedDescription
                    self.isAnalysisPending = false

                    if self.isContinuousCapture {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.captureImageForAnalysis(captionLength: .short)
                        }
                    }
                }
            }
        }
    }

    private func handleCaptionSuccess(_ caption: String) {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedCaption.isEmpty else {
            apiResponse = ""
            isAnalysisPending = false
            return
        }

        #if canImport(Translation)
        let targetLanguageIdentifier = selectedTranslationLanguageIdentifier.nilIfEmpty

        if CaptionTranslationSupport.shouldAttemptTranslation(
            for: trimmedCaption,
            isTranslationEnabled: isCaptionTranslationEnabled,
            targetLanguageIdentifier: targetLanguageIdentifier
        ), let targetLanguageIdentifier {
            translationRequest = CaptionTranslationRequest(
                sourceText: trimmedCaption,
                targetLanguageIdentifier: targetLanguageIdentifier
            )
            return
        }
        #endif

        presentCaption(trimmedCaption)
    }

    private func presentCaption(_ caption: String) {
        apiResponse = caption
        announceCaptionForAccessibility(caption)
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
        captureImageForAnalysis(captionLength: .short)

        print("Started continuous sequential capture")
    }

    private func stopContinuousCapture() {
        isContinuousCapture = false
        captureState = .ready

        print("Stopped continuous capture")
    }

    private func takeSinglePhoto() {
        guard !isContinuousCapture else { return }
        captureImageForAnalysis(captionLength: oneShotCaptionLength)
    }

    private func captureImageForAnalysis(captionLength: CaptionLength) {
        guard !isAnalysisPending else {
            print("Skipping capture - analysis still pending")
            return
        }

        cameraController?.capturePhoto { imageData in
            DispatchQueue.main.async {
                if let imageData = imageData {
                    self.sendImageForCaption(imageData: imageData, captionLength: captionLength)
                } else {
                    print("Failed to capture image")
                    if self.isContinuousCapture {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.captureImageForAnalysis(captionLength: .short)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CameraCaptureView(cameraView: $cameraController, captureState: $captureState)
                .edgesIgnoringSafeArea(.all)

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
            .disabled(isAnalysisPending || isContinuousCapture)
            .opacity((isAnalysisPending || isContinuousCapture) ? 0.6 : 1.0)
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
                    .disabled(isAnalysisPending || isContinuousCapture)
                    .opacity((isAnalysisPending || isContinuousCapture) ? 0.6 : 1.0)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }

            captionTranslationView
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(
                selectedCaptionLengthRawValue: $oneShotCaptionLengthRawValue,
                isCaptionTranslationEnabled: $isCaptionTranslationEnabled,
                selectedTranslationLanguageIdentifier: $selectedTranslationLanguageIdentifier
            )
        }
        .onAppear {
            guard UIAccessibility.isVoiceOverRunning else { return }
            DispatchQueue.main.async {
                focusedControl = .takePhoto
            }
        }
        .onDisappear {
            stopContinuousCapture()
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
                            presentCaption(translatedCaption.isEmpty ? request.sourceText : translatedCaption)
                        }
                    } catch {
                        await MainActor.run {
                            guard translationRequest?.id == request.id else { return }
                            presentCaption(request.sourceText)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Take Photo") {
                    Picker("Caption Length", selection: selectedCaptionLength) {
                        ForEach(CaptionLength.allCases) { length in
                            Text(length.displayName).tag(length)
                        }
                    }

                    Text("This setting applies to Take Photo only. Continuous mode always uses Short.")
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
            .onReceive(translationLanguageStore.$availableLanguages) { _ in
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
