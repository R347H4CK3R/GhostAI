import SwiftUI

/// Shared native components keep content readable at accessibility text sizes.
struct LibraryOverview: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(eyebrow, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.cyan)
            Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryMetric: View {
    let value: String
    let title: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct LibraryEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

struct LibraryItemIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.cyan)
            .frame(width: 42, height: 42)
            .background(.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
