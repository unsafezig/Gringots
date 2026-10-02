package ee.vaino.gringots;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.security.SecureRandom;
import java.util.Arrays;

/**
 * Phase 5 debug console: start / stop / status controls wired to real
 * native calls. Start runs a deterministic self-test (mint SOS, verify
 * it, verify expiry rejection, negative corrupt/truncated/empty/oversize
 * cases, describe text) and reports each step; stop returns to idle. The
 * ARM64 Zinux guest VM host attaches behind this console in
 * the next slice (HOST_CAPABILITIES.md lifecycle).
 */
public class MainActivity extends Activity {
    private TextView status;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);

        status = new TextView(this);
        status.setText("Gringots idle.");
        status.setTextSize(16);
        root.addView(status);

        Button start = new Button(this);
        start.setText("Start");
        start.setOnClickListener(v -> runSelfTest());
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("Stop");
        stop.setOnClickListener(v -> status.setText("Gringots idle."));
        root.addView(stop);

        setContentView(root);

        // Headless/self-test entry: `am start --ez selftest true` runs the
        // native self-test immediately (logcat tag Gringots).
        if (getIntent() != null && getIntent().getBooleanExtra("selftest", false)) {
            status.post(this::runSelfTest);
        }
        // Headless live-loop entry: `am start --ez udptest true` mints an SOS
        // with wall-clock time, sends it via UDP to the desktop receiver
        // (defaults 10.0.2.2:48483, extras udphost/udpport), verifies the
        // ACK, then replays the datagram and expects no second ACK.
        // Network runs on a worker thread (never the UI thread).
        if (getIntent() != null && getIntent().getBooleanExtra("udptest", false)) {
            String host = getIntent().getStringExtra("udphost");
            int port = getIntent().getIntExtra("udpport", 48483);
            runLiveLoop(host != null ? host : "10.0.2.2", port);
        }
    }

    private void runSelfTest() {
        StringBuilder sb = new StringBuilder();
        try {
            int ver = GringotsBridge.version();
            sb.append("native lib version=").append(ver).append('\n');
            if (ver != 1) {
                status.setText(sb.toString() + "FAIL: version");
                return;
            }
            byte[] seed = new byte[32];
            Arrays.fill(seed, (byte) 0xE0);
            byte[] nonce = new byte[16];
            Arrays.fill(nonce, (byte) 0xF1);
            long t0 = 1798675200L;
            byte[] sos = GringotsBridge.makeSos(seed, t0, t0 + 600, nonce);
            if (sos == null) {
                status.setText(sb.toString() + "FAIL: makeSos");
                return;
            }
            sb.append("sos bytes=").append(sos.length).append('\n');
            int ok = GringotsBridge.verifyFrame(sos, t0);
            sb.append("verify(valid)=").append(ok).append('\n');
            int expired = GringotsBridge.verifyFrame(sos, t0 + 901);
            sb.append("verify(expired)=").append(expired).append('\n');
            // Negative cases: corrupted signature, truncated, empty, oversize.
            byte[] bad = sos.clone();
            bad[bad.length - 1] ^= 0x01;
            int badsig = GringotsBridge.verifyFrame(bad, t0);
            sb.append("verify(badsig)=").append(badsig).append('\n');
            int trunc = GringotsBridge.verifyFrame(Arrays.copyOf(sos, sos.length / 2), t0);
            sb.append("verify(trunc)=").append(trunc).append('\n');
            int empty = GringotsBridge.verifyFrame(new byte[0], t0);
            sb.append("verify(empty)=").append(empty).append('\n');
            int big = GringotsBridge.verifyFrame(new byte[1025], t0);
            sb.append("verify(big)=").append(big).append('\n');
            // Describe: structure-only text of the valid frame, null on garbage.
            byte[] desc = GringotsBridge.describeFrame(sos);
            String descStr = (desc == null) ? null : new String(desc);
            sb.append("describe=").append(descStr == null ? "null"
                    : descStr.substring(0, Math.min(30, descStr.length()))).append('\n');
            byte[] baddesc = GringotsBridge.describeFrame(new byte[]{0x01, 0x02, 0x03});
            sb.append("describe(bad)=").append(baddesc == null ? "null" : "non-null").append('\n');
            if (ok == 0 && expired == 1 && badsig == 1 && trunc == 1 && empty == 1 && big == 1
                    && baddesc == null && descStr != null
                    && descStr.startsWith("GRINGOTTS/1 TYPE=CIVILIAN_SOS")) {
                sb.append("Gringots service ready.");
            } else {
                sb.append("FAIL: verdicts");
            }
        } catch (UnsatisfiedLinkError e) {
            sb.append("FAIL: native lib missing: ").append(e.getMessage());
        }
        status.setText(sb.toString());
        Log.i("Gringots", "selftest result: " + sb.toString().replace('\n', ';'));
    }

    private void runLiveLoop(String host, int port) {
        new Thread(() -> {
            StringBuilder sb = new StringBuilder();
            DatagramSocket sock = null;
            try {
                SecureRandom sr = new SecureRandom();
                byte[] seed = new byte[32];
                sr.nextBytes(seed);
                byte[] nonce = new byte[16];
                sr.nextBytes(nonce);
                long now = System.currentTimeMillis() / 1000L;
                byte[] sos = GringotsBridge.makeSos(seed, now, now + 600, nonce);
                if (sos == null) {
                    finishLive(sb.append("FAIL: makeSos"));
                    return;
                }
                byte[] dg = GringotsBridge.wrapSos(sos);
                if (dg == null) {
                    finishLive(sb.append("FAIL: wrap"));
                    return;
                }
                sb.append("sos bytes=").append(sos.length).append(';');
                sock = new DatagramSocket();
                sock.setSoTimeout(5000);
                InetAddress addr = InetAddress.getByName(host);
                sock.send(new DatagramPacket(dg, dg.length, addr, port));
                byte[] rbuf = new byte[2048];
                DatagramPacket rp = new DatagramPacket(rbuf, rbuf.length);
                sock.receive(rp);
                byte[] raw = Arrays.copyOf(rbuf, rp.getLength());
                sb.append("reply bytes=").append(raw.length).append(';');
                byte[] ack = GringotsBridge.unwrapDeliver(raw);
                if (ack == null) {
                    finishLive(sb.append("FAIL: no ack"));
                    return;
                }
                long now2 = System.currentTimeMillis() / 1000L;
                int v = GringotsBridge.verifyFrame(ack, now2);
                byte[] ad = GringotsBridge.describeFrame(ack);
                String at = (ad == null) ? null : new String(ad);
                sb.append("verify(ack)=").append(v).append(';');
                sb.append("ack=").append(at == null ? "null"
                        : at.substring(0, Math.min(22, at.length()))).append(';');
                // Replay probe: resend the same datagram, expect no second ACK.
                sock.send(new DatagramPacket(dg, dg.length, addr, port));
                byte[] rbuf2 = new byte[2048];
                DatagramPacket rp2 = new DatagramPacket(rbuf2, rbuf2.length);
                String replay;
                try {
                    sock.receive(rp2);
                    byte[] raw2 = Arrays.copyOf(rbuf2, rp2.getLength());
                    replay = (GringotsBridge.unwrapDeliver(raw2) == null) ? "held" : "LEAKED-ACK";
                } catch (SocketTimeoutException e) {
                    replay = "silent";
                }
                sb.append("replay=").append(replay).append(';');
                boolean ok = v == 0 && at != null && at.startsWith("GRINGOTTS/1 TYPE=ACK")
                        && (replay.equals("held") || replay.equals("silent"));
                finishLive(sb.append(ok ? "LIVE LOOP OK." : "FAIL: verdicts"));
            } catch (Exception e) {
                finishLive(sb.append("FAIL: ").append(e.toString()));
            } finally {
                if (sock != null) {
                    sock.close();
                }
            }
        }).start();
    }

    private void finishLive(StringBuilder sb) {
        final String res = sb.toString();
        status.post(() -> status.setText(res));
        Log.i("Gringots", "udptest result: " + res);
    }
}
