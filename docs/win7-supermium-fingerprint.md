# Win7 Supermium fingerprint capability

Win7 uses Supermium as a Chromium runtime and Windows 7 compatibility layer. It
is not treated as a fingerprint-spoofing fork. Simprint owns the environment
profile and the `SupermiumAdapter` owns the translation into runtime controls.

## Current capability boundary

Applied through command line: user agent, language, window size, proxy, startup
URLs, extensions and WebRTC policy. Applied through CDP: cookies, tabs, window
bounds, timezone and geolocation. UA Client Hints are best-effort because the
stock binary does not expose a complete native override surface.

The runtime explicitly reports Canvas, WebGL vendor/renderer/image,
AudioContext, ClientRects, font enumeration, media devices and WebGPU as
unsupported. These are not silently discarded or presented as successfully
spoofed.

## Native patch requirements

Future native work belongs in a maintained Supermium/Chromium fork and should
cover Blink Navigator and Screen surfaces, UA Client Hints, WebGL rendering and
readback, Canvas serialization, AudioContext, MediaDevices, font and speech
enumeration, WebGPU, hardware values and cross-surface consistency.

All values must be derived from one consistent environment profile. Randomizing
individual surfaces independently is explicitly out of scope.
