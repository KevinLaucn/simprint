//! Browser adapter boundary for runtime-specific launch and control.
//!
//! The Win7 build uses stock/near-stock Supermium.  Capabilities declared here
//! are intentionally conservative: a value is not reported as applied unless
//! this runtime can actually enforce it.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FingerprintCapability {
    Native,
    Cdp,
    CommandLine,
    Extension,
    BestEffort,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserAdapterKind {
    EventBusChromium,
    SupermiumWin7,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapabilityStatus {
    pub name: &'static str,
    pub capability: FingerprintCapability,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SupermiumAdapter;

impl SupermiumAdapter {
    pub const KIND: BrowserAdapterKind = BrowserAdapterKind::SupermiumWin7;

    /// Conservative capability matrix for the stock Supermium binary.
    /// Deep fingerprint spoofing requires a maintained Chromium source fork.
    pub fn capabilities() -> &'static [CapabilityStatus] {
        &[
            CapabilityStatus { name: "user_agent", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "language", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "window_size", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "proxy", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "startup_urls", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "extensions", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "cookies", capability: FingerprintCapability::Cdp },
            CapabilityStatus { name: "tabs", capability: FingerprintCapability::Cdp },
            CapabilityStatus { name: "window_bounds", capability: FingerprintCapability::Cdp },
            CapabilityStatus { name: "timezone", capability: FingerprintCapability::Cdp },
            CapabilityStatus { name: "geolocation", capability: FingerprintCapability::Cdp },
            CapabilityStatus { name: "webrtc_policy", capability: FingerprintCapability::CommandLine },
            CapabilityStatus { name: "canvas", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "webgl_vendor", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "webgl_renderer", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "webgl_image", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "audio_context", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "client_rects", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "font_list", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "media_devices", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "webgpu", capability: FingerprintCapability::Unsupported },
            CapabilityStatus { name: "ua_client_hints", capability: FingerprintCapability::BestEffort },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::{FingerprintCapability, SupermiumAdapter};

    #[test]
    fn stock_supermium_does_not_claim_native_deep_spoofing() {
        for capability in SupermiumAdapter::capabilities() {
            if matches!(
                capability.name,
                "canvas" | "webgl_vendor" | "webgl_renderer" | "audio_context" | "font_list"
            ) {
                assert_eq!(capability.capability, FingerprintCapability::Unsupported);
            }
        }
    }
}
