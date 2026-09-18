import { readFileSync } from 'node:fs';
import { after, before, beforeEach, test } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, doc, getDoc, setDoc } from 'firebase/firestore';

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-zeolite',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: '127.0.0.1',
      port: 8085,
    },
  });
});

beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const me = () => env.authenticatedContext('me').firestore();

// The shape the app writes for a mark, which every other kind resembles.
const mark = {
  status: 'present',
  weight: 1,
  note: null,
  tag: null,
  changedAt: 1_700_000_000_000,
  deletedAt: null,
};

test('the owner can write and read a row the app files', async () => {
  const ref = doc(me(), 'users/me/attendance/abc:20260304:540');
  await assertSucceeds(setDoc(ref, mark));
  await assertSucceeds(getDoc(ref));
});

test('nobody else can read or write it', async () => {
  const other = env.authenticatedContext('someone').firestore();
  await assertFails(setDoc(doc(other, 'users/me/attendance/x'), mark));
  await assertFails(getDoc(doc(other, 'users/me/attendance/x')));
  const nobody = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(nobody, 'users/me/attendance/x')));
});

test('a collection the app never files is refused', async () => {
  await assertFails(setDoc(doc(me(), 'users/me/anything/x'), mark));
});

test('a row far wider than the app writes is refused', async () => {
  const wide = Object.fromEntries(
    Array.from({ length: 41 }, (_, i) => [`f${i}`, i]),
  );
  await assertFails(setDoc(doc(me(), 'users/me/subjects/x'), wide));
});

test('a timestamp that is not a number is refused', async () => {
  const ref = doc(me(), 'users/me/attendance/x');
  await assertFails(setDoc(ref, { ...mark, changedAt: 'yesterday' }));
  await assertFails(setDoc(ref, { ...mark, deletedAt: 1.5 }));
});

test('a tombstone can be merged onto an existing row', async () => {
  const ref = doc(me(), 'users/me/attendance/x');
  await setDoc(ref, mark);
  await assertSucceeds(
    setDoc(ref, { deletedAt: 1_700_000_000_001 }, { merge: true }),
  );
});

test('the settings row files under meta', async () => {
  await assertSucceeds(
    setDoc(doc(me(), 'users/me/meta/schedule'), {
      semesterStart: 20260713,
      targetPercent: 0.75,
      changedAt: null,
      deletedAt: null,
    }),
  );
});

test('deleting an account can clear its rows and its user document', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users/me/attendance/x'), mark);
    await setDoc(doc(ctx.firestore(), 'users/me'), { note: 'seeded' });
  });
  await assertSucceeds(deleteDoc(doc(me(), 'users/me/attendance/x')));
  await assertSucceeds(deleteDoc(doc(me(), 'users/me')));
});
