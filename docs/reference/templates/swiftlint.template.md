<!--
SwiftLint configuration template.

Copy the block below to `.swiftlint.yml` at repo root.
This config matches the conventions in `docs/code-style.md` and includes custom rules
that enforce structured logging, typed errors, and "no print / no fatalError".
-->

# SwiftLint configuration

A reference `.swiftlint.yml` for projects following [`docs/code-style.md`](../code-style.md), with custom rules that enforce the patterns under [`docs/reference/patterns/`](../patterns/).

Copy to `.swiftlint.yml` at repo root:

```yaml
# ─── Paths ──────────────────────────────────────────────────────────────────
included:
  - src
  - tests

excluded:
  - .build
  - Build
  - Vendored
  - src/CodemixerApp/Codemixer.xcodeproj
  - "**/*.generated.swift"
  - "**/Pods"

# ─── Built-in rules ─────────────────────────────────────────────────────────

disabled_rules:
  - todo                           # we track TODOs in issues; comments are fine
  - line_length                    # SwiftFormat handles this
  - identifier_name                # we use our own custom_identifier_name (below)
  - opening_brace                  # SwiftFormat handles
  - trailing_comma                 # SwiftFormat handles
  - trailing_newline               # SwiftFormat handles
  - vertical_whitespace            # SwiftFormat handles

opt_in_rules:
  - anonymous_argument_in_multiline_closure
  - array_init
  - attributes
  - closure_body_length
  - closure_end_indentation
  - closure_spacing
  - collection_alignment
  - contains_over_filter_count
  - contains_over_filter_is_empty
  - contains_over_first_not_nil
  - contains_over_range_nil_comparison
  - convenience_type
  - discouraged_assert
  - discouraged_optional_boolean
  - discouraged_optional_collection
  - empty_collection_literal
  - empty_count
  - empty_string
  - enum_case_associated_values_count
  - explicit_init
  - extension_access_modifier
  - fallthrough
  - fatal_error_message
  - file_header
  - file_name
  - file_name_no_space
  - first_where
  - flatmap_over_map_reduce
  - force_unwrapping
  - function_default_parameter_at_end
  - identical_operands
  - implicit_return
  - implicitly_unwrapped_optional
  - joined_default_parameter
  - last_where
  - legacy_multiple
  - legacy_objc_type
  - literal_expression_end_indentation
  - lower_acl_than_parent
  - missing_docs
  - modifier_order
  - multiline_arguments
  - multiline_function_chains
  - multiline_literal_brackets
  - multiline_parameters
  - nimble_operator
  - nslocalizedstring_key
  - operator_usage_whitespace
  - optional_enum_case_matching
  - overridden_super_call
  - pattern_matching_keywords
  - prefer_self_in_static_references
  - prefer_self_type_over_type_of_self
  - prefer_zero_over_explicit_init
  - private_action
  - private_outlet
  - private_subject
  - prohibited_super_call
  - redundant_nil_coalescing
  - redundant_type_annotation
  - return_value_from_void_function
  - single_test_class
  - sorted_first_last
  - static_operator
  - strict_fileprivate
  - test_case_accessibility
  - toggle_bool
  - trailing_closure
  - unavailable_function
  - unneeded_parentheses_in_closure_argument
  - unowned_variable_capture
  - untyped_error_in_catch
  - unused_declaration
  - vertical_parameter_alignment_on_call
  - vertical_whitespace_closing_braces
  - vertical_whitespace_opening_braces
  - weak_delegate
  - yoda_condition

# ─── Built-in rule configuration ────────────────────────────────────────────

function_body_length:
  warning: 60
  error: 120

type_body_length:
  warning: 300
  error: 600

file_length:
  warning: 500
  error: 1000
  ignore_comment_only_lines: true

cyclomatic_complexity:
  warning: 10
  error: 20

nesting:
  type_level:
    warning: 2
  function_level:
    warning: 3

force_cast: error
force_try: error
force_unwrapping: error

missing_docs:
  excludes_extensions: true
  excludes_inherited_types: true
  warning:
    - open
    - public

file_header:
  required_pattern: ''            # empty means "no header required"; project-overridden if needed

# ─── Custom rules ───────────────────────────────────────────────────────────
# These enforce conventions from `docs/code-style.md` and `docs/reference/patterns/`.

custom_rules:

  no_print:
    name: "No print()"
    regex: "(?<!Swift\\.)\\bprint\\s*\\("
    message: "Use Logger (see structured-logging-with-privacy pattern), not print()."
    severity: error
    excluded:
      - "tests/.*"
      - ".*\\.docc/.*"

  no_naked_fatalerror:
    name: "No naked fatalError"
    regex: "(?<!Logger\\.)\\bfatalError\\s*\\("
    message: "Use Logger.fatal(...) so the fatality is logged with structured context."
    severity: error
    excluded:
      - "tests/.*"

  no_implicit_print_via_dump:
    name: "No dump()"
    regex: "\\bdump\\s*\\("
    message: "dump() outputs to stdout; use Logger and explicit interpolation."
    severity: error
    excluded:
      - "tests/.*"

  logger_privacy_required:
    name: "Logger interpolation must specify privacy"
    regex: "Logger.*?\\.(?:debug|info|notice|error|fault|warning|trace)\\([^)]*?\\\\\\([^,)]+\\)"
    message: "Every Logger interpolation must specify a privacy: tag. See structured-logging-with-privacy pattern."
    severity: warning
    excluded:
      - "tests/.*"

  no_nserror_throw:
    name: "No NSError throw"
    regex: "throw\\s+NSError\\s*\\("
    message: "Define a typed Error enum (see typed-errors-and-wire pattern) instead of throwing NSError."
    severity: error
    excluded:
      - "tests/.*"

  no_unchecked_sendable:
    name: "@unchecked Sendable requires justification"
    regex: "@unchecked\\s+Sendable"
    message: "@unchecked Sendable requires a // SAFETY: comment on the same or preceding line. See strict-concurrency-layout pattern."
    severity: warning
    match_kinds:
      - keyword
      - typeidentifier

  no_main_actor_on_engine:
    name: "Engine modules must not use @MainActor"
    regex: "@MainActor"
    message: "Engine code must remain decoupled from the UI thread. Use actor isolation instead."
    severity: error
    included:
      - "src/Core/AgentCore/.*\\.swift"
      - "src/AgenticCLIs/.*\\.swift"
      - "src/Remote/AgentRemoteControl/.*\\.swift"

  no_random_in_engine:
    name: "Engine modules must use RandomSource seam"
    regex: "(Int|UInt|Double|UUID)\\.random|arc4random|drand48|SecRandomCopyBytes"
    message: "Use RandomSource via dependency injection (see dependency-injection-seams pattern)."
    severity: warning
    included:
      - "src/Core/AgentCore/.*\\.swift"

  no_clock_now_in_engine:
    name: "Engine modules must use Clock seam"
    regex: "Date\\(\\)|Date\\.now|ContinuousClock\\(\\)\\.now"
    message: "Use AgentClock via dependency injection (see dependency-injection-seams pattern)."
    severity: warning
    included:
      - "src/Core/AgentCore/.*\\.swift"
      - "src/AgenticCLIs/.*\\.swift"
    excluded:
      - "src/Core/AgentCore/Seams/.*\\.swift"

  no_processinfo_in_engine:
    name: "Engine modules must use Environment seam"
    regex: "ProcessInfo\\.processInfo\\.environment"
    message: "Use Environment via dependency injection (see dependency-injection-seams pattern)."
    severity: warning
    included:
      - "src/Core/AgentCore/.*\\.swift"
      - "src/AgenticCLIs/.*\\.swift"
    excluded:
      - "src/Core/AgentCore/Seams/.*\\.swift"

  ipc_uses_actor:
    name: "IPC clients must be actors"
    regex: "class\\s+\\w*Client\\b"
    message: "Use an actor for per-client lifecycle (see ipc-server-listener pattern)."
    severity: warning
    included:
      - "src/Core/AgentCore/Hooks/.*\\.swift"

  no_hardcoded_color:
    name: "No hardcoded colours"
    regex: "Color\\(\\s*(red|green|blue):"
    message: "Use Theme tokens (see visual-style.md). Hardcoded RGB values bypass theming."
    severity: error
    included:
      - "src/AgentUI/.*\\.swift"

  no_hardcoded_font:
    name: "No hardcoded font sizes"
    regex: "\\.font\\(\\.system\\(size:\\s*\\d+"
    message: "Use Theme.Type tokens (see visual-style.md)."
    severity: error
    included:
      - "src/AgentUI/.*\\.swift"

  conventional_acronym_casing:
    name: "Acronyms keep their case"
    regex: "\\b(Url|Uri|Json|Http|Https|Pty|Xml|Tcp|Udp|Sql|Ui|Api|Id)\\b"
    message: "Acronyms keep their case: URL/URI/JSON/HTTP/PTY/XML/TCP/UDP/SQL/UI/API/ID."
    severity: error

# ─── Reporter ───────────────────────────────────────────────────────────────
reporter: "xcode"
strict: false                      # local runs warn; CI passes --strict
```

