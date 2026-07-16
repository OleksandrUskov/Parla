import ActivityKit
import WidgetKit
import SwiftUI

/// The transcription Live Activity / Dynamic Island. Renders the shared
/// `ParlaTranscriptionAttributes` the app drives (per-chunk updates). ParlaCore-free — brand colours via
/// `WidgetBrand`, the status line arrives already-localized in the state. Tapping it opens Parla (`parla://show`).
struct ParlaTranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParlaTranscriptionAttributes.self) { context in
            // Lock-screen / banner presentation.
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "parla://show"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform").font(.title3).foregroundStyle(WidgetBrand.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let f = context.state.fraction {
                        Text("\(Int(f * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.label).font(.caption.weight(.medium)).lineLimit(1)
                        Text(context.state.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let f = context.state.fraction {
                        ProgressView(value: f).tint(WidgetBrand.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(WidgetBrand.accent)
            } compactTrailing: {
                if let f = context.state.fraction {
                    Text("\(Int(f * 100))%").font(.caption2).monospacedDigit()
                }
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(WidgetBrand.accent)
            }
            .widgetURL(URL(string: "parla://show"))
        }
    }

    @ViewBuilder private func lockScreen(_ s: ParlaTranscriptionAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(WidgetBrand.gradient)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.label).font(.subheadline.weight(.semibold))
                Text(s.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let f = s.fraction {
                    ProgressView(value: f).tint(WidgetBrand.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
