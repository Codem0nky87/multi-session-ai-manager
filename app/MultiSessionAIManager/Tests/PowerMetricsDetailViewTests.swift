import Testing
import Foundation
import SwiftUI
@testable import MultiSessionAIManager

@Suite @MainActor struct PowerMetricsDetailViewTests {

    @Test func otherWattsCalculationWithAllComponents() {
        let metrics = PowerMetrics(totalWatts: 100.0, cpuWatts: 35.0, gpuWatts: 40.0, source: "rapl+nvml")
        let view = PowerMetricsDetailView(metrics: metrics)
        let other = view.otherWatts
        #expect(other != nil)
        #expect(abs((other ?? 0) - 25.0) < 0.001)

        // If components exceed total due to sensor timing jitter, otherWatts is clamped to 0
        let jitterMetrics = PowerMetrics(totalWatts: 50.0, cpuWatts: 30.0, gpuWatts: 30.0, source: "rapl+nvml")
        let jitterView = PowerMetricsDetailView(metrics: jitterMetrics)
        #expect(jitterView.otherWatts == 0.0)
    }

    @Test func otherWattsCalculationWithPartialComponents() {
        // CPU only
        let cpuOnly = PowerMetrics(totalWatts: 65.0, cpuWatts: 25.0, gpuWatts: nil, source: "rapl")
        let cpuView = PowerMetricsDetailView(metrics: cpuOnly)
        let cpuOther = cpuView.otherWatts
        #expect(cpuOther != nil)
        #expect(abs((cpuOther ?? 0) - 40.0) < 0.001)

        // GPU only
        let gpuOnly = PowerMetrics(totalWatts: 80.0, cpuWatts: nil, gpuWatts: 45.0, source: "nvml")
        let gpuView = PowerMetricsDetailView(metrics: gpuOnly)
        let gpuOther = gpuView.otherWatts
        #expect(gpuOther != nil)
        #expect(abs((gpuOther ?? 0) - 35.0) < 0.001)
    }

    @Test func otherWattsNilWhenNoComponentsOrNoTotal() {
        // Total only without component breakdown
        let totalOnly = PowerMetrics(totalWatts: 65.0, cpuWatts: nil, gpuWatts: nil, source: "acpi")
        let totalView = PowerMetricsDetailView(metrics: totalOnly)
        #expect(totalView.otherWatts == nil)

        // Components without total
        let noTotal = PowerMetrics(totalWatts: nil, cpuWatts: 25.0, gpuWatts: 15.0, source: "rapl")
        let noTotalView = PowerMetricsDetailView(metrics: noTotal)
        #expect(noTotalView.otherWatts == nil)

        // Neither
        let empty = PowerMetrics()
        let emptyView = PowerMetricsDetailView(metrics: empty)
        #expect(emptyView.otherWatts == nil)
    }

    @Test func peakWattsCalculation() {
        // Peak from history
        let viewWithHistory = PowerMetricsDetailView(
            metrics: PowerMetrics(totalWatts: 50.0),
            history: [30.0, 85.0, 40.0]
        )
        #expect(viewWithHistory.peakWatts == 85.0)

        // Peak from current total when higher than history
        let viewWithHigherTotal = PowerMetricsDetailView(
            metrics: PowerMetrics(totalWatts: 120.0),
            history: [30.0, 85.0, 40.0]
        )
        #expect(viewWithHigherTotal.peakWatts == 120.0)

        // Empty history uses current total
        let viewNoHistory = PowerMetricsDetailView(
            metrics: PowerMetrics(totalWatts: 65.4),
            history: []
        )
        #expect(viewNoHistory.peakWatts == 65.4)

        // No power reports nil peak
        let viewNoPower = PowerMetricsDetailView(
            metrics: PowerMetrics(),
            history: []
        )
        #expect(viewNoPower.peakWatts == nil)
    }

