//
//  TurnInProgressView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorDesign
import SwiftUI

struct TurnInProgressView: View {
    @ScaledMetric(relativeTo: ThemeFontStyle.codeSmall.textStyle)
    private var indicatorSize = ThemeFontStyle.codeSmall.size

    let row: Turn.Row.TurnInProgress

    var body: some View {
        Label {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(row.startedAt))
                Text(Self.elapsedTimeDescription(elapsed))
                    .monospacedDigit()
                    .accessibilityLabel("Working")
                    .accessibilityValue(
                        "Elapsed \(Self.elapsedTimeDescription(elapsed, showsTenths: false))"
                    )
            }
        } icon: {
            ProgressView()
                .progressViewStyle(.conductor)
                .tint(.theme(.textSecondary))
                .frame(width: indicatorSize, height: indicatorSize)
                .accessibilityHidden(true)
        }
        .labelStyle(.conductorSmall)
        .font(.theme(.codeSmall))
        .foregroundStyle(.theme(.textSecondary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func elapsedTimeDescription(
        _ interval: TimeInterval,
        showsTenths: Bool
    ) -> String {
        let precision = showsTenths ? 10 : 1
        let elapsed = max(0, Int(interval * Double(precision)))
        let secondsPerHour = 60 * 60
        let hours = elapsed / (secondsPerHour * precision)
        let minutes = elapsed / (60 * precision) % 60
        let seconds = elapsed / precision % 60
        let secondsDescription = if showsTenths {
            "\(seconds).\(elapsed % precision)s"
        } else {
            "\(seconds)s"
        }

        return if hours > 0 {
            "\(hours)h, \(minutes)m, \(secondsDescription)"
        } else if minutes > 0 {
            "\(minutes)m, \(secondsDescription)"
        } else {
            secondsDescription
        }
    }
}

#Preview {
    TurnInProgressView(
        row: .init(id: "turn-1", startedAt: Date())
    )
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
