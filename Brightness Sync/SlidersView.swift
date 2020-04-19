import Combine
import SwiftUI

struct SlidersView: View {
    let monitorPublisher: AnyPublisher<[CFUUID], Never>
    @State private var monitors = [CFUUID]()

    var body: some View {
        SlidersViewInner(monitors: monitors)
            .onReceive(monitorPublisher) {
                self.monitors = $0
            }
    }
}

private struct SlidersViewInner: View {
    let monitors: [CFUUID]

    var body: some View {
        VStack {
            ForEach(monitors, id: \.self) {
                SliderView(monitor: $0)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
    }
}

private struct SliderView: View {
    let monitor: CFUUID
    @EnvironmentObject private var monitorOffsets: MonitorOffsets

    var body: some View {
        Slider(value: $monitorOffsets[monitor], in: -0.4...0.4)
    }
}

struct SliderView_Previews: PreviewProvider {
    static var previews: some View {
        SlidersViewInner(monitors: [CFUUIDCreate(nil), CFUUIDCreate(nil), CFUUIDCreate(nil)])
    }
}
