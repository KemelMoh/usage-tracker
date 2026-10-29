import Foundation
import Combine

/// Reloj de la interfaz, separado de `AppModel` a propósito.
///
/// `AppModel` lo observa la aplicación entera. Si el reloj viviera ahí, cada
/// tic invalidaría todos los observadores y forzaría a rehacer la vista de
/// catálogos y de historial aunque nada hubiera cambiado. Con un objeto
/// propio, solo las vistas que muestran tiempos o cuentas atrás se actualizan.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Date()

    private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }
}
