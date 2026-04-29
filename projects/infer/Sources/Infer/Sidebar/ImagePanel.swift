import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InferCore

/// Stable Diffusion sidebar panel. Extracted from `SidebarView` into its own
/// `View` struct so it can carry its own `@State` (the multi-file
/// disclosure expansion) seeded from VM persistence at construction time.
/// `SidebarView`'s tab dispatch instantiates one of these for the Image tab
/// (see `SidebarView.imageSection`).
struct SDImagePanel: View {
    /// `@Bindable` so child controls can use `$vm.sdXxx` to obtain
    /// two-way bindings into the @Observable view model — same pattern as
    /// `SidebarView.vm`.
    @Bindable var vm: ChatViewModel
    /// Whether the multi-file (Z-Image / Flux) component disclosure is
    /// expanded. Seeded from VM persistence in `init`: if any of the
    /// component fields has a saved value, the disclosure opens
    /// immediately so returning users see their config; otherwise it's
    /// collapsed and SD-1.x / SDXL users see only the single all-in-one
    /// field. After init, the user can toggle freely — `@State` keeps
    /// their choice for the session.
    @State private var componentsExpanded: Bool

    init(vm: ChatViewModel) {
        self._vm = Bindable(vm)
        let anyComponentFilled = !vm.sdDiffusionModelInput.isEmpty
            || !vm.sdVAEInput.isEmpty
            || !vm.sdLLMInput.isEmpty
            || !vm.sdT5XXLInput.isEmpty
            || !vm.sdClipLInput.isEmpty
        self._componentsExpanded = State(initialValue: anyComponentFilled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelRow
            promptRow
            paramsRow
            generateRow
            progressRow
            galleryRow
        }
        .onAppear { vm.refreshGallery() }
    }

    // MARK: - Model row

    @ViewBuilder
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(icon: "cube.box", title: "Image Model")

