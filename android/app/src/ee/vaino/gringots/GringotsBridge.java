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
}
