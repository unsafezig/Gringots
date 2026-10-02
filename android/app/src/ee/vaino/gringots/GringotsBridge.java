package ee.vaino.gringots;

/**
 * JNI binding to libgringots.so (see src/jni.zig).
 *
 * The native side owns protocol bytes and cryptography; Android owns
 * radios, UI, consent and lifecycle (HOST_CAPABILITIES.md). All calls
 * are synchronous and buffer-based.
 */
public final class GringotsBridge {
    static {
        System.loadLibrary("gringots");
    }

    private GringotsBridge() {}

    /** Protocol version implemented by the native library. */
    public static native int version();

    /**
     * Build a signed CIVILIAN_SOS frame. Returns the frame bytes, or
     * null on failure. timestamp/expires are unix seconds.
     */
    public static native byte[] makeSos(byte[] seed32, long timestamp, long expires, byte[] nonce16);

    /** Verify a received frame at time now. 0 = valid, 1 = invalid. */
    public static native int verifyFrame(byte[] frame, long now);

    /**
     * Debug text form of a frame (unverified, structure only).
     * Returns the text bytes, or null on failure.
     */
    public static native byte[] describeFrame(byte[] frame);

    /**
     * Wrap an SOS frame in a GUEST_SOS_SEND host-protocol datagram
     * (test-only live loop). Returns the datagram bytes, or null on failure.
     */
    public static native byte[] wrapSos(byte[] sos);

    /**
     * Unwrap a HOST_FRAME_DELIVER datagram to the raw Gringots frame.
     * Returns null for HOST_ERROR or anything else ("no acknowledgement").
     */
    public static native byte[] unwrapDeliver(byte[] datagram);
}