            // Status / loading indicator. Mirrors the chat-header pattern.
            HStack(spacing: 6) {
                if vm.sdIsLoadingModel {
                    if let p = vm.sdDownloadProgress {
                        ProgressView(value: p)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("\(Int(p * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(vm.sdModelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Single-file (SD 1.x/2.x/SDXL/Flux all-in-one) goes here.
            // Multi-file workflows (Z-Image, Flux split) leave this blank
            // and fill the disclosure below.
            componentField(
                label: "All-in-one model",
                placeholder: ".safetensors / https URL / namespace/name/file.ext",
                binding: $vm.sdModelInput
            )

            DisclosureGroup(
                isExpanded: $componentsExpanded,
                content: {
                    VStack(alignment: .leading, spacing: 6) {
                        componentField(
                            label: "Diffusion model",
                            placeholder: "diffusion-only file (e.g. z_image_turbo-Q6_K.gguf)",
                            binding: $vm.sdDiffusionModelInput
                        )
                        componentField(
                            label: "VAE",
                            placeholder: "ae.safetensors",
                            binding: $vm.sdVAEInput
                        )
                        componentField(
                            label: "LLM (Z-Image text encoder)",
                            placeholder: "Qwen3-4B-Q8_0.gguf",
                            binding: $vm.sdLLMInput
                        )
                        componentField(
                            label: "T5XXL (Flux)",
                            placeholder: "t5xxl_fp16.safetensors",
                            binding: $vm.sdT5XXLInput
                        )
                        componentField(
                            label: "CLIP-L (Flux)",
                            placeholder: "clip_l.safetensors",
                            binding: $vm.sdClipLInput
                        )
                        Toggle("Offload params to CPU (lower RAM, slower)", isOn: $vm.sdOffloadToCPU)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                },
                label: {
                    Text("Components (Z-Image / Flux multi-file)")
                }
            )
            .font(.caption)

            HStack(spacing: 6) {
                if vm.sdIsLoadingModel {
                    Button(role: .cancel) { vm.cancelSDLoad() } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        vm.loadStableDiffusion()
                    } label: {
                        Label("Load", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    /// One row of the model section: a small label, a text field, and a
    /// Browse button that targets that field's binding. Used for both the
    /// all-in-one slot and each multi-file component.
    @ViewBuilder
    private func componentField(
        label: String,
        placeholder: String,
        binding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.sdIsLoadingModel)
                    .onSubmit { vm.loadStableDiffusion() }
                Button {
                    if let url = FileDialogs.openFile(
                        message: "Select \(label)",
                        contentTypes: Self.modelFileTypes
                    ) {
                        binding.wrappedValue = url.path
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Browse for \(label)")
            }
        }
    }

    private static let modelFileTypes: [UTType] = [
        UTType(filenameExtension: "safetensors"),
        UTType(filenameExtension: "gguf"),
        UTType(filenameExtension: "ckpt"),
    ].compactMap { $0 }

    // MARK: - Prompt rows

    @ViewBuilder
    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $vm.sdPrompt)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            DisclosureGroup("Negative prompt") {
                TextEditor(text: $vm.sdNegativePrompt)
                    .font(.body)
                    .frame(minHeight: 50, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
            .font(.caption)
        }
    }

    // MARK: - Params

    @ViewBuilder
    private var paramsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                paramStepper("Width", value: $vm.sdWidth, range: 64...2048, step: 64)
                paramStepper("Height", value: $vm.sdHeight, range: 64...2048, step: 64)
            }
            HStack {
                paramStepper("Steps", value: $vm.sdSteps, range: 1...150, step: 1)
                paramSliderDouble("CFG", value: $vm.sdCfgScale, range: 1...20)
            }
            Picker("Sampler", selection: $vm.sdSampler) {
                ForEach(SDSampler.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Seed").font(.caption).foregroundStyle(.secondary)
                TextField("random", text: $vm.sdSeedInput)
                    .textFieldStyle(.roundedBorder)
                Button {
                    vm.sdSeedInput = String(Int64.random(in: 0...Int64.max))
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.borderless)
                .help("Generate a fresh random seed")
                Button {
                    vm.sdSeedInput = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear (random per generation)")
            }
        }
    }

    private func paramStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.caption.monospacedDigit())
            }
            Stepper(value: value, in: range, step: step) { EmptyView() }
                .labelsHidden()
        }
    }

    private func paramSliderDouble(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - Generate / progress

    @ViewBuilder
    private var generateRow: some View {
        HStack(spacing: 6) {
            if vm.sdIsGenerating {
                Button(role: .cancel) {
                    vm.cancelImageGeneration()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("sd-cpp can't actually interrupt — current generation runs to completion. This stops follow-on calls.")
            } else {
                Button {
                    vm.generateImage()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.sdModelLoaded || vm.sdPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        if let err = vm.sdErrorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if let p = vm.sdProgress {
            switch p {
            case .step(let cur, let total, let secsPerStep):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(cur), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                    let remaining = Double(max(0, total - cur)) * secsPerStep
                    Text("Step \(cur)/\(total) — \(String(format: "%.1f", secsPerStep))s/step, ~\(Int(remaining))s left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .done(let url):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Gallery

    @ViewBuilder
    private var galleryRow: some View {
        if !vm.sdGallery.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionHeader(icon: "photo.on.rectangle", title: "Gallery")
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(vm.sdOutputDirectory)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Open output folder in Finder")
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(vm.sdGallery) { entry in
                        SDGalleryThumbnail(vm: vm, entry: entry)
                    }
                }
            }
        }
    }
}

extension SidebarView {
    /// Hook into the tab dispatch in `SidebarView.body`. Wraps the panel
    /// View struct so its init runs every time the tab is shown — that's
    /// what lets `componentsExpanded` re-seed from current VM state.
    @ViewBuilder
    var imageSection: some View {
        SDImagePanel(vm: vm)
    }
}

/// Single gallery cell. A proper `View` (not just an inline `@ViewBuilder`)
/// so it can hold its own popover state and re-render the NSImage lazily
/// — `LazyVGrid` of inline thumbnails would otherwise pin all images in
/// memory simultaneously.
struct SDGalleryThumbnail: View {
    let vm: ChatViewModel
    let entry: SDGalleryEntry
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            Group {
                if let img = NSImage(contentsOf: entry.imageURL) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 100)
                        .clipped()
                        .cornerRadius(6)
                } else {
                    Color.gray.opacity(0.2)
                        .frame(width: 100, height: 100)
                        .cornerRadius(6)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reuse settings") { vm.reuseGalleryEntrySettings(entry) }
            Button("Use in chat") { vm.useGalleryEntryInChat(entry) }
            Button("Reveal in Finder") { vm.revealGalleryEntryInFinder(entry) }
        }
        .popover(isPresented: $showingDetail, arrowEdge: .leading) {
            SDGalleryDetail(vm: vm, entry: entry)
                .frame(width: 480)
        }
    }
}

/// Detail popover: full-size image + metadata + action buttons.
struct SDGalleryDetail: View {
    let vm: ChatViewModel
    let entry: SDGalleryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = NSImage(contentsOf: entry.imageURL) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: 460)
                    .cornerRadius(8)
            }
            Text(entry.metadata.prompt)
                .font(.body)
                .lineLimit(4)
            Text("\(entry.metadata.width)×\(entry.metadata.height) · \(entry.metadata.steps) steps · CFG \(String(format: "%.1f", entry.metadata.cfgScale)) · seed \(entry.metadata.seed)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Button("Reuse settings") { vm.reuseGalleryEntrySettings(entry) }
                Button("Use in chat") { vm.useGalleryEntryInChat(entry) }
                Button("Reveal") { vm.revealGalleryEntryInFinder(entry) }
                Spacer()
            }
        }
        .padding(14)
    }
}
