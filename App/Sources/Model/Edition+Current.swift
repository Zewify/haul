import HaulCore

extension Edition {
    /// Which build this is, decided at compile time by the `DIRECT_EDITION` condition of the Direct configurations.
    static var current: Edition {
        #if DIRECT_EDITION
        .direct
        #else
        .store
        #endif
    }
}
