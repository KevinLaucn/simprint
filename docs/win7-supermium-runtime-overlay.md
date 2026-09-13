# Win7 Supermium runtime overlay

This build-only overlay adapts stock Supermium to Simprint's runtime without requiring the custom Chromium EventBus patch.

Applied by `scripts/before-build-win7.ps1` during the Win7 workflow.

Current Win7 adapter responsibilities:

- Pass fixed proxy configuration to Supermium through Chromium `--proxy-server` / `--proxy-bypass-list` flags.
- Add a generated Manifest V3 proxy authentication extension when HTTP proxy credentials are present.
- Pass configured startup URLs directly to stock Supermium.
- Stop Supermium through the Windows Job Object when EventBus is unavailable.
- Clean runtime status/CDP state when the browser process exits without an EventBus disconnect event.
- Treat CDP-managed environments as connected environments.
- Use the DevTools HTTP endpoints for tab listing, activation, and closing when EventBus is unavailable.

Known stock-Supermium limitations that are intentionally not hidden:

- Runtime proxy hot-switch is not supported by Chromium launch flags; restart the environment to apply a changed proxy.
- Custom fingerprint features that depended on Simprint's patched Chromium EventBus remain separate work and must not be reported as active unless they have a stock-Supermium implementation.
