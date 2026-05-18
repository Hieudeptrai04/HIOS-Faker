/**
 * start-cloud.js — server.js + public tunnel launcher.
 *
 * Why: the iOS app's embedded HTML phones home to a server URL baked
 * in at .deb build time (build-deb.js → `__CI_SERVER__` replacement).
 * Without this script, that URL was the build machine's LAN IP — fine
 * for "iPhone on same Wi-Fi" but useless once the iPhone leaves the
 * house. This wraps server.js + a public tunnel so the iPhone can hit
 * your server from anywhere.
 *
 * Usage:
 *   node start-cloud.js                    # uses cloudflared (free, persistent URL via login)
 *   node start-cloud.js --ngrok            # uses ngrok (requires NGROK_AUTHTOKEN env var)
 *   node start-cloud.js --no-tunnel        # just runs server.js, no public exposure
 *
 * Workflow:
 *   1. Run this script on the laptop/VPS that will host server.js.
 *   2. Wait for the public URL line ("Tunnel URL: https://...")
 *   3. Re-build the .deb with that URL embedded:
 *        CI_PUBLIC_URL=<that URL> node build-deb.js
 *   4. Push the .deb to GitHub Release or install via Sileo.
 *   5. iPhone now talks to your server from any network.
 *
 * Prerequisites:
 *   - cloudflared:  `winget install --id Cloudflare.cloudflared` (or brew/apt)
 *   - ngrok:        `npm i -g ngrok` + set NGROK_AUTHTOKEN
 */
const { spawn } = require('child_process');
const path = require('path');

const args = process.argv.slice(2);
const wantNgrok    = args.includes('--ngrok');
const wantNoTunnel = args.includes('--no-tunnel');
const PORT = 3456;

console.log('======================================================');
console.log('  ChangeInfoIos — Cloud Server Launcher');
console.log('======================================================');

// (1) server.js — inherit stdio so user sees its logs live.
console.log('\n[1/2] Starting server.js on port ' + PORT + '...');
const server = spawn('node', ['server.js'], {
  cwd: __dirname,
  stdio: 'inherit',
  env: { ...process.env, PORT: String(PORT) },
});
server.on('exit', code => {
  console.log('\n[server.js] exited with code', code);
  if (tunnel) tunnel.kill('SIGTERM');
  process.exit(code || 0);
});

if (wantNoTunnel) {
  console.log('\n[--no-tunnel] Skipping public tunnel — server is LAN-only.');
  return;
}

// (2) tunnel — pick cloudflared by default (free + persistent), ngrok if user passes --ngrok.
let tunnel = null;
setTimeout(() => {
  if (wantNgrok) {
    console.log('\n[2/2] Starting ngrok tunnel...');
    tunnel = spawn('ngrok', ['http', String(PORT), '--log=stdout'], {
      cwd: __dirname,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } else {
    // cloudflared quick tunnel — anonymous, ephemeral URL, no login required.
    // For a persistent URL, run `cloudflared tunnel login` once + use a
    // named tunnel; that's out of scope for this auto-launcher.
    console.log('\n[2/2] Starting cloudflared quick tunnel...');
    tunnel = spawn('cloudflared', ['tunnel', '--url', 'http://localhost:' + PORT], {
      cwd: __dirname,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  }

  tunnel.on('error', e => {
    console.error('\n[tunnel] FATAL: ' + e.message);
    console.error('Install hint:');
    if (wantNgrok) console.error('  npm i -g ngrok  &&  ngrok config add-authtoken <token>');
    else           console.error('  winget install --id Cloudflare.cloudflared');
    console.error('Or pass --no-tunnel to run server.js without public exposure.');
    server.kill('SIGTERM');
    process.exit(1);
  });

  // Sniff the tunnel URL from stdout/stderr so we can highlight it for the user.
  const urlRegex = /(https:\/\/[a-z0-9\-]+\.(?:trycloudflare\.com|ngrok(?:-free)?\.app|ngrok\.io))/i;
  let urlPrinted = false;
  const sniff = data => {
    const text = data.toString();
    process.stderr.write(text);                 // mirror tunnel logs live
    const m = text.match(urlRegex);
    if (m && !urlPrinted) {
      urlPrinted = true;
      const url = m[1];
      console.log('\n======================================================');
      console.log('  ★ Tunnel URL: ' + url);
      console.log('  ★ Rebuild .deb with:');
      console.log('    CI_PUBLIC_URL=' + url + ' node build-deb.js');
      console.log('======================================================\n');
    }
  };
  tunnel.stdout.on('data', sniff);
  tunnel.stderr.on('data', sniff);
}, 1500);  // small delay so server.js finishes binding to PORT first

process.on('SIGINT', () => {
  console.log('\n[exit] SIGINT — shutting down...');
  if (tunnel) tunnel.kill('SIGTERM');
  server.kill('SIGTERM');
});
