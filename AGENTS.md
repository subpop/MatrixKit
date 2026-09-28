# Architecture Guidelines

- Defer to [spec](https://spec.matrix.org/latest/) compliance when deciding on API design.

# Testing Guidelines

- House format is table-driven swift-testing: one `Sendable` row struct per
  table, driven by `@Test(arguments:)`. See
  `Tests/MatrixKitTests/AuthComplianceTests.swift` (the reference suite).
- Component behavior tests run against the in-process spec harness in
  `Tests/Support/` (`Harness` + `HarnessWorld` + `HarnessServer`), never
  against `https://example.com` no-ops. Wrap tests in `withHarness`, which
  asserts zero spec violations and shuts down transports on every path.
- Every harness request is validated against the pinned-spec registry
  (`SpecEndpoint` / `SpecRegistry`). Regenerate with
  `python3 Tools/spec-registry/gen_spec_registry.py`; the pin lives in
  `Tools/spec-registry/SPEC_VERSION`. CI enforces `--check`.
- Shared fakes, builders, and DTO helpers live in `MatrixKitTesting` —
  do not add per-file private duplicates.
- Coverage gate: `bash Tools/coverage.sh --min N` (per-library-target line
  coverage, `Tests/Support` and `mx` excluded). Baseline and ratchet
  target in `Tools/coverage-baseline.json`.
- Never use polling sleeps in tests; use `waitUntil` from
  `MatrixKitTesting`, and prefer completion-gated synchronization where
  the SDK exposes it.
- Tables in `@MainActor` suites must be `nonisolated static` — argument
  evaluation happens off-actor.
- Never use multi-pattern `case` with a single `where` in the harness
  router (`case "GET", "PUT" where …` gates only the LAST pattern —
  the compiler warns, the first patterns match unconditionally).
  Prefer `if`-`let` chains for route matching.

# Swift Guidelines
- `@Observable` classes must be marked `@MainActor` unless the project has Main Actor default actor isolation. Flag any `@Observable` class missing this annotation.
- All shared data should use `@Observable` classes with `@State` (for ownership) and `@Bindable` / `@Environment` (for passing).
- Strongly prefer not to use `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject` unless they are unavoidable, or if they exist in legacy/integration contexts when changing architecture would be complicated.
- Assume strict Swift concurrency rules are being applied.
- Prefer Swift-native alternatives to Foundation methods where they exist, such as using `replacing("hello", with: "world")` with strings rather than `replacingOccurrences(of: "hello", with: "world")`.
- Prefer modern Foundation API, for example `URL.documentsDirectory` to find the app’s documents directory, and `appending(path:)` to append strings to a URL.
- Never use C-style number formatting such as `Text(String(format: "%.2f", abs(myNumber)))`; always use `Text(abs(change), format: .number.precision(.fractionLength(2)))` instead.
- Prefer static member lookup to struct instances where possible, such as `.circle` rather than `Circle()`, and `.borderedProminent` rather than `BorderedProminentButtonStyle()`.
- Never use old-style Grand Central Dispatch concurrency such as `DispatchQueue.main.async()`. If behavior like this is needed, always use modern Swift concurrency.
- Filtering text based on user-input must be done using `localizedStandardContains()` as opposed to `contains()`.
- Avoid force unwraps and force `try` unless it is unrecoverable.
- Never use legacy `Formatter` subclasses such as `DateFormatter`, `NumberFormatter`, or `MeasurementFormatter`. Always use the modern `FormatStyle` API instead. For example, to format a date, use `myDate.formatted(date: .abbreviated, time: .shortened)`. To parse a date from a string, use `Date(inputString, strategy: .iso8601)`. For numbers, use `myNumber.formatted(.number)` or custom format styles.
