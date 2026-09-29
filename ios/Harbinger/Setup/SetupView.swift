import SwiftUI

struct SetupView: View {
  @State var model: SetupViewModel
  let onSaved: (Connection) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("Endpoint URL") {
          TextField("https://…", text: $model.endpoint)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Section("API key") {
          SecureField("API key", text: $model.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        if let message = model.errorMessage {
          Section {
            Text(message)
              .foregroundStyle(.red)
          }
        }
        Section {
          Button {
            Task {
              if let connection = await model.save() {
                onSaved(connection)
              }
            }
          } label: {
            if model.isChecking {
              ProgressView()
            } else {
              Text("Save")
            }
          }
          .disabled(!model.canSave)
        }
      }
      .navigationTitle("Connect")
    }
  }
}
