/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main SwiftUI view.
*/

import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        if AppDelegate.launchedAsLoginItem {
            // Silent login-item launch: render nothing and close the window the
            // SwiftUI scene created. The auto-mount runs in the AppDelegate.
            Color.clear
                .frame(width: 1, height: 1)
                .background(WindowCloser())
        } else {
            ConnectionListView()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}

/// Closes the window hosting this view as soon as it appears. Used to keep the
/// login-item launch fully headless.
private struct WindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            view?.window?.close()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
