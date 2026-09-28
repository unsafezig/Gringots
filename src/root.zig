//! Gringots library root: re-exports + test aggregator.

pub const types = @import("protocol/types.zig");
pub const frame = @import("protocol/frame.zig");
pub const msg = @import("protocol/msg.zig");
pub const crypto_ = @import("crypto/ed25519.zig");
pub const identity = @import("identity/ephemeral.zig");
pub const replay = @import("replay/cache.zig");
pub const session = @import("location/session.zig");
pub const transport = @import("transports/transport.zig");
pub const ble = @import("transports/ble.zig");
pub const udp = @import("transports/udp.zig");
pub const mesh = @import("transports/mesh.zig");
pub const rs = @import("audio/rs.zig");
pub const fsk = @import("audio/fsk.zig");
pub const apacket = @import("audio/packet.zig");
pub const wav = @import("audio/wav.zig");
pub const duty = @import("agent/duty.zig");
pub const consent = @import("agent/consent.zig");
pub const alocation = @import("agent/location.zig");
pub const service = @import("agent/service.zig");

test {
    _ = @import("protocol/types.zig");
    _ = @import("protocol/frame.zig");
    _ = @import("protocol/msg.zig");
    _ = @import("crypto/ed25519.zig");
    _ = @import("identity/ephemeral.zig");
    _ = @import("replay/cache.zig");
    _ = @import("location/session.zig");
    _ = @import("transports/transport.zig");
    _ = @import("transports/ble.zig");
    _ = @import("transports/udp.zig");
    _ = @import("transports/mesh.zig");
    _ = @import("audio/rs.zig");
    _ = @import("audio/fsk.zig");
    _ = @import("audio/packet.zig");
    _ = @import("audio/wav.zig");
    _ = @import("agent/duty.zig");
    _ = @import("agent/consent.zig");
    _ = @import("agent/location.zig");
    _ = @import("agent/service.zig");
}
