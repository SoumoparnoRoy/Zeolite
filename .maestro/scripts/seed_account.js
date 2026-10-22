// Runs on the host, against the Firebase emulators only. Wipes every emulator
// account and document, then creates the test account already confirmed, since
// the rules refuse writes from an address that was never verified.
const auth = "http://localhost:9099";
const store = "http://localhost:8085";
const owner = { Authorization: "Bearer owner", "Content-Type": "application/json" };

http.delete(`${auth}/emulator/v1/projects/${PROJECT}/accounts`);
http.delete(`${store}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`);

const created = http.post(
  `${auth}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator`,
  {
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD, returnSecureToken: true }),
  },
);
if (created.status !== 200) throw new Error(`sign-up failed: ${created.status}`);
output.uid = json(created.body).localId;

const confirmed = http.post(
  `${auth}/identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:update`,
  { headers: owner, body: JSON.stringify({ localId: output.uid, emailVerified: true }) },
);
if (confirmed.status !== 200) throw new Error(`confirm failed: ${confirmed.status}`);
