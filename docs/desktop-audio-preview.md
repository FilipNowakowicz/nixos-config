# Audio device switching preview

Switching outputs and microphones now shows progress and confirms the effective
default device. Rejected or unconfirmed writes expose Retry. Rapid selection
changes retain the latest intent, while keyboard focus survives device-list updates.
The pickers display readable descriptions and Active/Switch state instead of numeric
PipeWire IDs. Video devices are excluded; virtual audio sources remain available.

Selection targets PipeWire node.name. Immediately before writing, the backend
checks that exactly one present audio node has that name and the expected media
class. It writes a JSON configured preference through pw-metadata; subsequent
fresh polling must observe that name as the effective default before confirmation.
A reused numeric ID cannot redirect a stale request. Missing/ambiguous devices
cannot confirm it. Disappearance after preflight may leave an absent preference;
this is reported as unconfirmed rather than success. There is no automatic retry
of an uncertain write.

The native PipeWire CLI is a declared package runtime dependency. Read failures
leave no selectable numeric-ID fallback. Volume/mute controls keep their existing
semantics. The existing policy hides inactive HDMI/monitor outputs.

Validation includes parser/media-boundary regressions, device removal and ID reuse,
duplicate names, wrong media classes, stale readback, rejected writes and timeouts.
A separate local trial ran the production writer against isolated PipeWire and
WirePlumber policy with three synthetic nodes and zero hardware devices. Private
GTK pointer trials cover both output and input selection, Retry, late reconciliation
and rapid reversals, including reduced motion. These establish state and input
correctness; they do not establish physical audio quality or frame pacing.

This is a source-only draft, stacked on the interaction reliability preview. It
adds no shortcuts and performs no activation. Live audio/EasyEffects integration,
multi-monitor use and existing-stream routing still require acceptance. Changing
the default does not promise that every existing application's stream moves.

See [PipeWire metadata](https://pipewire.pages.freedesktop.org/pipewire/page_man_pw-metadata_1.html)
and [WirePlumber defaults](https://pipewire.pages.freedesktop.org/wireplumber/man/wpctl.html).
