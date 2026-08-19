import Foundation
import Darwin
import WattKit

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
        /// Byte scritti su disco perche' la RAM non bastava.
        ///
        /// E' il segnale piu' importante che questa app possa dare a chi
        /// compila: leggere una pagina dallo swap costa ordini di grandezza
        /// piu' che dalla RAM, e nessun profilo energetico lo migliora di un
        /// microsecondo.
        var swapUsedBytes: UInt64 = 0
        var swapTotalBytes: UInt64 = 0
        /// Livello di pressione riportato dal kernel: 1 normale, 2 avvertimento,
        /// 4 critico.
        var pressureLevel: Int32 = 1

        /// Quello che macOS considera davvero disponibile: la memoria libera
        /// piu' quella inattiva, che il sistema puo' riassegnare all'istante.
        var availableBytes: UInt64 { freeBytes + inactiveBytes }

        var availableText: String { Snapshot.gigabytes(availableBytes) }
        var freeText: String { Snapshot.gigabytes(freeBytes) }
        var swapText: String { Snapshot.gigabytes(swapUsedBytes) }

        /// `true` quando il sistema sta scrivendo memoria su disco in
        /// quantita' rilevante. Sotto questa soglia lo swap e' fisiologico.
        var isSwapping: Bool { swapUsedBytes > 1_073_741_824 }

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
        let swap = swapUsage()
        return Snapshot(
            freeBytes: UInt64(stats.free_count) * page,
            inactiveBytes: UInt64(stats.inactive_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            pressureLevel: pressureLevel())
    }

    /// Uso dello swap via `sysctl vm.swapusage`, senza lanciare processi.
    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normale, 2 avvertimento,
    /// 4 critico. E' la stessa grandezza che macOS usa per decidere quando
    /// iniziare a comprimere e a scrivere su disco.
    private static func pressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return level
    }
}
