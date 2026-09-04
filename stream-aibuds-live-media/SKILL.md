---
name: stream-aibuds-live-media
description: Help an iOS developer start and stop supported RTSP or JPEG live streams using documented AIBuds public APIs. Use for implementation, explanation, review, or troubleshooting in Swift or Objective-C without exposing SDK internals.
---

# Stream Live Media from AIBuds

Build or explain this feature through the public SDK contract and the application's existing architecture.


## Workflow

1. Read `references/implementation.md` completely.
2. Determine whether the consumer app uses Swift or Objective-C and preserve its existing state, dependency, callback, and UI architecture.
3. Confirm SDK initialization, a selected device, `isConnectedAndReady`, and each required public protocol capability before exposing the feature. For SDK-level services, confirm that their documented module is installed and initialized instead.
4. Use the linked official guide and the installed SDK's public interface as the authority for names, parameters, nullability, and availability. If they differ, explain the version mismatch and adapt only to the installed public contract.
5. Implement the smallest requested workflow, including main-thread UI handoff, duplicate-request prevention, nullable-error fallback, disconnect/cancellation cleanup, and observable success criteria.
6. Give code in the developer's requested language. If no language is stated, provide both Swift and Objective-C.
7. Verify the applicable cases in the reference matrix and report assumptions separately from documented behavior.

## Non-disclosure boundary

- Use only public modules, types, protocols, methods, properties, callbacks, and official documentation.
- Do not reveal or infer private classes, source layout, transport commands, packet formats, authentication algorithms, private errors, logs, or internal call chains.
- Do not reproduce SDK source, inspect binary internals, decompile, or explain how a public API works behind its contract.
- If asked for internals, decline that portion briefly and answer with the nearest public API, callback, configuration, or diagnostic step.
- Never place secrets, production credentials, private endpoints, or real device identifiers in examples.

## Completion criteria

- The integration uses only documented public contracts and cites the most relevant official page.
- Swift and Objective-C guidance are both available and behaviorally equivalent.
- Capability, readiness, callback, threading, retry, error, cancellation, and lifecycle behavior are addressed where applicable.
- The result contains no hidden implementation claim and is portable outside this repository.
