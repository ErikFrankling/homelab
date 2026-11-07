#!/usr/bin/env python3
"""Keep Proxmox's native OIDC login automatic; fail closed on upstream changes."""
from pathlib import Path
p = Path('/usr/share/pve-manager/js/pvemanagerlib.js')
s = p.read_text()
marker = '// Homelab automatic shared login'
if marker in s:
    raise SystemExit(0)
needle = "                    this.getViewModel().set('openid', data.type === 'openid');"
assert s.count(needle) == 1, 'Upstream Proxmox realm handler changed; review patch'
addition = '''
                    // Homelab automatic shared login; ?manual=1 retains recovery realms.
                    if (value === 'homelab' && data.type === 'openid' &&
                        !new URLSearchParams(location.search).has('manual') &&
                        Proxmox.Utils.getOpenIDRedirectionAuthorization() === undefined) {
                        const previous = Number(sessionStorage.getItem('homelab-sso-attempt') || 0);
                        if (Date.now() - previous > 30000) {
                            sessionStorage.setItem('homelab-sso-attempt', String(Date.now()));
                            Ext.defer(() => this.onLogon(), 50);
                        }
                    }'''
p.write_text(s.replace(needle, needle + addition))
