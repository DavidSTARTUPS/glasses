# Stream Live Media from AIBuds: public integration reference

## Scope and public contracts

Use this reference to start and stop supported RTSP or JPEG live streams. Confirm exact declarations in the installed SDK version before editing the consumer app.

- `LiveStreamingAPI`
- `supportsRTSPLiveStreaming`
- `supportsJPEGImageLiveStreaming`
- `startRTSPLiveStreaming`
- `startJPEGImageLiveStreaming`
- `stopLiveStreaming`

## Official documentation

- [docs/core/live-streaming/rtsp ](https://docs-aibuds.github.io/docs/core/live-streaming/rtsp)
- [docs/core/live-streaming/jpeg ](https://docs-aibuds.github.io/docs/core/live-streaming/jpeg)
- [docs/core/live-streaming/stop ](https://docs-aibuds.github.io/docs/core/live-streaming/stop)
- [AIBuds SDK API Reference](https://docs-aibuds.github.io/api-reference/aibuds-sdk)
- [Common troubleshooting](https://docs-aibuds.github.io/docs/troubleshooting/common-issues)


## Portable workflow

1. Initialize only the documented module needed for this feature.
2. Wait for the public ready callback and cast the selected `DeviceConvertible` to `LiveStreamingAPI` safely.
3. Validate user input and public capability/range information before calling the SDK.
4. Serialize mutually exclusive operations and keep callback/session owners alive for as long as the public contract requires.
5. Treat callback success and error as the operation result. Move UI work to the main queue and use public connection callbacks as the source of truth.
6. On cancellation, view exit, background transition, or disconnect, stop only through a documented stop/cancel API and clear application-owned state.

## Swift pattern

Adapt names such as `device`, handlers, models, and UI functions to the consumer app. Do not copy repository-specific helpers.

```swift
guard device.isConnectedAndReady else { return }
// guard let featureDevice = device as? LiveStreamingAPI else { return }

guard streamDevice.supportsRTSPLiveStreaming else { return }
streamDevice.startRTSPLiveStreaming(withParams: params, /* documented phase and session handlers */)
// Always pair a successful start with stopLiveStreaming().
```

## Objective-C pattern

Use the Objective-C names exposed by the installed generated interface; availability and nullability remain authoritative.

```objective-c
if (!device.isConnectedAndReady) { return; }
// Check conformsToProtocol: before casting to the public protocol.

if (!streamDevice.supportsRTSPLiveStreaming) { return; }
[streamDevice startRTSPLiveStreamingWithParams:params /* documented phase and session handlers */];
// Always pair a successful start with stopLiveStreaming.
```

## Error and lifecycle rules

- Do not force-cast optional capabilities or assume a callback queue.
- Prevent repeated submissions while an operation is in flight.
- Dispatch presentation/state mutations to the main queue.
- Show `localizedDescription` when a public error exists and a stable fallback otherwise.
- Do not guess device state after a command; reconcile it through public properties and callbacks.
- Keep credentials, private endpoints, and app-owned AI/network implementations outside SDK calls.

## Verification matrix

| Case | Expected check |
|---|---|
| Device or service unavailable | Reject cleanly without calling an unsupported API. |
| Success | Update UI on the main queue and refresh public state when relevant. |
| Failure with error | Present the public localized error without internal interpretation. |
| Failure without error | Present a stable application-owned fallback message. |
| Repeated action | Keep at most one incompatible request/session in flight. |
| Disconnect or lifecycle exit | Cancel/stop through public API when available and clear app state. |
| The selected transport is publicly reported as supported. | Confirm the app behaves deterministically and reports public errors safely. |
| Frames are processed off the main thread; UI updates return to it. | Confirm the app behaves deterministically and reports public errors safely. |
| Stop runs on exit, failure, and disconnect. | Confirm the app behaves deterministically and reports public errors safely. |

## Information boundary

Explain what the public call accepts, what its public callback reports, and how the app should react. Do not describe transport details, command encoding, SDK source structure, private dependencies, or internal execution paths.
