//! Phase 3 shared transport definitions (PROTOCOL.md Section 11).
//!
//! The Gringots frame is identical on every transport; only the
//! encapsulation changes. Wi-Fi, Wi-Fi Direct (after OS group formation)
//! and Zinux/mesh IP links all carry frames as UDP datagrams. BLE carries
//! them as fragmented advertisement payloads. LoRa/audio arrive in later
//! phases with their own codecs under this same scheme.

pub const DEFAULT_PORT: u16 = 4848;

/// Largest Gringots frame on the wire (5 + 512 + 4).
pub const MAX_FRAME: usize = 521;

pub const Kind = enum {
    udp_broadcast,
    ble_adv,
    mesh,
    loopback,
};

/// Per-transport payload limits (bytes).
pub const mtu = struct {
    /// UDP datagram payload ceiling we emit (well under 1500 B Ethernet).
    pub const udp_payload: usize = 1400;
    /// BLE advertisement chunk ceiling (spec: <=180 B with prefix).
    pub const ble_chunk: usize = 180;
    /// Usable frame bytes per BLE chunk (chunk minus chunk header).
    pub const ble_payload: usize = ble_chunk - chunk_header_len;
    /// Mesh envelope overhead (magic + TTL).
    pub const mesh_overhead: usize = 2;
};

/// BLE chunk header (concrete form of the PROTOCOL.md "chunk_idx/total
/// prefix"). Chunk layout, total <= 180 B:
///   [0]    CHUNK_MAGIC 'G'
///   [1]    total chunks (1..8)
///   [2]    chunk index (0-based)
///   [3..19] frame NONCE (16 B, reassembly key)
///   [19..]  frame payload
pub const chunk_magic: u8 = 0x47;
pub const chunk_header_len: usize = 19;
pub const max_chunks: u8 = 8;

/// Mesh envelope: [MAGIC 'M'][TTL] ++ frame. TTL 1..MAX_TTL.
pub const mesh_magic: u8 = 0x4D;
pub const max_ttl: u8 = 8;

/// BLE manufacturer company ID. 0xFFFF = reserved-for-development;
/// replace with an allocated ID before production hardware.
pub const company_id: u16 = 0xFFFF;

const std = @import("std");

test "mtu budget fits max frame everywhere" {
    try std.testing.expect(mtu.ble_payload * max_chunks >= MAX_FRAME);
    try std.testing.expect(mtu.udp_payload >= MAX_FRAME + mtu.mesh_overhead);
    try std.testing.expect(chunk_header_len + mtu.ble_payload == mtu.ble_chunk);
}
