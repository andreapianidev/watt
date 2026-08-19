import Foundation

/// Valori iniettati a build time da `scripts/build.sh`, che li ricava dalla
/// firma effettiva. Quelli qui sotto servono solo a far compilare il
/// sorgente appena clonato.
public enum WattBuildConfig {

    /// Team ID Apple Developer atteso dall'helper nel requisito di codesign.
    ///
    /// Va ricavato dalla **firma**, non dal nome del certificato: in
    /// un'identita' "Apple Development: Nome (XXXXXXXXXX)" il valore fra
    /// parentesi e' l'ID personale dello sviluppatore e differisce dal team.
    /// Usare quello produce un requisito che nessuna firma soddisfa, e
    /// l'helper rifiuta la propria stessa app senza dire perche'.
    public static let teamIdentifier = "ERAK83QBBM"

    /// Se `true` l'helper accetta qualunque client senza verificarne la
    /// firma. Solo per compilare in locale con binari non firmati: in questo
    /// stato un demone root e' pilotabile da qualunque processo dell'utente.
    public static let skipClientVerification = false
}
