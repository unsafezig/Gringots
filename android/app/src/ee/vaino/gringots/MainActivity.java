package ee.vaino.gringots;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Arrays;

/**
 * Phase 5 debug console: start / stop / status controls wired to real
 * native calls. Start runs a deterministic self-test (mint SOS, verify
 * it, verify expiry rejection) and reports each step; stop returns to
 * idle. The ARM64 Zinux guest VM host attaches behind this console in
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
            if (ok == 0 && expired == 1) {
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
}
