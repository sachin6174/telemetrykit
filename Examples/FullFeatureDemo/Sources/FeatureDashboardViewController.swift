import UIKit
import TelemetryKit

@MainActor
final class FeatureDashboardViewController: UIViewController {
    private enum Action: CaseIterable {
        case start
        case grantConsent
        case pendingConsent
        case denyConsent
        case allValues
        case allLevelsAndCategories
        case allSpans
        case clientNetwork
        case factoryNetwork
        case forwardedNetwork
        case queueStatus
        case flush
        case invalidFlush
        case erase
        case shutdown

        var title: String {
            switch self {
            case .start: return "1. Start Client (Pending Consent)"
            case .grantConsent: return "2. Grant Consent"
            case .pendingConsent: return "Set Consent to Pending"
            case .denyConsent: return "Deny Consent and Purge"
            case .allValues: return "3. Capture Every Value Type"
            case .allLevelsAndCategories: return "4. Every Level and Category"
            case .allSpans: return "5. All Span Outcomes"
            case .clientNetwork: return "6. Client Instrumented Request"
            case .factoryNetwork: return "7. Factory Instrumented Request"
            case .forwardedNetwork: return "8. Forward Metrics from App Delegate"
            case .queueStatus: return "9. Inspect Queue Status"
            case .flush: return "10. Flush and Show Report"
            case .invalidFlush: return "Test Invalid Flush Timeout"
            case .erase: return "11. Erase Stored Data"
            case .shutdown: return "12. Permanently Shut Down"
            }
        }

        var detail: String {
            switch self {
            case .start:
                return "Builds the complete configuration and starts without collection permission."
            case .grantConsent:
                return "Opens capture only after the runtime is privacy-ready."
            case .pendingConsent:
                return "Closes capture and purges queued telemetry."
            case .denyConsent:
                return "Revokes collection, stops adapters, cancels upload, and purges."
            case .allValues:
                return "String, integer, double, Boolean, array, object, null, and redaction."
            case .allLevelsAndCategories:
                return "Exercises all five severities and all seven collection categories."
            case .allSpans:
                return "Success, cancellation, error, attributes, timing, and end-once behavior."
            case .clientNetwork:
                return "Uses client.makeInstrumentedURLSession(configuration:)."
            case .factoryNetwork:
                return "Uses TelemetryNetworkInstrumentation.makeSession directly."
            case .forwardedNetwork:
                return "Uses TelemetryNetworkMetricsRecorder with an app-owned delegate."
            case .queueStatus:
                return "Reads counts, encoded payload bytes, and the oldest event date."
            case .flush:
                return "Attempts bounded delivery and displays the complete flush report."
            case .invalidFlush:
                return "Demonstrates the public invalid-configuration error path safely."
            case .erase:
                return "Deletes in-memory and disk data without changing consent."
            case .shutdown:
                return "Stops forever, releases storage, and proves later capture is rejected."
            }
        }
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let stateLabel = UILabel()
    private let latestResultLabel = UILabel()
    private let logView = UITextView()
    private var isPerformingAction = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TelemetryKit Full Demo"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        view.backgroundColor = .systemGroupedBackground
        configureTable()
        updateStateLabel()
        appendLog("Ready. Follow the numbered golden path from 1 through 12.")
    }

