import SwiftUI

struct BreadcrumbView: View {
    let path: String
    let onNavigate: (String) -> Void

    private var segments: [(label: String, path: String)] {
        guard !path.isEmpty else { return [] }
        var result: [(String, String)] = []
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }

        if path.hasPrefix("/") {
            result.append(("/", "/"))
        }

        var cumulative = ""
        for component in components {
            cumulative += "/\(component)"
            result.append((component, cumulative))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                crumbs
            }
            // Keep the current folder (trailing segment) visible after navigating
            // deep, instead of leaving the breadcrumb pinned at the root.
            .onChange(of: path) {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(segments.count - 1, anchor: .trailing)
                    }
                }
            }
            .onAppear { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
        }
    }

    private var crumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                let isLast = idx == segments.count - 1
                let isRoot = segment.label == "/"

                if isLast {
                    // Current location — non-interactive
                    Group {
                        if isRoot {
                            Image(systemName: "house.fill")
                        } else {
                            Text(segment.label)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .id(idx)
                } else {
                    Button {
                        onNavigate(segment.path)
                    } label: {
                        Group {
                            if isRoot {
                                Image(systemName: "house")
                            } else {
                                Text(segment.label)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .id(idx)
                }
            }
        }
    }
}