## Custom rule rationale

| Rule | Pattern it enforces |
| --- | --- |
| `no_print` | [structured-logging-with-privacy](../patterns/structured-logging-with-privacy.md) |
| `no_naked_fatalerror` | [structured-logging-with-privacy](../patterns/structured-logging-with-privacy.md) — `Logger.fatal` shim |
| `logger_privacy_required` | [structured-logging-with-privacy](../patterns/structured-logging-with-privacy.md) — privacy levels |
| `no_nserror_throw` | [typed-errors-and-wire](../patterns/typed-errors-and-wire.md) |
| `no_unchecked_sendable` | [strict-concurrency-layout](../patterns/strict-concurrency-layout.md) |
| `no_main_actor_on_engine` | [headless-remote-duality](../patterns/headless-remote-duality.md) — engine stays headless-friendly |
| `no_random_in_engine` / `no_clock_now_in_engine` / `no_processinfo_in_engine` | [dependency-injection-seams](../patterns/dependency-injection-seams.md) |
| `ipc_uses_actor` | [ipc-server-listener](../patterns/ipc-server-listener.md) |
| `no_hardcoded_color` / `no_hardcoded_font` | [visual-style.md](../../visual-style.md) — `Theme` as single source of truth |
| `conventional_acronym_casing` | [`docs/code-style.md`](../../code-style.md) — naming conventions |

## CI vs local

- **Local:** `strict: false` so the team can iterate without every warning being a hard fail.
- **CI:** `swiftlint lint --strict` — warnings become errors. See [`ci-workflow.template.md`](ci-workflow.template.md).

## Adding new rules

When you propose a new custom rule:

1. Reference the pattern doc the rule enforces.
2. List the `included:` / `excluded:` paths explicitly.
3. Start with `severity: warning` for one release cycle, then promote to `error`.
4. Add an entry to the rule-rationale table above.