    private func configureTable() {
        tableView.accessibilityIdentifier = "telemetry.feature.table"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ActionCell")
        view.addSubview(tableView)

        stateLabel.font = .preferredFont(forTextStyle: .headline)
        stateLabel.accessibilityIdentifier = "telemetry.client.state"
        stateLabel.textColor = .label
        stateLabel.numberOfLines = 0

        let explanation = UILabel()
        explanation.font = .preferredFont(forTextStyle: .subheadline)
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0
        explanation.text = "This app intentionally starts with pending consent. Its upload endpoint uses the reserved .invalid domain, so no demo telemetry can reach a real collector until a developer replaces it."

        latestResultLabel.accessibilityIdentifier = "telemetry.latest.result"
        latestResultLabel.font = .preferredFont(forTextStyle: .footnote)
        latestResultLabel.textColor = .systemBlue
        latestResultLabel.numberOfLines = 0
        latestResultLabel.text = "Latest result: none yet"

        let headerStack = UIStackView(arrangedSubviews: [stateLabel, explanation, latestResultLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 8
        headerStack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        headerStack.isLayoutMarginsRelativeArrangement = true
        headerStack.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 190)
        tableView.tableHeaderView = headerStack

        logView.isEditable = false
        logView.accessibilityIdentifier = "telemetry.activity.log"
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textColor = .label
        logView.backgroundColor = .secondarySystemGroupedBackground
        logView.layer.cornerRadius = 12
        logView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 300))
        logView.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(logView)
        NSLayoutConstraint.activate([
            logView.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            logView.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            logView.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            logView.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -20),
        ])
        tableView.tableFooterView = footer

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func perform(_ action: Action) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        tableView.isUserInteractionEnabled = false
        appendLog("▶︎ \(action.title)")

        Task { [weak self] in
            guard let self else { return }
            defer {
                isPerformingAction = false
                tableView.isUserInteractionEnabled = true
                updateStateLabel()
            }

            do {
                let message: String
                switch action {
                case .start:
                    message = try await TelemetryDemoService.shared.start()
                case .grantConsent:
                    message = try await TelemetryDemoService.shared.setConsent(.granted)
                case .pendingConsent:
                    message = try await TelemetryDemoService.shared.setConsent(.pending)
                case .denyConsent:
                    message = try await TelemetryDemoService.shared.setConsent(.denied)
                case .allValues:
                    message = try TelemetryDemoService.shared.captureEveryValueType()
                case .allLevelsAndCategories:
                    message = try TelemetryDemoService.shared.captureEveryLevelAndCategory()
                case .allSpans:
                    message = try await TelemetryDemoService.shared.exerciseAllSpanOutcomes()
                case .clientNetwork:
                    message = try await TelemetryDemoService.shared.performClientInstrumentedRequest()
                case .factoryNetwork:
                    message = try await TelemetryDemoService.shared.performFactoryInstrumentedRequest()
                case .forwardedNetwork:
                    message = try await TelemetryDemoService.shared.performForwardedMetricsRequest()
                case .queueStatus:
                    message = try await TelemetryDemoService.shared.queueStatus()
                case .flush:
                    message = try await TelemetryDemoService.shared.flush()
                case .invalidFlush:
                    message = try await TelemetryDemoService.shared.demonstrateInvalidFlushTimeout()
                case .erase:
                    message = try await TelemetryDemoService.shared.eraseStoredData()
                case .shutdown:
                    message = await TelemetryDemoService.shared.shutdown()
                }
                // Publish the final result only after the controls are usable
                // again. Besides feeling correct to VoiceOver users, this gives
                // automation one trustworthy completion signal.
                isPerformingAction = false
                tableView.isUserInteractionEnabled = true
                updateStateLabel()
                appendLog("✓ \(message)")
            } catch is CancellationError {
                isPerformingAction = false
                tableView.isUserInteractionEnabled = true
                updateStateLabel()
                appendLog("◼︎ Operation was cancelled. Queued events remain governed by queue policy.")
            } catch {
                isPerformingAction = false
                tableView.isUserInteractionEnabled = true
                updateStateLabel()
                appendLog("✕ \(error.localizedDescription)")
            }
        }
    }

    private func updateStateLabel() {
        let service = TelemetryDemoService.shared
        stateLabel.text = service.isRunning
            ? "Client: running  •  Consent: \(service.consent.rawValue)"
            : "Client: stopped  •  Consent: pending"
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        let line = "[\(timestamp)] \(message)"
        latestResultLabel.text = "Latest result: \(message)"
        logView.text = logView.text.isEmpty ? line : "\(logView.text!)\n\n\(line)"
        logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count, length: 0))
    }
}

extension FeatureDashboardViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Action.allCases.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
        let action = Action.allCases[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = action.title
        content.secondaryText = action.detail
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        perform(Action.allCases[indexPath.row])
    }
}
