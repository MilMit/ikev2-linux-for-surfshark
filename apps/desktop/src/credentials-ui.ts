import { invoke } from '@tauri-apps/api/core';

const STYLE_ID = 'milmit-credentials-style';
const ROW_ID = 'milmit-credentials-row';
const MODAL_ID = 'milmit-credentials-modal';
const USER_KEY = 'milmit-surfshark-service-user';

function installStyle() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement('style');
  style.id = STYLE_ID;
  style.textContent = `
    .credentials-overlay{position:fixed;inset:0;z-index:9999;background:rgba(4,12,22,.72);backdrop-filter:blur(9px);display:flex;align-items:center;justify-content:center;padding:22px}
    .credentials-card{width:min(520px,100%);background:#172d43;border:1px solid rgba(255,255,255,.09);border-radius:20px;box-shadow:0 28px 80px rgba(0,0,0,.42);overflow:hidden;color:#fff}
    .credentials-head{display:flex;align-items:center;justify-content:space-between;padding:18px 20px;border-bottom:1px solid rgba(255,255,255,.07)}
    .credentials-head h2{font-size:18px;margin:0}.credentials-close{border:0;background:transparent;color:#b9c8d6;font-size:27px;line-height:1;cursor:pointer}
    .credentials-body{padding:20px;display:grid;gap:15px}.credentials-note{font-size:12px;line-height:1.55;color:#9fb3c4;margin:0}
    .credentials-field{display:grid;gap:7px}.credentials-field label{font-size:12px;font-weight:800;color:#bdd0df}.credentials-field input{width:100%;box-sizing:border-box;min-height:45px;border-radius:10px;border:1px solid rgba(255,255,255,.1);background:#203b55;color:#fff;padding:0 12px;outline:none}.credentials-field input:focus{border-color:#57c28b;box-shadow:0 0 0 3px rgba(87,194,139,.12)}
    .credentials-status{display:flex;gap:8px;align-items:center;border-radius:10px;padding:10px 12px;background:#10263a;color:#bdd0df;font-size:12px}.credentials-status.ok{color:#83ddb0}.credentials-status.err{color:#ff9ca8}
    .credentials-save{min-height:47px;border:0;border-radius:10px;background:#57c28b;color:#082317;font-weight:900;cursor:pointer}.credentials-save:disabled{opacity:.55;cursor:default}
    .credentials-security{font-size:11px;color:#8ea5b8;line-height:1.5}.credentials-security b{color:#bcd2e2}
  `;
  document.head.appendChild(style);
}

async function credentialsSaved(): Promise<boolean> {
  try {
    const out = await invoke<string>('helper_action', { action: 'credentials-status', args: [] });
    return out.includes('SAVED=1');
  } catch {
    return false;
  }
}

async function openCredentials() {
  document.getElementById(MODAL_ID)?.remove();
  const saved = await credentialsSaved();
  const overlay = document.createElement('div');
  overlay.id = MODAL_ID;
  overlay.className = 'credentials-overlay';
  overlay.innerHTML = `
    <section class="credentials-card" role="dialog" aria-modal="true" aria-label="Surfshark credentials">
      <div class="credentials-head"><h2>Surfshark Credentials</h2><button class="credentials-close" aria-label="Close">×</button></div>
      <div class="credentials-body">
        <p class="credentials-note">Use the <b>service credentials</b> from Surfshark's manual VPN setup, not your normal Surfshark account email/password.</p>
        <div class="credentials-status ${saved ? 'ok' : ''}">${saved ? '✓ Credentials are saved on this device' : 'No Surfshark service credentials are saved yet'}</div>
        <div class="credentials-field"><label for="milmit-service-user">Service username</label><input id="milmit-service-user" autocomplete="username" spellcheck="false" placeholder="Surfshark service username" /></div>
        <div class="credentials-field"><label for="milmit-service-pass">Service password</label><input id="milmit-service-pass" type="password" autocomplete="new-password" placeholder="Surfshark service password" /></div>
        <button class="credentials-save">Save credentials securely</button>
        <div class="credentials-security"><b>Security:</b> the password is sent to the privileged helper over stdin and is never placed in command-line arguments. The helper stores it in <code>/etc/milmit-surfshark/credentials</code> as a root-only file.</div>
      </div>
    </section>`;
  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector<HTMLButtonElement>('.credentials-close')?.addEventListener('click', close);
  overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

  const user = overlay.querySelector<HTMLInputElement>('#milmit-service-user')!;
  const pass = overlay.querySelector<HTMLInputElement>('#milmit-service-pass')!;
  const save = overlay.querySelector<HTMLButtonElement>('.credentials-save')!;
  const status = overlay.querySelector<HTMLDivElement>('.credentials-status')!;
  user.value = localStorage.getItem(USER_KEY) || '';
  (user.value ? pass : user).focus();

  save.addEventListener('click', async () => {
    const username = user.value.trim();
    const password = pass.value;
    if (!username || !password) {
      status.className = 'credentials-status err';
      status.textContent = 'Enter both the Surfshark service username and service password.';
      return;
    }
    save.disabled = true;
    save.textContent = 'Saving…';
    status.className = 'credentials-status';
    status.textContent = 'Requesting permission and saving credentials…';
    try {
      await invoke<string>('save_credentials', { username, password });
      localStorage.setItem(USER_KEY, username);
      pass.value = '';
      status.className = 'credentials-status ok';
      status.textContent = '✓ Credentials saved securely. You can now connect to a location.';
      save.textContent = 'Saved';
      setTimeout(() => { save.disabled = false; save.textContent = 'Save credentials securely'; }, 1200);
    } catch (e) {
      status.className = 'credentials-status err';
      status.textContent = String(e) || 'Credential save failed.';
      save.disabled = false;
      save.textContent = 'Save credentials securely';
    }
  });
}

function injectSettingsRow() {
  const title = document.querySelector<HTMLElement>('.topbar h1');
  if (!title || title.textContent?.trim() !== 'Settings') return;
  const list = document.querySelector<HTMLElement>('.page-pad.stack-list');
  if (!list || document.getElementById(ROW_ID)) return;

  const row = document.createElement('button');
  row.id = ROW_ID;
  row.className = 'settings-row';
  row.innerHTML = '<span><b>Surfshark credentials</b><small>Service username and password for manual IKEv2</small></span><span aria-hidden="true" style="font-size:22px;color:#a8bacb">›</span>';
  row.addEventListener('click', () => void openCredentials());
  list.prepend(row);
}

installStyle();
injectSettingsRow();
new MutationObserver(injectSettingsRow).observe(document.body, { childList: true, subtree: true });
