// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit

extension View {
    /// A «Listo» button above the keyboard. Number pads have no return key, so without it the
    /// keyboard of an amount field cannot be closed.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("app.done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
    }

    /// The whole row opens its editor; buttons inside the row keep their own action.
    func tapToEdit(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("app.tapToEdit"))
            .accessibilityAction(named: Text("form.edit"), action)
    }
}

/// The currencies a form offers.
struct CurrencyPicker: View {
    @Binding var currency: String

    var body: some View {
        Picker("form.currency", selection: $currency) {
            Text(verbatim: "CRC").tag("CRC")
            Text(verbatim: "USD").tag("USD")
        }
    }
}
