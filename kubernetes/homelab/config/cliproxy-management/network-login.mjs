// Upstream has no auth-off mode for its management panel. The private-network
// nginx gateway holds the real key; this non-secret marker only satisfies the
// panel's client-side session model. Fail the build if upstream changes it.
import { readFileSync, writeFileSync } from 'node:fs';
const path = 'src/stores/useAuthStore.ts';
let source = readFileSync(path, 'utf8');
const replacements = [
  ["const wasLoggedIn = localStorage.getItem('isLoggedIn') === 'true';", 'const wasLoggedIn = true;'],
  ["const resolvedKey = managementKey || '';", "const resolvedKey = 'private-network';"],
  ['apiBase || legacyBase || detectApiBaseFromLocation()', 'detectApiBaseFromLocation()'],
  ['return shouldAttemptAutoLogin(wasLoggedIn, base, managementKey);', "return shouldAttemptAutoLogin(wasLoggedIn, base, managementKey || 'private-network');"],
];
for (const [from, to] of replacements) {
  if (!source.includes(from)) throw new Error(`Upstream auth contract changed: ${from}`);
  source = source.replaceAll(from, to);
}
// The two destructurings now contain unused fields; TypeScript checks them.
source = source.replace('const { apiBase, managementKey, rememberPassword } = get();', 'const { rememberPassword } = get();');
source = source.replace(/          const legacyBase =\n            obfuscatedStorage\.getItem<string>\('apiBase'\) \|\|\n            obfuscatedStorage\.getItem<string>\('apiUrl', \{ encrypt: true \}\);\n/, '');
writeFileSync(path, source);
