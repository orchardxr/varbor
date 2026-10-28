// Plays Half-Life: Alyx's side of the interstitials protocol against macvr-broker, as OpenComposite does for the game:
// RegisterExternalWebRoot, wait for the page's "ready" on hlvr/mailbox, then the messages from the game's log.
//   node tests/webui/alyx_sequence.mjs [map] [port]
// map: startup (default; "LOADING" then "Press Trigger To Start") or a game map such as a2_hideout (hologram map).
const map = process.argv[2] || 'startup';
const port = process.argv[3] || '27062';
const home = process.env.HOME;
const steam = `${home}/Library/Application Support/Steam`;
const winRoot = 'S:\\steamapps\\common\\Half-Life Alyx\\game\\hlvr';

const t0 = Date.now();
const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function mailbox(name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const box = { ws, queue: [], waiters: [] };
    ws.onopen = () => { ws.send(`mailbox_open ${name}`); resolve(box); };
    ws.onerror = e => reject(new Error(`ws ${name}: ${e.message || 'error'}`));
    ws.onmessage = e => {
      const m = JSON.parse(e.data);
      log(`<- ${name}:`, e.data.slice(0, 160));
      const w = box.waiters.findIndex(w => w.type === m.type);
      if (w >= 0) box.waiters.splice(w, 1)[0].resolve(m); else box.queue.push(m);
    };
    box.send = (to, obj) => { const s = JSON.stringify(obj, null, '\t'); log(`-> ${to}:`, s.replace(/\s+/g, ' ').slice(0, 160)); ws.send(`mailbox_send ${to} ${s}`); };
    box.wait = (type, ms) => new Promise((res, rej) => {
      const q = box.queue.findIndex(m => m.type === type);
      if (q >= 0) return res(box.queue.splice(q, 1)[0]);
      box.waiters.push({ type, resolve: res });
      setTimeout(() => rej(new Error(`timeout waiting for ${type} on ${name}`)), ms);
    });
  });
}

const ctl = await mailbox(`vrclient/${process.pid}`);
ctl.send('web_server_mailbox', {
  type: 'register_external_webroot', name: 'hlvr', path: `${winRoot}/webui`,
  unix_path: `${steam}/steamapps/common/Half-Life Alyx/game/hlvr/webui`,
  drives: { s: steam, c: `${steam}/steamapps/compatdata/546560/pfx/drive_c`, z: '/' },
  returnAddress: `vrclient/${process.pid}`, message_id: 1,
});
const r = await ctl.wait('register_external_webroot_response', 20000);
log('RegisterExternalWebRoot result', r.result);

const game = await mailbox('hlvr/mailbox');
await game.wait('ready', 20000);
log('page ready');

game.send('hlvr/interstitials', { type: 'set_paths', webroot: `${winRoot}\\webui`, models: `${winRoot}\\models\\ui\\` });
await sleep(50);
const tips = {
  startup: { chapter: '', tipText: 'BLACK MESA: ALYX VANCE was an infant during THE BLACK MESA INCIDENT.', facingAngle: 0 },
  default: { chapter: '', tipText: 'TIP: Store extra items by placing them in the locations near your wrists.',
    description: "THE SEVEN HOUR WAR: Earth's surrender to THE COMBINE was negotiated by DR. WALLACE BREEN, the administrator of BLACK MESA.", facingAngle: 1.386746 },
};
const t = tips[map] || tips.default;
game.send('hlvr/interstitials', { type: 'begin_loading', mapName: map, chapter: t.chapter, tipText: t.tipText,
  ...(t.description ? { description: t.description } : {}), loadingText: 'LOADING', facingAngle: t.facingAngle });
await sleep(Number(process.env.LOAD_MS || 5000));
game.send('hlvr/interstitials', { type: 'show_message', text: 'Press Trigger To Start' });
await sleep(Number(process.env.PROMPT_MS || 5000));
game.send('hlvr/interstitials', { type: 'end_loading' });
await sleep(Number(process.env.AFTER_MS || 8000));
log('done, closing (the broker destroys the webui)');
ctl.ws.close();
game.ws.close();
await sleep(500);
process.exit(0);
