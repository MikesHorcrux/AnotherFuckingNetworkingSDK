import SwiftUI

struct ContentView: View {
    @Bindable var model: HostModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Download") {
                    TextField("HTTP(S) URL", text: $model.sourceURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("Start") { model.startDownload() }
                            .buttonStyle(.borderedProminent)
                        Button("Pause") { model.pauseDownload() }
                            .buttonStyle(.bordered)
                    }
                }

                Section("Lifecycle") {
                    Text(model.status)
                        .font(.footnote)
                    if let taskIdentifier = model.activeTaskIdentifier {
                        Text("Foundation task: \(taskIdentifier)")
                            .font(.caption.monospaced())
                    }
                }

                Section("Durable jobs") {
                    ForEach(model.jobs, id: \.id) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.requestKey)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(job.state.rawValue) · \(job.bytesCompleted) bytes")
                                .font(.caption2.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("AFN Background Host")
        }
    }
}