    @Test func powerPercentCalculation() {
        // Default ceiling 850W: 85W / 850W = 10%
        let viewDefaultPsu = PowerMetricsDetailView(
            metrics: PowerMetrics(totalWatts: 85.0),
            history: [45.0, 52.0, 85.0]
        )
        #expect(viewDefaultPsu.powerPercent != nil)
        #expect(abs((viewDefaultPsu.powerPercent ?? 0) - 10.0) < 0.001)

        // Custom PSU ceiling 500W: 180W / 500W = 36%
        let viewCustomPsu = PowerMetricsDetailView(
            metrics: PowerMetrics(totalWatts: 180.0, cpuTdpWatts: 105.0, gpuTdpWatts: 250.0, psuCeilingWatts: 500.0),
            history: [150.0, 200.0, 180.0]
        )
        #expect(viewCustomPsu.powerPercent != nil)
        #expect(abs((viewCustomPsu.powerPercent ?? 0) - 36.0) < 0.001)
        #expect(viewCustomPsu.psuCeiling == 500.0)

        // Nil totalWatts yields nil powerPercent
        let viewNil = PowerMetricsDetailView(
            metrics: PowerMetrics(),
            history: [50.0, 60.0]
        )
        #expect(viewNil.powerPercent == nil)
    }

    @Test func viewInitializesAndRendersBody() {
        // Full telemetry
        let full = PowerMetrics(totalWatts: 72.5, cpuWatts: 28.0, gpuWatts: 14.2, source: "rapl+nvml")
        let fullView = PowerMetricsDetailView(metrics: full, history: [50.0, 60.0, 72.5])
        let _ = fullView.body

        // Empty telemetry
        let emptyView = PowerMetricsDetailView(metrics: PowerMetrics(), history: [])
        let _ = emptyView.body
    }

    @Test func cpuAndGpuMetricsDisplayPowerWattage() {
        var cpu = CPUMetrics()
        cpu.powerWatts = 42.5
        #expect(cpu.formattedPower == "42.5W")
        let cpuView = CPUMetricsDetailView(metrics: cpu)
        let _ = cpuView.body

        var gpu = GPUMetrics()
        gpu.powerWatts = 120.0
        #expect(gpu.formattedPower == "120W")
        let gpuView = GPUMetricsDetailView(metrics: gpu, history: [100.0, 120.0])
        let _ = gpuView.body
    }

    @Test func hostMetricsBarViewInitializesWithPowerState() {
        let model = HostMetricsModel()
        let barView = HostMetricsBarView(metricsModel: model)
        let _ = barView.body
        #expect(!model.power.hasPower)
        #expect(model.power.formattedTotalWatts == "—")

        model.power = PowerMetrics(totalWatts: 98.4, cpuWatts: 35.0, gpuWatts: 22.0, source: "rapl+nvml")
        #expect(model.power.hasPower)
        #expect(model.power.formattedTotalWatts == "98.4W")
        let activeBarView = HostMetricsBarView(metricsModel: model)
        let _ = activeBarView.body
    }

    @Test func recommendedPsuCalculationInfoGlyphAndPopover() {
        let metrics = PowerMetrics(
            totalWatts: 65.4,
            cpuWatts: 25.1,
            gpuWatts: 18.2,
            source: "rapl+nvml",
            cpuTdpWatts: 105.0,
            gpuTdpWatts: 220.0,
            psuCeilingWatts: 750.0
        )
        let view = PowerMetricsDetailView(metrics: metrics)
        let _ = view.body

        // Verify title, formula, and explanation constants
        #expect(PowerMetricsDetailView.psuInfoTitle == "Recommended PSU Capacity")
        #expect(PowerMetricsDetailView.psuInfoFormula == "(CPU TDP + GPU TDP + 80W) × 1.4")
        #expect(PowerMetricsDetailView.psuInfoExplanation.contains("(CPU TDP + GPU TDP + 80W) × 1.4"))
        #expect(PowerMetricsDetailView.psuInfoExplanation.contains("rounded up to standard PSU sizes"))
        #expect(PowerMetricsDetailView.psuInfoExplanation.contains("650W, 750W, 850W, 1000W"))

        // Verify popover component view renders
        let psuInfoView = PowerMetricsPsuInfoView()
        let _ = psuInfoView.body
    }
}
