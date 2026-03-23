# macOS: RunLoop (CFRunLoop / NSRunLoop)

GUI applications are event-driven: every state mutation traces back to a root event dispatched by the platform's event loop. When analyzing state mutations, trace backward through all paths — including reactive bindings — until you reach a root event source. A callback registered in application code can fire from a root event without any application-level caller.

## Root Event Sources

| Source Type | Mechanism | Examples |
|-------------|-----------|----------|
| **User events** | HIToolbox → NSApplication → NSEvent | Mouse clicks, key presses, scroll wheel, trackpad gestures |
| **Timer events** | CFRunLoopTimer / NSTimer / DispatchSourceTimer | Scheduled callbacks, animation timers, polling intervals |
| **Source0 (application-signaled)** | CFRunLoopSource / performSelector:onThread: | Cross-thread dispatch, manual source signaling |
| **Source1 (mach port)** | Mach port messages via kernel IPC | System notifications, IOKit device events, WindowServer events |
| **Display sync** | CVDisplayLink / CADisplayLink | Frame rendering callbacks, display refresh |
| **GCD / libdispatch** | DispatchQueue, DispatchSource | Network I/O readiness, file descriptor events, signal handling |
| **Network events** | NWConnection / URLSession / CFSocket | Socket data available, connection state change, TLS handshake complete |

## How Framework Callbacks Enter Application Code

When a network connection closes (peer disconnects, TCP timeout, process death), the sequence is:

1. The kernel detects the socket close and posts a kevent
2. libdispatch picks up the kevent on its network monitoring queue
3. The framework (URLSession / NWConnection / WebSocket library) processes the event
4. The framework calls the application's registered callback/delegate on the appropriate queue
5. The callback mutates application state

The application never initiates this call. The RunLoop (or GCD queue) dispatches it in response to an external event. In a function trace, this callback appears as a CALL with no application-level caller — its caller is the framework's internal dispatch mechanism.

## Implication for Causal Analysis

A callback that fires during a traced session as a downstream effect of an explicit application call (e.g., `disconnect()` → `onStateChange`) can ALSO fire independently from a root event (e.g., network socket closes → `onStateChange`). The trace only shows what happened — the explicit call may have preempted the environmental trigger. Blocking the explicit call path does NOT make the callback unreachable.
