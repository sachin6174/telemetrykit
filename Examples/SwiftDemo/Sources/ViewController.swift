import UIKit

@MainActor
final class ViewController: UIViewController {
    private let consentSwitch = UISwitch()
    private let captureButton = UIButton(type: .system)
    private let requestButton = UIButton(type: .system)
    private let flushButton = UIButton(type: .system)
    private let statusView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TelemetryKit · Swift"
        view.backgroundColor = .systemBackground
        configureView()
        appendStatus("Collection is off. No client has been started.")
    }

    private func configureView() {
        consentSwitch.accessibilityIdentifier = "telemetry.consent"
        captureButton.accessibilityIdentifier = "telemetry.capture"
        statusView.accessibilityIdentifier = "telemetry.status"
        let titleLabel = UILabel()
        titleLabel.text = "Privacy-first demo"
        titleLabel.font = .preferredFont(forTextStyle: .title2)

        let detailLabel = UILabel()
        detailLabel.text =
            "Collection starts only after the switch is enabled. The default telemetry endpoint is intentionally non-routable."
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let consentLabel = UILabel()
        consentLabel.text = "Allow demo telemetry"
        consentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        consentSwitch.addAction(
            UIAction { [weak self] _ in self?.consentChanged() },
            for: .valueChanged
        )

        let consentRow = UIStackView(arrangedSubviews: [consentLabel, consentSwitch])
        consentRow.axis = .horizontal
        consentRow.alignment = .center
        consentRow.spacing = 12

        configureButton(captureButton, title: "Capture local event") { [weak self] in
            self?.captureEvent()
        }
        configureButton(requestButton, title: "Example instrumented request") { [weak self] in
            self?.performRequest()
        }
        configureButton(flushButton, title: "Flush queue") { [weak self] in
            self?.flushQueue()
        }

        statusView.isEditable = false
        statusView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusView.backgroundColor = .secondarySystemBackground
        statusView.layer.cornerRadius = 10
        statusView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        statusView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            detailLabel,
            consentRow,
            captureButton,
            requestButton,
            flushButton,
            statusView,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        updateControls()
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        action: @escaping @MainActor () -> Void
    ) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func consentChanged() {
        let enabled = consentSwitch.isOn
        consentSwitch.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await DemoTelemetry.shared.setCollectionEnabled(enabled)
                appendStatus(
                    enabled ? "Consent granted; client started." : "Collection stopped; client shut down.")
            } catch {
                consentSwitch.setOn(DemoTelemetry.shared.isCollectionEnabled, animated: true)
                appendStatus("Could not change collection: \(error.localizedDescription)")
            }
            consentSwitch.isEnabled = true
            updateControls()
        }
    }

    private func captureEvent() {
        let result = DemoTelemetry.shared.captureButtonTap()
        appendStatus("Capture result: \(String(describing: result))")
    }

    private func performRequest() {
        setActionButtons(enabled: false)
        Task { [weak self] in
            guard let self else { return }
            defer { updateControls() }
            do {
                let statusCode = try await DemoTelemetry.shared.performInstrumentedRequest()
                appendStatus("Instrumented request finished with HTTP \(statusCode).")
            } catch {
                appendStatus("Instrumented request failed: \(error.localizedDescription)")
            }
        }
    }

    private func flushQueue() {
        setActionButtons(enabled: false)
        Task { [weak self] in
            guard let self else { return }
            defer { updateControls() }
            do {
                try await DemoTelemetry.shared.flush()
                appendStatus("Flush completed.")
            } catch is CancellationError {
                appendStatus("Flush cancelled.")
            } catch {
                appendStatus("Flush failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateControls() {
        setActionButtons(enabled: DemoTelemetry.shared.isCollectionEnabled)
    }

    private func setActionButtons(enabled: Bool) {
        captureButton.isEnabled = enabled
        requestButton.isEnabled = enabled
        flushButton.isEnabled = enabled
    }

    private func appendStatus(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        let line = "[\(timestamp)] \(message)"
        statusView.text = statusView.text.isEmpty ? line : "\(statusView.text!)\n\(line)"
        statusView.scrollRangeToVisible(NSRange(location: statusView.text.utf16.count, length: 0))
    }
}
