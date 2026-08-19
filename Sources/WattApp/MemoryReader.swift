import Foundation
import Darwin

/// Lettura della memoria di sistema.
///
/// Usa `host_statistics64` invece di lanciare `vm_stat`: nessun processo da
/// generare a ogni aggiornamento, e nessun privilegio richiesto.
enum MemoryReader {

    struct Snapshot {
        var freeBytes: UInt64
        var inactiveBytes: UInt64
        var compressedBytes: UInt64
        var totalBytes: UInt64

        /// Quello che macOS considera davvero disponibile: la memoria libera
        /// piu' quella inattiva, che il sistema puo' riassegnare all'istante.
        var availableBytes: UInt64 { freeBytes + inactiveBytes }

        var availableText: String { Snapshot.gigabytes(availableBytes) }
        var freeText: String { Snapshot.gigabytes(freeBytes) }

        static func gigabytes(_ bytes: UInt64) -> String {
            String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
    }

    static func read() -> Snapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // `vm_kernel_page_size` e' una var globale mutabile e Swift 6 non la
        // considera sicura da leggere: la si chiede al kernel.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }
        let page = UInt64(pageSize)
        return Snapshot(
            freeBytes: UInt64(stats.free_count) * page,
            inactiveBytes: UInt64(stats.inactive_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            totalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
