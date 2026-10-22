// The emulator's owner token reads past the rules.
const owner = { Authorization: "Bearer owner", "Content-Type": "application/json" };

const subjects = http.get(
  `http://localhost:8085/v1/projects/${PROJECT}/databases/(default)/documents/users/${UID}/subjects`,
  { headers: owner },
);
output.subjects = String((json(subjects.body).documents || []).length);

const lookup = http.post(
  `http://localhost:9099/identitytoolkit.googleapis.com/v1/projects/${PROJECT}/accounts:lookup`,
  { headers: owner, body: JSON.stringify({ localId: [UID] }) },
);
output.accounts = String((json(lookup.body).users || []).length);
